//! OusiaOS 图形子系统：合成器（compositor）+ Win3.1 风格桌面/任务栏/窗口管理
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
const winsys = @import("winsys.zig");
const vfs = @import("vfs.zig");

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
/// 边缘缩放拖拽：按住的边（L/R/B 位或）+ 起始几何 + 起始鼠标位置
var resize_drag: ?struct { idx: usize, edges: u3, mx: i32, my: i32, r: Rect } = null;
/// 缩放拖拽的目标几何（幽灵框；null = 无）
var ghost_rect: ?struct { idx: usize, rect: Rect } = null;
/// 鼠标捕获：左键按下落在哪个窗口的客户区，按住期间的移动就归它
/// （经典 GUI 捕获语义——画图时划出窗口也继续画）
var app_capture: ?usize = null;

/// 双击识别：350ms 内、同窗口、±4px 内的第二次左键按下 → EV_DBL
var last_click_tick: u64 = 0;
var last_click_win: usize = 0xFFFF;
var last_click_x: i32 = 0;
var last_click_y: i32 = 0;

/// 键盘焦点窗口（= 活动窗口 topVisible 的镜像；变化时发激活/失活事件）
var focused_win: usize = 0;
const DBL_TICKS: u64 = 50; // 500ms（与 Windows 缺省一致；100Hz tick）
const DBL_SLOP: i32 = 4;

/// 屏保：无输入 idle_ticks 秒后启动；任意输入退出
var last_input_tick: u64 = 0;
var saver_on = false;
var saver_timeout_s: u32 = 90; // 0 = 禁用（/etc/ousia.conf 可调）
const Star = struct { x: i32, y: i32, sp: i32 };
var stars: [48]Star = undefined;
var saver_frame: u32 = 0;

// 任务栏
var btn_pressed = false; // OusiaOS 按钮（菜单打开期间保持按下）
var clock_buf: [5]u8 = "00:00".*;
var last_clock: [5]u8 = "00:00".*;

// ---------------- 开始菜单 ----------------

var menu_open = false;
var menu_hover: i8 = -1;
const MENU_W: i32 = 148;
const ITEM_H: i32 = 18;
const SEP_H: i32 = 5;
const MENU_PAD: i32 = 3;

// ---------------- 窗口系统菜单（标题栏左盒弹出） ----------------

var sysmenu_open = false;
var sysmenu_win: usize = 0;
var sysmenu_hover: i8 = -1;

const SysItem = enum { restore, minimize, maximize, sep, close };
const sysmenu_items = [_]SysItem{ .restore, .minimize, .maximize, .sep, .close };
const SYSMENU_W: i32 = 108;

fn sysMenuItemEnabled(it: SysItem) bool {
    const w = &windows[sysmenu_win];
    return switch (it) {
        .restore => w.maximized,
        .minimize, .close => true,
        .maximize => w.resizable and !w.maximized,
        .sep => false,
    };
}

fn sysMenuHeight() i32 {
    var h: i32 = MENU_PAD * 2;
    for (sysmenu_items) |it| {
        h += if (it == .sep) SEP_H else ITEM_H;
    }
    return h;
}

fn sysMenuRect() Rect {
    const w = &windows[sysmenu_win];
    return mkRect(w.x + 4, w.y + 26, SYSMENU_W, sysMenuHeight());
}

fn hitSysMenuItem() i8 {
    const m = sysMenuRect();
    if (!inRect(mouse_x, mouse_y, m)) return -1;
    var y = m.y + MENU_PAD;
    for (sysmenu_items, 0..) |it, i| {
        const hh: i32 = if (it == .sep) SEP_H else ITEM_H;
        if (mouse_y >= y and mouse_y < y + hh) return if (it == .sep) -1 else @intCast(i);
        y += hh;
    }
    return -1;
}

fn paintSysMenu() void {
    const m = sysMenuRect();
    fillRect(mkRect(m.x + 2, m.y + 2, m.w, m.h), pal.shadow);
    fillRect(m, pal.white);
    rectStroke(m, pal.black);
    var y = m.y + MENU_PAD;
    for (sysmenu_items, 0..) |it, i| {
        if (it == .sep) {
            hline(m.x + 2, m.x + m.w - 3, y + 2, pal.shadow);
            hline(m.x + 2, m.x + m.w - 3, y + 3, pal.white);
            y += SEP_H;
            continue;
        }
        const enabled = sysMenuItemEnabled(it);
        const hov = sysmenu_hover == @as(i8, @intCast(i)) and enabled;
        if (hov) fillRect(mkRect(m.x + 1, y, m.w - 2, ITEM_H), pal.navy);
        const label: []const u8 = switch (it) {
            .restore => "Restore",
            .minimize => "Minimize",
            .maximize => "Maximize",
            .close => "Close    Alt+F4",
            .sep => "",
        };
        const fg: u32 = if (hov) pal.white else if (enabled) pal.black else pal.shadow;
        text(m.x + 8, y + 1, label, fg);
        y += ITEM_H;
    }
}

fn closeSysMenu() void {
    if (!sysmenu_open) return;
    sysmenu_open = false;
    sysmenu_hover = -1;
    const m = sysMenuRect();
    addDamage(mkRect(m.x, m.y, m.w + 2, m.h + 2)); // 含 2px 投影
}

fn sysMenuAction(idx: usize) void {
    const wi = sysmenu_win;
    closeSysMenu();
    switch (sysmenu_items[idx]) {
        .restore => {
            if (windows[wi].maximized) toggleMaximize(wi) else raiseWindow(wi);
        },
        .minimize => minimizeWindow(wi),
        .maximize => toggleMaximize(wi),
        .close => closeWindowByUser(wi),
        .sep => {},
    }
}

/// 关闭盒/系统菜单 Close 共用：用户窗口走关闭协议，内核窗口直接关
fn closeWindowByUser(wi: usize) void {
    const w = &windows[wi];
    if (w.kind == .user) {
        addDamage(winRect(w));
        w.visible = false;
        w.opened = false;
        addDamage(taskbarRect());
        winsys.requestClose(wi);
        syncActivation();
    } else {
        closeWin(w);
    }
}

/// 菜单项动作：内核窗口直接打开；用户应用经 winsys spawn 进程
const MenuAction = enum { about, terminal, launch, none };
const MenuItem = struct {
    label: []const u8,
    enabled: bool,
    sep: bool = false,
    act: MenuAction = .none,
    path: []const u8 = "", // act == .launch 时要 spawn 的程序
};
const menu_items = [_]MenuItem{
    .{ .label = "File Manager", .enabled = true, .act = .launch, .path = "/bin/fm" },
    .{ .label = "Notepad", .enabled = true, .act = .launch, .path = "/bin/note" },
    .{ .label = "Terminal", .enabled = true, .act = .terminal },
    .{ .label = "Paint", .enabled = true, .act = .launch, .path = "/bin/paint" },
    .{ .label = "Calculator", .enabled = true, .act = .launch, .path = "/bin/calc" },
    .{ .label = "Minesweeper", .enabled = true, .act = .launch, .path = "/bin/mine" },
    .{ .label = "Control Panel", .enabled = true, .act = .launch, .path = "/bin/cpanel" },
    .{ .label = "3D Demos", .enabled = true, .act = .launch, .path = "/bin/glview" },
    .{ .label = "", .enabled = false, .sep = true },
    .{ .label = "About OusiaOS...", .enabled = true, .act = .about },
    .{ .label = "", .enabled = false, .sep = true },
    .{ .label = "Exit GUI", .enabled = false }, // 教学演示：置灰项的画法
};

