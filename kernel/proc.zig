//! 进程管理与调度（PCB / 上下文切换 / fork / execve / wait / exit）
//!
//! 教学要点：
//!   - 进程 = 地址空间(页表) + 内核栈 + trapframe + 状态
//!   - 上下文切换 swtch 只保存 RSP：callee-saved 寄存器压在栈上，
//!     换栈即换进程，"栈就是进程的魂"
//!   - 用户态进入：iretq 弹出 TrapFrame（RIP/CS/RFLAGS/RSP/SS）
//!   - 首次运行：内核栈顶放 forkret 返回地址，swtch 的 ret 弹出它
//!   - 调度：时间片轮转（QUANTUM 个 tick），时钟中断里抢占
//!
//! 各协作方：
//!   idt.trapDispatch → trapHook（记录 tf、按时间片抢占）
//!   pit.onTick      → onTick（唤醒睡眠进程）
//!   syscall         → fork/exec/sleep/exit/wait4

const std = @import("std");
const console = @import("console.zig");
const gdt = @import("gdt.zig");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const pit = @import("pit.zig");
const idt = @import("idt.zig");
const vfs = @import("vfs.zig");
const tarfs = @import("tarfs.zig");
const elf = @import("elf.zig");

const TrapFrame = idt.TrapFrame;

pub const QUANTUM = 2; // 时间片 = 2 tick (20ms)
pub const MAX_PROCS = 24; // 多实例 GUI 应用 + shell 需要的容量
pub const KSTACK_PAGES = 4; // 每进程内核栈 16KB

/// 用户栈：16 页放在用户空间最高端
pub const USER_STACK_TOP: usize = 0x0000_7FFF_FFFF_F000;
pub const USER_STACK_PAGES = 32; // 初始 128KB
pub const USER_STACK_LIMIT: usize = 8 * 1024 * 1024; // 自动增长上限 8MB

/// 用户栈缺页时按需扩栈（在 #PF 处理中调用）。
/// 命中范围 [栈顶-上限, 栈顶) 且该页未映射 → 补一页，返回 true 重试指令。
pub fn growStackOnFault(cr2: usize) bool {
    const p = current() orelse return false;
    if (cr2 >= USER_STACK_TOP or cr2 < USER_STACK_TOP - USER_STACK_LIMIT) return false;
    const va = cr2 & ~@as(usize, 0xFFF);
    if (vmm.isMapped(p.page_map, va)) return false;
    const frame = pmm.allocFrame() orelse return false;
    @memset(@as([*]u8, @ptrFromInt(vmm.physToVirt(frame)))[0..4096], 0);
    if (!vmm.mapPage(p.page_map, va, frame, vmm.P | vmm.W | vmm.U)) {
        pmm.freeFrame(frame);
        return false;
    }
    return true;
}

extern const kernel_stack_top: u8; // 链接脚本：主内核栈（idle 用）

pub const State = enum {
    unused,
    runnable, // 就绪
    running, // 在 CPU 上
    sleeping, // 等待定时器唤醒
    blocked, // 等待事件（GUI 窗口事件）+ 可选超时
    waiting, // wait4 中
    zombie, // 已退出，等待父进程收尸
    dying, // 已退出且是孤儿：栈还在用（swtch 未离开），调度器收割后回 unused
};

/// 上下文切换现场：保存 RSP（其余 callee-saved 压在各自栈上），
/// 外加一份 SSE 现场（XMM0-15+MXCSR）——布局与 TrapFrame 的 XMM 区块
/// 相同，由 swtchImpl 内联保存/恢复。每个执行上下文（进程/调度器）一份。
pub const Context = extern struct {
    rsp: usize = 0,
    fpu: [66]u32 = default_fpu,
};

/// SSE 现场默认值：寄存器清零，MXCSR=0x1F80（全部异常屏蔽）。
pub const default_fpu: [66]u32 = blk: {
    var a: [66]u32 = @splat(0);
    a[64] = 0x1F80; // 264 字节布局中的 MXCSR 槽（16*16 字节之后）
    break :blk a;
};

pub const OpenFile = struct {
    used: bool = false,
    node: usize = 0, // vfs 节点号
    pos: u64 = 0, // 读写位置
};

pub const MAX_FD = 16;

