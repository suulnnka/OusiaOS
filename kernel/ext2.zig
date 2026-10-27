//! ext2 文件系统（读 + 写）—— 真磁盘上的经典文件系统
//!
//! 教学要点：
//!   - ext2 把磁盘切成等长的【块】(1K/2K/4K)，按【块组】管理：
//!     每组自带两张位图（块/ inode）+ inode 表 + 数据块
//!   - 磁盘布局（块号，1KB 块为例）：
//!       [0 引导块][1 超级块][2 组描述符][3 块位图][4 inode位图][5.. inode表][数据块...]
//!     超级块固定在字节 1024 处，magic = 0xEF53
//!   - 文件 = inode + 数据块链：i_block[0..11] 直接块，[12] 一重间接，
//!     [13] 二重，[14] 三重——间接块里存的是"块号数组"
//!   - 目录是特殊文件：内容为一串【目录项】(ino, rec_len, name)。
//!     rec_len 让条目可以"撑到"下一个条目——删除 = 把空间并给前一项
//!   - 空闲管理 = 位图：分配就是"找第一个 0 位并置 1"，O(n/8) 扫描
//!   - 一致性义务：任何分配/释放都要同步回写位图、超级块空闲计数、
//!     组描述符空闲计数、inode 的 i_blocks（512 字节扇区数）——
//!     这样宿主机上的 e2fsck 检查镜像才挑不出毛病
//!
//! 与本内核的对接：vfs 把 1024+ino 编码为 ext2 节点，挂载在 /mnt；
//! 写支持经 open(O_CREAT)/write/mkdir/unlink/rmdir 全链路落盘。
//!
//! 并发取舍（单核教学内核）：
//!   - 所有公开操作整体关中断（cli/sti）：磁盘 I/O 是"读-改-写"序列，
//!     中途被抢占会让另一进程插入自己的 I/O 命令、污染块缓存
//!   - 块缓存直接映射 24 块、写穿透：因此【禁止跨 blockPtr 持有切片】
//!     ——任何分配/递归都可能换出当前槽，写回前必须重新取块
//!   - 一次操作结束才 ata.flush()（按操作刷，不按块刷）

const std = @import("std");
const console = @import("console.zig");
const ata = @import("ata.zig");

pub const FsError = error{ Io, NoSpace };
pub const RmError = error{ NotFound, NotDir, NotEmpty, Io };

const ROOT_INO: u32 = 2;
const MAX_GROUPS = 32; // 32 组 × 8192 块 × 1KB = 256MB 容量上限
const CACHE_N = 24; // 块缓存条数（直接映射）
const CACHE_INVALID: u32 = 0xFFFF_FFFF;

// 目录项 file_type 值
const FT_REGULAR: u8 = 1;
const FT_DIR: u8 = 2;

// ---- 超级块字段偏移（自字节 1024 起）----
const SB_INODES = 0;
const SB_BLOCKS = 4;
const SB_FREE_BLOCKS = 12;
const SB_FREE_INODES = 16;
const SB_LOG_BSIZE = 24;
const SB_BPG = 32;
const SB_IPG = 40;
const SB_MAGIC = 56;
const SB_REV = 76;
const SB_FIRST_INO = 84;
const SB_INODE_SIZE = 88;
const SB_INCOMPAT = 96;
const MAGIC: u16 = 0xEF53;
const INCOMPAT_FILETYPE: u32 = 0x0002; // 唯一支持的 incompat 特性

// inode 字段偏移（自 inode 起）
const IN_MODE = 0;
const IN_UID = 2;
const IN_SIZE = 4;
const IN_DTIME = 20;
const IN_GID = 24;
const IN_LINKS = 26;
const IN_BLOCKS512 = 28;
const IN_IBLOCK = 40; // i_block[15]

// 组描述符偏移（每项 32 字节）
const GD_BLOCK_BITMAP = 0;
const GD_INODE_BITMAP = 4;
const GD_INODE_TABLE = 8;
const GD_FREE_BLOCKS = 12;
const GD_FREE_INODES = 14;
const GD_USED_DIRS = 16;

// ---------------- 挂载状态 ----------------

var ready = false;
var block_size: u32 = 1024;
var spb: u32 = 2; // 每块扇区数 = block_size/512
var blocks_per_group: u32 = 8192;
var inodes_per_group: u32 = 0;
var inode_size: u32 = 128;
var first_ino: u32 = 11; // 首个非保留 inode
var inodes_count: u32 = 0;
var blocks_count: u32 = 0;
var first_data_block: u32 = 1;
var gd_block: u32 = 2;
var group_count: u32 = 0;
var has_filetype = true;
var free_blocks_ram: u32 = 0;
var free_inodes_ram: u32 = 0;

const Group = struct {
    block_bitmap: u32,
    inode_bitmap: u32,
    inode_table: u32,
    free_blocks: u16,
    free_inodes: u16,
    used_dirs: u16,
};
var groups: [MAX_GROUPS]Group = undefined;

// 超级块/组描述符的 RAM 镜像（分配/释放时改镜像 → 整块回写）
var sb_buf: [1024]u8 = undefined;
var gd_buf: [4096]u8 = undefined;

// ---------------- 块缓存（直接映射，写穿透） ----------------

