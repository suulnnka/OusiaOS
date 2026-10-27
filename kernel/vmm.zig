//! 虚拟内存管理（VMM: 页表操作）
//!
//! 教学要点：
//!   - x86-64 四级页表：PML4 → PDPT → PD → PT，每级 512 项 × 9 位索引
//!   - 虚拟地址 48 位有效：低 256 项(128GB)给用户，高 256 项给内核
//!   - "直接映射区"：物理地址 X ↔ 虚拟地址 X+KERNEL_VIRT_BASE，
//!     内核借此用普通指针访问任意物理页（页表内容、进程内存拷贝）
//!   - fork = 克隆用户页表（深拷贝 4K 页）；execve = 销毁重建
//!
//! 权限位：P=1 存在  W=2 可写  U=4 用户可访问  A=0x20 已读  D=0x40 已写
//!         PS=0x80 大页（PD 级=2MB，PDPT 级=1GB）

const console = @import("console.zig");
const pmm = @import("pmm.zig");
const main = @import("main.zig");

const KERNEL_VIRT_BASE: usize = main.KERNEL_VIRT_BASE;

const Error = error{OutOfMemory};

pub const P: u64 = 1 << 0;
pub const W: u64 = 1 << 1;
pub const U: u64 = 1 << 2;
pub const A: u64 = 1 << 5;
pub const D: u64 = 1 << 6;
pub const PS: u64 = 1 << 7;

const ENTRIES = 512;

const Table = [ENTRIES]u64;

// ---------------- 直接映射换算 ----------------

pub inline fn physToVirt(paddr: usize) usize {
    return paddr + KERNEL_VIRT_BASE;
}

pub inline fn virtToPhys(vaddr: usize) usize {
    return vaddr - KERNEL_VIRT_BASE;
}

/// 物理地址 → 可直接访问的页表指针（借助直接映射区）
pub inline fn tableOf(paddr: usize) *Table {
    return @ptrFromInt(physToVirt(paddr));
}

// ---------------- 内核页表初始化 ----------------

/// 当前(内核)CR3 的物理地址
var kernel_pml4_phys: usize = 0;

pub fn kernelPml4() usize {
    return kernel_pml4_phys;
}

/// 建立内核正式页表：
///   1. 新 PML4，高位半区清零（放弃 boot.S 的临时映射，含恒等映射）
///   2. 直接映射全部物理内存（2MB 大页，supervisor 读写）
///   3. 切换 CR3
pub fn init() void {
    const pml4_frame = pmm.allocFrame() orelse @panic("vmm: 无内存建立页表");
    const pml4 = tableOf(pml4_frame);
    @memset(pml4, 0);

    // 直接映射 [0, MAX_PHYS) → [KERNEL_VIRT_BASE, KERNEL_VIRT_BASE+MAX_PHYS)
    const phys_max = pmm.MAX_PHYS;
    var offset: usize = 0;
    while (offset < phys_max) : (offset += 2 * 1024 * 1024) {
        const vaddr = KERNEL_VIRT_BASE + offset;
        const idx4: usize = (vaddr >> 39) & 511;
        const idx3: usize = (vaddr >> 30) & 511;
        const idx2: usize = (vaddr >> 21) & 511;

        // 按需建立 PDPT / PD
        if (pml4[idx4] & P == 0) {
            const f = pmm.allocFrame() orelse @panic("vmm: 无内存建立 PDPT");
            @memset(tableOf(f), 0);
            pml4[idx4] = f | P | W; // 内核区不需要 U
        }
        const pdpt = tableOf(pml4[idx4] & 0x000F_FFFF_FFFF_F000);
        if (pdpt[idx3] & P == 0) {
            const f = pmm.allocFrame() orelse @panic("vmm: 无内存建立 PD");
            @memset(tableOf(f), 0);
            pdpt[idx3] = f | P | W;
        }
        const pd = tableOf(pdpt[idx3] & 0x000F_FFFF_FFFF_F000);

        // 2MB 大页
        pd[idx2] = offset | P | W | PS | A | D;
    }

    kernel_pml4_phys = pml4_frame;
    switchTo(pml4_frame);
    // boot.S 的临时页表（位于保留的低 2MB 内）就此废弃
}

