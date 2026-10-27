//! ZOS 图形子系统：合成器（compositor）+ Win3.1 风格桌面/任务栏
//!
//! 教学要点：
//!   - 图形模式由 GRUB 设置（grub.cfg 的 gfxpayload=640x480x32），
//!     内核经 Multiboot2 framebuffer 标签拿到 帧缓冲物理地址/间距/
//!     像素布局，用 vmm.mapMMIO 映射后直接写像素
//!   - 合成器：分层表面按 z 序画进【后备缓冲】(backbuf)，只把受影响
//!     的【脏矩形】(damage) 搬运到帧缓冲——光标移动这类高频更新只需
//!     重画两个 16x16 的小区域，而不是整屏 1.2MB
//!   - 图层自底向上：桌面 → 窗口列表 → 任务栏 → 弹出菜单 → 鼠标光标。
//!     光标是普通 sprite 层，与别的层统一参与合成，遮挡自动正确
//!   - 线程模型：全部 GUI 状态只在【中断上下文】触碰（IRQ12 鼠标驱动
//!     状态变化即重绘、IRQ0 时钟驱动秒针刷新），彼此不会嵌套（中断门
//!     自动关 IF），因此无需任何锁
//!   - Win3.1 视觉语言：灰.chrome + 2px 斜面(bevel)、藏青标题栏、
//!     白底菜单带投影、系统菜单盒(横杠)/▼ 关闭盒

const std = @import("std");
const multiboot = @import("multiboot.zig");
const vmm = @import("vmm.zig");
const console = @import("console.zig");
const pit = @import("pit.zig");
const font = @import("font.zig");

pub const SCR_W: i32 = 640;
pub const SCR_H: i32 = 480;
const TASKBAR_H: i32 = 24;
const TB_Y: i32 = SCR_H - TASKBAR_H;

// ---------------- 状态 ----------------

var active = false;
var lfb: [*]u32 = undefined; // 帧缓冲（MMIO 映射后）
var pitch_px: usize = 0; // 帧缓冲行距（像素）

/// 后备缓冲：合成结果先画到这里，再按脏矩形搬运到帧缓冲。
/// 1.2MB 静态分配于 .bss（教学内核免抖动的最简单选择）。
var backbuf: [SCR_W * SCR_H]u32 = undefined;

var rsh: u5 = 0;
var gsh: u5 = 0;
var bsh: u5 = 0;

const Pal = struct {
    desktop: u32, // 青绿桌面（老 Windows 的经典底色）
    chrome: u32, // #C0C0C0 控件灰
    white: u32,
    black: u32,
    navy: u32, // 激活标题栏
    shadow: u32, // #808080
    ltf: u32, // #DFDFDF 亮面
};
var pal: Pal = undefined;

inline fn px(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << rsh) | (@as(u32, g) << gsh) | (@as(u32, b) << bsh);
}

// 输入状态（只在鼠标中断里改）
var mouse_x: i32 = 300;
var mouse_y: i32 = 200;
var left_down = false;
var drag: ?struct { idx: usize, offx: i32, offy: i32 } = null;

// 任务栏
var btn_pressed = false; // ZOS 按钮（菜单打开期间保持按下）
var clock_buf: [5]u8 = "00:00".*;
var last_clock: [5]u8 = "00:00".*;

// 弹出菜单
var menu_open = false;
var menu_hover: i8 = -1;
const MENU_W: i32 = 132;
const ITEM_H: i32 = 18;
const SEP_H: i32 = 5;
const MENU_PAD: i32 = 3;
const MenuItem = struct { label: []const u8, enabled: bool, sep: bool = false };
const menu_items = [_]MenuItem{
    .{ .label = "About ZOS...", .enabled = true },
    .{ .label = "", .enabled = false, .sep = true },
    .{ .label = "Exit GUI", .enabled = false }, // 教学演示：置灰项的画法
};

// 窗口列表（z 序 = 数组顺序，自底向上）
const Win = struct {
    visible: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 292,
    h: i32 = 150,
};
var windows = [_]Win{ .{}, .{}, .{}, .{} }; // [0] = About 对话框，其余预留

// ---------------- 矩形与脏区 ----------------

const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

fn mkRect(x: i32, y: i32, w: i32, h: i32) Rect {
    return .{ .x = x, .y = y, .w = w, .h = h };
}