// ---------------- 窗口 ----------------

/// 窗口种类：about/terminal 是内核窗口（合成器直画）；user 是用户态
/// 应用的窗口——客户区像素来自 winsys 的共享表面，输入经事件队列
pub const WinKind = enum { about, terminal, user };

/// 用户窗口在窗口表里的起始槽位（前面留给内核窗口）
pub const USER_SLOT_BASE: usize = 2;
const WIN_SLOTS: usize = 12; // 2 内核 + 10 用户（窗口槽动态化的容量上限）
const MAX_USER_WINDOWS = WIN_SLOTS - USER_SLOT_BASE;

pub const Win = struct {
    visible: bool = false,
    opened: bool = false, // 打开过（任务栏按钮跟着出现，最小化也不消失）
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 292,
    h: i32 = 150,
    kind: WinKind = .about,
    home_x: i32 = 0, // 内核窗口每次打开时回归的默认位置
    home_y: i32 = 0,
    owner_pid: u32 = 0, // user 窗口：属主进程
    title_buf: [24]u8 = @splat(0),
    title_len: usize = 0,
    // ---- 最大化 / 缩放 ----
    resizable: bool = false, // 有最大化盒、可拖边框缩放
    maximized: bool = false,
    restore_r: Rect = .{ .x = 0, .y = 0, .w = 292, .h = 150 }, // 最大化前的几何

    pub fn title(self: *const Win) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    /// 任务栏短标签：标题第一个词截到 6 字符
    pub fn tbLabel(self: *const Win, out: *[6]u8) []const u8 {
        var n: usize = 0;
        while (n < 6 and n < self.title_len and self.title_buf[n] != ' ' and self.title_buf[n] != '-') : (n += 1) {
            out[n] = self.title_buf[n];
        }
        return out[0..n];
    }
};

/// 窗口表：每类内核应用一个单例窗口；[USER_SLOT_BASE..] 给 winsys
var windows = [_]Win{
    .{ .kind = .about, .w = 292, .h = 150, .home_x = 174, .home_y = 150 },
    .{ .kind = .terminal, .w = 584, .h = 272, .home_x = 28, .home_y = 52, .resizable = true },
    .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{},
};

fn setKernelTitle(wi: usize, s: []const u8) void {
    const n = @min(s.len, windows[wi].title_buf.len);
    @memcpy(windows[wi].title_buf[0..n], s[0..n]);
    windows[wi].title_len = n;
}

/// z 序：windows 下标的排列，末位 = 最顶层。点击窗口把它的下标挪到末位
var zorder = blk: {
    var arr: [WIN_SLOTS]usize = undefined;
    for (0..WIN_SLOTS) |i| arr[i] = i;
    break :blk arr;
};

pub fn windowByKind(k: WinKind) *Win {
    for (&windows) |*w| {
        if (w.kind == k and k != .user) return w;
    }
    unreachable; // 内核窗口恰好各一个
}

/// 提到顶层（重排 zorder，全屏记脏——遮挡关系整体变化）
fn raiseWindow(wi: usize) void {
    var i: usize = 0;
    while (i < zorder.len and zorder[i] != wi) i += 1;
    if (i >= zorder.len - 1) {
        syncActivation();
        return; // 已在顶层
    }
    while (i < zorder.len - 1) : (i += 1) zorder[i] = zorder[i + 1];
    zorder[zorder.len - 1] = wi;
    addDamage(SCREEN);
    syncActivation();
}

/// 键盘焦点跟随 z 序顶端：变化时给用户窗口发 ACTIVATE/DEACTIVATE
/// （应用据此显示/隐藏插入光标）。内核窗口（终端）不收事件。
fn syncActivation() void {
    const top = topVisible();
    if (top == focused_win) return;
    if (focused_win >= USER_SLOT_BASE) {
        pushUserEvent(focused_win, .{ .kind = winsys.EV_DEACTIVATE, .x = 0, .y = 0, .code = 0, ._pad = 0, ._pad2 = 0 });
    }
    focused_win = top;
    if (focused_win >= USER_SLOT_BASE) {
        pushUserEvent(focused_win, .{ .kind = winsys.EV_ACTIVATE, .x = 0, .y = 0, .code = 0, ._pad = 0, ._pad2 = 0 });
    }
}

fn pushUserEvent(wi: usize, ev: winsys.WinEvent) void {
    if (wi < USER_SLOT_BASE or wi >= windows.len) return;
    winsys.push(wi, ev);
}

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
    raiseWindow(wi);
}

pub fn closeWin(w: *Win) void {
    addDamage(winRect(w));
    w.visible = false;
    w.maximized = false;
    addDamage(taskbarRect());
    syncActivation();
}

/// 最大化/还原切换（系统菜单、最大化盒共用）。
/// 用户窗口：表面随客户区重分配（EV_RESIZE 让应用重画）；
/// 内核窗口（终端）：paint 按客户区尺寸自适应行列。
fn toggleMaximize(wi: usize) void {
    const w = &windows[wi];
    addDamage(winRect(w));
    if (w.maximized) {
        w.x = w.restore_r.x;
        w.y = w.restore_r.y;
        w.w = w.restore_r.w;
        w.h = w.restore_r.h;
        w.maximized = false;
        if (w.kind == .user) {
            _ = winsys.resizeSlot(wi, w.w - 6, w.h - 31);
        }
    } else {
        w.restore_r = .{ .x = w.x, .y = w.y, .w = w.w, .h = w.h };
        w.x = 0;
        w.y = 0;
        w.w = SCR_W;
        w.h = TB_Y;
        w.maximized = true;
        if (w.kind == .user) {
            _ = winsys.resizeSlot(wi, SCR_W - 6, TB_Y - 31);
        }
    }
    addDamage(SCREEN);
}

/// 最小化（系统菜单/任务栏按钮）：藏窗口，焦点交给下一个
fn minimizeWindow(wi: usize) void {
    const w = &windows[wi];
    addDamage(winRect(w));
    w.visible = false;
    addDamage(taskbarRect());
    syncActivation();
}

