//! mine —— 扫雷（用户态 GUI 应用）
//!
//! 练习⑤的完整实现：
//!   - 三档难度（Game 菜单）：Beginner 9x9/10 雷、Intermediate 16x16/40、
//!     Expert 24x16/99——切难度 = 调 win.resize 重分配表面（窗口服务
//!     resize 特性的真实用户），窗口外观随之变
//!   - 最佳成绩按难度记在 /etc/minebest（纯文本，O_CREAT|O_TRUNC 写回
//!     ——0.3 起根文件系统是 ext2 磁盘，成绩真正跨重启保存）
//!   - 其余与经典版一致：首击保护、空白洪泛、右键插旗、计时 LED
//!   - 胜利时 tada 音效 + 破纪录 ding + 落盘

const zos = @import("lib/zos.zig");
const win = @import("lib/win.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

const CELL = 20;
const MENUBAR_H = 18;
const MAX_NX = 24;
const MAX_NY = 16;

const Level = struct { name: []const u8, nx: usize, ny: usize, mines: usize };
const levels = [_]Level{
    .{ .name = "Beginner", .nx = 9, .ny = 9, .mines = 10 },
    .{ .name = "Intermediate", .nx = 16, .ny = 16, .mines = 40 },
    .{ .name = "Expert", .nx = 24, .ny = 16, .mines = 99 },
};
const BEST_FILE = "/etc/minebest";

const Cell = struct {
    mine: bool = false,
    open: bool = false,
    flag: bool = false,
    adj: u8 = 0,
};

const State = enum { ready, playing, won, lost };

var cells: [MAX_NX * MAX_NY]Cell = undefined;
var level: usize = 0;
var nx: usize = 9;
var ny: usize = 9;
var mines: usize = 10;
var grid_px_w: i32 = 9 * CELL;
var grid_px_h: i32 = 9 * CELL;

var state: State = .ready;
var flags: usize = 0;
var opened: usize = 0;
var start_sec: i64 = 0;
var shown_sec: u32 = 0;
var boom: usize = 0xFFFF;
var rng: u32 = 1;
var dirty = true;

var cw: i32 = 194;
var ch: i32 = 231;
var best: [3]i32 = .{ -1, -1, -1 }; // 各难度最佳秒数（-1 = 无记录）
var new_record = false;

// 棋盘几何（客户区内）
const GRID_X = 5;
var grid_y: i32 = 44;
const LED_Y = 9;
var face_x: i32 = @divTrunc(194 - 26, 2);
const FACE_Y = 6;

// ---- 菜单 ----
const game_items = [_][]const u8{ "Beginner", "Intermediate", "Expert", "", "Best times..." };
const menu_defs = [_]win.MenuDef{
    .{ .label = "Game", .items = &game_items },
};
var menubar = win.MenuBar{ .defs = &menu_defs };
var menu_item_out: win.MenuHit = .{ .menu = 0, .idx = 0 };

// 简易 xorshift：种子取 SYS_time + pid 混合
fn rand() u32 {
    var x = rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng = x;
    return x;
}

// ---- 最佳成绩（/etc/minebest，每行 "<秒>" ×3 行对应三难度） ----

fn loadBest() void {
    for (&best) |*b| b.* = -1;
    const fd = zos.open(BEST_FILE, win.O_RDONLY);
    if (fd < 0) return;
    defer _ = zos.close(@intCast(fd));
    var buf: [128]u8 = undefined;
    const n = zos.read(@intCast(fd), &buf);
    if (n <= 0) return;
    var li: usize = 0;
    var pos: usize = 0;
    while (pos < n and li < 3) {
        // 跳过非数字
        while (pos < n and (buf[pos] < '0' or buf[pos] > '9')) pos += 1;
        var v: i32 = 0;
        var any = false;
        while (pos < n and buf[pos] >= '0' and buf[pos] <= '9') {
            v = v * 10 + @as(i32, buf[pos] - '0');
            pos += 1;
            any = true;
        }
        if (any) {
            best[li] = v;
            li += 1;
        }
    }
}

fn saveBest() void {
    const fd = zos.open(BEST_FILE, win.O_WRONLY | win.O_CREAT | win.O_TRUNC);
    if (fd < 0) return; // 只读 FS / 权限：静默放弃（成绩本次会话仍有效）
    defer _ = zos.close(@intCast(fd));
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (best) |b| {
        if (b < 0) {
            buf[n] = '-';
            n += 1;
        } else {
            n += putNum(buf[n..], @intCast(b));
        }
        buf[n] = '\n';
        n += 1;
    }
    _ = zos.write(@intCast(fd), buf[0..n]);
}

fn putNum(buf: []u8, v: u32) usize {
    var tmp: [12]u8 = undefined;
    var n: usize = 0;
    var x = v;
    if (x == 0) {
        buf[0] = '0';
        return 1;
    }
    while (x > 0) {
        tmp[n] = '0' + @as(u8, @intCast(x % 10));
        n += 1;
        x /= 10;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) buf[i] = tmp[n - 1 - i];
    return n;
}

// ---- 布局 ----

fn applyLevel(l: usize) void {
    level = l;
    nx = levels[l].nx;
    ny = levels[l].ny;
    mines = levels[l].mines;
    grid_px_w = @intCast(nx * CELL);
    grid_px_h = @intCast(ny * CELL);
    cw = grid_px_w + 14;
    ch = MENUBAR_H + grid_px_h + 56;
    grid_y = MENUBAR_H + 44;
    face_x = @divTrunc(cw - 26, 2);
    _ = win.resize(cw, ch); // 表面重分配（EV_RESIZE 回来重画）
    reset();
    updateTitle();
}

fn updateTitle() void {
    var t: [40]u8 = undefined;
    var n: usize = 0;
    n += put(&t, n, "Minesweeper - ");
    n += put(&t, n, levels[level].name);
    win.setTitle(t[0..n]);
}

fn put(buf: []u8, pos: usize, s: []const u8) usize {
    const n = @min(s.len, buf.len - pos);
    @memcpy(buf[pos .. pos + n], s[0..n]);
    return n;
}

fn reset() void {
    for (&cells) |*c| c.* = .{};
    state = .ready;
    flags = 0;
    opened = 0;
    shown_sec = 0;
    boom = 0xFFFF;
    new_record = false;
    dirty = true;
}

fn plant(safe: usize) void {
    rng = @truncate(@as(u64, @bitCast(zos.time())) ^ @as(u64, @intCast(zos.getpid())) << 16 | 1);
    const sx: i32 = @intCast(safe % nx);
    const sy: i32 = @intCast(safe / nx);
    var placed: usize = 0;
    while (placed < mines) {
        const idx = rand() % (nx * ny);
        if (cells[idx].mine) continue;
        const cx: i32 = @intCast(idx % nx);
        const cy: i32 = @intCast(idx / nx);
        if (@abs(cx - sx) <= 1 and @abs(cy - sy) <= 1) continue;
        cells[idx].mine = true;
        placed += 1;
    }
    for (0..nx * ny) |i| {
        if (cells[i].mine) continue;
        const cx: i32 = @intCast(i % nx);
        const cy: i32 = @intCast(i / nx);
        var n: u8 = 0;
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                if (dx == 0 and dy == 0) continue;
                const nxx = cx + dx;
                const nyy = cy + dy;
                if (nxx < 0 or nyy < 0 or nxx >= @as(i32, @intCast(nx)) or nyy >= @as(i32, @intCast(ny))) continue;
                if (cells[@as(usize, @intCast(nyy)) * nx + @as(usize, @intCast(nxx))].mine) n += 1;
            }
        }
        cells[i].adj = n;
    }
}

