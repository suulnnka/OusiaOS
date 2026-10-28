//! VFS —— 虚拟文件系统：路径解析 + 挂载表 + 设备抽象
//!
//! 教学要点：
//!   - Unix 的伟大发明："一切皆文件"。read(/dev/console) 与 read(/bin/sh)
//!     走同一个接口，背后一个是字符设备、一个真磁盘上的 ext2
//!   - 路径解析 namei：相对路径基于进程 cwd，逐段消解 "." 与 ".."
//!   - 挂载（mount）：把文件系统的根"嫁接"到名字树上。OusiaOS 0.3 起
//!     ext2 整体作为根文件系统（mountExt2("/")）：/bin /etc 全在盘上；
//!     无盘时回退 initrd tarfs（保留作教学对照）
//!   - ext2 是工业格式：mke2fs 可做盘、debugfs/e2fsck 可检查、掉电不丢
//!
//! 节点编号（vfs 层的统一句柄）：
//!   0            /        （虚拟根目录；ext2 根挂载时信息/列表透传给 ext2）
//!   1            /dev/console（字符设备，内核特判）
//!   2..2+N-1     tarfs 节点（仅无盘兜底模式）
//!   1024+ino     ext2 节点（ino = ext2 inode 号）

const std = @import("std");
const tarfs = @import("tarfs.zig");
const ext2 = @import("ext2.zig");
const console = @import("console.zig");
const tty = @import("tty.zig");

pub const ROOT_NODE: usize = 0;
pub const CONSOLE_NODE: usize = 1;
const TARFS_BASE: usize = 2;
pub const EXT2_BASE: usize = 1024;
/// sock 节点段（远程会话的 fd 指向这里；SOCK_BASE+conn 编号）。
/// 段起点避开 tarfs（≤258）与 ext2（≤1024+maxIno≈25.6k）。
pub const SOCK_BASE: usize = 60000;
pub const SOCK_MAX: usize = 4;

pub fn isSock(node: usize) bool {
    return node >= SOCK_BASE and node < SOCK_BASE + SOCK_MAX;
}

pub fn init() void {
    // tarfs.init() 已在 main 里填充节点表；本模块无需额外初始化
}

// ---------------- 挂载表（教学简化：单一 ext2） ----------------

var mp_buf: [64]u8 = undefined;
var mp_len: usize = 0; // 0 = 根挂载（mountExt2("/")）或未挂载，看 root_mounted
var root_mounted = false;

/// 挂载 ext2。mp="/"：整体作为根文件系统（0.3 起的形态）；
/// mp="/mnt"：嫁接到名字树某节点（旧的双文件系统演示形态）。
/// 要求 ext2.mount() 已成功。
pub fn mountExt2(mp: []const u8) bool {
    if (!ext2.mounted()) return false;
    if (eqStr(mp, "/")) {
        mp_len = 0;
        root_mounted = true;
        return true;
    }
    if (mp.len == 0 or mp.len + 1 > mp_buf.len) return false;
    // 规范化：去掉首尾 '/'；教学简化只支持单段挂载点（"mnt"）
    var s: usize = 0;
    var e: usize = mp.len;
    if (mp[0] == '/') s = 1;
    if (e > s and mp[e - 1] == '/') e -= 1;
    if (e <= s) return false;
    for (mp[s..e]) |c| {
        if (c == '/') return false;
    }
    @memcpy(mp_buf[0 .. e - s], mp[s..e]);
    mp_len = e - s;
    root_mounted = false;
    return true;
}

/// 规范化绝对路径与挂载点做前缀匹配。
/// 命中返回挂载点之下的相对路径（"" 表示挂载点本身），未命中 null。
/// 根挂载时任何路径都命中（整个名字树都归 ext2）。
fn mountMatch(norm: []const u8) ?[]const u8 {
    if (norm.len < 1 or norm[0] != '/') return null;
    if (root_mounted) return norm[1..];
    if (mp_len == 0) return null;
    const mp = mp_buf[0..mp_len];
    const rest = norm[1..];
    if (rest.len == mp.len and eqStr(rest, mp)) return "";
    if (rest.len > mp.len + 1 and eqStr(rest[0..mp.len], mp) and rest[mp.len] == '/')
        return rest[mp.len + 1 ..];
    return null;
}