/// 开始菜单 / 任务栏的入口（内核窗口）
fn openApp(k: WinKind) void {
    const w = windowByKind(k);
    addDamage(winRect(w)); // 旧位置（若可见）
    w.x = w.home_x;
    w.y = w.home_y;
    var wi: usize = 0;
    while (windows[wi].kind != k) wi += 1;
    showWindow(wi);
}

// ---------------- 用户窗口管理（winsys 调用） ----------------

/// 用户应用 win_create：登记窗口并显示（级联摆位，避免全叠一起）
pub fn createUserWindow(widx: usize, cw: i32, ch: i32, pid: u32, title: []const u8) void {
    const wi = USER_SLOT_BASE + widx;
    const w = &windows[wi];
    const n = @min(title.len, w.title_buf.len);
    @memcpy(w.title_buf[0..n], title[0..n]);
    w.title_len = n;
    w.kind = .user;
    w.owner_pid = pid;
    w.resizable = true;
    w.maximized = false;
    w.w = cw + 6;
    w.h = ch + 31;
    w.x = 24 + @as(i32, @intCast(widx)) * 24;
    w.y = 14 + @as(i32, @intCast(widx)) * 22;
    showWindow(wi);
}

/// 用户窗口消失（进程退出/关闭盒）：清状态并通知任务栏
pub fn destroyUserWindow(wi: usize) void {
    if (wi < USER_SLOT_BASE or wi >= windows.len) return;
    const w = &windows[wi];
    if (app_capture == wi) app_capture = null;
    if (drag != null and drag.?.idx == wi) drag = null;
    if (resize_drag) |rd| {
        if (rd.idx == wi) resize_drag = null;
    }
    ghost_rect = null;
    closeWin(w);
    w.opened = false;
    w.kind = .user;
    w.owner_pid = 0;
    w.resizable = false;
    syncActivation();
}

/// win_present：整块客户区记脏（重绘在 IRQ0 里做）
pub fn damageUserWindow(wi: usize) void {
    const w = &windows[wi];
    if (w.visible) addDamage(clientRect(w));
}

/// win_title：改标题（标题栏 + 任务栏按钮都记脏）
pub fn setWindowTitle(wi: usize, title: []const u8) void {
    if (wi >= windows.len) return;
    const w = &windows[wi];
    const n = @min(title.len, w.title_buf.len);
    @memcpy(w.title_buf[0..n], title[0..n]);
    w.title_len = n;
    if (w.visible) {
        addDamage(titleRect(w));
        addDamage(taskbarRect());
    }
}

/// 表面重分配完成（winsys.resizeSlot）：外框跟着新客户区走
pub fn resizeUserWindow(wi: usize, cw: i32, ch: i32) void {
    if (wi < USER_SLOT_BASE or wi >= windows.len) return;
    const w = &windows[wi];
    addDamage(winRect(w));
    w.w = cw + 6;
    w.h = ch + 31;
    if (w.maximized) {
        // 最大化状态下的 resize 来自 WM 自己：恢复基准也要跟上
        w.restore_r.w = cw + 6;
        w.restore_r.h = ch + 31;
    }
    addDamage(winRect(w));
}

/// 提升某进程名下所有可见窗口（保留：进程管理工具用）
pub fn raiseWindowsOfPid(pid: u32) void {
    for (&windows, 0..) |*w, wi| {
        if (w.kind == .user and w.owner_pid == pid and w.visible) raiseWindow(wi);
    }
}

/// winsys 合成搬运：一行表面像素 → 后备缓冲（setPx 自带 clip）
pub fn blitRun(src: []const u32, x: i32, y: i32) void {
    var i: i32 = 0;
    while (i < src.len) : (i += 1) setPx(x + i, y, src[@intCast(i)]);
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

/// 多档字号：8x16 基底 × 整数最近邻（1..4）——About 大标题等
pub fn textScaled(x: i32, y: i32, s: []const u8, fg: u32, scale: i32) void {
    const sc: u5 = @intCast(@max(1, @min(scale, 4)));
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
                if (b & 0x80 != 0) {
                    var yy: i32 = 0;
                    while (yy < sc) : (yy += 1) {
                        var xx: i32 = 0;
                        while (xx < sc) : (xx += 1) {
                            setPx(cx + rx * sc + xx, y + @as(i32, @intCast(ry)) * sc + yy, fg);
                        }
                    }
                }
                rx += 1;
            }
        }
        cx += font.W * sc;
    }
}

// ---------------- 图层几何 ----------------

fn btnRect() Rect {
    return mkRect(4, TB_Y + 3, 84, TASKBAR_H - 6);
}

fn clockRect() Rect {
    return mkRect(SCR_W - 4 - 60, TB_Y + 3, 60, TASKBAR_H - 6);
}

/// 任务栏整体（窗口按钮变化时的脏区）
fn taskbarRect() Rect {
    return mkRect(0, TB_Y, SCR_W, TASKBAR_H);
}

/// 第 k 个【已打开】窗口的任务栏按钮（按钮随开窗动态排列，最多
/// TB_MAX 挤满一排；返回 null 表示窗口没有自己的按钮）
const TB_MAX = 7;
fn taskBtnOrdinal(wi: usize) ?usize {
    var ord: usize = 0;
    for (&windows, 0..) |*w, k| {
        if (!w.opened) continue;
        if (k == wi) return ord;
        ord += 1;
    }
    return null;
}

fn taskBtnRect(ord: usize) Rect {
    const x0 = btnRect().x + btnRect().w + 22;
    return mkRect(x0 + @as(i32, @intCast(ord)) * 66, TB_Y + 3, 64, TASKBAR_H - 6);
}

