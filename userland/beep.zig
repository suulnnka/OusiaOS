//! beep —— 播放一段正弦纯音（AC'97 音频子系统演示）
//!
//! 用法: beep [freq_hz] [ms]     默认 440Hz 200ms

const ousia = @import("lib/ousia.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

/// ousia_beep 系统调用（nr=505）
fn beep(freq: u32, ms: u32) isize {
    return ousia.syscall3(505, freq, ms, 0);
}

export fn main() i32 {
    var freq: u32 = 440;
    var ms: u32 = 200;

    if (ousia.argc() >= 2) {
        freq = parseNum(ousia.arg(1)) orelse {
            ousia.printf("usage: beep [freq_hz] [ms]   (20..8000 Hz)\n", .{});
            return 1;
        };
    }
    if (ousia.argc() >= 3) {
        ms = parseNum(ousia.arg(2)) orelse 200;
    }

    const r = beep(freq, ms);
    if (r < 0) {
        ousia.printf("beep: failed ({d}) -- run qemu with '-device AC97'\n", .{r});
        return 1;
    }
    ousia.printf("beep: {d} Hz x {d} ms\n", .{ freq, ms });
    return 0;
}

fn parseNum(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
        if (v > 100_000) return null;
    }
    return v;
}
