//! Minesweeper —— 9x9 / 10 雷（自包含状态机型应用）
//!
//! 经典规则：左键翻开（首次点击保护：首格及其 8 邻不布雷，必有展开
//! 区），空白格洪泛展开（显式栈，81 格小深搜不递归）；右键插旗；翻开
//! 全部非雷格获胜（雷自动插旗）；踩雷 = 输（红底高亮、亮出所有雷）；
//! 笑脸按钮重开。布雷种子取 PIT 拍数（xorshift32），每次开局不同；
//! 计秒由 IRQ0 驱动。

const gui = @import("../gui.zig");
const pit = @import("../pit.zig");

const Rect = gui.Rect;
const mkRect = gui.mkRect;
const inRect = gui.inRect;

const MS_N = 9;
const MS_MINES = 10;
const MS_CELL: i32 = 20;
const MS_GRID_PX: i32 = MS_N * MS_CELL; // 180

const MsCell = struct {
    mine: bool = false,
    open: bool = false,
    flag: bool = false,
    adj: u8 = 0, // 周围雷数 0..8
};

const MsState = enum { ready, playing, won, lost };

var cells: [MS_N * MS_N]MsCell = undefined;
var state: MsState = .ready;
var flags: u8 = 0;
var opened: usize = 0;
var start_ms: u64 = 0;
var shown_sec: u32 = 0;
var boom: usize = 0xFFFF; // 踩中的那颗雷（输时红底高亮）
var rng: u32 = 1;

pub fn reset() void {
    for (&cells) |*c| c.* = .{};
    state = .ready;
    flags = 0;
    opened = 0;
    shown_sec = 0;
    boom = 0xFFFF;
}

fn gridRect(w: *const gui.Win) Rect {
    const cr = gui.clientRect(w);
    const gx = cr.x + @divTrunc(cr.w - MS_GRID_PX - 4, 2);
    return mkRect(gx, cr.y + 44, MS_GRID_PX + 4, MS_GRID_PX + 4);
}

fn faceRect(w: *const gui.Win) Rect {
    const cr = gui.clientRect(w);
    return mkRect(cr.x + @divTrunc(cr.w - 26, 2), cr.y + 6, 26, 26);
}

fn mineLedRect(w: *const gui.Win) Rect {
    const cr = gui.clientRect(w);
    return mkRect(cr.x + 8, cr.y + 9, 36, 20);
}

fn timerRect() Rect {
    const w = gui.windowByKind(.mine);
    const cr = gui.clientRect(w);
    return mkRect(cr.x + cr.w - 8 - 36, cr.y + 9, 36, 20);
}

/// IRQ0 每拍：计时器秒数变化才记脏区（窗口不可见时跳过）
pub fn tick() void {
    if (state != .playing) return;
    const w = gui.windowByKind(.mine);
    if (!w.visible) return;
    const sec: u32 = @intCast(@min((pit.uptimeMs() - start_ms) / 1000, 999));
    if (sec != shown_sec) {
        shown_sec = sec;
        gui.addDamage(timerRect());
    }
}

/// xorshift32（内核没有熵源，用 PIT 拍数做种子——每次开局都不同）
fn rand() u32 {
    var x = rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng = x;
    return x;
}

fn plant(safe: usize) void {
    rng = @truncate(pit.ticks | 1);
    const sx: i32 = @intCast(safe % MS_N);
    const sy: i32 = @intCast(safe / MS_N);
    var placed: usize = 0;
    while (placed < MS_MINES) {
        const idx = rand() % (MS_N * MS_N);
        if (idx == safe) continue;
        const cx: i32 = @intCast(idx % MS_N);
        const cy: i32 = @intCast(idx / MS_N);
        if (@abs(cx - sx) <= 1 and @abs(cy - sy) <= 1) continue; // 首击安全区
        if (cells[idx].mine) continue;
        cells[idx].mine = true;
        placed += 1;
    }
    for (0..MS_N * MS_N) |i| {
        if (cells[i].mine) continue;
        const cx: i32 = @intCast(i % MS_N);
        const cy: i32 = @intCast(i / MS_N);
        var n: u8 = 0;
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                if (dx == 0 and dy == 0) continue;
                const nx = cx + dx;
                const ny = cy + dy;
                if (nx < 0 or ny < 0 or nx >= MS_N or ny >= MS_N) continue;
                if (cells[@intCast(ny * MS_N + nx)].mine) n += 1;
            }
        }
        cells[i].adj = n;
    }
}

