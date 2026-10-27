//! echo —— 输出参数

const zos = @import("lib/zos.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

export fn main() i32 {
    var first = true;
    for (1..zos.argc()) |i| {
        if (!first) _ = zos.write(1, " ");
        _ = zos.write(1, zos.arg(i));
        first = false;
    }
    _ = zos.write(1, "\n");
    return 0;
}
