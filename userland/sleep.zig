//! sleep —— 睡眠指定秒数

const ousia = @import("lib/ousia.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

export fn main() i32 {
    if (ousia.argc() < 2) {
        ousia.printf("usage: sleep <seconds>\n", .{});
        return 1;
    }
    const secs = parse(ousia.arg(1)) orelse {
        ousia.printf("sleep: bad number\n", .{});
        return 1;
    };
    ousia.sleepMs(secs * 1000);
    return 0;
}

fn parse(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}
