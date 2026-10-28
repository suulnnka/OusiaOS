//! calc —— 计算器（用户态 GUI 应用）
//!
//! f64 四则 + 链式运算 + 退格/取负/CE/C。用户态下用浮点毫无压力——
//! 内核的陷入/上下文切换都保存 XMM 现场（见 idt.zig / proc.zig），
//! 这正是"内核态/用户态边界上浮点寄存器归属"的经典教学内容。

const ousia = @import("lib/ousia.zig");
const win = @import("lib/win.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

const CW = 184;
const CH = 217;
const BTN_W = 34;
const BTN_H = 26;
const GAP = 6;

/// 4x5 键阵（E=CE，<=退格，N=取负）
const KEYS = [5][4]u8{
    .{ 'C', 'E', '<', '/' },
    .{ '7', '8', '9', '*' },
    .{ '4', '5', '6', '-' },
    .{ '1', '2', '3', '+' },
    .{ '0', '.', 'N', '=' },
};

var acc: f64 = 0;
var pending: u8 = 0;
var entry: [17]u8 = @splat('0');
var entry_len: usize = 1;
var fresh = true;
var is_error = false;
var dirty = true;

fn keyRect(row: usize, col: usize) struct { x: i32, y: i32 } {
    const gx = @divTrunc(CW - (4 * BTN_W + 3 * GAP), 2);
    const gy = 8 + 24 + 8; // 显示区下
    return .{ .x = gx + @as(i32, @intCast(col)) * (BTN_W + GAP), .y = gy + @as(i32, @intCast(row)) * (BTN_H + GAP) };
}

fn entryVal() f64 {
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
    return v == v and v > -1.0e15 and v < 1.0e15;
}

/// f64 → 字符串：整数部分 + 小数 6 位去尾零
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
        '/' => a / b,
        else => b,
    };
}

fn pressKey(k: u8) void {
    if (is_error) {
        if (k >= '0' and k <= '9') {
            is_error = false;
            acc = 0;
            pending = 0;
        } else if (k != 'C') {
            return;
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
        'C' => {
            acc = 0;
            pending = 0;
            entry_len = 1;
            entry[0] = '0';
            fresh = true;
            is_error = false;
        },
        'E' => {
            entry_len = 1;
            entry[0] = '0';
            fresh = true;
        },
        '<' => {
            if (!fresh and entry_len > 0) {
                entry_len -= 1;
                if (entry_len == 0) {
                    entry[0] = '0';
                    entry_len = 1;
                }
            }
        },
        'N' => {
            if (fresh) {
                acc = -acc;
                if (!isFinite(acc)) {
                    is_error = true;
                    win.sound(5);
                }
            } else if (entry_len + 1 < entry.len) {
                var i = entry_len;
                while (i > 0) {
                    i -= 1;
                    entry[i + 1] = entry[i];
                }
                entry[0] = '-';
                entry_len += 1;
            }
        },
        else => {},
    }
    dirty = true;
}

fn press(x: i32, y: i32) void {
    for (KEYS, 0..) |krow, ri| {
        for (krow, 0..) |k, ci| {
            const r = keyRect(ri, ci);
            if (x >= r.x and y >= r.y and x < r.x + BTN_W and y < r.y + BTN_H) {
                pressKey(k);
                return;
            }
        }
    }
}

fn draw() void {
    win.fillRect(0, 0, CW, CH, win.C_CHROME);

    // 显示区
    const dx = 8;
    const dy = 8;
    const dw = CW - 16;
    win.fillRect(dx, dy, dw, 24, win.C_WHITE);
    win.bevel(dx, dy, dw, 24, false);
    var buf: [24]u8 = undefined;
    var s: []const u8 = undefined;
    if (is_error) {
        s = "Error";
    } else if (fresh) {
        const n = fmtVal(acc, &buf) orelse 0;
        s = if (n == 0) "Error" else buf[0..n];
    } else {
        s = entry[0..entry_len];
    }
    win.text(dx + dw - 6 - @as(i32, @intCast(s.len)) * 8, dy + 4, s, win.C_BLACK);

    // 键阵：首行与运算符列灰底，数字白底
    for (KEYS, 0..) |krow, ri| {
        for (krow, 0..) |k, ci| {
            const r = keyRect(ri, ci);
            const is_op = ci == 3 or ri == 0;
            win.fillRect(r.x, r.y, BTN_W, BTN_H, if (is_op) win.C_CHROME else win.C_WHITE);
            win.bevel(r.x, r.y, BTN_W, BTN_H, true);
            const kk = [1]u8{k};
            win.text(r.x + @divTrunc(BTN_W - 8, 2), r.y + 5, &kk, win.C_BLACK);
        }
    }
}

export fn main() i32 {
    if (!win.create(CW, CH, "Calculator")) return 1;
    win.initColors();

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
                win.EV_KEY => pressKey(e.code), // 键盘也能按计算器！
                else => {},
            }
        }
    }
    return 0;
}