const SCREEN = mkRect(0, 0, SCR_W, SCR_H);
var damage = mkRect(0, 0, 0, 0);
var clip: Rect = SCREEN; // 重绘期间的所有图元都被裁剪到这里

fn inRect(x: i32, y: i32, r: Rect) bool {
    return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h;
}

fn clampRect(r: Rect) Rect {
    const x0 = @max(r.x, 0);
    const y0 = @max(r.y, 0);
    const x1 = @min(r.x + r.w, SCR_W);
    const y1 = @min(r.y + r.h, SCR_H);
    return mkRect(x0, y0, @max(x1 - x0, 0), @max(y1 - y0, 0));
}

/// 记脏区：合并为包围盒（教学取舍：多个分散小脏区会合并成大矩形，
/// 正确性优先；更精细的做法是脏区列表）
fn addDamage(r: Rect) void {
    const c = clampRect(r);
    if (c.w <= 0 or c.h <= 0) return;
    if (damage.w <= 0 or damage.h <= 0) {
        damage = c;
        return;
    }
    const x0 = @min(damage.x, c.x);
    const y0 = @min(damage.y, c.y);
    const x1 = @max(damage.x + damage.w, c.x + c.w);
    const y1 = @max(damage.y + damage.h, c.y + c.h);
    damage = mkRect(x0, y0, x1 - x0, y1 - y0);
}

// ---------------- 绘制原语（全部尊重 clip） ----------------

fn setPx(x: i32, y: i32, c: u32) void {
    if (x < clip.x or y < clip.y or x >= clip.x + clip.w or y >= clip.y + clip.h) return;
    backbuf[@intCast(y * SCR_W + x)] = c;
}

fn fillRect(r: Rect, c: u32) void {
    const x0 = @max(r.x, clip.x);
    const y0 = @max(r.y, clip.y);
    const x1 = @min(r.x + r.w, clip.x + clip.w);
    const y1 = @min(r.y + r.h, clip.y + clip.h);
    if (x1 <= x0 or y1 <= y0) return;
    var y = y0;
    while (y < y1) : (y += 1) {
        const off: usize = @intCast(y * SCR_W + x0);
        @memset(backbuf[off .. off + @as(usize, @intCast(x1 - x0))], c);
    }
}

fn hline(x0: i32, x1: i32, y: i32, c: u32) void {
    var x = x0;
    while (x <= x1) : (x += 1) setPx(x, y, c);
}

fn vline(x: i32, y0: i32, y1: i32, c: u32) void {
    var y = y0;
    while (y <= y1) : (y += 1) setPx(x, y, c);
}

/// 1px 斜面：raised = 顶/左亮、底/右暗；sunken 反转
fn bevel1(r: Rect, raised: bool) void {
    const tl = if (raised) pal.white else pal.shadow;
    const br = if (raised) pal.shadow else pal.white;
    hline(r.x, r.x + r.w - 1, r.y, tl);
    vline(r.x, r.y, r.y + r.h - 1, tl);
    hline(r.x, r.x + r.w - 1, r.y + r.h - 1, br);
    vline(r.x + r.w - 1, r.y, r.y + r.h - 1, br);
}

/// 2px 斜面：Win3.1 控件的标准立体感（外圈白/暗灰，内圈亮灰/黑）
fn bevel2(r: Rect, raised: bool) void {
    bevel1(r, raised);
    const tl = if (raised) pal.ltf else pal.black;
    const br = if (raised) pal.black else pal.ltf;
    const i = mkRect(r.x + 1, r.y + 1, r.w - 2, r.h - 2);
    if (i.w <= 0 or i.h <= 0) return;
    hline(i.x, i.x + i.w - 1, i.y, tl);
    vline(i.x, i.y, i.y + i.h - 1, tl);
    hline(i.x, i.x + i.w - 1, i.y + i.h - 1, br);
    vline(i.x + i.w - 1, i.y, i.y + i.h - 1, br);
}

