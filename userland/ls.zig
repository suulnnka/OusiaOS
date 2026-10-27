//! ls —— 列目录

const zos = @import("lib/zos.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

export fn main() i32 {
    const path = if (zos.argc() > 1) zos.arg(1) else "/";

    var entries: [32]zos.Dirent = undefined;
    const n = zos.listDir(path, &entries);
    if (n < 0) {
        zos.printf("ls: {s}: cannot list ({d})\n", .{ path, n });
        return 1;
    }
    for (entries[0..@intCast(n)]) |*e| {
        if (e.is_dir) {
            zos.printf("{s:<10} <dir>\n", .{e.nameSlice()});
        } else {
            zos.printf("{s}\n", .{e.nameSlice()});
        }
    }
    return 0;
}