var cache_block: [CACHE_N]u32 = @splat(CACHE_INVALID);
var cache_data: [CACHE_N][4096]u8 = undefined;

/// 取块的可写视图：未命中则从磁盘装入（可能换出同槽旧块）
fn blockPtr(b: u32) ?[]u8 {
    const i: usize = b % CACHE_N;
    if (cache_block[i] == b) return cache_data[i][0..block_size];
    if (!ata.readSectors(b * spb, @intCast(spb), &cache_data[i])) return null;
    cache_block[i] = b;
    return cache_data[i][0..block_size];
}

/// 新分配块装入缓存（全零，跳过读盘——内容马上要被覆盖/必须为零）
fn zeroBlock(b: u32) ?[]u8 {
    const i: usize = b % CACHE_N;
    @memset(cache_data[i][0..block_size], 0);
    cache_block[i] = b;
    return cache_data[i][0..block_size];
}

/// 把缓存中的块写回磁盘（写穿透：调用方改完立即刷，不持有脏页）
fn flushBlock(b: u32) bool {
    const i: usize = b % CACHE_N;
    if (cache_block[i] != b) return false;
    return ata.writeSectors(b * spb, @intCast(spb), &cache_data[i]);
}

// ---------------- inode ----------------

pub const Inode = struct {
    mode: u16 = 0,
    uid: u16 = 0,
    gid: u16 = 0,
    size: u32 = 0,
    links: u16 = 0,
    nsec512: u32 = 0, // i_blocks：占用 512 字节扇区数（含间接块）
    dtime: u32 = 0, // 删除时间（存活 inode 恒为 0；e2fsck 要求删除时写入）
    ib: [15]u32 = @splat(0),
};

const InodeLoc = struct { blk: u32, off: u32 };

fn inodeLoc(ino: u32) InodeLoc {
    const g = (ino - 1) / inodes_per_group;
    const idx = (ino - 1) % inodes_per_group;
    const byte = @as(u64, idx) * inode_size;
    return .{ .blk = groups[g].inode_table + @as(u32, @intCast(byte / block_size)), .off = @intCast(byte % block_size) };
}

/// 读 inode（时戳/flags 等未管理字段不携带——writeInode 按字段回写不碰它们）
fn readInode(ino: u32) ?Inode {
    if (!ready or ino == 0 or ino > inodes_count) return null;
    const loc = inodeLoc(ino);
    const bp = blockPtr(loc.blk) orelse return null;
    const q = bp[loc.off .. loc.off + inode_size];
    var in = Inode{
        .mode = le16(q, IN_MODE),
        .uid = le16(q, IN_UID),
        .gid = le16(q, IN_GID),
        .size = le32(q, IN_SIZE),
        .links = le16(q, IN_LINKS),
        .nsec512 = le32(q, IN_BLOCKS512),
        .dtime = le32(q, IN_DTIME),
    };
    for (0..15) |i| in.ib[i] = le32(q, IN_IBLOCK + i * 4);
    return in;
}

/// 回写 inode 的管理字段（其余字段保持磁盘原样）
fn writeInode(ino: u32, in: *const Inode) bool {
    const loc = inodeLoc(ino);
    const bp = blockPtr(loc.blk) orelse return false;
    const q = bp[loc.off .. loc.off + inode_size];
    setLe16(q, IN_MODE, in.mode);
    setLe16(q, IN_UID, in.uid);
    setLe32(q, IN_SIZE, in.size);
    setLe32(q, IN_DTIME, in.dtime);
    setLe16(q, IN_GID, in.gid);
    setLe16(q, IN_LINKS, in.links);
    setLe32(q, IN_BLOCKS512, in.nsec512);
    for (0..15) |i| setLe32(q, IN_IBLOCK + i * 4, in.ib[i]);
    return flushBlock(loc.blk);
}

/// 新分配 inode 清零（ialloc 内调用；保证未管理字段干净）
fn zeroInode(ino: u32) bool {
    const loc = inodeLoc(ino);
    const bp = blockPtr(loc.blk) orelse return false;
    @memset(bp[loc.off .. loc.off + inode_size], 0);
    return flushBlock(loc.blk);
}

// ---------------- 位图分配 ----------------

fn testBit(bp: []const u8, bit: u32) bool {
    return bp[bit / 8] & (@as(u8, 1) << @as(u3, @intCast(bit % 8))) != 0;
}
fn setBit(bp: []u8, bit: u32) void {
    bp[bit / 8] |= @as(u8, 1) << @as(u3, @intCast(bit % 8));
}
fn clearBit(bp: []u8, bit: u32) void {
    bp[bit / 8] &= ~(@as(u8, 1) << @as(u3, @intCast(bit % 8)));
}

/// 找第一个 0 位
fn findClearBit(bp: []const u8, bits: u32) ?u32 {
    var i: u32 = 0;
    while (i < bits) : (i += 8) {
        const byte = bp[i / 8];
        if (byte == 0xFF) continue;
        var b: u32 = 0;
        while (b < 8 and i + b < bits) : (b += 1) {
            if (byte & (@as(u8, 1) << @as(u3, @intCast(b))) == 0) return i + b;
        }
    }
    return null;
}

