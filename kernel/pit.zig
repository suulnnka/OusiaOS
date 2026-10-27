//! PIT（8253/8254 可编程间隔定时器）
//!
//! 教学要点：
//!   - PIT 通道 0 按 ~1193182 Hz 的固定频率倒计数，减到 0 触发 IRQ0
//!   - 写入分频值 divisor 即可得到目标频率：freq = 1193182 / divisor
//!   - 本内核取 100Hz（每 10ms 一次时钟中断）：
//!       - 时间片轮转调度的"时间片"
//!       - sleep/nanosleep 的时基
//!   - uptime：自开机以来的滴答数（教学内核的"墙上时钟"）

const serial = @import("serial.zig");

pub const FREQUENCY_HZ = 100;
const BASE_HZ = 1193182;

pub var ticks: u64 = 0;

pub fn init() void {
    const divisor: u16 = @intCast(BASE_HZ / FREQUENCY_HZ); // 11932 → ~100Hz

    serial.outb(0x43, 0x36); // 通道0 | 先低后高字节 | 模式3(方波) | 二进制
    serial.outb(0x40, @truncate(divisor));
    serial.outb(0x40, @truncate(divisor >> 8));
}

/// IRQ0 处理：滴答计数 + 唤醒睡眠进程（由调度器注册）
pub var tick_hook: ?*const fn () void = null; // 进程阶段接入唤醒逻辑

pub fn onTick() void {
    ticks += 1;
    if (tick_hook) |h| h();
}

pub fn uptimeMs() u64 {
    return ticks * (1000 / FREQUENCY_HZ);
}
