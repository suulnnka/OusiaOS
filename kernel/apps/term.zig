//! Terminal —— 控制台镜像（事件镜像型应用）
//!
//! 数据通路（与串口完全同源，GUI 不另起 shell 会话）：
//!   键盘 IRQ1 → tty 行规程 → shell(用户态) read/exec
//!   shell printf → console.putChar ─┬─ 串口（无头测试/日志）
//!                                  └─ gui.onConsoleChar → 本缓冲 → 窗口
//!   tty 回显同样走 putChar → 敲的字符自动出现在窗口里
//!
//! GUI 有自己的键盘焦点模型：只有当【活动窗口是用户应用】时按键才被
//! 截走，其余时候键盘照旧走 tty——串口 shell 与本窗口始终看到同一条
//! 会话。Terminal 自己只截四个键做【回滚】：PgUp/PgDn 翻页、Home/End
//! 跳头/尾（gui.onKey 路由，练习③）。
//!
//! 窗口可缩放/最大化：行数列数按客户区尺寸现算（8x16 字格），不再是
//! 固定 15 行。

const gui = @import("../gui.zig");
const pit = @import("../pit.zig");

const Rect = gui.Rect;
const mkRect = gui.mkRect;

const TERM_COLS_MAX = 96;
const TERM_LINES = 128; // 回滚行数（超出丢最老）

const TermLine = struct {
    len: u8 = 0,
    buf: [TERM_COLS_MAX]u8 = undefined,
};

var lines: [TERM_LINES]TermLine = undefined;
var head: usize = 0; // 最老行下标（环形）
var count: usize = 0; // 现存行数（0 = 尚无任何输出）
var ansi: enum { plain, esc, csi } = .plain;
var param: [4]u8 = undefined;
var param_len: usize = 0;
var blink: u1 = 0;
var scroll_off: usize = 0; // 从尾部往回翻的行数（0 = 跟随最新）

fn cur() *TermLine {
    return &lines[(head + count - 1) % TERM_LINES];
}

fn newLine() void {
    if (count < TERM_LINES) {
        count += 1;
    } else {
        head = (head + 1) % TERM_LINES; // 挤掉最老行
    }
    cur().len = 0;
}

fn paramHas(digit: u8) bool {
    for (param[0..param_len]) |p| {
        if (p == digit) return true;
    }
    return false;
}

/// console.putChar → gui.onConsoleChar → 这里（可能处于进程上下文：
/// shell printf）。每字符追加用极短关中断临界区（IRQ 上下文里 IF
/// 本来就是关的，等价零开销），环形缓冲按 SPSC 语义使用。
pub fn putChar(c: u8) void {
    const flags = gui.irqSave();
    scroll_off = 0; // 新输出到达 → 回到跟随模式（与真终端一致）
    switch (ansi) {
        .plain => {
            if (c == 0x1B) {
                ansi = .esc;
            } else {
                putPlain(c);
            }
        },
        // 只认 CSI（ESC [ 参数 final）；其余转义整段吞掉
        .esc => {
            if (c == '[') {
                ansi = .csi;
                param_len = 0;
            } else {
                ansi = .plain;
            }
        },
        .csi => {
            if (c >= 0x40 and c <= 0x7E) { // final 字节，序列结束
                // 唯一实现的语义：sh 内建 clear 发的 ESC[2J（清屏）
                if (c == 'J' and paramHas('2')) {
                    head = 0;
                    count = 1;
                    cur().len = 0;
                }
                ansi = .plain;
            } else if (param_len < param.len) {
                param[param_len] = c;
                param_len += 1;
            }
        },
    }
    gui.irqRestore(flags);
}

