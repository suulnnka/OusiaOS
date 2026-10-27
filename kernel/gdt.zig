//! GDT（全局描述符表）与 TSS（任务状态段）
//!
//! 教学要点：
//!   - x86-64 下的分段已名存实亡，但"特权级"仍由段选择子的 DPL 体现：
//!       内核态 CPL=0，用户态 CPL=3
//!   - TSS 不再用于硬件任务切换，它的唯一关键作用是 rsp0：
//!     用户态→内核态转移（中断/系统调用）时 CPU 自动加载的内核栈顶
//!
//! 段选择子布局：
//!   0x08 内核代码 | 0x10 内核数据 | 0x18 用户代码 | 0x20 用户数据 | 0x28 TSS

/// 64 位 TSS（Task State Segment）
/// 注意布局：RSP0 位于字节偏移 4（而非 8）！
/// 因此 u64 字段必须 align(4)，否则 extern struct 会按 8 对齐
/// 把 RSP0 挪到偏移 8，特权级切换时 CPU 读到错位的栈指针。
pub const Tss = extern struct {
    reserved0: u32 = 0,
    /// 特权级 0/1/2 对应的内核栈；本内核只用 rsp0
    rsp0: u64 align(4) = 0,
    rsp1: u64 align(4) = 0,
    rsp2: u64 align(4) = 0,
    reserved1: u64 align(4) = 0,
    ist: [7]u64 align(4) = .{ 0, 0, 0, 0, 0, 0, 0 },
    reserved2: u32 = 0,
    reserved3: u16 = 0,
    /// I/O 位图偏移：= 表长表示"没有位图"，用户态所有端口访问都触发 #GP
    iopb_offset: u16 = @sizeOf(Tss),
};

comptime {
    if (@offsetOf(Tss, "rsp0") != 4) @compileError("TSS 布局错误：rsp0 必须在偏移 4");
}

var tss: Tss = .{};

const Gdt = extern struct {
    null: u64 = 0,
    kernel_code: u64 = 0x00AF9A000000FFFF, // L=1, D=0, P=1, DPL=0, S=1, 可执行
    kernel_data: u64 = 0x00CF92000000FFFF, // 数据段，DPL=0
    user_code: u64 = 0x00AFFA000000FFFF, // L=1, P=1, DPL=3, 可执行
    user_data: u64 = 0x00CFF2000000FFFF, // 数据段，DPL=3
    tss_lo: u64 = 0, // TSS 描述符低 8 字节（运行时填充）
    tss_hi: u64 = 0, // TSS 描述符高 8 字节
};

var gdt: Gdt = .{};

// 注意：LGDT/LIDT 的"伪描述符"是【紧凑的 10 字节】：
//   [0..2) = u16 limit,  [2..10) = u64 base（未对齐！）
// extern struct 会给 u64 插入对齐填充，无论 padding 放前放后都会读错，
// 只能用字节数组手工填充。
pub fn loadPseudoDesc(comptime instr: []const u8, rec: *[10]u8, limit: u16, base: u64) void {
    rec[0] = @truncate(limit);
    rec[1] = @truncate(limit >> 8);
    inline for (0..8) |i| {
        rec[2 + i] = @truncate(base >> @intCast(8 * i));
    }
    const p: usize = @intFromPtr(rec);
    asm volatile (instr ++ " (%[p])"
        :
        : [p] "{rax}" (p),
    );
}

/// 选择子常量（与 GDT 布局对应）
pub const SEL_KCODE: u16 = 0x08;
pub const SEL_KDATA: u16 = 0x10;
pub const SEL_UCODE: u16 = 0x18 | 3; // 用户段选择子带 RPL=3
pub const SEL_UDATA: u16 = 0x20 | 3;

pub fn init() void {
    // 填充 TSS 描述符（类型 0x9 = 64 位可用 TSS）
    const base: u64 = @intFromPtr(&tss);
    const limit: u32 = @sizeOf(Tss) - 1;
    gdt.tss_lo = @as(u64, limit & 0xFFFF) |
        ((base & 0xFFFFFF) << 16) |
        (@as(u64, 0x89) << 40) | // P=1, DPL=0, S=0, type=1001
        (@as(u64, (limit >> 16) & 0xF) << 48) |
        ((base >> 24) & 0xFF) << 56;
    gdt.tss_hi = base >> 32;

    var gdtr: [10]u8 align(2) = undefined;
    loadPseudoDesc("lgdt", &gdtr, @sizeOf(Gdt) - 1, @intFromPtr(&gdt));

    reloadSegments();

    // 载入 TSS
    asm volatile ("ltr %[sel]"
        :
        : [sel] "{ax}" (@as(u16, 0x28)),
    );
}

/// 重载段寄存器；CS 不能直接 MOV，通过远返回(lret)切换
fn reloadSegments() void {
    asm volatile (
        \\movl %[ds], %eax
        \\movw %ax, %ds
        \\movw %ax, %es
        \\movw %ax, %ss
        \\movw %ax, %fs
        \\movw %ax, %gs
        \\movl %[cs], %ecx
        \\pushq %rcx
        \\leaq 1f(%rip), %rax
        \\pushq %rax
        \\lretq
        \\1:
        :
        : [ds] "r" (@as(u32, SEL_KDATA)),
          [cs] "r" (@as(u32, SEL_KCODE)),
        : .{ .rax = true, .rcx = true, .memory = true });
}

/// 设置用户态→内核态切换时使用的内核栈顶（每次进程切换时更新）
pub fn setKernelStack(rsp0: usize) void {
    tss.rsp0 = rsp0;
}

pub fn kernelStack() usize {
    return tss.rsp0;
}
