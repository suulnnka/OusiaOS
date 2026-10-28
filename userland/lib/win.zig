//! win —— 用户态窗口库（内核 winsys.zig 的协议封装）
//!
//! 应用模型：
//!   win.create(w, h, "标题")   拿到一块共享表面（像素 = 帧缓冲格式 u32）
//!   loop { win.wait(事件, 超时) → 处理 → 画表面 → win.present() }
//!
//! 事件循环里的一切都是普通用户态代码：内核只负责把全局鼠标/键盘
//! 事件按窗口几何换算成客户区坐标推进队列。方向键是 0xF0..0xF8
//! 私有键码；Ctrl+字母以控制码（0x01..0x1A）投递。
//!
//! 本库同时提供一套 Win3.1 风格的小控件/图元（约等于"极简 toolkook"）：
//!   - Edit      单行文本编辑控件（插入光标/选区/剪贴板/鼠标定位）
//!   - MenuBar   客户区菜单栏 + 下拉菜单（状态机式，见 controlPanel）
//!   - 图形      line/ellipse/circle/poly/polyfill + text 多档字号
//!   - 剪贴板    clipSet/clipGet（内核全局缓冲，Ctrl+C/X/V 由应用翻译）

const ousia = @import("ousia.zig");
const font = @import("font.zig");

pub const EV_PRESS: u8 = 1; // 左键按下（x,y = 客户区坐标）
pub const EV_RPRESS: u8 = 2; // 右键按下
pub const EV_RELEASE: u8 = 3; // 左键松开
pub const EV_MOVE: u8 = 4; // 按住拖动（捕获：划出窗口也有）
pub const EV_KEY: u8 = 5; // 键盘（code = ASCII/控制码 或方向键私有码）
pub const EV_CLOSE: u8 = 6; // 关闭盒被点：尽快 exit
pub const EV_RESIZE: u8 = 7; // 表面已重分配（x,y = 新客户区尺寸）
pub const EV_DBL: u8 = 8; // 双击
pub const EV_ACTIVATE: u8 = 9; // 窗口成为活动窗口（键盘焦点到手）
pub const EV_DEACTIVATE: u8 = 10; // 失去活动状态

pub const KEY_UP: u8 = 0xF0;
pub const KEY_DOWN: u8 = 0xF1;
pub const KEY_LEFT: u8 = 0xF2;
pub const KEY_RIGHT: u8 = 0xF3;
pub const KEY_HOME: u8 = 0xF4;
pub const KEY_END: u8 = 0xF5;
pub const KEY_PGUP: u8 = 0xF6;
pub const KEY_PGDN: u8 = 0xF7;
pub const KEY_DEL: u8 = 0xF8;

// Ctrl+字母 → 控制码（内核 keyboard.zig 的映射，这里给可读常量）
pub const CTRL_A: u8 = 0x01; // 全选
pub const CTRL_C: u8 = 0x03; // 复制
pub const CTRL_S: u8 = 0x13; // 保存
pub const CTRL_V: u8 = 0x16; // 粘贴
pub const CTRL_X: u8 = 0x18; // 剪切
pub const CTRL_Z: u8 = 0x1A; // 撤销

// open() 的 flags（与内核 syscall.zig 一致）
pub const O_RDONLY: i32 = 0;
pub const O_WRONLY: i32 = 1;
pub const O_RDWR: i32 = 2;
pub const O_CREAT: i32 = 0o100;
pub const O_EXCL: i32 = 0o200;
pub const O_TRUNC: i32 = 0o1000;

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
    const r = ousia.syscall3(510, @intCast(w), @intCast(h), @intFromPtr(&t));
    if (r <= 0) return false;
    px = @ptrFromInt(@as(usize, @intCast(r)));
    sw = w;
    sh = h;
    return true;
}

