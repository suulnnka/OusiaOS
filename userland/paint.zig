//! paint —— 画图（用户态 GUI 应用）
//!
//! 画布是本进程自己的静态数组（300x200，每像素 1 字节 = 调色板下标），
//! 与内核时代的实现同源：16 色板、画笔/橡皮（Bresenham）、直线/矩形
//! （快照+恢复的橡皮筋）、油漆桶（洪泛）。区别：鼠标事件来自
//! win_wait（捕获语义由内核保证——按住划出窗口也持续收到 EV_MOVE），
//! 画完把"画布 → 窗口表面"整幅刷新再 present。

const zos = @import("lib/zos.zig");
const win = @import("lib/win.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

const CW = 454;
const CH = 260;
const CANVAS_W = 300;
const CANVAS_H = 200;
const TOOLBAR_W = 64;

const palette = [16][3]u8{
    .{ 0x00, 0x00, 0x00 }, .{ 0xFF, 0xFF, 0xFF }, .{ 0xFF, 0x00, 0x00 }, .{ 0x80, 0x00, 0x00 },
    .{ 0xFF, 0xFF, 0x00 }, .{ 0x80, 0x80, 0x00 }, .{ 0x00, 0xFF, 0x00 }, .{ 0x00, 0x80, 0x00 },
    .{ 0x00, 0xFF, 0xFF }, .{ 0x00, 0x80, 0x80 }, .{ 0x00, 0x00, 0xFF }, .{ 0x00, 0x00, 0x80 },
    .{ 0xFF, 0x00, 0xFF }, .{ 0x80, 0x00, 0x80 }, .{ 0xC0, 0xC0, 0xC0 }, .{ 0x80, 0x80, 0x80 },
};

const Tool = enum { pencil, eraser, line, rect, fill };
const tool_names = [_][]const u8{ "P", "E", "L", "R", "F" };

var canvas: [CANVAS_W * CANVAS_H]u8 = @splat(1); // 1 = 白
var snapshot: [CANVAS_W * CANVAS_H]u8 = @splat(1); // 橡皮筋快照
var fill_stack: [CANVAS_W * CANVAS_H]u16 = @splat(0); // 洪泛栈
var pal32: [16]u32 = undefined;

var tool: Tool = .pencil;
var color: u8 = 0;
var drawing = false;
var last_x: i32 = 0;
var last_y: i32 = 0;
var anchor_x: i32 = 0;
var anchor_y: i32 = 0;
var dirty = true;

const CV_X = TOOLBAR_W + 8; // 画布在窗口里的位置
const CV_Y = 4;
const SWATCH_W = 24;
const SWATCH_H = 13;

fn inBox(x: i32, y: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return x >= bx and y >= by and x < bx + bw and y < by + bh;
}

fn swatchRect(i: usize) struct { x: i32, y: i32 } {
    const col: i32 = @intCast(i % 2);
    const row: i32 = @intCast(i / 2);
    return .{ .x = 6 + col * (SWATCH_W + 2), .y = 6 + row * (SWATCH_H + 1) };
}

fn toolRect(i: usize) struct { x: i32, y: i32 } {
    return .{ .x = 6, .y = 122 + @as(i32, @intCast(i)) * 24 };
}

fn clearRect() struct { x: i32, y: i32 } {
    return .{ .x = 6, .y = 246 };
}

// ---- 画布操作（下标坐标） ----

fn cset(x: i32, y: i32, c: u8) void {
    if (x < 0 or y < 0 or x >= CANVAS_W or y >= CANVAS_H) return;
    canvas[@intCast(y * CANVAS_W + x)] = c;
}

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

fn crect(x0: i32, y0: i32, x1: i32, y1: i32, c: u8) void {
    cline(x0, y0, x1, y0, c, 1);
    cline(x0, y1, x1, y1, c, 1);
    cline(x0, y0, x0, y1, c, 1);
    cline(x1, y0, x1, y1, c, 1);
}

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

fn toCanvas(x: i32, y: i32) ?struct { x: i32, y: i32 } {
    const cx = x - CV_X;
    const cy = y - CV_Y;
    if (cx < 0 or cy < 0 or cx >= CANVAS_W or cy >= CANVAS_H) return null;
    return .{ .x = cx, .y = cy };
}

// ---- 事件 ----

fn press(x: i32, y: i32) void {
    for (tool_names, 0..) |_, i| {
        const r = toolRect(i);
        if (inBox(x, y, r.x, r.y, 52, 20)) {
            tool = @enumFromInt(i);
            dirty = true;
            return;
        }
    }
    const c = clearRect();
    if (inBox(x, y, c.x, c.y, 52, 20)) {
        @memset(canvas[0..], 1);
        dirty = true;
        return;
    }
    for (0..palette.len) |i| {
        const r = swatchRect(i);
        if (inBox(x, y, r.x, r.y, SWATCH_W, SWATCH_H)) {
            color = @intCast(i);
            dirty = true;
            return;
        }
    }
    const p = toCanvas(x, y) orelse return;
    drawing = true;
    last_x = p.x;
    last_y = p.y;
    switch (tool) {
        .pencil => {
            cset(p.x, p.y, color);
            dirty = true;
        },
        .eraser => {
            cline(p.x, p.y, p.x, p.y, 1, 9);
            dirty = true;
        },
        .line, .rect => {
            @memcpy(snapshot[0..], canvas[0..]);
            anchor_x = p.x;
            anchor_y = p.y;
            dirty = true;
        },
        .fill => {
            cfill(p.x, p.y, color);
            dirty = true;
            drawing = false;
        },
    }
}

fn moveEvt(x: i32, y: i32) void {
    if (!drawing) return;
    const p = toCanvas(x, y) orelse return;
    switch (tool) {
        .pencil => {
            cline(last_x, last_y, p.x, p.y, color, 1);
            dirty = true;
        },
        .eraser => {
            cline(last_x, last_y, p.x, p.y, 1, 9);
            dirty = true;
        },
        .line => {
            @memcpy(canvas[0..], snapshot[0..]);
            cline(anchor_x, anchor_y, p.x, p.y, color, 1);
            dirty = true;
        },
        .rect => {
            @memcpy(canvas[0..], snapshot[0..]);
            crect(anchor_x, anchor_y, p.x, p.y, color);
            dirty = true;
        },
        .fill => {},
    }
    last_x = p.x;
    last_y = p.y;
}

fn release() void {
    drawing = false;
}

// ---- 绘制 ----

fn draw() void {
    win.fillRect(0, 0, CW, CH, win.C_CHROME);

    // 工具栏
    win.fillRect(2, 2, TOOLBAR_W, CH - 4, win.C_CHROME);
    win.bevel(2, 2, TOOLBAR_W, CH - 4, false);
    for (0..palette.len) |i| {
        const r = swatchRect(i);
        win.fillRect(r.x, r.y, SWATCH_W, SWATCH_H, pal32[i]);
        if (color == i) {
            win.fillRect(r.x, r.y - 1, SWATCH_W, 1, win.C_BLACK);
            win.fillRect(r.x, r.y + SWATCH_H, SWATCH_W, 1, win.C_BLACK);
            win.fillRect(r.x - 1, r.y - 1, 1, SWATCH_H + 2, win.C_BLACK);
            win.fillRect(r.x + SWATCH_W, r.y - 1, 1, SWATCH_H + 2, win.C_BLACK);
        }
    }
    for (tool_names, 0..) |name, i| {
        const r = toolRect(i);
        win.fillRect(r.x, r.y, 52, 20, win.C_CHROME);
        win.bevel(r.x, r.y, 52, 20, @intFromEnum(tool) != i);
        win.text(r.x + 4, r.y + 2, name, win.C_BLACK);
        win.fillRect(r.x + 36, r.y + 7, 10, 6, pal32[color]);
    }
    const c = clearRect();
    win.fillRect(c.x, c.y, 52, 20, win.C_CHROME);
    win.bevel(c.x, c.y, 52, 20, true);
    win.text(c.x + 8, c.y + 2, "Clear", win.C_BLACK);

    // 画布（白底凹框 + 位图搬运）
    win.fillRect(CV_X - 1, CV_Y - 1, CANVAS_W + 2, CANVAS_H + 2, win.C_WHITE);
    win.bevel(CV_X - 1, CV_Y - 1, CANVAS_W + 2, CANVAS_H + 2, false);
    var y: i32 = 0;
    while (y < CANVAS_H) : (y += 1) {
        var x: i32 = 0;
        while (x < CANVAS_W) : (x += 1) {
            win.set(CV_X + x, CV_Y + y, pal32[canvas[@intCast(y * CANVAS_W + x)]]);
        }
    }
}

export fn main() i32 {
    if (!win.create(CW, CH, "Paint")) return 1;
    win.initColors();
    for (0..palette.len) |i| {
        pal32[i] = win.color(palette[i][0], palette[i][1], palette[i][2]);
    }

    var evs: [8]win.Event = undefined;
    while (true) {
        if (dirty) {
            draw();
            win.present();
            dirty = false;
        }
        const n = win.wait(&evs, 0);
        for (evs[0..n]) |e| {
            switch (e.kind) {
                win.EV_CLOSE => zos.exit(0),
                win.EV_PRESS => press(e.x, e.y),
                win.EV_MOVE => moveEvt(e.x, e.y),
                win.EV_RELEASE => release(),
                else => {},
            }
        }
    }
    return 0;
}
