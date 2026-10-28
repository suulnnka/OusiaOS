//! paint —— 画图（用户态 GUI 应用）
//!
//! 画布是本进程自己的静态数组（300x200，每像素 1 字节 = 调色板下标）。
//! 工具集（"线条/圆/多边形"特性 + 练习⑥）：
//!   - 铅笔/橡皮/刷子（宽度 1/2/4/8 的 Bresenham）
//!   - 直线/矩形/实心矩形/椭圆（快照+恢复的橡皮筋预览）
//!   - 多边形：单击落顶点，双击（或回车）闭合并填充——polyFill 扫描线
//!   - 油漆桶（洪泛）、撤销栈（8 步快照环，Ctrl+Z / Edit 菜单）
//!   - MenuBar：File(New/Exit) Edit(Undo/Clear)
//! 鼠标事件来自 win_wait（捕获语义由内核保证——按住划出窗口也持续
//! 收到 EV_MOVE），画完把"画布 → 窗口表面"整幅刷新再 present。

const ousia = @import("lib/ousia.zig");
const win = @import("lib/win.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

const CW = 454;
const CH = 264;
const CANVAS_W = 300;
const CANVAS_H = 200;
const TOOLBAR_W = 64;
const UNDO_DEPTH = 8;

const palette = [16][3]u8{
    .{ 0x00, 0x00, 0x00 }, .{ 0xFF, 0xFF, 0xFF }, .{ 0xFF, 0x00, 0x00 }, .{ 0x80, 0x00, 0x00 },
    .{ 0xFF, 0xFF, 0x00 }, .{ 0x80, 0x80, 0x00 }, .{ 0x00, 0xFF, 0x00 }, .{ 0x00, 0x80, 0x00 },
    .{ 0x00, 0xFF, 0xFF }, .{ 0x00, 0x80, 0x80 }, .{ 0x00, 0x00, 0xFF }, .{ 0x00, 0x00, 0x80 },
    .{ 0xFF, 0x00, 0xFF }, .{ 0x80, 0x00, 0x80 }, .{ 0xC0, 0xC0, 0xC0 }, .{ 0x80, 0x80, 0x80 },
};

const Tool = enum { pencil, eraser, line, rect, frect, ellipse, polygon, fill };
const tool_names = [_][]const u8{ "Pen", "Era", "Line", "Box", "FillB", "Oval", "Poly", "Fill" };
const brush_widths = [_]i32{ 1, 2, 4, 8 };

var canvas: [CANVAS_W * CANVAS_H]u8 = @splat(1); // 1 = 白
var snapshot: [CANVAS_W * CANVAS_H]u8 = @splat(1); // 橡皮筋快照
var fill_stack: [CANVAS_W * CANVAS_H]u16 = @splat(0); // 洪泛栈
var pal32: [16]u32 = undefined;

// 撤销栈（快照环；静态 480KB 放 .bss——教学版不用 malloc）
var undo_buf: [UNDO_DEPTH][CANVAS_W * CANVAS_H]u8 = undefined;
var undo_len: usize = 0; // 已存快照数
var undo_head: usize = 0; // 下一个写入位置（环）

var tool: Tool = .pencil;
var color: u8 = 0;
var brush: usize = 0; // brush_widths 下标
var drawing = false;
var last_x: i32 = 0;
var last_y: i32 = 0;
var anchor_x: i32 = 0;
var anchor_y: i32 = 0;
// 多边形进行中的顶点（客户区画布坐标）
var poly_pts: [16][2]i32 = undefined;
var poly_n: usize = 0;
var dirty = true;

// ---- 菜单 ----
const file_items = [_][]const u8{ "New", "", "Exit" };
const edit_items = [_][]const u8{ "Undo  Ctrl+Z", "Clear Canvas" };
const menu_defs = [_]win.MenuDef{
    .{ .label = "File", .items = &file_items },
    .{ .label = "Edit", .items = &edit_items },
};
var menubar = win.MenuBar{ .defs = &menu_defs };
var menu_item_out: win.MenuHit = .{ .menu = 0, .idx = 0 };

const CV_X = TOOLBAR_W + 8; // 画布在窗口里的位置
const CV_Y = MENUBAR_H + 6;
const MENUBAR_H = 18;
const SWATCH_W = 24;
const SWATCH_H = 13;

fn inBox(x: i32, y: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return x >= bx and y >= by and x < bx + bw and y < by + bh;
}

fn swatchRect(i: usize) struct { x: i32, y: i32 } {
    const col: i32 = @intCast(i % 2);
    const row: i32 = @intCast(i / 2);
    return .{ .x = 6 + col * (SWATCH_W + 2), .y = MENUBAR_H + 4 + row * (SWATCH_H + 1) };
}

fn toolRect(i: usize) struct { x: i32, y: i32 } {
    // 两列四行（8 个工具）；每个 26x20，行距 24
    const col: i32 = @intCast(i % 2);
    const row: i32 = @intCast(i / 2);
    return .{ .x = 6 + col * 28, .y = MENUBAR_H + 150 + row * 24 };
}

fn brushRect(i: usize) struct { x: i32, y: i32 } {
    return .{ .x = 6 + @as(i32, @intCast(i)) * 14, .y = MENUBAR_H + 134 };
}

// ---- 撤销 ----

fn pushUndo() void {
    undo_buf[undo_head] = canvas;
    undo_head = (undo_head + 1) % UNDO_DEPTH;
    if (undo_len < UNDO_DEPTH) undo_len += 1;
}

fn undo() void {
    if (undo_len == 0) {
        win.sound(5);
        return;
    }
    undo_head = (undo_head + UNDO_DEPTH - 1) % UNDO_DEPTH;
    undo_len -= 1;
    canvas = undo_buf[undo_head];
    poly_n = 0;
    dirty = true;
    win.sound(3);
}

// ---- 画布操作（下标坐标） ----

fn cset(x: i32, y: i32, c: u8) void {
    if (x < 0 or y < 0 or x >= CANVAS_W or y >= CANVAS_H) return;
    canvas[@intCast(y * CANVAS_W + x)] = c;
}

/// 按当前刷子宽度落一个"笔触点"（宽度 = 正方形块）
fn cdot(x: i32, y: i32, c: u8, w: i32) void {
    if (w <= 1) {
        cset(x, y, c);
        return;
    }
    const half = @divTrunc(w, 2);
    var ty = y - half;
    while (ty < y - half + w) : (ty += 1) {
        var tx = x - half;
        while (tx < x - half + w) : (tx += 1) cset(tx, ty, c);
    }
}

fn cline(x0: i32, y0: i32, x1: i32, y1: i32, c: u8, w: i32) void {
    var x = x0;
    var y = y0;
    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        cdot(x, y, c, w);
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

fn crect(x0: i32, y0: i32, x1: i32, y1: i32, c: u8, filled: bool) void {
    if (filled) {
        const lx = @min(x0, x1);
        const hx = @max(x0, x1);
        const ly = @min(y0, y1);
        const hy = @max(y0, y1);
        var yy = ly;
        while (yy <= hy) : (yy += 1) {
            var xx = lx;
            while (xx <= hx) : (xx += 1) cset(xx, yy, c);
        }
        return;
    }
    cline(x0, y0, x1, y0, c, 1);
    cline(x0, y1, x1, y1, c, 1);
    cline(x0, y0, x0, y1, c, 1);
    cline(x1, y0, x1, y1, c, 1);
}

fn cellipse(x0: i32, y0: i32, x1: i32, y1: i32, c: u8) void {
    // 外接矩形 → 中心/半径（最小 1 防除零/不可见）
    const cx = @divTrunc(x0 + x1, 2);
    const cy = @divTrunc(y0 + y1, 2);
    const adx: i32 = if (x1 > x0) x1 - x0 else x0 - x1;
    const ady: i32 = if (y1 > y0) y1 - y0 else y0 - y1;
    const rx: i32 = @max(@divTrunc(adx, 2), 1);
    const ry: i32 = @max(@divTrunc(ady, 2), 1);
    // 参数方程步进（@cos/@sin 不可用于 freestanding 运行时——
    // 用逐行扫描：每行左右端点，与 lib/win.ellipse 同思路）
    var dy: i32 = -ry;
    while (dy <= ry) : (dy += 1) {
        const t = 1.0 - (@as(f32, @floatFromInt(dy)) * @as(f32, @floatFromInt(dy))) / (@as(f32, @floatFromInt(ry)) * @as(f32, @floatFromInt(ry)));
        if (t < 0) continue;
        const h: i32 = @intFromFloat(@sqrt(t) * @as(f32, @floatFromInt(rx)) + 0.5);
        cset(cx - h, cy + dy, c);
        cset(cx + h, cy + dy, c);
    }
    var dx: i32 = -rx;
    while (dx <= rx) : (dx += 1) {
        const t = 1.0 - (@as(f32, @floatFromInt(dx)) * @as(f32, @floatFromInt(dx))) / (@as(f32, @floatFromInt(rx)) * @as(f32, @floatFromInt(rx)));
        if (t < 0) continue;
        const v: i32 = @intFromFloat(@sqrt(t) * @as(f32, @floatFromInt(ry)) + 0.5);
        cset(cx + dx, cy - v, c);
        cset(cx + dx, cy + v, c);
    }
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

/// 顶点数组 → 画布坐标画多边形（描边 + 当前色填充）
fn cpoly(pts: []const [2]i32, c: u8) void {
    if (pts.len < 3) {
        if (pts.len == 2) cline(pts[0][0], pts[0][1], pts[1][0], pts[1][1], c, 1);
        return;
    }
    // lib/win.polyFill 是屏幕像素——画布坐标需要自己的扫描线；
    // 复用 win.polyFill 不可行（它画到窗口表面），这里走"洪泛式"取巧：
    // 先描边，再对包围盒每行求交（同 win.polyFill 算法，落 cset）
    var min_y: i32 = pts[0][1];
    var max_y: i32 = pts[0][1];
    for (pts) |p| {
        min_y = @min(min_y, p[1]);
        max_y = @max(max_y, p[1]);
    }
    var xs: [16]i32 = undefined;
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var n: usize = 0;
        for (pts, 0..) |a, i| {
            const b = pts[(i + 1) % pts.len];
            if (a[1] == b[1]) continue;
            const lo = @min(a[1], b[1]);
            const hi = @max(a[1], b[1]);
            if (y < lo or y >= hi) continue;
            const t = @divTrunc((y - a[1]) * 65536, b[1] - a[1]);
            const xi = a[0] + @divTrunc((b[0] - a[0]) * t, 65536);
            if (n < xs.len) {
                xs[n] = xi;
                n += 1;
            }
        }
        var k: usize = 1;
        while (k < n) : (k += 1) {
            const kv = xs[k];
            var j = k;
            while (j > 0 and xs[j - 1] > kv) : (j -= 1) xs[j] = xs[j - 1];
            xs[j] = kv;
        }
        var m: usize = 0;
        while (m + 1 < n) : (m += 2) {
            var xx = xs[m];
            while (xx <= xs[m + 1]) : (xx += 1) cset(xx, y, c);
        }
    }
    // 描边盖在填充上（边界清晰）
    var i: usize = 0;
    while (i < pts.len) : (i += 1) {
        const a = pts[i];
        const b = pts[(i + 1) % pts.len];
        cline(a[0], a[1], b[0], b[1], c, 1);
    }
}

fn toCanvas(x: i32, y: i32) ?struct { x: i32, y: i32 } {
    const cx = x - CV_X;
    const cy = y - CV_Y;
    if (cx < 0 or cy < 0 or cx >= CANVAS_W or cy >= CANVAS_H) return null;
    return .{ .x = cx, .y = cy };
}

// ---- 事件 ----

fn handleMenu() void {
    switch (menu_item_out.menu) {
        0 => switch (menu_item_out.idx) {
            0 => {
                pushUndo();
                @memset(canvas[0..], 1);
                poly_n = 0;
                win.sound(2);
            },
            1 => {},
            2 => ousia.exit(0),
            else => {},
        },
        1 => switch (menu_item_out.idx) {
            0 => undo(),
            1 => {
                pushUndo();
                @memset(canvas[0..], 1);
                poly_n = 0;
            },
            else => {},
        },
        else => {},
    }
    dirty = true;
}

fn press(x: i32, y: i32) void {
    // 菜单栏
    if (menubar.press(x, y, &menu_item_out)) {
        handleMenu();
        return;
    }
    // 工具
    for (tool_names, 0..) |_, i| {
        const r = toolRect(i);
        if (inBox(x, y, r.x, r.y, 52, 20)) {
            tool = @enumFromInt(i);
            poly_n = 0;
            dirty = true;
            return;
        }
    }
    // 刷子宽度
    for (brush_widths, 0..) |_, i| {
        const r = brushRect(i);
        if (inBox(x, y, r.x, r.y, 12, 12)) {
            brush = i;
            dirty = true;
            return;
        }
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
            pushUndo();
            cdot(p.x, p.y, color, brush_widths[brush]);
            dirty = true;
        },
        .eraser => {
            pushUndo();
            cline(p.x, p.y, p.x, p.y, 1, 9);
            dirty = true;
        },
        .line, .rect, .frect, .ellipse => {
            pushUndo();
            @memcpy(snapshot[0..], canvas[0..]);
            anchor_x = p.x;
            anchor_y = p.y;
            dirty = true;
        },
        .polygon => {
            // 落顶点；16 个封顶自动闭合
            if (poly_n == 0) pushUndo();
            if (poly_n < poly_pts.len) {
                poly_pts[poly_n] = .{ p.x, p.y };
                poly_n += 1;
            }
            if (poly_n == poly_pts.len) closePoly();
            dirty = true;
            drawing = false;
        },
        .fill => {
            pushUndo();
            cfill(p.x, p.y, color);
            dirty = true;
            drawing = false;
        },
    }
}

fn closePoly() void {
    if (poly_n >= 3) {
        cpoly(poly_pts[0..poly_n], color);
        win.sound(2);
    }
    poly_n = 0;
}

fn moveEvt(x: i32, y: i32) void {
    if (!drawing) return;
    const p = toCanvas(x, y) orelse return;
    switch (tool) {
        .pencil => {
            cline(last_x, last_y, p.x, p.y, color, brush_widths[brush]);
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
            crect(anchor_x, anchor_y, p.x, p.y, color, false);
            dirty = true;
        },
        .frect => {
            @memcpy(canvas[0..], snapshot[0..]);
            crect(anchor_x, anchor_y, p.x, p.y, color, true);
            dirty = true;
        },
        .ellipse => {
            @memcpy(canvas[0..], snapshot[0..]);
            cellipse(anchor_x, anchor_y, p.x, p.y, color);
            dirty = true;
        },
        .polygon => {},
        .fill => {},
    }
    last_x = p.x;
    last_y = p.y;
}

fn release() void {
    drawing = false;
}

fn key(c: u8) void {
    switch (c) {
        win.CTRL_Z => undo(),
        0x0D, '\n' => {
            if (tool == .polygon and poly_n >= 3) {
                closePoly();
                dirty = true;
            }
        },
        0x1B => { // Esc：取消进行中的多边形（回滚到快照）
            if (tool == .polygon and poly_n > 0) {
                poly_n = 0;
                undo();
            }
        },
        else => {},
    }
}

// ---- 绘制 ----

fn draw() void {
    win.fillRect(0, 0, CW, CH, win.C_CHROME);
    menubar.draw(CW);

    // 工具栏
    win.fillRect(2, MENUBAR_H + 2, TOOLBAR_W, CH - MENUBAR_H - 4, win.C_CHROME);
    win.bevel(2, MENUBAR_H + 2, TOOLBAR_W, CH - MENUBAR_H - 4, false);
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
    // 刷子宽度选择（点越大越粗）
    for (brush_widths, 0..) |w, i| {
        const r = brushRect(i);
        win.fillRect(r.x, r.y, 12, 12, win.C_CHROME);
        win.bevel(r.x, r.y, 12, 12, brush != i);
        const dot: i32 = if (w == 1) 2 else if (w == 2) 4 else if (w == 4) 6 else 9;
        const off = @divTrunc(12 - dot, 2);
        win.fillRect(r.x + off, r.y + off, dot, dot, win.C_BLACK);
    }
    for (tool_names, 0..) |name, i| {
        const r = toolRect(i);
        win.fillRect(r.x, r.y, 52, 20, win.C_CHROME);
        win.bevel(r.x, r.y, 52, 20, @intFromEnum(tool) != i);
        win.text(r.x + 4, r.y + 2, name, win.C_BLACK);
        win.fillRect(r.x + 36, r.y + 7, 10, 6, pal32[color]);
    }
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
    // 多边形进行中：已落顶点之间的预览线（画在表面层，不进画布）
    if (poly_n > 0) {
        var i: usize = 0;
        while (i + 1 < poly_n) : (i += 1) {
            win.line(CV_X + poly_pts[i][0], CV_Y + poly_pts[i][1], CV_X + poly_pts[i + 1][0], CV_Y + poly_pts[i + 1][1], pal32[color]);
        }
        // 光标处到首点的虚线提示（简单画一条到首点的线）
        if (poly_n >= 2) {
            win.line(CV_X + poly_pts[poly_n - 1][0], CV_Y + poly_pts[poly_n - 1][1], CV_X + poly_pts[0][0], CV_Y + poly_pts[0][1], pal32[palette.len - 1]);
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
                win.EV_CLOSE => ousia.exit(0),
                win.EV_PRESS => press(e.x, e.y),
                win.EV_DBL => {
                    if (tool == .polygon) {
                        closePoly();
                        dirty = true;
                    } else {
                        press(e.x, e.y);
                    }
                },
                win.EV_MOVE => moveEvt(e.x, e.y),
                win.EV_RELEASE => release(),
                win.EV_KEY => key(e.code),
                win.EV_RESIZE => { win.onResizeEvent(e); dirty = true; },
                else => {},
            }
        }
    }
    return 0;
}
