# 系统调用参考

ZOS 的系统调用走 **int 0x80 软中断**，编号与参数约定对齐
**Linux x86_64** 传统 ABI（非 syscall 指令的 ABI）：

| 寄存器 | 角色 |
|---|---|
| RAX | 系统调用号（入口）/ 返回值（出口） |
| RDI / RSI / RDX | 第 1/2/3 参数 |
| R10 / R8 | 第 4/5 参数（仅 zos_http_get 使用） |
| 返回值 | 成功 ≥ 0；失败为**负 errno**（如 -2 = ENOENT） |

实现位于 `kernel/syscall.zig`（分发 `handle()`），
用户态封装位于 `userland/lib/zos.zig`（syscall0/1/3/5 内联汇编）。
libc 层（`userland/lib/libc.zig`）把 -errno 转换成 C 惯例
"返回 -1 并设置全局 `errno`"。

> 内核态发出的 int 0x80 会被拒绝（TrapFrame 布局不同，返回 ENOSYS）。

## 1. 调用一览

| nr | 调用 | 原型要点 | 语义摘要 |
|---|---|---|---|
| 0 | read | (fd, buf, count) | console 行缓冲读 / tarfs 文件读；上限 64KB 每次 |
| 1 | write | (fd, buf, count) | console / tarfs(RAM) / ext2(磁盘) 可写；从 fd 位置续写 |
| 2 | open | (path, flags) | O_RDONLY/O_WRONLY/O_RDWR + O_CREAT/O_EXCL/O_TRUNC；/mnt 下落盘 ext2 |
| 3 | close | (fd) | 释放 fd 槽位 |
| 5 | fstat | (fd, buf) | 填 x86_64 struct stat 关键字段 |
| 9 | mmap | (addr 忽略, len, prot 忽略) | 匿名 RW 用户页，游标分配 |
| 10 | mprotect | — | 空操作，返回 0 |
| 11 | munmap | — | 空操作，返回 0 |
| 12 | brk | (addr) | addr=0 查询；否则只增长（上限 +32MB） |
| 16 | ioctl | (fd, req) | console + TCGETS(0x5401) → 0；isatty 的基础 |
| 19 | lseek | (fd, off, whence) | SEEK_SET/CUR/END；console→ESPIPE |
| 32 | dup | (fd) | 复制到最低空闲槽 |
| 33 | dup2 | (fd, newfd) | 复制到指定槽位（shell 重定向 `>` 的基础） |
| 35 | nanosleep | (req) | 按 timespec 睡眠（调度器阻塞） |
| 39 | getpid | — | 当前 pid |
| 57 | fork | — | 深拷贝克隆；子进程返回 0 |
| 59 | execve | (path, argv) | 替换地址空间；不传 envp |
| 60 | exit | (code) | 变 zombie，子进程移交 init，唤醒父进程 |
| 61 | wait4 | (which, status*) | which=-1 任意；收尸取退出码 |
| 63 | uname | (buf) | "ZOS 0.1.0 x86_64" |
| 79 | getcwd | (buf, size) | 每进程 cwd |
| 80 | chdir | (path) | 规范化后更新 cwd |
| 90 | chmod | (path, mode) | 权限位生效（owner/root）；tarfs 改 RAM 副本，ext2 落盘 |
| 92 | chown | (path, uid, gid) | root 专属；gid=-1 不改 |
| 102/104 | getuid/getgid | — | 进程凭证 |
| 105/106 | setuid/setgid | (uid/gid) | root 任意切；普通人只能切自己 |
| 201 | time | — | 自开机秒数 |
| 83 | mkdir | (path, mode) | 建目录（父目录需 w+x；ext2 落盘） |
| 84 | rmdir | (path) | 删空目录（非空 → ENOTEMPTY） |
| 87 | unlink | (path) | 删文件（目录 → EISDIR） |
| 217 | getdents64 | (fd, buf, count) | 一次性返回目录全部孩子 |
| 510 | win_create | (w, h, title*) | → 表面用户虚拟地址（用户态 GUI） |
| 511 | win_present | — | 客户区记脏区，IRQ0 合成上屏 |
| 512 | win_poll | (ev*, n) | 非阻塞取事件 |
| 513 | win_wait | (ev*, n, timeout_ms) | 空队列阻塞；事件/超时唤醒 |
| 514 | win_color | (r, g, b) | → 帧缓冲格式像素值 |
| 500 | zos_psinfo | (buf, max) | 进程表快照（ps 用） |
| 501 | zos_ping | (ip, seq) | ICMP ping，返回 RTT(ms) |
| 502 | zos_http_get | (host, port, path, out*, out_len) | 阻塞式 DNS+TCP+HTTP GET |
| 503 | zos_net_info | (buf, len) | 网络配置串（ifconfig 用） |
| 505 | zos_beep | (freq, ms) | AC'97 正弦单音，阻塞播完（audio 用） |
| 508 | zos_fsinfo | (buf, len) | ext2 概要串（df 用）；未挂载 → ENOSYS |

