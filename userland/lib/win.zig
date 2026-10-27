//! win —— 用户态窗口库（内核 winsys.zig 的协议封装）
//!
//! 应用模型：
//!   win.create(w, h, "标题")   拿到一块共享表面（像素 = 帧缓冲格式 u32）
//!   loop { win.wait(事件, 超时) → 处理 → 画表面 → win.present() }
//!
//! 事件循环里的一切都是普通用户态代码：内核只负责把全局鼠标/键盘
//! 事件按窗口几何换算成客户区坐标推进队列。方向键是 0xF0..0xF3
//! 私有键码（KEY_UP/DOWN/LEFT/RIGHT）。

const zos = @import("zos.zig");
const font = @import("font.zig");

pub const EV_PRESS: u8 = 1; // 左键按下（x,y = 客户区坐标）
pub const EV_RPRESS: u8 = 2; // 右键按下
pub const EV_RELEASE: u8 = 3; // 左键松开
pub const EV_MOVE: u8 = 4; // 按住拖动（捕获：划出窗口也有）
pub const EV_KEY: u8 = 5; // 键盘（code = ASCII 或方向键私有码）
pub const EV_CLOSE: u8 = 6; // 关闭盒被点：尽快 exit

pub const KEY_UP: u8 = 0xF0;
pub const KEY_DOWN: u8 = 0xF1;
pub const KEY_LEFT: u8 = 0xF2;
pub const KEY_RIGHT: u8 = 0xF3;

pub const Event = extern struct {
    kind: u8,
    x: i16,
    y: i16,
    code: u8,
    _pad: u8,
    _pad2: u8,
};

// ---------------- 表面 ----------------

pub var sw: i32 = 0; // 表面尺寸（像素）
pub var sh: i32 = 0;
var px: [*]u32 = undefined; // 用户映射地址（win_create 返回）

/// 创建窗口（每进程一个，重复创建返回 false）。成功后 sw/sh 生效。
pub fn create(w: i32, h: i32, title: []const u8) bool {
    var t: [40]u8 = undefined;
    const n = @min(title.len, t.len - 1);
    @memcpy(t[0..n], title[0..n]);
    t[n] = 0;
    const r = zos.syscall3(510, @intCast(w), @intCast(h), @intFromPtr(&t));
    if (r <= 0) return false;
    px = @ptrFromInt(@as(usize, @intCast(r)));
    sw = w;
    sh = h;
    return true;
}

/// 画完调用：内核记脏区，IRQ0 合成上屏
pub fn present() void {
    _ = zos.syscall0(511);
}

/// r,g,b → 帧缓冲像素格式（BGR 位移由内核告诉你）
pub fn color(r: u8, g: u8, b: u8) u32 {
    const v: isize = zos.syscall3(514, r, g, b);
    return @truncate(@as(u64, @bitCast(v)));
}

/// 共享表面本体（miniGL 的渲染目标：gl.beginFrame 直接绑它）
pub fn surface() []u32 {
    return px[0..@intCast(sw * sh)];
}

/// 帧缓冲像素格式的通道移位（win_fmt；miniGL 逐像素打包用，
/// 一次查询后渲染循环里零陷入）
pub fn fmt() struct { rsh: u5, gsh: u5, bsh: u5 } {
    const f: usize = @bitCast(zos.syscall0(515));
    return .{ .rsh = @intCast((f >> 10) & 31), .gsh = @intCast((f >> 5) & 31), .bsh = @intCast(f & 31) };
}

/// 阻塞等事件；timeout_ms=0 无限等，超时返回 0（闪烁计时用）
pub fn wait(buf: []Event, timeout_ms: i32) usize {
    const r = zos.syscall3(513, @intFromPtr(buf.ptr), buf.len, @as(usize, @bitCast(@as(isize, timeout_ms))));
    return if (r > 0) @intCast(r) else 0;
}

pub fn poll(buf: []Event) usize {
    const r = zos.syscall3(512, @intFromPtr(buf.ptr), buf.len, 0);
    return if (r > 0) @intCast(r) else 0;
}

// ---------------- 表面绘制原语 ----------------

pub fn set(x: i32, y: i32, c: u32) void {
    if (x < 0 or y < 0 or x >= sw or y >= sh) return;
    px[@intCast(y * sw + x)] = c;
}

pub fn fillRect(x: i32, y: i32, w: i32, h: i32, c: u32) void {
    var yy = y;
    while (yy < y + h) : (yy += 1) {
        var xx = x;
        while (xx < x + w) : (xx += 1) set(xx, yy, c);
    }
}

pub fn hline(x0: i32, x1: i32, y: i32, c: u32) void {
    var x = x0;
    while (x <= x1) : (x += 1) set(x, y, c);
}

pub fn vline(x: i32, y0: i32, y1: i32, c: u32) void {
    var y = y0;
    while (y <= y1) : (y += 1) set(x, y, c);
}

/// Bresenham 直线（画图笔划）
pub fn line(x0: i32, y0: i32, x1: i32, y1: i32, c: u32) void {
    var x = x0;
    var y = y0;
    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        set(x, y, c);
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

/// 8x16 位图文本（lib/font.zig，与内核同一份生成物）
pub fn text(x: i32, y: i32, s: []const u8, c: u32) void {
    var cx = x;
    for (s) |ch| {
        const idx: usize = if (ch >= font.FIRST and ch < font.FIRST + font.COUNT) ch - font.FIRST else '?' - font.FIRST;
        const g = &font.glyphs[idx];
        for (g, 0..) |row, ry| {
            if (row == 0) continue;
            var b = row;
            var rx: i32 = 0;
            while (b != 0) : (b <<= 1) {
                if (b & 0x80 != 0) set(cx + rx, y + @as(i32, @intCast(ry)), c);
                rx += 1;
            }
        }
        cx += font.W;
    }
}

pub fn textBold(x: i32, y: i32, s: []const u8, c: u32) void {
    text(x, y, s, c);
    text(x + 1, y, s, c);
}

// ---------------- 常用配色 ----------------

pub var C_WHITE: u32 = 0;
pub var C_BLACK: u32 = 0;
pub var C_CHROME: u32 = 0;
pub var C_NAVY: u32 = 0;
pub var C_SHADOW: u32 = 0;
pub var C_RED: u32 = 0;

/// create() 后调一次：预打包常用颜色（帧缓冲格式由内核决定）
pub fn initColors() void {
    C_WHITE = color(255, 255, 255);
    C_BLACK = color(0, 0, 0);
    C_CHROME = color(192, 192, 192);
    C_NAVY = color(0, 0, 128);
    C_SHADOW = color(128, 128, 128);
    C_RED = color(255, 0, 0);
}

/// 1px 斜面（Win3.1 立体感）
pub fn bevel(x: i32, y: i32, w: i32, h: i32, raised: bool) void {
    const lt = if (raised) C_WHITE else C_SHADOW;
    const br = if (raised) C_SHADOW else C_WHITE;
    hline(x, x + w - 1, y, lt);
    vline(x, y, y + h - 1, lt);
    hline(x, x + w - 1, y + h - 1, br);
    vline(x + w - 1, y, y + h - 1, br);
}
