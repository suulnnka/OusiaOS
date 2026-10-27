//! 计算器 —— Win3.1 calc 复刻（无状态重建型：一切状态就是一个 f64 +
//! 一个待处理运算符 + 正在键入的数字串）
//!
//! 教学要点：
//!   - 内核里也能用 f64（SSE2 是 x86_64 基线，加减乘除不需要数学库）
//!   - 浮点显示自己写：整数部分 + 小数 6 位去尾零；溢出/除零 → "Error"
//!   - 状态机：entry（键入中）↔ acc（累计值）+ pending 运算符；
//!     连续按运算符实现"链式计算"（12 + 3 + → 显示 15）

const gui = @import("../gui.zig");

const Rect = gui.Rect;
const mkRect = gui.mkRect;
const inRect = gui.inRect;

const BTN_W: i32 = 34;
const BTN_H: i32 = 26;
const GAP: i32 = 6;

/// 4x5 键阵（经典布局）
const KEYS = [5][4]u8{
    .{ 'C', 'E', '<', '/' },
    .{ '7', '8', '9', '*' },
    .{ '4', '5', '6', '-' },
    .{ '1', '2', '3', '+' },
    .{ '0', '.', 'N', '=' },
};

var acc: f64 = 0; // 累计值
var pending: u8 = 0; // 待处理运算符：0 无 / '+' '-' '*' '/'
var entry: [17]u8 = @splat('0'); // 正在键入的数字串（len 记长度，实际显示 [0..len]）
var entry_len: usize = 1;
var fresh: bool = true; // 下一个数字键开始新 entry（刚算完/刚按运算符）
var is_error: bool = false;

fn displayRect(w: *const gui.Win) Rect {
    const cr = gui.clientRect(w);
    return mkRect(cr.x + 8, cr.y + 8, cr.w - 16, 24);
}

fn keyRect(w: *const gui.Win, row: usize, col: usize) Rect {
    const cr = gui.clientRect(w);
    const gx = cr.x + @divTrunc(cr.w - (4 * BTN_W + 3 * GAP), 2);
    const gy = displayRect(w).y + displayRect(w).h + 8;
    return mkRect(gx + @as(i32, @intCast(col)) * (BTN_W + GAP), gy + @as(i32, @intCast(row)) * (BTN_H + GAP), BTN_W, BTN_H);
}

fn entryVal() f64 {
    // 手写 atof（键入串只会是 [0-9.]* ，不处理指数）
    var v: f64 = 0;
    var dot = false;
    var scale: f64 = 0.1;
    for (entry[0..entry_len]) |c| {
        if (c == '.') {
            dot = true;
        } else if (!dot) {
            v = v * 10 + @as(f64, @floatFromInt(c - '0'));
        } else {
            v += @as(f64, @floatFromInt(c - '0')) * scale;
            scale /= 10;
        }
    }
    return v;
}

fn isFinite(v: f64) bool {
    return v == v and v > -1.0e15 and v < 1.0e15; // 排除 NaN/Inf/超显示范围
}

/// f64 → 字符串：整数部分 + 小数 6 位去尾零（超长返回 null → "Error"）
fn fmtVal(v: f64, buf: []u8) ?usize {
    if (!isFinite(v)) return null;
    var n: usize = 0;
    var x = v;
    if (x < 0) {
        if (n >= buf.len) return null;
        buf[n] = '-';
        n += 1;
        x = -x;
    }
    const ipart: u64 = @intFromFloat(x);
    const frac = x - @as(f64, @floatFromInt(ipart));
    // 整数部分
    var tmp: [20]u8 = undefined;
    var tn: usize = 0;
    var iv = ipart;
    if (iv == 0) {
        tmp[tn] = '0';
        tn += 1;
    }
    while (iv > 0) {
        tmp[tn] = '0' + @as(u8, @intCast(iv % 10));
        tn += 1;
        iv /= 10;
    }
    while (tn > 0) {
        tn -= 1;
        if (n >= buf.len) return null;
        buf[n] = tmp[tn];
        n += 1;
    }
    // 小数部分：四舍五入到 6 位再逐位去零
    if (frac > 0.5e-6) {
        var fr: u64 = @intFromFloat(frac * 1.0e6 + 0.5);
        var digits: [6]u8 = undefined;
        var dn: usize = 6;
        while (dn > 0) {
            dn -= 1;
            digits[dn] = '0' + @as(u8, @intCast(fr % 10));
            fr /= 10;
        }
        var end: usize = 6;
        while (end > 0 and digits[end - 1] == '0') end -= 1;
        if (end > 0) {
            if (n >= buf.len) return null;
            buf[n] = '.';
            n += 1;
            for (digits[0..end]) |d| {
                if (n >= buf.len) return null;
                buf[n] = d;
                n += 1;
            }
        }
    }
    return n;
}