fn writeGDs() bool {
    @memset(gd_buf[0 .. MAX_GROUPS * 32], 0);
    for (0..group_count) |g| {
        const o = g * 32;
        setLe32(gd_buf[0..], o, groups[g].block_bitmap);
        setLe32(gd_buf[0..], o + 4, groups[g].inode_bitmap);
        setLe32(gd_buf[0..], o + 8, groups[g].inode_table);
        setLe16(gd_buf[0..], o + 12, groups[g].free_blocks);
        setLe16(gd_buf[0..], o + 14, groups[g].free_inodes);
        setLe16(gd_buf[0..], o + 16, groups[g].used_dirs);
    }
    // 经块缓存写回（可能跨多块；GD 块不会与数据块混用）
    const nbytes = group_count * 32;
    var off: u32 = 0;
    while (off < nbytes) : (off += block_size) {
        const blk = gd_block + off / block_size;
        const bp = blockPtr(blk) orelse return false;
        @memset(bp, 0);
        const chunk = @min(block_size, nbytes - off);
        @memcpy(bp[0..chunk], gd_buf[off..off + chunk]);
        if (!flushBlock(blk)) return false;
    }
    return true;
}

fn writeSuper() bool {
    setLe32(sb_buf[0..], SB_FREE_BLOCKS, free_blocks_ram);
    setLe32(sb_buf[0..], SB_FREE_INODES, free_inodes_ram);
    // 超级块固定占字节 1024..2048 = 扇区 2..4，与块大小无关
    return ata.writeSectors(2, 2, &sb_buf);
}

/// 分配一个数据块（全零、已落盘）
fn balloc(nalloc: *u32) ?u32 {
    for (0..group_count) |g| {
        if (groups[g].free_blocks == 0) continue;
        const gstart: u32 = @intCast(g * blocks_per_group + first_data_block);
        const bits = @min(blocks_per_group, blocks_count - gstart);
        const bp = blockPtr(groups[g].block_bitmap) orelse return null;
        const b = findClearBit(bp, bits) orelse continue; // 计数漂移的兜底
        setBit(bp, b);
        if (!flushBlock(groups[g].block_bitmap)) return null;
        groups[g].free_blocks -= 1;
        free_blocks_ram -= 1;
        _ = writeGDs();
        _ = writeSuper();
        nalloc.* += 1;
        return gstart + b;
    }
    return null;
}

fn bfree(blk: u32) void {
    if (blk < first_data_block or blk >= blocks_count) return;
    const g = (blk - first_data_block) / blocks_per_group;
    const b = (blk - first_data_block) % blocks_per_group;
    const bp = blockPtr(groups[g].block_bitmap) orelse return;
    if (!testBit(bp, b)) return; // 双重释放防御
    clearBit(bp, b);
    _ = flushBlock(groups[g].block_bitmap);
    groups[g].free_blocks += 1;
    free_blocks_ram += 1;
    _ = writeGDs();
    _ = writeSuper();
}

fn ialloc() ?u32 {
    for (0..group_count) |g| {
        if (groups[g].free_inodes == 0) continue;
        const bp = blockPtr(groups[g].inode_bitmap) orelse return null;
        const b = findClearBit(bp, inodes_per_group) orelse continue;
        const ino: u32 = @intCast(g * inodes_per_group + b + 1);
        if (ino < first_ino or ino > inodes_count) continue; // 保留段
        setBit(bp, b);
        if (!flushBlock(groups[g].inode_bitmap)) return null;
        groups[g].free_inodes -= 1;
        free_inodes_ram -= 1;
        _ = writeGDs();
        _ = writeSuper();
        if (!zeroInode(ino)) return null;
        return ino;
    }
    return null;
}

fn ifree(ino: u32) void {
    if (ino == 0 or ino > inodes_count) return;
    const g = (ino - 1) / inodes_per_group;
    const b = (ino - 1) % inodes_per_group;
    const bp = blockPtr(groups[g].inode_bitmap) orelse return;
    if (!testBit(bp, b)) return;
    clearBit(bp, b);
    _ = flushBlock(groups[g].inode_bitmap);
    groups[g].free_inodes += 1;
    free_inodes_ram += 1;
    _ = writeGDs();
    _ = writeSuper();
}

/// 分配 + 清零 + 落盘（数据块和间接块共用；计数供 inode.i_blocks 用）
fn allocZeroBlock(nalloc: *u32) ?u32 {
    const blk = balloc(nalloc) orelse return null;
    if (zeroBlock(blk) == null) return null;
    if (!flushBlock(blk)) return null;
    return blk;
}

// ---------------- 块映射（含间接块的按需分配） ----------------

const MapRes = struct { blk: u32, fresh: bool };

fn upow(b: u32, e: u32) u32 {
    var r: u32 = 1;
    for (0..e) |_| r *= b;
    return r;
}

