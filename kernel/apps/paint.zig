//! 画图 —— 位图画板（鼠标捕获型应用：按住拖动连续作画）
//!
//! 教学要点：
//!   - 画布是应用自有的位图（每像素 1 字节 = 16 色调色板下标），
//!     合成时才经 gui.setPx 映射成帧缓冲像素——应用状态与屏幕解耦
//!   - 直线/矩形的"橡皮筋"预览：按下时快照画布，移动时恢复快照再画
//!     预览线，松手即成品（无需第三套预览层）
//!   - 鼠标捕获：按下画布 → gui 把后续移动事件持续转给本窗口
//!     （app_capture），即使光标划出窗口也继续画——经典 GUI 捕获语义
//!   - 油漆桶 = 又一个四邻洪泛（显式栈；栈静态分配 190KB，不占内核栈）

const gui = @import("../gui.zig");

const Rect = gui.Rect;
const mkRect = gui.mkRect;
const inRect = gui.inRect;

const CANVAS_W = 380;
const CANVAS_H = 250;

const TOOLBAR_W: i32 = 64;
const SWATCH_W: i32 = 24;
const SWATCH_H: i32 = 13;

/// Win 调色板（16 色，与 VGA/Win3.1 经典色一致）；下标即画布像素值
const palette = [16][3]u8{
    .{ 0x00, 0x00, 0x00 }, // 0 黑
    .{ 0xFF, 0xFF, 0xFF }, // 1 白
    .{ 0xFF, 0x00, 0x00 }, // 2 红
    .{ 0x80, 0x00, 0x00 }, // 3 褐红
    .{ 0xFF, 0xFF, 0x00 }, // 4 黄
    .{ 0x80, 0x80, 0x00 }, // 5 橄榄
    .{ 0x00, 0xFF, 0x00 }, // 6 亮绿
    .{ 0x00, 0x80, 0x00 }, // 7 绿
    .{ 0x00, 0xFF, 0xFF }, // 8 青
    .{ 0x00, 0x80, 0x80 }, // 9 深青
    .{ 0x00, 0x00, 0xFF }, // 10 蓝
    .{ 0x00, 0x00, 0x80 }, // 11 藏青
    .{ 0xFF, 0x00, 0xFF }, // 12 品红
    .{ 0x80, 0x00, 0x80 }, // 13 紫
    .{ 0xC0, 0xC0, 0xC0 }, // 14 银灰
    .{ 0x80, 0x80, 0x80 }, // 15 灰
};

const Tool = enum { pencil, eraser, line, rect, fill };
const tool_names = [_][]const u8{ "P", "E", "L", "R", "F" };

var canvas: [CANVAS_W * CANVAS_H]u8 = undefined; // 像素 = 调色板下标
var snapshot: [CANVAS_W * CANVAS_H]u8 = undefined; // 橡皮筋预览用快照
var fill_stack: [CANVAS_W * CANVAS_H]u16 = undefined; // 油漆桶洪泛栈（静态）

var tool: Tool = .pencil;
var color: u8 = 0; // 当前前景色下标
var drawing: bool = false; // 捕获期间为真
var last_x: i32 = 0;
var last_y: i32 = 0;
var anchor_x: i32 = 0; // 直线/矩形起点
var anchor_y: i32 = 0;

fn palColor(i: u8) u32 {
    const c = palette[i & 15];
    return gui.px(c[0], c[1], c[2]);
}

// ---- 几何 ----

fn canvasRect(w: *const gui.Win) Rect {
    const cr = gui.clientRect(w);
    return mkRect(cr.x + TOOLBAR_W + 6, cr.y + 4, CANVAS_W + 2, CANVAS_H + 2);
}

fn swatchRect(w: *const gui.Win, i: usize) Rect {
    const cr = gui.clientRect(w);
    const col: i32 = @intCast(i % 2);
    const row: i32 = @intCast(i / 2);
    // 8 行 × 14（含 1px 缝），从工具栏顶部开始
    return mkRect(cr.x + 6 + col * (SWATCH_W + 2), cr.y + 6 + row * (SWATCH_H + 1), SWATCH_W, SWATCH_H);
}

fn toolRect(w: *const gui.Win, i: usize) Rect {
    const cr = gui.clientRect(w);
    // 色板占 8*14=112，工具按钮 5 个 × 24（20 高 + 4 缝）
    return mkRect(cr.x + 6, cr.y + 122 + @as(i32, @intCast(i)) * 24, 52, 20);
}

