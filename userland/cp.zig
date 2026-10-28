//! cp —— 复制文件（Unix 语义子集）
//!
//! 教学要点：文件复制 = "open 读 → open 写" 的搬运循环，一个 syscall
//! 都不用加——两个文件系统操作经 VFS 就是这么正交：
//!   - cp <src> <dst>        dst 是已存在目录 → 拷入该目录（保留名字）
//!   - 权限位跟随源文件（stat src → openMode(dst, ..., src.mode)）
//!   - 64KB 缓冲做读-写循环；ext2 根文件系统上拷贝 = 真落盘
//!
//! 与磁盘镜像互拷（guest↔宿主机）走 scripts/disk.sh（debugfs 封装）。

const ousia = @import("lib/ousia.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

var buf: [64 * 1024]u8 = undefined;

/// 从路径里取末段名字（拷入目录时保留原名）
fn basename(p: []const u8) []const u8 {
    var last: usize = 0;
    for (p, 0..) |c, i| {
        if (c == '/') last = i + 1;
    }
    return p[last..];
}

export fn main() i32 {
    if (ousia.argc() != 3) {
        ousia.printf("usage: cp <src> <dst>   (dst 为目录时拷入其中)\n", .{});
        return 1;
    }
    const src = ousia.arg(1);
    var dst = ousia.arg(2);

    // dst 是目录 → 拷入该目录，沿用源文件名
    if (ousia.stat(dst)) |st| {
        if (st.mode & 0o170000 == 0o040000) {
            var b: [300]u8 = undefined;
            const name = basename(src);
            if (dst.len + 1 + name.len + 1 > b.len) {
                ousia.printf("cp: path too long\n", .{});
                return 1;
            }
            @memcpy(b[0..dst.len], dst);
            b[dst.len] = '/';
            @memcpy(b[dst.len + 1 ..][0..name.len], name);
            dst = b[0 .. dst.len + 1 + name.len];
        }
    }

    const in_fd = ousia.open(src, ousia.O_RDONLY);
    if (in_fd < 0) {
        ousia.printf("cp: {s}: cannot open ({d})\n", .{ src, in_fd });
        return 1;
    }
    defer _ = ousia.close(@intCast(in_fd));

    // 权限位跟随源（没有就 0644）
    const src_st = ousia.stat(src);
    const mode: u32 = if (src_st) |st| st.mode & 0o7777 else 0o644;

    const out_fd = ousia.openMode(dst, ousia.O_WRONLY | ousia.O_CREAT | ousia.O_TRUNC, mode);
    if (out_fd < 0) {
        ousia.printf("cp: {s}: cannot create ({d})\n", .{ dst, out_fd });
        return 1;
    }
    defer _ = ousia.close(@intCast(out_fd));

    while (true) {
        const n = ousia.read(@intCast(in_fd), &buf);
        if (n < 0) {
            ousia.printf("cp: {s}: read error ({d})\n", .{ src, n });
            return 1;
        }
        if (n == 0) break;
        const w = ousia.write(@intCast(out_fd), buf[0..@intCast(n)]);
        if (w != n) {
            ousia.printf("cp: {s}: write error ({d})\n", .{ dst, w });
            return 1;
        }
    }
    return 0;
}