pub fn switchTo(pml4_phys: usize) void {
    asm volatile ("movq %[p], %%cr3"
        :
        : [p] "{rax}" (pml4_phys),
        : .{ .memory = true });
}

pub fn readCr3() usize {
    return asm volatile ("movq %%cr3, %[out]"
        : [out] "={rax}" (-> u64),
    );
}

// ---------------- 设备 MMIO 映射 ----------------
// 直接映射区只覆盖低 2GB 物理内存；PCI 设备的 MMIO BAR 通常在
// 0xF0000000 一带，需要专用映射区。初始化发生在进程诞生之前，
// 所有进程的内核半区都会带上这份映射。

const MMIO_BASE: usize = KERNEL_VIRT_BASE - 0x4000_0000; // 直接映射区顶到 2^64，借下方 1GB
var mmio_next: usize = MMIO_BASE;

pub fn mapMMIO(phys: u64, len: usize) usize {
    const start = phys & ~@as(u64, 0xFFF);
    const pages = (phys + len + 0xFFF - start) / 0x1000;
    var i: u64 = 0;
    while (i < pages) : (i += 1) {
        _ = mapPage(kernel_pml4_phys, mmio_next + @as(usize, @intCast(i * 0x1000)), @intCast(start + i * 0x1000), P | W);
    }
    const va = mmio_next + @as(usize, @intCast(phys - start));
    mmio_next += @as(usize, @intCast(pages * 0x1000)) + 0x1000;
    return va;
}

// ---------------- 通用映射接口（用户进程页表）----------------

const EntryIdx = struct {
    l4: usize,
    l3: usize,
    l2: usize,
    l1: usize,
};

fn indicesOf(vaddr: usize) EntryIdx {
    return .{
        .l4 = (vaddr >> 39) & 511,
        .l3 = (vaddr >> 30) & 511,
        .l2 = (vaddr >> 21) & 511,
        .l1 = (vaddr >> 12) & 511,
    };
}

/// 从指定 PML4（物理地址）取下一级表，不存在则分配。
/// 返回 null 表示物理内存耗尽。
fn ensureTable(table: *Table, idx: usize, flags: u64) ?*Table {
    const entry = table[idx];
    if (entry & P != 0) return tableOf(entry & 0x000F_FFFF_FFFF_F000);
    const f = pmm.allocFrame() orelse return null;
    @memset(tableOf(f), 0);
    table[idx] = f | flags;
    return tableOf(f);
}

/// 映射一个 4KB 页（按需建立中间级）
pub fn mapPage(pml4_phys: usize, vaddr: usize, paddr: usize, flags: u64) bool {
    const ix = indicesOf(vaddr);
    const pml4 = tableOf(pml4_phys);

    // 中间级带 USER 位：用户叶子页要能穿过各级（否则 #PF）
    const mid_flags = P | W | U;
    const pdpt = ensureTable(pml4, ix.l4, mid_flags) orelse return false;
    const pd = ensureTable(pdpt, ix.l3, mid_flags) orelse return false;
    const pt = ensureTable(pd, ix.l2, mid_flags) orelse return false;

    pt[ix.l1] = (paddr & 0x000F_FFFF_FFFF_F000) | flags;
    return true;
}

/// 解除映射（不释放物理页，也不释放中间级表——由 destroyUserSpace 统一处理）
pub fn unmapPage(pml4_phys: usize, vaddr: usize) void {
    const ix = indicesOf(vaddr);
    const pml4 = tableOf(pml4_phys);

    var t = pml4;
    inline for (.{ ix.l4, ix.l3, ix.l2 }) |i| {
        const e = t[i];
        if (e & P == 0) return;
        t = tableOf(e & 0x000F_FFFF_FFFF_F000);
    }
    t[ix.l1] = 0;
    invlpg(vaddr);
}