/// 在 inode 的 i_block 表里解析逻辑块 bi 的物理块号。
/// alloc=true 时缺失的（间接/数据）块会分配并清零；nalloc 累计分配数。
fn mapFileBlock(icb: *[15]u32, bi: u32, alloc: bool, nalloc: *u32) ?MapRes {
    const bps = block_size / 4;

    if (bi < 12) {
        if (icb[bi] != 0) return .{ .blk = icb[bi], .fresh = false };
        if (!alloc) return null;
        const nb = allocZeroBlock(nalloc) orelse return null;
        icb[bi] = nb;
        return .{ .blk = nb, .fresh = true };
    }

    // 间接层：定位 (根槽位, 深度, 层内索引)
    var idx = bi - 12;
    var depth: u32 = 1;
    var root_slot: usize = 12; // 一重间接
    if (idx >= bps) {
        idx -= bps;
        depth = 2;
        root_slot = 13;
    }
    if (idx >= upow(bps, 2)) {
        idx -= upow(bps, 2);
        depth = 3;
        root_slot = 14;
    }
    if (idx >= upow(bps, 3)) return null; // 超出三重间接

    if (icb[root_slot] == 0) {
        if (!alloc) return null;
        icb[root_slot] = allocZeroBlock(nalloc) orelse return null;
    }
    return mapIndirect(icb[root_slot], depth, idx, alloc, nalloc);
}

/// 沿间接树走 depth 层。idx 的每层除法由 upow(bps, depth-1) 切分。
/// 纪律：写表项前重新取块（alloc 可能换出了本槽），改完立即 flush。
fn mapIndirect(root: u32, depth: u32, idx: u32, alloc: bool, nalloc: *u32) ?MapRes {
    const bps = block_size / 4;

    if (depth == 1) {
        // 本层表项即数据块
        const e = blk: {
            const bp = blockPtr(root) orelse return null;
            break :blk le32(bp, idx * 4);
        };
        if (e != 0) return .{ .blk = e, .fresh = false };
        if (!alloc) return null;
        const nb = allocZeroBlock(nalloc) orelse return null;
        const bp = blockPtr(root) orelse return null; // 重新取（可能被换出）
        setLe32(bp, idx * 4, nb);
        if (!flushBlock(root)) return null;
        return .{ .blk = nb, .fresh = true };
    }

    const span = upow(bps, depth - 1);
    const child_idx = idx / span;
    const child_rem = idx % span;
    var child: u32 = blk: {
        const bp = blockPtr(root) orelse return null;
        break :blk le32(bp, child_idx * 4);
    };
    if (child == 0) {
        if (!alloc) return null;
        child = allocZeroBlock(nalloc) orelse return null;
        const bp = blockPtr(root) orelse return null; // 重新取
        setLe32(bp, child_idx * 4, child);
        if (!flushBlock(root)) return null;
    }
    return mapIndirect(child, depth - 1, child_rem, alloc, nalloc);
}

/// 释放文件全部块：数据块 + 各级间接块
fn freeTree(blk: u32, depth: u32) void {
    if (depth == 0) {
        bfree(blk);
        return;
    }
    // 每个表项处理前重新取块（子块释放会动位图缓存）
    var i: u32 = 0;
    while (i < block_size / 4) : (i += 1) {
        const e = blk: {
            const bp = blockPtr(blk) orelse return;
            break :blk le32(bp, i * 4);
        };
        if (e != 0) freeTree(e, depth - 1);
    }
    bfree(blk);
}

fn freeInodeData(in: *const Inode) void {
    for (in.ib[0..12]) |b| {
        if (b != 0) bfree(b);
    }
    if (in.ib[12] != 0) freeTree(in.ib[12], 1);
    if (in.ib[13] != 0) freeTree(in.ib[13], 2);
    if (in.ib[14] != 0) freeTree(in.ib[14], 3);
}

// ---------------- 目录项 ----------------

const Dirent = struct { ino: u32, rec_len: u16, name_len: u16, ftype: u8 };

fn direntAt(bp: []const u8, off: usize) Dirent {
    // 无 FILETYPE 特性时 name_len 是 u16（低字节同位），byte7 是其高位
    const nl: u16 = if (has_filetype) bp[off + 6] else le16(bp, off + 6);
    const ft: u8 = if (has_filetype) bp[off + 7] else 0;
    return .{ .ino = le32(bp, off), .rec_len = le16(bp, off + 4), .name_len = nl, .ftype = ft };
}

fn writeDirent(bp: []u8, off: usize, rec_len: u16, ino: u32, ftype: u8, name: []const u8) void {
    setLe32(bp, off, ino);
    setLe16(bp, off + 4, rec_len);
    if (has_filetype) {
        bp[off + 6] = @intCast(name.len);
        bp[off + 7] = ftype;
    } else {
        setLe16(bp, off + 6, @intCast(name.len));
    }
    @memcpy(bp[off + 8 ..][0..name.len], name);
}

fn direntName(bp: []const u8, e: Dirent, off: usize) []const u8 {
    return bp[off + 8 .. off + 8 + e.name_len];
}

fn isDotName(name: []const u8) bool {
    return (name.len == 1 and name[0] == '.') or (name.len == 2 and name[0] == '.' and name[1] == '.');
}

/// 在目录里按名字查 inode
pub fn dirLookup(dir: u32, name: []const u8) ?u32 {
    const in = readInode(dir) orelse return null;
    if (in.mode & 0o170000 != 0o040000) return null;
    var ib = in.ib; // mapFileBlock 需要 *mut（只读路径复制一份）
    const nblocks = (in.size + block_size - 1) / block_size;
    var nalloc: u32 = 0;
    var bi: u32 = 0;
    while (bi < nblocks) : (bi += 1) {
        const mr = mapFileBlock(&ib, bi, false, &nalloc) orelse continue;
        const bp = blockPtr(mr.blk) orelse continue;
        var off: usize = 0;
        while (off + 8 <= block_size) {
            const e = direntAt(bp, off);
            if (e.rec_len < 8 or off + e.rec_len > block_size) break;
            if (e.ino != 0 and e.name_len == name.len and
                std.mem.eql(u8, direntName(bp, e, off), name)) return e.ino;
            off += e.rec_len;
        }
    }
    return null;
}