pub fn ext2Mounted() bool {
    return ext2.mounted() and (root_mounted or mp_len > 0);
}

/// ext2 是否为根文件系统
pub fn ext2IsRoot() bool {
    return root_mounted and ext2.mounted();
}

/// 节点是否属于 ext2
pub fn isExt2(node: usize) bool {
    return ext2.mounted() and node >= EXT2_BASE and node - EXT2_BASE < ext2.maxIno();
}

pub const NodeInfo = struct {
    is_dir: bool,
    is_console: bool,
    size: u64,
    /// fstat 的 st_mode: S_IFREG=0100000 S_IFDIR=0040000 S_IFCHR=0020000
    /// 权限位 rwxrwxrwx 与 Linux 一致
    mode: u32,
    uid: u32 = 0,
    gid: u32 = 0,
};

// ---------------- Linux 风格权限检查 ----------------
//
// 规则与 Unix 相同：root(uid 0) 旁路一切；否则按 owner/group/other
// 三元组取一组判断。r/w 在 open 时查，x 在路径遍历（进入目录）与
// execve 时查。

pub const Access = enum { r, w, x };

fn permBit(a: Access) u32 {
    return switch (a) {
        .r => 4,
        .w => 2,
        .x => 1,
    };
}

/// uid/gid 是否对 node 拥有 want 权限
pub fn mayAccess(ni: NodeInfo, uid: u32, gid: u32, want: Access) bool {
    if (uid == 0) return true; // root 旁路
    const perm = ni.mode & 0o777;
    const shift: u5 = if (uid == ni.uid)
        6 // owner
    else if (gid == ni.gid)
        3 // group
    else
        0; // other
    return (perm >> shift) & permBit(want) != 0;
}

pub const ResolveError = error{ NoEnt, Access };

/// 带凭证的路径解析：逐级检查目录的 x 位（Linux 的 namei 行为）。
/// 内核自身用 resolve()（root 旁路）。
pub fn resolveCred(path: []const u8, cwd: []const u8, uid: u32, gid: u32) ResolveError!usize {
    var buf: [256]u8 = undefined;
    const n = normalizePath(path, cwd, &buf) orelse return error.NoEnt;
    const norm = buf[0..n];

    // 逐段检查祖先目录的 x 位（"a/b/c" 检查 a、a/b）。每个前缀做完整
    // resolve（挂载感知）——"mnt/x" 的前缀 "mnt" 会落到 ext2 的根上
    var seg_end: usize = 1;
    while (seg_end < norm.len) : (seg_end += 1) {
        if (norm[seg_end] == '/') {
            const dir = resolve(norm[0..seg_end], "/") orelse return error.NoEnt;
            if (!mayAccess(nodeInfoOf(dir), uid, gid, .x)) return error.Access;
        }
    }
    return resolve(norm, "/") orelse return error.NoEnt;
}

fn nodeInfoOf(node: usize) NodeInfo {
    return info(node);
}

/// 规范化路径：合并 cwd（若相对路径）、消解 "." 与 ".."，输出到 out。
/// 返回规范路径的字节数（"/a/b" 形式，根为 "/"）。超长返回 null。
pub fn normalizePath(path: []const u8, cwd: []const u8, out: *[256]u8) ?usize {
    if (path.len == 0) return null;

    var len: usize = 0;
    if (path[0] == '/') {
        out[0] = '/';
        len = 1;
    } else {
        if (cwd.len == 0 or cwd[0] != '/') return null;
        if (cwd.len + 1 > out.len) return null;
        @memcpy(out[0..cwd.len], cwd);
        len = cwd.len;
        if (len > 1 and out[len - 1] == '/') len -= 1; // cwd 去掉尾 '/'
        if (len == 0) {
            out[0] = '/';
            len = 1;
        }
    }

    var it = SegmentIterator{ .s = path };
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (seg.len == 1 and seg[0] == '.') continue;
        if (seg.len == 2 and seg[0] == '.' and seg[1] == '.') {
            if (len > 1) {
                len -= 1; // 去掉结尾的段内容或 '/'
                while (len > 1 and out[len - 1] != '/') len -= 1;
            }
            continue;
        }
        // 追加段（非根时先补 '/'）
        const need = if (len > 1) seg.len + 1 else seg.len;
        if (len + need + 1 > out.len) return null;
        if (len > 1) {
            out[len] = '/';
            len += 1;
        }
        @memcpy(out[len .. len + seg.len], seg);
        len += seg.len;
    }

    return len;
}

