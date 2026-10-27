# 构建、运行、测试与调试

## 1. 依赖

| 工具 | 用途 | 安装 |
|---|---|---|
| zig 0.17.0 | 编译内核与所有用户程序 | [官网](https://ziglang.org) 下载 |
| qemu-system-x86_64 | 运行内核 | `apt install qemu-system-x86` |
| grub-mkrescue | 打包可引导 ISO | `apt install grub-pc-bin xorriso` |
| mtools | grub-mkrescue 的 FAT 工具 | `apt install mtools` |
| python3 | 自动化测试脚本 | 系统自带 |
| tar | 打 initrd | 系统自带 |

## 2. 构建系统（build.zig）

```
zig build            编译内核 → zig-out/bin/zos-kernel.elf
                     + 用户程序 → zig-out/bin/user/* + zig-out/lib/libzos.a
zig build iso        上述 + mkiso.sh → build/zos.iso
zig build run        iso + run.sh（QEMU 无头串口模式）
zig build test-run   iso + scripts/test.py（自动化集成测试）
```

构建管线拆解：

```
kernel/main.zig ──(LLVM 后端, mcmodel=kernel, no-red-zone,
                   linker.ld, boot.S 汇编)──► zos-kernel.elf
userland/*.zig  ──(ReleaseSafe, user.ld)──►  zig-out/bin/user/<name>
userland/lib/*  ──(Zig+C 混编静态库)────►    zig-out/lib/libzos.a
userland/*.c    ──(zig cc -nostdlib + libzos.a)► zig-out/bin/user/<name>
rootfs/ + zig-out/bin/user ──(mkinitrd.sh, ustar tar)──► build/initrd.tar
kernel + initrd.tar + grub.cfg ──(mkiso.sh: grub-mkrescue)──► build/zos.iso
```

几个构建细节（build.zig 注释均有说明）：

- **内核**：freestanding、`code_model=kernel`（高端地址寻址）、
  **关 red-zone**（中断帧会覆盖它）、use_llvm（自研后端不支持
  port I/O 指令）；
- **用户程序**：同样 freestanding + 关 red-zone（保持简单；
  理论上用户态中断切内核栈后可用 red-zone）；
- **C 程序**是 `addSystemCommand` 调 `zig cc`——注意
  **必须 addFileInput**，否则构建系统不跟踪 .c 源码变化，
  出现"改了代码跑的还是旧二进制"的灵异现象（README 踩坑 9）。

### 2.1 增删一个用户程序

- Zig 程序：`userland/<name>.zig` + `build.zig` 的
  `user_progs` 列表加 `"<name>"`；
- C 程序：`userland/<name>.c` + `c_progs` 列表加名字；
- 删除即从列表去掉；重跑 `zig build iso`，initrd 自动更新
  （mkinitrd.sh 合并 rootfs/ 与 zig-out/bin/user/）。

### 2.2 产物位置

| 产物 | 路径 |
|---|---|
| 内核 ELF（带符号，可 gdb） | zig-out/bin/zos-kernel.elf |
| 用户程序 | zig-out/bin/user/* |
| libc 静态库 | zig-out/lib/libzos.a |
| initrd tar | build/initrd.tar |
| 可引导 ISO | build/zos.iso |

## 3. 运行

### 3.1 无头串口模式（默认，推荐）

```bash
zig build run        # 或 ./scripts/run.sh
```

等价于：

```bash
qemu-system-x86_64 -cdrom build/zos.iso -m 256M \
    -display none -serial stdio -no-reboot \
    -netdev user,id=n0 -device e1000,netdev=n0
```

串口（COM1）就是完整终端：内核日志 + shell 交互共用。
退出：**Ctrl-A X**。`run.sh` 末尾的 `"$@"` 允许追加 QEMU 参数，
例如 `-d int -D /tmp/qemu.log`。

### 3.2 VGA 图形模式（键盘输入）

```bash
qemu-system-x86_64 -cdrom build/zos.iso -m 256M
```

VGA 文本屏 + PS/2 键盘；串口仍有镜像输出。

### 3.3 常用运行时参数

| 需求 | 参数 |
|---|---|
| 更多内存 | `-m 512M`（注意直接映射上限 2GB） |
| 无网络 | 去掉 `-netdev/-device`（内核会打印 no NIC found 并继续跑） |
| 内核异常日志 | `-d int,cpu_reset -D /tmp/qemu.log` |
| GDB 调试 | `-s -S`（见 §5.3） |

## 4. 自动化测试（scripts/test.py）

```bash
python3 scripts/test.py                 # 默认命令集
python3 scripts/test.py uname -a ls /   # 自定义命令序列
zig build test-run                      # 等价（先构建 ISO）
```

工作原理：

1. 起**桩 HTTP 服务**（宿主 127.0.0.1:8099，含 hello.txt——
   guest 眼中即 10.0.2.2:8099）；
2. 用 **PTY** 承载 QEMU 串口（`-serial stdio` 接 pty 主端），
   规避管道与 chardev 的兼容性问题；
3. 等 `$ ` 提示符（30s 启动超时）→ 逐条发命令 → 每条等
   提示符回来（15s 超时）；输出全程 tee 到宿主终端；
4. 全部通过返回 0，任一超时返回 1。

默认命令集覆盖：`uname/ls/cat/echo/ps/forkdemo/hello/cdemo/
wc/ifconfig/ping/curl`——即"内核+进程+C 移植+网络"四条线各
有代表用例。CI 里就是一行 `zig build iso && zig build test-run`。

**加自己的用例**：直接把命令追加到参数里即可；要断言输出内容，
目前脚本只检查"命令返回提示符"（时长隐含成功），需要更强
断言可扩展 `read_until` 的 pattern 匹配。

### 4.1 GUI 截图验证（scripts/guishot.py）

GUI 无法走串口断言，用无头截图代替（详见 [gui.md §7](gui.md#7-自动化截图scriptsguishotpy)）：

```bash
python3 scripts/guishot.py    # 开机→悬停→菜单→About→拖动，产物 /tmp/zos-shot-*.png
```

原理：QEMU monitor 走 unix socket（`-monitor unix:…,server,nowait`），
HMP 的 `mouse_move`/`mouse_button`/`screendump` 驱动交互与截图，
PPM 由脚本内置的 zlib 编码器转 PNG（无第三方依赖）。

## 5. 调试

### 5.1 串口即日志

`-serial stdio` 下 COM1 是唯一的日志与交互通道；
`console.kprintf` 的输出（启动横幅、mmap、pmm/vmm 统计、
tarfs 条目、e1000 MAC、tick 报告）全部在这里。
用户态的 printf/zos.printf 也走 write(1) → console → 串口。

### 5.2 异常现场

内核异常（idt.zig 的 `exception()`）打印：

```
!!! EXCEPTION: vector 14 (#PF 页错误)
  RIP=… CS=… RFLAGS=…
  RSP=… RBP=… ERR=… CR2=… (present write user)
  RAX/RBX/RCX/RDX/RSI/RDI/R8-R11/CR3=…
```

配合 QEMU 侧日志定位第一现场：

```bash
qemu … -d int,cpu_reset -D /tmp/qemu.log
grep -n check_exception /tmp/qemu.log | head    # 找第一条异常
```

用户态进程的致命异常（野指针等）不会停机：内核打印
`[signal] pid N killed: vector M rip=…` 后杀掉该进程继续运行。

### 5.3 GDB

```bash
# 终端 1
qemu-system-x86_64 -cdrom build/zos.iso -m 256M -display none \
     -serial stdio -s -S -netdev user,id=n0 -device e1000,netdev=n0
# 终端 2
gdb zig-out/bin/zos-kernel.elf
(gdb) target remote :1234
(gdb) b zos_start
(gdb) c
```

zos-kernel.elf 带完整符号，可直接对 Zig 函数下断点。
注意：入口断在 16 位实模式→32 位（boot.S 前半）时符号还不可用，
长模式跳板完成后（`zos_start` 起）体验正常。

### 5.4 看 initrd 与产物

```bash
tar -tf build/initrd.tar          # initrd 里有什么
objdump -d zig-out/bin/zos-kernel.elf | less
readelf -l zig-out/bin/user/sh    # 用户程序段布局（0x400000 起）
```

### 5.5 "改了没生效"排查顺序

1. `zig build` 是否真的重编了目标文件（看时间戳）；
2. `build/zos.iso`、`build/initrd.tar` 是否重新生成
   （iso 步骤依赖 install，但**外部脚本改动不会自动触发**，
   必要时 `rm -rf build && zig build iso`）;
3. C 程序：确认 build.zig 的 cc 步骤 addFileInput 覆盖了源文件；
4. QEMU 是否用了你以为的 ISO（绝对路径 `-cdrom`）。

## 6. 常见故障速查

| 症状 | 常见原因 |
|---|---|
| GRUB 后无任何输出 | ISO 没带内核；串口没接（-serial stdio） |
| `no initrd module` | grub.cfg 缺 module2；mkinitrd.sh 没跑 |
| `no /bin/sh … in initrd` | 用户程序没编译/没进 tar：查 zig-out/bin/user 与 tar -tf |
| `no NIC found` | QEMU 没加 e1000；无网络系统照常跑，501-503 返回 ENODEV |
| ping 通不了 10.0.2.2 | QEMU user 网络被改；宿主防火墙拦 ICMP（罕见） |
| curl 超时 | 目标不支持 HTTP/1.0 短连接；或 15s 总超时太短（大页面） |
| 键盘无输入（VGA 模式） | 焦点不在 QEMU 窗口 |
| 三重故障重启循环 | 开 `-d int -D log` 找第一条异常；多为页表/栈错位 |