pub const Proc = struct {
    state: State = .unused,
    pid: u32 = 0,
    ppid: u32 = 0,
    exit_code: i32 = 0,
    quantum: u32 = 0,
    wake_tick: u64 = 0, // sleeping：绝对唤醒拍；blocked=0 表示无超时

    // ---- 凭证（Linux 风格；fork 继承，setuid 可改）----
    uid: u32 = 0,
    gid: u32 = 0,

    name: [16]u8 = std.mem.zeroes([16]u8),

    page_map: usize = 0, // 用户 PML4 物理地址

    kstack_frames: [KSTACK_PAGES]usize = std.mem.zeroes([KSTACK_PAGES]usize),
    kstack_top: usize = 0, // 内核栈顶（虚拟）

    ctx: Context = .{}, // swtch 现场
    tf: *TrapFrame = undefined, // 最近一次陷入的帧（fork 用）

    brk: usize = 0, // 程序断点
    mmap_next: usize = 0x0000_5000_0000_0000, // mmap 分配游标

    fds: [MAX_FD]OpenFile = std.mem.zeroes([MAX_FD]OpenFile),
    cwd_buf: [256]u8 = std.mem.zeroes([256]u8),
    cwd_len: usize = 1,

    pub fn cwd(self: *const Proc) []const u8 {
        return self.cwd_buf[0..self.cwd_len];
    }
};

var procs: [MAX_PROCS]Proc = undefined;

/// 供 psinfo 系统调用只读访问
pub fn procsExported() []const Proc {
    return &procs;
}
var current_idx: ?usize = null;
var sched_ctx: Context = .{}; // 调度器上下文
var next_pid: u32 = 1;

pub fn current() ?*Proc {
    if (current_idx) |i| return &procs[i];
    return null;
}

pub fn init() void {
    for (&procs) |*p| p.* = .{};

    pit.tick_hook = &onTick;
    idt.dispatch_hook = &trapHook;
    gdt.setKernelStack(@intFromPtr(&kernel_stack_top));
    // tty.read 在调度器就绪后改用 yield 等待
    @import("tty.zig").setSchedulerReady();
}

// ================= 上下文切换 =================

/// swtch(old, new)：保存 old->rsp，加载 new->rsp 并恢复寄存器。
/// 控制流：切换后从"新上下文"上次保存的返回地址继续；
/// 旧栈帧原封不动留在旧栈上，等下次切回时恢复。
fn swtch(old: *Context, new: *Context) void {
    asm volatile (
        \\movq %[o], %%rdi
        \\movq %[n], %%rsi
        \\callq swtchImpl
        :
        : [o] "r" (old),
          [n] "r" (new),
        : .{ .rdi = true, .rsi = true, .rbp = true, .rbx = true,
            .r12 = true, .r13 = true, .r14 = true, .r15 = true,
            .memory = true });
}

/// 真正的切换体。必须是 naked 函数：若放在普通函数里，编译器序言
/// (push/sub) 会垫在保存的 RSP 与返回地址之间，恢复路径的 ret 就会
/// 读到序言的局部区而不是返回地址——这是本内核踩过的真实坑。
///
/// rdi/rsi 指向 Context{rsp, fpu[264B]}。FPU 现场与栈一起切换：
/// 进入时把当前 XMM 存进 old->fpu、从 new->fpu 恢复；被切走后再次
/// 调度回来时，XMM 已由唤醒方（另一次 swtch）恢复，这里只需弹栈。
export fn swtchImpl() callconv(.naked) void {
    asm volatile (
        \\pushq %rbp
        \\pushq %rbx
        \\pushq %r12
        \\pushq %r13
        \\pushq %r14
        \\pushq %r15
        \\movups %xmm0, 8(%rdi)      # 保存 old->fpu（偏移 8 = rsp 字段之后）
        \\movups %xmm1, 24(%rdi)
        \\movups %xmm2, 40(%rdi)
        \\movups %xmm3, 56(%rdi)
        \\movups %xmm4, 72(%rdi)
        \\movups %xmm5, 88(%rdi)
        \\movups %xmm6, 104(%rdi)
        \\movups %xmm7, 120(%rdi)
        \\movups %xmm8, 136(%rdi)
        \\movups %xmm9, 152(%rdi)
        \\movups %xmm10, 168(%rdi)
        \\movups %xmm11, 184(%rdi)
        \\movups %xmm12, 200(%rdi)
        \\movups %xmm13, 216(%rdi)
        \\movups %xmm14, 232(%rdi)
        \\movups %xmm15, 248(%rdi)
        \\stmxcsr 264(%rdi)
        \\movups 8(%rsi), %xmm0      # 恢复 new->fpu
        \\movups 24(%rsi), %xmm1
        \\movups 40(%rsi), %xmm2
        \\movups 56(%rsi), %xmm3
        \\movups 72(%rsi), %xmm4
        \\movups 88(%rsi), %xmm5
        \\movups 104(%rsi), %xmm6
        \\movups 120(%rsi), %xmm7
        \\movups 136(%rsi), %xmm8
        \\movups 152(%rsi), %xmm9
        \\movups 168(%rsi), %xmm10
        \\movups 184(%rsi), %xmm11
        \\movups 200(%rsi), %xmm12
        \\movups 216(%rsi), %xmm13
        \\movups 232(%rsi), %xmm14
        \\movups 248(%rsi), %xmm15
        \\ldmxcsr 264(%rsi)
        \\movq %rsp, (%rdi)      # old->rsp = 当前栈
        \\movq (%rsi), %rsp      # rsp = new->rsp
        \\popq %r15
        \\popq %r14
        \\popq %r13
        \\popq %r12
        \\popq %rbx
        \\popq %rbp
        \\ret                    # 弹出新上下文保存的返回地址
    );
}

