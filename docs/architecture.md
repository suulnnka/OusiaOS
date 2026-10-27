# 总体架构

本文给出 ZOS 的全局图景：模块分层、从加电到 shell 的完整启动流程、
虚拟/物理内存布局，以及几条贯穿全系统的关键控制流。
各子系统的实现细节见 [kernel.md](kernel.md) 及后续各篇。

## 1. 模块全景

```
┌────────────────────────────── 用户态 ──────────────────────────────┐
│  sh.zig（shell=init 进程）  ls/cat/echo/ps/uname/sleep/hello/…      │
│  wc/cdemo/curl（C 程序，经 libc 移植）                              │
│  ┌ crt0.zig ─ _start → main → exit ┐                               │
│  │ libc.zig + clib.c（C ABI：stdio/string/stdlib/dirent/qsort…）│   │
│  │ zos.zig（syscall 封装 + printf + malloc）                     │   │
└──────────────────────┬ int $0x80 ──────────────────────────────────┘
                       │ IDT 0x80 号门（DPL=3）
┌──────────────────────▼───────────── 内核态 ────────────────────────┐
│ syscall.zig   POSIX 子集分发（Linux x86_64 编号，返回 -errno）      │
│ proc.zig      PCB/调度器/swtch/fork/execve/exit/wait4              │
│ vmm.zig       四级页表、直接映射区、fork 克隆/execve 重建          │
│ pmm.zig       位图页帧分配器（multiboot mmap 初始化）              │
│ vfs+tarfs+elf 路径解析 / ustar 内存盘 / ELF64 加载器               │
│ net.zig       以太网/ARP/IP/ICMP/DNS/TCP(停等)/HTTP                │
│ e1000+pci     网卡驱动（描述符环 DMA）/ PCI 枚举与 MMIO            │
│ idt/gdt/pic   中断框架 / 特权级与 TSS.rsp0 / 8259 重映射            │
│ pit/keyboard  100Hz 定时器 / PS/2 键盘（IRQ1）                     │
│ console/tty   VGA+COM1 双通道输出 / 行规程（回显、行缓冲）          │
│ serial        UART 16550（同时也是端口 I/O 原语所在地）             │
│ boot.S        Multiboot2 头 + 32 位入口 + 建页表 + 开长模式跳板     │
└────────────────────────────────────────────────────────────────────┘
```

