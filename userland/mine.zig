//! mine —— 扫雷（用户态 GUI 应用）
//!
//! 与内核版同规则：9x9/10 雷、首击保护（首格及 8 邻不布雷）、空白
//! 洪泛（显式栈）、右键插旗、笑脸重开、雷数/计时 LED。计时用
//! SYS_time（开机秒）；主循环 win_wait(1000)——没事件也每秒醒一拍
//! 刷新计时器，这是事件驱动应用里"低频定时"的标准做法。

const zos = @import("lib/zos.zig");
const win = @import("lib/win.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

const CW = 194;
const CH = 231;
const N = 9;
const MINES = 10;
const CELL = 20;
const GRID_PX = N * CELL;

const Cell = struct {
    mine: bool = false,
    open: bool = false,
    flag: bool = false,
    adj: u8 = 0,
};

const State = enum { ready, playing, won, lost };

var cells: [N * N]Cell = undefined;
var state: State = .ready;
var flags: u8 = 0;
var opened: usize = 0;
var start_sec: i64 = 0;
var shown_sec: u32 = 0;
var boom: usize = 0xFFFF;
var rng: u32 = 1;
var dirty = true;

// 棋盘几何（客户区内）
const GRID_X = 5;
const GRID_Y = 44;
const LED_Y = 9;
const FACE_X = @divTrunc(CW - 26, 2);
const FACE_Y = 6;

// 简易 xorshift：种子取 SYS_time + pid 混合
fn rand() u32 {
    var x = rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng = x;
    return x;
}

fn reset() void {
    for (&cells) |*c| c.* = .{};
    state = .ready;
    flags = 0;
    opened = 0;
    shown_sec = 0;
    boom = 0xFFFF;
    dirty = true;
}

fn plant(safe: usize) void {
    rng = @truncate(@as(u64, @bitCast(zos.time())) ^ @as(u64, @intCast(zos.getpid())) << 16 | 1);
    const sx: i32 = @intCast(safe % N);
    const sy: i32 = @intCast(safe / N);
    var placed: usize = 0;
    while (placed < MINES) {
        const idx = rand() % (N * N);
        if (idx == safe) continue;
        const cx: i32 = @intCast(idx % N);
        const cy: i32 = @intCast(idx / N);
        if (@abs(cx - sx) <= 1 and @abs(cy - sy) <= 1) continue;
        if (cells[idx].mine) continue;
        cells[idx].mine = true;
        placed += 1;
    }
    for (0..N * N) |i| {
        if (cells[i].mine) continue;
        const cx: i32 = @intCast(i % N);
        const cy: i32 = @intCast(i / N);
        var n: u8 = 0;
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                if (dx == 0 and dy == 0) continue;
                const nx = cx + dx;
                const ny = cy + dy;
                if (nx < 0 or ny < 0 or nx >= N or ny >= N) continue;
                if (cells[@intCast(ny * N + nx)].mine) n += 1;
            }
        }
        cells[i].adj = n;
    }
}

fn cellRect(idx: usize) struct { x: i32, y: i32 } {
    const cx: i32 = @intCast(idx % N);
    const cy: i32 = @intCast(idx / N);
    return .{ .x = GRID_X + 2 + cx * CELL, .y = GRID_Y + 2 + cy * CELL };
}

fn press(x: i32, y: i32, right: bool) void {
    // 笑脸 = 重开
    if (x >= FACE_X and y >= FACE_Y and x < FACE_X + 26 and y < FACE_Y + 26) {
        reset();
        return;
    }
    if (state == .won or state == .lost) return;
    if (x < GRID_X + 2 or y < GRID_Y + 2 or x >= GRID_X + 2 + GRID_PX or y >= GRID_Y + 2 + GRID_PX) return;
    const cx = @divTrunc(x - GRID_X - 2, CELL);
    const cy = @divTrunc(y - GRID_Y - 2, CELL);
    if (cx < 0 or cy < 0 or cx >= N or cy >= N) return;
    const idx: usize = @intCast(cy * N + cx);
    const c = &cells[idx];

    if (right) {
        if (c.open) return;
        c.flag = !c.flag;
        if (c.flag) flags += 1 else flags -= 1;
        dirty = true;
        return;
    }
    if (c.flag or c.open) return;
    if (state == .ready) {
        plant(idx);
        state = .playing;
        start_sec = zos.time();
    }
    if (c.mine) {
        c.open = true;
        boom = idx;
        state = .lost;
        dirty = true;
        return;
    }

    var stack: [N * N]u8 = undefined;
    var sp: usize = 0;
    stack[sp] = @intCast(idx);
    sp += 1;
    while (sp > 0) {
        sp -= 1;
        const cur: usize = stack[sp];
        const cc = &cells[cur];
        if (cc.open or cc.flag) continue;
        cc.open = true;
        opened += 1;
        if (cc.adj != 0) continue;
        const px: i32 = @intCast(cur % N);
        const py: i32 = @intCast(cur / N);
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                if (dx == 0 and dy == 0) continue;
                const nx = px + dx;
                const ny = py + dy;
                if (nx < 0 or ny < 0 or nx >= N or ny >= N) continue;
                const ni: usize = @intCast(ny * N + nx);
                if (!cells[ni].open and sp < stack.len) {
                    stack[sp] = @intCast(ni);
                    sp += 1;
                }
            }
        }
    }
    if (opened == N * N - MINES) {
        state = .won;
        for (&cells) |*mc| {
            if (mc.mine) mc.flag = true;
        }
        flags = MINES;
    }
    dirty = true;
}

