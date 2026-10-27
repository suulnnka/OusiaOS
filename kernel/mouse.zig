//! PS/2 鼠标驱动（IRQ12，轮转数据包协议）
//!
//! 教学要点：
//!   - 8042 键盘控制器同时管理两个口：端口 1 = 键盘，端口 2 = 鼠标(aux)
//!   - 使能三步：开 aux 口(0xA8) → 控制器命令字置 bit1 允许 IRQ12、
//!     清 bit5(鼠标时钟) → 给鼠标发 0xD4 前缀命令：0xF6 默认值 + 0xF4 上报
//!   - 数据包 3 字节：[flags, dx, dy]
//!       flags: bit0 左键 bit1 右键 bit2 中键 bit3 恒 1(同步用)
//!              bit4 dx 为负 bit5 dy 为负 bit6/7 溢出
//!   - 屏幕 y 向下增长，PS/2 dy 向上为正 → gui 侧取反
//!   - bit3 恒 1 是同步锚点：错位后丢弃直到对齐（ACK 0xFA 没有 bit3，
//!     初始化残留字节不会进入状态机）
//!
//! 命令字(CCByte)保留位的坑：重写时必须保留 bit6 的 scancode 转换
//! （键盘驱动依赖 set 1），只动 bit1/bit5。

const serial = @import("serial.zig");
const gui = @import("gui.zig");

const STAT = 0x64; // 状态/命令口
const DATA = 0x60; // 数据口

var inited = false;
var cycle: u8 = 0; // 包内位置 0/1/2
var pkt: [3]u8 = .{ 0, 0, 0 };

/// 等输出缓冲区空（可向 8042 发命令），带超时
fn waitWrite() bool {
    var spins: usize = 0;
    while (spins < 100_000) : (spins += 1) {
        if (serial.inb(STAT) & 0x02 == 0) return true;
    }
    return false;
}

/// 等输入缓冲区有数据（可读），带超时
fn waitRead() bool {
    var spins: usize = 0;
    while (spins < 100_000) : (spins += 1) {
        if (serial.inb(STAT) & 0x01 != 0) return true;
    }
    return false;
}

/// 向鼠标发命令（0xD4 前缀）并等 ACK(0xFA)
fn mouseCmd(cmd: u8) bool {
    if (!waitWrite()) return false;
    serial.outb(STAT, 0xD4);
    if (!waitWrite()) return false;
    serial.outb(DATA, cmd);
    return waitRead() and serial.inb(DATA) == 0xFA;
}

pub fn init() bool {
    // 1) 使能 aux（鼠标）口
    if (!waitWrite()) return false;
    serial.outb(STAT, 0xA8);

    // 2) 控制器命令字：|0x03(两个 IRQ 都开) &~0x20(鼠标时钟别禁)
    if (!waitWrite()) return false;
    serial.outb(STAT, 0x20);
    if (!waitRead()) return false;
    var ccb = serial.inb(DATA);
    ccb = (ccb | 0x03) & ~@as(u8, 0x20);
    if (!waitWrite()) return false;
    serial.outb(STAT, 0x60);
    if (!waitWrite()) return false;
    serial.outb(DATA, ccb);

    // 3) 鼠标：默认值 + 开始上报
    if (!mouseCmd(0xF6)) return false;
    if (!mouseCmd(0xF4)) return false;

    cycle = 0;
    inited = true;
    return true;
}

pub fn ready() bool {
    return inited;
}

/// IRQ12 中断处理：积累 3 字节数据包，完整后交给 gui
pub fn onInterrupt() void {
    if (!inited) return;
    // 排空当前所有【鼠标】字节（状态字 bit5=aux）；键盘字节留给 IRQ1
    while (serial.inb(STAT) & 0x21 == 0x21) {
        const b = serial.inb(DATA);
        switch (cycle) {
            0 => {
                if (b & 0x08 == 0) continue; // 不在包边界：等 bit3
                pkt[0] = b;
                cycle = 1;
            },
            1 => {
                pkt[1] = b;
                cycle = 2;
            },
            else => {
                pkt[2] = b;
                cycle = 0;
                deliver();
            },
        }
    }
}

fn deliver() void {
    const f = pkt[0];
    if (f & 0xC0 != 0) return; // 溢出包丢弃
    var dx: i32 = pkt[1];
    var dy: i32 = pkt[2]; // PS/2: y 向上为正
    if (f & 0x10 != 0) dx -= 256;
    if (f & 0x20 != 0) dy -= 256;
    gui.onMouseDelta(dx, -dy, @as(u3, @truncate(f & 7))); // 屏幕 y 向下 → 取反
}
