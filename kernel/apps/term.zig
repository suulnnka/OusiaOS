//! Terminal —— 控制台镜像（事件镜像型应用）
//!
//! 数据通路（与串口完全同源，GUI 不另起 shell 会话）：
//!   键盘 IRQ1 → tty 行规程 → shell(用户态) read/exec
//!   shell printf → console.putChar ─┬─ 串口（无头测试/日志）
//!                                  └─ gui.onConsoleChar → 本缓冲 → 窗口
//!   tty 回显同样走 putChar → 敲的字符自动出现在窗口里
//!
//! GUI 有自己的键盘焦点模型（见 note.zig）：只有当【活动窗口是记事本】
//! 时按键才被截走，其余时候键盘照旧走 tty——串口 shell 与本窗口始终
//! 看到同一条会话。

const gui = @import("../gui.zig");
const pit = @import("../pit.zig");

const Rect = gui.Rect;
const mkRect = gui.mkRect;

const TERM_COLS = 72;
const TERM_VIS_ROWS = 15;
const TERM_LINES = 128; // 回滚行数（超出丢最老）

const TermLine = struct {
    len: u8 = 0,
    buf: [TERM_COLS]u8 = undefined,
};

var lines: [TERM_LINES]TermLine = undefined;
var head: usize = 0; // 最老行下标（环形）
var count: usize = 0; // 现存行数（0 = 尚无任何输出）
var ansi: enum { plain, esc, csi } = .plain;
var param: [4]u8 = undefined;
var param_len: usize = 0;
var blink: u1 = 0;

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
            while (l.len < TERM_COLS and l.len % 8 != 0) {
                l.buf[l.len] = ' ';
                l.len += 1;
            }
        },
        else => {
            const ch: u8 = if (c >= 32 and c < 127) c else '?';
            if (cur().len >= TERM_COLS) newLine(); // 硬换行
            const l = cur();
            l.buf[l.len] = ch;
            l.len += 1;
        },
    }
}

pub fn paint(w: *const gui.Win) void {
    const cr = gui.clientRect(w);
    gui.fillRect(cr, gui.pal.white);

    var shown: usize = TERM_VIS_ROWS;
    if (count < shown) shown = count;
    if (shown == 0) return;

    const first = head + count - shown; // 最老可见行的环形下标
    var i: usize = 0;
    while (i < shown) : (i += 1) {
        const l = &lines[(first + i) % TERM_LINES];
        gui.text(cr.x + 2, cr.y + 2 + @as(i32, @intCast(i)) * 16, l.buf[0..l.len], gui.pal.black);
    }

    // 块状光标：缓冲末尾，0.5s 闪烁（相位由 IRQ0 的 onTick 翻转）
    if (blink == 1) {
        const last = cur();
        const col: i32 = if (last.len >= TERM_COLS) 0 else last.len;
        const row: i32 = @intCast(shown - 1);
        const fits = !(last.len >= TERM_COLS and shown >= TERM_VIS_ROWS);
        if (fits) gui.fillRect(mkRect(cr.x + 2 + col * 8, cr.y + 2 + row * 16, 7, 14), gui.pal.navy);
    }
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
    var shown: usize = TERM_VIS_ROWS;
    if (count < shown) shown = count;
    if (shown == 0) return mkRect(cr.x, cr.y, cr.w, 16);
    const last = cur();
    const col: i32 = if (last.len >= TERM_COLS) 0 else last.len;
    return mkRect(cr.x + 2 + col * 8 - 1, cr.y + 2 + @as(i32, @intCast(shown)) * 16 - 17, 9, 16);
}