const SegmentIterator = struct {
    s: []const u8,
    pos: usize = 0,

    fn next(self: *SegmentIterator) ?[]const u8 {
        if (self.pos >= self.s.len) return null;
        const start = self.pos;
        while (self.pos < self.s.len and self.s[self.pos] != '/') self.pos += 1;
        const seg = self.s[start..self.pos];
        self.pos += 1; // 跳过 '/'
        return seg;
    }
};

/// 解析路径 → vfs 节点号。失败返回 null。
pub fn resolve(path: []const u8, cwd: []const u8) ?usize {
    var buf: [256]u8 = undefined;
    const n = normalizePath(path, cwd, &buf) orelse return null;
    const norm = buf[0..n];

    if (norm.len == 1 and norm[0] == '/') return ROOT_NODE;
    if (eqStr(norm, "/dev/console")) return CONSOLE_NODE;

    // 挂载点前缀匹配优先：/mnt 与 /mnt/** 归 ext2（"嫁接"到名字树上）
    if (mountMatch(norm)) |rel| {
        const ino = ext2.lookupPath(rel) orelse return null;
        return EXT2_BASE + ino;
    }

    if (tarfs.lookup(norm[1..])) |i| return TARFS_BASE + i;
    return null;
}

pub fn info(node: usize) NodeInfo {
    if (node == ROOT_NODE) {
        // ext2 根挂载：根目录就是 ext2 的根（mode/uid 来自盘上 inode）
        if (ext2IsRoot()) {
            if (ext2.statIno(ext2.rootIno())) |st| {
                return .{
                    .is_dir = true,
                    .is_console = false,
                    .size = st.size,
                    .mode = st.mode,
                    .uid = st.uid,
                    .gid = st.gid,
                };
            }
        }
        return .{ .is_dir = true, .is_console = false, .size = 0, .mode = 0o040755, .uid = 0, .gid = 0 };
    }
    if (node == CONSOLE_NODE) {
        return .{ .is_dir = false, .is_console = true, .size = 0, .mode = 0o020600, .uid = 0, .gid = 0 };
    }
    if (isSock(node)) {
        // 远程会话端点：字符设备语义（size 0；root 使用，权限放行）
        return .{ .is_dir = false, .is_console = false, .size = 0, .mode = 0o020600, .uid = 0, .gid = 0 };
    }
    if (isExt2(node)) {
        // ext2 的 mode 字段与 Linux 同款（类型位 + rwxrwxrwx），直接透传
        const st = ext2.statIno(@intCast(node - EXT2_BASE)) orelse
            return .{ .is_dir = false, .is_console = false, .size = 0, .mode = 0, .uid = 0, .gid = 0 };
        return .{
            .is_dir = st.mode & 0o170000 == 0o040000,
            .is_console = false,
            .size = st.size,
            .mode = st.mode,
            .uid = st.uid,
            .gid = st.gid,
        };
    }
    const n = tarfs.getNode(node - TARFS_BASE);
    return .{
        .is_dir = n.kind == .dir,
        .is_console = false,
        .size = n.size,
        .mode = n.mode,
        .uid = n.uid,
        .gid = n.gid,
    };
}

/// 可变节点访问（chmod/chown 修改内存态权限——tarfs 只读指数据不落盘，
/// 权限位是内核 RAM 里的副本）
pub fn nodeMut(node: usize) ?*tarfs.Node {
    if (node < TARFS_BASE or node >= TARFS_BASE + tarfs.nodeCount()) return null;
    return tarfs.getNodeMut(node - TARFS_BASE);
}

/// 读文件/console（console 阻塞按行读）。返回读到的字节数，负值表示错误。
pub fn read(node: usize, pos: u64, buf: []u8) isize {
    switch (node) {
        ROOT_NODE => return -21, // EISDIR
        CONSOLE_NODE => return @intCast(tty.read(buf)),
        else => {},
    }
    if (isExt2(node)) {
        return @intCast(ext2.readFile(@intCast(node - EXT2_BASE), pos, buf));
    }
    if (node < TARFS_BASE or node >= TARFS_BASE + tarfs.nodeCount()) return -9; // EBADF
    const n = tarfs.getNode(node - TARFS_BASE);
    if (n.kind != .file) return -21; // EISDIR
    const p: usize = @intCast(pos);
    if (p >= n.size) return 0; // EOF
    const want: usize = @intCast(@min(n.size - p, buf.len));
    @memcpy(buf[0..want], n.data.?[p .. p + want]);
    return @intCast(want);
}