/// 枚举目录孩子（跳过 "." 与 ".."；child = base + ino 供 vfs 直接编码）
pub fn listIno(dir: u32, base: usize, ctx: anytype, cb: fn (@TypeOf(ctx), name: []const u8, child: usize) void) void {
    const in = readInode(dir) orelse return;
    if (in.mode & 0o170000 != 0o040000) return;
    var ib = in.ib;
    const nblocks = (in.size + block_size - 1) / block_size;
    var nalloc: u32 = 0;
    var bi: u32 = 0;
    while (bi < nblocks) : (bi += 1) {
        const mr = mapFileBlock(&ib, bi, false, &nalloc) orelse continue;
        const bp = blockPtr(mr.blk) orelse continue;
        var off: usize = 0;
        while (off + 8 <= block_size) {
            const e = direntAt(bp, off);
            if (e.rec_len < 8 or off + e.rec_len > block_size) break;
            if (e.ino != 0) {
                const name = direntName(bp, e, off);
                if (!isDotName(name)) cb(ctx, name, base + e.ino);
            }
            off += e.rec_len;
        }
    }
}

/// 目录是否只剩 "." ".."（rmdir 的前提）
fn dirIsEmpty(dir: u32) bool {
    const in = readInode(dir) orelse return false;
    var ib = in.ib;
    const nblocks = (in.size + block_size - 1) / block_size;
    var nalloc: u32 = 0;
    var bi: u32 = 0;
    while (bi < nblocks) : (bi += 1) {
        const mr = mapFileBlock(&ib, bi, false, &nalloc) orelse continue;
        const bp = blockPtr(mr.blk) orelse continue;
        var off: usize = 0;
        while (off + 8 <= block_size) {
            const e = direntAt(bp, off);
            if (e.rec_len < 8 or off + e.rec_len > block_size) break;
            if (e.ino != 0 and !isDotName(direntName(bp, e, off))) return false;
            off += e.rec_len;
        }
    }
    return true;
}

/// 向目录加一条目录项（自动扩块）。条目更新该目录 inode 的 size/i_blocks。
pub fn dirAdd(dir: u32, name: []const u8, child: u32, ftype: u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    var in = readInode(dir) orelse return false;
    if (in.mode & 0o170000 != 0o040000) return false;

    const need: u16 = @intCast((8 + name.len + 3) & ~@as(usize, 3));
    const nblocks = (in.size + block_size - 1) / block_size;
    var nalloc: u32 = 0;

    var bi: u32 = 0;
    while (bi < nblocks) : (bi += 1) {
        const mr = mapFileBlock(&in.ib, bi, false, &nalloc) orelse continue;
        const bp = blockPtr(mr.blk) orelse continue;
        var off: usize = 0;
        while (off + 8 <= block_size) {
            const e = direntAt(bp, off);
            if (e.rec_len < 8 or off + e.rec_len > block_size) break;
            const min_len: u16 = @intCast((8 + e.name_len + 3) & ~@as(usize, 3));
            if (e.ino == 0 and e.rec_len >= need) {
                // 空洞复用：保留大 rec_len，之后仍可整段再利用
                writeDirent(bp, off, e.rec_len, child, ftype, name);
                if (!flushBlock(mr.blk)) return false;
                return true;
            }
            if (e.ino != 0 and e.rec_len >= min_len + need) {
                // 收缩现条目的松弛空间，紧随其后插入新条目
                writeDirent(bp, off + min_len, e.rec_len - min_len, child, ftype, name);
                setLe16(bp, off + 4, min_len);
                if (!flushBlock(mr.blk)) return false;
                return true;
            }
            off += e.rec_len;
        }
    }

    // 无空位：目录尾部追加一块（mapFileBlock 分配并清零）
    const mr = mapFileBlock(&in.ib, nblocks, true, &nalloc) orelse return false;
    const bp = blockPtr(mr.blk) orelse return false;
    writeDirent(bp, 0, @intCast(block_size), child, ftype, name);
    if (!flushBlock(mr.blk)) return false;
    in.size += block_size;
    in.nsec512 += 2 * nalloc;
    return writeInode(dir, &in);
}

/// 从目录摘除条目：并入前一条目的 rec_len（块首则置成空洞）
fn dirRemove(dir: u32, name: []const u8) bool {
    const in = readInode(dir) orelse return false;
    var ib = in.ib;
    const nblocks = (in.size + block_size - 1) / block_size;
    var nalloc: u32 = 0;
    var bi: u32 = 0;
    while (bi < nblocks) : (bi += 1) {
        const mr = mapFileBlock(&ib, bi, false, &nalloc) orelse continue;
        const bp = blockPtr(mr.blk) orelse continue;
        var off: usize = 0;
        var prev: ?usize = null;
        while (off + 8 <= block_size) {
            const e = direntAt(bp, off);
            if (e.rec_len < 8 or off + e.rec_len > block_size) break;
            if (e.ino != 0 and e.name_len == name.len and
                std.mem.eql(u8, direntName(bp, e, off), name))
            {
                if (prev) |po| {
                    const pr = le16(bp, po + 4);
                    setLe16(bp, po + 4, pr + e.rec_len);
                } else {
                    setLe32(bp, off, 0); // 块首：就地成洞
                }
                return flushBlock(mr.blk);
            }
            prev = off;
            off += e.rec_len;
        }
    }
    return false;
}