pub fn press(w: *const gui.Win, x: i32, y: i32) void {
    if (inRect(x, y, faceRect(w))) { // 笑脸 = 重开
        reset();
        gui.addDamage(gui.clientRect(w));
        return;
    }
    pressCell(w, x, y, false);
}

pub fn rightPress(w: *const gui.Win, x: i32, y: i32) void {
    pressCell(w, x, y, true);
}

fn pressCell(w: *const gui.Win, x: i32, y: i32, right: bool) void {
    if (state == .won or state == .lost) return; // 终局只能点笑脸重开
    const g = gridRect(w);
    if (!inRect(x, y, g)) return;
    const cx = @divTrunc(x - g.x - 2, MS_CELL);
    const cy = @divTrunc(y - g.y - 2, MS_CELL);
    if (cx < 0 or cy < 0 or cx >= MS_N or cy >= MS_N) return;
    const idx: usize = @intCast(cy * MS_N + cx);
    const c = &cells[idx];

    if (right) { // 插旗/拔旗（已翻开的格子无效）
        if (c.open) return;
        c.flag = !c.flag;
        if (c.flag) flags += 1 else flags -= 1; // 成对翻转，不会下溢
        gui.addDamage(cellRect(g, idx));
        return;
    }
    if (c.flag or c.open) return;

    if (state == .ready) { // 首次点击：此刻才布雷（保证首击安全）
        plant(idx);
        state = .playing;
        start_ms = pit.uptimeMs();
    }

    if (c.mine) {
        c.open = true;
        boom = idx;
        state = .lost;
        gui.addDamage(gui.clientRect(w));
        return;
    }

    // 洪泛展开：显式栈（81 格的小深搜，避免内核栈上的递归）
    var stack: [MS_N * MS_N]u8 = undefined;
    var sp: usize = 0;
    stack[sp] = @intCast(idx);
    sp += 1;
    while (sp > 0) {
        sp -= 1;
        const cur_i: usize = stack[sp];
        const cc = &cells[cur_i];
        if (cc.open or cc.flag) continue;
        cc.open = true;
        opened += 1;
        if (cc.adj != 0) continue; // 数字格不扩散
        const px: i32 = @intCast(cur_i % MS_N);
        const py: i32 = @intCast(cur_i / MS_N);
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                if (dx == 0 and dy == 0) continue;
                const nx = px + dx;
                const ny = py + dy;
                if (nx < 0 or ny < 0 or nx >= MS_N or ny >= MS_N) continue;
                const ni: usize = @intCast(ny * MS_N + nx);
                if (!cells[ni].open and sp < stack.len) {
                    stack[sp] = @intCast(ni);
                    sp += 1;
                }
            }
        }
    }

    if (opened == MS_N * MS_N - MS_MINES) { // 胜利：所有雷自动插旗
        state = .won;
        for (&cells) |*mc| {
            if (mc.mine) mc.flag = true;
        }
        flags = MS_MINES;
        gui.addDamage(gui.clientRect(w));
        return;
    }
    gui.addDamage(g);
}

fn cellRect(g: Rect, idx: usize) Rect {
    const cx: i32 = @intCast(idx % MS_N);
    const cy: i32 = @intCast(idx / MS_N);
    return mkRect(g.x + 2 + cx * MS_CELL, g.y + 2 + cy * MS_CELL, MS_CELL, MS_CELL);
}