/// 从 TrapFrame 返回用户态。不返回。
pub fn userReturn(tf: usize) noreturn {
    asm volatile (
        \\movq %[f], %rsp         # 栈指向 trapframe（XMM 区块在最低处）
        \\movups 0(%rsp), %xmm0
        \\movups 16(%rsp), %xmm1
        \\movups 32(%rsp), %xmm2
        \\movups 48(%rsp), %xmm3
        \\movups 64(%rsp), %xmm4
        \\movups 80(%rsp), %xmm5
        \\movups 96(%rsp), %xmm6
        \\movups 112(%rsp), %xmm7
        \\movups 128(%rsp), %xmm8
        \\movups 144(%rsp), %xmm9
        \\movups 160(%rsp), %xmm10
        \\movups 176(%rsp), %xmm11
        \\movups 192(%rsp), %xmm12
        \\movups 208(%rsp), %xmm13
        \\movups 224(%rsp), %xmm14
        \\movups 240(%rsp), %xmm15
        \\ldmxcsr 256(%rsp)
        \\addq $264, %rsp
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
        \\addq $16, %rsp         # 跳过 intno + errcode
        \\iretq                  # 弹出 rip/cs/rflags/rsp/ss → 用户态
        :
        : [f] "{rdi}" (tf),
        : .{ .memory = true });
    unreachable;
}

/// 新进程的第一次执行入口（swtch 的 ret 弹到这里）。
/// 此时 rsp 正好指向内核栈顶的 TrapFrame——直接恢复现场进入用户态。
/// （不经过普通函数调用，避免 SysV 栈对齐问题）
fn firstEntry() callconv(.naked) noreturn {
    asm volatile (
        \\movups 0(%rsp), %xmm0
        \\movups 16(%rsp), %xmm1
        \\movups 32(%rsp), %xmm2
        \\movups 48(%rsp), %xmm3
        \\movups 64(%rsp), %xmm4
        \\movups 80(%rsp), %xmm5
        \\movups 96(%rsp), %xmm6
        \\movups 112(%rsp), %xmm7
        \\movups 128(%rsp), %xmm8
        \\movups 144(%rsp), %xmm9
        \\movups 160(%rsp), %xmm10
        \\movups 176(%rsp), %xmm11
        \\movups 192(%rsp), %xmm12
        \\movups 208(%rsp), %xmm13
        \\movups 224(%rsp), %xmm14
        \\movups 240(%rsp), %xmm15
        \\ldmxcsr 256(%rsp)
        \\addq $264, %rsp
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
        \\addq $16, %rsp
        \\iretq
    );
}

// ================= 调度器 =================

/// 主调度循环（在 idle 内核栈上运行，永不返回）
///
/// 中断纪律（教学重点）：
///   - 扫描/idle 阶段开中断——时钟必须能打断，否则永远无法抢占；
///     swtch 可能从关中断的陷入上下文切入，所以循环顶部要 sti
///   - 切换临界区关中断——若在换栈/换页表途中被切走会破坏现场
pub fn scheduler() noreturn {
    while (true) {
        asm volatile ("sti");

        // 收割已退出的孤儿（GUI 应用）：此刻 CR3 已是内核表、
        // swtch 已离开它的内核栈，释放页表/内核栈是安全的
        if (reap_me) |rp| {
            reap_me = null;
            freeKStack(rp);
            vmm.destroyUserSpace(rp.page_map);
            rp.page_map = 0;
            rp.state = .unused;
        }

        var found = false;
        for (&procs, 0..) |*p, i| {
            if (p.state != .runnable) continue;
            found = true;

            asm volatile ("cli"); // ---- 切换临界区 ----
            current_idx = i;
            p.state = .running;
            p.quantum = 0;
            gdt.setKernelStack(p.kstack_top);
            vmm.switchTo(p.page_map);
            swtch(&sched_ctx, &p.ctx);
            // —— 回到这里时 p 已让出 CPU（IF=0，可能来自陷入上下文）——

            vmm.switchTo(vmm.kernelPml4());
            gdt.setKernelStack(@intFromPtr(&kernel_stack_top));
            current_idx = null;
            // 循环顶部的 sti 会重新开中断
        }
        if (!found) {
            // 无事可做：开中断并休眠，等下一个时钟/输入事件
            asm volatile ("sti");
            asm volatile ("hlt");
        }
    }
}