## 2. 分组说明

### 2.1 文件 I/O（0/1/2/3/5/19/32/217）

fd 是 `proc.fds[16]` 的下标；0/1/2 在 init 进程出生时即指向
console（`/dev/console`，vfs 节点 1），fork 继承、execve 保留。

- **read**：console 走 tty 行规程（阻塞到完整行，回显由 tty 负责）；
  文件按 `f.pos` 读，EOF 返回 0；单次上限 64KB。
- **open**：路径解析经 vfs（相对路径基于进程 cwd）；
  `(flags & 3) != O_RDONLY` 且目标非 console → EROFS；
  fd 满返回 EAGAIN（不是 EMFILE，教学简化）。
- **fstat**：按 x86_64 `struct stat` 偏移填 `st_ino@8`（=vfs 节点号）、
  `st_mode@24`、`st_size@48`；S_IFREG/S_IFDIR/S_IFCHR 由节点类型定。
- **getdents64**：**一次性**填入全部直接孩子（f.pos==1 表示已读完，
  再调返回 0）。dirent64 记录：ino/off/reclen(19+名字长+1)/dtype
  （4=dir 2=chr 8=reg），名字在偏移 **19**（不是 sizeof=24，
  extern struct 对齐填充的坑，源码有注释）。

### 2.2 内存（9/10/11/12）

- **mmap**：只支持匿名（MAP_ANONYMOUS）RW 用户页；忽略 hint 与
  prot；单次 ≤1024 页；从 `p.mmap_next`（0x0000500000000000 起）
  线性分配，失败回滚已映射部分。malloc 的底层。
- **brk**：addr=0 返回当前断点；否则只增长不收缩（收缩不还页），
  单次增量上限 32MB。K&R malloc 扩堆的底层。
- mprotect/munmap 为**空操作**（返回 0）——足够让移植代码链接通过。

### 2.3 进程控制（35/39/57/59/60/61）

- **fork**：无参数。子进程从内核栈顶拷贝的 TrapFrame 恢复，
  rax 被改写为 0；失败 EAGAIN（进程表满/内存不足）。
- **execve**：argv 为用户空间 `char*` 数组（NULL 结尾，≤32 个，
  每个截断 255 字节）。成功不返回；失败 ENOENT/EINVAL。
  **无 envp**——getenv 恒返回 NULL，这是移植边界之一。
- **exit**：code 取低 32 位。子进程移交给 pid 1（init 收养）。
- **wait4**：which=-1 任意子进程 / 指定 pid。status 非空则写 4 字节
  退出码。无子进程返回 -ECHILD。
- **nanosleep**：req 指向 `{i64 秒, i64 纳秒}`；不足 10ms 按 10ms
  向上取整（1 tick）。睡眠期间进程阻塞（sleeping），不占 CPU。

### 2.4 系统信息（16/63/79/80/201）

- **ioctl TCGETS**：fd 是 console 时返回 0，否则 ENOTTY——
  libc 的 `isatty()` 就是它。
- **uname**：按 6×65 字节填 sysname/nodename/release/version/machine。
- **time**：`pit.uptimeMs()/1000`，无时区/墙上时钟概念。
- **getcwd/chdir**：cwd 存 PCB 内（256 字节缓冲），chdir 先
  normalizePath 再 resolve 校验是目录。

### 2.5 ZOS 扩展（500-503）

不与 Linux 编号冲突的自定义调用，网络功能的用户态入口：

- **zos_psinfo(buf, max)**：填 `PsEntry[]`（pid/ppid/state/name[16]），
  跳过 unused 槽位，返回条数。`ps` 命令用。
- **zos_ping(ip, seq)**：ip 为**主机序 u32**（首段在最高字节，
  与 `net.parseIp` 约定一致，README 踩坑 14）；返回 RTT 毫秒，
  失败 -110 ETIMEDOUT / -19 ENODEV / -5 EIO。
- **zos_http_get(host, port, path, out, out_len)**：第 4/5 参数走
  **R10/R8**（不是 SysV 的 RCX/R8——int 0x80 语义下自行约定）。
  阻塞完成 DNS→ARP→TCP→HTTP，响应（含头）拷入 out，返回长度。
- **zos_net_info(buf, len)**：返回
  `"ip=10.0.2.15 mask=255.255.255.0 gw=10.0.2.2 dns=10.0.2.3\n"`。