/// 文本：8x16 位图字体，MSB=最左像素
fn text(x: i32, y: i32, s: []const u8, fg: u32) void {
    var cx = x;
    for (s) |ch| {
        const idx: usize = if (ch >= font.FIRST and ch < font.FIRST + font.COUNT)
            ch - font.FIRST
        else
            '?' - font.FIRST;
        const g = &font.glyphs[idx];
        for (g, 0..) |row, ry| {
            if (row == 0) continue;
            var b = row;
            var rx: i32 = 0;
            while (b != 0) : (b <<= 1) {
                if (b & 0x80 != 0) setPx(cx + rx, y + @as(i32, @intCast(ry)), fg);
                rx += 1;
            }
        }
        cx += font.W;
    }
}

/// 粗体：同一字符画两遍，横向错开 1px（3.1 时代的"字体加粗"）
fn textBold(x: i32, y: i32, s: []const u8, fg: u32) void {
    text(x, y, s, fg);
    text(x + 1, y, s, fg);
}

// ---------------- 图层几何 ----------------

fn btnRect() Rect {
    return mkRect(4, TB_Y + 3, 52, TASKBAR_H - 6);
}

fn clockRect() Rect {
    return mkRect(SCR_W - 4 - 60, TB_Y + 3, 60, TASKBAR_H - 6);
}

fn menuHeight() i32 {
    return MENU_PAD * 2 + ITEM_H * 2 + SEP_H;
}

fn menuRect() Rect {
    return mkRect(2, TB_Y - menuHeight() - 3, MENU_W, menuHeight());
}

fn winRect(w: *const Win) Rect {
    return mkRect(w.x, w.y, w.w, w.h);
}

fn titleRect(w: *const Win) Rect {
    return mkRect(w.x + 3, w.y + 3, w.w - 6, 22);
}

fn sysBoxRect(w: *const Win) Rect {
    return mkRect(w.x + 7, w.y + 5, 18, 18);
}

fn closeBoxRect(w: *const Win) Rect {
    return mkRect(w.x + w.w - 7 - 18, w.y + 5, 18, 18);
}

fn okRect(w: *const Win) Rect {
    return mkRect(w.x + @divTrunc(w.w - 70, 2), w.y + w.h - 32, 70, 22);
}

fn cursorRect() Rect {
    return mkRect(mouse_x, mouse_y, 12, 15);
}

// ---------------- 图层绘制 ----------------

fn paintDesktop() void {
    fillRect(SCREEN, pal.desktop);
}

fn paintTaskbar() void {
    fillRect(mkRect(0, TB_Y, SCR_W, TASKBAR_H), pal.chrome);
    hline(0, SCR_W - 1, TB_Y, pal.white); // 顶缘亮线（凸出感）

    // ZOS 按钮：菜单打开期间保持"按下"
    const b = btnRect();
    fillRect(b, pal.chrome);
    bevel2(b, !btn_pressed);
    const off: i32 = if (btn_pressed) 1 else 0;
    textBold(b.x + 14 + off, b.y + 1 + off, "ZOS", pal.black);

    // 按钮右侧的蚀刻分隔线（暗+亮 = 凹槽）
    vline(b.x + b.w + 8, TB_Y + 4, TB_Y + TASKBAR_H - 5, pal.shadow);
    vline(b.x + b.w + 9, TB_Y + 4, TB_Y + TASKBAR_H - 5, pal.white);

    // 时钟面板（凹）
    const c = clockRect();
    fillRect(c, pal.chrome);
    bevel1(c, false);
    text(c.x + 6, c.y + 1, &clock_buf, pal.black);
}

fn paintMenu() void {
    // 投影：菜单整体向右下偏移 2px 的灰色矩形
    const m = menuRect();
    fillRect(mkRect(m.x + 2, m.y + 2, m.w, m.h), pal.shadow);
    fillRect(m, pal.white);
    hline(m.x, m.x + m.w - 1, m.y, pal.black);
    hline(m.x, m.x + m.w - 1, m.y + m.h - 1, pal.black);
    vline(m.x, m.y, m.y + m.h - 1, pal.black);
    vline(m.x + m.w - 1, m.y, m.y + m.h - 1, pal.black);

    var y = m.y + MENU_PAD;
    for (menu_items, 0..) |it, i| {
        if (it.sep) {
            hline(m.x + 2, m.x + m.w - 3, y + 2, pal.shadow);
            hline(m.x + 2, m.x + m.w - 3, y + 3, pal.white);
            y += SEP_H;
            continue;
        }
        const hov = menu_hover == @as(i8, @intCast(i));
        if (hov) fillRect(mkRect(m.x + 1, y, m.w - 2, ITEM_H), pal.navy);
        const fg: u32 = if (hov)
            pal.white
        else if (it.enabled)
            pal.black
        else
            pal.shadow;
        text(m.x + 8, y + 1, it.label, fg);
        y += ITEM_H;
    }
}