// ---- 绘制 ----

fn draw() void {
    win.fillRect(0, 0, CW, CH, win.C_CHROME);

    if (state == .playing) {
        const sec: u32 = @intCast(@min(@max(zos.time() - start_sec, 0), 999));
        if (sec != shown_sec) shown_sec = sec;
    }
    drawLed(8, LED_Y, @as(i32, MINES) - flags);
    drawLed(CW - 8 - 36, LED_Y, @intCast(shown_sec));
    drawFace();

    // 雷区外凹框
    win.fillRect(GRID_X, GRID_Y, GRID_PX + 4, GRID_PX + 4, win.C_CHROME);
    win.bevel(GRID_X, GRID_Y, GRID_PX + 4, GRID_PX + 4, false);
    var i: usize = 0;
    while (i < N * N) : (i += 1) drawCell(i);
}

fn drawLed(x: i32, y: i32, v: i32) void {
    win.fillRect(x, y, 36, 20, win.C_BLACK);
    win.bevel(x, y, 36, 20, false);
    const shown: i32 = @max(0, @min(v, 999));
    const b = [3]u8{
        '0' + @as(u8, @intCast(@divTrunc(shown, 100))),
        '0' + @as(u8, @intCast(@mod(@divTrunc(shown, 10), 10))),
        '0' + @as(u8, @intCast(@mod(shown, 10))),
    };
    win.text(x + 6, y + 2, &b, win.C_RED);
}

fn drawCell(idx: usize) void {
    const r = cellRect(idx);
    const c = &cells[idx];
    const reveal = state == .lost or state == .won;

    if (!c.open and !(reveal and c.mine)) {
        win.fillRect(r.x, r.y, CELL, CELL, win.C_CHROME);
        win.bevel(r.x, r.y, CELL, CELL, true);
        if (c.flag) drawFlag(r.x, r.y);
        return;
    }
    const boom_bg = if (idx == boom) win.C_RED else win.C_WHITE;
    win.fillRect(r.x, r.y, CELL, CELL, boom_bg);
    win.fillRect(r.x, r.y + CELL - 1, CELL, 1, win.C_SHADOW);
    win.fillRect(r.x + CELL - 1, r.y, 1, CELL, win.C_SHADOW);
    if (c.mine) {
        drawMine(r.x, r.y);
    } else if (c.adj > 0) {
        const digit = [1]u8{'0' + c.adj};
        win.text(r.x + 6, r.y + 2, &digit, numColor(c.adj));
    }
}

fn numColor(n: u8) u32 {
    return switch (n) {
        1 => win.color(0, 0, 255),
        2 => win.color(0, 128, 0),
        3 => win.C_RED,
        4 => win.C_NAVY,
        5 => win.color(128, 0, 0),
        6 => win.color(0, 128, 128),
        7 => win.C_BLACK,
        else => win.C_SHADOW,
    };
}

fn drawMine(x: i32, y: i32) void {
    const cx = x + 10;
    const cy = y + 10;
    win.fillRect(cx - 2, cy - 5, 5, 11, win.C_BLACK);
    win.fillRect(cx - 4, cy - 3, 9, 7, win.C_BLACK);
    win.fillRect(cx - 5, cy - 1, 11, 3, win.C_BLACK);
    win.fillRect(cx - 1, cy - 8, 1, 3, win.C_BLACK);
    win.fillRect(cx + 3, cy + 5, 3, 1, win.C_BLACK);
    win.fillRect(cx - 5, cy + 5, 3, 1, win.C_BLACK);
    win.set(cx - 2, cy - 2, win.C_WHITE);
    win.set(cx - 1, cy - 2, win.C_WHITE);
    win.set(cx - 2, cy - 1, win.C_WHITE);
}