/// WM 发起的 resize（最大化/还原/拖边）以 EV_RESIZE 通知：
/// 表面 VA 不变（指针仍有效），但应用要同步新的表面尺寸
pub fn onResizeEvent(e: Event) void {
    sw = e.x;
    sh = e.y;
}

/// 表面重分配（EV_RESIZE 之后应用无需再调；主动变尺寸时用）
pub fn resize(w: i32, h: i32) bool {
    const r = ousia.syscall2(518, @intCast(w), @intCast(h));
    if (r != 0) return false;
    sw = w;
    sh = h;
    return true;
}

/// 改窗口标题（任务栏/标题栏联动）
pub fn setTitle(title: []const u8) void {
    var t: [40]u8 = undefined;
    const n = @min(title.len, t.len - 1);
    @memcpy(t[0..n], title[0..n]);
    t[n] = 0;
    _ = ousia.syscall1(519, @intFromPtr(&t));
}

/// 画完调用：内核记脏区，IRQ0 合成上屏
pub fn present() void {
    _ = ousia.syscall0(511);
}

/// r,g,b → 帧缓冲像素格式（BGR 位移由内核告诉你）
pub fn color(r: u8, g: u8, b: u8) u32 {
    const v: isize = ousia.syscall3(514, r, g, b);
    return @truncate(@as(u64, @bitCast(v)));
}

/// 共享表面本体（miniGL 的渲染目标：gl.beginFrame 直接绑它）
pub fn surface() []u32 {
    return px[0..@intCast(sw * sh)];
}

/// 帧缓冲像素格式的通道移位（win_fmt；miniGL 逐像素打包用，
/// 一次查询后渲染循环里零陷入）
pub fn fmt() struct { rsh: u5, gsh: u5, bsh: u5 } {
    const f: usize = @bitCast(ousia.syscall0(515));
    return .{ .rsh = @intCast((f >> 10) & 31), .gsh = @intCast((f >> 5) & 31), .bsh = @intCast(f & 31) };
}

/// 阻塞等事件；timeout_ms=0 无限等，超时返回 0（闪烁计时用）
pub fn wait(buf: []Event, timeout_ms: i32) usize {
    const r = ousia.syscall3(513, @intFromPtr(buf.ptr), buf.len, @as(usize, @bitCast(@as(isize, timeout_ms))));
    return if (r > 0) @intCast(r) else 0;
}

pub fn poll(buf: []Event) usize {
    const r = ousia.syscall3(512, @intFromPtr(buf.ptr), buf.len, 0);
    return if (r > 0) @intCast(r) else 0;
}

// ---------------- 系统剪贴板 ----------------

/// 写剪贴板（最长 1KB）；返回写入长度或 -errno
pub fn clipSet(data: []const u8) isize {
    if (data.len == 0) return 0;
    return ousia.syscall2(516, @intFromPtr(data.ptr), data.len);
}

/// 读剪贴板；返回拷入 buf 的长度（0 = 空）
pub fn clipGet(buf: []u8) isize {
    if (buf.len == 0) return 0;
    return ousia.syscall2(517, @intFromPtr(buf.ptr), buf.len);
}

// ---------------- 表面绘制原语 ----------------

pub fn set(x: i32, y: i32, c: u32) void {
    if (x < 0 or y < 0 or x >= sw or y >= sh) return;
    px[@intCast(y * sw + x)] = c;
}

