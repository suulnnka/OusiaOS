//! echo —— 输出参数

const ousia = @import("lib/ousia.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

export fn main() i32 {
    var first = true;
    for (1..ousia.argc()) |i| {
        if (!first) _ = ousia.write(1, " ");
        _ = ousia.write(1, ousia.arg(i));
        first = false;
    }
    _ = ousia.write(1, "\n");
    return 0;
}