// ---------------- 文件读写 ----------------

/// 读文件（不跨界、不分配）。返回实际读到的字节数。
pub fn readFile(ino: u32, off: u64, buf: []u8) usize {
    const in = readInode(ino) orelse return 0;
    if (off >= in.size) return 0;
    const n = @min(in.size - @as(u32, @intCast(off)), buf.len);
    var ib = in.ib;
    var nalloc: u32 = 0;
    var done: usize = 0;
    var pos = off;
    while (done < n) {
        const bi: u32 = @intCast(pos / block_size);
        const inoff: usize = @intCast(pos % block_size);
        const chunk = @min(block_size - inoff, n - done);
        const mr = mapFileBlock(&ib, bi, false, &nalloc) orelse break;
        const bp = blockPtr(mr.blk) orelse break;
        @memcpy(buf[done..done + chunk], bp[inoff..inoff + chunk]);
        done += chunk;
        pos += chunk;
    }
    return done;
}

/// 写文件：按需分配块（间接块含内），扩展 size。返回字节数或负 errno。
pub fn writeFile(ino: u32, off: u64, buf: []const u8) isize {
    if (off + buf.len > 0xFFFF_FFFF) return -27; // EFBIG
    var in = readInode(ino) orelse return -5; // EIO
    var nalloc: u32 = 0;
    var done: usize = 0;
    while (done < buf.len) {
        const bi: u32 = @intCast((off + done) / block_size);
        const inoff: usize = @intCast((off + done) % block_size);
        const chunk = @min(block_size - inoff, buf.len - done);
        const mr = mapFileBlock(&in.ib, bi, true, &nalloc) orelse {
            // 中途失败：把已分配的记账落盘（位图已写，i_blocks 必须跟上）
            in.nsec512 += 2 * nalloc;
            in.size = @max(in.size, @as(u32, @intCast(off + done)));
            _ = writeInode(ino, &in);
            return -5;
        };
        const bp = blockPtr(mr.blk) orelse return -5;
        @memcpy(bp[inoff..inoff + chunk], buf[done..done + chunk]);
        if (!flushBlock(mr.blk)) return -5;
        done += chunk;
    }
    in.size = @max(in.size, @as(u32, @intCast(off + buf.len)));
    in.nsec512 += 2 * nalloc;
    if (!writeInode(ino, &in)) return -5;
    return @intCast(buf.len);
}

// ---------------- 元数据与树操作 ----------------

pub const NodeStat = struct { mode: u32, uid: u32, gid: u32, size: u64, links: u32 };

pub fn statIno(ino: u32) ?NodeStat {
    const in = readInode(ino) orelse return null;
    return .{ .mode = in.mode, .uid = in.uid, .gid = in.gid, .size = in.size, .links = in.links };
}

pub fn setMode(ino: u32, mode: u32) bool {
    var in = readInode(ino) orelse return false;
    in.mode = @intCast((in.mode & 0o170000) | (mode & 0o7777)); // 类型位不动
    return writeInode(ino, &in);
}

pub fn setOwner(ino: u32, uid: u32, gid: u32) bool {
    var in = readInode(ino) orelse return false;
    in.uid = @intCast(uid & 0xFFFF);
    in.gid = @intCast(gid & 0xFFFF);
    return writeInode(ino, &in);
}

/// O_TRUNC：释放全部数据块，size 归零
pub fn truncate(ino: u32) bool {
    var in = readInode(ino) orelse return false;
    freeInodeData(&in);
    in.size = 0;
    in.nsec512 = 0;
    @memset(&in.ib, 0);
    return writeInode(ino, &in);
}

/// 创建普通文件（调用方保证父目录存在且有权限；存在同名条目返回 error）
pub fn create(dir: u32, name: []const u8, mode: u32, uid: u32, gid: u32) FsError!u32 {
    const ino = ialloc() orelse return error.NoSpace;
    var in = Inode{};
    in.mode = @intCast(0o100000 | (mode & 0o7777));
    in.uid = @intCast(uid & 0xFFFF);
    in.gid = @intCast(gid & 0xFFFF);
    in.links = 1;
    if (!writeInode(ino, &in)) return error.Io;
    if (!dirAdd(dir, name, ino, FT_REGULAR)) {
        ifree(ino); // 回滚
        return error.NoSpace;
    }
    return ino;
}

