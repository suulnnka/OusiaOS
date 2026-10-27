//! note —— 记事本（用户态 GUI 应用）
//!
//! GUI 键盘焦点的直接受益者：内核把按键作为 EV_KEY 事件投给活动
//! 窗口（本进程），应用自己解释——Enter 拆行、退格删字/并上行、
//! 方向键移动（0xF0..0xF3 私有码）。光标闪烁靠 win_wait 的超时参数：
//! 没事件就 500ms 醒一次翻相位。tarfs 只读，是草稿板。

const zos = @import("lib/zos.zig");
const win = @import("lib/win.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

const CW = 514;
const CH = 229;
const MAX_LINES = 64;
const MAX_COLS = 62;
const VIS_ROWS = 12;

const Line = struct {
    len: u8 = 0,
    buf: [MAX_COLS]u8 = undefined,
};

var lines: [MAX_LINES]Line = undefined;
var nlines: usize = 1;
var row: usize = 0;
var col: usize = 0;
var top: usize = 0;
var blink = false;
var dirty = true;

fn scrollFollow() void {
    if (row < top) top = row;
    if (row >= top + VIS_ROWS) top = row - VIS_ROWS + 1;
}

fn key(c: u8) void {
    switch (c) {
        win.KEY_UP => {
            if (row > 0) row -= 1;
            col = @min(col, lines[row].len);
        },
        win.KEY_DOWN => {
            if (row + 1 < nlines) row += 1;
            col = @min(col, lines[row].len);
        },
        win.KEY_LEFT => {
            if (col > 0) {
                col -= 1;
            } else if (row > 0) {
                row -= 1;
                col = lines[row].len;
            }
        },
        win.KEY_RIGHT => {
            if (col < lines[row].len) {
                col += 1;
            } else if (row + 1 < nlines) {
                row += 1;
                col = 0;
            }
        },
        '\n' => {
            if (nlines < MAX_LINES) {
                var i = nlines;
                while (i > row + 1) : (i -= 1) lines[i] = lines[i - 1];
                nlines += 1;
                const l = &lines[row];
                const tail: u8 = l.len - @as(u8, @intCast(col));
                @memcpy(lines[row + 1].buf[0..tail], l.buf[col..l.len]);
                lines[row + 1].len = tail;
                l.len = @intCast(col);
                row += 1;
                col = 0;
            }
        },
        0x08 => {
            if (col > 0) {
                const l = &lines[row];
                var i = col - 1;
                while (i < l.len - 1) : (i += 1) l.buf[i] = l.buf[i + 1];
                l.len -= 1;
                col -= 1;
            } else if (row > 0) {
                const prev_len = lines[row - 1].len;
                const cur_len = lines[row].len;
                if (prev_len + cur_len <= MAX_COLS) {
                    @memcpy(lines[row - 1].buf[prev_len .. prev_len + cur_len], lines[row].buf[0..cur_len]);
                    lines[row - 1].len = prev_len + cur_len;
                    var i = row;
                    while (i + 1 < nlines) : (i += 1) lines[i] = lines[i + 1];
                    nlines -= 1;
                    row -= 1;
                    col = prev_len;
                } else {
                    row -= 1;
                    col = prev_len;
                }
            }
        },
        else => {
            if (c < 32 or c >= 127) return;
            if (col >= MAX_COLS) {
                if (nlines < MAX_LINES) key('\n') else return;
            }
            const l = &lines[row];
            var i = l.len;
            while (i > col) : (i -= 1) l.buf[i] = l.buf[i - 1];
            l.buf[col] = c;
            l.len += 1;
            col += 1;
        },
    }
    scrollFollow();
    dirty = true;
}

fn draw() void {
    win.fillRect(0, 0, CW, CH, win.C_CHROME);

    // 文本区
    const tx = 4;
    const ty = 4;
    const tw = CW - 8;
    const th = CH - 28;
    win.fillRect(tx, ty, tw, th, win.C_WHITE);
    win.bevel(tx, ty, tw, th, false);

    var i: usize = top;
    while (i < nlines and i < top + VIS_ROWS) : (i += 1) {
        const l = &lines[i];
        win.text(tx + 2, ty + 2 + @as(i32, @intCast(i - top)) * 16, l.buf[0..l.len], win.C_BLACK);
    }

    // 光标（闪烁）
    if (blink and row >= top and row < top + VIS_ROWS) {
        win.fillRect(tx + 2 + @as(i32, @intCast(col)) * 8, ty + 2 + @as(i32, @intCast(row - top)) * 16, 7, 14, win.C_NAVY);
    }

    // 状态栏
    const sy = CH - 18;
    win.fillRect(4, sy, CW - 8, 16, win.C_CHROME);
    win.bevel(4, sy, CW - 8, 16, false);
    var buf: [24]u8 = undefined;
    var n: usize = put(&buf, 0, "Ln ");
    n += num(&buf, n, row + 1);
    n += put(&buf, n, ", Col ");
    n += num(&buf, n, col + 1);
    win.text(8, sy, buf[0..n], win.C_BLACK);
}

fn put(buf: []u8, pos: usize, s: []const u8) usize {
    const n = @min(s.len, buf.len - pos);
    @memcpy(buf[pos .. pos + n], s[0..n]);
    return n;
}

fn num(buf: []u8, pos: usize, v: usize) usize {
    var tmp: [8]u8 = undefined;
    var n: usize = 0;
    var x = v;
    if (x == 0) {
        if (pos < buf.len) buf[pos] = '0';
        return 1;
    }
    while (x > 0) {
        tmp[n] = '0' + @as(u8, @intCast(x % 10));
        n += 1;
        x /= 10;
    }
    var i: usize = 0;
    while (i < n and pos + i < buf.len) : (i += 1) buf[pos + i] = tmp[n - 1 - i];
    return i;
}

export fn main() i32 {
    if (!win.create(CW, CH, "Notepad")) return 1;
    win.initColors();

    var evs: [8]win.Event = undefined;
    while (true) {
        if (dirty) {
            draw();
            win.present();
            dirty = false;
        }
        const n = win.wait(&evs, 500); // 500ms：光标闪烁节拍
        if (n == 0) {
            blink = !blink;
            dirty = true;
            continue;
        }
        for (evs[0..n]) |e| {
            switch (e.kind) {
                win.EV_CLOSE => zos.exit(0),
                win.EV_KEY => key(e.code),
                else => {},
            }
        }
    }
    return 0;
}
