//! VFS —— 虚拟文件系统：路径解析 + 设备抽象
//!
//! 教学要点：
//!   - Unix 的伟大发明："一切皆文件"。read(/dev/console) 与 read(/etc/motd)
//!     走同一个接口，背后一个是字符设备、一个是内存盘文件
//!   - 路径解析 namei：相对路径基于进程 cwd，逐段消解 "." 与 ".."
//!
//! 节点编号（vfs 层的统一句柄）：
//!   0            /        （虚拟根目录）
//!   1            /dev/console（字符设备，内核特判）
//!   2..2+N-1     tarfs 节点（tarfs 内部下标 = vfs 编号 - 2）

const tarfs = @import("tarfs.zig");
const console = @import("console.zig");
const tty = @import("tty.zig");

pub const ROOT_NODE: usize = 0;
pub const CONSOLE_NODE: usize = 1;
const TARFS_BASE: usize = 2;

pub fn init() void {
    // tarfs.init() 已在 main 里填充节点表；本模块无需额外初始化
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

    // 逐段检查祖先目录的 x 位（"a/b/c" 检查 a、a/b；norm[0..seg_end]
    // 是含前导 '/' 的前缀，tarfs 路径要去掉它）
    var seg_end: usize = 1;
    while (seg_end < norm.len) : (seg_end += 1) {
        if (norm[seg_end] == '/') {
            const dir = tarfs.lookup(norm[1..seg_end]) orelse return error.NoEnt;
            if (!mayAccess(nodeInfoOf(TARFS_BASE + dir), uid, gid, .x)) return error.Access;
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

    if (tarfs.lookup(norm[1..])) |i| return TARFS_BASE + i;
    return null;
}

pub fn info(node: usize) NodeInfo {
    return switch (node) {
        ROOT_NODE => .{ .is_dir = true, .is_console = false, .size = 0, .mode = 0o040755, .uid = 0, .gid = 0 },
        CONSOLE_NODE => .{ .is_dir = false, .is_console = true, .size = 0, .mode = 0o020600, .uid = 0, .gid = 0 },
        else => blk: {
            const n = tarfs.getNode(node - TARFS_BASE);
            break :blk .{
                .is_dir = n.kind == .dir,
                .is_console = false,
                .size = n.size,
                .mode = n.mode,
                .uid = n.uid,
                .gid = n.gid,
            };
        },
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
    if (node < TARFS_BASE or node >= TARFS_BASE + tarfs.nodeCount()) return -9; // EBADF
    const n = tarfs.getNode(node - TARFS_BASE);
    if (n.kind != .file) return -21; // EISDIR
    const p: usize = @intCast(pos);
    if (p >= n.size) return 0; // EOF
    const want: usize = @intCast(@min(n.size - p, buf.len));
    @memcpy(buf[0..want], n.data.?[p .. p + want]);
    return @intCast(want);
}

/// 写：只有 console 可写（tarfs 只读）。返回写入字节数，负值表示错误。
pub fn write(node: usize, buf: []const u8) isize {
    if (node == CONSOLE_NODE) {
        console.writeStr(buf);
        return @intCast(buf.len);
    }
    if (node == ROOT_NODE) return -21;
    return -30; // EROFS
}

/// 遍历目录孩子
pub fn listDir(node: usize, ctx: anytype, cb: fn (@TypeOf(ctx), name: []const u8, child_node: usize) void) void {
    var prefix: []const u8 = "";
    switch (node) {
        ROOT_NODE => {},
        CONSOLE_NODE => return,
        else => {
            if (node < TARFS_BASE or node >= TARFS_BASE + tarfs.nodeCount()) return;
            const n = tarfs.getNode(node - TARFS_BASE);
            if (n.kind != .dir) return;
            prefix = n.path();
        },
    }

    var it = tarfs.childIter(prefix);
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
