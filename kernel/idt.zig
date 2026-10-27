//! IDT（中断描述符表）与中断/异常处理框架
//!
//! 教学要点（x86-64 中断的完整链路）：
//!   1. CPU 收到中断/异常 → 依据向量号查 IDT
//!   2. 若发生在用户态(CPL=3)：从 TSS.rsp0 取内核栈切换过去，
//!      并依次压入 SS、RSP、RFLAGS、CS、RIP
//!   3. 若该异常有错误码（#PF/#GP 等）再压入错误码
//!   4. 跳到我们的入口桩(stub)，统一压入"向量号(+补0错误码)"和全部
//!      通用寄存器，形成 TrapFrame，再调用 Zig 写的 trapDispatch
//!
//! 向量号约定：0-31 CPU 异常 | 32-47 8259 PIC 的 IRQ | 0x80 系统调用

const std = @import("std");
const gdt = @import("gdt.zig");
const console = @import("console.zig");

/// SSE 寄存器现场（XMM0-15 + MXCSR）。用 movups 保存/恢复而非 fxsave：
/// 免 16 字节对齐要求，也不需要 x87（Zig 的 f32/f64 全部走 SSE2 指令）。
pub const XMM_SAVE_BYTES = 264; // 16*16 + 4(MXCSR) + 4(pad)

/// 中断入口时完整的寄存器现场（教学重点：字段顺序 = 栈上的排列顺序）
pub const TrapFrame = extern struct {
    // ---- 由 trapCommon 入口桩压入（从低地址到高地址）----
    // SSE 现场放在最低处：入口先 sub 栈再保存，epilogue 加载后跳过它弹 GPR。
    // 为什么必须保存：处理程序本身会用 SSE（GUI 的 GL 光栅化、@memcpy 的
    // SIMD 内联），若不打断现场保存，用户态浮点代码会被中断处理践踏。
    xmm: [16]u128 = @splat(0),
    mxcsr: u32 = 0x1F80, // 默认值：全部浮点异常屏蔽
    pad0: u32 = 0,
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbp: u64,
    rbx: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rax: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    // ---- 由各向量入口桩压入 ----
    intno: u64, // 向量号
    errcode: u64, // CPU 错误码；无错误码的向量补 0，保证布局统一
    // ---- 由 CPU 压入 ----
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64, // 仅特权级变化时压入（本内核用户中断必然变特权级）
    ss: u64,
};

/// 是否从用户态陷入（CS 低 2 位 = CPL）
pub fn fromUser(frame: *const TrapFrame) bool {
    return (frame.cs & 3) == 3;
}

// ---------------- 门描述符 ----------------

const Gate = extern struct {
    offset_lo: u16,
    selector: u16,
    ist: u8, // Interrupt Stack Table 索引，0=不切换
    type_attr: u8, // P|DPL|0|type(0xE=中断门)
    offset_mid: u16,
    offset_hi: u32,
    zero: u32 = 0,
};

var idt: [256]Gate = undefined;

// ---------------- 入口桩生成 ----------------

const Stub = fn () callconv(.naked) noreturn;

/// 这些向量的异常 CPU 会自动压入错误码，入口桩不再补 0
const has_errcode = [_]u8{ 8, 10, 11, 12, 13, 14, 17, 21 };

