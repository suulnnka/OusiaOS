# 用户态：crt0、系统调用库、libc 与程序移植

OusiaOS 的用户态目标是双重的：**Zig 写系统工具**（像内核一样直接、
无依赖），以及**让标准 C 程序零修改移植**（真 Unix `wc`、
`curl` 都是活例子）。本文覆盖从进程入口到 libc 的整条链路，
最后给出移植指南。

```
用户程序（.zig 或 .c）
  │ main(argc, argv, envp)
crt0.zig   _start：摆好 SysV 栈布局 → main → exit
  │
  ├─ Zig 路线 ──────────────┬─ C 路线 ─────────────────┐
  │ ousia.zig                 │ libc.zig（Zig 导出 C ABI）│
  │  syscall 封装/printf/   │  + clib.c（C 的 printf    │
  │  malloc/字符串           │    全家族 + getopt）      │
  │                         │  + include/*.h 标准头     │
  └──────────┬──────────────┴──────────┬───────────────┘
             └──── int $0x80（内核 -errno）────┘
```

## 1. 进程入口：crt0.zig

内核 execve 后，用户栈顶是 `[argc][argv0][argv1…][NULL]`
（envp 恒为空表）。`_start`（naked 函数）做四件事：

1. 从栈上取 argc/argv，`environ` 指向空表；
2. 存入导出变量 `__argc/__argv`（ousia.zig 的 `argc()/arg()` 读它们）；
3. 栈对齐 16 字节（SysV 要求）后 `call main`；
4. main 返回后 `exit(返回值)`——先跑 atexit 链再陷入内核。

> crt0 同时 `comptime { _ = @import("libc.zig"); }`——
> **Zig 程序也因此获得完整 C 符号**，Zig/C 互调零成本。

## 2. Zig 程序路线：ousia.zig

`userland/lib/ousia.zig` 是内核之外的第二把"瑞士军刀"：

- **系统调用封装**：`syscall0/1/3/5` 内联汇编 + POSIX 风格函数
  （read/write/open/fork/execve/waitpid/getcwd…）；
- **printf**：comptime 展开的格式化（`{s}/{d}/{x}/{c}` +
  `{s:<10}`/`{d:>6}` 宽度对齐），4KB 缓冲一次 write；
- **malloc 家族**：K&R 空闲链表（见 §4.1）；
- **argv 工具、字符串工具、parseIp、网络扩展调用封装**；
- **自定义 panic 命名空间**：std 默认 panic 打印器在 freestanding
  上直接 `@trap` 吞掉信息，必须逐个实现 panic 钩子路由到自己的
  printf（README 踩坑 8，源码注释很详细）。

写一个新 Zig 命令的骨架：

```zig
const ousia = @import("lib/ousia.zig");
comptime { _ = @import("lib/crt0.zig"); }   // 拉入 _start

export fn main() i32 {
    ousia.printf("hello {s}, pid={d}\n", .{"ousia", ousia.getpid()});
    return 0;
}
```

## 3. C 程序路线：libc

### 3.1 组成

| 文件 | 角色 |
|---|---|
| `userland/lib/libc.zig`（Zig） | 导出 C ABI 符号：string/ctype/stdlib/errno/unistd/dirent/stdio(FILE) |
| `userland/lib/clib.c`（C） | printf 全家族（真 va_list）+ getopt |
| `userland/include/*.h` | 标准头：stdio/string/stdlib/ctype/errno/unistd/fcntl/time/dirent/assert/sys/stat.h |
| `userland/lib/crt0.zig` | _start（两种语言共用） |

### 3.2 语义约定

- **errno 转换**：内核 -errno → C 的"返回 -1 + 设 errno"
  （`check()` 函数）；`strerror` 带消息表；`__errno_location`
  供 `errno` 宏展开；
- **stdio**：`FILE*` 流（fopen 解析 r/w/a 标志——写模式只对
  console 有效，普通文件 EROFS；fopen/fgets/fread/fwrite/fputs/
  fflush/fclose…，FILE 无用户态缓冲，内核 tty 自带行缓冲），
  stdin/stdout/stderr 映射 fd 0/1/2；
- **printf 家族**：printf/fprintf/sprintf/snprintf/dprintf/v 系列，
  支持宽度/精度/左右对齐/零填充与 `l ll z h` 长度修饰符——
  用真 C `va_list` 实现，格式引擎只写一份，输出统一走 Sink
  抽象（fd 或缓冲区）；
- **dirent**：opendir/readdir/closedir，包装 getdents64；
- **杂项**：qsort（需要 memcpy 逐元素交换）、atexit、getopt、
  strdup/strtok、rand/srand、abort、assert。

### 3.3 两个必须知道的坑（源码有注释）

1. **mem 三兄弟必须 volatile 写入**：`memcpy/memset/memmove`
   循环里若用普通写入，LLVM 死存储消除会判断"经转换指针的
   写入无读者"而整段删除——memset 变成跳回自己的空循环
   （README 踩坑 7）。
2. **`zig cc -nostdlib` 不链 compiler_rt**：`__zig_probe_stack`
   之类的内部符号要 libc 自备；栈探针长度经 **rax** 传递
   （zig 内部 ABI，不走 SysV，README 踩坑 6）。

## 4. malloc 实现（ousia.zig，libc 的 malloc 也建在其上）

K&R 风格空闲链表分配器：

