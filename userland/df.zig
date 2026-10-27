//! df —— 文件系统概要（ext2 挂载信息来自内核 zos_fsinfo 系统调用）

const zos = @import("lib/zos.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

export fn main() i32 {
    var buf: [256]u8 = undefined;
    const n = zos.fsinfo(&buf);
    if (n < 0) {
        zos.printf("df: no filesystem mounted ({d})\n", .{n});
        return 1;
    }
    // 内核返回一行带换行的字符串
    var len: usize = @intCast(n);
    if (len > buf.len) len = buf.len;
    zos.printf("{s}", .{buf[0..len]});
    return 0;
}