/// 创建目录：".." 令父目录 links+1；used_dirs 记账到子目录所在组
pub fn mkdir(dir: u32, name: []const u8, mode: u32, uid: u32, gid: u32) FsError!u32 {
    const ino = ialloc() orelse return error.NoSpace;
    var in = Inode{};
    in.mode = @intCast(0o040000 | (mode & 0o7777));
    in.uid = @intCast(uid & 0xFFFF);
    in.gid = @intCast(gid & 0xFFFF);
    in.links = 2; // "." + ".."
    if (!writeInode(ino, &in)) return error.Io;
    if (!dirAdd(dir, name, ino, FT_DIR)) {
        ifree(ino);
        return error.NoSpace;
    }
    if (!dirAdd(ino, ".", ino, FT_DIR) or !dirAdd(ino, "..", dir, FT_DIR)) {
        _ = dirRemove(dir, name);
        ifree(ino);
        return error.Io;
    }
    groups[(ino - 1) / inodes_per_group].used_dirs += 1;
    _ = writeGDs();
    var pin = readInode(dir) orelse return error.Io;
    pin.links += 1;
    if (!writeInode(dir, &pin)) return error.Io;
    return ino;
}

/// 删除文件（多链接则只减计数）
pub fn unlink(dir: u32, name: []const u8) RmError!void {
    const ino = dirLookup(dir, name) orelse return error.NotFound;
    var in = readInode(ino) orelse return error.Io;
    if (in.mode & 0o170000 == 0o040000) return error.NotDir;
    if (in.links > 1) {
        in.links -= 1;
        if (!writeInode(ino, &in)) return error.Io;
    } else {
        freeInodeData(&in);
        in.links = 0;
        in.size = 0;
        in.nsec512 = 0;
        in.dtime = nowSecs(); // e2fsck：删除的 inode 必须有 dtime
        @memset(&in.ib, 0);
        if (!writeInode(ino, &in)) return error.Io;
        ifree(ino);
    }
    if (!dirRemove(dir, name)) return error.Io;
}

/// 删除空目录（含 "." ".." 的清理与父目录 links--）
pub fn rmdir(dir: u32, name: []const u8) RmError!void {
    const ino = dirLookup(dir, name) orelse return error.NotFound;
    var in = readInode(ino) orelse return error.Io;
    if (in.mode & 0o170000 != 0o040000) return error.NotDir;
    if (!dirIsEmpty(ino)) return error.NotEmpty;
    freeInodeData(&in);
    in.links = 0;
    in.size = 0;
    in.nsec512 = 0;
    in.dtime = nowSecs();
    @memset(&in.ib, 0);
    if (!writeInode(ino, &in)) return error.Io;
    ifree(ino);
    if (!dirRemove(dir, name)) return error.Io;
    groups[(ino - 1) / inodes_per_group].used_dirs -= 1;
    _ = writeGDs();
    var pin = readInode(dir) orelse return error.Io;
    pin.links -= 1;
    if (!writeInode(dir, &pin)) return error.Io;
}

// ---------------- 路径与挂载 ----------------

/// 相对挂载点的路径查找（"a/b"；"" = 根）
pub fn lookupPath(rel: []const u8) ?u32 {
    if (!ready) return null;
    var cur: u32 = ROOT_INO;
    var start: usize = 0;
    while (start < rel.len) {
        var end = start;
        while (end < rel.len and rel[end] != '/') end += 1;
        const seg = rel[start..end];
        if (seg.len > 0) cur = dirLookup(cur, seg) orelse return null;
        start = end + 1;
    }
    return cur;
}

/// 挂载：读超级块 + 组描述符并做特性检查。调用前 ata.init() 必须已成功。
pub fn mount() bool {
    ready = false;
    if (!ata.readSectors(2, 2, &sb_buf)) {
        console.kprintf("ext2: cannot read superblock\n", .{});
        return false;
    }
    if (le16(sb_buf[0..], SB_MAGIC) != MAGIC) {
        console.kprintf("ext2: bad magic (not ext2)\n", .{});
        return false;
    }
    const log = le32(sb_buf[0..], SB_LOG_BSIZE);
    if (log > 2) {
        console.kprintf("ext2: unsupported block size log {d}\n", .{log});
        return false;
    }
    block_size = @as(u32, 1024) << @intCast(log);
    spb = block_size / 512;

    const incompat = le32(sb_buf[0..], SB_INCOMPAT);
    if (incompat & ~INCOMPAT_FILETYPE != 0) {
        console.kprintf("ext2: unsupported incompatible features {x}\n", .{incompat});
        return false;
    }
    has_filetype = incompat & INCOMPAT_FILETYPE != 0;

    const rev = le32(sb_buf[0..], SB_REV);
    if (rev >= 1) {
        inode_size = le16(sb_buf[0..], SB_INODE_SIZE);
        first_ino = le32(sb_buf[0..], SB_FIRST_INO);
        if (inode_size == 0) inode_size = 128;
        if (first_ino == 0) first_ino = 11;
    } else {
        inode_size = 128;
        first_ino = 11;
    }
    if (block_size % inode_size != 0) {
        console.kprintf("ext2: inode size {d} not supported\n", .{inode_size});
        return false; // 本实现要求 inode 不跨块
    }

    inodes_count = le32(sb_buf[0..], SB_INODES);
    blocks_count = le32(sb_buf[0..], SB_BLOCKS);
    blocks_per_group = le32(sb_buf[0..], SB_BPG);
    inodes_per_group = le32(sb_buf[0..], SB_IPG);
    free_blocks_ram = le32(sb_buf[0..], SB_FREE_BLOCKS);
    free_inodes_ram = le32(sb_buf[0..], SB_FREE_INODES);
    if (inodes_per_group == 0 or blocks_per_group == 0 or inodes_count == 0) return false;

    first_data_block = if (block_size == 1024) 1 else 0;
    gd_block = first_data_block + 1;
    group_count = (blocks_count - first_data_block + blocks_per_group - 1) / blocks_per_group;
    if (group_count == 0 or group_count > MAX_GROUPS) {
        console.kprintf("ext2: {d} groups exceeds support ({d})\n", .{ group_count, MAX_GROUPS });
        return false;
    }

    // 组描述符表（紧跟超级块所在块；32 组×32B=1KB，1KB 块恰好一块）
    const gd_bytes = group_count * 32;
    const gd_sectors: u8 = @intCast((gd_bytes + 511) / 512);
    if (!ata.readSectors(gd_block * spb, gd_sectors, &gd_buf)) {
        console.kprintf("ext2: cannot read group descriptors\n", .{});
        return false;
    }
    for (0..group_count) |g| {
        const o = g * 32;
        groups[g] = .{
            .block_bitmap = le32(gd_buf[0..], o + GD_BLOCK_BITMAP),
            .inode_bitmap = le32(gd_buf[0..], o + GD_INODE_BITMAP),
            .inode_table = le32(gd_buf[0..], o + GD_INODE_TABLE),
            .free_blocks = le16(gd_buf[0..], o + GD_FREE_BLOCKS),
            .free_inodes = le16(gd_buf[0..], o + GD_FREE_INODES),
            .used_dirs = le16(gd_buf[0..], o + GD_USED_DIRS),
        };
    }

    ready = true;
    console.kprintf("ext2: {d} blocks x {d}B, {d} group(s), {d} inodes ({d}B each), rev {d}{s}\n", .{
        blocks_count, block_size, group_count, inodes_count, inode_size, rev,
        if (has_filetype) ", filetype" else "",
    });
    console.kprintf("ext2: free {d}/{d} blocks, {d}/{d} inodes\n", .{
        free_blocks_ram, blocks_count, free_inodes_ram, inodes_count,
    });
    return true;
}