pub fn get(x: i32, y: i32) u32 {
    if (x < 0 or y < 0 or x >= sw or y >= sh) return 0;
    return px[@intCast(y * sw + x)];
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

/// 空心矩形
pub fn rectStroke(x: i32, y: i32, w: i32, h: i32, c: u32) void {
    hline(x, x + w - 1, y, c);
    hline(x, x + w - 1, y + h - 1, c);
    vline(x, y, y + h - 1, c);
    vline(x + w - 1, y, y + h - 1, c);
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

/// 椭圆描边：行扫描（左右端点）∪ 列扫描（上下端点）。
/// @sqrt(f32) 是硬件 sqrtss 指令（SSE2 基线集），无 libm 依赖。
pub fn ellipse(cx: i32, cy: i32, rx: i32, ry: i32, c: u32) void {
    if (rx < 1 or ry < 1) return;
    const rxf: f32 = @floatFromInt(rx);
    const ryf: f32 = @floatFromInt(ry);
    var dy: i32 = -ry;
    while (dy <= ry) : (dy += 1) {
        const t = 1.0 - (@as(f32, @floatFromInt(dy)) * @as(f32, @floatFromInt(dy))) / (ryf * ryf);
        if (t < 0) continue;
        const h: i32 = @intFromFloat(@sqrt(t) * rxf + 0.5);
        set(cx + h, cy + dy, c);
        set(cx - h, cy + dy, c);
    }
    var dx: i32 = -rx;
    while (dx <= rx) : (dx += 1) {
        const t = 1.0 - (@as(f32, @floatFromInt(dx)) * @as(f32, @floatFromInt(dx))) / (rxf * rxf);
        if (t < 0) continue;
        const v: i32 = @intFromFloat(@sqrt(t) * ryf + 0.5);
        set(cx + dx, cy + v, c);
        set(cx + dx, cy - v, c);
    }
}

pub fn circle(cx: i32, cy: i32, r: i32, c: u32) void {
    ellipse(cx, cy, r, r, c);
}

/// 实心椭圆（扫描线，每行求半宽）
pub fn ellipseFill(x: i32, y: i32, w: i32, h: i32, c: u32) void {
    if (w <= 0 or h <= 0) return;
    const cx: f32 = @as(f32, @floatFromInt(x)) + @as(f32, @floatFromInt(w)) / 2.0 - 0.5;
    const cy: f32 = @as(f32, @floatFromInt(y)) + @as(f32, @floatFromInt(h)) / 2.0 - 0.5;
    const rx: f32 = @as(f32, @floatFromInt(w)) / 2.0;
    const ry: f32 = @as(f32, @floatFromInt(h)) / 2.0;
    var yy = y;
    while (yy < y + h) : (yy += 1) {
        const fy = (@as(f32, @floatFromInt(yy)) - cy) / ry;
        const t = 1.0 - fy * fy;
        if (t <= 0) continue;
        const half = @sqrt(t) * rx;
        hline(@intFromFloat(cx - half), @intFromFloat(cx + half), yy, c);
    }
}

/// 折线/多边形描边：pts 顺序连线，close=true 时首尾相连
pub fn poly(pts: []const [2]i32, close: bool, c: u32) void {
    if (pts.len < 2) return;
    var i: usize = 0;
    while (i + 1 < pts.len) : (i += 1) {
        line(pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1], c);
    }
    if (close) {
        line(pts[pts.len - 1][0], pts[pts.len - 1][1], pts[0][0], pts[0][1], c);
    }
}

/// 多边形填充：扫描线 + 奇偶规则（交点取边中点规则防顶点重计）。
/// 教学版：每行对每条边求交点，排序后成对填充。
pub fn polyFill(pts: []const [2]i32, c: u32) void {
    if (pts.len < 3) return;
    var min_y: i32 = pts[0][1];
    var max_y: i32 = pts[0][1];
    for (pts) |p| {
        min_y = @min(min_y, p[1]);
        max_y = @max(max_y, p[1]);
    }
    var xs: [32]i32 = undefined;
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var n: usize = 0;
        for (pts, 0..) |a, i| {
            const b = pts[(i + 1) % pts.len];
            const y0 = a[1];
            const y1 = b[1];
            if (y0 == y1) continue; // 水平边不产生交点
            const lo = @min(y0, y1);
            const hi = @max(y0, y1);
            // 半开区间 [lo, hi)：顶点只计一次
            if (y < lo or y >= hi) continue;
            const t = @divTrunc((y - y0) * 65536, y1 - y0);
            const xi = a[0] + @divTrunc((b[0] - a[0]) * t, 65536);
            if (n < xs.len) {
                xs[n] = xi;
                n += 1;
            }
        }
        // 插入排序（n 很小）
        var k: usize = 1;
        while (k < n) : (k += 1) {
            const key = xs[k];
            var j = k;
            while (j > 0 and xs[j - 1] > key) : (j -= 1) xs[j] = xs[j - 1];
            xs[j] = key;
        }
        var m: usize = 0;
        while (m + 1 < n) : (m += 2) {
            hline(xs[m], xs[m + 1], y, c);
        }
    }
}