fn paintWindow(w: *const Win) void {
    // 外框：灰底 + 2px 凸边
    fillRect(winRect(w), pal.chrome);
    bevel2(winRect(w), true);

    // 标题栏（藏青底、白粗体）
    const tr = titleRect(w);
    fillRect(tr, pal.navy);

    // 系统菜单盒（左，横杠图标）——3.1 的装饰，单击无动作
    const sb = sysBoxRect(w);
    fillRect(sb, pal.chrome);
    bevel1(sb, true);
    fillRect(mkRect(sb.x + 4, sb.y + 8, 10, 2), pal.black);

    // 关闭盒（右，▼ 图标）
    const cb = closeBoxRect(w);
    fillRect(cb, pal.chrome);
    bevel1(cb, true);
    const cx = cb.x + 9; // ▼ 顶点中心
    fillRect(mkRect(cx - 3, cb.y + 6, 7, 1), pal.black);
    fillRect(mkRect(cx - 2, cb.y + 7, 5, 1), pal.black);
    fillRect(mkRect(cx - 1, cb.y + 8, 3, 1), pal.black);
    fillRect(mkRect(cx, cb.y + 9, 1, 1), pal.black);

    textBold(tr.x + 28, tr.y + 3, "About ZOS", pal.white);

    // 客户区文字
    const lines = [_][]const u8{
        "ZOS 0.1.0 -- teaching kernel in Zig",
        "Compositor: damage-rect repaint",
        "Input: PS/2 mouse (IRQ12)",
        "VBE 640x480x32 via GRUB gfxpayload",
    };
    var ty = w.y + 36;
    for (lines) |l| {
        text(w.x + 18, ty, l, pal.black);
        ty += 18;
    }

    // 按钮区上方的凹分隔线
    const dy = w.y + w.h - 38;
    hline(w.x + 8, w.x + w.w - 9, dy, pal.shadow);
    hline(w.x + 8, w.x + w.w - 9, dy + 1, pal.white);

    // OK 按钮
    const ok = okRect(w);
    fillRect(ok, pal.chrome);
    bevel2(ok, true);
    textBold(ok.x + 28, ok.y + 3, "OK", pal.black);
}

// 鼠标光标（白箭头 + 黑描边，热点在左上角；bit15 = 最左像素）
const cur_black = [16]u16{
    0b1000000000000000,
    0b1010000000000000,
    0b1001000000000000,
    0b1000100000000000,
    0b1000010000000000,
    0b1000001000000000,
    0b1000000100000000,
    0b1000000010000000,
    0b1000000001000000,
    0b1000000000100000,
    0b1000111111100000,
    0b1000100000000000,
    0b1000100000000000,
    0b1000100000000000,
    0b1111100000000000,
    0,
};
const cur_white = [16]u16{
    0,
    0b0100000000000000,
    0b0110000000000000,
    0b0111000000000000,
    0b0111100000000000,
    0b0111110000000000,
    0b0111111000000000,
    0b0111111100000000,
    0b0111111110000000,
    0b0111111111000000,
    0b0111000000000000,
    0b0111000000000000,
    0b0111000000000000,
    0b0111000000000000,
    0,
    0,
};

fn paintCursor() void {
    for (cur_black, cur_white, 0..) |brow, wrow, ry| {
        var rx: usize = 0;
        while (rx < 16) : (rx += 1) {
            const bit = @as(u16, 0x8000) >> @as(u4, @intCast(rx));
            if (brow & bit != 0) {
                setPx(mouse_x + @as(i32, @intCast(rx)), mouse_y + @as(i32, @intCast(ry)), pal.black);
            } else if (wrow & bit != 0) {
                setPx(mouse_x + @as(i32, @intCast(rx)), mouse_y + @as(i32, @intCast(ry)), pal.white);
            }
        }
    }
}

// ---------------- 合成 ----------------

