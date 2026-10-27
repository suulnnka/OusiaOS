//! uname —— 系统信息

const zos = @import("lib/zos.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

export fn main() i32 {
    var buf: [6 * 65]u8 = undefined;
    const r = zos.syscall1(zos.SYS_uname, @intFromPtr(&buf));
    if (r < 0) return 1;

    const sysname = field(&buf, 0);
    const nodename = field(&buf, 1);
    const release = field(&buf, 2);
    const version = field(&buf, 3);
    const machine = field(&buf, 4);

    if (zos.argc() > 1 and zos.eql(zos.arg(1), "-a")) {
        zos.printf("{s} {s} {s} {s} {s}\n", .{ sysname, nodename, release, version, machine });
    } else {
        zos.printf("{s}\n", .{sysname});
    }
    return 0;
}

fn field(buf: []const u8, i: usize) []const u8 {
    const start = i * 65;
    var l: usize = 0;
    while (l < 65 and buf[start + l] != 0) l += 1;
    return buf[start .. start + l];
}
