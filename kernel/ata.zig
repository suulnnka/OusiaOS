//! ATA PIO 磁盘驱动 —— 主通道主盘（primary master），LBA28 寻址
//!
//! 教学要点：
//!   - 磁盘是"块设备"：512 字节扇区为最小读写单位，随机寻址（对比
//!     串口/键盘的字符流）。文件系统就架在这层之上
//!   - 访问协议 = 一组 I/O 端口：写扇区号(LBA) → 写命令 → 轮询状态
//!     → 批量搬数据（PIO：CPU 亲自 insw/outsw，不走 DMA）
//!   - 状态寄存器三要素：BSY(忙) DRQ(数据就绪) ERR(出错)。
//!     每步操作前等 BSY 清零，传输前等 DRQ 置位
//!   - 复位后先 IDENTIFY DEVICE 探测：返回 512 字节的"身份证"
//!     （型号字符串、总扇区数……），有盘才继续
//!
//! 并发约定：本驱动无内部锁——上层（ext2）在【关中断临界区】里调用
//! （教学取舍：单核 + 轮询，一次块操作只有微秒级；见 ext2.zig 注释）。
//! QEMU 侧用 `-drive file=...,if=ide` 接到主通道主盘；-cdrom 走
//! 副通道(0x170)，互不干扰。

const serial = @import("serial.zig");
const console = @import("console.zig");

pub const SECTOR: usize = 512;

// ---- 主通道寄存器端口 ----
const IO: u16 = 0x1F0; // 数据 + 寄存器组基地址
const CTRL: u16 = 0x3F6; // 设备控制/备用状态寄存器

// IO+偏移（读/写含义可能不同）
const REG_DATA: u16 = 0; // 数据端口（insw/outsw）
const REG_ERROR: u16 = 1; // 读：错误码
const REG_SECCOUNT: u16 = 2; // 扇区数
const REG_LBA_LO: u16 = 3; // LBA 低 8 位
const REG_LBA_MID: u16 = 4; // LBA 中 8 位
const REG_LBA_HI: u16 = 5; // LBA 高 8 位
const REG_DRIVE: u16 = 6; // 0xE0 | (LBA>>24 & 0xF)，bit4=盘号
const REG_STATUS: u16 = 7; // 读：状态 / 写：命令

// 状态位
const ST_BSY: u8 = 0x80;
const ST_DRQ: u8 = 0x08;
const ST_ERR: u8 = 0x01;

// 命令
const CMD_IDENTIFY: u8 = 0xEC;
const CMD_READ_PIO: u8 = 0x20;
const CMD_WRITE_PIO: u8 = 0x30;
const CMD_FLUSH: u8 = 0xE7;

var ready = false;
var total_sectors: u32 = 0;

pub fn readyFlag() bool {
    return ready;
}

/// 探测主盘：IDENTIFY 成功则记录容量。返回是否就绪。
pub fn init() bool {
    ready = false;

    // 选盘 + LBA28 模式（0xE0 = bit7 置 1 | bit6 LBA | bit5 保留 1 | bit4=0 主盘）
    serial.outb(IO + REG_DRIVE, 0xE0);
    ioWait();

    // 发 IDENTIFY DEVICE
    _ = waitNotBusy() orelse return false;
    serial.outb(IO + REG_SECCOUNT, 0);
    serial.outb(IO + REG_LBA_LO, 0);
    serial.outb(IO + REG_LBA_MID, 0);
    serial.outb(IO + REG_LBA_HI, 0);
    serial.outb(IO + REG_STATUS, CMD_IDENTIFY);

    // 无盘时 MID/HI 寄存器是 0xFF 且永远不置 DRQ
    if (serial.inb(IO + REG_LBA_MID) == 0xFF and serial.inb(IO + REG_LBA_HI) == 0xFF) {
        console.kprintf("ata: no primary master disk\n", .{});
        return false;
    }
    _ = waitNotBusy() orelse return false;
    const st = serial.inb(IO + REG_STATUS);
    if (st & ST_ERR != 0 or st & ST_DRQ == 0) {
        console.kprintf("ata: identify failed (status {x})\n", .{st});
        return false;
    }

    // 读 512 字节身份证
    var id: [SECTOR]u8 = undefined;
    insw(IO, &id);

    // 字 60-61：LBA28 可寻址总扇区数
    total_sectors = @as(u32, id[120]) | @as(u32, id[121]) << 8 | @as(u32, id[122]) << 16 | @as(u32, id[123]) << 24;

    // 字 27-46：型号字符串（每个字内字节对调 = 大端）
    var model: [40]u8 = undefined;
    for (0..20) |w| {
        model[w * 2] = id[54 + w * 2 + 1];
        model[w * 2 + 1] = id[54 + w * 2];
    }
    var mlen: usize = 40;
    while (mlen > 0 and (model[mlen - 1] == ' ' or model[mlen - 1] == 0)) mlen -= 1;

    ready = true;
    console.kprintf("ata: primary master \"{s}\" {d} sectors ({d} MB)\n", .{
        model[0..mlen], total_sectors, total_sectors / 2048,
    });
    return true;
}

