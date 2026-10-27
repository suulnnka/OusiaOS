//! tarfs —— 内存盘文件系统：initrd(ustar) 导入 + 运行时可写（练习 5）
//!
//! 教学要点：
//!   - "文件系统 = 对一块内存的解释"。GRUB 把整块 tar 按原样装进物理
//!     内存，引导时解析头部建节点表——文件数据起初就躺在 initrd 里
//!     （零拷贝导入）；【写入时才把数据搬到自己分配的物理页】（写时
//!     拷贝的简化版：整个文件一份），此后该节点与 initrd 无关
//!   - 运行期支持 create/mkdir/unlink/rmdir 与随机位置写：新节点走
//!     空闲槽表复用；文件数据用 pmm 的连续帧分配（文件 ≤ 256KB，
//!     拼一段虚拟连续区间即可随机读写）
//!   - ustar 头部 512 字节：name/mode/size/typeflag...，数据紧跟其后
//!     按 512 对齐。typeflag: '0'=文件 '5'=目录
//!
//! tar 内路径约定：无前导 '/'，解析时统一去掉首尾斜杠后与规范化路径
//! 比较。unlink 一个 initrd 导入的文件 = 节点标 deleted（不释放 initrd
//! 内存——它属于引导镜像）；unlink 自己创建的文件 = 数据页一并归还。

const console = @import("console.zig");
const multiboot = @import("multiboot.zig");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");

const BLOCK = 512;
const MAX_NODES = 256;
/// 单文件上限 256KB（运行期创建/写入的文件）
pub const MAX_FILE: usize = 256 * 1024;

pub const NodeKind = enum { file, dir };

