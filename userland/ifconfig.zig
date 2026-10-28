//! ifconfig —— 打印网络配置（经系统调用 503）

const ousia = @import("lib/ousia.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

export fn main() i32 {
    var buf: [256]u8 = undefined;
    const r = ousia.syscall3(503, @intFromPtr(&buf), buf.len, 0);
    if (r < 0) {
        ousia.printf("ifconfig: network not available ({d})\n", .{r});
        return 1;
    }
    const n: usize = @intCast(r);
    ousia.printf("eth0  {s}", .{buf[0..n]});
    return 0;
}
