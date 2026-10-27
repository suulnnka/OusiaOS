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
    mode: u32,
};

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
        ROOT_NODE => .{ .is_dir = true, .is_console = false, .size = 0, .mode = 0o040755 },
        CONSOLE_NODE => .{ .is_dir = false, .is_console = true, .size = 0, .mode = 0o020620 },
        else => blk: {
            const n = tarfs.getNode(node - TARFS_BASE);
            break :blk .{
                .is_dir = n.kind == .dir,
                .is_console = false,
                .size = n.size,
                .mode = if (n.kind == .dir) 0o040755 else 0o100644,
            };
        },
    };
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