/// 写 console/文件（tarfs：RAM 副本；ext2：真磁盘落盘）。
/// 返回写入字节数，负值表示错误。
pub fn write(node: usize, pos: u64, buf: []const u8) isize {
    if (node == CONSOLE_NODE) {
        console.writeStr(buf);
        return @intCast(buf.len);
    }
    if (node == ROOT_NODE) return -21;
    if (isExt2(node)) {
        return ext2.writeFile(@intCast(node - EXT2_BASE), pos, buf);
    }
    if (node < TARFS_BASE or node >= TARFS_BASE + tarfs.nodeCount()) return -9;
    return tarfs.writeNode(node - TARFS_BASE, pos, buf);
}

// ---------------- 运行期目录操作（tarfs RAM 版 + ext2 磁盘版） ----------------

pub const NameError = error{ NoEnt, NotDir, Access, Exist, NotEmpty, BadName, NoSpace, Io };

/// 把规范化路径拆成 [父目录规范化路径(无尾'/'), 末段名字]。
/// "/" 或非法路径返回错误。
fn splitParent(norm: []const u8) ?struct { dir: []const u8, name: []const u8 } {
    if (norm.len < 2 or norm[0] != '/') return null; // 至少 "/x"
    const cut = std.mem.lastIndexOfScalar(u8, norm, '/') orelse return null;
    if (cut == 0) {
        // "/name" → 父 = 根（dir 为 "" 约定）
        return .{ .dir = "", .name = norm[1..] };
    }
    return .{ .dir = norm[1..cut], .name = norm[cut + 1 ..] };
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (c == '/' or c == 0) return false;
    }
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return true;
}

/// 父目录节点号（"" → 根）。要求存在且是目录，并对凭证有 w 权限。
fn parentForWrite(dir_norm: []const u8, uid: u32, gid: u32) NameError!usize {
    var parent: usize = ROOT_NODE;
    if (dir_norm.len > 0) {
        const idx = tarfs.lookup(dir_norm) orelse return error.NoEnt;
        parent = TARFS_BASE + idx;
    }
    const inf = info(parent);
    if (!inf.is_dir) return error.NotDir;
    if (!mayAccess(inf, uid, gid, .w)) return error.Access;
    return parent;
}

/// mkdir(path, perm)：创建目录。挂载点之下走 ext2（落盘），否则 tarfs（RAM）
pub fn mkdir(path: []const u8, cwd: []const u8, perm: u32, uid: u32, gid: u32) NameError!void {
    var buf: [256]u8 = undefined;
    const n = normalizePath(path, cwd, &buf) orelse return error.BadName;
    const norm = buf[0..n];
    if (mountMatch(norm)) |rel| return ext2MkdirRel(rel, perm, uid, gid);
    if (resolve(norm, "/") != null) return error.Exist;
    const sp = splitParent(norm) orelse return error.BadName;
    if (!validName(sp.name)) return error.BadName;
    _ = try parentForWrite(sp.dir, uid, gid);
    if (tarfs.createDir(sp.dir, sp.name, perm) == null) return error.NoSpace;
}

/// rmdir(path)：只删空目录
pub fn rmdir(path: []const u8, cwd: []const u8, uid: u32, gid: u32) NameError!void {
    {
        var nb: [256]u8 = undefined;
        if (normalizePath(path, cwd, &nb)) |n| {
            if (mountMatch(nb[0..n])) |rel| return ext2RmdirRel(rel, uid, gid);
        }
    }
    const node = try resolveForWrite(path, cwd, uid, gid);
    const inf = info(node);
    if (node == ROOT_NODE) return error.Exist; // 根不可删
    if (!inf.is_dir) return error.NotDir;
    const idx = node - TARFS_BASE;
    if (!tarfs.dirIsEmpty(idx)) return error.NotEmpty;
    _ = tarfs.removeNode(idx);
}