/// 统一入口：保存通用寄存器 + SSE 现场 → 调用 trapDispatch → 恢复现场 → iretq
///
/// XMM 现场保存是"无条件"的：虽然只在用户态浮点代码被打断时才必要，
/// 但判断 CPL 需要先读栈上的 CS——不如直接保存，换来"显然正确"。
/// 代价是每次陷入多 ~270 字节访存（QEMU TCG 下完全无感）。
export fn trapCommon() callconv(.naked) noreturn {
    asm volatile (
        \\pushq %rdi
        \\pushq %rsi
        \\pushq %rdx
        \\pushq %rcx
        \\pushq %rax
        \\pushq %r8
        \\pushq %r9
        \\pushq %r10
        \\pushq %r11
        \\pushq %rbx
        \\pushq %rbp
        \\pushq %r12
        \\pushq %r13
        \\pushq %r14
        \\pushq %r15
        \\subq $264, %rsp          # TrapFrame 的 XMM 区块（movups 免对齐要求）
        \\movups %xmm0, 0(%rsp)
        \\movups %xmm1, 16(%rsp)
        \\movups %xmm2, 32(%rsp)
        \\movups %xmm3, 48(%rsp)
        \\movups %xmm4, 64(%rsp)
        \\movups %xmm5, 80(%rsp)
        \\movups %xmm6, 96(%rsp)
        \\movups %xmm7, 112(%rsp)
        \\movups %xmm8, 128(%rsp)
        \\movups %xmm9, 144(%rsp)
        \\movups %xmm10, 160(%rsp)
        \\movups %xmm11, 176(%rsp)
        \\movups %xmm12, 192(%rsp)
        \\movups %xmm13, 208(%rsp)
        \\movups %xmm14, 224(%rsp)
        \\movups %xmm15, 240(%rsp)
        \\stmxcsr 256(%rsp)
        \\movq %rsp, %rdi          # rdi = TrapFrame*（指向 xmm[0]）
        \\movq %rsp, %rbp          # 备份（rbp 是被调用者保存寄存器）
        \\andq $-16, %rsp          # 按 SysV ABI 对齐到 16 字节
        \\callq trapDispatch
        \\movq %rbp, %rsp
        \\movups 0(%rbp), %xmm0
        \\movups 16(%rbp), %xmm1
        \\movups 32(%rbp), %xmm2
        \\movups 48(%rbp), %xmm3
        \\movups 64(%rbp), %xmm4
        \\movups 80(%rbp), %xmm5
        \\movups 96(%rbp), %xmm6
        \\movups 112(%rbp), %xmm7
        \\movups 128(%rbp), %xmm8
        \\movups 144(%rbp), %xmm9
        \\movups 160(%rbp), %xmm10
        \\movups 176(%rbp), %xmm11
        \\movups 192(%rbp), %xmm12
        \\movups 208(%rbp), %xmm13
        \\movups 224(%rbp), %xmm14
        \\movups 240(%rbp), %xmm15
        \\ldmxcsr 256(%rbp)
        \\addq $264, %rsp          # 跳过 XMM 区块
        \\popq %r15
        \\popq %r14
        \\popq %r13
        \\popq %r12
        \\popq %rbp
        \\popq %rbx
        \\popq %r11
        \\popq %r10
        \\popq %r9
        \\popq %r8
        \\popq %rax
        \\popq %rcx
        \\popq %rdx
        \\popq %rsi
        \\popq %rdi
        \\addq $16, %rsp           # 跳过 intno + errcode
        \\iretq
    );
}

/// 为向量 v 生成入口桩：压入(错误码+)向量号后跳到 trapCommon
fn stubFor(comptime v: u8) *const Stub {
    const S = struct {
        fn entry() callconv(.naked) noreturn {
            comptime var with_err = false;
            comptime for (has_errcode) |e| {
                if (e == v) with_err = true;
            };
            const push = comptime if (with_err)
                ""
            else
                "pushq $0\n"; // 无错误码的向量补 0，统一栈布局
            asm volatile (push ++ "pushq $" ++ std.fmt.comptimePrint("{d}", .{v}) ++ "\n\tjmp trapCommon");
        }
    };
    return &S.entry;
}

const stub_table: [256]*const Stub = blk: {
    var t: [256]*const Stub = undefined;
    for (0..256) |i| t[i] = stubFor(@intCast(i));
    break :blk t;
};

pub fn init() void {
    for (0..256) |i| {
        const addr = @intFromPtr(stub_table[i]);
        // 系统调用门(0x80)必须 DPL=3 才能从用户态触发；其余 DPL=0
        const dpl: u8 = if (i == 0x80) 3 else 0;
        idt[i] = .{
            .offset_lo = @truncate(addr),
            .selector = gdt.SEL_KCODE,
            .ist = 0,
            .type_attr = 0x80 | (dpl << 5) | 0x0E, // P=1, 中断门
            .offset_mid = @truncate(addr >> 16),
            .offset_hi = @truncate(addr >> 32),
        };
    }

    var idtr: [10]u8 align(2) = undefined;
    gdt.loadPseudoDesc("lidt", &idtr, @sizeOf(@TypeOf(idt)) - 1, @intFromPtr(&idt));
}

// ---------------- 分发 ----------------

const pic = @import("pic.zig");
const pit = @import("pit.zig");
const keyboard = @import("keyboard.zig");
const serial = @import("serial.zig");
const tty = @import("tty.zig");

pub var dispatch_hook: ?*const fn (*TrapFrame) void = null; // 调度器挂载点（进程阶段接入）