```
堆区（brk 向内核要页，按 16 字节对齐）：
[Header|数据…][Header|数据…]…    Header{size, free, next}
```

- **malloc**：空闲链表**首次适应**；剩余 ≥ 最小块（头+16B）
  则分裂；找不到→`brkGrow` 顶部追加（不足一页向上取整）；
- **free**：标记空闲 + 一遍扫描合并**地址相邻**空闲块
  （链表按地址序，邻居即 next）；
- **calloc/realloc**：乘法溢出检查 / 分配-拷贝-释放。

## 5. shell（sh.zig）

PID 1，循环 `read(行) → fork → execve → waitpid`：

- **内建命令**（不 fork）：`cd/pwd/help/exit/clear`；
- **外部命令**：非 `/` 开头自动拼 `/bin/` 前缀；子进程
  execve 失败打印错误并 exit(127)（Unix 惯例）；
- 提示符 `{cwd} $ `；Ctrl+C 被 tty 行规程转成行终结符，
  shell 看到空行继续（真正的信号终止是练习 3）。

Zig 与 C 程序在 shell 眼里完全一样：fork 出来的子进程
execve 一个 ELF，语言无关。

## 6. 移植一个 C 程序（三步）

```bash
# 1) 源码放进 userland/foo.c —— #include 原样保留
# 2) build.zig 的 c_progs 列表加 "foo"
# 3) zig build iso && zig build run
```

实际编译命令（build.zig 生成）：

```bash
zig cc -target x86_64-freestanding -O1 -nostdlib -no-pie \
      -fno-stack-protector \
      -Iuserland/include -Wl,--script=userland/user.ld -Wl,-e,_start \
      -o zig-out/bin/user/foo userland/foo.c zig-out/lib/libousia.a
```

要点：

- **静态 ELF，基址 0x400000**（user.ld），无 PIE；
- 链接 libousia.a（libc.zig+clib.c+crt0 打包）；
- 新程序自动进 initrd（mkinitrd.sh 合并 zig-out/bin/user → /bin/）；
- 也可用自研 C 工具链 **occ**（OusiaC 项目，`../ccompiler`，原名 zcc）
  替代 zig cc：`occ userland/foo.c -o zig-out/bin/user/foo`——
  occ 自带汇编器 oas + 链接器 old，直接链接 libousia.a，一步出可执行文件。

### 6.1 现成示例

| 程序 | 语言 | 演示内容 |
|---|---|---|
| `wc.c` | C | 真 Unix wc 移植（-c/-l/-w），stdio 读文件 |
| `cdemo.c` | C | libc 全家桶自检：printf/字符串/qsort/malloc/atexit/getopt |
| `curl.c` | C | HTTP 客户端：标准 C + 一个 `ousia_http_get` extern 扩展调用 |

### 6.2 移植边界（动手前先对照）

| 边界 | 影响 | 绕行 |
|---|---|---|
| 无环境变量 | getenv 恒 NULL，`**environ` 为空表 | 配置走 argv/文件 |
| 文件系统只读 | fopen("w") 失败（EROFS）；无临时文件 | 输出到 stdout |
| 无信号 | signal() 无；Ctrl+C 不杀进程 | 交互程序自己查输入 |
| 无 locale / 无多字节 | setlocale 无效；UTF-8 原样透传（串口） | — |
| clock() 未实现 | 返回 0（无 CPU 时间概念；time() 可用） | 用 time() |
| 无线程/fork-only | 无 pthread | fork+fd 通信（fd 会跨 fork 保留） |
| 单次 read/write ≤64KB | 大块 IO 自己循环 | — |
| 阻塞网络仅 501-503 | 无 socket API | 参照 curl.c 用扩展调用 |

### 6.3 常见移植问题排查

| 症状 | 原因 |
|---|---|
| 链接错 `undefined reference to __aeabi_*/__multf3` | 缺 compiler_rt 符号：在 libc 侧补实现（参考已有导出） |
| printf 输出乱码/丢字 | 检查是否用了 `%lf` 之外的浮点——本 printf **不支持浮点** |
| 崩溃在 main 之前 | 栈溢出（大局部数组）或未对齐——减小缓冲/检查静态初始化 |
| 改了源码跑的还是旧逻辑 | build.zig 系统命令缺 addFileInput，不跟踪源码变化（README 踩坑 9） |
| fopen 返回 NULL | 文件不在 initrd：确认 `tar -tf build/initrd.tar` 里有它 |

## 7. 已装进 /bin 的程序清单

| 命令 | 语言 | 一句话 |
|---|---|---|
| sh | Zig | shell（init 进程） |
| ls / cat / echo | Zig | 基础文件操作 |
| ps | Zig | ousia_psinfo 展示进程表 |
| uname | Zig | 系统信息 |
| sleep | Zig | nanosleep |
| hello | Zig | 最小程序样例 |
| forkdemo | Zig | fork 并发演示（父子交替打印） |
| ping / ifconfig | Zig | ousia_ping / ousia_net_info |
| wc | C | Unix wc 移植 |
| cdemo | C | libc 自检 |
| curl | C | HTTP 客户端 |
| mkdir / rm / df | Zig | 目录创建 / 删除（-d 删空目录）/ 文件系统概要 |
| play | Zig | 播放 WAV（SYS_ousia_wav，内核解析 RIFF + AC'97 DMA） |
| fm / note / paint / calc / mine / cp | Zig | 用户态 GUI 应用（lib/win.zig 窗口库） |
