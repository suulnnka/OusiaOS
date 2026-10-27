//! ZOS 内核小应用：分发器（registry）—— gui.zig 与各应用之间的总机
//!
//! 每个应用一个源文件（kernel/apps/<name>.zig），本文件只做两件事：
//!   1. 汇总初始化（init）
//!   2. 按 WinKind 把 gui.zig 的回调转发给对应应用
//!
//! 应用接口约定（全部在 IRQ 上下文调用，除非另注明）：
//!   onOpen(w)            窗口每次打开（gui.showWindow）
//!   paint(w)             画客户区（repaint 内，clip 已设好）
//!   press(w, x, y)       客户区左键
//!   rightPress(w, x, y)  客户区右键
//!   move(w, x, y)        鼠标捕获期间的移动（gui.onMouseDelta）
//!   release()            左键松开（捕获结束；只有画图用）
//!   key(c)               键盘按键（仅持有焦点的应用：记事本）
//!   tick()               IRQ0 每拍：定时器/闪烁记脏区
//!
//! 例外：term.putChar 由 console.putChar 调用，可能处于进程上下文
//! （shell printf），内部有极短关中断临界区，见 apps/term.zig。
//!
//! 三个应用代表内核 GUI 的三种典型数据流：
//!   filer：按需拉取（点击 → vfs 遍历/读取，同步完成）
//!   term： 事件镜像（console → 环形行缓冲，IRQ0 刷新）
//!   mine： 自包含状态机（纯输入驱动 + 定时器计秒）
//!   paint：位图 + 鼠标捕获（按住拖动连续作画）
//!   calc： 无状态重建（f64 + 键阵）
//!   note： 键盘焦点（GUI 真正吃键盘的第一个应用）

const gui = @import("gui.zig");

const about = @import("apps/about.zig");
const filer = @import("apps/filer.zig");
const term = @import("apps/term.zig");
const mine = @import("apps/mine.zig");
const paint = @import("apps/paint.zig");
const calc = @import("apps/calc.zig");
const note = @import("apps/note.zig");

/// gui.init 末尾调用（此刻 tarfs 还没解析，文件浏览器延迟到首次打开）
pub fn init() void {
    mine.reset();
}

/// 窗口每次打开时调用（gui.showWindow）
pub fn onOpen(w: *const gui.Win) void {
    switch (w.kind) {
        .filer => filer.onOpen(), // 首次列根目录；之后记住上次所在目录
        else => {},
    }
}

/// 客户区绘制（repaint 内调用，clip 已设好）
pub fn paintClient(w: *const gui.Win) void {
    switch (w.kind) {
        .about => about.paint(w),
        .filer => filer.paint(w),
        .terminal => term.paint(w),
        .mine => mine.paint(w),
        .paint => paint.paint(w),
        .calc => calc.paint(w),
        .note => note.paint(w),
    }
}

/// 客户区左键（IRQ12 上下文；gui 已先把窗口提到 z 序顶端并设置捕获）
pub fn onPress(w: *gui.Win, x: i32, y: i32) void {
    switch (w.kind) {
        .about => about.press(w, x, y),
        .filer => filer.press(w, x, y),
        .terminal => {},
        .mine => mine.press(w, x, y),
        .paint => paint.press(w, x, y),
        .calc => calc.press(w, x, y),
        .note => {},
    }
}

/// 客户区右键（只有扫雷用：插旗）
pub fn onRightPress(w: *const gui.Win, x: i32, y: i32) void {
    switch (w.kind) {
        .mine => mine.rightPress(w, x, y),
        else => {},
    }
}

/// 鼠标捕获期间的移动（左键按住且按下点落在某窗口客户区时）
pub fn onMove(w: *const gui.Win, x: i32, y: i32) void {
    switch (w.kind) {
        .paint => paint.move(w, x, y),
        else => {},
    }
}

/// 左键松开（捕获结束）
pub fn onRelease() void {
    paint.release();
}

/// 键盘按键（gui.onKey 仅在活动窗口是记事本时转发）
pub fn onKey(c: u8) void {
    note.key(c);
}

/// IRQ0 每拍调用：各应用定时器（只记脏区，重绘留给 repaint）
pub fn onTick() void {
    term.tick();
    mine.tick();
    note.tick();
}

/// console.putChar → GUI 终端镜像（可能处于进程上下文：shell printf）
pub fn termPutChar(c: u8) void {
    term.putChar(c);
}
