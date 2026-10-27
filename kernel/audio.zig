//! AC'97 音频子系统（Intel 82801AA，QEMU `-device AC97`）
//!
//! 教学要点：
//!   - 声卡 = 两块寄存器：NAM（原生音频 mixer，音量/采样率）与
//!     NABM（原生音频总线主控：DMA 引擎）。两块都是 I/O 端口 BAR
//!   - 播放路径与 e1000 同构：内核把 PCM 填进内存缓冲，设备按
//!     【BDL 描述符环】逐条 DMA 搬给 codec——只是方向反过来
//!   - 轮询驱动（本内核的教学取舍，同串口/网卡）：CIV 寄存器指示
//!     正在播放的描述符，播放环保持 2 个缓冲的填充提前量，
//!     sti/hlt 等时钟醒来再补（net.waitTick 同款等待原语）
//!   - 正弦合成用 DDS（直接数字合成）：32 位相位累加器 + 256 项
//!     comptime 查表——频率就是累加步进，改一个数就变调
//!
//! 已知取舍：只做 PCM out（无录音）、48kHz/16bit/立体声固定、
//! 单音（无混音）。多音混音/录音是很好的练习。

const console = @import("console.zig");
const serial = @import("serial.zig");
const pci = @import("pci.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const pit = @import("pit.zig");

const PCI_VID_INTEL: u16 = 0x8086;
const PCI_DID_AC97: u16 = 0x2415;

// ---- NABM（总线主控）寄存器偏移 ----
const PO_BDBAR = 0x10; // PCM-out BDL 物理地址（32 位）
const PO_CIV = 0x14; // 当前描述符索引（只读，DMA 推进）
const PO_LVI = 0x15; // 最后有效索引（播完此条即停）
const PO_SR = 0x16; // 状态（写 1 清除）
const PO_CR = 0x1B; // 控制
const GLOB_CNT = 0x2C; // 全局控制（bit1 = 冷复位 AC-link）
const GLOB_STA = 0x30; // 全局状态

// ---- NAM（mixer）寄存器偏移 ----
const MIX_RESET = 0x00; // 写任意值 = codec 热复位
const MIX_MASTER = 0x02; // 主音量（每字节一声道，0 = 最大）
const MIX_PCM = 0x18; // PCM 播放音量
const MIX_DAC_RATE = 0x2C; // 前置 DAC 采样率

const SR_DCH: u8 = 0x01; // DMA 已停（播完 LVI / 未启动 / 下溢）
const CR_RPBM: u8 = 0x01; // 启动总线主控（写 0 暂停）
const CR_RESET: u8 = 0x02; // 复位流——注意：会清掉 BDBAR/CIV/LVI！

const SAMPLE_RATE = 48000;
// BDL 固定 32 槽（QEMU/ICH 的描述符索引按 32 取模推进——
// 只用 8 个的话，9..31 是未清零的垃圾条目，DMA 会在里面漫游）
const NBUF = 32;
const BUF_SAMPLES = 2048; // 每缓冲 16-bit 样本数（1024 立体声帧 ≈ 21ms）
const BDL_MASK: u8 = NBUF - 1;
const FADE = 240; // 首尾淡入淡出样本数（5ms，防爆音）

/// BDL 描述符：缓冲区物理地址 + 32 位 ctl_len
/// （低 16 位 = 16-bit 样本总数【不减一】；高 16 位 = IOC/BUP 标志，本驱动不用）
const BdlEntry = extern struct {
    addr: u32,
    ctl_len: u32,
};

var nam_port: u16 = 0; // BAR0（mixer）
var nabm_port: u16 = 0; // BAR1（bus master）
var bdl_frame: usize = 0; // BDL 所在页帧
var buf_frames: [NBUF]usize = @splat(0); // 播放缓冲页帧

var inited = false;
var busy = false; // 一次只允许一个播放会话

// ---------------- 寄存器访问（I/O 端口） ----------------

inline fn namRead16(reg: u16) u16 {
    return serial.in16(nam_port + reg);
}

inline fn namWrite16(reg: u16, val: u16) void {
    serial.out16(nam_port + reg, val);
}

inline fn nabmRead8(reg: u16) u8 {
    return serial.inb(nabm_port + reg);
}

inline fn nabmWrite8(reg: u16, val: u8) void {
    serial.outb(nabm_port + reg, val);
}

inline fn nabmWrite32(reg: u16, val: u32) void {
    serial.outw(nabm_port + reg, val); // serial.outw 是 32 位 outl
}

/// 消磨约 N 微秒（复位时序用；此时可能还没有时钟中断，忙等）
fn spinUs() void {
    var i: usize = 0;
    while (i < 200_000) : (i += 1) serial.ioWait();
}

// ---------------- 初始化 ----------------

pub fn init() bool {
    const dev = pci.find(PCI_VID_INTEL, PCI_DID_AC97) orelse {
        console.kprintf("audio: no AC97 controller (add '-device AC97' to qemu)\n", .{});
        return false;
    };
    // AC97 的 BAR0/BAR1 都是 I/O 端口空间（bar & 1 == 1）
    if (dev.bar0_phys & 1 == 0 or dev.bar0_phys == 0) {
        console.kprintf("audio: unexpected BAR type {x}\n", .{dev.bar0_phys});
        return false;
    }
    nam_port = @intCast(dev.bar0_phys & ~@as(u32, 3));
    nabm_port = @intCast(configBar1(dev) & ~@as(u32, 3));
    pci.enableBusMaster(&dev);

    // 冷复位：拉断 AC-link 再放开（GLOB_CNT bit1 置位 → 等 → 清零）
    nabmWrite8(GLOB_CNT, 0x02);
    spinUs();
    nabmWrite8(GLOB_CNT, 0x00);
    spinUs();
    // codec 热复位：mixer RESET 寄存器写全 1
    namWrite16(MIX_RESET, 0xFFFF);
    spinUs();

    // 音量：主音量与 PCM 均 0 dB（每字节一声道，0 = 不衰减）
    namWrite16(MIX_MASTER, 0x0000);
    namWrite16(MIX_PCM, 0x0000);
    // 采样率 48kHz（codec 与 QEMU wav 后端保持一致）
    namWrite16(MIX_DAC_RATE, SAMPLE_RATE);

    // BDL 与播放缓冲：各一页帧（物理 < 4GB，DMA 可直达）
    bdl_frame = pmm.allocFrame() orelse return false;
    const bdl: *align(4096) volatile [NBUF]BdlEntry = @ptrFromInt(vmm.physToVirt(bdl_frame));
    for (0..NBUF) |i| {
        buf_frames[i] = pmm.allocFrame() orelse return false;
        bdl[i] = .{
            .addr = @truncate(buf_frames[i]),
            .ctl_len = BUF_SAMPLES, // 低 16 位 = 样本数（原始值，不减一）
        };
    }

    inited = true;
    console.kprintf("audio: AC97 nam={x} nabm={x} 48kHz S16 stereo, {d} x {d} samples\n", .{
        nam_port, nabm_port, NBUF, BUF_SAMPLES,
    });
    return true;
}

/// 读 BAR1（NABM 基址）——pci.Device 只缓存了 BAR0，这里经原设备坐标回读
fn configBar1(dev: pci.Device) u32 {
    // 0x14 = BAR1 偏移；借用 pci 模块的配置空间访问
    return pci.configRead32(dev.bus, dev.dev, dev.func, 0x14);
}

pub fn ready() bool {
    return inited;
}

// ---------------- DDS 正弦合成 ----------------

/// 256 项正弦表（幅度 10000，留 headroom 防削波）
const SINE = blk: {
    var t: [256]i16 = undefined;
    for (0..256) |i| {
        const v = @sin(@as(f64, @floatFromInt(i)) * std_math_tau / 256.0) * 10000.0;
        t[i] = @intFromFloat(v);
    }
    break :blk t;
};
const std_math_tau: f64 = 6.283185307179586;

/// 单音播放状态（playTone 内部使用）
const Synth = struct {
    freq: u32,
    inc: u32, // 相位步进 = freq * 2^32 / 48000
    phase: u32 = 0,
    n: u64 = 0, // 已产出帧数
    total: u64, // 总帧数
    amp: i32 = 10000,

    fn sample(self: *Synth) i16 {
        if (self.n >= self.total) return 0; // 尾缓冲填零（防下溢）
        const rem = self.total - self.n;
        // 淡入淡出包络（首尾各 FADE 帧）
        var e: u64 = FADE;
        if (self.n < FADE) e = self.n;
        if (rem < FADE) e = rem;
        const v: i32 = SINE[(self.phase >> 24) & 0xFF];
        const out: i32 = @divTrunc(v * @as(i32, @intCast(e)), @as(i32, FADE));
        self.phase +%= self.inc;
        self.n += 1;
        return @intCast(out);
    }
};

fn fillBuffer(idx: u8, s: *Synth) void {
    const buf: [*]i16 = @ptrFromInt(vmm.physToVirt(buf_frames[idx]));
    var i: usize = 0;
    while (i < BUF_SAMPLES) : (i += 2) {
        const v = s.sample();
        buf[i] = v; // 左
        buf[i + 1] = v; // 右
    }
}

// ---------------- 播放（阻塞，net.waitTick 同款等待原语） ----------------

/// 播放一段纯音。阻塞直至播完（或超时兜底——无音频后端时 DMA 不消费）。
/// 返回 0 或负 errno。
pub fn playTone(freq: u32, ms: u32) isize {
    if (!inited) return -19; // ENODEV
    if (busy) return -11; // EAGAIN
    busy = true;
    defer busy = false;

    var s = Synth{
        .freq = freq,
        .inc = @intCast((@as(u64, freq) << 32) / SAMPLE_RATE),
        .total = @as(u64, SAMPLE_RATE) * ms / 1000,
    };
    if (freq == 0) s.inc = 0; // 静音（休止符）

    // 停流 → 复位流 → 重写 BDBAR（复位会把它清零！）→ 预填 → 启动
    nabmWrite8(PO_CR, 0);
    nabmWrite8(PO_SR, 0x1E); // 写 1 清全部状态位
    nabmWrite8(PO_CR, CR_RESET);
    spinUs();
    nabmWrite32(PO_BDBAR, @truncate(bdl_frame));

    // 预填两个缓冲（LVI=1），DMA 播完 LVI 条即停（DCH）
    fillBuffer(0, &s);
    fillBuffer(1, &s);
    var lvi: u8 = 1;
    nabmWrite8(PO_LVI, lvi);
    nabmWrite8(PO_CR, CR_RPBM); // 启动

    // 播放环（武装协议）：
    //   dist = (lvi - civ) mod NBUF = 已武装未播完的缓冲数
    //   只在 dist < NBUF-1 时武装 (lvi+1)——它恰好是 CIV 身后刚播完的
    //   缓冲，绝不触碰 DMA 排队中的数据（无撕扯）；DMA 播完 LVI 停机
    //   （DCH）时补一条 + 推进 LVI 即可唤醒。填充节奏被播放天然限速。
    //   总时长 +1s 硬超时兜底（无音频后端时 DMA 不消费）。
    const deadline = pit.ticks + @as(u64, ms) / 10 + 100;
    while (pit.ticks < deadline) {
        const civ = nabmRead8(PO_CIV);
        const dist = (lvi + NBUF - civ) % NBUF;
        const halted = (nabmRead8(PO_SR) & SR_DCH) != 0;
        if (s.n < s.total and dist < NBUF - 1) {
            const next = (lvi + 1) & BDL_MASK;
            fillBuffer(next, &s);
            lvi = next;
            nabmWrite8(PO_LVI, lvi);
        }
        if (s.n >= s.total and halted) break; // 全部播完（DMA 停在 LVI）
        asm volatile ("sti");
        asm volatile ("hlt");
        asm volatile ("cli");
    }

    nabmWrite8(PO_CR, 0); // 停流
    return 0;
}
