//! music —— 播放一段小旋律（连续调用 ousia_beep）
//!
//! 曲目：贝多芬《欢乐颂》主题（公有领域），C 大调。

const ousia = @import("lib/ousia.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

const NOTE_C4: u32 = 262;
const NOTE_D4: u32 = 294;
const NOTE_E4: u32 = 330;
const NOTE_F4: u32 = 349;
const NOTE_G4: u32 = 392;

const Q: u32 = 300; // 四分音符
const DOT: u32 = 450; // 附点四分
const HALF: u32 = 600; // 二分音符

const Note = struct { f: u32, ms: u32 };

const melody = [_]Note{
    .{ .f = NOTE_E4, .ms = Q }, .{ .f = NOTE_E4, .ms = Q }, .{ .f = NOTE_F4, .ms = Q }, .{ .f = NOTE_G4, .ms = Q },
    .{ .f = NOTE_G4, .ms = Q }, .{ .f = NOTE_F4, .ms = Q }, .{ .f = NOTE_E4, .ms = Q }, .{ .f = NOTE_D4, .ms = Q },
    .{ .f = NOTE_C4, .ms = Q }, .{ .f = NOTE_C4, .ms = Q }, .{ .f = NOTE_D4, .ms = Q }, .{ .f = NOTE_E4, .ms = Q },
    .{ .f = NOTE_E4, .ms = DOT }, .{ .f = NOTE_D4, .ms = HALF },

    .{ .f = NOTE_E4, .ms = Q }, .{ .f = NOTE_E4, .ms = Q }, .{ .f = NOTE_F4, .ms = Q }, .{ .f = NOTE_G4, .ms = Q },
    .{ .f = NOTE_G4, .ms = Q }, .{ .f = NOTE_F4, .ms = Q }, .{ .f = NOTE_E4, .ms = Q }, .{ .f = NOTE_D4, .ms = Q },
    .{ .f = NOTE_C4, .ms = Q }, .{ .f = NOTE_C4, .ms = Q }, .{ .f = NOTE_D4, .ms = Q }, .{ .f = NOTE_E4, .ms = Q },
    .{ .f = NOTE_D4, .ms = DOT }, .{ .f = NOTE_C4, .ms = HALF },
};

export fn main() i32 {
    for (melody, 0..) |n, i| {
        const r = ousia.syscall3(505, n.f, n.ms, 0);
        if (r < 0) {
            ousia.printf("music: beep failed ({d}) -- run qemu with '-device AC97'\n", .{r});
            return 1;
        }
        // 音符间留一点气口（休止符效果）
        if (i + 1 < melody.len) ousia.sleepMs(50);
    }
    ousia.printf("music: ode to joy ({d} notes)\n", .{melody.len});
    return 0;
}
