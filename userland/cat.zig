//! cat —— 读文件到标准输出（循环 read/write）

const ousia = @import("lib/ousia.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

export fn main() i32 {
    if (ousia.argc() < 2) {
        ousia.printf("usage: cat <file> [file...]\n", .{});
        return 1;
    }
    var rc: i32 = 0;
    for (1..ousia.argc()) |i| {
        const path = ousia.arg(i);
        const fd = ousia.open(path, 0);
        if (fd < 0) {
            ousia.printf("cat: {s}: cannot open ({d})\n", .{ path, fd });
            rc = 1;
            continue;
        }
        var buf: [1024]u8 = undefined;
        while (true) {
            const n = ousia.read(@intCast(fd), &buf);
            if (n <= 0) break;
            _ = ousia.write(1, buf[0..@intCast(n)]);
        }
        _ = ousia.close(@intCast(fd));
    }
    return rc;
}
