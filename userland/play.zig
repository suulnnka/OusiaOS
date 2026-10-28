//! play —— WAV 播放命令（shell）
//!
//! 用法：play /etc/sounds/chime.wav
//! 底层是 SYS_ousia_wav(506)：内核读文件 → 解析 RIFF/PCM → 归一化
//! （8/16bit、单/立体声、任意采样率 → 48k S16 立体声）→ AC'97 DMA。
//! 阻塞至播完；音频忙（另一路在放）返回 EAGAIN。

const ousia = @import("lib/ousia.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

export fn main() i32 {
    if (ousia.argc() < 2) {
        ousia.printf("usage: play <file.wav>\n", .{});
        return 1;
    }
    const path = ousia.arg(1);
    ousia.printf("playing {s}...\n", .{path});
    const r = ousia.playWav(path);
    if (r == 0) {
        ousia.printf("play: done\n", .{});
        return 0;
    }
    ousia.printf("play: failed ({d})\n", .{r});
    return 1;
}
