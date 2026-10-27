//! cat —— 读文件到标准输出（循环 read/write）

const zos = @import("lib/zos.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

export fn main() i32 {
    if (zos.argc() < 2) {
        zos.printf("usage: cat <file> [file...]\n", .{});
        return 1;
    }
    var rc: i32 = 0;
    for (1..zos.argc()) |i| {
        const path = zos.arg(i);
        const fd = zos.open(path, 0);
        if (fd < 0) {
            zos.printf("cat: {s}: cannot open ({d})\n", .{ path, fd });
            rc = 1;
            continue;
        }
        var buf: [1024]u8 = undefined;
        while (true) {
            const n = zos.read(@intCast(fd), &buf);
            if (n <= 0) break;
            _ = zos.write(1, buf[0..@intCast(n)]);
        }
        _ = zos.close(@intCast(fd));
    }
    return rc;
}