/// 命中测试：屏幕坐标 → 拥有该按钮的窗口下标（无则 null）
fn taskBtnHit(x: i32, y: i32) ?usize {
    if (y < TB_Y + 3 or y >= TB_Y + 3 + TASKBAR_H - 6) return null;
    var ord: usize = 0;
    for (&windows, 0..) |*w, wi| {
        if (!w.opened) continue;
        if (ord >= TB_MAX) break;
        if (inRect(x, y, taskBtnRect(ord))) return wi;
        ord += 1;
    }
    return null;
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

/// 最大化盒（关闭盒左边；可缩放窗口才有）
fn maxBoxRect(w: *const Win) Rect {
    return mkRect(w.x + w.w - 7 - 18 - 20, w.y + 5, 18, 18);
}

fn closeBoxRect(w: *const Win) Rect {
    return mkRect(w.x + w.w - 7 - 18, w.y + 5, 18, 18);
}

/// resize 边缘带：窗口矩形外缘 5px（上边不缩放——那是标题栏拖动）
const EDGE_NONE: u3 = 0;
const EDGE_L: u3 = 1;
const EDGE_R: u3 = 2;
const EDGE_B: u3 = 4;

fn edgeAt(w: *const Win, x: i32, y: i32) u3 {
    if (!w.resizable) return EDGE_NONE;
    const r = winRect(w);
    if (!inRect(x, y, mkRect(r.x - 4, r.y, r.w + 8, r.h + 4))) return EDGE_NONE;
    if (y < r.y + 24) return EDGE_NONE; // 顶部交给标题栏
    var e: u3 = 0;
    if (x < r.x + 5) e |= EDGE_L;
    if (x >= r.x + r.w - 5) e |= EDGE_R;
    if (y >= r.y + r.h - 5) e |= EDGE_B;
    return e;
}

/// 客户区：标题栏以下、外框以内（apps.zig 的画布）
pub fn clientRect(w: *const Win) Rect {
    return mkRect(w.x + 3, w.y + 28, w.w - 6, w.h - 31);
}

fn cursorRect() Rect {
    return mkRect(mouse_x, mouse_y, 12, 15);
}

// ---------------- 桌面图标 ----------------

/// 图标动作：内核窗口 / spawn 用户程序
const IconAction = enum { terminal, launch };
const DeskIcon = struct {
    label: []const u8,
    act: IconAction,
    path: []const u8 = "",
};
const desk_icons = [_]DeskIcon{
    .{ .label = "Files", .act = .launch, .path = "/bin/fm" },
    .{ .label = "Notepad", .act = .launch, .path = "/bin/note" },
    .{ .label = "Paint", .act = .launch, .path = "/bin/paint" },
    .{ .label = "Mines", .act = .launch, .path = "/bin/mine" },
    .{ .label = "Calc", .act = .launch, .path = "/bin/calc" },
    .{ .label = "Control Panel", .act = .launch, .path = "/bin/cpanel" },
    .{ .label = "Terminal", .act = .terminal },
    .{ .label = "3D Demos", .act = .launch, .path = "/bin/glview" },
};
const ICON_W: i32 = 76;
const ICON_STEP_Y: i32 = 76;
const ICON_COL_STEP: i32 = 78;
const ICON_AREA_X: i32 = 8;
const ICON_AREA_Y: i32 = 8;

/// 图标格（左上原点，竖排再换列）
fn iconRect(i: usize) Rect {
    const col: i32 = @intCast(i / 6);
    const row: i32 = @intCast(i % 6);
    return mkRect(ICON_AREA_X + col * ICON_COL_STEP, ICON_AREA_Y + row * ICON_STEP_Y, ICON_W, 64);
}

var icon_sel: i8 = -1; // 单击选中的图标（高亮）

/// 命中桌面图标；无命中返回 -1
fn hitIcon(x: i32, y: i32) i8 {
    for (desk_icons, 0..) |_, i| {
        if (inRect(x, y, iconRect(i))) return @intCast(i);
    }
    return -1;
}

fn launchIcon(i: usize) void {
    const ic = desk_icons[i];
    switch (ic.act) {
        .terminal => openApp(.terminal),
        .launch => winsys.launchApp(ic.path),
    }
}

// ---------------- 壁纸 ----------------

var wallpaper: u32 = 0; // 桌面底色（init 里按帧缓冲格式打包）

fn paintDesktop() void {
    fillRect(SCREEN, wallpaper);
    // 图标（16 色系统调色板风格：黄色文件夹/纸页 + 白描边，下面白字标签）
    for (desk_icons, 0..) |ic, i| {
        const r = iconRect(i);
        const sel = icon_sel == @as(i8, @intCast(i));
        if (sel) {
            // Win95 式选中：标签底染藏青 + 图标蒙一层藏青点阵（这里用半调方块）
            fillRect(mkRect(r.x, r.y, ICON_W, 60), pal.navy);
        }
        drawDeskGlyph(r.x + (ICON_W - 32) / 2, r.y + 4, i);
        const lw: i32 = @intCast(ic.label.len * 8);
        const lx = r.x + @divTrunc(ICON_W - lw, 2);
        if (sel) {
            text(lx, r.y + 44, ic.label, pal.white);
        } else {
            text(lx + 1, r.y + 45, ic.label, pal.black);
            text(lx, r.y + 44, ic.label, pal.white);
        }
    }
}

/// 桌面图标位图（32x32 区域内画一个 16 色小图）：
/// 0=Files 文件夹 1..4=文档/画板/地雷/计算器（简化同款纸页+色条）
fn drawDeskGlyph(x: i32, y: i32, i: usize) void {
    switch (i) {
        0 => { // 文件夹
            fillRect(mkRect(x + 6, y + 6, 10, 3), px(228, 200, 88));
            fillRect(mkRect(x + 2, y + 9, 28, 17), px(255, 224, 96));
            hline(x + 2, x + 29, y + 9, pal.black);
            vline(x + 2, y + 9, y + 25, pal.black);
            vline(x + 29, y + 9, y + 25, pal.black);
            hline(x + 2, x + 29, y + 26, pal.black);
        },
        1 => { // Notepad 纸页
            drawPageGlyph(x, y, px(255, 255, 255));
        },
        2 => { // Paint 调色板
            ellipseFill(mkRect(x + 4, y + 6, 26, 22), px(255, 224, 96));
            fillRect(mkRect(x + 10, y + 11, 5, 5), px(255, 0, 0));
            fillRect(mkRect(x + 18, y + 11, 5, 5), px(0, 128, 0));
            fillRect(mkRect(x + 10, y + 19, 5, 5), px(0, 0, 255));
            fillRect(mkRect(x + 18, y + 19, 5, 5), pal.black);
        },
        3 => { // Mine 地雷
            fillRect(mkRect(x + 12, y + 8, 8, 18), pal.black);
            fillRect(mkRect(x + 8, y + 12, 16, 10), pal.black);
            fillRect(mkRect(x + 14, y + 4, 1, 4), pal.black);
            fillRect(mkRect(x + 12, y + 12, 3, 3), pal.white);
        },
        4 => { // Calc 计算器
            fillRect(mkRect(x + 8, y + 4, 18, 26), px(224, 224, 224));
            fillRect(mkRect(x + 10, y + 6, 14, 6), px(128, 160, 128));
            for (0..3) |rr| {
                for (0..3) |cc| {
                    fillRect(mkRect(x + 10 + @as(i32, @intCast(cc)) * 5, y + 15 + @as(i32, @intCast(rr)) * 5, 4, 4), pal.shadow);
                }
            }
        },
        5 => { // Control Panel 滑杆面板
            fillRect(mkRect(x + 5, y + 5, 24, 24), px(224, 224, 224));
            hline(x + 8, x + 26, y + 12, pal.shadow);
            hline(x + 8, x + 26, y + 20, pal.shadow);
            fillRect(mkRect(x + 12, y + 9, 5, 7), pal.navy);
            fillRect(mkRect(x + 20, y + 17, 5, 7), px(255, 0, 0));
        },
        6 => { // Terminal 屏幕窗口
            fillRect(mkRect(x + 3, y + 7, 26, 18), pal.black);
            fillRect(mkRect(x + 5, y + 9, 22, 12), px(0, 64, 0));
            fillRect(mkRect(x + 7, y + 11, 10, 2), px(0, 192, 0));
            fillRect(mkRect(x + 7, y + 15, 14, 2), px(0, 192, 0));
        },
        else => { // 3D Demos 立方体
            line3(x + 16, y + 5, x + 27, y + 11);
            line3(x + 16, y + 5, x + 5, y + 11);
            line3(x + 5, y + 11, x + 5, y + 23);
            line3(x + 27, y + 11, x + 27, y + 23);
            line3(x + 5, y + 23, x + 16, y + 29);
            line3(x + 27, y + 23, x + 16, y + 29);
            line3(x + 16, y + 5, x + 16, y + 17);
            line3(x + 5, y + 11, x + 16, y + 17);
            line3(x + 27, y + 11, x + 16, y + 17);
            line3(x + 16, y + 17, x + 16, y + 29);
        },
    }
}

fn drawPageGlyph(x: i32, y: i32, paper: u32) void {
    fillRect(mkRect(x + 7, y + 4, 18, 26), paper);
    rectStroke(mkRect(x + 7, y + 4, 18, 26), pal.black);
    for (0..4) |ln| {
        hline(x + 10, x + 21, y + 9 + @as(i32, @intCast(ln)) * 5, pal.shadow);
    }
}

/// 1px 空心矩形（图标描边用）
fn rectStroke(r: Rect, c: u32) void {
    hline(r.x, r.x + r.w - 1, r.y, c);
    hline(r.x, r.x + r.w - 1, r.y + r.h - 1, c);
    vline(r.x, r.y, r.y + r.h - 1, c);
    vline(r.x + r.w - 1, r.y, r.y + r.h - 1, c);
}

fn line3(x0: i32, y0: i32, x1: i32, y1: i32) void {
    var x = x0;
    var y = y0;
    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        setPx(x, y, pal.black);
        if (x == x1 and y == y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y += sy;
        }
    }
}