fn cellRect(idx: usize) struct { x: i32, y: i32 } {
    const cx: i32 = @intCast(idx % nx);
    const cy: i32 = @intCast(idx / nx);
    return .{ .x = GRID_X + 2 + cx * CELL, .y = grid_y + 2 + cy * CELL };
}

fn handleMenu() void {
    switch (menu_item_out.idx) {
        0, 1, 2 => applyLevel(menu_item_out.idx),
        3 => {},
        4 => {
            // Best times 弹到状态消息（简单画法：状态栏滚动显示）
            dirty = true;
        },
        else => {},
    }
    dirty = true;
}

fn press(x: i32, y: i32, right: bool) void {
    if (menubar.press(x, y, &menu_item_out)) {
        handleMenu();
        return;
    }
    // 笑脸 = 重开
    if (x >= face_x and y >= FACE_Y and x < face_x + 26 and y < FACE_Y + 26) {
        reset();
        return;
    }
    if (state == .won or state == .lost) return;
    if (x < GRID_X + 2 or y < grid_y + 2 or x >= GRID_X + 2 + grid_px_w or y >= grid_y + 2 + grid_px_h) return;
    const cx = @divTrunc(x - GRID_X - 2, CELL);
    const cy = @divTrunc(y - grid_y - 2, CELL);
    if (cx < 0 or cy < 0 or cx >= @as(i32, @intCast(nx)) or cy >= @as(i32, @intCast(ny))) return;
    const idx: usize = @as(usize, @intCast(cy)) * nx + @as(usize, @intCast(cx));
    const c = &cells[idx];

    if (right) {
        if (c.open) return;
        c.flag = !c.flag;
        if (c.flag) flags += 1 else flags -= 1;
        dirty = true;
        win.sound(1); // 插旗咔哒
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
        win.sound(5);
        return;
    }

    var stack: [MAX_NX * MAX_NY]u8 = undefined;
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
        const px: i32 = @intCast(cur % nx);
        const py: i32 = @intCast(cur / nx);
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                if (dx == 0 and dy == 0) continue;
                const nxx = px + dx;
                const nyy = py + dy;
                if (nxx < 0 or nyy < 0 or nxx >= @as(i32, @intCast(nx)) or nyy >= @as(i32, @intCast(ny))) continue;
                const ni: usize = @as(usize, @intCast(nyy)) * nx + @as(usize, @intCast(nxx));
                if (!cells[ni].open and sp < stack.len) {
                    stack[sp] = @intCast(ni);
                    sp += 1;
                }
            }
        }
    }
    if (opened == nx * ny - mines) {
        state = .won;
        for (&cells) |*mc| {
            if (mc.mine) mc.flag = true;
        }
        flags = mines;
        const sec: i32 = @intCast(@min(@max(zos.time() - start_sec, 0), 999));
        // 破纪录判定 + 落盘
        if (best[level] < 0 or sec < best[level]) {
            best[level] = sec;
            new_record = true;
            saveBest();
            win.sound(4); // ding：新纪录
        } else {
            win.sound(6); // tada
        }
    }
    dirty = true;
}