/// 时钟 tick（PIT 回调，关中断上下文）
pub fn onTick() void {
    for (&procs) |*p| {
        if (p.state == .sleeping and pit.ticks >= p.wake_tick) {
            p.state = .runnable;
        }
        // blocked 带超时：到点唤醒（win_wait 的定时闪烁等用途）
        if (p.state == .blocked and p.wake_tick != 0 and pit.ticks >= p.wake_tick) {
            p.state = .runnable;
        }
    }
}

/// 从 IRQ 上下文唤醒一个 blocked 进程（事件到达时调用）
pub fn wake(pid: u32) void {
    for (&procs) |*p| {
        if (p.pid == pid and p.state == .blocked) p.state = .runnable;
    }
}

/// 按名字找进程（GUI 菜单避免重复启动同一应用）
pub fn findByName(name: []const u8) ?*Proc {
    for (&procs) |*p| {
        if (p.state == .unused or p.state == .zombie) continue;
        const n = std_strlen(&p.name);
        if (std.mem.eql(u8, p.name[0..n], name)) return p;
    }
    return null;
}

/// 按 pid 找进程（winsys 释放表面时找属主页表用；dying 也算——
/// 它的地址空间此刻还在）
pub fn findByPid(pid: u32) ?*Proc {
    for (&procs) |*p| {
        if (p.state != .unused and p.pid == pid) return p;
    }
    return null;
}

/// 陷入分发钩子（idt.trapDispatch 每次陷入后调用）
pub fn trapHook(frame: *TrapFrame) void {
    const p = current() orelse return; // idle 上的中断不抢占
    p.tf = frame; // fork/exec 需要最新现场

    if (p.state != .running) {
        // sleep()/exit() 已经把状态改掉并主动 swtch 走了，
        // 走到这里说明是被动了（如 wait 中被信号打断的路径）——直接切走
        swtch(&p.ctx, &sched_ctx);
        return;
    }
    p.quantum += 1;
    if (p.quantum >= QUANTUM) {
        p.quantum = 0;
        yieldCpu();
    }
}

/// 主动让出 CPU（仍保持就绪）
pub fn yieldCpu() void {
    const p = current() orelse return;
    if (p.state == .running) p.state = .runnable;
    swtch(&p.ctx, &sched_ctx);
}

/// 让出 CPU 且保持 blocked（winsys.sysWait 用；唤醒靠 wake/超时）
pub fn switchAway() void {
    const p = current() orelse return;
    swtch(&p.ctx, &sched_ctx);
}

/// 睡眠 ms 毫秒
pub fn sleepMs(ms: u64) void {
    const p = current() orelse {
        // 调度器启动前的内核路径：忙等
        const t = pit.ticks;
        while (pit.ticks - t < ms / 10 + @intFromBool(ms % 10 != 0)) asm volatile ("hlt");
        return;
    };
    p.state = .sleeping;
    p.wake_tick = pit.ticks + ms / 10 + @intFromBool(ms % 10 != 0);
    swtch(&p.ctx, &sched_ctx);
}

// ================= 进程创建/销毁 =================

fn allocPid() u32 {
    const pid = next_pid;
    next_pid += 1;
    return pid;
}

fn allocProcSlot() ?usize {
    for (&procs, 0..) |*p, i| {
        if (p.state == .unused) return i;
    }
    return null;
}