/// 读连续扇区（count ≤ 255）。buf 至少 count*512 字节。
pub fn readSectors(lba: u32, count: u8, buf: []u8) bool {
    if (!ready or count == 0 or buf.len < @as(usize, count) * SECTOR) return false;
    if (!issueCommand(CMD_READ_PIO, lba, count)) return false;

    var done: usize = 0;
    while (done < count) : (done += 1) {
        // 每个扇区都要重新等 DRQ（PIO 每扇区一次握手）
        if (!waitDrq()) return false;
        insw(IO, buf[done * SECTOR ..][0..SECTOR]);
    }
    return true;
}

/// 写连续扇区（count ≤ 255）。只保证命令完成，设备缓存由调用方
/// 在逻辑操作收尾时统一 flush()（按操作刷，而不是按块刷）。
pub fn writeSectors(lba: u32, count: u8, buf: []const u8) bool {
    if (!ready or count == 0 or buf.len < @as(usize, count) * SECTOR) return false;
    if (!issueCommand(CMD_WRITE_PIO, lba, count)) return false;

    var done: usize = 0;
    while (done < count) : (done += 1) {
        if (!waitDrq()) return false;
        outsw(IO, buf[done * SECTOR ..][0..SECTOR]);
    }
    return waitNotBusy() != null;
}

/// FLUSH CACHE：把设备写缓存推出（对 QEMU 即保证镜像文件已更新）
pub fn flush() bool {
    if (!ready) return false;
    if (!waitNotBusy()) return false;
    serial.outb(IO + REG_STATUS, CMD_FLUSH);
    if (!waitNotBusy()) return false;
    return serial.inb(IO + REG_STATUS) & ST_ERR == 0;
}

// ---------------- 内部 ----------------

/// 装载 LBA 地址与扇区数并发起命令
fn issueCommand(cmd: u8, lba: u32, count: u8) bool {
    _ = waitNotBusy() orelse return false;
    serial.outb(IO + REG_DRIVE, 0xE0 | @as(u8, @intCast((lba >> 24) & 0x0F)));
    ioWait();
    serial.outb(IO + REG_SECCOUNT, count);
    serial.outb(IO + REG_LBA_LO, @truncate(lba));
    serial.outb(IO + REG_LBA_MID, @truncate(lba >> 8));
    serial.outb(IO + REG_LBA_HI, @truncate(lba >> 16));
    serial.outb(IO + REG_STATUS, cmd);
    return true;
}

/// 等 BSY 清零（带超时上限，防无设备死循环）
fn waitNotBusy() ?u8 {
    var n: usize = 0;
    while (n < 5_000_000) : (n += 1) {
        const st = serial.inb(IO + REG_STATUS);
        if (st & ST_BSY == 0) return st;
    }
    return null;
}

/// 等 BSY 清零且 DRQ 置位（数据可搬）；ERR/超时返回 false
fn waitDrq() bool {
    var n: usize = 0;
    while (n < 5_000_000) : (n += 1) {
        const st = serial.inb(IO + REG_STATUS);
        if (st & ST_ERR != 0) return false;
        if (st & ST_BSY == 0 and st & ST_DRQ != 0) return true;
    }
    return false;
}

/// 400ns 等待：读备用状态寄存器 4 次（ATA 规范的延时原语）
fn ioWait() void {
    _ = serial.inb(CTRL);
    _ = serial.inb(CTRL);
    _ = serial.inb(CTRL);
    _ = serial.inb(CTRL);
}

/// 16 位端口批量读（insw）：搬一个扇区
fn insw(port: u16, buf: []u8) void {
    const words = buf.len / 2;
    var i: usize = 0;
    while (i < words) : (i += 1) {
        const w: u16 = asm volatile ("inw %[p], %[r]"
            : [r] "={ax}" (-> u16),
            : [p] "{dx}" (port),
        );
        buf[i * 2] = @truncate(w);
        buf[i * 2 + 1] = @truncate(w >> 8);
    }
}

/// 16 位端口批量写（outsw）
fn outsw(port: u16, buf: []const u8) void {
    const words = buf.len / 2;
    var i: usize = 0;
    while (i < words) : (i += 1) {
        const w: u16 = @as(u16, buf[i * 2]) | @as(u16, buf[i * 2 + 1]) << 8;
        asm volatile ("outw %[v], %[p]"
            :
            : [v] "{ax}" (w),
              [p] "{dx}" (port),
        );
    }
}