fn putPlain(c: u8) void {
    if (count == 0) count = 1;
    switch (c) {
        '\n' => newLine(),
        '\r' => cur().len = 0, // 回行首（本内核只有 clear 序列尾随）
        0x08 => { // 退格：tty 回显退格 = 0x08 ' ' 0x08 三连，净效果正确
            const l = cur();
            if (l.len > 0) l.len -= 1;
        },
        '\t' => { // 补空格到 8 的倍数（与 VGA 文本模式一致）
            const l = cur();
            while (l.len < TERM_COLS_MAX and l.len % 8 != 0) {
                l.buf[l.len] = ' ';
                l.len += 1;
            }
        },
        else => {
            const ch: u8 = if (c >= 32 and c < 127) c else '?';
            if (cur().len >= TERM_COLS_MAX) newLine(); // 硬换行
            const l = cur();
            l.buf[l.len] = ch;
            l.len += 1;
        },
    }
}

/// 可视行数/列数：跟随窗口客户区（可缩放窗口）
fn visRows(w: *const gui.Win) usize {
    const cr = gui.clientRect(w);
    const n: usize = @intCast(@max(@divTrunc(cr.h - 4, 16), 1));
    return n;
}

fn visCols(w: *const gui.Win) usize {
    const cr = gui.clientRect(w);
    return @intCast(@max(@divTrunc(cr.w - 4, 8), 8));
}

pub fn paint(w: *const gui.Win) void {
    const cr = gui.clientRect(w);
    gui.fillRect(cr, gui.pal.white);

    const rows = visRows(w);
    const cols = visCols(w);
    var shown: usize = rows;
    if (count - @min(scroll_off, count) < shown) shown = count - @min(scroll_off, count);
    if (shown == 0) return;

    const first = head + count - scroll_off - shown; // 最老可见行的环形下标
    var i: usize = 0;
    while (i < shown) : (i += 1) {
        const l = &lines[(first + i) % TERM_LINES];
        gui.text(cr.x + 2, cr.y + 2 + @as(i32, @intCast(i)) * 16, l.buf[0..@min(l.len, cols)], gui.pal.black);
    }

    // 回滚位置指示（翻离底部时右下角亮起）
    if (scroll_off > 0) {
        gui.text(cr.x + cr.w - 40, cr.y + cr.h - 16, "--more--", gui.pal.shadow);
    }

    // 块状光标：缓冲末尾（只在跟随模式显示），0.5s 闪烁
    if (blink == 1 and scroll_off == 0) {
        const last = cur();
        const col: i32 = if (last.len >= cols) 0 else @intCast(last.len);
        const row: i32 = @intCast(shown - 1);
        const fits = !(last.len >= cols and shown >= rows);
        if (fits) gui.fillRect(mkRect(cr.x + 2 + col * 8, cr.y + 2 + row * 16, 7, 14), gui.pal.navy);
    }
}

/// gui.onKey 路由过来的回滚键（0xF4 Home 0xF5 End 0xF6 PgUp 0xF7 PgDn）
pub fn onKey(c: u8) void {
    const w = gui.windowByKind(.terminal);
    const rows = visRows(w);
    const max_off = count -| @min(count, rows);
    switch (c) {
        0xF4 => scroll_off = max_off, // Home
        0xF5 => scroll_off = 0, // End
        0xF6 => scroll_off = @min(scroll_off + rows -| 1, max_off), // PgUp
        0xF7 => scroll_off -|= rows -| 1, // PgDn
        else => {},
    }
    gui.addDamage(gui.clientRect(w));
}

/// IRQ0 每拍调用：光标闪烁记脏区
pub fn tick() void {
    const ph: u1 = @intCast((pit.uptimeMs() / 500) & 1);
    if (ph != blink) {
        blink = ph;
        const w = gui.windowByKind(.terminal);
        if (w.visible) gui.addDamage(cursorCellRect(w));
    }
}

fn cursorCellRect(w: *const gui.Win) Rect {
    const cr = gui.clientRect(w);
    var shown: usize = visRows(w);
    const tail = count - @min(scroll_off, count);
    if (tail < shown) shown = tail;
    if (shown == 0) return mkRect(cr.x, cr.y, cr.w, 16);
    const last = cur();
    const cols = visCols(w);
    const col: i32 = if (last.len >= cols) 0 else @intCast(last.len);
    return mkRect(cr.x + 2 + col * 8 - 1, cr.y + 2 + @as(i32, @intCast(shown)) * 16 - 17, 9, 16);
}
