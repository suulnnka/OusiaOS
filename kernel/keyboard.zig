//! PS/2 键盘驱动（中断驱动版）
//!
//! 教学要点：
//!   - 键盘控制器(8042)输出缓冲区端口 0x60，按键产生 IRQ1
//!   - 扫描码集合 1（make=按下 / break=松开=make+0x80）
//!   - 驱动只做"扫描码 → 字符"，行规程（回显、退格、缓冲）在 tty.zig

const serial = @import("serial.zig");
const tty = @import("tty.zig");

/// 扫描码集合 1 → ASCII（US 布局）；0 表示无映射/不可打印
const map_normal = [_]u8{
    0,    0x1B, '1', '2', '3',  '4', '5', '6', '7', '8', '9', '0', '-',  '=',  0x08, '\t',
    'q',  'w',  'e', 'r', 't',  'y', 'u', 'i', 'o', 'p', '[', ']', '\n', 0,    'a',  's',
    'd',  'f',  'g', 'h', 'j',  'k', 'l', ';', '\'', '`', 0,   '\\', 'z', 'x',  'c',  'v',
    'b',  'n',  'm', ',', '.',  '/', 0,   '*', 0,   ' ', 0,    0,    0,   0,    0,    0,
    0,    0,    0,   0,   0,    0,   0,   0,   0,   0,   0,    0,    0,   0,    0,    0,
    0,    0,    0,   0,   0,    0,   0,   0,   0,   0,   0,    0,    0,   0,    0,    0,
};

const map_shift = [_]u8{
    0,    0x1B, '!', '@', '#',  '$', '%', '^', '&', '*', '(', ')', '_',  '+',  0x08, '\t',
    'Q',  'W',  'E', 'R', 'T',  'Y', 'U', 'I', 'O', 'P', '{', '}', '\n', 0,    'A',  'S',
    'D',  'F',  'G', 'H', 'J',  'K', 'L', ':', '"', '~', 0,   '|',  'Z', 'X',  'C',  'V',
    'B',  'N',  'M', '<', '>',  '?', 0,   '*', 0,   ' ', 0,    0,    0,   0,    0,    0,
    0,    0,    0,   0,   0,    0,   0,   0,   0,   0,   0,    0,    0,   0,    0,    0,
    0,    0,    0,   0,   0,    0,   0,   0,   0,   0,   0,    0,    0,   0,    0,    0,
};

var shift_down = false;
var ctrl_down = false;

pub fn init() void {
    // 清空 8042 输出缓冲区里可能的残留字节
    while (serial.inb(0x64) & 0x01 != 0) {
        _ = serial.inb(0x60);
    }
}

/// IRQ1 中断处理
pub fn onInterrupt() void {
    // 鼠标字节也走 0x60（状态字 bit5=aux）：绝不能被键盘处理消费，
    // 否则 IRQ12 晚到时会丢包——留给 mouse.onInterrupt
    if (serial.inb(0x64) & 0x20 != 0) return;

    const scancode = serial.inb(0x60);

    if (scancode & 0x80 != 0) {
        // break 码（松开）
        switch (scancode & 0x7F) {
            0x2A, 0x36 => shift_down = false,
            0x1D => ctrl_down = false,
            else => {},
        }
        return;
    }

    // make 码（按下）
    switch (scancode) {
        0x2A, 0x36 => {
            shift_down = true;
            return;
        },
        0x1D => {
            ctrl_down = true;
            return;
        },
        else => {},
    }

    if (scancode >= map_normal.len) return;
    const c: u8 = if (shift_down) map_shift[scancode] else map_normal[scancode];
    if (c == 0) return;

    if (ctrl_down) {
        // Ctrl+X → 控制字符（如 Ctrl+C = 0x03）
        if (c >= 'a' and c <= 'z') tty.onInput(c - 'a' + 1);
        return;
    }
    tty.onInput(c);
}