/// 位图文本（8x16 基底；scale = 1..4 的整数最近邻放大——多档字号）
pub fn text(x: i32, y: i32, s: []const u8, c: u32) void {
    textScaled(x, y, s, c, 1);
}

pub fn textScaled(x: i32, y: i32, s: []const u8, c: u32, scale: i32) void {
    const sc: u5 = @intCast(@max(1, @min(scale, 4)));
    var cx = x;
    for (s) |ch| {
        const idx: usize = if (ch >= font.FIRST and ch < font.FIRST + font.COUNT) ch - font.FIRST else '?' - font.FIRST;
        const g = &font.glyphs[idx];
        for (g, 0..) |row, ry| {
            if (row == 0) continue;
            var b = row;
            var rx: i32 = 0;
            while (b != 0) : (b <<= 1) {
                if (b & 0x80 != 0) {
                    // 基底 1 像素 → scale×scale 方块
                    var yy: i32 = 0;
                    while (yy < sc) : (yy += 1) {
                        var xx: i32 = 0;
                        while (xx < sc) : (xx += 1) {
                            set(cx + rx * sc + xx, y + @as(i32, @intCast(ry)) * sc + yy, c);
                        }
                    }
                }
                rx += 1;
            }
        }
        cx += font.W * sc;
    }
}

/// 文本像素宽（按当前 scale）
pub fn textWidth(s: []const u8, scale: i32) i32 {
    const sc: i32 = @max(1, @min(scale, 4));
    return @intCast(s.len * font.W * sc);
}