/// 中断分发（关中断状态下进入；离开前通过 iretq 自动恢复 EFLAGS.IF）
export fn trapDispatch(frame: *TrapFrame) void {
    const v = frame.intno;

    if (v < 32) {
        // 页错误 + 用户态：先尝试按需扩栈（经典 demand paging 入门）
        if (frame.intno == 14 and fromUser(frame)) {
            const cr2 = asm volatile ("movq %%cr2, %[out]"
                : [out] "={rax}" (-> u64),
            );
            if (@import("proc.zig").growStackOnFault(cr2)) return; // iretq 重试
        }
        if (fromUser(frame)) {
            // 用户态致命错误：终止该进程，内核与其他进程继续运行
            const proc = @import("proc.zig");
            console.kprintf("\n[signal] pid {d} killed: vector {d} rip={x}\n", .{
                proc.current().?.pid, frame.intno, frame.rip,
            });
            proc.exit(139); // 128+11 = SIGSEGV 惯例值
        }
        exception(frame);
    } else if (v == 0x80) {
        const syscall_mod = @import("syscall.zig");
        syscall_mod.handle(frame); // 系统调用阶段实现
    } else if (v < 48) {
        const irq_no: u8 = @intCast(v - 32);
        switch (irq_no) {
            0 => {
                pit.onTick(); // IRQ0: 定时器
                // 串口输入采用 100Hz 轮询而非中断（QEMU 的 UART 中断在
                // 连续字节下有投递竞态；轮询对交互延迟无感知，键盘仍为中断驱动）
                while (serial.readByte()) |c| tty.onInput(c);
                // 网卡同理轮询：空闲时的包也由此路径进入协议栈
                @import("e1000.zig").poll();
                // GUI：秒级时钟刷新 + 重绘脏区（无脏区时是空操作）
                @import("gui.zig").onTick();
            },
            1 => keyboard.onInterrupt(), // IRQ1: 键盘
            12 => @import("mouse.zig").onInterrupt(), // IRQ12: PS/2 鼠标
            else => {},
        }
        pic.sendEoi(irq_no);
    } else {
        console.kprintf("\nunexpected vector {d}\n", .{v});
    }

    if (dispatch_hook) |hook| hook(frame); // 时机片到 → 调度器可能切换栈
}

/// CPU 异常（0-31）：教学内核直接打印现场并停机
fn exception(frame: *TrapFrame) void {
    const names = [_][]const u8{
        "#DE 除法错误",    "#DB 调试",       "#NMI",           "#BP 断点",
        "#OF 溢出",       "#BR 越界",       "#UD 无效指令",    "#NM 设备不可用",
        "#DF 双重故障",   "协处理器段",     "#TS 无效TSS",    "#NP 段不存在",
        "#SS 栈段错误",   "#GP 通用保护",   "#PF 页错误",     "保留",
        "#MF x87",        "#AC 对齐检查",   "#MC 机器检查",    "#XF SIMD",
    };

    var cr2: u64 = 0;
    var cr3: u64 = 0;
    if (frame.intno == 14) {
        cr2 = asm volatile ("movq %%cr2, %[out]"
            : [out] "={rax}" (-> u64),
        );
    }
    cr3 = asm volatile ("movq %%cr3, %[out]"
        : [out] "={rax}" (-> u64),
    );

    console.kprintf("\n!!! EXCEPTION: vector {d}", .{frame.intno});
    if (frame.intno < names.len) console.kprintf(" ({s})", .{names[@intCast(frame.intno)]});
    console.kprintf("\n", .{});
    console.kprintf("  RIP={x} CS={x} RFLAGS={x}\n", .{ frame.rip, frame.cs, frame.rflags });
    console.kprintf("  RSP={x} RBP={x} ERR={x}", .{ frame.rsp, frame.rbp, frame.errcode });
    if (frame.intno == 14) {
        console.kprintf(" CR2={x} ({s}{s}{s})", .{
            cr2,
            if (frame.errcode & 1 != 0) "present " else "not-present ",
            if (frame.errcode & 2 != 0) "write " else "read ",
            if (frame.errcode & 4 != 0) "user" else "kernel",
        });
    }
    console.kprintf("\n  RAX={x} RBX={x} RCX={x} RDX={x}\n", .{ frame.rax, frame.rbx, frame.rcx, frame.rdx });
    console.kprintf("  RSI={x} RDI={x} R8={x}  R9={x}\n", .{ frame.rsi, frame.rdi, frame.r8, frame.r9 });
    console.kprintf("  CR3={x} R10={x} R11={x} RBX={x}\n", .{ cr3, frame.r10, frame.r11, frame.rbx });

    if (fromUser(frame)) {
        console.kprintf("  (from user mode -- 本应终止该进程)\n", .{});
    }
    while (true) asm volatile ("hlt");
}
