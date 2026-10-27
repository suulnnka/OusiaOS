# ZOS 文档集

这里是对 ZOS 内核与用户态的**深入文档**，按子系统展开，内容以源码为准。
快速上手（装依赖、跑起来、玩 shell）请看[项目根 README](../README.md)，
本目录面向想**读懂并修改这份代码**的读者。

## 文档地图（建议阅读顺序）

| 文档 | 内容 | 适合什么时候读 |
|---|---|---|
| [architecture.md](architecture.md) | 总体架构：启动流程、内存布局、模块全景、关键控制流 | 刚拿到代码，先建立全局图景 |
| [kernel.md](kernel.md) | 内核子系统：控制台、中断体系、物理/虚拟内存、文件系统、进程与调度 | 对照源码逐模块精读 |
| [fs.md](fs.md) | 文件系统：ATA 块设备、ext2 读/写实现、VFS 挂载表 | 学真磁盘文件系统时读 |
| [syscalls.md](syscalls.md) | 系统调用参考：编号、参数、语义、错误码、使用示例 | 写用户程序、调系统调用时查阅 |
| [network.md](network.md) | 网络栈：PCI 枚举、e1000 驱动、ARP/IP/ICMP/DNS/TCP/HTTP | 学驱动与协议实现 |
| [gui.md](gui.md) | 图形界面：VBE 帧缓冲、合成器、Win3.1 桌面/任务栏、PS/2 鼠标 | 学图形子系统与输入驱动 |
| [gl.md](gl.md) | miniGL：软件 OpenGL 子集、光栅化管线、透视校正、FPU 上下文切换 | 学 3D 图形原理与 SSE 现场保存 |
| [audio.md](audio.md) | 音频：AC'97 驱动、BDL 描述符环、DDS 合成、wav 录音验证 | 学 DMA 设备驱动与音频 |
| [userland.md](userland.md) | 用户态：crt0、zos.zig、libc、shell，以及 C 程序移植指南 | 移植自己的程序进 ZOS |
| [build-and-debug.md](build-and-debug.md) | 构建系统、运行方式、自动化测试、调试手段 | 改代码遇到问题时查阅 |

## 一图看懂 ZOS

```
        用户态 (CPL=3)                          内核态 (CPL=0)
┌─────────────────────────────┐      ┌───────────────────────────────────┐
│ /bin/sh   ls cat echo ps …  │      │  trapDispatch ← IDT (256 向量)    │
│ wc cdemo curl (C 程序)      │      │   ├─ 异常(#PF 扩栈/杀进程)        │
│   │  libc(zig+C)  zos.zig   │ int  │   ├─ IRQ0 定时器+串口/网卡轮询    │
│   │  printf/malloc/stdio    │ 0x80 │   ├─ IRQ1 键盘                   │
│   ▼                          ├─────►│   └─ 0x80 系统调用分发            │
│ crt0 _start → main → exit    │      │  syscall.zig (POSIX 子集)         │
└─────────────────────────────┘      │   ├─ proc.zig  进程/调度/swtch     │
                                     │   ├─ vfs/tarfs/ext2/elf 文件与加载│
   fork ──► execve ──► wait4         │   ├─ vmm/pmm   四级页表/位图       │
                                     │   ├─ net/e1000/pci 网络栈         │
                                     │   └─ console/serial/tty VGA+COM1  │
                                     └───────────────────────────────────┘
```

## 三条主线

1. **启动主线**：GRUB → `boot.S`（32 位跳板 → 长模式）→ `zos_start`
   初始化流水线 → `spawnInit` 创建 PID 1（shell）→ 调度器永不返回。
   详见 [architecture.md 的启动流程一节](architecture.md#2-启动流程从-grub-到-shell)。

2. **陷入主线**：用户态 `int $0x80` → CPU 切 TSS.rsp0 内核栈 → 入口桩
   压 TrapFrame → `trapDispatch` 分发 → 返回值写回 RAX → `iretq`。
   详见 [kernel.md 的中断一节](kernel.md#2-中断体系idtpicpit)。

3. **调度主线**：时钟中断到 → `trapHook` 时间片计数 → `yieldCpu` →
   `swtch` 换栈回调度器 → 扫描下一个 runnable → 换 CR3 切换地址空间。
   详见 [kernel.md 的进程一节](kernel.md#6-进程与调度proczig)。

## 约定

- 文档中的代码引用形如 `kernel/proc.zig` 的 `scheduler()`，指源文件与符号名；
  行号会随修改漂移，以符号为准。
- 本项目自带大量"真实踩坑"注释，文档在相应小节会点名，但**注释本体**（源码内）
  是第一手材料，值得直接读。
- 文档与代码不一致时，以代码为准，并欢迎顺手改文档。
