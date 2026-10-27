//! 记事本 —— 行编辑器（键盘焦点型应用：GUI 第一次真正"吃"键盘）
//!
//! 键盘焦点模型（gui.onKey）：
//!   活动窗口（z 序最顶的可见窗口）是记事本时，keyboard.zig 的按键
//!   送给本应用；否则照旧走 tty → 串口 shell（回显/控制字符全都不变）。
//!   想把键盘还给 shell？点任何一个别的窗口把它提到顶层即可——
//!   这就是经典 GUI 的"点击切换焦点"。
//!
//! 方向键：keyboard.zig 映射成私有键码 0xF0..0xF3（不进 tty，避免
//!   XON/XOFF 之类的控制字符污染串口行缓冲）。
//!
//! 编辑模型：定长行数组（64 行 × 64 列），光标 (row,col)，Enter 拆行、
//! 退格删字符/并上行；视图滚动跟随光标。tarfs 只读，所以是草稿板，
//! 不做保存（写文件是课后练习）。

const gui = @import("../gui.zig");
const pit = @import("../pit.zig");

const Rect = gui.Rect;
const mkRect = gui.mkRect;

pub const KEY_UP: u8 = 0xF0;
pub const KEY_DOWN: u8 = 0xF1;
pub const KEY_LEFT: u8 = 0xF2;
pub const KEY_RIGHT: u8 = 0xF3;

const MAX_LINES = 64;
const MAX_COLS = 62; // 客户区一行的可见宽度（520 宽窗口 → 62 列）

const VIS_ROWS = 12; // 可见行数（窗口 520x260 的文本区）

const Line = struct {
    len: u8 = 0,
    buf: [MAX_COLS]u8 = undefined,
};

var lines: [MAX_LINES]Line = undefined;
var nlines: usize = 1;
var row: usize = 0; // 光标
var col: usize = 0;
var top: usize = 0; // 视图首行
var blink: u1 = 0;

fn textRect(w: *const gui.Win) Rect {
    const cr = gui.clientRect(w);
    return mkRect(cr.x + 4, cr.y + 4, cr.w - 8, cr.h - 24);
}

fn statusRect(w: *const gui.Win) Rect {
    const cr = gui.clientRect(w);
    return mkRect(cr.x + 4, cr.y + cr.h - 18, cr.w - 8, 16);
}

/// 光标落点（屏幕像素）；行超出可视区返回 null
fn cursorPx(w: *const gui.Win) ?Rect {
    if (row < top or row >= top + VIS_ROWS) return null;
    const tr = textRect(w);
    return mkRect(tr.x + 2 + @as(i32, @intCast(col)) * 8, tr.y + 2 + @as(i32, @intCast(row - top)) * 16, 7, 14);
}

fn scrollFollow() void {
    if (row < top) top = row;
    if (row >= top + VIS_ROWS) top = row - VIS_ROWS + 1;
}

/// 按键（gui.onKey 在焦点属于本窗口时转发；含私有方向键码）
pub fn key(c: u8) void {
    const w = gui.windowByKind(.note);
    switch (c) {
        KEY_UP => {
            if (row > 0) row -= 1;
            col = @min(col, lines[row].len);
        },
        KEY_DOWN => {
            if (row + 1 < nlines) row += 1;
            col = @min(col, lines[row].len);
        },
        KEY_LEFT => {
            if (col > 0) {
                col -= 1;
            } else if (row > 0) { // 行首左移 = 光标到上一行末
                row -= 1;
                col = lines[row].len;
            }
        },
        KEY_RIGHT => {
            if (col < lines[row].len) {
                col += 1;
            } else if (row + 1 < nlines) { // 行末右移 = 下一行首
                row += 1;
                col = 0;
            }
        },
        '\n' => { // 拆行：光标右侧的内容搬到新行
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
        0x08 => { // 退格：删字符；行首 = 与上一行合并
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
                    col = prev_len; // 合不下就只把光标挪上去
                    row -= 1;
                }
            }
        },
        else => {
            if (c < 32 or c >= 127) return; // 控制字符/私有码不进正文
            if (col >= MAX_COLS) { // 硬边界：换行继续（光标行末回车行为）
                if (nlines < MAX_LINES) {
                    key('\n');
                } else return;
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
    gui.addDamage(gui.clientRect(w));
}

pub fn paint(w: *const gui.Win) void {
    const tr = textRect(w);
    gui.fillRect(tr, gui.pal.white);
    gui.bevel1(tr, false);

    var i: usize = top;
    while (i < nlines and i < top + VIS_ROWS) : (i += 1) {
        const l = &lines[i];
        gui.text(tr.x + 2, tr.y + 2 + @as(i32, @intCast(i - top)) * 16, l.buf[0..l.len], gui.pal.black);
    }

    // 光标（仅当本窗口持有焦点时闪烁显示）
    if (gui.topKind() == .note and blink == 1) {
        if (cursorPx(w)) |cp| gui.fillRect(cp, gui.pal.navy);
    }

    // 状态栏：行列位置
    const st = statusRect(w);
    gui.fillRect(st, gui.pal.chrome);
    gui.bevel1(st, false);
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    n += put(&buf, n, "Ln ");
    n += putNum(&buf, n, row + 1);
    n += put(&buf, n, ", Col ");
    n += putNum(&buf, n, col + 1);
    gui.text(st.x + 4, st.y, buf[0..n], gui.pal.black);
}

/// IRQ0：焦点在本窗口时光标闪烁
pub fn tick() void {
    const ph: u1 = @intCast((pit.uptimeMs() / 500) & 1);
    if (ph != blink) {
        blink = ph;
        const w = gui.windowByKind(.note);
        if (w.visible and gui.topKind() == .note) {
            if (cursorPx(w)) |cp| gui.addDamage(cp);
        }
    }
}

fn put(buf: []u8, pos: usize, s: []const u8) usize {
    const n = @min(s.len, buf.len - pos);
    @memcpy(buf[pos .. pos + n], s[0..n]);
    return n;
}

fn putNum(buf: []u8, pos: usize, v: usize) usize {
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
