//! PS/2 键盘驱动（中断驱动版）
//!
//! 教学要点：
//!   - 键盘控制器(8042)输出缓冲区端口 0x60，按键产生 IRQ1
//!   - 扫描码集合 1（make=按下 / break=松开=make+0x80）
//!   - 驱动只做"扫描码 → 字符"，行规程（回显、退格、缓冲）在 tty.zig

const serial = @import("serial.zig");
const gui = @import("gui.zig");

/// 扫描码集合 1 → ASCII（US 布局）；0 表示无映射/不可打印
const map_normal = [_]u8{
    0,    0x1B, '1', '2', '3',  '4', '5', '6', '7', '8', '9', '0', '-',  '=',  0x08, '\t',
    'q',  'w',  'e', 'r', 't',  'y', 'u', 'i', 'o', 'p', '[', ']', '\n', 0,    'a',  's',
    'd',  'f',  'g', 'h', 'j',  'k', 'l', ';', '\'', '`', 0,   '\\', 'z', 'x',  'c',  'v',
    'b',  'n',  'm', ',', '.',  '/', 0,   '*', 0,   ' ', 0,    0,    0,   0,    0,    0,
    0,    0,    0,   0,   0,    0,   0,   0,   0,   0,   0,    0,    0,   0,    0,    0,
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

    // 方向键/编辑键 → GUI 私有键码（0xF0..0xF8）：没有 ASCII 映射，且
    // 绝不能以控制字符身份进 tty（0x11/0x13 是 XON/XOFF，串口终端会炸流控）
    const special: u8 = switch (scancode) {
        0x48 => 0xF0, // ↑
        0x50 => 0xF1, // ↓
        0x4B => 0xF2, // ←
        0x4D => 0xF3, // →
        0x47 => 0xF4, // Home
        0x4F => 0xF5, // End
        0x49 => 0xF6, // PgUp
        0x51 => 0xF7, // PgDn
        0x53 => 0xF8, // Del
        else => 0,
    };
    if (special != 0) {
        gui.onKey(special); // gui.onKey：焦点在 GUI 应用才收，否则丢弃
        return;
    }

    if (scancode >= map_normal.len) return;
    const c: u8 = if (shift_down) map_shift[scancode] else map_normal[scancode];
    if (c == 0) return;

    if (ctrl_down) {
        // Ctrl+X → 控制字符（如 Ctrl+C = 0x03）
        if (c >= 'a' and c <= 'z') gui.onKey(c - 'a' + 1);
        return;
    }
    // 统一入口：gui.onKey 决定按键归 GUI 焦点应用还是串口 shell 的 tty
    gui.onKey(c);
}