pub const Node = struct {
    kind: NodeKind = .file,
    /// 规范化路径（无首尾 '/'），如 "etc/motd"、"bin"
    path_buf: [128]u8 = undefined,
    path_len: usize = 0,
    size: u64 = 0,
    /// 文件数据：initrd 内存中的切片（未写过的导入文件），或本文件系
    /// 统自己分配的连续物理页（写过的/新建的文件）
    data: ?[]const u8 = null,
    /// data 是否为运行期分配的物理页（owned_frames > 0 = 是；释放时归还 pmm）
    owned_frames: usize = 0,
    data_phys: usize = 0,
    deleted: bool = false, // unlink 过的槽位（等待复用）

    // ---- Linux 风格权限（来自 ustar 头的 mode/uid/gid 字段）----
    /// st_mode：类型位(IFREG/IFDIR) + rwxrwxrwx 权限位
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,

    pub fn path(self: *const Node) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

var nodes: [MAX_NODES]Node = undefined;
var node_count: usize = 0; // 曾经用过的最大槽位（含已删除）
var free_list: [MAX_NODES]usize = undefined; // 删除后可复用的槽位
var free_count: usize = 0;

pub fn nodeCount() usize {
    return node_count;
}

/// 可见节点数（排查用）
pub fn liveCount() usize {
    var n: usize = 0;
    for (nodes[0..node_count]) |*nd| {
        if (!nd.deleted and nd.path_len > 0) n += 1;
    }
    return n;
}

pub fn getNode(i: usize) *const Node {
    return &nodes[i];
}

/// 可变节点（chmod/chown 改内存态权限、写入数据用）
pub fn getNodeMut(i: usize) *Node {
    return &nodes[i];
}

// ---------------- initrd 导入 ----------------

/// 解析 initrd（由 multiboot 模块加载的 tar 镜像）
pub fn init() bool {
    const start = multiboot.initrd_start;
    const end = multiboot.initrd_end;
    if (start == 0 or end <= start) {
        console.kprintf("tarfs: no initrd module (add 'module2 /boot/initrd.tar' to grub.cfg)\n", .{});
        return false;
    }
    const base = vmm.physToVirt(start);
    const total = end - start;

    var offset: usize = 0;
    while (offset + BLOCK <= total) {
        const hdr: [*]const u8 = @ptrFromInt(base + offset);
        if (hdr[0] == 0) break; // 全零块 = 归档结束

        // name[100]
        var name_len: usize = 0;
        while (name_len < 100 and hdr[name_len] != 0) name_len += 1;
        const name_raw = hdr[0..name_len];

        // size[12]：八进制字符串
        const size = parseOctal(hdr[124 .. 124 + 12]);
        const typeflag = hdr[156];
        // mode[8] / uid[8] / gid[8]：八进制（宿主 tar 的权限位原样携带——
        // mkinitrd.sh 里 chmod 755 bin/* 即成为文件系统的执行位）
        const raw_mode = parseOctal(hdr[100 .. 100 + 8]);
        const raw_uid = parseOctal(hdr[108 .. 108 + 8]);
        const raw_gid = parseOctal(hdr[116 .. 116 + 8]);

        if (node_count < MAX_NODES and name_len > 0) {
            const n = &nodes[node_count];
            n.* = .{};
            n.kind = if (typeflag == '5') .dir else .file;
            n.size = if (typeflag == '5') 0 else size;
            n.uid = @intCast(@min(raw_uid, 65535));
            n.gid = @intCast(@min(raw_gid, 65535));
            // 类型位按节点类型重写，权限位取 tar 值；缺省 644/755
            const perm: u32 = if (raw_mode & 0o777 != 0) @as(u32, @intCast(raw_mode & 0o777)) else (if (n.kind == .dir) @as(u32, 0o755) else @as(u32, 0o644));
            const type_bits: u32 = if (n.kind == .dir) 0o040000 else 0o100000;
            n.mode = type_bits | perm;

            // 规范化：去掉 "./" 前缀、首 '/'、尾 '/'
            var s: usize = 0;
            var e: usize = name_len;
            if (name_len >= 2 and name_raw[0] == '.' and name_raw[1] == '/') s = 2;
            if (e > s and name_raw[e - 1] == '/') e -= 1;
            var copied: usize = 0;
            while (s < e and copied < n.path_buf.len - 1) : (s += 1) {
                n.path_buf[copied] = name_raw[s];
                copied += 1;
            }
            n.path_len = copied;

            if (n.path_len > 0 and n.kind == .file) {
                n.data = @as([*]const u8, @ptrFromInt(base + offset + BLOCK))[0..@intCast(size)];
            }
            if (n.path_len > 0) node_count += 1;
        }

        // 跳过 头部+数据（向上取整到 512）
        const data_blocks = (size + BLOCK - 1) / BLOCK;
        offset += BLOCK + data_blocks * BLOCK;
    }

    console.kprintf("tarfs: initrd [{x},{x}) {d}KB, {d} entries (writable)\n", .{
        start, end, (end - start) / 1024, node_count,
    });
    return true;
}

fn parseOctal(field: []const u8) u64 {
    var v: u64 = 0;
    for (field) |c| {
        if (c < '0' or c > '7') break;
        v = v * 8 + (c - '0');
    }
    return v;
}

// ---------------- 运行期：节点分配/回收 ----------------

fn allocSlot() ?usize {
    if (free_count > 0) {
        free_count -= 1;
        return free_list[free_count];
    }
    if (node_count < MAX_NODES) {
        const i = node_count;
        node_count += 1;
        return i;
    }
    return null;
}

/// 槽位是否空闲可复用（deleted 或从未填充）
fn slotFree(i: usize) bool {
    return i >= node_count or nodes[i].deleted or nodes[i].path_len == 0;
}

fn releaseSlot(i: usize) void {
    const n = &nodes[i];
    if (n.owned_frames > 0) {
        for (0..n.owned_frames) |k| pmm.freeFrame(n.data_phys + k * 4096);
    }
    n.* = .{ .deleted = true, .path_len = 0 };
    if (free_count < free_list.len) {
        free_list[free_count] = i;
        free_count += 1;
    }
}

// ---------------- 查找 ----------------

/// 按规范化路径精确查找（跳过已删除节点）
pub fn lookup(norm_path: []const u8) ?usize {
    if (norm_path.len == 0) return null;
    for (0..node_count) |i| {
        const n = &nodes[i];
        if (n.deleted or n.path_len == 0) continue;
        if (stdEql(n.path(), norm_path)) return i;
    }
    return null;
}

// ---------------- 创建/删除 ----------------

fn setPath(n: *Node, dir_norm: []const u8, name: []const u8) bool {
    // 拼规范化路径：dir 为空 = 根下的条目
    var len: usize = 0;
    if (dir_norm.len > 0) {
        if (dir_norm.len + 1 + name.len + 1 > n.path_buf.len) return false;
        @memcpy(n.path_buf[0..dir_norm.len], dir_norm);
        len = dir_norm.len;
        n.path_buf[len] = '/';
        len += 1;
    } else if (name.len + 1 > n.path_buf.len) {
        return false;
    }
    @memcpy(n.path_buf[len .. len + name.len], name);
    n.path_len = len + name.len;
    return true;
}

/// 在目录 dir_norm（"" = 根）下创建文件。已存在返回 null（由调用方报 EEXIST）。
pub fn createFile(dir_norm: []const u8, name: []const u8, perm: u32) ?usize {
    return createNode(dir_norm, name, .file, perm);
}

/// 在目录 dir_norm（"" = 根）下创建目录
pub fn createDir(dir_norm: []const u8, name: []const u8, perm: u32) ?usize {
    return createNode(dir_norm, name, .dir, perm);
}

fn createNode(dir_norm: []const u8, name: []const u8, kind: NodeKind, perm: u32) ?usize {
    if (name.len == 0) return null;
    // 先拼出完整路径查重（顺序不能反：先占槽再查的话，lookup 会
    // 看到刚填好的自己——永远"已存在"，创建永远失败）
    var pbuf: [160]u8 = undefined;
    var plen: usize = 0;
    if (dir_norm.len > 0) {
        if (dir_norm.len + 1 + name.len > pbuf.len) return null;
        @memcpy(pbuf[0..dir_norm.len], dir_norm);
        plen = dir_norm.len;
        pbuf[plen] = '/';
        plen += 1;
    } else if (name.len > pbuf.len) {
        return null;
    }
    @memcpy(pbuf[plen .. plen + name.len], name);
    plen += name.len;
    if (lookup(pbuf[0..plen]) != null) return null; // 已存在（调用方报 EEXIST）

    const i = allocSlot() orelse return null;
    const n = &nodes[i];
    n.* = .{};
    if (!setPath(n, dir_norm, name)) {
        n.path_len = 0;
        return null;
    }
    n.kind = kind;
    if (kind == .dir) {
        n.mode = 0o040000 | (perm & 0o777) | 0o111; // 目录至少要有 x
    } else {
        n.mode = 0o100000 | (perm & 0o777);
    }
    return i;
}

/// 删除节点（文件或空目录——空检查由调用方做）。返回是否删除成功。
pub fn removeNode(i: usize) bool {
    if (i >= node_count) return false;
    const n = &nodes[i];
    if (n.deleted or n.path_len == 0) return false;
    releaseSlot(i);
    return true;
}

/// 目录是否为空（不含 "." ".."——本 FS 不生成它们）
pub fn dirIsEmpty(i: usize) bool {
    const n = getNode(i);
    if (n.kind != .dir) return false;
    var it = childIter(n.path());
    return it.nextChild() == null;
}

// ---------------- 写入 ----------------

/// 保证节点数据在【自己分配的连续物理页】里，且容量 ≥ need_end 字节。
/// 迁移时把旧内容拷过去（initrd 导入 → 首次写 = 写时拷贝）。
fn ensureOwned(n: *Node, need_end: usize) bool {
    const need_pages = (need_end + 4095) / 4096;
    if (n.owned_frames >= need_pages) {
        // 容量已够：只需把 data 切片拉长到覆盖本次写入
        //（切片长度跟随 size，容量在页里——不拉长的话 buf[0..end] 越界）
        const buf: [*]u8 = @ptrFromInt(vmm.physToVirt(n.data_phys));
        n.data = buf[0..@max(n.size, need_end)];
        return true;
    }

    const new_phys = pmm.allocContigFrames(need_pages) orelse return false;
    const dst: [*]u8 = @ptrFromInt(vmm.physToVirt(new_phys));
    @memset(dst[0 .. need_pages * 4096], 0);
    if (n.data) |old| @memcpy(dst[0..old.len], old);
    if (n.owned_frames > 0) {
        for (0..n.owned_frames) |k| pmm.freeFrame(n.data_phys + k * 4096);
    }
    n.data_phys = new_phys;
    n.owned_frames = need_pages;
    n.data = dst[0..@max(n.size, need_end)];
    return true;
}

/// 随机位置写。返回写入字节数或负 errno（EFBIG=-27 ENOSPC=-28）。
pub fn writeNode(i: usize, pos: u64, bytes: []const u8) isize {
    if (i >= node_count) return -9; // EBADF
    const n = &nodes[i];
    if (n.deleted or n.kind != .file) return -21; // EISDIR
    if (pos > MAX_FILE or bytes.len > MAX_FILE or pos + bytes.len > MAX_FILE) return -27; // EFBIG
    const end: usize = @intCast(pos + bytes.len);
    if (!ensureOwned(n, end)) return -28; // ENOSPC
    const buf: []u8 = @constCast(n.data.?);
    @memcpy(buf[@intCast(pos)..end], bytes);
    if (end > n.size) {
        n.size = end;
        n.data = buf[0..end];
    }
    return @intCast(bytes.len);
}

/// O_TRUNC：清空文件（保留运行期已分配的容量）
pub fn truncateNode(i: usize) void {
    if (i >= node_count) return;
    const n = &nodes[i];
    if (n.kind != .file) return;
    n.size = 0;
    if (n.owned_frames > 0) {
        const buf: [*]u8 = @ptrFromInt(vmm.physToVirt(n.data_phys));
        n.data = buf[0..0];
    } else {
        n.data = null;
    }
}

// ---------------- 目录遍历 ----------------

/// 列出目录下的直接孩子（name 为孩子名，不含路径前缀）
pub const Child = struct {
    node: usize,
    name: []const u8,
};

pub const ChildIter = struct {
    prefix_buf: [160]u8 = undefined,
    prefix_len: usize = 0,
    dir_idx: usize = 0,
    next: usize = 0,

    pub fn nextChild(self: *ChildIter) ?Child {
        while (self.next < node_count) {
            const idx = self.next;
            self.next += 1; // 先推进，返回后不会重复处理同一节点
            const n = &nodes[idx];
            if (n.deleted or n.path_len == 0) continue; // 已删除/空槽
            if (n.path_len <= self.prefix_len) continue;
            if (self.prefix_len > 0 and !stdStartsWith(n.path(), self.prefix_buf[0..self.prefix_len])) continue;

            const rest = n.path()[self.prefix_len..];
            // 直接孩子：剩余部分不含 '/'（目录条目本身就是孩子）
            const slash = stdIndexOf(rest, '/');
            if (slash) |sl| {
                // 是更深的后代；如果 rest 在 sl 处结束（如 "bin/"），它就是目录本身
                if (sl + 1 == rest.len) {
                    return .{ .node = idx, .name = rest[0..sl] };
                }
                continue;
            }
            return .{ .node = idx, .name = rest };
        }
        return null;
    }
};

pub fn childIter(dir_norm_path: []const u8) ChildIter {
    var it = ChildIter{ .dir_idx = 0 };
    var pl: usize = 0;
    if (dir_norm_path.len > 0) {
        @memcpy(it.prefix_buf[0..dir_norm_path.len], dir_norm_path);
        it.prefix_buf[dir_norm_path.len] = '/';
        pl = dir_norm_path.len + 1;
    }
    it.prefix_len = pl;
    return it;
}

// ---- 极简字符串工具（内核里避免引入 std.mem 的开销与依赖）----
pub fn stdEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn stdStartsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return stdEql(s[0..prefix.len], prefix);
}

fn stdIndexOf(s: []const u8, c: u8) ?usize {
    for (s, 0..) |x, i| {
        if (x == c) return i;
    }
    return null;
}