模块间依赖大体自底向上；唯一的"回调"是 `pit.tick_hook` 与
`idt.dispatch_hook`——进程子系统初始化时挂上自己，让时钟与陷入
两条路径接进调度器（见 [§4.3](#43-调度循环)）。

## 2. 启动流程：从 GRUB 到 shell

### 2.1 GRUB 阶段（bootloader 交接）

`grub.cfg` 声明两个东西：

```
multiboot2 /boot/zos-kernel.elf     ← 按 ELF 加载内核
module2   /boot/initrd.tar initrd   ← 把 tar 内存盘原样装进物理内存
```

GRUB 按 Multiboot2 协议加载后，CPU 处于：**32 位保护模式、未开分页**，
`EAX = 0x36d76289`（魔数），`EBX =` boot 信息块的**物理**地址。
此后的一切都由 `kernel/boot.S` 的 `_start` 接管。

### 2.2 boot.S：32 位跳板（约 90 行汇编干完五件事）

1. **长模式自检**：`CPUID 0x80000001` 的 EDX bit29（LM）不置位则往
   0xB8000 显存写 `!` 死循环。
2. **建引导页表**（4 张 4KB 表，位于 `.boot.bss`）：
   - `boot_pd`：512 个 2MB 大页，恒等映射物理前 1GB；
   - `PML4[0] → PDPT_low → PD`：低地址恒等映射（此刻还要在低地址执行）；
   - `PML4[511] → PDPT_high[510] → 同一张 PD`：高端映射
     `0xFFFFFFFF80000000` 起的 1GB。
   **两张映射指向同一张 PD**——这是"换地址不换页表"的交接手法。
3. **开分页与长模式**：`CR3 = boot_pml4`；`CR4 |= PAE|PGE|OSFXSR|OSXMMEXCPT`
   （OSFXSR 不开则 SSE 触发 #UD）；`EFER.LME=1`；`CR0.PG=1`。
4. **远跳进 64 位**：LGDT 一个含 `L=1` 代码段的临时 GDT，
   `ljmp $0x08, .Lcode64`。
5. **进入 Zig**：切到链接脚本定义的 `kernel_stack_top`（高端地址的
   64KB 主内核栈），把 EBX 的物理地址加上 `0xFFFFFFFF80000000` 换算成
   高端虚拟地址，`call zos_start(magic, mbi_virt)`——从此是 Zig 世界。

> 引导段 `.boot` 链接在**物理 1MB、VMA==LMA**；内核主体链接在
> **物理 2MB、虚拟 0xFFFFFFFF80200000**。详见 `kernel/linker.ld`
> 与 [§3 内存布局](#3-内存布局)。

### 2.3 zos_start：初始化流水线（kernel/main.zig）

```
console.init            VGA 清屏 + 串口 115200 8N1
multiboot.init          解析 mmap（可用内存）/ module（initrd 位置）
gdt.init                正式 GDT + TSS（ltr）
idt.init                256 个门（0x80 的 DPL=3）
pic.init                8259 重映射 IRQ→向量 32-47，先全屏蔽
pit.init                100Hz 定时器
keyboard.init           清 8042 残留
pic.unmask(0/1/2)       放行定时器/键盘/级联
pmm.init                位图分配器就绪（低 2MB、内核镜像、initrd 保留）
vmm.init                建正式内核页表：放弃恒等映射，直接映射 2GB，
                        2MB 大页 supervisor 读写，切 CR3
net.init                PCI 枚举→e1000 驱动→MMIO（需在 vmm 之后）
sti                     ← 内核从此被中断驱动
（忙等 2 秒）            验证时钟中断在跑；顺便等 QEMU e1000 的
                        RCTL flush 定时器过期（README 踩坑 13）
net 自检                ping 10.0.2.2 打印 RTT
tarfs.init + vfs.init   解析 initrd tar；列根目录、读 /etc/motd
proc.init               进程表清零；挂 tick_hook / dispatch_hook
proc.spawnInit          创建 PID 1（/bin/sh，fd 0/1/2=console）
proc.scheduler()        进入调度循环，永不返回
```

两个初始化顺序的"为什么"：

- **网络在进程之前**：网卡 MMIO 映射写进内核页表，而用户进程的
  内核半区是从内核页表复制的——先映射，所有进程才能共享。
- **内存管理在网络之前**：`mapMMIO` 依赖 `vmm.init` 建好的内核页表。

### 2.4 第一个用户进程

`spawnInit` 优先执行 `/bin/sh`（找不到则 `/bin/hello`）：

1. `newKernelSharedPml4()`：新页表，高 256 项复制内核映射；
2. `elf.load()`：把 sh 的 PT_LOAD 段逐页映射到 0x400000 起；
3. 用户栈 32 页（128KB）映射到 `0x00007FFFFFFFFFF000` 向下；
4. 栈上摆 `[argc][argv0][NULL]`；
5. 内核栈顶放伪造的 TrapFrame（RIP=入口、CS=用户代码段、
   RFLAGS=0x202 开中断）+ `firstEntry` 返回地址；
6. 调度器首次 `swtch` 到它，`firstEntry` 弹 TrapFrame `iretq` 进用户态。

之后 shell 打印提示符，阻塞在 `read(0, …)`——tty 行规程里
`yieldCpu` 让出 CPU，等你敲键盘。

## 3. 内存布局

### 3.1 物理与虚拟的对应

```
虚拟地址                              用途                物理
────────────────────────────────────────────────────────────────
0x0000000000000000 ─ 0x00007FFF…     用户空间            按进程分配
  0x0000000000400000                 用户程序加载基址     （user.ld）
  0x0000500000000000  ↑              mmap 游标起点
  0x00007FFFFFFFFFF000 ─ 向下         用户栈（自动扩页，上限 8MB）
0xFFFFFFFF40000000 附近               设备 MMIO 窗口      0xF0000000 一带
0xFFFFFFFF80000000 ─ +2GB             直接映射区           phys X ↔ X+BASE
0xFFFFFFFF80200000                   内核主体             2MB（2MB 对齐）
                                      （.text/.data/.bss/
                                        64KB 主内核栈）
```

`KERNEL_VIRT_BASE = 0xFFFFFFFF80000000` 定义在 `kernel/main.zig`，
被 vmm/console 等模块引用。三个要点：

- **直接映射区**是内核的"万能物理内存视角"：改页表、拷贝进程内存、
  读 initrd、写用户栈，全部经由 `vmm.physToVirt(p)` 用普通指针完成，
  不需要临时映射的繁琐。
- **上限 2GB**：直接映射区从 0xFFFFFFFF80000000 到 2^64 顶只有 2GB
  （`pmm.MAX_PHYS`）。扩展练习：把直接映射区挪到
  0xFFFF880000000000（Linux 老式做法）。
- **MMIO 窗口**在直接映射区**下方** 1GB（`vmm.zig` 的 `MMIO_BASE`），
  供 PCI BAR（通常在 0xF0000000 附近）映射，不占直接映射区配额。

### 3.2 用户进程页表：高半区共享

```
PML4（每进程一张）
├─ 低 256 项（用户区，0 ─ 0x00007FFF…）
│    fork：逐页深拷贝（cloneLevel）
│    execve：全部丢弃重建（destroyUserSpace + elf.load）
└─ 高 256 项（内核区，0xFFFF8000…）
     指向内核页表 —— 所有进程共享同一份
```

推论：**切换进程只需换 CR3**；内核映射对所有进程一致；
用户指针在陷入路径上可以安全地直接解引用（当前 CR3 就是
该进程页表，内核半区又在场）——`syscall.zig` 的 `userSlice`
正是吃这个红利。代价是 fork 是深拷贝（COW 是练习 4）。

### 3.3 引导阶段的两张映射

`boot.S` 的引导页表同时把物理前 1GB 映射到两处：恒等映射（0 起）
与高端映射（0xFFFFFFFF80000000 起），共享同一张 PD。`vmm.init`
建好正式页表并切换 CR3 后，**恒等映射被放弃**——内核从此只能
通过高端地址访问物理内存，低虚拟地址交还给用户空间。

## 4. 关键控制流

### 4.1 一次系统调用的完整路径

```
用户态                          内核态
──────                          ──────
zos.read(fd, buf)
  └ rax=0, rdi=fd, …
    int $0x80 ──────────────►   CPU 查 IDT[0x80]（DPL=3，门合法）
                                  从 TSS.rsp0 取内核栈，压 SS/RSP/RFLAGS/CS/RIP
                                  跳到入口桩：push 向量号 0x80（补 0 错误码）
                                trapCommon：压 15 个通用寄存器 → TrapFrame
                                trapDispatch(frame)
                                  ├ v==0x80 → syscall.handle(frame)
                                  │    switch(nr) → sysRead …
                                  │    frame.rax = 返回值（负数=-errno）
                                  └ dispatch_hook → trapHook（时间片检查）
                                trapCommon 恢复寄存器
    ◄───────────────────────   iretq 弹出 RIP/CS/RFLAGS/RSP/SS
rax = 返回值
```

TrapFrame 的字段顺序 = 栈上排列顺序（`idt.zig`），这是内核里
最重要的一份 ABI 约定：fork 拷贝它、execve 伪造它、调度器更新它。

### 4.2 一次时钟中断（抢占的源头）

```
PIT 100Hz → IRQ0 → 向量 32 → pit.onTick（ticks+1，唤醒睡眠进程）
                          → 轮询串口/网卡（教学取舍，见 kernel.md）
                          → pic.sendEoi
                          → trapHook：quantum+1
                             ≥ QUANTUM(2 tick) → yieldCpu → swtch 回调度器
```

### 4.3 调度循环

`proc.scheduler()` 运行在链接脚本定义的**主内核栈**（idle 上下文），
永不返回。每个循环：

1. `sti`——扫描阶段必须开中断（时钟要能打断，否则无法抢占；
   从关中断的陷入上下文切回来时 IF=0）；
2. 找到 runnable 进程 → `cli` 进**切换临界区**：设 current、
   `gdt.setKernelStack(p.kstack_top)`（下次陷入用它的内核栈）、
   `vmm.switchTo(p.page_map)`（换 CR3）、`swtch(&sched_ctx, &p.ctx)`；
3. 进程让出 CPU 回到此处 → 切回内核页表与主栈、current=null；
4. 没有 runnable → `sti; hlt` 睡到下一个中断。

"中断纪律"（扫描开、切换关）是 `proc.zig` 调度器注释里的教学重点，
违反任一半都会出现偶发挂死。

### 4.4 上下文切换的本质

```
swtch(old, new)          swtchImpl（naked 函数）
  保存 old->rsp  ◄────   push rbp/rbx/r12-r15; mov %rsp,(%rdi)
  加载 new->rsp  ────►   mov (%rsi),%rsp; pop r15…rbp; ret
```

只保存 **RSP**：callee-saved 寄存器由被切换方自己压栈，
caller-saved 寄存器按 ABI 本来就不跨调用存活。"栈就是进程的魂"
——新进程的栈顶预摆了 `firstEntry`（首次运行）或上次让出时的
返回地址（再次运行）。

两个配套细节：

- `swtchImpl` 必须是 **naked** 函数：普通函数的编译器序言会把
  局部垫在"保存的 RSP 与返回地址"之间，恢复路径的 ret 读到垃圾。
- 新进程首次运行走 `firstEntry`（也是 naked）：内核栈顶是伪造的
  TrapFrame，直接弹寄存器 + iretq 进用户态，不经过普通调用路径，
  避开 SysV 栈对齐问题。

## 5. 设计取舍速览

| 取舍 | 选择 | 理由（教学视角） |
|---|---|---|
| 单内核/微内核 | 单内核，模块清晰 | 4000 行讲清楚一件事 |
| 抢占方式 | 时钟中断 + 时间片轮转（20ms） | 最小可讲解的调度器 |
| fork 语义 | 深拷贝 | 先懂"地址空间是数据结构"，再谈 COW |
| 系统调用机制 | int 0x80 | 复用中断框架；SYSCALL/SYSRET 是练习 7 |
| 文件系统 | ustar 内存盘（运行期可写：写时拷贝到自分配页）+ ext2 挂载 | "文件系统=对一块内存的解释"；练习 5 已完成——写入时才把数据搬进自己的页 |
| 网络收包 | 100Hz 时钟轮询 | 避开 QEMU UART/e1000 中断投递竞态；改中断是练习 |
| 并发 | 单核、网络大锁、无自旋锁 | SMP 是练习 8（毕业设计级） |
| libc | 自带（Zig+C 混写） | 让标准 C 程序零修改移植（wc/curl 是活例子） |

## 6. 与 xv6 的对照

| 主题 | xv6 | ZOS |
|---|---|---|
| 语言 | C | Zig（comptime 生成 IDT 桩/printf） |
| 引导 | 自带 bootloader / -kernel | GRUB Multiboot2 + 32 位跳板 |
| 页表 | RISC-V SV39 / x86 二级 | x86-64 四级，高半区共享内核页表 |
| 文件系统 | log FS（可写） | tarfs（只读） |
| 系统调用 | ecall/syscall 指令 | int 0x80 软中断 |
| 用户库 | ulib.c | zos.zig + libc（Zig/C 混写，支持 C ABI） |
| 网络 | 无 | PCI/e1000/ARP/IP/ICMP/DNS/TCP/HTTP |
| shell | sh.c | sh.zig（同样 read-fork-exec-wait） |

## 7. 术语与约定

- **帧（frame）**：4KB 物理页，PMM 的分配单位；
- **陷入（trap）**：异常/中断/系统调用的统称，现场即 TrapFrame；
- **内核半区/用户半区**：PML4 高/低 256 项；
- **-errno 约定**：内核系统调用失败返回负 errno（如 -2=ENOENT）；
  libc 层再转成"返回 -1 + 设置全局 errno"的 C 惯例；
- **大锁**：`net.zig` 的 `net_lock`，同一时刻只允许一个网络会话。