/// 分配进程内核栈（4 页物理连续帧，用直接映射区拼成虚拟连续）
/// 连续性由 pmm.allocContigFrames 保证（逐帧分配会在保留区边界
/// 跨界硬拼——详见其注释），这里无需再校验。
fn allocKStack(p: *Proc) bool {
    p.kstack_top = 0;
    const base = pmm.allocContigFrames(KSTACK_PAGES) orelse return false;
    for (0..KSTACK_PAGES) |i| p.kstack_frames[i] = base + i * 4096;
    p.kstack_top = vmm.physToVirt(p.kstack_frames[KSTACK_PAGES - 1]) + 4096;
    return true;
}

fn freeKStack(p: *Proc) void {
    for (0..KSTACK_PAGES) |i| {
        if (p.kstack_frames[i] != 0) {
            pmm.freeFrame(p.kstack_frames[i]);
            p.kstack_frames[i] = 0;
        }
    }
    p.kstack_top = 0;
}

/// 把进程终点设置为"从 tf 进入用户态"：
/// 内核栈顶放 TrapFrame，其下放 forkret 返回地址。
fn setupFirstEntry(p: *Proc, entry: usize, sp: usize) void {
    const tf_addr = p.kstack_top - @sizeOf(TrapFrame);
    const tf: *TrapFrame = @ptrFromInt(tf_addr);

    tf.* = std.mem.zeroes(TrapFrame);
    tf.mxcsr = 0x1F80; // SSE 默认：全部浮点异常屏蔽（清零值会开异常）
    tf.rip = entry;
    tf.cs = gdt.SEL_UCODE;
    tf.rflags = 0x202; // IF=1，开中断进用户态
    tf.rsp = sp;
    tf.ss = gdt.SEL_UDATA;

    // swtch 恢复序列：pop r15,r14,r13,r12,rbx,rbx,rbp 后 ret
    // → 新栈需 [6 个寄存器槽][forkret 返回地址] 共 7 个 qword
    const frame: *[7]usize = @ptrFromInt(tf_addr - 7 * 8);
    @memset(frame, 0);
    frame[6] = @intFromPtr(&firstEntry);

    p.tf = tf;
    p.ctx.rsp = tf_addr - 7 * 8;
}

// ================= fork / execve / exit / wait =================

/// fork：克隆当前进程。返回子进程 pid；失败返回 null。
pub fn fork() ?*Proc {
    const parent = current() orelse return null;
    const slot = allocProcSlot() orelse return null;
    const child = &procs[slot];
    child.* = .{}; // 清零
    child.pid = allocPid();
    child.ppid = parent.pid;
    child.state = .runnable;

    if (!allocKStack(child)) {
        child.state = .unused;
        return null;
    }
    child.page_map = vmm.cloneUserSpace(parent.page_map);
    if (child.page_map == 0) {
        freeKStack(child);
        child.state = .unused;
        return null;
    }

    // 拷贝 trapframe（子进程从 fork 调用点"返回"），rax=0
    const ctf_addr = child.kstack_top - @sizeOf(TrapFrame);
    const ctf: *TrapFrame = @ptrFromInt(ctf_addr);
    ctf.* = parent.tf.*;
    ctf.rax = 0; // 子进程 fork() 返回 0
    child.tf = ctf;

    const frame: *[7]usize = @ptrFromInt(ctf_addr - 7 * 8);
    @memset(frame, 0);
    frame[6] = @intFromPtr(&firstEntry);
    child.ctx.rsp = ctf_addr - 7 * 8;

    // 继承：fd 表、cwd、brk、名字、凭证
    child.fds = parent.fds;
    child.cwd_buf = parent.cwd_buf;
    child.cwd_len = parent.cwd_len;
    child.brk = parent.brk;
    child.mmap_next = parent.mmap_next;
    child.uid = parent.uid;
    child.gid = parent.gid;
    setName(child, parent.name[0..std_strlen(&parent.name)]);

    return child;
}

fn setName(p: *Proc, s: []const u8) void {
    const n = @min(s.len, p.name.len - 1);
    @memcpy(p.name[0..n], s[0..n]);
    p.name[n] = 0;
}

fn std_strlen(buf: []const u8) usize {
    var i: usize = 0;
    while (i < buf.len and buf[i] != 0) i += 1;
    return i;
}

pub const ExecError = error{ NoEnt, Access, BadExe, NoMem };

/// ext2 ELF 的暂存缓冲：块设备文件没有 tarfs 那样的现成内存切片可
/// 借用，exec 时整文件读进来。0.3 起 /bin 全在盘上，ReleaseSafe 用户
/// 程序 2-4MB（.data 段占大头），缓冲给 8MB。教学简化：同一时刻只有
/// 一次 exec 在跑（execve 全程不让出 CPU）。
/// 注意：内核栈只有 16KB，大缓冲绝不能放栈上。
var exec_disk_buf: [8 * 1024 * 1024]u8 = undefined;

