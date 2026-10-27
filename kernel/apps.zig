//! ZOS 内核窗口应用：分发器 —— gui.zig 与内核侧窗口的"住户"
//!
//! ZOS 0.2 起大多数 GUI 应用搬到【用户态】（/bin/fm、/bin/note、
//! /bin/paint、/bin/calc、/bin/mine——经 winsys.zig 窗口服务画进共享
//! 表面）。留在内核的只剩两类：
//!   - Terminal：内核控制台的镜像（console.putChar 三路输出的第三路，
//!     环形行缓冲天然属于内核——串口日志/打印k 都汇到这里）
//!   - About ZOS：窗口管理器自己的系统对话框
//!
//! 应用接口（IRQ 上下文）：paint（画客户区）/ press（左键）；
//! term.putChar 可能来自进程上下文（shell printf），内部有极短
//! 关中断临界区。

const gui = @import("gui.zig");

const about = @import("apps/about.zig");
const term = @import("apps/term.zig");

/// gui.init 末尾调用
pub fn init() void {}

/// 客户区绘制（repaint 内调用，clip 已设好）
pub fn paintClient(w: *const gui.Win) void {
    switch (w.kind) {
        .about => about.paint(w),
        .terminal => term.paint(w),
        .user => {}, // 用户窗口由 gui 直接 blit 共享表面
    }
}

/// 客户区左键（IRQ12 上下文；gui 已先把窗口提到 z 序顶端）
pub fn onPress(w: *gui.Win, x: i32, y: i32) void {
    switch (w.kind) {
        .about => about.press(w, x, y),
        else => {},
    }
}

/// 左键松开 / 捕获移动：内核窗口目前无使用者（画图已迁用户态），
/// 保留接口以免 gui.zig 依赖具体应用
pub fn onRelease() void {}
pub fn onMove(w: *const gui.Win, x: i32, y: i32) void {
    _ = w;
    _ = x;
    _ = y;
}

/// IRQ0 每拍调用：终端光标闪烁
pub fn onTick() void {
    term.tick();
}

/// console.putChar → GUI 终端镜像（可能处于进程上下文：shell printf）
pub fn termPutChar(c: u8) void {
    term.putChar(c);
}