/// 实心椭圆（扫描线，图标上色用）
fn ellipseFill(r: Rect, c: u32) void {
    const cx: f32 = @as(f32, @floatFromInt(r.x)) + @as(f32, @floatFromInt(r.w)) / 2.0 - 0.5;
    const cy: f32 = @as(f32, @floatFromInt(r.y)) + @as(f32, @floatFromInt(r.h)) / 2.0 - 0.5;
    const rx: f32 = @as(f32, @floatFromInt(r.w)) / 2.0;
    const ry: f32 = @as(f32, @floatFromInt(r.h)) / 2.0;
    var yy = r.y;
    while (yy < r.y + r.h) : (yy += 1) {
        const fy = (@as(f32, @floatFromInt(yy)) - cy) / ry;
        const t = 1.0 - fy * fy;
        if (t <= 0) continue;
        const half = @sqrt(t) * rx;
        hline(@intFromFloat(cx - half), @intFromFloat(cx + half), yy, c);
    }
}

fn paintTaskbar() void {
    fillRect(mkRect(0, TB_Y, SCR_W, TASKBAR_H), pal.chrome);
    hline(0, SCR_W - 1, TB_Y, pal.white); // 顶缘亮线（凸出感）

    // OusiaOS 按钮：菜单打开期间保持"按下"
    const b = btnRect();
    fillRect(b, pal.chrome);
    bevel2(b, !btn_pressed);
    const off: i32 = if (btn_pressed) 1 else 0;
    textBold(b.x + 14 + off, b.y + 1 + off, "OusiaOS", pal.black);

    // 按钮右侧的蚀刻分隔线（暗+亮 = 凹槽）
    vline(b.x + b.w + 8, TB_Y + 4, TB_Y + TASKBAR_H - 5, pal.shadow);
    vline(b.x + b.w + 9, TB_Y + 4, TB_Y + TASKBAR_H - 5, pal.white);

    // 窗口按钮：打开过的窗口各占一格（Win95 式最小化/还原；动态排列）
    const top = topVisible();
    var ord: usize = 0;
    for (&windows, 0..) |*w, wi| {
        if (!w.opened) continue;
        if (ord >= TB_MAX) break;
        const tb = taskBtnRect(ord);
        ord += 1;
        fillRect(tb, pal.chrome);
        const active_btn = w.visible and top == wi;
        bevel2(tb, !active_btn); // 活动窗口的按钮呈按下状
        var lbl: [6]u8 = undefined;
        const ls = w.tbLabel(&lbl);
        const t_off: i32 = if (active_btn) 1 else 0;
        text(tb.x + 8 + t_off, tb.y + 1 + t_off, ls, pal.black);
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

/// 窗口外框（WM 拥有的部分）：边框/标题栏/系统菜单盒/最大化盒/关闭盒。
/// 活动窗口标题栏藏青；非活动窗口灰色（键盘焦点/激活状态的视觉线索）。
/// 客户区：内核窗口由 apps.zig 画；用户窗口 blit 共享表面（winsys）。
fn paintWindow(wi: usize, w: *const Win) void {
    fillRect(winRect(w), pal.chrome);
    bevel2(winRect(w), true);

    const tr = titleRect(w);
    fillRect(tr, if (topVisible() == wi) pal.navy else pal.chrome);

    // 系统菜单盒（左，横杠图标）
    const sb = sysBoxRect(w);
    fillRect(sb, pal.chrome);
    bevel1(sb, true);
    fillRect(mkRect(sb.x + 4, sb.y + 8, 10, 2), pal.black);

    // 最大化盒（▲/还原 双三角；不可缩放窗口不画）
    if (w.resizable) {
        const mb = maxBoxRect(w);
        fillRect(mb, pal.chrome);
        bevel1(mb, true);
        const mx = mb.x + 9;
        const my = mb.y + 8;
        if (!w.maximized) {
            fillRect(mkRect(mx - 1, my - 1, 3, 1), pal.black);
            fillRect(mkRect(mx - 2, my, 5, 1), pal.black);
            fillRect(mkRect(mx - 3, my + 1, 7, 1), pal.black);
            fillRect(mkRect(mx - 3, my + 2, 7, 2), pal.black);
        } else {
            // 还原：两个错位小窗
            rectStroke(mkRect(mx - 4, my - 1, 7, 6), pal.black);
            rectStroke(mkRect(mx - 2, my + 1, 7, 6), pal.black);
            fillRect(mkRect(mx - 1, my, 5, 1), pal.chrome);
        }
    }

    // 关闭盒（右，▼ 图标）
    const cb = closeBoxRect(w);
    fillRect(cb, pal.chrome);
    bevel1(cb, true);
    const cx = cb.x + 9; // ▼ 顶点中心
    fillRect(mkRect(cx - 3, cb.y + 6, 7, 1), pal.black);
    fillRect(mkRect(cx - 2, cb.y + 7, 5, 1), pal.black);
    fillRect(mkRect(cx - 1, cb.y + 8, 3, 1), pal.black);
    fillRect(mkRect(cx, cb.y + 9, 1, 1), pal.black);

    textBold(tr.x + 28, tr.y + 3, w.title(), pal.white);

    // 客户区
    if (w.kind == .user) {
        // 只搬运 clip ∩ 客户区 的行；行内再按 clip 截左右
        const cr = clientRect(w);
        const y0 = @max(cr.y, clip.y);
        const y1 = @min(cr.y + cr.h, clip.y + clip.h);
        const sx0 = @max(cr.x, clip.x) - cr.x;
        const sx1 = @min(cr.x + cr.w, clip.x + clip.w) - cr.x;
        var y = y0;
        while (y < y1) : (y += 1) {
            winsys.blitRow(wi, y - cr.y, sx0, sx1, cr.x + sx0, y);
        }
    } else {
        apps.paintClient(w);
    }

    // resize 拖拽中的"幽灵框"：目标几何的 2px 藏青描边（拖动期间
    // 表面不真重分配，松手才一次性 resize——预览画在最上层窗口之后）
    if (ghost_rect) |g| {
        if (g.idx == wi) {
            const gr = g.rect;
            rectStroke(mkRect(gr.x - 1, gr.y - 1, gr.w + 2, gr.h + 2), pal.navy);
            rectStroke(mkRect(gr.x - 2, gr.y - 2, gr.w + 4, gr.h + 4), pal.navy);
        }
    }
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
    if (saver_on) {
        // 屏保独占整屏（进入时全屏清黑；此后只按星点小脏区动画）
        const r = damage;
        if (r.w <= 0 or r.h <= 0) return;
        damage = mkRect(0, 0, 0, 0);
        clip = r;
        paintSaverFrame();
        blit(r);
        return;
    }
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
    if (sysmenu_open) paintSysMenu();
    paintCursor();

    blit(r);
}

// ---------------- 屏保（星场） ----------------

fn saverStart() void {
    saver_on = true;
    saver_frame = 0;
    var rng: u32 = 0x1234_5678;
    for (&stars) |*s| {
        rng = rng *% 1103515245 +% 12345;
        s.x = @intCast((rng >> 16) % @as(u32, @intCast(SCR_W)));
        rng = rng *% 1103515245 +% 12345;
        s.y = @intCast((rng >> 16) % @as(u32, @intCast(TB_Y)));
        s.sp = @intCast(1 + (rng >> 8) % 4);
    }
    addDamage(SCREEN);
}

fn saverStop() void {
    saver_on = false;
    last_input_tick = pit.ticks;
    addDamage(SCREEN);
}

/// 每 tick 动画：星星右移（3 档速度=视差），出界回绕
fn paintSaverFrame() void {
    for (&stars) |*s| {
        // 擦旧点
        setPx(s.x, s.y, pal.black);
        setPx(s.x + 1, s.y, pal.black);
        s.x += s.sp;
        if (s.x >= SCR_W) {
            s.x = 0;
            var rng: u32 = @truncate(pit.ticks *% 2654435761 +% @as(u32, @intCast(s.sp)));
            rng = rng *% 1103515245 +% 12345;
            s.y = @intCast((rng >> 8) % @as(u32, @intCast(TB_Y)));
        }
        const c: u32 = switch (@as(u32, @intCast(s.sp))) {
            1 => px(96, 96, 96),
            2 => px(160, 160, 160),
            else => px(255, 255, 255),
        };
        setPx(s.x, s.y, c);
        setPx(s.x + 1, s.y, c);
    }
    // 角落一行标题（暗灰，低存在感）
    saver_frame +%= 1;
    if (saver_frame % 100 == 0) {
        addDamage(mkRect(SCR_W - 200, SCR_H - 40, 192, 16));
    }
    if (saver_frame % 100 >= 95) text(SCR_W - 196, SCR_H - 40, "OusiaOS -- idle", px(64, 64, 64));
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
    last_input_tick = pit.ticks;
    if (saver_on) {
        saverStop();
        return;
    }

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
    } else if (resize_drag) |*rd| {
        updateGhost(rd);
    }

    if (menu_open) {
        const h = hitMenuItem();
        if (h != menu_hover) {
            menu_hover = h;
            addDamage(menuRect());
        }
    } else if (sysmenu_open) {
        const h = hitSysMenuItem();
        if (h != sysmenu_hover) {
            sysmenu_hover = h;
            addDamage(sysMenuRect());
        }
    }

    const left = buttons & 1 != 0;
    if (left != left_down) {
        left_down = left;
        if (left) {
            handlePress(mouse_x, mouse_y);
        } else {
            if (resize_drag) |rd| {
                finishResize(rd);
            }
            if (app_capture) |wi| {
                const w = &windows[wi];
                if (w.kind == .user and w.visible) {
                    const cr = clientRect(w);
                    winsys.push(wi, .{ .kind = winsys.EV_RELEASE, .x = @intCast(mouse_x - cr.x), .y = @intCast(mouse_y - cr.y), .code = 0, ._pad = 0, ._pad2 = 0 });
                }
                apps.onRelease();
            }
            drag = null;
            app_capture = null;
        }
    }
    // 捕获期间的移动：归按下时命中的窗口（画图连续笔划；用户窗口
    // 收到的是客户区坐标，可能为负——应用自行裁剪）
    if (left_down and drag == null and resize_drag == null) {
        if (app_capture) |wi| {
            const w = &windows[wi];
            if (w.kind == .user and w.visible) {
                const cr = clientRect(w);
                winsys.push(wi, .{ .kind = winsys.EV_MOVE, .x = @intCast(mouse_x - cr.x), .y = @intCast(mouse_y - cr.y), .code = 0, ._pad = 0, ._pad2 = 0 });
            }
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

/// 缩放拖拽中：按边缘位更新幽灵框几何（min 160x80 客户区）
fn updateGhost(rd: anytype) void {
    const start = rd.r;
    var x = start.x;
    const y = start.y;
    var ww = start.w;
    var hh = start.h;
    const mdx = mouse_x - rd.mx;
    const mdy = mouse_y - rd.my;
    if (rd.edges & EDGE_L != 0) {
        x = start.x + mdx;
        ww = start.w - mdx;
    }
    if (rd.edges & EDGE_R != 0) ww = start.w + mdx;
    if (rd.edges & EDGE_B != 0) hh = start.h + mdy;
    const MIN_W: i32 = 160;
    const MIN_H: i32 = 96;
    if (ww < MIN_W) {
        if (rd.edges & EDGE_L != 0) x = start.x + start.w - MIN_W;
        ww = MIN_W;
    }
    if (hh < MIN_H) hh = MIN_H;
    if (hh > TB_Y - y) hh = TB_Y - y;
    const nr = mkRect(x, y, ww, hh);
    const changed = ghost_rect == null or blk: {
        const g = ghost_rect.?;
        break :blk g.rect.x != nr.x or g.rect.y != nr.y or g.rect.w != nr.w or g.rect.h != nr.h;
    };
    if (changed) {
        if (ghost_rect) |g| addDamage(mkRect(g.rect.x - 4, g.rect.y - 4, g.rect.w + 8, g.rect.h + 8));
        ghost_rect = .{ .idx = rd.idx, .rect = nr };
        addDamage(mkRect(nr.x - 4, nr.y - 4, nr.w + 8, nr.h + 8));
        repaint();
    }
}

/// 松手落锤：内核窗口直接改几何；用户窗口改外框 + 表面重分配
fn finishResize(rd: anytype) void {
    const g = ghost_rect orelse {
        resize_drag = null;
        return;
    };
    const nr = g.rect;
    ghost_rect = null;
    resize_drag = null;
    const wi = rd.idx;
    const w = &windows[wi];
    addDamage(mkRect(nr.x - 4, nr.y - 4, nr.w + 8, nr.h + 8));
    addDamage(winRect(w));
    w.maximized = false;
    w.x = nr.x;
    w.y = nr.y;
    w.w = nr.w;
    w.h = nr.h;
    if (w.kind == .user) {
        _ = winsys.resizeSlot(wi, w.w - 6, w.h - 31);
    } else {
        addDamage(SCREEN); // 终端自适应新行列
    }
    addDamage(winRect(w));
}

fn closeMenu() void {
    menu_open = false;
    btn_pressed = false;
    menu_hover = -1;
    const m = menuRect();
    addDamage(mkRect(m.x, m.y, m.w + 2, m.h + 2)); // 含右/下 2px 投影
    addDamage(btnRect());
}

/// 左键按下：自顶向下做命中测试
fn handlePress(x: i32, y: i32) void {
    // 1) 系统菜单打开：点击只作用于它
    if (sysmenu_open) {
        const m = sysMenuRect();
        if (inRect(x, y, m)) {
            const idx = hitSysMenuItem();
            if (idx >= 0 and sysMenuItemEnabled(sysmenu_items[@intCast(idx)])) {
                sysMenuAction(@intCast(idx));
            } else {
                closeSysMenu();
            }
        } else {
            closeSysMenu();
        }
        return;
    }

    // 2) 开始菜单打开：本次点击只作用于菜单（点外面 = 收起）
    if (menu_open) {
        const m = menuRect();
        if (inRect(x, y, m)) {
            const idx = hitMenuItem();
            if (idx >= 0 and menu_items[@intCast(idx)].enabled) {
                const it = menu_items[@intCast(idx)];
                closeMenu();
                switch (it.act) {
                    .about => openApp(.about),
                    .terminal => openApp(.terminal),
                    .launch => winsys.launchApp(it.path), // spawn 用户进程（IF=0 安全）
                    .none => {},
                }
            }
        } else {
            closeMenu();
        }
        return;
    }

    // 3) 窗口（沿 z 序自顶向下；点中即提层，再按部位分发）
    var zi: usize = zorder.len;
    while (zi > 0) {
        zi -= 1;
        const wi = zorder[zi];
        const w = &windows[wi];
        if (!w.visible) continue;

        // 边缘缩放带优先（比标题栏更靠外的命中）
        const edges = edgeAt(w, x, y);
        if (edges != EDGE_NONE) {
            raiseWindow(wi);
            resize_drag = .{ .idx = wi, .edges = edges, .mx = x, .my = y, .r = winRect(w) };
            ghost_rect = .{ .idx = wi, .rect = winRect(w) };
            return;
        }
        if (inRect(x, y, closeBoxRect(w))) {
            closeWindowByUser(wi);
            return;
        }
        if (w.resizable and inRect(x, y, maxBoxRect(w))) {
            toggleMaximize(wi);
            return;
        }
        if (!inRect(x, y, winRect(w))) continue;
        raiseWindow(wi);

        if (inRect(x, y, sysBoxRect(w))) {
            // 系统菜单盒：弹出（再点一次 = 收起）
            if (sysmenu_open and sysmenu_win == wi) {
                closeSysMenu();
            } else {
                closeSysMenu();
                sysmenu_open = true;
                sysmenu_win = wi;
                sysmenu_hover = -1;
                addDamage(sysMenuRect());
            }
            return;
        }
        if (inRect(x, y, titleRect(w))) {
            if (!w.maximized) drag = .{ .idx = wi, .offx = x - w.x, .offy = y - w.y };
            return;
        }

        // 客户区/任务栏按钮
        if (w.kind == .user) {
            const cr = clientRect(w);
            const cx = x - cr.x;
            const cy = y - cr.y;
            // 双击识别（同窗口、±4px、350ms 内的第二次按下）
            const is_dbl = last_click_win == wi and
                pit.ticks - last_click_tick <= DBL_TICKS and
                @abs(cx - last_click_x) <= DBL_SLOP and @abs(cy - last_click_y) <= DBL_SLOP;
            last_click_win = wi;
            last_click_tick = pit.ticks;
            last_click_x = cx;
            last_click_y = cy;
            const kind: u8 = if (is_dbl) winsys.EV_DBL else winsys.EV_PRESS;
            winsys.push(wi, .{ .kind = kind, .x = @intCast(cx), .y = @intCast(cy), .code = 0, ._pad = 0, ._pad2 = 0 });
        } else {
            apps.onPress(w, x, y); // 内核窗口客户区
        }
        app_capture = wi; // 按住期间的移动归这个窗口
        return;
    }

    // 4) 桌面图标（单击选中 / 双击启动）
    const ic = hitIcon(x, y);
    if (ic >= 0) {
        const i: usize = @intCast(ic);
        const is_dbl = last_click_win == (0x8000_0000 | i) and
            pit.ticks - last_click_tick <= DBL_TICKS and
            @abs(x - last_click_x) <= DBL_SLOP and @abs(y - last_click_y) <= DBL_SLOP;
        if (is_dbl) {
            icon_sel = -1;
            last_click_win = 0xFFFF;
            addDamage(iconRect(i));
            launchIcon(i);
        } else {
            const old = icon_sel;
            icon_sel = ic;
            last_click_win = 0x8000_0000 | i;
            last_click_tick = pit.ticks;
            last_click_x = x;
            last_click_y = y;
            if (old >= 0) addDamage(iconRect(@intCast(old)));
            addDamage(iconRect(i));
        }
        return;
    }
    if (icon_sel >= 0) {
        addDamage(iconRect(@intCast(icon_sel)));
        icon_sel = -1;
    }

    // 5) 任务栏：OusiaOS 按钮弹菜单，窗口按钮最小化/还原/提层
    if (inRect(x, y, btnRect())) {
        menu_open = true;
        btn_pressed = true;
        menu_hover = -1;
        addDamage(btnRect());
        addDamage(menuRect());
        return;
    }
    if (taskBtnHit(x, y)) |wi| {
        const w = &windows[wi];
        if (!w.visible) {
            showWindow(wi); // 还原（并提层）
        } else if (topVisible() == wi) {
            minimizeWindow(wi); // 活动窗口 → 最小化
        } else {
            raiseWindow(wi); // 切到前台
        }
        addDamage(taskbarRect());
        return;
    }
}

/// 右键按下：用户窗口发事件（扫雷插旗）；内核窗口只有扫雷用过（已迁出）
fn handleRightPress(x: i32, y: i32) void {
    var zi: usize = zorder.len;
    while (zi > 0) {
        zi -= 1;
        const wi = zorder[zi];
        const w = &windows[wi];
        if (!w.visible) continue;
        if (!inRect(x, y, winRect(w))) continue;
        if (!inRect(x, y, titleRect(w)) and w.kind == .user) {
            const cr = clientRect(w);
            winsys.push(wi, .{ .kind = winsys.EV_RPRESS, .x = @intCast(x - cr.x), .y = @intCast(y - cr.y), .code = 0, ._pad = 0, ._pad2 = 0 });
        }
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
    if (saver_on) {
        // 星场动画：只记星点周围的小脏区（整屏重刷 100Hz 太贵）
        for (stars) |s| {
            addDamage(mkRect(s.x - 2, s.y - 1, 8, 3));
        }
        repaint();
        return;
    }
    // 屏保倒计时（0 = 禁用）
    if (saver_timeout_s > 0 and pit.ticks - last_input_tick >= @as(u64, saver_timeout_s) * 100) {
        saverStart();
        return;
    }
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
/// 键盘焦点 = 活动窗口：
///   - 用户应用窗口：EV_KEY 事件（应用自己解释，0xF0..0xF8 私有码，
///     Ctrl+字母 = 控制码 0x01..0x1A）；
///   - Terminal（内核窗口）：PgUp/PgDn/Home/End 归回滚，其余照旧进
///     tty 行规程（串口 shell 的回显/控制字符行为完全不变）；
///   - 桌面/About：ASCII 照旧进 tty。
pub fn onKey(c: u8) void {
    if (!active) {
        if (c < 0xF0) tty.onInput(c);
        return;
    }
    last_input_tick = pit.ticks;
    if (saver_on) {
        saverStop();
        return;
    }
    if (sysmenu_open and c == 0x1B) { // Esc 收系统菜单
        closeSysMenu();
        return;
    }
    if (menu_open and c == 0x1B) { // Esc 收开始菜单
        closeMenu();
        addDamage(menuRect());
        return;
    }

    const wi = topVisible();
    const w = &windows[wi];
    if (w.visible and w.kind == .user) {
        pushUserEvent(wi, .{ .kind = winsys.EV_KEY, .x = 0, .y = 0, .code = c, ._pad = 0, ._pad2 = 0 });
        return;
    }
    if (w.visible and w.kind == .terminal) {
        switch (c) {
            0xF6, 0xF7, 0xF4, 0xF5 => { // PgUp/PgDn/Home/End → 回滚
                @import("apps/term.zig").onKey(c);
                return;
            },
            else => {},
        }
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

/// 当前帧缓冲像素格式的通道移位（miniGL 等自绘库经 win_fmt 查询）
pub fn pixelShifts() struct { rsh: u5, gsh: u5, bsh: u5 } {
    return .{ .rsh = rsh, .gsh = gsh, .bsh = bsh };
}

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
    wallpaper = pal.desktop;

    active = true;
    setKernelTitle(0, "About OusiaOS");
    setKernelTitle(1, "Terminal");
    apps.init(); // 内核应用状态复位（about/terminal）

    // PS/2 鼠标（失败不致命：GUI 只是没有光标输入）
    const mouse = @import("mouse.zig");
    if (mouse.init()) {
        @import("pic.zig").unmask(12);
        console.kprintf("gui: mouse on IRQ12\n", .{});
    } else {
        console.kprintf("gui: PS/2 mouse init failed\n", .{});
    }

    _ = updateClock();
    last_input_tick = pit.ticks;
    addDamage(SCREEN);
    repaint();
    console.kprintf("gui: 640x480x32 compositor up (desktop icons/taskbar/menu/windows/saver)\n", .{});
}

/// 文件系统就绪后调用（main.zig）：读回 Control Panel 存的设置 +
/// 播放开机音（WAV 依赖 ramfs，必须晚于 tarfs.init）。
pub fn lateInit() void {
    loadSettings();
    _ = @import("audio.zig").playSystem(0); // 0 = startup chime
}

// ---------------- 设置（/etc/ousia.conf） ----------------
//
// Control Panel 写、gui 读的极简 key=value 文本：
//   wallpaper=0,128,128     桌面底色 RGB
//   saver=90                屏保超时秒（0 禁用）
// 文件在 ramfs 里，重启丢失（教学内核没有掉电存储）。

pub fn loadSettings() void {
    const node = vfs.resolve("/etc/ousia.conf", "/") orelse return;
    const inf = vfs.info(node);
    if (inf.is_dir or inf.size == 0) return;
    var buf: [256]u8 = undefined;
    const n = vfs.read(node, 0, buf[0..@min(inf.size, buf.len)]);
    if (n <= 0) return;

    var it = LineIter{ .s = buf[0..@intCast(n)] };
    while (it.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const val = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "wallpaper")) {
            var parts: [3]u32 = .{ 0, 128, 128 };
            var pi: usize = 0;
            var cur: u32 = 0;
            var any = false;
            for (val) |ch| {
                if (ch == ',') {
                    if (pi < 3) parts[pi] = cur;
                    pi += 1;
                    cur = 0;
                    any = false;
                } else if (ch >= '0' and ch <= '9') {
                    cur = cur * 10 + (ch - '0');
                    any = true;
                }
            }
            if (any and pi < 3) parts[pi] = cur;
            wallpaper = px(@intCast(@min(parts[0], 255)), @intCast(@min(parts[1], 255)), @intCast(@min(parts[2], 255)));
        } else if (std.mem.eql(u8, key, "saver")) {
            var v: u32 = 0;
            for (val) |ch| {
                if (ch < '0' or ch > '9') break;
                v = v * 10 + (ch - '0');
            }
            saver_timeout_s = @min(v, 3600);
        } else if (std.mem.eql(u8, key, "volume")) {
            var v: u32 = 0;
            for (val) |ch| {
                if (ch < '0' or ch > '9') break;
                v = v * 10 + (ch - '0');
            }
            @import("audio.zig").setVolume(@min(v, 100));
        }
    }
    addDamage(SCREEN);
}

const LineIter = struct {
    s: []const u8,
    pos: usize = 0,

    fn next(self: *LineIter) ?[]const u8 {
        if (self.pos >= self.s.len) return null;
        const start = self.pos;
        while (self.pos < self.s.len and self.s[self.pos] != '\n') self.pos += 1;
        const l = self.s[start..self.pos];
        self.pos += 1;
        return l;
    }
};