pub fn paint(w: *const gui.Win) void {
    // 计数 LED：黑底红字
    const mines_left: i32 = @as(i32, MS_MINES) - flags;
    paintLed(mineLedRect(w), mines_left);
    const sec: i32 = if (state == .ready) 0 else @intCast(shown_sec);
    paintLed(timerRect(), sec);

    paintFace(faceRect(w));

    // 雷区：外凹框 + 9x9 格
    const g = gridRect(w);
    gui.fillRect(g, gui.pal.chrome);
    gui.bevel2(g, false);
    var i: usize = 0;
    while (i < MS_N * MS_N) : (i += 1) {
        paintCell(g, i);
    }
}

fn paintLed(r: Rect, v: i32) void {
    gui.fillRect(r, gui.pal.black);
    gui.bevel1(r, false);
    const shown: i32 = @max(0, @min(v, 999));
    const buf = [3]u8{
        '0' + @as(u8, @intCast(@divTrunc(shown, 100))),
        '0' + @as(u8, @intCast(@mod(@divTrunc(shown, 10), 10))),
        '0' + @as(u8, @intCast(@mod(shown, 10))),
    };
    gui.text(r.x + 6, r.y + 2, &buf, gui.px(0xFF, 0x00, 0x00));
}

fn paintCell(g: Rect, idx: usize) void {
    const r = cellRect(g, idx);
    const c = &cells[idx];
    const reveal = state == .lost or state == .won; // 终局亮出所有雷

    if (!c.open and !(reveal and c.mine)) {
        // 未翻开：凸起格子，插了旗画旗
        gui.fillRect(r, gui.pal.chrome);
        gui.bevel1(r, true);
        if (c.flag) paintFlag(r);
        return;
    }

    // 已翻开（或终局亮雷）：平底浅色格；踩中的那颗红底
    const bg: u32 = if (idx == boom) gui.px(0xFF, 0x00, 0x00) else gui.pal.white;
    gui.fillRect(r, bg);
    gui.hline(r.x, r.x + r.w - 1, r.y + r.h - 1, gui.pal.shadow);
    gui.vline(r.x + r.w - 1, r.y, r.y + r.h - 1, gui.pal.shadow);

    if (c.mine) {
        paintMineIcon(r);
    } else if (c.adj > 0) {
        const digit = [1]u8{'0' + c.adj};
        gui.text(r.x + 6, r.y + 2, &digit, numColor(c.adj));
    }
}

fn numColor(n: u8) u32 {
    return switch (n) {
        1 => gui.px(0x00, 0x00, 0xFF), // 蓝
        2 => gui.px(0x00, 0x80, 0x00), // 绿
        3 => gui.px(0xFF, 0x00, 0x00), // 红
        4 => gui.pal.navy,
        5 => gui.px(0x80, 0x00, 0x00), // 褐
        6 => gui.px(0x00, 0x80, 0x80), // 青
        7 => gui.pal.black,
        else => gui.pal.shadow, // 8
    };
}

fn paintMineIcon(r: Rect) void {
    // 黑圆雷 + 白高光 + 两根触角（经典造型）
    const cx = r.x + 10;
    const cy = r.y + 10;
    const black = gui.pal.black;
    gui.fillRect(mkRect(cx - 2, cy - 5, 5, 11), black);
    gui.fillRect(mkRect(cx - 4, cy - 3, 9, 7), black);
    gui.fillRect(mkRect(cx - 5, cy - 1, 11, 3), black);
    gui.fillRect(mkRect(cx - 1, cy - 8, 1, 3), black); // 上触角
    gui.fillRect(mkRect(cx + 3, cy + 5, 3, 1), black); // 下左刺
    gui.fillRect(mkRect(cx - 5, cy + 5, 3, 1), black); // 下右刺
    gui.setPx(cx - 2, cy - 2, gui.pal.white); // 高光
    gui.setPx(cx - 1, cy - 2, gui.pal.white);
    gui.setPx(cx - 2, cy - 1, gui.pal.white);
}

