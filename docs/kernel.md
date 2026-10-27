# 内核子系统详解

本文按"控制台 → 中断 → 内存 → 文件 → 进程"的顺序逐模块展开，
每个小节给出职责、关键数据结构、实现要点与源码位置。
启动相关（boot.S / linker.ld / multiboot）见
[architecture.md](architecture.md#2-启动流程从-grub-到-shell)，
网络（pci/e1000/net）见 [network.md](network.md)。

## 1. 控制台与 I/O 原语

### 1.1 serial.zig —— UART 16550（COM1）

- 初始化 115200 波特、8N1、开 FIFO；发送为轮询阻塞
  （等 LSR bit5 THR 空），接收为非阻塞（LSR bit0 有数据才读）。
- 本文件同时是全内核的**端口 I/O 原语**所在地：
  `outb/outw/inb/inw/ioWait` 被 pic/pit/keyboard/pci 直接使用——
  这也是 `pic.zig` import `serial.zig` 的原因。
- QEMU `-serial stdio` 把 COM1 接到宿主终端，因此串口同时承担
  内核日志、无头测试通道、交互 shell 三重角色。

### 1.2 console.zig —— VGA 文本屏 + 串口镜像 + kprintf

- `putChar` 一个字节写两路：串口原样（支持 UTF-8），
  VGA 经 0xB8000 显存（80×25，每字符 2 字节=ASCII+属性，
  非 ASCII 显示 `?`）。
- 处理 `\n \r \t` 退格，满屏滚动（整屏上移一行），
  硬件光标经 CRT 索引/数据端口 0x3D4/0x3D5 更新。
- `kprintf(fmt, args)` 是 **comptime 展开**的格式化：
  格式串在编译期逐字符解析，`{s}/{d}/{x}/{X}/{c}` 与 `{}`（自动
  按类型选十进制或字符串）在编译期绑定到对应参数，参数个数
  不匹配直接编译错误。Zig 元编程教学的活标本。

### 1.3 tty.zig —— 行规程（line discipline）

字符设备的输入缓冲与回显，介于"驱动吐裸字节"与"read 拿到完整行"之间：

- 1KB **环形缓冲**（head/count），生产者是键盘与串口中断，消费者是进程；
- 回显、退格（0x08/0x7F，行首不允许退）、忽略 `\r`；
- `complete_lines` 计数完整行（`\n` 或 Ctrl+C 的 0x03 都终结一行）；
- `read(dst)` 阻塞直到有完整行：调度器就绪前 `hlt` 轮询，
  就绪后 `yieldCpu()` 让出 CPU（`setSchedulerReady` 在 proc.init 时置位）。

```
键盘中断 ─┐
          ├─► tty.onInput ─► [环形缓冲+回显] ─► tty.read ─► shell
串口轮询 ─┘                                        ▲
                                            阻塞时 yieldCpu
```

## 2. 中断体系（IDT/PIC/PIT）

### 2.1 gdt.zig —— GDT 与 TSS

x86-64 分段已名存实亡，但**特权级**（CPL=0/3）仍由段选择子承载：

| 选择子 | 值 | 用途 |
|---|---|---|
| KCODE/KDATA | 0x08/0x10 | 内核代码/数据段 |
| UCODE/UDATA | 0x18|3 / 0x20|3 | 用户段（RPL=3） |
| TSS | 0x28 | 任务段 |

TSS 在 64 位下的唯一关键作用是 **rsp0**：用户态→内核态转移时
CPU 自动加载的内核栈顶。每次进程切换都要 `setKernelStack` 更新。

两个经典布局陷阱（源码注释有完整分析）：

1. **LGDT/LIDT 伪描述符是紧凑 10 字节**：u16 limit + 未对齐 u64 base。
   Zig extern struct 会给 u64 插对齐填充，读出垃圾 base——
   只能用字节数组手工填充（`loadPseudoDesc`）。
2. **64 位 TSS 的 RSP0 在字节偏移 4**（不是 8）：u64 字段必须
   `align(4)`，并用 comptime 断言 `@offsetOf(Tss,"rsp0")==4` 兜底。

### 2.2 idt.zig —— 中断描述符表与分发

- 256 个 64 位中断门；0x80 号门 DPL=3（用户态可触发），其余 DPL=0。
- **入口桩 comptime 生成**：`stubFor(v)` 为每个向量生成一个 naked
  函数——有错误码的异常（8,10,11,12,13,14,17,21）不补，其余
  `push $0` 补齐，保证 TrapFrame 布局统一，然后 `jmp trapCommon`。
- `trapCommon`：压 15 个通用寄存器形成 **TrapFrame**
  （字段顺序=栈上排列：寄存器 / intno+errcode / CPU 压的
  RIP,CS,RFLAGS,RSP,SS），对齐 16 字节后调 `trapDispatch`。
- `trapDispatch` 的分发逻辑：

```
v < 32   异常
  ├ #PF 且来自用户态 → growStackOnFault(cr2)？重试 : 杀进程(exit 139)
  ├ 其他来自用户态   → "[signal] pid N killed" + exit(139)   ← 单进程崩溃不拖垮内核
  └ 内核态           → exception()：打印 RIP/CR2/CR3/全寄存器，hlt
v == 0x80 系统调用    → syscall.handle(frame)
v < 48   IRQ（= v-32）
  ├ IRQ0：pit.onTick + 轮询串口 + 轮询网卡 + EOI
  └ IRQ1：keyboard.onInterrupt + EOI
最后     dispatch_hook（进程阶段=trapHook：时间片抢占）
```

**用户态异常的处置**是本内核的健壮性亮点：野指针/除零只杀
当前进程（退出码 139 = 128+SIGSEGV 惯例），内核与其他进程继续跑。

### 2.3 pic.zig —— 8259 中断控制器

- 两片级联（主 0x20/0xA0，从片接主片 IRQ2）；
- BIOS 默认把 IRQ0-15 映到向量 8-15，与 CPU 异常冲突——
  ICW 序列**重映射到 32-47**；
- 初始化后全屏蔽，由 main.zig 按需 `unmask`（0 定时器/1 键盘/2 级联）；
- EOI：从片 IRQ 要给两片都发 EOI。

### 2.4 pit.zig —— 100Hz 定时器

- 通道 0 除数 `1193182/100 = 11932` → 每 10ms 一次 IRQ0；
- `ticks` 全局计数是**全内核唯一时基**：调度时间片、sleep 唤醒、
  ping/HTTP 超时、TCP 重传都读它；
- `tick_hook` 回调在 proc.init 后指向 `proc.onTick`（唤醒睡眠进程）。

### 2.5 keyboard.zig —— PS/2 键盘

- IRQ1 中断驱动；扫描码集 1 → ASCII（US 布局双表：normal/shift）；
- 维护 shift/ctrl 状态；Ctrl+字母 → 控制字符（Ctrl+C=0x03）；
- 只做"扫描码→字符"，回显/行缓冲职责在 tty.zig。

## 3. 物理内存：pmm.zig

位图页帧分配器——内核的第一个数据结构：

- **位图**：每帧 1 bit（1=占用），静态 64KB 于 .bss，
  覆盖上限 `MAX_PHYS = 2GB`（直接映射窗口大小）；
- **初始化**：全部置 1，再按 multiboot mmap 把 usable 区域逐帧清 0；
  另外保留低 2MB（引导段+内核镜像）、`kernel_phys_start..end`、
  initrd 模块区间；
- **分配**：从 `next_hint` 线性向下扫描找第一个空闲位
  （轮询指针，简单且分配地址渐次推进）；
- `freeFrame` 带双释放检测（打印警告）；
- `selfTest`：开机自检 分配→写→读→释放。

注意一个曾经的**隐性约定**（后来被打脸修掉了）：`allocFrame` 的
线性扫描"看起来天然"返回物理连续的帧序列，`proc.allocKStack` 早期
就依赖这一点拼虚拟连续的内核栈——但扫描跨过保留区边界（内核↔
initrd 的间隙、MMIO 洞）时会"跨界硬拼"出不连续的序列，内核长胖
让间隙位置挪动后真的踩中过（现象：`proc: kstack not contiguous!`）。
现在 pmm 提供显式的 `allocContigFrames(n)`：凑齐长度为 n 的连续
空闲位段才整体占用，跨界整段跳过；kstack 一律走它（见
[§6.2](#62-内核栈)）。真实内核的对应物是 Linux 的 buddy 分配器。

## 4. 虚拟内存：vmm.zig

### 4.1 核心机制

- x86-64 四级页表 PML4→PDPT→PD→PT，每级 9 位索引、512 项；
- `physToVirt/virtToPhys`：直接映射区的加减换算；
  `tableOf(paddr)`：把页表物理地址变成可解引用的 `*Table`；
- 权限位常量 `P/W/U/A/D/PS`（PS=大页：PD 级 2MB，PDPT 级 1GB）。

### 4.2 init()：建正式内核页表

放弃 boot.S 的临时映射（含恒等映射），新建 PML4：

- 直接映射 [0, 2GB) → [BASE, BASE+2GB)，2MB 大页 `P|W|PS|A|D`
  （supervisor 读写，无 U——用户态不可摸物理内存）；
- 切 CR3；此后恒等映射失效，boot.S 的四张引导页表成死内存。

### 4.3 通用接口

- `mapPage(pml4, va, pa, flags)`：4KB 页，按需建立中间级
  （中间级统一带 `P|W|U`——用户叶子页要能"穿过"各级，否则 #PF）；
- `unmapPage`：清 PTE + invlpg（不释放页帧，归 destroyUserSpace 统管）；
- `isMapped`：走页表查询，遇大页（PS 位）直接判已映射；
- `mapMMIO(phys, len)`：把设备 BAR 映射进内核 MMIO 窗口
  （`MMIO_BASE = BASE - 0x4000_0000`，向下借 1GB）。

### 4.4 fork / execve 的地址空间操作

| 操作 | 函数 | 行为 |
|---|---|---|
| fork | `cloneUserSpace` | 新 PML4；高 256 项复制内核表项；低 256 项递归 `cloneLevel` **逐页深拷贝**（叶子分配新帧+memcpy，保留权限位） |
| execve | `newKernelSharedPml4` | 全新 PML4，仅高 256 项=内核映射；旧空间稍后 `destroyUserSpace` |
| 收尸 | `destroyUserSpace` | 递归释放低半区全部表+数据页+PML4 本身；**高半区绝不释放**（共享内核页表） |

`level==0 只遍历 256 项`的边界检查在 clone/free 两处都成立，
违反它会直接把内核页表拆了。

### 4.5 elf.zig —— ELF64 加载器

- 支持 ET_EXEC 静态小端 x86-64（PIE/动态链接不支持）；
- 校验 ELF 魔数/类别/版本/e_machine 后遍历 **PT_LOAD** 段：
  逐页"分配帧→清零→mapPage→拷贝属于本页的文件内容"
  （`p_offset..filesz` 拷数据，`filesz..memsz` 保持清零即 bss）；
- 拒绝 `p_vaddr < 0x1000`——第 0 页不映射，空指针解引用立刻 #PF；
- 关键手法 `userPageVirt`：向**非当前 CR3** 的地址空间填内容时，
  先从页表查出物理帧，再经直接映射区写入——不必切 CR3。
  execve 摆 argv（`proc.writeUser`）同款思路。

## 5. 文件系统：tarfs.zig + vfs.zig

### 5.1 tarfs —— ustar 内存盘

- GRUB `module2` 把整块 tar 装进物理内存；"文件系统"只是
  对这块内存的**解释方式**；
- init 扫描 512 字节 ustar 头链：name[100]/size[12 八进制]/
  typeflag（'0' 文件 '5' 目录），数据紧跟其后按 512 对齐；
  全零块=归档结束；最多 128 个节点（MAX_NODES）；
- 节点保存**规范化路径**（去 "./" 前缀与首尾 '/'，如 `etc/motd`），
  文件数据是指向 initrd 内存的切片（零拷贝）；
- 目录没有独立结构：`childIter(prefix)` 遍历节点表，
  "路径前缀匹配且剩余部分不含 /"即为直接孩子。

### 5.2 vfs —— 路径解析与设备抽象

"一切皆文件"的最小实现。**节点编号**即统一句柄：

| 节点 | 含义 |
|---|---|
| 0 | `/`（虚拟根） |
| 1 | `/dev/console`（字符设备，内核特判） |
| 2..N+1 | tarfs 节点（tarfs 下标 = vfs 编号 − 2） |

- `normalizePath`：合并 cwd、消解 `.`/`..`，输出规范路径
  （长度上限 256，超长返回 null）——chdir 与 resolve 共用；
- `resolve` → 节点号；`info` → is_dir/is_console/size/st_mode；
- `read`：根=EISDIR；console=行缓冲阻塞读（tty）；
  文件=内存切片 memcpy + EOF 语义；
- `write`：只有 console 可写，其余 EROFS（只读文件系统）；
- `listDir`：回调式遍历目录孩子（getdents64 与内核列目录共用）。

## 6. 进程与调度（proc.zig）

### 6.1 进程模型

进程 = 地址空间（PML4）+ 内核栈 + TrapFrame 现场 + 状态。
静态进程表 `procs[16]`（MAX_PROCS），无动态分配。

```zig
Proc {
    state: unused|runnable|running|sleeping|waiting|zombie,
    pid, ppid, exit_code, quantum, wake_tick,
    page_map,                 // 用户 PML4 物理地址
    kstack_frames[4], kstack_top,
    ctx: Context{rsp},        // swtch 现场
    tf: *TrapFrame,           // 最近陷入帧（fork/exec 用）
    brk, mmap_next,           // 堆游标 / mmap 游标
    fds[16], cwd_buf[256],    // 打开文件表 / 工作目录
}
```

### 6.2 内核栈

- 每进程 4 页（16KB），`allocKStack` 连续分配 4 帧，
  依赖 PMM 线性扫描保证**帧号连续**，再校验；
  在直接映射区下"物理连续=虚拟连续"，栈顶即可用。
- 为什么必须虚拟连续的内核栈：TSS.rsp0 只有一个栈顶值，
  陷入路径向下压栈不能跨到别的映射。

### 6.3 用户栈与按需扩页

- 初始 32 页（128KB）位于 `0x00007FFFFFFFFFF000` 向下；
- `growStackOnFault(cr2)`：#PF 落在 [栈顶−8MB, 栈顶) 且该页
  未映射 → 补一页清零映射，返回 true 重试指令——
  经典 demand paging 入门（在 idt.trapDispatch 的 #PF 分支调用）。

### 6.4 fork / execve / exit / wait4

**fork**（父进程陷入上下文中调用）：
1. 找空槽、分配 pid/ppid、allocKStack；
2. `cloneUserSpace` 深拷贝地址空间；
3. 内核栈顶拷贝**父进程 TrapFrame 并改 rax=0**——子进程从
   fork 调用点"返回 0"；栈下再摆 firstEntry 返回地址；
4. 继承 fd 表、cwd、brk、mmap 游标、名字。

**execve**（成功不返回）：
1. resolve+读 tarfs 数据；`newKernelSharedPml4` + `elf.load`
   ——全程在旧地址空间里干活，失败返回 false 原样继续跑；
2. 新空间里建用户栈，自顶向下摆：字符串区 → argv 指针数组 →
   argc（`writeUser` 经物理页写非当前地址空间）；
3. **换空间三连**：destroyUserSpace(旧) → p.page_map=新 →
   `switchTo` 立即 mov cr3（只改字段不切 CR3 的话 userReturn
   会拿着旧表回用户态——README 踩坑 4）；
4. `setupFirstEntry` + `userReturn` 从新入口直接进用户态。

**exit**：state=zombie；子进程移交给 init（pid 1）；
唤醒 waiting 的父进程；swtch 让出，永不回来。

**wait4**：扫描找 zombie 子进程→收尸（freeKStack +
destroyUserSpace + 槽位置 unused）→ 返回 pid 与退出码；
没有 zombie 但有子进程→ state=waiting 让出 CPU；
没有子进程→ -ECHILD。

### 6.5 调度器

轮转（Round-Robin），时间片 QUANTUM=2 tick（20ms）。
主循环与"中断纪律"见 [architecture.md §4.3](architecture.md#43-调度循环)。

三个让出 CPU 的路径殊途同归（都 `swtch(&p.ctx, &sched_ctx)`）：

| 路径 | 触发 | 状态变迁 |
|---|---|---|
| `yieldCpu` | 时间片到（trapHook）/ tty 等输入 | running→runnable |
| `sleepMs` | nanosleep/内核 sleep | running→sleeping，onTick 到点唤醒 |
| `exit`/`wait4` | 进程终止/等子进程 | →zombie / →waiting |

`trapHook` 里还有一个防御分支：进程状态不是 running 却又进了
trapHook（说明在非预期点被动切走了），直接再 swtch 回调度器。

## 7. 常量速查

| 常量 | 值 | 位置 |
|---|---|---|
| KERNEL_VIRT_BASE | 0xFFFFFFFF80000000 | main.zig |
| MAX_PHYS（直接映射上限） | 2GB | pmm.zig |
| QUANTUM（时间片） | 2 tick = 20ms | proc.zig |
| MAX_PROCS | 16 | proc.zig |
| MAX_FD | 16 | proc.zig |
| KSTACK_PAGES | 4（16KB） | proc.zig |
| USER_STACK_TOP | 0x00007FFFFFFFFFF000 | proc.zig |
| USER_STACK_PAGES / LIMIT | 32 页 / 8MB | proc.zig |
| mmap 游标起点 | 0x0000500000000000 | proc.zig |
| PIT 频率 | 100Hz（tick=10ms） | pit.zig |
| IRQ 基向量 | 32 | pic.zig |
| tty 缓冲 | 1024B | tty.zig |
| tarfs 节点上限 | 128 | tarfs.zig |
| 主内核栈 | 64KB | linker.ld |
| 用户程序基址 | 0x400000 | user.ld |
