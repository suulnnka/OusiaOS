//! mkdir —— 创建目录（根文件系统 ext2，直接落盘）

const zos = @import("lib/zos.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

export fn main() i32 {
    if (zos.argc() < 2) {
        zos.printf("usage: mkdir <dir>\n", .{});
        return 1;
    }
    const r = zos.mkdir(zos.arg(1), 0o755);
    if (r != 0) {
        zos.printf("mkdir: {s}: failed ({d})\n", .{ zos.arg(1), r });
        return 1;
    }
    return 0;
}