fn drawFlag(x: i32, y: i32) void {
    const red = win.C_RED;
    win.fillRect(x + 9, y + 4, 1, 9, win.C_BLACK);
    win.fillRect(x + 4, y + 12, 8, 2, win.C_BLACK);
    win.fillRect(x + 4, y + 4, 5, 1, red);
    win.fillRect(x + 4, y + 5, 4, 1, red);
    win.fillRect(x + 4, y + 6, 3, 1, red);
    win.fillRect(x + 4, y + 7, 2, 1, red);
}

fn drawFace() void {
    win.fillRect(FACE_X, FACE_Y, 26, 26, win.C_CHROME);
    win.fillRect(FACE_X + 1, FACE_Y + 1, 24, 24, win.C_CHROME);
    win.bevel(FACE_X, FACE_Y, 26, 26, true);
    const cx = FACE_X + 13;
    const cy = FACE_Y + 13;
    const yellow = win.color(255, 255, 0);
    // 圆脸（半径 10，逐行宽度 18,22,24,26,26,28,28,28,28,28...近似）
    const spans = [21]i32{ 8, 12, 14, 16, 16, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 16, 16, 14, 12, 8, 0 };
    for (spans, 0..) |span, i| {
        if (span == 0) continue;
        const yy = cy - 10 + @as(i32, @intCast(i));
        win.fillRect(cx - @divTrunc(span, 2), yy, span, 1, win.C_BLACK);
    }
    for (spans[1 .. spans.len - 1], 1..) |span, i| {
        const yy = cy - 10 + @as(i32, @intCast(i));
        const s = @max(span - 4, 0);
        win.fillRect(cx - @divTrunc(s, 2), yy, s, 1, yellow);
    }
    // 表情
    switch (state) {
        .lost => {
            drawX(cx - 6, cy - 5);
            drawX(cx + 2, cy - 5);
            win.fillRect(cx - 2, cy + 4, 4, 1, win.C_BLACK);
            win.fillRect(cx - 3, cy + 5, 6, 1, win.C_BLACK);
        },
        .won => {
            win.fillRect(cx - 7, cy - 5, 6, 4, win.C_BLACK);
            win.fillRect(cx + 1, cy - 5, 6, 4, win.C_BLACK);
            win.fillRect(cx - 1, cy - 4, 2, 2, win.C_BLACK);
            win.fillRect(cx - 5, cy + 3, 10, 1, win.C_BLACK);
            win.fillRect(cx - 3, cy + 4, 6, 1, win.C_BLACK);
        },
        else => {
            win.fillRect(cx - 5, cy - 4, 2, 3, win.C_BLACK);
            win.fillRect(cx + 3, cy - 4, 2, 3, win.C_BLACK);
            win.fillRect(cx - 5, cy + 2, 10, 1, win.C_BLACK);
            win.fillRect(cx - 4, cy + 3, 8, 1, win.C_BLACK);
            win.fillRect(cx - 2, cy + 4, 4, 1, win.C_BLACK);
        },
    }
}

fn drawX(x: i32, y: i32) void {
    var i: i32 = 0;
    while (i < 4) : (i += 1) {
        win.set(x + i, y + i, win.C_BLACK);
        win.set(x + 3 - i, y + i, win.C_BLACK);
    }
}

export fn main() i32 {
    if (!win.create(CW, CH, "Minesweeper")) return 1;
    win.initColors();
    reset();

    var evs: [8]win.Event = undefined;
    while (true) {
        if (dirty) {
            draw();
            win.present();
            dirty = false;
        }
        // 1s 超时：计时 LED 每秒醒一拍；平时事件驱动
        const n = win.wait(&evs, if (state == .playing) 1000 else 0);
        if (n == 0) {
            if (state == .playing) {
                const sec: u32 = @intCast(@min(@max(zos.time() - start_sec, 0), 999));
                if (sec != shown_sec) {
                    shown_sec = sec;
                    dirty = true;
                }
            }
            continue;
        }
        for (evs[0..n]) |e| {
            switch (e.kind) {
                win.EV_CLOSE => zos.exit(0),
                win.EV_PRESS => press(e.x, e.y, false),
                win.EV_RPRESS => press(e.x, e.y, true),
                else => {},
            }
        }
    }
    return 0;
}