pub fn textHeight(scale: i32) i32 {
    return 16 * @max(1, @min(scale, 4));
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
pub var C_LTF: u32 = 0; // 亮面（2px 斜面内圈）
pub var C_YELLOW: u32 = 0;
pub var C_GREEN: u32 = 0;

/// create() 后调一次：预打包常用颜色（帧缓冲格式由内核决定）
pub fn initColors() void {
    C_WHITE = color(255, 255, 255);
    C_BLACK = color(0, 0, 0);
    C_CHROME = color(192, 192, 192);
    C_NAVY = color(0, 0, 128);
    C_SHADOW = color(128, 128, 128);
    C_RED = color(255, 0, 0);
    C_LTF = color(223, 223, 223);
    C_YELLOW = color(255, 224, 96);
    C_GREEN = color(0, 128, 0);
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

/// 2px 斜面：Win3.1 控件的标准立体感
pub fn bevel2(x: i32, y: i32, w: i32, h: i32, raised: bool) void {
    bevel(x, y, w, h, raised);
    const tl = if (raised) C_LTF else C_BLACK;
    const br = if (raised) C_BLACK else C_LTF;
    hline(x + 1, x + w - 2, y + 1, tl);
    vline(x + 1, y + 1, y + h - 2, tl);
    hline(x + 1, x + w - 2, y + h - 2, br);
    vline(x + w - 2, y + 1, y + h - 2, br);
}

// ================= Edit 单行编辑控件 =================
//
// 状态 + 绘制 + 键盘/鼠标处理的三件套。调用方持有 Edit 结构体，
// 在事件循环里把 EV_KEY/EV_PRESS/EV_DBL 转给它；每帧调 draw。
// 剪贴板走内核（Ctrl+C/X/V 控制码），选区高亮 Win 风格藏青。

pub const Edit = struct {
    buf: [120]u8 = undefined,
    len: usize = 0,
    caret: usize = 0, // 插入点（字符下标）
    sel_a: usize = 0, // 选区 [min(a,b), max(a,b))；a==b = 无选区
    sel_b: usize = 0,
    focused: bool = true, // 活动窗口里才画光标

    pub fn content(self: *const Edit) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn clear(self: *Edit) void {
        self.len = 0;
        self.caret = 0;
        self.sel_a = 0;
        self.sel_b = 0;
    }

    pub fn setText(self: *Edit, s: []const u8) void {
        const n = @min(s.len, self.buf.len);
        @memcpy(self.buf[0..n], s[0..n]);
        self.len = n;
        self.caret = n;
        self.sel_a = 0;
        self.sel_b = 0;
    }

    fn selLo(self: *const Edit) usize {
        return @min(self.sel_a, self.sel_b);
    }
    fn selHi(self: *const Edit) usize {
        return @max(self.sel_a, self.sel_b);
    }
    pub fn hasSel(self: *const Edit) bool {
        return self.sel_a != self.sel_b;
    }

    fn deleteSel(self: *Edit) void {
        if (!self.hasSel()) return;
        const lo = self.selLo();
        const hi = self.selHi();
        var i = lo;
        while (i + hi - lo < self.len) : (i += 1) self.buf[i] = self.buf[i + hi - lo];
        self.len -= hi - lo;
        self.caret = lo;
        self.sel_a = lo;
        self.sel_b = lo;
    }

    fn insert(self: *Edit, c: u8) void {
        self.deleteSel();
        if (self.len >= self.buf.len) return;
        var i = self.len;
        while (i > self.caret) : (i -= 1) self.buf[i] = self.buf[i - 1];
        self.buf[self.caret] = c;
        self.len += 1;
        self.caret += 1;
        self.sel_a = self.caret;
        self.sel_b = self.caret;
    }

    /// 键盘事件（EV_KEY 的 code）。返回 true 表示重画。
    pub fn key(self: *Edit, c: u8) bool {
        switch (c) {
            KEY_LEFT => {
                if (self.caret > 0) self.caret -= 1;
                self.sel_a = self.caret;
                self.sel_b = self.caret;
            },
            KEY_RIGHT => {
                if (self.caret < self.len) self.caret += 1;
                self.sel_a = self.caret;
                self.sel_b = self.caret;
            },
            KEY_HOME => {
                self.caret = 0;
                self.sel_a = 0;
                self.sel_b = 0;
            },
            KEY_END => {
                self.caret = self.len;
                self.sel_a = self.len;
                self.sel_b = self.len;
            },
            0x08 => { // 退格
                if (self.hasSel()) {
                    self.deleteSel();
                } else if (self.caret > 0) {
                    var i = self.caret - 1;
                    while (i < self.len - 1) : (i += 1) self.buf[i] = self.buf[i + 1];
                    self.len -= 1;
                    self.caret -= 1;
                }
            },
            KEY_DEL => {
                if (self.hasSel()) {
                    self.deleteSel();
                } else if (self.caret < self.len) {
                    var i = self.caret;
                    while (i < self.len - 1) : (i += 1) self.buf[i] = self.buf[i + 1];
                    self.len -= 1;
                }
            },
            CTRL_C, CTRL_X => {
                if (self.hasSel()) {
                    _ = clipSet(self.buf[self.selLo()..self.selHi()]);
                    if (c == CTRL_X) {
                        self.deleteSel();
                    }
                }
            },
            CTRL_V => {
                var cb: [1024]u8 = undefined;
                const n = clipGet(&cb);
                if (n > 0) {
                    for (cb[0..@intCast(n)]) |cc| self.insert(cc);
                }
            },
            else => {
                if (c < 32 or c >= 127) return false;
                self.insert(c);
            },
        }
        return true;
    }

    /// 鼠标按下：定位插入点（x 相对控件内），双击 = 全选
    pub fn click(self: *Edit, rel_x: i32, dbl: bool) void {
        if (dbl) {
            self.sel_a = 0;
            self.sel_b = self.len;
            self.caret = self.len;
            return;
        }
        var i: usize = 0;
        while (i < self.len and rel_x > 3 + @as(i32, @intCast(i + 1)) * 8) i += 1;
        self.caret = i;
        self.sel_a = i;
        self.sel_b = i;
    }

    /// 绘制（凹白底）；active 控制光标显示
    pub fn draw(self: *const Edit, x: i32, y: i32, w: i32, h: i32) void {
        fillRect(x, y, w, h, C_WHITE);
        bevel(x, y, w, h, false);
        if (self.hasSel()) {
            const lo: i32 = @intCast(self.selLo());
            const hi: i32 = @intCast(self.selHi());
            fillRect(x + 3 + lo * 8, y + 2, (hi - lo) * 8, h - 4, C_NAVY);
        }
        text(x + 3, y + @divTrunc(h - 16, 2) + 1, self.buf[0..self.len], C_BLACK);
        if (self.focused and !self.hasSel()) {
            fillRect(x + 3 + @as(i32, @intCast(self.caret)) * 8, y + 2, 7, h - 4, C_NAVY);
        } else if (self.focused and self.hasSel()) {
            fillRect(x + 3 + @as(i32, @intCast(self.caret)) * 8, y + 2, 1, h - 4, C_NAVY);
        }
    }
};

// ================= MenuBar 菜单栏控件 =================
//
// 客户区顶部的菜单条 + 下拉白底菜单（投影/高亮与开始菜单同款）。
// 状态机：closed → 点击主项打开 → 移动换高亮 → 点击项执行/点击外部关闭。
// 下拉画在客户区内部（窗口服务不提供越界绘制——教学取舍）。

/// 菜单项命中的返回槽（press 的 out 参数）
pub const MenuHit = struct { menu: usize, idx: usize };

pub const MenuDef = struct {
    label: []const u8,
    items: []const []const u8, // "" = 分隔线
};

pub const MenuBar = struct {
    defs: []const MenuDef,
    open_idx: i8 = -1, // 当前下拉的 主项下标（-1 = 收起）
    hover_main: i8 = -1,
    hover_item: i8 = -1,
    bar_h: i32 = 18,

    fn mainRect(self: *const MenuBar, i: usize) [4]i32 {
        var x: i32 = 2;
        for (self.defs, 0..) |d, k| {
            const w: i32 = @intCast(d.label.len * 8 + 16);
            if (k == i) return .{ x, 0, w, self.bar_h };
            x += w;
        }
        return .{ x, 0, 0, self.bar_h };
    }

    fn dropdownRect(self: *const MenuBar, i: usize) [4]i32 {
        const mr = self.mainRect(i);
        var h: i32 = 4;
        for (self.defs[i].items) |it| {
            h += if (it.len == 0) 5 else 18;
        }
        return .{ mr[0], self.bar_h, 168, h };
    }

    /// 返回值：true = 重画
    pub fn press(self: *MenuBar, x: i32, y: i32, out_item: ?*MenuHit) bool {
        if (self.open_idx >= 0) {
            const i: usize = @intCast(self.open_idx);
            const dr = self.dropdownRect(i);
            if (x >= dr[0] and y >= dr[1] and x < dr[0] + dr[2] and y < dr[1] + dr[3]) {
                const idx = self.itemAt(i, y - dr[1] - 2);
                if (idx) |k| {
                    if (out_item) |o| {
                        o.menu = i;
                        o.idx = k;
                    }
                }
                self.open_idx = -1;
                self.hover_item = -1;
                return true;
            }
            self.open_idx = -1;
            self.hover_main = -1;
            return true;
        }
        for (self.defs, 0..) |_, k| {
            const mr = self.mainRect(k);
            if (x >= mr[0] and y >= 0 and x < mr[0] + mr[2] and y < self.bar_h) {
                self.open_idx = @intCast(k);
                self.hover_item = -1;
                return true;
            }
        }
        return false;
    }

    /// 移动时的高亮；返回 true = 重画
    pub fn motion(self: *MenuBar, x: i32, y: i32) bool {
        if (self.open_idx >= 0) {
            const i: usize = @intCast(self.open_idx);
            const dr = self.dropdownRect(i);
            var hov: i8 = -1;
            if (x >= dr[0] and y >= dr[1] and x < dr[0] + dr[2] and y < dr[1] + dr[3]) {
                if (self.itemAt(i, y - dr[1] - 2)) |k| hov = @intCast(k);
            }
            if (hov != self.hover_item) {
                self.hover_item = hov;
                return true;
            }
            return false;
        }
        var hov: i8 = -1;
        for (self.defs, 0..) |_, k| {
            const mr = self.mainRect(k);
            if (x >= mr[0] and y < self.bar_h and x < mr[0] + mr[2]) hov = @intCast(k);
        }
        if (hov != self.hover_main) {
            self.hover_main = hov;
            return true;
        }
        return false;
    }

    fn itemAt(self: *const MenuBar, i: usize, rel_y: i32) ?usize {
        var y: i32 = 0;
        for (self.defs[i].items, 0..) |it, k| {
            const hh: i32 = if (it.len == 0) 5 else 18;
            if (rel_y >= y and rel_y < y + hh) return if (it.len == 0) null else k;
            y += hh;
        }
        return null;
    }

    pub fn draw(self: *const MenuBar, max_w: i32) void {
        fillRect(0, 0, max_w, self.bar_h, C_CHROME);
        hline(0, max_w - 1, self.bar_h, C_SHADOW);
        for (self.defs, 0..) |d, k| {
            const mr = self.mainRect(k);
            const active = self.open_idx == @as(i8, @intCast(k)) or self.hover_main == @as(i8, @intCast(k));
            if (active) fillRect(mr[0], mr[1], mr[2], mr[3], C_NAVY);
            const fg: u32 = if (active) C_WHITE else C_BLACK;
            text(mr[0] + 8, mr[1] + 1, d.label, fg);
        }
        if (self.open_idx >= 0) {
            const i: usize = @intCast(self.open_idx);
            const dr = self.dropdownRect(i);
            // 投影 + 白底 + 黑描边（与开始菜单同款）
            fillRect(dr[0] + 2, dr[1] + 2, dr[2], dr[3], C_SHADOW);
            fillRect(dr[0], dr[1], dr[2], dr[3], C_WHITE);
            rectStroke(dr[0], dr[1], dr[2], dr[3], C_BLACK);
            var y = dr[1] + 2;
            for (self.defs[i].items, 0..) |it, k| {
                if (it.len == 0) {
                    hline(dr[0] + 2, dr[0] + dr[2] - 3, y + 2, C_SHADOW);
                    hline(dr[0] + 2, dr[0] + dr[2] - 3, y + 3, C_WHITE);
                    y += 5;
                    continue;
                }
                if (self.hover_item == @as(i8, @intCast(k))) {
                    fillRect(dr[0] + 1, y, dr[2] - 2, 18, C_NAVY);
                }
                const fg: u32 = if (self.hover_item == @as(i8, @intCast(k))) C_WHITE else C_BLACK;
                text(dr[0] + 8, y + 1, it, fg);
                y += 18;
            }
        }
    }
};

// ---------------- 应用可用的系统音效 ----------------

/// 系统音效（内核 DDS 合成；音频忙时静默）
/// 0 startup 1 click 2 open 3 close 4 ding 5 error 6 tada
pub fn sound(kind: u8) void {
    _ = ousia.syscall1(507, kind);
}
