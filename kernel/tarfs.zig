//! tarfs —— 内存盘(initrd)文件系统，基于 ustar 格式的 tar 归档
//!
//! 教学要点：
//!   - GRUB 用 `module2` 把整块 tar 文件按原样装进物理内存，
//!     "文件系统"本质上只是对这块内存的解释方式
//!   - ustar 头部 512 字节：name/mode/size/typeflag...，数据紧跟其后，
//!     按 512 字节对齐。typeflag: '0'=文件 '5'=目录
//!   - 只读文件系统：内核镜像里的内容天然不可变（写文件是课后练习）
//!
//! tar 内路径约定：无前导 '/'，目录名带（或不带）尾 '/'，
//! 解析时统一去掉首尾斜杠后与规范化路径比较。

const console = @import("console.zig");
const multiboot = @import("multiboot.zig");
const vmm = @import("vmm.zig");

const BLOCK = 512;
const MAX_NODES = 128;

pub const NodeKind = enum { file, dir };

pub const Node = struct {
    kind: NodeKind = .file,
    /// 规范化路径（无首尾 '/'），如 "etc/motd"、"bin"
    path_buf: [128]u8 = undefined,
    path_len: usize = 0,
    size: u64 = 0,
    /// 文件数据（位于 initrd 内存中，直接映射后的虚拟地址切片）
    data: ?[]const u8 = null,

    pub fn path(self: *const Node) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

var nodes: [MAX_NODES]Node = undefined;
var node_count: usize = 0;

pub fn nodeCount() usize {
    return node_count;
}

pub fn getNode(i: usize) *const Node {
    return &nodes[i];
}

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

        if (node_count < MAX_NODES and name_len > 0) {
            const n = &nodes[node_count];
            n.* = .{};
            n.kind = if (typeflag == '5') .dir else .file;
            n.size = if (typeflag == '5') 0 else size;

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

    console.kprintf("tarfs: initrd [{x},{x}) {d}KB, {d} entries\n", .{
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

/// 按规范化路径精确查找
pub fn lookup(norm_path: []const u8) ?usize {
    for (0..node_count) |i| {
        if (stdEql(nodes[i].path(), norm_path)) return i;
    }
    return null;
}

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