// ---- 绘制 ----

fn draw() void {
    win.fillRect(0, 0, win.sw, win.sh, win.C_CHROME);
    menubar.draw(win.sw);

    if (state == .playing) {
        const sec: u32 = @intCast(@min(@max(zos.time() - start_sec, 0), 999));
        if (sec != shown_sec) shown_sec = sec;
    }
    drawLed(8, LED_Y + MENUBAR_H, @as(i32, @intCast(mines)) - @as(i32, @intCast(flags)));
    drawLed(cw - 8 - 36, LED_Y + MENUBAR_H, @intCast(shown_sec));
    drawFace();

    // 雷区外凹框
    win.fillRect(GRID_X, grid_y, grid_px_w + 4, grid_px_h + 4, win.C_CHROME);
    win.bevel(GRID_X, grid_y, grid_px_w + 4, grid_px_h + 4, false);
    var i: usize = 0;
    while (i < nx * ny) : (i += 1) drawCell(i);

    // 底部状态：难度 + 最佳成绩
    const sy = win.sh - 16;
    var buf: [72]u8 = undefined;
    var n: usize = put(&buf, 0, levels[level].name);
    n += put(&buf, n, "  best: ");
    if (best[level] < 0) {
        n += put(&buf, n, "--");
    } else {
        n += putNum(buf[n..], @intCast(best[level]));
        n += put(&buf, n, "s");
    }
    if (new_record and state == .won) n += put(&buf, n, "  NEW RECORD!");
    win.fillRect(2, sy, cw - 4, 14, win.C_CHROME);
    win.text(6, sy + 1, buf[0..n], if (new_record and state == .won) win.C_RED else win.C_BLACK);
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
    win.fillRect(face_x, FACE_Y + MENUBAR_H, 26, 26, win.C_CHROME);
    win.fillRect(face_x + 1, FACE_Y + MENUBAR_H + 1, 24, 24, win.C_CHROME);
    win.bevel(face_x, FACE_Y + MENUBAR_H, 26, 26, true);
    const cx = face_x + 13;
    const cy = FACE_Y + MENUBAR_H + 13;
    const yellow = win.color(255, 255, 0);
    // 圆脸（半径 10，逐行宽度近似）
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
    if (!win.create(cw, ch, "Minesweeper")) return 1;
    win.initColors();
    loadBest();
    updateTitle();

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
                win.EV_KEY => {
                    // 数字键 1/2/3 切难度（键盘玩家的捷径）
                    if (e.code >= '1' and e.code <= '3') {
                        applyLevel(e.code - '1');
                    }
                },
                win.EV_RESIZE => { win.onResizeEvent(e); dirty = true; },
                else => {},
            }
        }
    }
    return 0;
}
