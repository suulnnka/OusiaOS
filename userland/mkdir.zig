//! mkdir —— 创建目录（根文件系统 ext2，直接落盘）

const ousia = @import("lib/ousia.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

export fn main() i32 {
    if (ousia.argc() < 2) {
        ousia.printf("usage: mkdir <dir>\n", .{});
        return 1;
    }
    const r = ousia.mkdir(ousia.arg(1), 0o755);
    if (r != 0) {
        ousia.printf("mkdir: {s}: failed ({d})\n", .{ ousia.arg(1), r });
        return 1;
    }
    return 0;
}