- **zos_beep(freq, ms)**：阻塞播放正弦单音（详见 [audio.md](audio.md)）。
  freq 限 20..8000、ms 限 1..10000；返回 -19 无声卡、-11 有播放进行中、
  -22 参数越界。

## 3. errno 一览（内核实际会返回的）

| 值 | 名 | 场景 |
|---|---|---|
| 1 | EPERM | （保留） |
| 2 | ENOENT | 路径不存在；execve 失败 |
| 9 | EBADF | fd 越界/未打开 |
| 10 | ECHILD | wait4 无子进程 |
| 11 | EAGAIN | 进程表满；fd 表满；DNS 解析失败（http_get） |
| 12 | ENOMEM | mmap/brk/页分配失败 |
| 19 | ENODEV | 网卡未初始化 |
| 20 | ENOTDIR | chdir 目标非目录；getdents64 非 fd 目录 |
| 21 | EISDIR | read 目录；open 目录写 |
| 22 | EINVAL | 参数非法（空路径、lseek whence、缓冲不足…） |
| 25 | ENOTTY | ioctl 非 console |
| 29 | ESPIPE | console 上 lseek |
| 30 | EROFS | 只读文件系统上写打开/写文件 |
| 38 | ENOSYS | 未知调用号；内核态 int 0x80 |
| 110 | ETIMEDOUT | ping/ARP/TCP/HTTP 超时 |
| 111 | ECONNREFUSED | TCP 收到 RST |

## 4. 用户态怎么发一个系统调用

Zig（`userland/lib/zos.zig` 已封装好）：

```zig
const zos = @import("lib/zos.zig");
// 直接走封装：
const n = zos.read(0, &buf);
// 或裸调（示例：time）：
const t = zos.syscall1(zos.SYS_time, 0);
```

C（经 libc，或直接内联汇编）：

```c
#include <unistd.h>          /* read/write/... 直接可用 */
long t = time(0);            /* libc 封装 */
```

裸汇编形式（便于理解 ABI）：

```asm
mov rax, 39          ; getpid
int 0x80             ; rax = pid
```

## 5. 新增一个系统调用的步骤

以"读取开机毫秒数 `zos_uptime`（nr=504）"为例：

1. `kernel/syscall.zig`：定义 `const SYS_zos_uptime = 504;`，
   在 `handle()` 的 switch 里加分支：
   ```zig
   SYS_zos_uptime => @intCast(@import("pit.zig").uptimeMs()),
   ```
2. （可选）`userland/lib/zos.zig` 加封装：
   ```zig
   pub fn uptimeMs() i64 { return syscall1(504, 0); }
   ```
3. C 程序想用则在程序里 `extern long zos_uptime(void);`
   并在 libc 里补一个导出（参考 `netPing` 风格）。
4. 写个用户程序验证，`build.zig` 的 `user_progs` 列表加名字，
   重新 `zig build iso`。

复杂调用（需要阻塞/换页表的）参考 `sysNanosleep`（阻塞）与
`sysExecve`（改地址空间）的写法。

## 6. 已知限制

- 无信号（无 kill/信号量/进程组）——Ctrl-C 终止前台进程是练习 3；
- 无管道/无 socket——网络只能经 501-503 扩展调用；
- execve 失败时已建的新地址空间会泄漏（练习：补清理）；
- getdents64 假设调用方缓冲足够大（ls 用 4KB）；
- read/write 单次上限 64KB；
- 无 environ；fchmod/fchown 无（chmod/chown/unlink/mkdir/rmdir 已有）。

## 7. ZOS 扩展调用（500 段 + 窗口服务 510 段）

| 号 | 语义 |
|---|---|
| 505 | zos_beep(freq, ms)：阻塞正弦单音 |
| 506 | zos_wav(path)：读文件播 WAV（RIFF/PCM，重采样归一到 48k S16） |
| 507 | zos_sound(kind)：系统音效 0 startup 1 click 2 open 3 close 4 ding 5 error 6 tada |
| 509 | zos_volume(pct)：AC'97 主音量 0..100 |
| 510-515 | win_create/present/poll/wait/color/fmt（窗口服务） |
| 516/517 | win_clip_set/get：系统剪贴板（1KB 文本） |
| 518 | win_resize(cw,ch)：重分配表面（最大化/缩放后应用重画） |
| 519 | win_title(ptr)：改窗口标题 |

事件（win_wait/win_poll 的 WinEvent.kind）：1 PRESS 2 RPRESS
3 RELEASE 4 MOVE 5 KEY 6 CLOSE 7 RESIZE 8 DBL 9 ACTIVATE
10 DEACTIVATE；键盘码 = ASCII/Ctrl+字母(0x01..0x1A) 或私有码
0xF0..0xF8（↑↓←→ Home End PgUp PgDn Del）。
