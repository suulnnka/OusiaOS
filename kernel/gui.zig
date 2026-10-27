//! ZOS 图形子系统：合成器（compositor）+ Win3.1 风格桌面/任务栏/窗口管理
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
//!   - 窗口管理 vs 应用：本文件是"窗口管理器"（外框/标题栏/关闭盒/
//!     拖拽/z 序提升/任务栏按钮/开始菜单），客户区画法和点击行为在
//!     apps.zig（文件浏览器/终端镜像/扫雷/About）
//!   - z 序 = zorder 置换数组（windows 下标的一个排列）；点击窗口
//!     先提到顶端再分发事件，paint 与命中测试都沿 zorder 遍历
//!   - 线程模型：repaint 只在【中断上下文】跑（IRQ12 鼠标 / IRQ0 时钟），
//!     中断门自动关 IF，天然互斥、无需锁。唯一的跨上下文共享是
//!     addDamage（终端镜像来自进程上下文的 console.putChar）与终端
//!     行缓冲——前者用关中断的极短临界区，后者按 SPSC 环形缓冲使用
//!   - Win3.1 视觉语言：灰.chrome + 2px 斜面(bevel)、藏青标题栏、
//!     白底菜单带投影、系统菜单盒(横杠)/▼ 关闭盒

const std = @import("std");
const multiboot = @import("multiboot.zig");
const vmm = @import("vmm.zig");
const console = @import("console.zig");
const pit = @import("pit.zig");
const font = @import("font.zig");
const tty = @import("tty.zig");
const apps = @import("apps.zig");

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

pub const Pal = struct {
    desktop: u32, // 青绿桌面（老 Windows 的经典底色）
    chrome: u32, // #C0C0C0 控件灰
    white: u32,
    black: u32,
    navy: u32, // 激活标题栏
    shadow: u32, // #808080
    ltf: u32, // #DFDFDF 亮面
};
pub var pal: Pal = undefined;

pub inline fn px(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << rsh) | (@as(u32, g) << gsh) | (@as(u32, b) << bsh);
}

// 输入状态（只在鼠标中断里改）
var mouse_x: i32 = 300;
var mouse_y: i32 = 200;
var left_down = false;
var right_down = false;
var drag: ?struct { idx: usize, offx: i32, offy: i32 } = null;
/// 鼠标捕获：左键按下落在哪个窗口的客户区，按住期间的移动就归它
/// （经典 GUI 捕获语义——画图时划出窗口也继续画）
var app_capture: ?usize = null;

// 任务栏
var btn_pressed = false; // ZOS 按钮（菜单打开期间保持按下）
var clock_buf: [5]u8 = "00:00".*;
var last_clock: [5]u8 = "00:00".*;

// ---------------- 开始菜单 ----------------

var menu_open = false;
var menu_hover: i8 = -1;
const MENU_W: i32 = 148;
const ITEM_H: i32 = 18;
const SEP_H: i32 = 5;
const MENU_PAD: i32 = 3;

/// 菜单项动作：关闭菜单后打开对应应用（窗口单例）
const MenuAction = enum { about, filer, terminal, mine, paint, calc, note, none };
const MenuItem = struct {
    label: []const u8,
    enabled: bool,
    sep: bool = false,
    act: MenuAction = .none,
};
const menu_items = [_]MenuItem{
    .{ .label = "File Manager", .enabled = true, .act = .filer },
    .{ .label = "Notepad", .enabled = true, .act = .note },
    .{ .label = "Terminal", .enabled = true, .act = .terminal },
    .{ .label = "Paint", .enabled = true, .act = .paint },
    .{ .label = "Calculator", .enabled = true, .act = .calc },
    .{ .label = "Minesweeper", .enabled = true, .act = .mine },
    .{ .label = "", .enabled = false, .sep = true },
    .{ .label = "About ZOS...", .enabled = true, .act = .about },
    .{ .label = "", .enabled = false, .sep = true },
    .{ .label = "Exit GUI", .enabled = false }, // 教学演示：置灰项的画法
};

