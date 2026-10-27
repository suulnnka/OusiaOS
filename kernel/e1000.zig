//! e1000（Intel 8254x）网卡驱动 —— 轮询模式
//!
//! 教学要点：
//!   - 网卡与 CPU 通过"描述符环"协作：环形数组放在物理内存，
//!     CPU 写描述符（指向缓冲区），网卡 DMA 直接读写缓冲区
//!   - TX：填描述符(addr+len+cmd)，写 TDT"踢"网卡开始发送
//!   - RX：网卡填缓冲区并置 DD 位，CPU 取包后回填 RDT 归还
//!   - 本驱动收包用轮询（时钟中断里查询），发送同步等待完成；
//!     改成真中断是经典练习
//!
//! 寄存器偏移（8254x 手册）：CTRL 0x0000 STATUS 0x0008 RCTL 0x0100
//! TCTL 0x0400 TIPG 0x0410 RDBAL 0x2800 RDLEN 0x2808 RDH 0x2810 RDT 0x2818
//! TDBAL 0x3800 TDLEN 0x3808 TDH 0x3810 TDT 0x3818 RAL 0x5400 RAH 0x5404

const console = @import("console.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const pit = @import("pit.zig");
const pci = @import("pci.zig");

const NUM_RX = 64;
const NUM_TX = 16;
const BUF_SIZE = 2048; // 单包缓冲（覆盖 MTU 1514）

/// legacy RX 描述符：缓冲区地址 + 长度/状态
const RxDesc = extern struct {
    addr: u64,
    length: u16,
    checksum: u16,
    status: u8,
    errors: u8,
    special: u16,
};

/// legacy TX 描述符
const TxDesc = extern struct {
    addr: u64,
    length: u16,
    cso: u8,
    cmd: u8,
    status: u8,
    css: u8,
    special: u16,
};

const CMD_EOP: u8 = 0x01; // 包结束
const CMD_IFCS: u8 = 0x02; // 插入 FCS(CRC)
const CMD_RS: u8 = 0x08; // 报告状态（回写 DD）
const RX_DD: u8 = 0x01; // 描述符完成
const RX_EOP: u8 = 0x02;

// 描述符环静态分配：必须 128 字节对齐且物理连续（.bss 天然满足）
var rx_ring: [NUM_RX]RxDesc align(4096) = undefined;
var tx_ring: [NUM_TX]TxDesc align(4096) = undefined;
var tx_bounce: [1536]u8 = undefined; // 发送数据的稳定副本（DMA 期间不能变）

var rx_bufs: [NUM_RX]usize = undefined; // 各缓冲区物理地址
var rx_cur: usize = 0;
var tx_cur: usize = 0;

var regs: ?[*]volatile u32 = null; // MMIO 基址
var mac_addr: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };
var inited = false;

pub fn mac() [6]u8 {
    return mac_addr;
}

pub fn ready() bool {
    return inited;
}

inline fn rd(off: usize) u32 {
    return regs.?[off / 4];
}
inline fn wr(off: usize, val: u32) void {
    regs.?[off / 4] = val;
}