fn clearRect(w: *const gui.Win) Rect {
    const cr = gui.clientRect(w);
    return mkRect(cr.x + 6, cr.y + 246, 52, 20);
}

// ---- 画布操作（下标坐标系） ----

fn cset(x: i32, y: i32, c: u8) void {
    if (x < 0 or y < 0 or x >= CANVAS_W or y >= CANVAS_H) return;
    canvas[@intCast(y * CANVAS_W + x)] = c;
}

/// Bresenham 直线（带笔宽：thickness=1 画笔，9 橡皮）
fn cline(x0: i32, y0: i32, x1: i32, y1: i32, c: u8, thickness: i32) void {
    var x = x0;
    var y = y0;
    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        if (thickness <= 1) {
            cset(x, y, c);
        } else {
            const half = @divTrunc(thickness, 2);
            var ty = y - half;
            while (ty < y - half + thickness) : (ty += 1) {
                var tx = x - half;
                while (tx < x - half + thickness) : (tx += 1) cset(tx, ty, c);
            }
        }
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

fn crectOutline(x0: i32, y0: i32, x1: i32, y1: i32, c: u8) void {
    cline(x0, y0, x1, y0, c, 1);
    cline(x0, y1, x1, y1, c, 1);
    cline(x0, y0, x0, y1, c, 1);
    cline(x1, y0, x1, y1, c, 1);
}

/// 油漆桶：四邻洪泛替换同色连通区（显式栈，静态分配）
fn cfill(sx: i32, sy: i32, repl: u8) void {
    if (sx < 0 or sy < 0 or sx >= CANVAS_W or sy >= CANVAS_H) return;
    const target = canvas[@intCast(sy * CANVAS_W + sx)];
    if (target == repl) return;
    var sp: usize = 0;
    fill_stack[sp] = @intCast(sy * CANVAS_W + sx);
    sp += 1;
    while (sp > 0) {
        sp -= 1;
        const idx = fill_stack[sp];
        if (canvas[idx] != target) continue;
        canvas[idx] = repl;
        const px: i32 = @intCast(idx % CANVAS_W);
        const py: i32 = @intCast(idx / CANVAS_W);
        if (px > 0 and sp < fill_stack.len) {
            fill_stack[sp] = @intCast(idx - 1);
            sp += 1;
        }
        if (px < CANVAS_W - 1 and sp < fill_stack.len) {
            fill_stack[sp] = @intCast(idx + 1);
            sp += 1;
        }
        if (py > 0 and sp < fill_stack.len) {
            fill_stack[sp] = @intCast(idx - CANVAS_W);
            sp += 1;
        }
        if (py < CANVAS_H - 1 and sp < fill_stack.len) {
            fill_stack[sp] = @intCast(idx + CANVAS_W);
            sp += 1;
        }
    }
}

fn canvasOrigin(w: *const gui.Win) struct { x: i32, y: i32 } {
    const c = canvasRect(w);
    return .{ .x = c.x + 1, .y = c.y + 1 };
}

/// 屏幕坐标 → 画布下标（不在画布内返回 null）
fn toCanvas(w: *const gui.Win, x: i32, y: i32) ?struct { x: i32, y: i32 } {
    const o = canvasOrigin(w);
    const cx = x - o.x;
    const cy = y - o.y;
    if (cx < 0 or cy < 0 or cx >= CANVAS_W or cy >= CANVAS_H) return null;
    return .{ .x = cx, .y = cy };
}

fn damageCanvas(w: *const gui.Win) void {
    gui.addDamage(canvasRect(w));
}

// ---- 事件 ----

pub fn press(w: *const gui.Win, x: i32, y: i32) void {
    // 工具按钮
    for (tool_names, 0..) |_, i| {
        if (inRect(x, y, toolRect(w, i))) {
            tool = @enumFromInt(i);
            gui.addDamage(gui.clientRect(w)); // 工具栏按下态 + 画布无变化
            return;
        }
    }
    if (inRect(x, y, clearRect(w))) {
        @memset(canvas[0..], 1); // 清成白
        damageCanvas(w);
        return;
    }
    // 调色板
    for (0..palette.len) |i| {
        if (inRect(x, y, swatchRect(w, i))) {
            color = @intCast(i);
            gui.addDamage(gui.clientRect(w)); // 选中框 + 前景色指示条
            return;
        }
    }
    // 画布
    const p = toCanvas(w, x, y) orelse return;
    drawing = true;
    last_x = p.x;
    last_y = p.y;
    switch (tool) {
        .pencil => {
            cset(p.x, p.y, color);
            damageCanvas(w);
        },
        .eraser => {
            cline(p.x, p.y, p.x, p.y, 1, 9);
            damageCanvas(w);
        },
        .line, .rect => {
            @memcpy(snapshot[0..], canvas[0..]); // 橡皮筋快照
            anchor_x = p.x;
            anchor_y = p.y;
            damageCanvas(w);
        },
        .fill => {
            cfill(p.x, p.y, color);
            damageCanvas(w);
            drawing = false; // 单击完成
        },
    }
}

/// 鼠标捕获期间的移动（gui.onMouseDelta → apps.onMove → 这里）
pub fn move(w: *const gui.Win, x: i32, y: i32) void {
    if (!drawing) return;
    const p = toCanvas(w, x, y) orelse return;
    switch (tool) {
        .pencil => {
            cline(last_x, last_y, p.x, p.y, color, 1);
            damageCanvas(w);
        },
        .eraser => {
            cline(last_x, last_y, p.x, p.y, 1, 9);
            damageCanvas(w);
        },
        .line => { // 恢复快照 → 画预览线（松手时留下的就是成品）
            @memcpy(canvas[0..], snapshot[0..]);
            cline(anchor_x, anchor_y, p.x, p.y, color, 1);
            damageCanvas(w);
        },
        .rect => {
            @memcpy(canvas[0..], snapshot[0..]);
            crectOutline(anchor_x, anchor_y, p.x, p.y, color);
            damageCanvas(w);
        },
        .fill => {},
    }
    last_x = p.x;
    last_y = p.y;
}

/// 松开左键（gui 清除捕获时通知；直线/矩形此刻定稿——画布已是成品）
pub fn release() void {
    drawing = false;
}

// ---- 绘制 ----

pub fn paint(w: *const gui.Win) void {
    const cr = gui.clientRect(w);

    // 工具栏底
    gui.fillRect(mkRect(cr.x + 2, cr.y + 2, TOOLBAR_W, cr.h - 4), gui.pal.chrome);
    gui.bevel1(mkRect(cr.x + 2, cr.y + 2, TOOLBAR_W, cr.h - 4), false);

    // 16 色色板（2 列 × 8 行；选中色加黑框）
    for (0..palette.len) |i| {
        const r = swatchRect(w, i);
        gui.fillRect(r, palColor(@intCast(i)));
        if (color == i) {
            gui.hline(r.x - 1, r.x + r.w, r.y - 1, gui.pal.black);
            gui.hline(r.x - 1, r.x + r.w, r.y + r.h, gui.pal.black);
            gui.vline(r.x - 1, r.y - 1, r.y + r.h, gui.pal.black);
            gui.vline(r.x + r.w, r.y - 1, r.y + r.h, gui.pal.black);
        }
    }

    // 工具按钮（选中项凹下 + 当前色画小笔尖示意）
    for (tool_names, 0..) |name, i| {
        const r = toolRect(w, i);
        gui.fillRect(r, gui.pal.chrome);
        const sel = @intFromEnum(tool) == i;
        gui.bevel1(r, !sel);
        gui.text(r.x + 4, r.y + 3, name, gui.pal.black);
        gui.fillRect(mkRect(r.x + 36, r.y + 8, 10, 6), palColor(color));
    }

    // Clear 按钮
    const cb = clearRect(w);
    gui.fillRect(cb, gui.pal.chrome);
    gui.bevel1(cb, true);
    gui.text(cb.x + 8, cb.y + 3, "Clear", gui.pal.black);

    // 画布（白底凹框；只遍历 clip ∩ 画布 的行——笔划重绘代价 ~ 脏区大小）
    const c = canvasRect(w);
    gui.fillRect(c, gui.pal.white);
    gui.bevel1(c, false);
    const x0 = @max(gui.clipRect().x, c.x + 1);
    const y0 = @max(gui.clipRect().y, c.y + 1);
    const x1 = @min(gui.clipRect().x + gui.clipRect().w, c.x + 1 + CANVAS_W);
    const y1 = @min(gui.clipRect().y + gui.clipRect().h, c.y + 1 + CANVAS_H);
    var y = y0;
    while (y < y1) : (y += 1) {
        const row = (y - c.y - 1) * CANVAS_W;
        var x = x0;
        while (x < x1) : (x += 1) {
            gui.setPx(x, y, palColor(canvas[@intCast(row + (x - c.x - 1))]));
        }
    }
}