// ---------------- 窗口 ----------------

/// 窗口种类 = 客户区的行为（apps.zig 按它分发绘制与输入）
pub const WinKind = enum { about, filer, terminal, mine, paint, calc, note };

pub const Win = struct {
    visible: bool = false,
    opened: bool = false, // 打开过（任务栏按钮跟着出现，最小化也不消失）
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 292,
    h: i32 = 150,
    kind: WinKind = .about,
    title: []const u8 = "",
    tb: []const u8 = "", // 任务栏按钮短标签
    home_x: i32 = 0, // 每次打开时回归的默认位置
    home_y: i32 = 0,
};

/// 窗口表：每类应用一个单例窗口（下标恒定，drag/任务栏都引用它）
var windows = [_]Win{
    .{ .kind = .about, .title = "About ZOS", .tb = "About", .w = 292, .h = 150, .home_x = 174, .home_y = 150 },
    .{ .kind = .filer, .title = "File Manager", .tb = "Files", .w = 460, .h = 300, .home_x = 14, .home_y = 18 },
    .{ .kind = .terminal, .title = "Terminal", .tb = "Term", .w = 584, .h = 272, .home_x = 28, .home_y = 52 },
    .{ .kind = .mine, .title = "Minesweeper", .tb = "Mines", .w = 200, .h = 262, .home_x = 436, .home_y = 120 },
    .{ .kind = .paint, .title = "Paint", .tb = "Paint", .w = 470, .h = 310, .home_x = 60, .home_y = 26 },
    .{ .kind = .calc, .title = "Calculator", .tb = "Calc", .w = 190, .h = 248, .home_x = 300, .home_y = 84 },
    .{ .kind = .note, .title = "Notepad - (untitled)", .tb = "Note", .w = 520, .h = 260, .home_x = 40, .home_y = 60 },
};

/// z 序：windows 下标的排列，末位 = 最顶层。点击窗口把它的下标挪到末位
var zorder = [_]usize{ 0, 1, 2, 3, 4, 5, 6 };

pub fn windowByKind(k: WinKind) *Win {
    for (&windows) |*w| {
        if (w.kind == k) return w;
    }
    unreachable; // 每种窗口恰好一个
}

/// 活动窗口（z 序最顶的可见窗口）的种类——键盘焦点的归属
pub fn topKind() WinKind {
    return windows[topVisible()].kind;
}

/// 提到顶层（重排 zorder，全屏记脏——遮挡关系整体变化）
fn raiseWindow(wi: usize) void {
    var i: usize = 0;
    while (i < zorder.len and zorder[i] != wi) i += 1;
    if (i >= zorder.len - 1) return; // 已在顶层
    while (i < zorder.len - 1) : (i += 1) zorder[i] = zorder[i + 1];
    zorder[zorder.len - 1] = wi;
    addDamage(SCREEN);
}

/// 最顶层可见窗口的下标（活动窗口）
fn topVisible() usize {
    var i = zorder.len;
    while (i > 0) {
        i -= 1;
        if (windows[zorder[i]].visible) return zorder[i];
    }
    return 0;
}

fn showWindow(wi: usize) void {
    const w = &windows[wi];
    w.opened = true;
    w.visible = true;
    apps.onOpen(w); // 应用获知被打开（文件浏览器首次列根目录）
    raiseWindow(wi);
}

pub fn closeWin(w: *Win) void {
    addDamage(winRect(w));
    w.visible = false;
    addDamage(taskbarRect());
}

/// 开始菜单 / 任务栏按钮的入口
fn openApp(k: WinKind) void {
    const w = windowByKind(k);
    addDamage(winRect(w)); // 旧位置（若可见）
    w.x = w.home_x;
    w.y = w.home_y;
    var wi: usize = 0;
    while (windows[wi].kind != k) wi += 1;
    showWindow(wi);
}

// ---------------- 矩形与脏区 ----------------

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