fn invlpg(vaddr: usize) void {
    asm volatile ("invlpg (%[v])"
        :
        : [v] "{rax}" (vaddr),
        : .{ .memory = true });
}

/// 查询 vaddr 是否已映射（走页表，遇到大页也算已映射）
pub fn isMapped(pml4_phys: usize, vaddr: usize) bool {
    var t = tableOf(pml4_phys);
    var e: u64 = 0;
    inline for (.{ (vaddr >> 39) & 511, (vaddr >> 30) & 511, (vaddr >> 21) & 511, (vaddr >> 12) & 511 }, 0..) |idx, level| {
        e = t[idx];
        if (e & P == 0) return false;
        if (level < 3 and e & PS != 0) return true; // 1GB/2MB 大页
        if (level < 3) t = tableOf(e & 0x000F_FFFF_FFFF_F000);
    }
    return true;
}

// ---------------- fork / execve 支持 ----------------

/// 深拷贝用户地址空间（低 256 个 PML4 项）。
/// 内核半区直接复制表项（所有进程共享内核页表）。
/// 返回新 PML4 物理地址；失败返回 0。
pub fn cloneUserSpace(src_pml4_phys: usize) usize {
    const new_frame = pmm.allocFrame() orelse return 0;
    const new_pml4 = tableOf(new_frame);
    const src_pml4 = tableOf(src_pml4_phys);
    @memset(new_pml4, 0);

    // 高半区：共享内核页表（直接复制指针）
    for (256..512) |i| new_pml4[i] = src_pml4[i];

    // 低半区（用户区）：逐页深拷贝
    cloneLevel(src_pml4, new_pml4, 0) catch {
        destroyUserSpace(new_frame);
        return 0;
    };
    return new_frame;
}

/// 递归拷贝某一级表（level: 0=PML4 1=PDPT 2=PD 3=PT）
/// 注意：level 0 只遍历低 256 项——高半区是内核共享页表，禁止深拷贝
fn cloneLevel(src: *Table, dst: *Table, comptime level: usize) Error!void {
    for (0..if (level == 0) 256 else ENTRIES) |i| {
        const e = src[i];
        if (e & P == 0) continue;

        if (level == 3) {
            // 叶子：分配新物理页并拷贝内容
            const f = pmm.allocFrame() orelse return error.OutOfMemory;
            const src_page: *const [4096]u8 = @ptrFromInt(physToVirt(e & 0x000F_FFFF_FFFF_F000));
            const dst_page: *[4096]u8 = @ptrFromInt(physToVirt(f));
            @memcpy(dst_page, src_page);
            dst[i] = f | (e & 0xFFF); // 保留权限位
        } else {
            const f = pmm.allocFrame() orelse return error.OutOfMemory;
            @memset(tableOf(f), 0);
            dst[i] = f | P | W | U;
            try cloneLevel(tableOf(e & 0x000F_FFFF_FFFF_F000), tableOf(f), level + 1);
        }
    }
}

/// 销毁用户地址空间：释放低半区（用户区）全部页表+数据页。
/// 高半区是内核共享页表，绝对不能释放！
pub fn destroyUserSpace(pml4_phys: usize) void {
    const pml4 = tableOf(pml4_phys);
    freeLevel(pml4, 0);
    pmm.freeFrame(pml4_phys);
}

fn freeLevel(table: *Table, comptime level: usize) void {
    for (0..if (level == 0) 256 else ENTRIES) |i| {
        const e = table[i];
        if (e & P == 0) continue;
        const frame = e & 0x000F_FFFF_FFFF_F000;
        if (level < 3) {
            freeLevel(tableOf(frame), level + 1);
        }
        pmm.freeFrame(frame);
        table[i] = 0;
    }
}

/// 返回一个仅含内核映射的新页表（execve 用）
pub fn newKernelSharedPml4() usize {
    const f = pmm.allocFrame() orelse return 0;
    const pml4 = tableOf(f);
    @memset(pml4, 0);
    const kern = tableOf(kernel_pml4_phys);
    for (256..512) |i| pml4[i] = kern[i];
    return f;
}
