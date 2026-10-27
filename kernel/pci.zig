//! PCI 总线枚举
//!
//! 教学要点：
//!   - PCI 配置空间经 0xCF8(地址)/0xCFC(数据) 端口访问，
//!     地址格式：bit31 使能 | 总线 | 设备 | 功能 | 寄存器偏移
//!   - 每个功能 256 字节头：vendor/device 在 0x00，BAR0 在 0x10，
//!     中断线在 0x3C
//!   - MMIO BAR（bit0=0）给出物理地址，需映射进内核地址空间后访问

const serial = @import("serial.zig");
const console = @import("console.zig");
const vmm = @import("vmm.zig");

/// 设置 PCI COMMAND：开启 I/O + 内存访问 + 总线主控（DMA 的前提！）
pub fn enableBusMaster(d: *const Device) void {
    const cmd = configRead32(d.bus, d.dev, d.func, 0x04);
    configWrite32(d.bus, d.dev, d.func, 0x04, cmd | 0x7);
    _ = configRead32(d.bus, d.dev, d.func, 0x04);
}

pub const Device = struct {
    bus: u8,
    dev: u8,
    func: u8,
    vendor: u16,
    device: u16,
    bar0_phys: u64,
    bar0_size: usize,
    irq_line: u8,
    mmio_va: usize = 0,
};

// 0xCF8 是 32 位端口：一次写整个配置地址（类型 1 访问机制）
fn configAddr(bus: u8, dev: u8, func: u8, off: u8) u32 {
    return 0x8000_0000 |
        (@as(u32, bus) << 16) | (@as(u32, @intCast(dev)) << 11) |
        (@as(u32, @intCast(func)) << 8) | off;
}

fn configRead32(bus: u8, dev: u8, func: u8, off: u8) u32 {
    serial.outw(0xCF8, configAddr(bus, dev, func, off));
    return serial.inw(0xCFC);
}

fn configWrite32(bus: u8, dev: u8, func: u8, off: u8, val: u32) void {
    serial.outw(0xCF8, configAddr(bus, dev, func, off));
    serial.outw(0xCFC, val);
}

/// 探测 BAR 大小：写全 1 再读回，低 0 位个数即尺寸
fn barSize(bus: u8, dev: u8, func: u8, barno: u8) usize {
    const off = 0x10 + barno * 4;
    const orig = configRead32(bus, dev, func, off);
    configWrite32(bus, dev, func, off, 0xFFFF_FFFF);
    const readback = configRead32(bus, dev, func, off);
    configWrite32(bus, dev, func, off, orig);
    if (readback == 0 or readback == 0xFFFF_FFFF) return 0;
    // 只支持 32 位 MMIO BAR（QEMU e1000 即是）
    const mask = readback & 0xFFFF_FFF0;
    if (mask == 0) return 0;
    return @as(usize, 1) << @intCast(@ctz(mask));
}

/// 扫描 0 号总线找 e1000（vendor 0x8086 / device 0x100E）
pub fn findE1000() ?Device {
    var dev: u8 = 0;
    while (dev < 32) : (dev += 1) {
        var func: u8 = 0;
        while (func < 8) : (func += 1) {
            const v = configRead32(0, dev, func, 0);
            const vendor: u16 = @truncate(v);
            const device: u16 = @truncate(v >> 16);
            if (vendor == 0xFFFF) continue;
            if (vendor == 0x8086 and device == 0x100E) {
                const bar0 = configRead32(0, dev, func, 0x10);
                if (bar0 & 1 != 0) continue; // I/O BAR，跳过
                var d = Device{
                    .bus = 0,
                    .dev = dev,
                    .func = func,
                    .vendor = vendor,
                    .device = device,
                    .bar0_phys = bar0 & 0xFFFF_FFF0,
                    .bar0_size = barSize(0, dev, func, 0),
                    .irq_line = @truncate(configRead32(0, dev, func, 0x3C)),
                };
                if (d.bar0_size == 0) d.bar0_size = 0x20000; // e1000 规格值兜底
                d.mmio_va = vmm.mapMMIO(d.bar0_phys, d.bar0_size);
                console.kprintf("pci: e1000 @ 00:{x}.{d} bar0={x}/{d}KB irq={d}\n", .{
                    @as(u8, dev), func, d.bar0_phys, d.bar0_size / 1024, d.irq_line,
                });
                return d;
            }
        }
    }
    return null;
}