/// 重绘脏区：按 z 序把各层画进后备缓冲，再搬运到帧缓冲。
/// 空闲时是空函数（无脏区不干活）。
pub fn repaint() void {
    if (!active) return;
    const r = damage;
    if (r.w <= 0 or r.h <= 0) return;
    damage = mkRect(0, 0, 0, 0);
    clip = r;

    paintDesktop();
    for (&windows) |*w| {
        if (w.visible) paintWindow(w);
    }
    paintTaskbar();
    if (menu_open) paintMenu();
    paintCursor();

    blit(r);
}

/// 后备缓冲 → 帧缓冲：只搬运脏矩形覆盖的行
fn blit(r: Rect) void {
    var y = r.y;
    while (y < r.y + r.h) : (y += 1) {
        const src: usize = @intCast(y * SCR_W + r.x);
        const w: usize = @intCast(r.w);
        const dst: [*]u32 = lfb + @as(usize, @intCast(y)) * pitch_px + @as(usize, @intCast(r.x));
        @memcpy(dst[0..w], backbuf[src .. src + w]);
    }
}

// ---------------- 输入（IRQ12 上下文调用） ----------------

/// 鼠标相对位移（dy 已换算为屏幕方向）+ 按键位图 bit0=左键
pub fn onMouseDelta(dx: i32, dy: i32, buttons: u3) void {
    if (!active) return;

    addDamage(cursorRect());
    mouse_x = @max(@min(mouse_x + dx, SCR_W - 12), 0);
    mouse_y = @max(@min(mouse_y + dy, SCR_H - 15), 0);
    addDamage(cursorRect());

    if (drag) |*d| {
        const w = &windows[d.idx];
        addDamage(winRect(w));
        w.x = @max(@min(mouse_x - d.offx, SCR_W - 24), 24 - w.w);
        w.y = @max(@min(mouse_y - d.offy, TB_Y - 24), 0);
        addDamage(winRect(w));
    }

    if (menu_open) {
        const h = hitMenuItem();
        if (h != menu_hover) {
            menu_hover = h;
            addDamage(menuRect());
        }
    }

    const left = buttons & 1 != 0;
    if (left != left_down) {
        left_down = left;
        if (left) handlePress(mouse_x, mouse_y) else drag = null;
    }

    repaint();
}

fn closeMenu() void {
    menu_open = false;
    btn_pressed = false;
    menu_hover = -1;
    addDamage(menuRect());
    addDamage(btnRect());
}

fn openAbout() void {
    const w = &windows[0];
    addDamage(winRect(w));
    w.x = @divTrunc(SCR_W - w.w, 2);
    w.y = 150;
    w.visible = true;
    addDamage(winRect(w));
}

/// 左键按下：自顶向下做命中测试
fn handlePress(x: i32, y: i32) void {
    // 1) 菜单打开时：本次点击只作用于菜单（点外面 = 收起）
    if (menu_open) {
        const m = menuRect();
        if (inRect(x, y, m)) {
            const idx = hitMenuItem();
            if (idx >= 0 and menu_items[@intCast(idx)].enabled) {
                closeMenu();
                if (idx == 0) openAbout(); // 菜单项动作表（目前只有一项）
            }
        } else {
            closeMenu();
        }
        return;
    }

    // 2) 窗口（数组倒序 = z 序自顶向下）
    var i: usize = windows.len;
    while (i > 0) {
        i -= 1;
        const w = &windows[i];
        if (!w.visible) continue;
        if (inRect(x, y, closeBoxRect(w)) or inRect(x, y, okRect(w))) {
            w.visible = false;
            addDamage(winRect(w));
            return;
        }
        if (inRect(x, y, titleRect(w)) and !inRect(x, y, sysBoxRect(w))) {
            drag = .{ .idx = i, .offx = x - w.x, .offy = y - w.y };
            return;
        }
        if (inRect(x, y, winRect(w))) return; // 客户区：吞掉点击
    }

    // 3) 任务栏 ZOS 按钮：弹出菜单
    if (inRect(x, y, btnRect())) {
        menu_open = true;
        btn_pressed = true;
        menu_hover = -1;
        addDamage(btnRect());
        addDamage(menuRect());
        return;
    }
    // 4) 桌面：无操作
}

fn hitMenuItem() i8 {
    if (!inRect(mouse_x, mouse_y, menuRect())) return -1;
    var y = menuRect().y + MENU_PAD;
    for (menu_items, 0..) |it, i| {
        const hh: i32 = if (it.sep) SEP_H else ITEM_H;
        if (mouse_y >= y and mouse_y < y + hh) return if (it.sep) -1 else @intCast(i);
        y += hh;
    }
    return -1;
}