pub fn init() bool {
    const dev = pci.findE1000() orelse {
        console.kprintf("e1000: no NIC found (add -device e1000 to qemu)\n", .{});
        return false;
    };
    regs = @ptrFromInt(dev.mmio_va);
    pci.enableBusMaster(&dev); // 不开总线主控，网卡无法 DMA（经典坑）

    // 复位
    wr(0x0000, rd(0x0000) | 0x0400_0000); // CTRL.RST
    var spins: usize = 0;
    while (rd(0x0000) & 0x0400_0000 != 0 and spins < 100_000_000) spins += 1;

    // 读出厂 MAC（RAL/RAH）
    const ral = rd(0x5400);
    const rah = rd(0x5404);
    mac_addr[0] = @truncate(ral);
    mac_addr[1] = @truncate(ral >> 8);
    mac_addr[2] = @truncate(ral >> 16);
    mac_addr[3] = @truncate(ral >> 24);
    mac_addr[4] = @truncate(rah);
    mac_addr[5] = @truncate(rah >> 8);

    // 中断：保持默认（不主动屏蔽）。轮询模式仍工作——
    // QEMU 的 e1000 模型在 IMS 全零时收包路径可能停滞，实测保留默认可靠

    // 多播表清零
    wr(0x5200, 0);

    // ---- RX 环 ----
    const ring_phys = vmm.virtToPhys(@intFromPtr(&rx_ring));
    for (0..NUM_RX) |i| {
        const f = pmm.allocFrame() orelse return false;
        rx_bufs[i] = f;
        rx_ring[i] = .{
            .addr = f,
            .length = 0,
            .checksum = 0,
            .status = 0,
            .errors = 0,
            .special = 0,
        };
    }
    wr(0x2800, @truncate(ring_phys)); // RDBAL
    wr(0x2804, 0); // RDBAH（<4GB）
    wr(0x2808, NUM_RX * 16); // RDLEN
    wr(0x2810, 0); // RDH
    wr(0x2818, NUM_RX - 1); // RDT：告诉网卡 0..N-2 可用

    // ---- TX 环 ----
    const tphys = vmm.virtToPhys(@intFromPtr(&tx_ring));
    for (0..NUM_TX) |i| tx_ring[i] = .{ .addr = 0, .length = 0, .cso = 0, .cmd = 0, .status = RX_DD, .css = 0, .special = 0 };
    wr(0x3800, @truncate(tphys)); // TDBAL
    wr(0x3804, 0);
    wr(0x3808, NUM_TX * 16); // TDLEN
    wr(0x3810, 0); // TDH
    wr(0x3818, 0); // TDT

    // 使能收发
    wr(0x0100, 0x0400_8002); // RCTL = EN | BAM | SECRC
    wr(0x0400, 0x0004_010A); // TCTL = EN | PSP | CT/COLD 最小值
    wr(0x0410, 0x0060_200A); // TIPG 标准

    inited = true;
    console.kprintf("e1000: mac {x}:{x}:{x}:{x}:{x}:{x} rx={d} tx={d}\n", .{
        mac_addr[0], mac_addr[1], mac_addr[2], mac_addr[3], mac_addr[4], mac_addr[5],
        NUM_RX,    NUM_TX,
    });
    return true;
}

/// 发送一帧（会拷贝到驱动私有缓冲，返回后调用者可复用原缓冲）
pub fn send(frame: []const u8) bool {
    if (!inited or frame.len == 0 or frame.len > tx_bounce.len) return false;
    @memcpy(tx_bounce[0..frame.len], frame);

    const i = tx_cur;
    // 等该槽上一帧完成（DD 置位）
    var spins: usize = 0;
    while (tx_ring[i].status & RX_DD == 0 and spins < 200_000_000) spins += 1;
    if (tx_ring[i].status & RX_DD == 0) return false;

    tx_ring[i] = .{
        .addr = vmm.virtToPhys(@intFromPtr(&tx_bounce)),
        .length = @intCast(frame.len),
        .cso = 0,
        .cmd = CMD_EOP | CMD_IFCS | CMD_RS,
        .status = 0,
        .css = 0,
        .special = 0,
    };
    tx_cur = (tx_cur + 1) % NUM_TX;
    wr(0x3818, @intCast(tx_cur)); // TDT：踢
    return true;
}

/// 取一个收到的帧（返回帧内容切片，驻留在驱动缓冲里，处理完前不要再收）
pub fn recv() ?[]const u8 {
    if (!inited) return null;
    if (rx_ring[rx_cur].status & RX_DD == 0) return null;
    const len: usize = rx_ring[rx_cur].length;
    if (len == 0 or len > BUF_SIZE) {
        reclaim();
        return null;
    }
    const buf: [*]const u8 = @ptrFromInt(vmm.physToVirt(rx_bufs[rx_cur]));
    // 注意：切片指向驱动缓冲，调用方用完前不得再次 recv
    return buf[0..len];
}

/// 归还当前缓冲区给网卡
fn reclaim() void {
    rx_ring[rx_cur].status = 0;
    wr(0x2818, @intCast(rx_cur)); // RDT = 当前槽
    rx_cur = (rx_cur + 1) % NUM_RX;
}

/// 轮询入口：把所有待处理的帧交给 net 层处理后归还
pub fn poll() void {
    const net = @import("net.zig");
    var guard: usize = 0;
    while (guard < 64) : (guard += 1) {
        const frame = recv() orelse break;
        net.handleFrame(frame);
        reclaim();
    }
}