fn apply(a: f64, b: f64, op: u8) f64 {
    return switch (op) {
        '+' => a + b,
        '-' => a - b,
        '*' => a * b,
        '/' => a / b, // 除零 → Inf → isFinite 拦下 → Error
        else => b,
    };
}

fn pressKey(k: u8) void {
    if (is_error) {
        if (k >= '0' and k <= '9') {
            // 出错后按数字 = 重新开始
            is_error = false;
            acc = 0;
            pending = 0;
        } else if (k != 'C') {
            return; // 出错后只接受数字或 C
        }
    }
    switch (k) {
        '0'...'9' => {
            if (fresh) {
                entry_len = 0;
                fresh = false;
            }
            if (entry_len < entry.len) {
                entry[entry_len] = k;
                entry_len += 1;
            }
        },
        '.' => {
            if (fresh) {
                entry[0] = '0';
                entry_len = 1;
                fresh = false;
            }
            var has_dot = false;
            for (entry[0..entry_len]) |c| {
                if (c == '.') has_dot = true;
            }
            if (!has_dot and entry_len < entry.len) {
                entry[entry_len] = '.';
                entry_len += 1;
            }
        },
        '+', '-', '*', '/' => {
            if (pending != 0 and !fresh) {
                acc = apply(acc, entryVal(), pending);
                if (!isFinite(acc)) {
                    is_error = true;
                    return;
                }
            } else if (pending == 0) {
                acc = if (fresh) acc else entryVal();
            }
            pending = k;
            fresh = true;
        },
        '=' => {
            if (pending != 0) {
                // "a + ="（等号前没键入新数）→ 用 acc 自身，与 Win 计算器一致
                const b: f64 = if (fresh) acc else entryVal();
                acc = apply(acc, b, pending);
                if (!isFinite(acc)) {
                    is_error = true;
                    return;
                }
                pending = 0;
            }
            fresh = true;
        },
        'C' => { // 全清
            acc = 0;
            pending = 0;
            entry_len = 1;
            entry[0] = '0';
            fresh = true;
            is_error = false;
        },
        'E' => { // 清当前键入
            entry_len = 1;
            entry[0] = '0';
            fresh = true;
        },
        '<' => { // 退格
            if (!fresh and entry_len > 0) {
                entry_len -= 1;
                if (entry_len == 0) {
                    entry[0] = '0';
                    entry_len = 1;
                }
            }
        },
        'N' => { // 取负：作用在"将参与运算"的那个数上
            if (fresh) {
                acc = -acc;
                if (!isFinite(acc)) is_error = true;
            } else {
                if (entry_len > 0 and entry[0] == '-') {
                    // 键入串一般不带负号（用 N 添加），保守处理：去掉
                    for (1..entry_len) |i| entry[i - 1] = entry[i];
                    entry_len -= 1;
                } else {
                    if (entry_len + 1 < entry.len) {
                        var i = entry_len;
                        while (i > 0) {
                            i -= 1;
                            entry[i + 1] = entry[i];
                        }
                        entry[0] = '-';
                        entry_len += 1;
                    }
                }
            }
        },
        else => {},
    }
}

pub fn press(w: *const gui.Win, x: i32, y: i32) void {
    for (KEYS, 0..) |row, ri| {
        for (row, 0..) |k, ci| {
            if (inRect(x, y, keyRect(w, ri, ci))) {
                pressKey(k);
                gui.addDamage(gui.clientRect(w)); // 显示区必变，整客户区简单重画
                return;
            }
        }
    }
}

pub fn paint(w: *const gui.Win) void {
    // 显示区：右对齐
    const dr = displayRect(w);
    gui.fillRect(dr, gui.pal.white);
    gui.bevel1(dr, false);
    var buf: [24]u8 = undefined;
    var text_slice: []const u8 = undefined;
    if (is_error) {
        text_slice = "Error";
    } else if (fresh) {
        const n = fmtVal(acc, &buf) orelse 0;
        text_slice = if (n == 0) "Error" else buf[0..n];
    } else {
        text_slice = entry[0..entry_len];
    }
    const tx = dr.x + dr.w - 6 - @as(i32, @intCast(text_slice.len)) * 8;
    gui.text(tx, dr.y + 4, text_slice, gui.pal.black);

    // 键阵：运算符列藏青底白字，数字白底黑字
    for (KEYS, 0..) |row, ri| {
        for (row, 0..) |k, ci| {
            const r = keyRect(w, ri, ci);
            const is_op = ci == 3 or ri == 0;
            const bg: u32 = if (is_op) gui.pal.chrome else gui.pal.white;
            gui.fillRect(r, bg);
            gui.bevel1(r, true);
            const label = [1]u8{k};
            gui.text(r.x + @divTrunc(BTN_W - 8, 2), r.y + 5, &label, gui.pal.black);
        }
    }
}
