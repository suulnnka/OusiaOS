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
//!   - 纯音合成 = DDS（直接数字合成）：32 位相位累加器 + 256 项
//!     comptime 查表——频率就是累加步进，改一个数就变调
//!   - 系统音效 = 音符序列：一段 comptime {频率, 毫秒} 表按序合成，
//!     与 WAV 播放共用同一条"源 → BDL 环"流水线（Source 抽象）
//!   - WAV = RIFF 容器：fmt 块声明 每样本位数/声道/采样率，data 块是
//!     原始 PCM。播放器做三件事归一到 48kHz/16bit/立体声：
//!     8bit 无符号→16bit 有符号、单声道→立体声复制、
//!     采样率≠48k → 固定点步进的最近邻重采样
//!
//! 已知取舍：只做 PCM out（无录音）、单会话（无混音，两个播放方
//! 竞争时后到者 EAGAIN）。多路混音器 = 多源求和 + 削波，是练习。

const std = @import("std");
const console = @import("console.zig");
const serial = @import("serial.zig");
const pci = @import("pci.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const pit = @import("pit.zig");
const vfs = @import("vfs.zig");

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
const FADE = 240; // 淡入淡出样本数（5ms，防爆音）

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
var volume_pct: u32 = 70; // 0..100（Control Panel 可调，MIX_MASTER 衰减）

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

    // 采样率 48kHz（codec 与 QEMU wav 后端保持一致）
    namWrite16(MIX_DAC_RATE, SAMPLE_RATE);
    applyVolume();

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
    console.kprintf("audio: AC97 nam={x} nabm={x} 48kHz S16 stereo, {d} x {d} samples, vol={d}%\n", .{
        nam_port, nabm_port, NBUF, BUF_SAMPLES, volume_pct,
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

/// 音量（0..100）：mixer 衰减寄存器 0=最大、63=最小——
/// pct → 衰减档位线性换算后写主音量（左右声道对称）。
pub fn setVolume(pct: u32) void {
    volume_pct = @min(pct, 100);
    applyVolume();
}

pub fn getVolume() u32 {
    return volume_pct;
}

fn applyVolume() void {
    if (!inited) return;
    const atten: u16 = @intCast((100 - volume_pct) * 63 / 100);
    const v: u16 = atten | (atten << 8);
    namWrite16(MIX_MASTER, v);
    namWrite16(MIX_PCM, v);
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

/// 音符：频率（0 = 休止符）+ 时长毫秒
pub const Note = struct { freq: u32, ms: u32 };

// ---------------- 播放源（纯音序列 / WAV PCM 的统一抽象） ----------------

const Session = struct {
    // ---- 合成模式 ----
    notes: []const Note = &.{},
    note_idx: usize = 0,
    note_left: u64 = 0, // 当前音符剩余帧数
    inc: u32 = 0, // 相位步进 = freq * 2^32 / 48000
    phase: u32 = 0,
    amp: i32 = 10000,

    // ---- PCM 模式（WAV 归一化产物：48kHz 交错立体声 S16）----
    pcm: []const u16 = &.{},
    pcm_pos: usize = 0,

    total: u64 = 0, // 总立体声帧数
    n: u64 = 0, // 已产出帧数
    is_pcm: bool = false,

    /// 产出下一对立体声样本（播完后返回 0——尾缓冲填零防下溢）
    fn nextStereo(self: *Session) [2]i16 {
        if (self.n >= self.total) return .{ 0, 0 };
        var l: i32 = 0;
        var r: i32 = 0;
        if (self.is_pcm) {
            const base = self.pcm_pos * 2;
            if (base + 1 < self.pcm.len) {
                // pcm 缓冲是 u16 存储：按位重解释成 S16（数值转换会把
                // 负样本读成 3 万多的大正数，@intCast 回 i16 直接panic）
                l = @as(i16, @bitCast(self.pcm[base]));
                r = @as(i16, @bitCast(self.pcm[base + 1]));
            }
            self.pcm_pos += 1;
        } else {
            // 音符推进（0 频率 = 休止）
            if (self.note_left == 0 and self.note_idx < self.notes.len) {
                self.startNote(self.notes[self.note_idx]);
                self.note_idx += 1;
            }
            if (self.note_left > 0) {
                self.note_left -= 1;
                const v: i32 = SINE[(self.phase >> 24) & 0xFF];
                self.phase +%= self.inc;
                l = @divTrunc(v * self.amp, 10000);
                r = l;
            }
        }
        self.n += 1;
        // 首尾 5ms 淡入淡出（跨源防爆音；PCM 自带包络则无感）
        const rem = self.total - self.n;
        var e: u64 = FADE;
        if (self.n < FADE) e = self.n;
        if (rem < FADE) e = rem;
        if (e < FADE) {
            l = @divTrunc(l * @as(i32, @intCast(e)), @as(i32, FADE));
            r = @divTrunc(r * @as(i32, @intCast(e)), @as(i32, FADE));
        }
        return .{ @intCast(l), @intCast(r) };
    }

    fn startNote(self: *Session, note: Note) void {
        self.note_left = @as(u64, SAMPLE_RATE) * note.ms / 1000;
        self.phase = 0;
        self.inc = if (note.freq == 0)
            0
        else
            @intCast((@as(u64, note.freq) << 32) / SAMPLE_RATE);
    }
};

fn fillBuffer(idx: u8, s: *Session) void {
    const buf: [*]i16 = @ptrFromInt(vmm.physToVirt(buf_frames[idx]));
    var i: usize = 0;
    while (i < BUF_SAMPLES) : (i += 2) {
        const fr = s.nextStereo();
        buf[i] = fr[0]; // 左
        buf[i + 1] = fr[1]; // 右
    }
}

// ---------------- 播放（阻塞，net.waitTick 同款等待原语） ----------------

/// 播放一段纯音。阻塞直至播完（或超时兜底——无音频后端时 DMA 不消费）。
/// 返回 0 或负 errno。
pub fn playTone(freq: u32, ms: u32) isize {
    const notes = [_]Note{.{ .freq = freq, .ms = ms }};
    var s = Session{ .notes = &notes, .total = @as(u64, SAMPLE_RATE) * ms / 1000 };
    return stream(&s, ms + 1000);
}

/// 播放音符序列（系统音效的底层）
pub fn playNotes(notes: []const Note, amp: i32) isize {
    var total: u64 = 0;
    for (notes) |n| total += @as(u64, SAMPLE_RATE) * n.ms / 1000;
    var ms: u64 = 0;
    for (notes) |n| ms += n.ms;
    var s = Session{ .notes = notes, .total = total, .amp = amp };
    return stream(&s, @intCast(ms + 1000));
}

/// 系统音效（winsys/gui 事件配音；音频忙时静默跳过——单会话取舍）
/// 0 startup  1 click  2 open  3 close  4 ding  5 error  6 tada
pub fn playSystem(kind: u8) isize {
    if (!inited) return -19;
    switch (kind) {
        0 => return playNotes(&.{ .{ .freq = 523, .ms = 90 }, .{ .freq = 659, .ms = 90 }, .{ .freq = 784, .ms = 90 }, .{ .freq = 1047, .ms = 200 } }, 7000),
        1 => return playNotes(&.{.{ .freq = 2400, .ms = 14 }}, 4000),
        2 => return playNotes(&.{ .{ .freq = 392, .ms = 55 }, .{ .freq = 784, .ms = 90 } }, 8000),
        3 => return playNotes(&.{ .{ .freq = 784, .ms = 55 }, .{ .freq = 392, .ms = 90 } }, 8000),
        4 => return playNotes(&.{.{ .freq = 1568, .ms = 220 }}, 8000),
        5 => return playNotes(&.{ .{ .freq = 220, .ms = 130 }, .{ .freq = 185, .ms = 220 } }, 9000),
        6 => return playNotes(&.{ .{ .freq = 523, .ms = 90 }, .{ .freq = 659, .ms = 90 }, .{ .freq = 784, .ms = 90 }, .{ .freq = 1047, .ms = 90 }, .{ .freq = 1319, .ms = 260 } }, 8000),
        else => return -22,
    }
}

/// 共用播放环（武装协议，见 playTone 原版注释）：
///   dist = (lvi - civ) mod NBUF = 已武装未播完的缓冲数
///   只在 dist < NBUF-1 时武装 (lvi+1)——它恰好是 CIV 身后刚播完的
///   缓冲，绝不触碰 DMA 排队中的数据（无撕扯）；DMA 播完 LVI 停机
///   （DCH）时补一条 + 推进 LVI 即可唤醒。填充节奏被播放天然限速。
fn stream(s: *Session, timeout_ms: u64) isize {
    if (!inited) return -19; // ENODEV
    if (busy) return -11; // EAGAIN
    busy = true;
    defer busy = false;

    // 停流 → 复位流 → 重写 BDBAR（复位会把它清零！）→ 预填 → 启动
    nabmWrite8(PO_CR, 0);
    nabmWrite8(PO_SR, 0x1E); // 写 1 清全部状态位
    nabmWrite8(PO_CR, CR_RESET);
    spinUs();
    nabmWrite32(PO_BDBAR, @truncate(bdl_frame));

    // 预填两个缓冲（LVI=1），DMA 播完 LVI 条即停（DCH）
    fillBuffer(0, s);
    fillBuffer(1, s);
    var lvi: u8 = 1;
    nabmWrite8(PO_LVI, lvi);
    nabmWrite8(PO_CR, CR_RPBM); // 启动

    const deadline = pit.ticks + timeout_ms / 10 + 100;
    while (pit.ticks < deadline) {
        const civ = nabmRead8(PO_CIV);
        const dist = (lvi + NBUF - civ) % NBUF;
        const halted = (nabmRead8(PO_SR) & SR_DCH) != 0;
        if (s.n < s.total and dist < NBUF - 1) {
            const next = (lvi + 1) & BDL_MASK;
            fillBuffer(next, s);
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

// ---------------- WAV 播放 ----------------

// WAV 读取/归一化缓冲（静态分配：内核栈只有 16KB，大缓冲绝不能上栈；
// 单会话语义下无并发访问者，静态缓冲安全）
var wav_scratch: [512 * 1024]u8 = undefined;
var pcm_scratch: [128 * 1024]u16 = undefined; // 64K 立体声帧 ≈ 1.4s@48kHz

/// 读文件并播放（sys_ousia_wav / shell `play` 命令的底层）。
/// 内核以 root 身份读（uid 0 旁路权限检查）。
pub fn playWavPath(path: []const u8, cwd: []const u8) isize {
    if (!inited) return -19;
    if (busy) return -11;
    const node = vfs.resolve(path, cwd) orelse return -2; // ENOENT
    const inf = vfs.info(node);
    if (inf.is_dir) return -21; // EISDIR
    if (inf.size > wav_scratch.len) return -27; // EFBIG：教学版单缓冲
    const n = vfs.read(node, 0, wav_scratch[0..@intCast(inf.size)]);
    if (n <= 0) return -5; // EIO
    return playWav(wav_scratch[0..@intCast(n)]);
}

/// 播放内存中的 WAV（RIFF/PCM）。只支持：fmt=1（PCM）、8/16bit、
/// 1/2 声道；其他格式/超长返回 EINVAL。
pub fn playWav(data: []const u8) isize {
    if (!inited) return -19;
    if (busy) return -11;
    if (data.len < 44 or !stdEql3(data[0..4], "RIFF") or !stdEql3(data[8..12], "WAVE")) return -22;

    // 扫 chunk 找 fmt / data（chunk 头 8 字节：id[4] + len[u32 LE]）
    var fmt: ?struct { ch: u16, rate: u32, bits: u16 } = null;
    var pcm_in: ?[]const u8 = null;
    var off: usize = 12;
    while (off + 8 <= data.len) {
        const id = data[off .. off + 4];
        const len: usize = @intCast(data[off + 4] | (@as(u32, data[off + 5]) << 8) | (@as(u32, data[off + 6]) << 16) | (@as(u32, data[off + 7]) << 24));
        const body_start = off + 8;
        if (body_start + len > data.len) break; // 截断文件：取到哪算哪
        if (stdEql3(id, "fmt ") and len >= 16) {
            const b = data[body_start .. body_start + 16];
            const audio_fmt: u16 = @intCast(b[0] | (@as(u16, b[1]) << 8));
            const ch: u16 = @intCast(b[2] | (@as(u16, b[3]) << 8));
            const rate: u32 = b[4] | (@as(u32, b[5]) << 8) | (@as(u32, b[6]) << 16) | (@as(u32, b[7]) << 24);
            const bits: u16 = @intCast(b[14] | (@as(u16, b[15]) << 8));
            if (audio_fmt != 1) return -22; // 只支持线性 PCM
            fmt = .{ .ch = ch, .rate = rate, .bits = bits };
        } else if (stdEql3(id, "data")) {
            pcm_in = data[body_start .. body_start + len];
        }
        off = body_start + (len + 1) & ~@as(usize, 1); // chunk 按 2 字节对齐
    }
    const f = fmt orelse return -22;
    const raw = pcm_in orelse return -22;
    if (f.ch == 0 or f.ch > 2 or (f.bits != 8 and f.bits != 16) or f.rate == 0) return -22;

    // ---- 归一化到 48kHz 交错立体声 S16（放 pcm_scratch）----
    const bytes_per_frame: usize = @as(usize, f.ch) * (f.bits / 8);
    if (bytes_per_frame == 0) return -22;
    const in_frames = raw.len / bytes_per_frame;
    const max_out = pcm_scratch.len / 2; // 立体声帧上限
    // 重采样步进（16.16 定点）：输出每前进一帧，输入步进 inRate/48k；
    // 48k 输入时步进恰为 1<<16（逐帧直通，不损音质）
    const step48: u64 = (@as(u64, f.rate) << 16) / SAMPLE_RATE;

    var frames: usize = 0;
    var acc: u64 = 0;
    while (frames < in_frames and frames < max_out) : (frames += 1) {
        const src_i: usize = @intCast(acc >> 16);
        acc += step48;
        const base = src_i * bytes_per_frame;
        var sample: i32 = 0;
        if (f.bits == 16) {
            // 小端 S16；立体声取左右平均（防止只播一个声道）
            const lo: u16 = raw[base];
            const hi: u16 = raw[@min(base + 1, raw.len - 1)];
            sample = @as(i16, @bitCast(lo | (hi << 8)));
            if (f.ch == 2) {
                const rlo: u16 = raw[@min(base + 2, raw.len - 1)];
                const rhi: u16 = raw[@min(base + 3, raw.len - 1)];
                const r: i32 = @as(i16, @bitCast(rlo | (rhi << 8)));
                sample = @divTrunc(sample + r, 2);
            }
        } else {
            // 8bit WAV 是无符号（128 = 静音）→ 平移成有符号
            sample = (@as(i32, raw[base]) - 128) * 256;
            if (f.ch == 2) {
                const r: i32 = (@as(i32, raw[@min(base + 1, raw.len - 1)]) - 128) * 256;
                sample = @divTrunc(sample + r, 2);
            }
        }
        const out: u16 = @bitCast(@as(i16, @intCast(std.math.clamp(sample, -32768, 32767))));
        pcm_scratch[frames * 2] = out;
        pcm_scratch[frames * 2 + 1] = out; // 单声道 → 立体声复制
    }
    if (frames == 0) return -22;
    var s = Session{ .is_pcm = true, .pcm = pcm_scratch[0 .. frames * 2], .total = frames };
    return stream(&s, @intCast(frames * 1000 / SAMPLE_RATE + 1000));
}

fn stdEql3(a: []const u8, b: []const u8) bool {
    if (a.len < 4 or b.len != 4) return false;
    for (0..4) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}