pub fn mkRect(x: i32, y: i32, w: i32, h: i32) Rect {
    return .{ .x = x, .y = y, .w = w, .h = h };
}

const SCREEN = mkRect(0, 0, SCR_W, SCR_H);
var damage = mkRect(0, 0, 0, 0);
var clip: Rect = SCREEN; // 重绘期间的所有图元都被裁剪到这里

/// 当前裁剪矩形（应用自绘位图时用它跳过脏区外的像素，见 apps/paint.zig）
pub fn clipRect() Rect {
    return clip;
}

pub fn inRect(x: i32, y: i32, r: Rect) bool {
    return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h;
}

fn clampRect(r: Rect) Rect {
    const x0 = @max(r.x, 0);
    const y0 = @max(r.y, 0);
    const x1 = @min(r.x + r.w, SCR_W);
    const y1 = @min(r.y + r.h, SCR_H);
    return mkRect(x0, y0, @max(x1 - x0, 0), @max(y1 - y0, 0));
}

/// 读 RFLAGS（bit9 = IF 中断标志）
pub inline fn irqSave() u64 {
    return asm ("pushfq; popq %[v]" : [v] "=r" (-> u64));
}

pub inline fn irqRestore(flags: u64) void {
    if (flags & 0x200 != 0) asm volatile ("sti");
}

/// 记脏区：合并为包围盒（教学取舍：多个分散小脏区会合并成大矩形，
/// 正确性优先；更精细的做法是脏区列表）。
/// 终端镜像可能从【进程上下文】调用（shell printf），与 IRQ0 里的
/// repaint 存在竞态——用极短的关中断临界区把"读-改-写"做成原子
/// （IRQ 上下文里 IF 本来就是关的，等价于零开销直通）。
pub fn addDamage(r: Rect) void {
    const flags = irqSave();
    asm volatile ("cli");
    const c = clampRect(r);
    if (c.w > 0 and c.h > 0) {
        if (damage.w <= 0 or damage.h <= 0) {
            damage = c;
        } else {
            const x0 = @min(damage.x, c.x);
            const y0 = @min(damage.y, c.y);
            const x1 = @max(damage.x + damage.w, c.x + c.w);
            const y1 = @max(damage.y + damage.h, c.y + c.h);
            damage = mkRect(x0, y0, x1 - x0, y1 - y0);
        }
    }
    irqRestore(flags);
}

// ---------------- 绘制原语（apps.zig 共用；全部尊重 clip） ----------------

pub fn setPx(x: i32, y: i32, c: u32) void {
    if (x < clip.x or y < clip.y or x >= clip.x + clip.w or y >= clip.y + clip.h) return;
    backbuf[@intCast(y * SCR_W + x)] = c;
}

