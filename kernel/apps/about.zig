//! About ZOS —— 最小应用范例：静态文字 + 一个按钮
//!
//! 从 gui.zig 迁来；演示一个应用需要的全部接口：
//! paintClient（画客户区）+ onPress（点击）。无状态、无定时器。

const gui = @import("../gui.zig");
const Rect = gui.Rect;
const mkRect = gui.mkRect;
const inRect = gui.inRect;

pub fn paint(w: *const gui.Win) void {
    // 多档字号演示：2x 大标题 + 1x 正文
    gui.textScaled(w.x + 18, w.y + 30, "ZOS 0.2.0", gui.pal.navy, 2);
    const lines = [_][]const u8{
        "teaching kernel in Zig -- GUI/writable-FS/audio",
        "Compositor: damage-rect repaint, desktop icons",
        "Input: PS/2 mouse (IRQ12) + keyboard focus",
        "VBE 640x480x32 via GRUB gfxpayload",
    };
    var ty = w.y + 66;
    for (lines) |l| {
        gui.text(w.x + 18, ty, l, gui.pal.black);
        ty += 18;
    }

    // 按钮区上方的凹分隔线
    const dy = w.y + w.h - 38;
    gui.hline(w.x + 8, w.x + w.w - 9, dy, gui.pal.shadow);
    gui.hline(w.x + 8, w.x + w.w - 9, dy + 1, gui.pal.white);

    const ok = okRect(w);
    gui.fillRect(ok, gui.pal.chrome);
    gui.bevel2(ok, true);
    gui.textBold(ok.x + 28, ok.y + 3, "OK", gui.pal.black);
}

fn okRect(w: *const gui.Win) Rect {
    return mkRect(w.x + @divTrunc(w.w - 70, 2), w.y + w.h - 32, 70, 22);
}

pub fn press(w: *gui.Win, x: i32, y: i32) void {
    if (inRect(x, y, okRect(w))) gui.closeWin(w);
}