/// exec 的 ELF 数据来源：tarfs 直接指进 initrd 内存（零拷贝，兜底
/// 模式）；ext2 走块设备整文件读入暂存缓冲（根文件系统模式）。
/// 超出缓冲/读取失败返回 null（调用方报 BadExe）。
fn readExecImage(node: usize) ?[]const u8 {
    if (vfs.isExt2(node)) {
        const inf = vfs.info(node);
        if (inf.size > exec_disk_buf.len) return null; // 先查大小，绝不截断
        const n = vfs.read(node, 0, &exec_disk_buf);
        if (n <= 0) return null;
        return exec_disk_buf[0..@intCast(n)];
    }
    const file_node = tarfs.getNode(node - 2);
    return file_node.data;
}

/// execve：用 path 的 ELF 镜像替换当前进程地址空间。
/// argv 为参数列表。成功后不再返回（从新程序入口进入用户态）；
/// 失败返回错误（原镜像保持可用）。执行前检查 x 权限位（含路径遍历）。
pub fn execve(path: []const u8, argv: []const []const u8) ExecError!void {
    const p = current() orelse return error.BadExe;

    const node = vfs.resolveCred(path, p.cwd(), p.uid, p.gid) catch |e| switch (e) {
        error.Access => return error.Access,
        error.NoEnt => return error.NoEnt,
    };
    const inf = vfs.info(node);
    if (inf.is_dir or inf.is_console) return error.BadExe;
    // exec 权限：x 位（root 旁路）
    if (!vfs.mayAccess(inf, p.uid, p.gid, .x)) return error.Access;

    // 两个文件系统经 vfs 统一，此处只是取数差异
    const data = readExecImage(node) orelse return error.BadExe;

    // 1. 新地址空间 + 加载 ELF（后续任何失败都要销毁它——旧空间
    //    在失败路径上必须保持可用，泄漏检查是 execve 的经典练习）
    const new_map = vmm.newKernelSharedPml4();
    if (new_map == 0) return error.NoMem;
    errdefer vmm.destroyUserSpace(new_map);
    const img = elf.load(new_map, data) orelse {
        return error.BadExe;
    };

    // 2. 用户栈 + argv
    var sp = USER_STACK_TOP;
    var str_area: [2048]u8 = undefined;
    var str_len: usize = 0;
    var argc: usize = 0;

    for (argv) |a| {
        if (argc >= 32 or str_len + a.len + 1 > str_area.len) break;
        @memcpy(str_area[str_len .. str_len + a.len], a);
        str_len += a.len;
        str_area[str_len] = 0;
        str_len += 1;
        argc += 1;
    }

    // 栈页
    var si: usize = 0;
    while (si < USER_STACK_PAGES) : (si += 1) {
        const va = USER_STACK_TOP - (si + 1) * 4096;
        const frame = pmm.allocFrame() orelse return error.NoMem; // errdefer 兜底清理 new_map
        @memset(@as([*]u8, @ptrFromInt(vmm.physToVirt(frame)))[0..4096], 0);
        if (!vmm.mapPage(new_map, va, frame, vmm.P | vmm.W | vmm.U)) return error.NoMem;
    }

    // 自栈顶向下：字符串区 → 对齐 → argv 数组 → argc
    sp -= (str_len + 15) & ~@as(usize, 15);
    const str_base = sp;
    // 把字符串写进用户栈（新地址空间，需经物理页写入）
    writeUser(new_map, sp, str_area[0..str_len]);
    sp -= (argc + 2) * 8; // argv 指针 + NULL... 再加 argc 本身
    sp &= ~@as(usize, 15); // 16 字节对齐

    // argc 槽
    writeUser(new_map, sp, &std_as_usize_bytes(argc));
    var ai: usize = 0;
    while (ai < argc) : (ai += 1) {
        // 计算第 i 个字符串在用户栈上的地址
        var off: usize = 0;
        var k: usize = 0;
        while (k < ai) : (k += 1) {
            off += argv[k].len + 1;
        }
        const slot = sp + 8 + ai * 8;
        writeUser(new_map, slot, &std_as_usize_bytes(str_base + off));
    }
    // argv[argc] = NULL
    writeUser(new_map, sp + 8 + argc * 8, &std_as_usize_bytes(0));

    const entry_rsp = sp;

    // 3. 切换到新空间：销毁旧表、安装并立即载入 CR3
    // （关键：只改 p.page_map 不切 CR3 的话，userReturn 会拿着旧表进用户态）
    vmm.destroyUserSpace(p.page_map);
    p.page_map = new_map;
    vmm.switchTo(new_map);
    p.brk = img.brk;
    setName(p, path);

    // 4. 从新入口进入用户态
    setupFirstEntry(p, img.entry, entry_rsp);
    gdt.setKernelStack(p.kstack_top);
    userReturn(@intFromPtr(p.tf));
}

