# ZOS —— 用 Zig 编写的 x86_64 教学操作系统内核

ZOS 是一个为**操作系统课程教学**设计的迷你内核：从 GRUB 引导、32 位实模式跳板、
长模式分页，一路到多进程、系统调用与交互 shell，全部约 4000 行代码，内核与用户
程序（包括 shell）都用 [Zig](https://ziglang.org) 编写，没有任何第三方依赖。

> 📚 **深入文档见 [docs/](docs/README.md)**——按子系统展开的源码级讲解：
> [总体架构](docs/architecture.md) · [内核子系统](docs/kernel.md) ·
> [文件系统](docs/fs.md) ·
> [系统调用参考](docs/syscalls.md) · [网络栈](docs/network.md) ·
> [用户态与移植](docs/userland.md) · [miniGL 3D 图形](docs/gl.md) · [构建与调试](docs/build-and-debug.md)

```
ZOS 0.3.0 -- a tiny teaching kernel in Zig
boot: 64-bit long mode OK
...
ext2: 98304 blocks x 1024B, 12 group(s), 24576 inodes (128B each), rev 1, filetype
boot: root filesystem = ext2 on ATA disk
boot: init process spawned, entering scheduler

ZOS shell (pid=1) -- type 'help' for commands

/ $ uname -a
ZOS zos 0.2.0 ZOS #1 teaching kernel (zig) x86_64
/ $ ls /
etc        <dir>
dev        <dir>
bin        <dir>
hello.txt
/ $ forkdemo
forkdemo: parent pid=7, forking...
  [child ] pid=8 round 1
[parent] pid=7 round 1 (child=8)
...
```

## 快速开始

依赖：`zig 0.17.0`、`qemu-system-x86_64`、`grub-mkrescue`（打包 ISO）、
`tar`、`e2fsprogs`（mke2fs/debugfs，制作 ext2 磁盘镜像）。

```bash
# Ubuntu/Debian 安装工具（Zig 从官网下载 0.17.0）
sudo apt install qemu-system-x86 grub-pc-bin xorriso mtools e2fsprogs

zig build iso        # 编译内核+用户程序 → build/zos.iso（含 build/disk.img ext2 磁盘）
zig build run        # 启动 QEMU（串口即控制台，Ctrl-A X 退出）
./scripts/run.sh     # 等价于 zig build run
```

带 VGA 窗口的交互模式（可用键盘输入）：

```bash
qemu-system-x86_64 -cdrom build/zos.iso -drive file=build/disk.img,format=raw,if=ide -m 256M
```

无头自动化测试（PTY 驱动串口 shell，逐条执行命令）：

```bash
python3 scripts/test.py uname -a ls / cat /etc/motd ps forkdemo
python3 scripts/fscheck.py   # ext2 落盘校验：QEMU 写入 → 宿主 e2fsck/debugfs 核对
```

改过用户程序后记得 `./scripts/mkdisk.sh --force` 重建盘上的 /bin
（mkdisk.sh 默认保留盘内容，跨重启的用户文件因此不丢）。

音频子系统（AC'97 + DDS 合成，QEMU 需 `-device AC97`）：

```bash
# 串口 shell 里： beep 440 500    music
python3 scripts/audiotest.py   # wav 录音验证频率/时长（详见 docs/audio.md）
```

内核控制台同时输出到 VGA 文本屏（0xB8000）与 COM1 串口；
`qemu -serial stdio` 时串口就是完整终端（输出 + 输入 + 回显）。

### ext2 根文件系统（0.3 起：整个系统都在一块真磁盘上）

ATA PIO 驱动（`kernel/ata.zig`）+ 完整 ext2 实现（`kernel/ext2.zig`：
超级块/组描述符/位图分配/一至三重间接块/目录项算法），VFS 把它
整体挂为根（`kernel/vfs.zig` 挂载表）——`/bin`（用户程序，execve
直接从 ext2 inode 加载 ELF）、`/etc` 全在盘上，initrd/tarfs 不再
参与引导。shell 里：

```bash
ls /                          # 根 = ext2 磁盘根（mkdisk.sh 预置 /bin /etc …）
echo hi > /hi.txt             # 重定向写（O_CREAT+O_TRUNC 落盘）
cat /hi.txt
mkdir /d && rm -d /d          # 目录建删
chmod 600 /hi.txt             # 权限位真正写进 inode
df                            # 超级块空闲计数
```

写进去的文件**跨重启保留**（对比旧 tarfs：RAM 里，重启即失），
宿主机可以用 `debugfs -R "ls -l /" build/disk.img` 直接查看、
`e2fsck -fn` 体检。详见 [docs/fs.md](docs/fs.md)。

文件互拷（guest ↔ 宿主机）：

```bash
# QEMU 关机后：宿主机 debugfs 直接读写镜像（scripts/disk.sh 封装）
./scripts/disk.sh put file.txt /file.txt      # 拷入
./scripts/disk.sh get /etc/motd ./motd        # 拷出
./scripts/disk.sh ls /bin                     # 旁路查看
# guest 内部：cp <src> <dst>（dst 是目录则拷入其中）
```

### 图形界面（Win3.1 风格桌面 + 窗口 + 任务栏）

ISO 引导时 GRUB 会把视频模式设为 VBE 640x480x32，内核随后启动
GUI 合成器：青绿桌面、可拖拽窗口（点击自动提到顶层、非活动窗口
灰标题栏）、带 ZOS 按钮/RTC 时钟/窗口按钮的任务栏。点 ZOS 按钮
弹开始菜单，内置七个应用（每应用一个源文件，`kernel/apps/`）：

- **File Manager** —— 浏览 tarfs：单击目录进入、`..` 返回、
  单击文件右栏预览内容（超过 13 行带滚动条）
- **Notepad** —— 记事本：GUI 键盘焦点（活动窗口是它时按键进编辑
  器而非串口 shell，点别的窗口即归还），方向键/退格/拆行/并行
- **Terminal** —— 控制台镜像：显示完整开机日志与 shell 会话，
  在窗口里打字就是敲串口 shell（`console.putChar` 三路输出），
  光标闪烁、支持 `clear`
- **Paint** —— 画图：16 色调色板，画笔/橡皮/直线（橡皮筋预览）/
  矩形/油漆桶（洪泛填充），鼠标捕获——划出窗口也能连续画
- **Calculator** —— 计算器：f64 四则、链式运算、退格/取负/CE/C
- **Minesweeper** —— 经典 9×9/10 雷：左键翻开（首击保护区 +
  空白洪泛）、右键插旗、雷数/笑脸/计时 LED 三件套
- **About ZOS** —— 版本信息对话框
- **3D Demos** —— miniGL 软件三维：纹理棋盘立方体 / Gouraud 光照
  圆环 / 线框波浪地形，点击或左右键切换场景（见下节）

串口 shell 照常可用，两套界面互不干扰。无头环境跑自动化截图与
鼠标/键盘脚本（开全部七个应用、终端里真打一条 `ls`、记事本打字、
画图拖笔画线、扫雷翻格插旗）：

```bash
python3 scripts/guishot.py     # 自动开机→菜单→七应用→拖动，存 /tmp/zos-shot-*.png
```

详见 [docs/gui.md](docs/gui.md)。

### miniGL：软件 OpenGL 子集（3D 图形）

`userland/lib/gl.zig` 是自研的 OpenGL 1.x 风格**软件光栅化器**（纯
Zig、零依赖、宿主机可单测）：立即模式 glBegin/glEnd、矩阵栈、深度
测试、Gouraud 光照、背面剔除、**透视校正纹理采样**。渲染目标就是
winsys 的共享表面——纯用户态浮点代码，时钟中断随时打断，靠内核的
XMM 现场保存（TrapFrame + swtchImpl 两处）保证正确性。

- **glview**（菜单 "3D Demos"，Zig）：三场景演示，TCG 下约 18fps
- **glcube**（shell 运行，C）：`userland/include/zgl.h` 的 C ABI 证明
  同一份光栅化器跨语言可用
- **fputest**（shell 运行）：FPU 上下文切换回归——父子进程并发 f64
  演算，位级比对

```bash
zig build test             # 宿主机单测：光栅化逐像素断言等 12 例
python3 scripts/glishot.py # 无头视觉回归：GL 窗口两帧差异 + 场景截图
```

详见 [docs/gl.md](docs/gl.md)。

## 目录结构（源码导读顺序 = 推荐学习顺序）

| 文件 | 主题 | 教学要点 |
|---|---|---|
| `kernel/boot.S` | 引导 | Multiboot2 头、32 位入口、建页表、开长模式、跳入 64 位 |
| `kernel/linker.ld` | 链接 | 引导段(VMA==LMA)与内核主体(高端 0xFFFFFFFF80000000)的布局 |
| `kernel/main.zig` | 总入口 | zos_start：初始化流水线一览 |
| `kernel/console.zig` | 控制台 | VGA 文本模式、串口镜像、kprintf（comptime 格式化） |
| `kernel/serial.zig` | UART 16550 | 端口 I/O、轮询发送 |
| `kernel/gdt.zig` | GDT/TSS | 特权级、段描述符、TSS.rsp0（含两个经典布局陷阱的注释） |
| `kernel/idt.zig` | 中断框架 | 门描述符、256 个入口桩的 comptime 生成、TrapFrame、异常打印 |
| `kernel/pic.zig` | 8259 PIC | 重映射 IRQ 到向量 32-47、屏蔽/EOI |
| `kernel/pit.zig` | 定时器 | 100Hz 时钟、时间片与 sleep 的时基 |
| `kernel/keyboard.zig` | PS/2 键盘 | 扫码集 1 → ASCII、shift/ctrl |
| `kernel/tty.zig` | 行规程 | 环形缓冲、回显、退格、行缓冲 |
| `kernel/pmm.zig` | 物理内存 | 位图页帧分配器、内存映射初始化 |
| `kernel/vmm.zig` | 虚拟内存 | 四级页表、直接映射区、mapPage、fork 克隆/销毁 |
| `kernel/tarfs.zig` | 文件系统 | ustar 内存盘解析、目录列举（无盘兜底；0.2 为根） |
| `kernel/ata.zig` | **块设备** | ATA PIO 驱动：IDENTIFY、LBA28 扇区读写、轮询握手 |
| `kernel/ext2.zig` | **ext2（读+写）** | 超级块/组描述符、位图分配、间接块映射、目录项算法 |
| `kernel/vfs.zig` | VFS | 路径规范化（./..解析）、/dev/console 字符设备、挂载表（ext2 为根） |
| `kernel/elf.zig` | 加载器 | ELF64 PT_LOAD 段映射、bss 清零 |
| `kernel/proc.zig` | 进程 | PCB、swtch 上下文切换、fork/exec/exit/wait4、轮转调度器 |
| `kernel/pci.zig` | **PCI 枚举** | 配置空间访问、BAR 解码、MMIO 映射、总线主控使能 |
| `kernel/e1000.zig` | **网卡驱动** | e1000 描述符环（TX/RX）、DMA、轮询收发 |
| `kernel/net.zig` | **协议栈** | 以太网/ARP/IP/ICMP/UDP+DNS/TCP(停等)+HTTP |
| `kernel/gui.zig` | **GUI 合成器** | VBE 帧缓冲、分层合成、脏矩形重绘、窗口管理（z 序/任务栏/菜单/鼠标捕获/键盘焦点） |
| `kernel/apps.zig` | **GUI 应用分发** | WinKind → 每应用一个文件的回调路由（`kernel/apps/`） |
| `kernel/mouse.zig` | **PS/2 鼠标** | 8042 aux 口、IRQ12、三字节数据包协议 |
| `kernel/font.zig` | **位图字体** | 8x16（scripts/genfont.py 从 PSF 控制台字体生成） |
| `kernel/audio.zig` | **音频子系统** | AC'97 驱动（NAM/NABM、BDL 描述符环 DMA）、DDS 正弦合成 |
| `kernel/syscall.zig` | 系统调用 | int 0x80 入口分发、POSIX 子集实现 |
| `userland/lib/zos.zig` | 系统调用层 | int 0x80 封装、Zig 版 printf、空闲链表 malloc |
| `userland/lib/libc.zig` | **libc（C ABI）** | string/ctype/stdlib/errno/stdio(FILE)/dirent/qsort 导出 |
| `userland/lib/clib.c` | **libc（C 部分）** | C va_list 实现的 printf 全家族 + getopt |
| `userland/lib/crt0.zig` | 启动代码 | _start → main(argc,argv,environ) → exit(atexit) |
| `userland/include/` | **标准头文件** | stdio.h/string.h/... 移植的 C 代码零修改 include |
| `userland/sh.zig` | shell | read→fork→exec→wait 循环、内建命令、`>`/`>>` 重定向 |
| `userland/*.zig` | Zig 命令 | ls cat echo ps uname sleep hello forkdemo mkdir rm df |
| `userland/wc.c` `cdemo.c` | **C 程序** | 真 Unix wc 移植 + libc 全家桶演示 |
| `userland/beep.zig` `music.zig` | **音频命令** | AC'97 蜂鸣 / 欢乐颂旋律（zos_beep 505） |
| `userland/lib/gl.zig` | **miniGL 光栅化器** | OpenGL 1.x 子集：矩阵栈/深度/光照/透视校正纹理；宿主机可单测 |
| `userland/lib/zglabi.zig` `include/zgl.h` | **GL 的 C ABI** | zgl_* 导出，C 程序（glcube.c）同一光栅化器 |
| `userland/glview.zig` | **3D 演示** | 纹理立方体/Gouraud 圆环/线框地形三场景（用户态 GUI 应用） |
| `userland/fputest.zig` | **FPU 回归** | 并发 f64 位级校验——XMM 现场保存的正确性证明 |
| `scripts/test.py` | 自动化测试 | PTY 驱动 QEMU 串口的集成测试 |

## 内存布局

```
虚拟地址                         用途
0000000000000000 - 00007FFF...   用户空间（代码 0x400000 起，栈在 0x7FFFFFFF...）
FFFFFFFF80000000 -               直接映射区起点：phys X ↔ X + 0xFFFFFFFF80000000
FFFFFFFF80200000 -               内核主体（文本/数据/bss/内核栈）
              物理 1MB           .boot 引导段（32 位入口 + 引导页表）
              物理 2MB           内核物理起始（2MB 对齐，大页映射）
```

用户进程页表：低 256 项(用户区)深拷贝（fork）或重建（execve），
高 256 项共享内核页表——**内核映射对所有进程一致，切换只需换 CR3**。

## 系统调用（int 0x80，Linux x86_64 编号，返回 -errno）

| nr | 调用 | 说明 |
|---|---|---|
| 0/1 | read/write | fd 语义：tarfs 文件 / console（行缓冲读、回显） |
| 2/3 | open/close | 只读打开；O_DIRECTORY 支持 ls |
| 5 | fstat | st_mode/st_size/st_ino |
| 9/10/11 | mmap/mprotect/munmap | 匿名 mmap（进程游标分配） |
| 12 | brk | 用户堆（只增长） |
| 16 | ioctl | TCGETS → isatty |
| 19 | lseek | 文件内随机读 |
| 35 | nanosleep | 定时器睡眠（调度器阻塞） |
| 39 | getpid | |
| 57/59/60/61 | fork/execve/exit/wait4 | 完整进程生命周期 |
| 63 | uname | "ZOS 0.1.0 x86_64" |
| 79/80 | getcwd/chdir | 每进程 cwd |
| 19 | lseek | 文件内随机读 |
| 32 | dup | 复制 fd |
| 201 | time | 自开机秒数 |
| 217 | getdents64 | ls/opendir 的基础 |
| 500 | zos_psinfo | ZOS 扩展：进程表快照（ps 用） |
| 501 | zos_ping | ZOS 扩展：ICMP ping（返回 RTT） |
| 502 | zos_http_get | ZOS 扩展：阻塞式 DNS+TCP+HTTP GET |
| 503 | zos_net_info | ZOS 扩展：网络配置（ifconfig 用） |
| 505 | zos_beep | ZOS 扩展：AC'97 正弦蜂鸣（beep/music 用） |
| 510-514 | win_create/present/poll/wait/color | ZOS 窗口服务：共享表面 + 事件队列（用户态 GUI 应用） |
| 515 | win_fmt | ZOS 窗口服务：帧缓冲像素格式移位（miniGL 打包像素用） |

## 网络栈

ZOS 内置完整的教学网络栈，`ping` 与 `curl` 均可在 QEMU user 网络下真实工作：

```
/ $ ping 10.0.2.2 3          # QEMU 虚拟网关（= 宿主机回环）
64 bytes from 10.0.2.2: seq=1 ttl=64 time=0ms  ×3, 0% loss
/ $ curl http://example.com/  # 真实互联网
HTTP/1.1 200 OK ... 577 bytes body
```

- **驱动**：PCI 枚举 → e1000（QEMU 默认网卡）→ 描述符环 DMA 收发。
  记得设 PCI COMMAND 的 **Bus Master 位**，否则寄存器可读写但 DMA 全废。
- **协议**：以太网 → ARP（带缓存表）→ IPv4 → ICMP（可 ping 也可被 ping）→
  UDP+DNS（查 A 记录）→ TCP（停等教学实现：三次握手、重传、挥手）→ HTTP GET。
- **架构**：网络会话在内核侧阻塞完成（`sti/hlt` 等待时钟醒来后轮询网卡），
  一次只有一个会话持有"网络大锁"；用户态经扩展系统调用 501-503 访问。
- **地址**：QEMU user 网络固定 10.0.2.15/24，**10.0.2.2 即宿主机回环**——
  宿主机上 `python3 -m http.server 8099`，guest 里 `curl http://10.0.2.2:8099/`
  就能拉到，`scripts/test.py` 的自动化测试正是这么做的。

### 网络层的真实踩坑（README 老传统）

10. **PCI Bus Master**：不写 COMMAND 寄存器 bit2，网卡一切寄存器正常、
    描述符也"被消费"，但数据 DMA 全部为空——抓包看到零包；
11. **ARP 报文不能用 extern struct**：sha[6]u8 后接 u32 会对齐填充 2 字节，
    字段全体错位。抓包看到 `aa aa` 混进 SPA 才定位（又是它，0xAA 毒化）；
12. **校验和的字节序**：Internet 校验和在大端字空间运算，写回 extern struct
    字段是 LE 落盘——必须再 htons 一次，否则 IP/ICMP 校验和"值对字节反"；
13. **QEMU e1000 的 RCTL flush 定时器**：写 RCTL 后 1 秒内收包在 QEMU
    网络层排队不投递（读它的 e1000.c 才知道）——驱动初始化后等 1.2s；
14. **点分 IP 解析的字节序约定**：内核常量（首段在最高字节）与解析器
    （首段在最低字节）不一致时，ICMP 能通 ARP 全歪——统一约定并用
    `curl` 到真实域名做回归。

## libc 与程序移植

ZOS 自带完整的用户态 libc（用 Zig + C 混写），目标是让**标准 C 程序零修改移植**：

- **标准头文件**：`userland/include/` 提供 `stdio.h / stdlib.h / string.h /
  ctype.h / errno.h / unistd.h / fcntl.h / time.h / sys/stat.h / dirent.h /
  assert.h`——移植的代码保持原样 `#include`。
- **语义遵循 C/POSIX 惯例**：失败返回 -1 并设置 `errno`（内核层是 -errno，
  libc 层负责转换）；`FILE*` 流（fopen/fgets/fread/...）、`opendir/readdir`、
  `qsort`、`atexit`、`getopt`、`strdup/strtok` 一应俱全。
- **printf 全家族**（printf/fprintf/sprintf/snprintf/dprintf + v 系列）用
  C `va_list` 实现，支持宽度/精度/左右对齐/零填充/`l ll z h` 长度修饰符。
- **malloc/free/realloc/calloc**：K&R 风格空闲链表（首适应 + 分裂 + 相邻合并），
  底层经 brk 向内核要页。

### 移植一个 C 程序（三步）

```bash
# 1) 把源码放进 userland/（如 userland/foo.c），include 原样保留
# 2) build.zig 的 c_progs 列表里加 "foo"
# 3) zig build && zig build run
```

编译命令等价于：

```bash
zig cc -target x86_64-freestanding -O1 -nostdlib -no-pie \
      -Iuserland/include -Wl,--script=userland/user.ld -Wl,-e,_start \
      -o zig-out/bin/user/foo userland/foo.c zig-out/lib/libzos.a
```

`wc.c`（Unix 字数统计工具）与 `cdemo.c`（libc 全家桶自检）就是两个活例子；
Zig 程序与 C 程序可以互相 fork/exec，共存于同一个 initrd。

### 移植时的已知边界

- 无环境变量（execve 不传 envp，`getenv` 恒返回 NULL）；
- 文件系统只读（O_CREAT/写文件返回 EROFS）；
- 无信号、无线程、无 locale；`clock()` 未实现；
- `memcpy/memset/memmove` 由本 libc 提供——注意必须用 volatile 写入，
  否则会被 LLVM 死存储消除优化掉（见 libc.zig 注释，真实踩坑）。

## 调试技巧

- **串口即日志**：`-serial stdio` 下内核日志、shell 交互共用 COM1。
- **QEMU 异常日志**：`qemu -d int,cpu_reset -D /tmp/qemu.log`，grep `check_exception`
  找第一条异常；内核自己的异常打印会给出 RIP/CR2/CR3/寄存器现场。
- **GDB**：`qemu -s -S` + `gdb` `target remote :1234`，内核 ELF 带符号可直接断点。
- **踩过的真实坑**（都有代码注释，值得一看）：
  1. `LGDT/LIDT` 伪描述符是**紧凑 10 字节**（base 在偏移 2），Zig extern struct
     的对齐填充会读出垃圾 base（gdt.zig）；
  2. 64 位 TSS 的 **RSP0 在偏移 4**，u64 字段必须 `align(4)`（gdt.zig）；
  3. 上下文切换汇编若放在普通函数里，编译器**序言**会垫在保存的 RSP 与返回地址
     之间，恢复时 ret 读到垃圾——切换体必须是 naked 函数（proc.zig 的 swtchImpl）；
  4. execve 换页表必须同步 `mov cr3`，只改 PCB 字段会让 iretq 落进旧地址空间；
  5. 调度器可能从关中断的陷入上下文切入——扫描阶段必须 sti，切换临界区必须 cli
     （proc.zig scheduler 的"中断纪律"注释）；
  6. `zig cc -nostdlib` 不链 compiler_rt：`__zig_probe_stack`/`memcpy` 等要
     libc 自备；且探针长度经 **rax** 传递（zig 内部 ABI，不走 SysV）；
  7. LLVM 死存储消除会删掉 export 函数里"经转换指针写入"的循环——mem 三兄弟
     必须 volatile 写入，否则 memset 变成跳回自己的空循环；
  8. std 的默认 panic 打印器在 freestanding 上直接 `@trap` 吞掉错误信息——
     用户库要自定义完整 panic 命名空间（zos.zig 的 panic struct）；
  9. build.zig 的系统命令若不 addFileInput，**不跟踪源文件变化**——C 程序
     改了源码却在跑旧二进制（本项目真实踩坑，症状是崩溃地址永远不变）。

## 与 xv6 的对照（适合先学过 xv6 的读者）

| 主题 | xv6 (RISC-V/x86) | ZOS |
|---|---|---|
| 语言 | C | Zig（comptime 生成 IDT 桩/格式化） |
| 引导 | xv6 bootloader / QEMU -kernel | GRUB Multiboot2 + 32 位跳板 |
| 文件系统 | log FS（可写） | tarfs 内存盘（只读，练习 6 改造） |
| 系统调用 | syscall/ecall 指令 | int 0x80 软中断（IDT 门 DPL=3） |
| 用户库 | ulib.c | userland/lib/zos.zig |
| shell | sh.c | userland/sh.zig |

## 练习题（由易到难）

1. **printf 增强**：给 `userland/lib/zos.zig` 的 printf 加 `%08x`、`{c}` 转义支持。
2. **uptime 命令**：新增系统调用读取 `pit.ticks`，写 `/bin/uptime`。
3. **Ctrl-C 终止前台进程**：tty 已把 Ctrl+C(0x03) 送进缓冲并结束一行；
   给 shell/内核加信号机制终止运行中的子进程（需要"进程组"雏形）。
4. **COW fork**：把 fork 的深拷贝改为写时复制——页表项清 W 位，#PF 处理里
   按需复制（idt.zig 的 #PF 分支 + vmm.zig 的 refcount）。
5. **可写文件系统**：在 tarfs 之上加一层 ramfs overlay，实现 open(O_CREAT)/write，
   让 `echo hi > /tmp/a.txt` 可用。
6. **管道**：实现 pipe(22) 系统调用 + shell 的 `|` 语法（环形缓冲 + 阻塞读）。
7. **SYSCALL/SYSRET**：把 int 0x80 换成专用指令（MSR STAR/LSTAR + swapgs），
   比较两者陷入路径的开销。
8. **多核（SMP）**：AP 启动 + per-CPU 运行队列 + 自旋锁（大工程，毕业设计级）。
9. **miniGL 扩展**：双线性纹理过滤 / alpha 混合 / top-left 填充规则
   （docs/gl.md 的"扩展练习"有完整清单与提示）。

## 已知限制（教学取舍）

- 物理内存上限 2GB（直接映射窗口大小；见 pmm.zig 注释的扩展练习）。
- tarfs 只读；无 swap；无信号；无线程；单核。
- getdents64 一次性返回全部孩子（假设调用方缓冲足够）。
- 串口输入用 100Hz 轮询（QEMU 的 UART 中断在连续字节下有投递竞态，
  见 idt.zig 注释；键盘仍是中断驱动）。
- execve 失败时已建立的新地址空间会泄漏（练习：补 destroy 清理）。

## 常用命令

```bash
zig build              # 只编译内核 + 用户程序
zig build iso          # 制作 build/zos.iso
zig build run          # 构建并启动 QEMU（无头串口模式）
zig build test         # 宿主机单测（miniGL 光栅化逐像素断言等）
zig build test-run     # （等价 python3 scripts/test.py）
objdump -d zig-out/bin/zos-kernel.elf | less   # 看内核反汇编
tar -tf build/initrd.tar                        # 看 initrd 内容
```