// ---------------- 时钟（IRQ0 上下文调用） ----------------

pub fn onTick() void {
    if (!active) return;
    if (updateClock()) addDamage(clockRect());
    repaint();
}

fn readCmos(reg: u8) u8 {
    serial_outb(0x70, reg);
    return serial_inb(0x71);
}

// 端口原语直接内联（serial.zig 的 outb/inb）
const serial_outb = @import("serial.zig").outb;
const serial_inb = @import("serial.zig").inb;

fn bcd2bin(v: u8) u8 {
    return (v & 0x0F) + ((v >> 4) * 10);
}

fn rtcTime() ?struct { h: u8, m: u8 } {
    // regA bit7 = 更新进行中：等它清零再读，避免读到撕裂数据
    var spins: usize = 0;
    while (spins < 100_000) : (spins += 1) {
        if (readCmos(0x0A) & 0x80 == 0) break;
    }
    if (spins >= 100_000) return null;

    const rb = readCmos(0x0B);
    const binary = rb & 0x04 != 0;
    var s = readCmos(0x00);
    var m = readCmos(0x02);
    var h = readCmos(0x04);
    if (rb & 0x02 == 0) { // 12 小时制：bit7 = PM
        const pm = h & 0x80 != 0;
        h &= 0x7F;
        if (!binary) h = bcd2bin(h);
        if (pm and h < 12) h += 12;
        if (!pm and h == 12) h = 0;
    } else if (!binary) {
        h = bcd2bin(h);
    }
    if (!binary) {
        s = bcd2bin(s);
        m = bcd2bin(m);
    }
    return .{ .h = h, .m = m };
}

/// 秒级刷新时钟；变化了返回 true（调用方记脏区）
fn updateClock() bool {
    var h: u8 = 0;
    var m: u8 = 0;
    if (rtcTime()) |t| {
        h = t.h;
        m = t.m;
    } else {
        // 无 RTC：退化为开机 分:秒
        const s = pit.uptimeMs() / 1000;
        h = @intCast(@min(s / 60, 99));
        m = @intCast(s % 60);
    }
    clock_buf = .{
        '0' + h / 10,
        '0' + h % 10,
        ':',
        '0' + m / 10,
        '0' + m % 10,
    };
    if (std.mem.eql(u8, &clock_buf, &last_clock)) return false;
    last_clock = clock_buf;
    return true;
}

// ---------------- 初始化 ----------------

pub fn ready() bool {
    return active;
}

/// 在 vmm.init 之后、开中断之前调用（main.zig）
pub fn init() void {
    if (!multiboot.framebufferUsable()) {
        console.kprintf("gui: no usable VBE framebuffer (want 640x480x32 RGB) -- text mode\n", .{});
        return;
    }

    const fb_bytes: usize = @intCast(multiboot.fb_pitch * multiboot.fb_height);
    lfb = @ptrFromInt(vmm.mapMMIO(multiboot.fb_addr, fb_bytes));
    pitch_px = multiboot.fb_pitch / 4;

    rsh = @intCast(multiboot.fb_r_pos);
    gsh = @intCast(multiboot.fb_g_pos);
    bsh = @intCast(multiboot.fb_b_pos);
    pal = .{
        .desktop = px(0x00, 0x80, 0x80),
        .chrome = px(0xC0, 0xC0, 0xC0),
        .white = px(0xFF, 0xFF, 0xFF),
        .black = px(0, 0, 0),
        .navy = px(0x00, 0x00, 0x80),
        .shadow = px(0x80, 0x80, 0x80),
        .ltf = px(0xDF, 0xDF, 0xDF),
    };

    active = true;

    // PS/2 鼠标（失败不致命：GUI 只是没有光标输入）
    const mouse = @import("mouse.zig");
    if (mouse.init()) {
        @import("pic.zig").unmask(12);
        console.kprintf("gui: mouse on IRQ12\n", .{});
    } else {
        console.kprintf("gui: PS/2 mouse init failed\n", .{});
    }

    _ = updateClock();
    addDamage(SCREEN);
    repaint();
    console.kprintf("gui: 640x480x32 compositor up (desktop/taskbar/menu/cursor)\n", .{});
}