/// 经由物理页向"非当前 CR3"的用户地址写入字节
fn writeUser(pml4: usize, vaddr: usize, bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const va = (vaddr + done) & ~@as(usize, 0xFFF);
        const off = vaddr + done - va;
        const n = @min(4096 - off, bytes.len - done);
        const pv = elf_userPageVirt(pml4, va);
        const dst: [*]u8 = @ptrFromInt(pv + off);
        @memcpy(dst[0..n], bytes[done .. done + n]);
        done += n;
    }
}

fn elf_userPageVirt(pml4: usize, vaddr: usize) usize {
    var t = vmm.tableOf(pml4);
    inline for (.{ (vaddr >> 39) & 511, (vaddr >> 30) & 511, (vaddr >> 21) & 511 }) |idx| {
        t = vmm.tableOf(t[idx] & 0x000F_FFFF_FFFF_F000);
    }
    const frame = t[(vaddr >> 12) & 511] & 0x000F_FFFF_FFFF_F000;
    return vmm.physToVirt(frame);
}

fn std_as_usize_bytes(v: usize) [8]u8 {
    var b: [8]u8 = undefined;
    inline for (0..8) |i| {
        b[i] = @truncate(v >> @intCast(8 * i));
    }
    return b;
}

/// exit：进程退出。普通进程变 zombie 等父进程 wait4；内核直启的孤儿
/// （ppid=0，GUI 应用）挂到 reap_me 由调度器在切走后回收——不能在
/// 自己还在自己的内核栈/页表上时就释放它们。
pub fn exit(code: i32) noreturn {
    const p = current() orelse unreachable;
    p.exit_code = code;

    // GUI 窗口等内核资源先行回收（与地址空间无关，安全）
    @import("winsys.zig").onProcExit(p.pid);

    // 子进程移交给 init(pid 1)
    for (&procs) |*c| {
        if (c.state != .unused and c.ppid == p.pid) c.ppid = 1;
    }
    // 唤醒父进程（若在 wait）
    for (&procs) |*q| {
        if (q.state == .waiting and q.pid == p.ppid) q.state = .runnable;
    }

    if (p.ppid == 0) {
        // 内核直启的孤儿：标记待收割（调度器 swtch 回来后释放资源）
        reap_me = p;
        p.state = .dying; // 占住槽位防止复用，等调度器清
    } else {
        p.state = .zombie;
    }

    swtch(&p.ctx, &sched_ctx);
    unreachable; // 不会再被调度
}

var reap_me: ?*Proc = null;

/// wait4：等待子进程。which=-1 任意子进程；成功把退出码写进 status。
/// 返回子进程 pid；错误返回负 errno。
pub fn wait4(which: i32, status: *?i32) isize {
    const p = current() orelse return -1;
    while (true) {
        var has_child = false;
        for (&procs) |*c| {
            if (c.state == .unused) continue;
            if (c.ppid != p.pid) continue;
            has_child = true;
            if (which != -1 and @as(i32, @intCast(c.pid)) != which) continue;
            if (c.state == .zombie) {
                status.* = c.exit_code;
                const pid = c.pid;
                freeKStack(c);
                vmm.destroyUserSpace(c.page_map);
                c.page_map = 0;
                c.state = .unused;
                return @intCast(pid);
            }
        }
        if (!has_child) return -10; // ECHILD
        p.state = .waiting;
        swtch(&p.ctx, &sched_ctx);
    }
}

// ================= init 进程 =================

