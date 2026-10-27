//! 物理页帧分配器（PMM: Physical Memory Manager）
//!
//! 教学要点：
//!   - "谁在管理物理内存"是内核的第一要务：把整块物理内存切成
//!     4096 字节的"页帧"，用一个位图跟踪每帧是否空闲
//!   - 位图按 multiboot2 内存映射初始化：只有 usable 的区域可分配，
//!     内核镜像、initrd、显存等区域标记为保留
//!   - 分配策略：从上次分配位置线性向下扫描（简单且够用）
//!
//! 约定：低 2MB（引导段+内核镜像）全部保留，永不分配。

const console = @import("console.zig");
const multiboot = @import("multiboot.zig");

pub const FRAME_SIZE: usize = 4096;
pub const FRAME_SHIFT: u6 = 12;

/// 支持的物理内存上限：2GB。
/// 原因：内核链接在 0xFFFFFFFF80000000，到 2^64 顶界只有 2GB 空间做直接映射。
/// （位图 64KB，静态分配在内核 .bss；Linux 的做法是独立的直接映射窗口，
///  作为练习可以尝试把直接映射区挪到 0xFFFF880000000000 来支持更大内存。）
pub const MAX_PHYS: usize = 2 * 1024 * 1024 * 1024;
const MAX_FRAMES = MAX_PHYS / FRAME_SIZE;
const BITMAP_WORDS = MAX_FRAMES / 64;

/// 位图：bit=1 表示该帧已被占用
var bitmap: [BITMAP_WORDS]u64 = undefined;
var total_frames: usize = 0; // 实际存在的帧数（按内存上限截断）
var free_count: usize = 0;
var next_hint: usize = 0; // 下次扫描起点（轮询指针）

extern const kernel_phys_start: u8; // 链接脚本符号
extern const kernel_phys_end: u8;

pub fn init() void {
    // 全部置为占用，再按内存映射打开可用区域
    @memset(&bitmap, 0xFFFF_FFFF_FFFF_FFFF);

    walkMmapAndInit();

    // 保留低 2MB（引导段 + 内核镜像 + multiboot 信息通常也在这附近）
    reserveRange(0, 2 * 1024 * 1024);
    // 内核镜像范围（可能超过 2MB）
    reserveRange(@intFromPtr(&kernel_phys_start), @intFromPtr(&kernel_phys_end));
    // initrd 模块
    if (multiboot.initrd_end > multiboot.initrd_start) {
        reserveRange(multiboot.initrd_start, multiboot.initrd_end);
    }

    free_count = countFree();
    total_frames = MAX_FRAMES;
}

/// 重新遍历 multiboot mmap，把 usable 区域的帧标记为可用
fn walkMmapAndInit() void {
    for (multiboot.usableRegions()) |r| {
        const start = (r.base_addr + FRAME_SIZE - 1) & ~(FRAME_SIZE - 1); // 向上取整对齐
        const end = @min(r.base_addr + r.length, MAX_PHYS);
        var addr = start;
        while (addr + FRAME_SIZE <= end) : (addr += FRAME_SIZE) {
            clearBit(frameIndexOf(addr));
        }
    }
}

pub fn allocFrame() ?usize {
    var i: usize = 0;
    while (i < MAX_FRAMES) : (i += 1) {
        const idx = (next_hint + i) % MAX_FRAMES;
        const w = idx / 64;
        const bit: u6 = @intCast(idx % 64);
        if (bitmap[w] & (@as(u64, 1) << bit) == 0) {
            bitmap[w] |= @as(u64, 1) << bit;
            next_hint = (idx + 1) % MAX_FRAMES;
            free_count -= 1;
            return idx * FRAME_SIZE;
        }
    }
    return null;
}

pub fn freeFrame(paddr: usize) void {
    const idx = frameIndexOf(paddr);
    const w = idx / 64;
    const bit: u6 = @intCast(idx % 64);
    if (bitmap[w] & (@as(u64, 1) << bit) == 0) {
        console.kprintf("pmm: double free at {x}\n", .{paddr});
        return;
    }
    bitmap[w] &= ~(@as(u64, 1) << bit);
    free_count += 1;
}

/// 保留一段物理地址范围（不可分配）
pub fn reserveRange(start: usize, end: usize) void {
    const s = start & ~(FRAME_SIZE - 1);
    var addr = s;
    while (addr < end) : (addr += FRAME_SIZE) {
        if (addr + FRAME_SIZE > MAX_PHYS) break;
        setBit(frameIndexOf(addr));
    }
}

pub fn freeFrames() usize {
    return free_count;
}

fn frameIndexOf(paddr: usize) usize {
    return paddr >> FRAME_SHIFT;
}

fn countFree() usize {
    var n: usize = 0;
    for (bitmap) |w| {
        n += @popCount(~w);
    }
    return n;
}

fn setBit(idx: usize) void {
    bitmap[idx / 64] |= @as(u64, 1) << @intCast(idx % 64);
}
fn clearBit(idx: usize) void {
    bitmap[idx / 64] &= ~(@as(u64, 1) << @intCast(idx % 64));
}

/// 自检：分配/写入/释放一帧
pub fn selfTest() bool {
    const p = allocFrame() orelse return false;
    const v = @import("vmm.zig").physToVirt(p);
    const page: *[4096]u8 = @ptrFromInt(v);
    page[0] = 0xA5;
    page[4095] = 0x5A;
    const ok = page[0] == 0xA5 and page[4095] == 0x5A;
    page[0] = 0;
    page[4095] = 0;
    freeFrame(p);
    return ok;
}