pub fn fillRect(r: Rect, c: u32) void {
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

pub fn hline(x0: i32, x1: i32, y: i32, c: u32) void {
    var x = x0;
    while (x <= x1) : (x += 1) setPx(x, y, c);
}

pub fn vline(x: i32, y0: i32, y1: i32, c: u32) void {
    var y = y0;
    while (y <= y1) : (y += 1) setPx(x, y, c);
}

/// 1px 斜面：raised = 顶/左亮、底/右暗；sunken 反转
pub fn bevel1(r: Rect, raised: bool) void {
    const tl = if (raised) pal.white else pal.shadow;
    const br = if (raised) pal.shadow else pal.white;
    hline(r.x, r.x + r.w - 1, r.y, tl);
    vline(r.x, r.y, r.y + r.h - 1, tl);
    hline(r.x, r.x + r.w - 1, r.y + r.h - 1, br);
    vline(r.x + r.w - 1, r.y, r.y + r.h - 1, br);
}

/// 2px 斜面：Win3.1 控件的标准立体感（外圈白/暗灰，内圈亮灰/黑）
pub fn bevel2(r: Rect, raised: bool) void {
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
pub fn text(x: i32, y: i32, s: []const u8, fg: u32) void {
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
pub fn textBold(x: i32, y: i32, s: []const u8, fg: u32) void {
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

/// 任务栏整体（窗口按钮变化时的脏区）
fn taskbarRect() Rect {
    return mkRect(0, TB_Y, SCR_W, TASKBAR_H);
}

/// 第 wi 个窗口的任务栏按钮（ZOS 按钮右侧一排；7 个正好排到时钟前）
fn taskBtnRect(wi: usize) Rect {
    const x0 = btnRect().x + btnRect().w + 22;
    return mkRect(x0 + @as(i32, @intCast(wi)) * 66, TB_Y + 3, 64, TASKBAR_H - 6);
}

fn menuHeight() i32 {
    var h = MENU_PAD * 2;
    for (menu_items) |it| {
        h += if (it.sep) SEP_H else ITEM_H;
    }
    return h;
}

fn menuRect() Rect {
    return mkRect(2, TB_Y - menuHeight() - 3, MENU_W, menuHeight());
}

pub fn winRect(w: *const Win) Rect {
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

/// 客户区：标题栏以下、外框以内（apps.zig 的画布）
pub fn clientRect(w: *const Win) Rect {
    return mkRect(w.x + 3, w.y + 28, w.w - 6, w.h - 31);
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

    // 窗口按钮：打开过的窗口各占一格（Win95 式最小化/还原）
    const top = topVisible();
    for (&windows, 0..) |*w, wi| {
        if (!w.opened) continue;
        const tb = taskBtnRect(wi);
        fillRect(tb, pal.chrome);
        const active_btn = w.visible and top == wi;
        bevel2(tb, !active_btn); // 活动窗口的按钮呈按下状
        const t_off: i32 = if (active_btn) 1 else 0;
        text(tb.x + 8 + t_off, tb.y + 1 + t_off, w.tb, pal.black);
    }

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

/// 窗口外框（WM 拥有的部分）：边框/标题栏/系统菜单盒/关闭盒。
/// 活动窗口标题栏藏青；非活动窗口灰色（键盘焦点/激活状态的视觉线索）
fn paintWindow(wi: usize, w: *const Win) void {
    fillRect(winRect(w), pal.chrome);
    bevel2(winRect(w), true);

    const tr = titleRect(w);
    fillRect(tr, if (topVisible() == wi) pal.navy else pal.chrome);

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

    textBold(tr.x + 28, tr.y + 3, w.title, pal.white);

    // 客户区：应用自己画
    apps.paintClient(w);
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
/// 空闲时是空函数（无脏区不干活）。只在 IRQ0/IRQ12/init 调用。
pub fn repaint() void {
    if (!active) return;
    const r = damage;
    if (r.w <= 0 or r.h <= 0) return;
    damage = mkRect(0, 0, 0, 0);
    clip = r;

    paintDesktop();
    for (zorder) |wi| {
        if (windows[wi].visible) paintWindow(wi, &windows[wi]);
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

/// 鼠标相对位移（dy 已换算为屏幕方向）+ 按键位图 bit0=左 bit1=右
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
        if (left) {
            handlePress(mouse_x, mouse_y);
        } else {
            if (app_capture != null) apps.onRelease();
            drag = null;
            app_capture = null;
        }
    }
    // 捕获期间的移动：归按下时命中的窗口（画图连续笔划）
    if (left_down and drag == null) {
        if (app_capture) |wi| {
            apps.onMove(&windows[wi], mouse_x, mouse_y);
        }
    }
    const right = buttons & 2 != 0;
    if (right != right_down) {
        right_down = right;
        if (right and drag == null) handleRightPress(mouse_x, mouse_y);
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

/// 左键按下：自顶向下做命中测试
fn handlePress(x: i32, y: i32) void {
    // 1) 菜单打开时：本次点击只作用于菜单（点外面 = 收起）
    if (menu_open) {
        const m = menuRect();
        if (inRect(x, y, m)) {
            const idx = hitMenuItem();
            if (idx >= 0 and menu_items[@intCast(idx)].enabled) {
                const act = menu_items[@intCast(idx)].act;
                closeMenu();
                switch (act) {
                    .about => openApp(.about),
                    .filer => openApp(.filer),
                    .terminal => openApp(.terminal),
                    .mine => openApp(.mine),
                    .paint => openApp(.paint),
                    .calc => openApp(.calc),
                    .note => openApp(.note),
                    .none => {},
                }
            }
        } else {
            closeMenu();
        }
        return;
    }

    // 2) 窗口（沿 z 序自顶向下；点中即提层，再按部位分发）
    var zi: usize = zorder.len;
    while (zi > 0) {
        zi -= 1;
        const wi = zorder[zi];
        const w = &windows[wi];
        if (!w.visible) continue;
        if (inRect(x, y, closeBoxRect(w))) {
            closeWin(w);
            return;
        }
        if (!inRect(x, y, winRect(w))) continue;
        raiseWindow(wi);
        if (inRect(x, y, titleRect(w)) and !inRect(x, y, sysBoxRect(w))) {
            drag = .{ .idx = wi, .offx = x - w.x, .offy = y - w.y };
        } else if (!inRect(x, y, titleRect(w))) {
            app_capture = wi; // 按住期间的移动归这个窗口
            apps.onPress(w, x, y); // 客户区：交给应用
        }
        return;
    }

    // 3) 任务栏：ZOS 按钮弹菜单，窗口按钮最小化/还原/提层
    if (inRect(x, y, btnRect())) {
        menu_open = true;
        btn_pressed = true;
        menu_hover = -1;
        addDamage(btnRect());
        addDamage(menuRect());
        return;
    }
    for (&windows, 0..) |*w, wi| {
        if (!w.opened) continue;
        if (!inRect(x, y, taskBtnRect(wi))) continue;
        if (!w.visible) {
            showWindow(wi); // 还原（并提层）
        } else if (topVisible() == wi) {
            closeWin(w); // 活动窗口 → 最小化
        } else {
            raiseWindow(wi); // 切到前台
        }
        addDamage(taskbarRect());
        return;
    }
    // 4) 桌面：无操作
}

/// 右键按下：只有扫雷用（插旗）。点在拖拽外的窗口客户区即转发
fn handleRightPress(x: i32, y: i32) void {
    var zi: usize = zorder.len;
    while (zi > 0) {
        zi -= 1;
        const w = &windows[zorder[zi]];
        if (!w.visible) continue;
        if (!inRect(x, y, winRect(w))) continue;
        if (!inRect(x, y, titleRect(w))) apps.onRightPress(w, x, y);
        return;
    }
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
    apps.onTick(); // 应用计时器（终端光标闪烁/扫雷秒表）
    repaint();
}

/// 控制台镜像：console.putChar 的每个字节都进终端行缓冲
/// （gui 未激活时 apps.termPutChar 也照收——开机日志一个不漏）
pub fn onConsoleChar(c: u8) void {
    apps.termPutChar(c);
    if (active) {
        const w = windowByKind(.terminal);
        if (w.visible) addDamage(clientRect(w));
    }
}

/// 键盘入口（keyboard.zig 的所有按键都走这里）。
/// 键盘焦点模型：活动窗口是记事本时按键归它；否则照旧进 tty 行规程
/// （串口 shell 的回显/控制字符行为完全不变）。0xF0..0xF3 是键盘驱动
/// 为方向键准备的私有键码，不进 tty（会污染串口行缓冲）。
pub fn onKey(c: u8) void {
    if (active and topKind() == .note and windowByKind(.note).visible) {
        apps.onKey(c);
        return;
    }
    if (c < 0xF0) tty.onInput(c);
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
    apps.init(); // 应用状态复位（此刻 tarfs 未解析，文件浏览器延迟初始化）

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
    console.kprintf("gui: 640x480x32 compositor up (desktop/taskbar/menu/windows/apps)\n", .{});
}