/// unlink(path)：删除普通文件
pub fn unlink(path: []const u8, cwd: []const u8, uid: u32, gid: u32) NameError!void {
    {
        var nb: [256]u8 = undefined;
        if (normalizePath(path, cwd, &nb)) |n| {
            if (mountMatch(nb[0..n])) |rel| return ext2UnlinkRel(rel, uid, gid);
        }
    }
    const node = try resolveForWrite(path, cwd, uid, gid);
    const inf = info(node);
    if (inf.is_dir) return error.NotDir; // 删目录请用 rmdir
    const idx = node - TARFS_BASE;
    const inf_parent_for_owner = inf;
    // 只有 owner/root 能删（目录 sticky 位语义从简）
    if (uid != 0 and uid != inf_parent_for_owner.uid) return error.Access;
    _ = tarfs.removeNode(idx);
}

/// 解析路径并检查父目录链的 x 权限（删除/写打开都要先能走到它）
fn resolveForWrite(path: []const u8, cwd: []const u8, uid: u32, gid: u32) NameError!usize {
    return resolveCred(path, cwd, uid, gid) catch |e| switch (e) {
        error.Access => return error.Access,
        error.NoEnt => return error.NoEnt,
    };
}

/// open 的 O_CREAT 后半段：文件不存在时创建。返回新节点号。
/// （父目录存在性与 w 权限在此检查；挂载点之下走 ext2）
pub fn createFile(norm: []const u8, perm: u32, uid: u32, gid: u32) NameError!usize {
    if (mountMatch(norm)) |rel| return ext2CreateRel(rel, perm, uid, gid);
    const sp = splitParent(norm) orelse return error.BadName;
    if (!validName(sp.name)) return error.BadName;
    _ = try parentForWrite(sp.dir, uid, gid);
    const idx = tarfs.createFile(sp.dir, sp.name, perm) orelse return error.NoSpace;
    return TARFS_BASE + idx;
}

// ---------------- ext2 挂载树内的写操作 ----------------
//
// 输入都是"挂载点之下的相对路径"（"" = 挂载点根）。权限检查与 tarfs
// 分支共用 mayAccess；错误语义与 tarfs 分支对齐（如 unlink 目录报 NotDir）。

/// 拆出 ext2 父目录 inode 与末段名字（name 借用 rel 的内存，同步使用）
fn ext2ParentOf(rel: []const u8) ?struct { dir: u32, name: []const u8 } {
    var last: ?usize = null;
    for (rel, 0..) |c, i| {
        if (c == '/') last = i;
    }
    const name = if (last) |l| rel[l + 1 ..] else rel;
    const parent_rel = if (last) |l| rel[0..l] else "";
    const dir = ext2.lookupPath(parent_rel) orelse return null;
    return .{ .dir = dir, .name = name };
}

fn ext2CheckName(name: []const u8) NameError!void {
    if (name.len == 0 or name.len > 255) return error.BadName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.Exist;
}

/// 目录的 w+x 权限（创建/删除都要：目录写权限隐含可进）
fn ext2DirPerm(dir_ino: u32, uid: u32, gid: u32) NameError!void {
    const st = ext2.statIno(dir_ino) orelse return error.NoEnt;
    if (st.mode & 0o170000 != 0o040000) return error.NotDir;
    const ni = NodeInfo{ .is_dir = true, .is_console = false, .size = st.size, .mode = st.mode, .uid = st.uid, .gid = st.gid };
    if (!mayAccess(ni, uid, gid, .x) or !mayAccess(ni, uid, gid, .w)) return error.Access;
}

fn ext2CreateRel(rel: []const u8, perm: u32, uid: u32, gid: u32) NameError!usize {
    if (rel.len == 0) return error.Exist; // 目标是挂载点本身
    const t = ext2ParentOf(rel) orelse return error.NoEnt;
    try ext2CheckName(t.name);
    try ext2DirPerm(t.dir, uid, gid);
    if (ext2.lookupPath(rel)) |existing| return EXT2_BASE + existing;
    const ino = ext2.create(t.dir, t.name, perm, uid, gid) catch |e| switch (e) {
        error.NoSpace => return error.NoSpace,
        error.Io => return error.Io,
    };
    return EXT2_BASE + ino;
}