pub fn mounted() bool {
    return ready;
}

pub fn maxIno() u32 {
    return inodes_count;
}

pub fn rootIno() u32 {
    return ROOT_INO;
}

/// df 用的概要字符串
pub fn fsInfo(out: []u8, mp: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(
        out,
        "ext2 {s}: {d} blocks x {d}B ({d} free), {d} inodes ({d} free), {d} group(s)",
        .{ mp, blocks_count, block_size, free_blocks_ram, inodes_count, free_inodes_ram, group_count },
    ) catch null;
}

// ---------------- 小工具 ----------------

/// 当前墙钟（unix 秒）：读 CMOS RTC。用于 i_dtime（以后也可给 mtime 用）。
/// 日期→天数用 Howard Hinnant 的 days_from_civil 算法（公历，无闰年表）。
fn nowSecs() u32 {
    const serial = @import("serial.zig");
    const outb = serial.outb;
    const inb = serial.inb;
    // 等 UIP（更新进行中）清零再读，避免撕裂数据
    var spins: usize = 0;
    while (spins < 1_000_000) : (spins += 1) {
        outb(0x70, 0x0A);
        if (inb(0x71) & 0x80 == 0) break;
    }
    outb(0x70, 0x0B);
    const rb = inb(0x71);
    const bcd = rb & 0x04 == 0;
    const rd = struct {
        fn f(p: u8, is_bcd: bool) u32 {
            outb(0x70, p);
            const v = inb(0x71);
            if (!is_bcd) return v;
            return (v & 0x0F) + (v >> 4) * 10;
        }
    }.f;
    const sec = rd(0x00, bcd);
    const minute = rd(0x02, bcd);
    var hour = rd(0x04, bcd);
    const day = @max(rd(0x07, bcd), 1);
    const month = @max(rd(0x08, bcd), 1);
    var year = rd(0x09, bcd);
    const century = rd(0x32, bcd);
    if (rb & 0x02 == 0) { // 12 小时制：bit7 = PM
        const pm = hour & 0x80 != 0;
        hour &= 0x7F;
        if (pm and hour < 12) hour += 12;
        if (!pm and hour == 12) hour = 0;
    }
    year += century * 100;

    // days_from_civil(1970-01-01 = 0)
    var y: i64 = @intCast(year);
    const m: i64 = @intCast(month);
    const d: i64 = @intCast(day);
    if (m <= 2) y -= 1;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp = @mod(m + 9, 12); // [0, 11]
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;

    const secs = days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, sec);
    if (secs < 0) return 0;
    return @intCast(secs);
}

inline fn le16(b: []const u8, off: usize) u16 {
    return @as(u16, b[off]) | @as(u16, b[off + 1]) << 8;
}
inline fn le32(b: []const u8, off: usize) u32 {
    return @as(u32, b[off]) | @as(u32, b[off + 1]) << 8 |
        @as(u32, b[off + 2]) << 16 | @as(u32, b[off + 3]) << 24;
}
inline fn setLe16(b: []u8, off: usize, v: u16) void {
    b[off] = @truncate(v);
    b[off + 1] = @truncate(v >> 8);
}
inline fn setLe32(b: []u8, off: usize, v: u32) void {
    b[off] = @truncate(v);
    b[off + 1] = @truncate(v >> 8);
    b[off + 2] = @truncate(v >> 16);
    b[off + 3] = @truncate(v >> 24);
}