/// 创建第一个用户进程。优先 /bin/sh，其次 /bin/hello。
pub fn spawnInit() bool {
    const slot = allocProcSlot() orelse return false;
    const p = &procs[slot];
    p.* = .{};
    p.pid = allocPid();
    p.ppid = 0;
    p.state = .runnable;

    if (!allocKStack(p)) {
        p.state = .unused;
        return false;
    }
    p.page_map = vmm.newKernelSharedPml4();
    if (p.page_map == 0) {
        freeKStack(p);
        p.state = .unused;
        return false;
    }

    // 进程 1 基础 fd：0/1/2 = 控制台
    p.fds[0] = .{ .used = true, .node = vfs.CONSOLE_NODE };
    p.fds[1] = .{ .used = true, .node = vfs.CONSOLE_NODE };
    p.fds[2] = .{ .used = true, .node = vfs.CONSOLE_NODE };
    p.cwd_buf[0] = '/';
    p.cwd_len = 1;

    // 选择要运行的 init 程序
    const try_paths = [_][]const u8{ "/bin/sh", "/bin/hello" };
    var chosen: ?[]const u8 = null;
    for (try_paths) |tp| {
        if (vfs.resolve(tp, "/") != null) {
            chosen = tp;
            break;
        }
    }
    const path = chosen orelse {
        console.kprintf("proc: no /bin/sh or /bin/hello in initrd!\n", .{});
        freeKStack(p);
        vmm.destroyUserSpace(p.page_map);
        p.state = .unused;
        return false;
    };

    return execIntoFresh(p, path);
}

/// 内核直启一个用户程序（GUI 应用菜单用）：ppid=0 的"孤儿"，退出时
/// 由调度器收割（见 exit/dying）。可在 IRQ 上下文调用——中断门 IF=0，
/// 与调度器天然互斥；vfs/elf 都是纯内存操作。
pub fn spawnKernel(path: []const u8) bool {
    const slot = allocProcSlot() orelse return false;
    const p = &procs[slot];
    p.* = .{};
    p.pid = allocPid();
    p.ppid = 0; // 孤儿：exit 走 dying 自收割
    p.state = .runnable;
    p.uid = 0; // 系统应用以 root 运行（filer 需要遍历任意目录）
    p.gid = 0;

    if (!allocKStack(p)) {
        p.state = .unused;
        return false;
    }
    p.page_map = vmm.newKernelSharedPml4();
    if (p.page_map == 0) {
        freeKStack(p);
        p.state = .unused;
        return false;
    }
    p.cwd_buf[0] = '/';
    p.cwd_len = 1;
    // 控制台三件套：GUI 应用也保留串口日志通道（printf 可见，便于调试；
    // 输出会同时进 GUI 终端镜像——内核本来就只有一条控制台流）
    p.fds[0] = .{ .used = true, .node = vfs.CONSOLE_NODE };
    p.fds[1] = .{ .used = true, .node = vfs.CONSOLE_NODE };
    p.fds[2] = .{ .used = true, .node = vfs.CONSOLE_NODE };

    const ok = execIntoFresh(p, path);
    if (!ok) {
        freeKStack(p);
        vmm.destroyUserSpace(p.page_map);
        p.page_map = 0;
        p.state = .unused;
    }
    return ok;
}

/// spawnInit 专用：p 尚无用户空间，加载 path 后从其入口进入。
/// （与 execve 不同：不替换旧空间、由调度器首次调度时进入用户态）
fn execIntoFresh(p: *Proc, path: []const u8) bool {
    const node = vfs.resolve(path, "/") orelse return false;
    const inf = vfs.info(node);
    if (inf.is_dir or inf.is_console) return false;
    const data = readExecImage(node) orelse return false;

    const img = elf.load(p.page_map, data) orelse return false;

    // 用户栈
    var si: usize = 0;
    while (si < USER_STACK_PAGES) : (si += 1) {
        const va = USER_STACK_TOP - (si + 1) * 4096;
        const frame = pmm.allocFrame() orelse return false;
        @memset(@as([*]u8, @ptrFromInt(vmm.physToVirt(frame)))[0..4096], 0);
        if (!vmm.mapPage(p.page_map, va, frame, vmm.P | vmm.W | vmm.U)) return false;
    }

    // argv[0] = path
    var str_area: [256]u8 = undefined;
    const n = @min(path.len, str_area.len);
    @memcpy(str_area[0..n], path[0..n]);
    str_area[n] = 0;
    var sp = USER_STACK_TOP - ((n + 1 + 15) & ~@as(usize, 15));
    const str_base = sp;
    writeUser(p.page_map, sp, str_area[0 .. n + 1]);

    sp -= 24; // [argc][argv0][NULL]
    sp &= ~@as(usize, 15);
    writeUser(p.page_map, sp, &std_as_usize_bytes(1));
    writeUser(p.page_map, sp + 8, &std_as_usize_bytes(str_base));
    writeUser(p.page_map, sp + 16, &std_as_usize_bytes(0));

    p.brk = img.brk;
    setName(p, path);
    setupFirstEntry(p, img.entry, sp);
    return true;
}
