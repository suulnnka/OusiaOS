//! 8259 PIC（可编程中断控制器）
//!
//! 教学要点：
//!   - PC 用两片级联 8259（主片 0x20/0xA0，从片接在主片 IRQ2）
//!   - CPU 前 32 个向量是异常，BIOS 默认 IRQ0-15 映射到向量 8-15，
//!     与异常冲突 → 必须重映射到 32-47
//!   - IMR（中断屏蔽寄存器）决定放行哪些 IRQ

const serial = @import("serial.zig");

pub const IRQ_BASE = 32; // 重映射目标向量基址

const MASTER_CMD = 0x20;
const MASTER_DATA = 0x21;
const SLAVE_CMD = 0xA0;
const SLAVE_DATA = 0xA1;

/// 初始化：重映射 IRQ0-15 → 向量 32-47，8086 模式，级联
pub fn init() void {
    // ICW1: 初始化，级联模式，需要 ICW4
    serial.outb(MASTER_CMD, 0x11);
    serial.ioWait();
    serial.outb(SLAVE_CMD, 0x11);
    serial.ioWait();

    // ICW2: 向量基址
    serial.outb(MASTER_DATA, IRQ_BASE);
    serial.ioWait();
    serial.outb(SLAVE_DATA, IRQ_BASE + 8);
    serial.ioWait();

    // ICW3: 主片 IRQ2 接从片；从片身份号 2
    serial.outb(MASTER_DATA, 0x04);
    serial.ioWait();
    serial.outb(SLAVE_DATA, 0x02);
    serial.ioWait();

    // ICW4: 8086 模式
    serial.outb(MASTER_DATA, 0x01);
    serial.ioWait();
    serial.outb(SLAVE_DATA, 0x01);
    serial.ioWait();

    // 先屏蔽全部，由各驱动按需打开
    serial.outb(MASTER_DATA, 0xFF);
    serial.outb(SLAVE_DATA, 0xFF);
}

/// 解除某个 IRQ 的屏蔽（irq: 0-15）
pub fn unmask(irq: u8) void {
    if (irq >= 16) return;
    if (irq < 8) {
        const cur = serial.inb(MASTER_DATA);
        serial.outb(MASTER_DATA, cur & ~(@as(u8, 1) << @intCast(irq)));
    } else {
        const cur = serial.inb(SLAVE_DATA);
        serial.outb(SLAVE_DATA, cur & ~(@as(u8, 1) << @intCast(irq - 8)));
    }
}

pub fn mask(irq: u8) void {
    if (irq >= 16) return;
    if (irq < 8) {
        const cur = serial.inb(MASTER_DATA);
        serial.outb(MASTER_DATA, cur | (@as(u8, 1) << @intCast(irq)));
    } else {
        const cur = serial.inb(SLAVE_DATA);
        serial.outb(SLAVE_DATA, cur | (@as(u8, 1) << @intCast(irq - 8)));
    }
}

/// 中断处理结束信号（EOI）；从片 IRQ 需通知两片
pub fn sendEoi(irq: u8) void {
    if (irq >= 8) {
        serial.outb(SLAVE_CMD, 0x20);
    }
    serial.outb(MASTER_CMD, 0x20);
}