fn ext2MkdirRel(rel: []const u8, perm: u32, uid: u32, gid: u32) NameError!void {
    if (rel.len == 0) return error.Exist;
    const t = ext2ParentOf(rel) orelse return error.NoEnt;
    try ext2CheckName(t.name);
    try ext2DirPerm(t.dir, uid, gid);
    if (ext2.lookupPath(rel) != null) return error.Exist;
    _ = ext2.mkdir(t.dir, t.name, perm, uid, gid) catch |e| switch (e) {
        error.NoSpace => return error.NoSpace,
        error.Io => return error.Io,
    };
}

fn ext2RmdirRel(rel: []const u8, uid: u32, gid: u32) NameError!void {
    if (rel.len == 0) return error.Access; // 挂载点本身不可删
    const t = ext2ParentOf(rel) orelse return error.NoEnt;
    try ext2DirPerm(t.dir, uid, gid);
    ext2.rmdir(t.dir, t.name) catch |e| switch (e) {
        error.NotFound => return error.NoEnt,
        error.NotDir => return error.NotDir,
        error.NotEmpty => return error.NotEmpty,
        error.Io => return error.Io,
    };
}

fn ext2UnlinkRel(rel: []const u8, uid: u32, gid: u32) NameError!void {
    if (rel.len == 0) return error.NotDir; // 挂载点是目录
    const t = ext2ParentOf(rel) orelse return error.NoEnt;
    try ext2DirPerm(t.dir, uid, gid);
    ext2.unlink(t.dir, t.name) catch |e| switch (e) {
        error.NotFound => return error.NoEnt,
        error.NotDir => return error.NotDir,
        error.NotEmpty => return error.NotEmpty,
        error.Io => return error.Io,
    };
}

/// O_TRUNC 的 ext2 分支（sysOpen 调用；tarfs 节点无效果）
pub fn ext2TruncateNode(node: usize) void {
    if (isExt2(node)) _ = ext2.truncate(@intCast(node - EXT2_BASE));
}

/// chmod 落盘（ext2 节点返回 true；tarfs 节点由调用方走 nodeMut）
pub fn ext2SetMode(node: usize, mode: u32) bool {
    if (!isExt2(node)) return false;
    return ext2.setMode(@intCast(node - EXT2_BASE), mode);
}

/// chown 落盘
pub fn ext2SetOwner(node: usize, uid: u32, gid: u32) bool {
    if (!isExt2(node)) return false;
    return ext2.setOwner(@intCast(node - EXT2_BASE), uid, gid);
}

/// df 用的 ext2 概要（未挂载返回 null）
pub fn ext2Info(out: []u8) ?[]const u8 {
    if (!ext2Mounted()) return null;
    var mp: [65]u8 = undefined;
    mp[0] = '/';
    @memcpy(mp[1 .. 1 + mp_len], mp_buf[0..mp_len]);
    return ext2.fsInfo(out, mp[0 .. 1 + mp_len]);
}

/// 遍历目录孩子。根目录额外报告挂载点（挂载点在名字树上"虚拟存在"——
/// tarfs 里不需要真的有个 mnt 目录）
pub fn listDir(node: usize, ctx: anytype, cb: fn (@TypeOf(ctx), name: []const u8, child_node: usize) void) void {
    if (node == ROOT_NODE) {
        // ext2 根挂载：根目录列表 = ext2 根的直接孩子
        if (ext2IsRoot()) {
            ext2.listIno(ext2.rootIno(), EXT2_BASE, ctx, cb);
            return;
        }
        // 嫁接挂载形态：先报挂载点名（挂载点在名字树上"虚拟存在"）
        if (ext2Mounted()) cb(ctx, mp_buf[0..mp_len], EXT2_BASE + ext2.rootIno());
        var it0 = tarfs.childIter("");
        while (it0.nextChild()) |c| {
            cb(ctx, c.name, TARFS_BASE + c.node);
        }
        return;
    }
    if (node == CONSOLE_NODE) return;
    if (isExt2(node)) {
        ext2.listIno(@intCast(node - EXT2_BASE), EXT2_BASE, ctx, cb);
        return;
    }
    if (node < TARFS_BASE or node >= TARFS_BASE + tarfs.nodeCount()) return;
    const n = tarfs.getNode(node - TARFS_BASE);
    if (n.kind != .dir) return;

    var it = tarfs.childIter(n.path());
    while (it.nextChild()) |c| {
        cb(ctx, c.name, TARFS_BASE + c.node);
    }
}

fn eqStr(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}