fn paintFlag(r: Rect) void {
    const black = gui.pal.black;
    const red = gui.px(0xFF, 0x00, 0x00);
    gui.fillRect(mkRect(r.x + 9, r.y + 4, 1, 9), black); // 旗杆
    gui.fillRect(mkRect(r.x + 4, r.y + 12, 8, 2), black); // 底座
    gui.fillRect(mkRect(r.x + 4, r.y + 4, 5, 1), red); // 三角旗
    gui.fillRect(mkRect(r.x + 4, r.y + 5, 4, 1), red);
    gui.fillRect(mkRect(r.x + 4, r.y + 6, 3, 1), red);
    gui.fillRect(mkRect(r.x + 4, r.y + 7, 2, 1), red);
}

// 笑脸：半径 10 的圆（每行跨度 comptime 算好），三种表情
const FACE_R = 10;
const face_spans: [2 * FACE_R + 1]i32 = blk: {
    var spans: [2 * FACE_R + 1]i32 = undefined;
    var dy: i32 = -FACE_R;
    while (dy <= FACE_R) : (dy += 1) {
        const d: f64 = @floatFromInt(dy);
        const r: f64 = @floatFromInt(FACE_R);
        spans[@intCast(dy + FACE_R)] = @intFromFloat(@sqrt(r * r - d * d));
    }
    break :blk spans;
};

fn paintFace(r: Rect) void {
    gui.fillRect(r, gui.pal.chrome);
    gui.bevel2(r, true);
    const cx = r.x + 13;
    const cy = r.y + 13;
    const yellow = gui.px(0xFF, 0xFF, 0x00);
    const black = gui.pal.black;

    // 黑描边圆盘 + 黄芯
    for (face_spans, 0..) |span, i| {
        const yy = cy - FACE_R + @as(i32, @intCast(i));
        gui.fillRect(mkRect(cx - span, yy, 2 * span + 1, 1), black);
    }
    for (face_spans[1 .. face_spans.len - 1], 1..) |span, i| {
        const yy = cy - FACE_R + @as(i32, @intCast(i));
        const s = @max(span - 2, 0);
        gui.fillRect(mkRect(cx - s, yy, 2 * s + 1, 1), yellow);
    }

    switch (state) {
        .lost => { // X 眼 + 苦嘴
            paintX(cx - 6, cy - 5);
            paintX(cx + 2, cy - 5);
            gui.fillRect(mkRect(cx - 2, cy + 4, 4, 1), black);
            gui.fillRect(mkRect(cx - 3, cy + 5, 6, 1), black);
        },
        .won => { // 墨镜 + 笑嘴
            gui.fillRect(mkRect(cx - 7, cy - 5, 6, 4), black);
            gui.fillRect(mkRect(cx + 1, cy - 5, 6, 4), black);
            gui.fillRect(mkRect(cx - 1, cy - 4, 2, 2), black); // 镜梁
            gui.fillRect(mkRect(cx - 5, cy + 3, 10, 1), black);
            gui.fillRect(mkRect(cx - 3, cy + 4, 6, 1), black);
            gui.fillRect(mkRect(cx - 1, cy + 5, 2, 1), black);
        },
        else => { // 常态：点眼 + 笑嘴
            gui.fillRect(mkRect(cx - 5, cy - 4, 2, 3), black);
            gui.fillRect(mkRect(cx + 3, cy - 4, 2, 3), black);
            gui.fillRect(mkRect(cx - 5, cy + 2, 10, 1), black);
            gui.fillRect(mkRect(cx - 4, cy + 3, 8, 1), black);
            gui.fillRect(mkRect(cx - 2, cy + 4, 4, 1), black);
        },
    }
}

fn paintX(x: i32, y: i32) void {
    var i: i32 = 0;
    while (i < 4) : (i += 1) {
        gui.setPx(x + i, y + i, gui.pal.black);
        gui.setPx(x + 3 - i, y + i, gui.pal.black);
    }
}
