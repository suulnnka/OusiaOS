# 图形界面：合成器、窗口管理与内核应用

ZOS 的 GUI 是**内核内**的图形子系统（`kernel/gui.zig` 窗口管理 +
`kernel/apps.zig` 应用分发 + `kernel/apps/<name>.zig` 每应用一个源
文件 + `kernel/mouse.zig` + `kernel/font.zig`）：GRUB 负责切换视频
模式，内核拿到帧缓冲后由**合成器（compositor）**管理分层表面的
绘制与刷新，输入来自 PS/2 鼠标/键盘中断。串口 shell 与 GUI 并行
共存，互不干扰。

```
┌────────────────────────────────────────────────────┐
│                 青绿桌面 (teal)                      │
│  ┌ Terminal ────────────┐  ┌ Minesweeper ┐          │
│  │ / $ ls               │  │ [010]☺[000] │          │
│  │ etc dev bin ...      │  │ ▦▦▦▦▦▦▦▦▦   │          │
│  └──────────────────────┘  └─────────────┘          │
│     ┌ File Manager ───────────────┐                 │
│     │ /etc │ .. │ ▲ │ 预览│  ┌ Paint ─┐┌Calc┐      │
├────────────────────────────────────────────────────┤
│ [ZOS] │ [Files][Note][Term][Paint][Calc][Mines] ⌚   │ ← 任务栏
└────────────────────────────────────────────────────┘
   ▲            ▲                        ▲
   │            └─ 最小化/还原/提层        └─ RTC 实时钟
   └─ 开始菜单：File Manager / Notepad / Terminal /
      Paint / Calculator / Minesweeper / About ZOS

图层（z 序自底向上）：桌面 → 窗口（zorder 置换数组）→ 任务栏
→ 弹出菜单 → 鼠标光标。窗口点击自动提到顶层（活动窗口 = 藏青
标题栏，其余灰色——键盘焦点也归它）。
```

## 1. 视频模式：从 GRUB 到帧缓冲

三步接力，内核自己不碰 BIOS：

1. **内核声明**（`kernel/boot.S`）：Multiboot2 头里放 **framebuffer
   头标签**（type 5，请求 640x480x32）。没有它，GRUB 按 MB2 默认留在
   EGA 文本模式，只给 type=2 的文本标签。
2. **GRUB 设置**（`grub.cfg`）：`insmod all_video` +
   `set gfxpayload=640x480x32`，GRUB 经 VBE 切模式。
3. **内核接收**（`kernel/multiboot.zig`）：解析 framebuffer 信息标签
   （type 8）：帧缓冲物理地址（QEMU 为 0xFD000000）、pitch=2560、
   像素格式（BGR：r@16 g@8 b@0）。

两个真实踩坑（现场都在代码注释里）：

- **MB2 头标签必须 8 字节对齐排布**：framebuffer 标签 20 字节，
  之后的结束标签若不 `.align 8` 补到偏移 40，GRUB 标签遍历错位、
  直接卡死在引导（内核根本不会被加载，串口一个字都没有）。
- **颜色信息在偏移 32 而不是 30**：GRUB 的结构里 bpp/type 两个 u8
  之后垫了 2 字节对齐填充（实测 tag size=38 = 30+2+6），照 spec 抄
  偏移会解析出 r=0/0 的鬼值。

`vmm.mapMMIO` 把帧缓冲映射进内核 MMIO 窗口（它在 4GB 高位，
直接映射区盖不到）。`console` 在初始化前就探测该标签：图形模式下
0xB8000 是帧缓冲开头的别名而非文本屏，VGA 文本路径必须整体跳过
（`console.init(graphical)`）。

## 2. 合成器架构

核心思想：**分层表面画进后备缓冲，只把脏矩形搬去帧缓冲**。

```
状态变化（IRQ12 鼠标 / IRQ0 时钟）
        │ addDamage(rect)          ← 合并成包围盒
        ▼
   ┌──────────── repaint() ────────────┐
   │ clip = damage                       │
   │ 依次绘制（全部图元都按 clip 裁剪）：  │
   │   桌面 → 窗口×N → 任务栏 → 菜单      │
   │   → 光标（最顶层 sprite）            │
   │ blit: backbuf[damage] → LFB         │
   └─────────────────────────────────────┘
```

- **后备缓冲**：`backbuf[640*480]u32`（1.2MB，静态 .bss）。合成结果
  先落这里，帧缓冲只接收最终像素——读-改-写撕裂、层间覆盖全部消解。
- **脏矩形**：全局一个包围盒（多个分散脏区会被合并，教学取舍；
  更精细的实现是脏区列表）。光标移动 = 两个 16×16 小矩形的重绘，
  而不是 1.2MB 全屏搬运。
- **光标是普通层**：12×15 双位图（黑描边+白填充）作为最顶层参与
  合成，遮挡关系自动正确——不需要经典的"保存/恢复光标底图"手法。
- **无锁并发模型**：全部 GUI 状态只在**中断上下文**触碰
  （IRQ12 状态变化即重绘、IRQ0 每秒刷时钟）。中断门自动关 IF，
  处理程序不会嵌套 → 单核无锁。前提：`gui.init` 在 `sti` 之前完成
  （main.zig 的调用点在内存管理之后、网络之前）。

## 3. 绘制原语

全部尊重 `clip`（矩形裁剪）：`setPx/fillRect/hline/vline`、
`bevel1/bevel2`（Win3.1 的 1px/2px 斜面）、`text/textBold`
（8×16 位图字体，MSB=最左像素；"粗体"= 横向错开 1px 画两遍——
如假包换的老办法）。

Win3.1 视觉规格（`gui.zig` 顶部调色板）：

| 元素 | 规格 |
|---|---|
| 桌面 | 青绿 #008080 |
| 控件面 | #C0C0C0 |
| 凸斜面 | 外圈顶/左白、底/右 #808080；内圈顶/左 #DFDFDF、底/右黑 |
| 凹斜面 | 上者反转 |
| 标题栏 | 藏青 #000080 + 白粗体；左侧系统菜单盒（横杠）、右侧▼关闭盒 |
| 菜单 | 白底 1px 黑框 + 右下 2px 灰投影；悬停=藏青底白字；禁用项灰字 |
| 任务栏 | 24px：顶缘白线；ZOS 按钮（按下=凹+文字位移）；蚀刻分隔线；凹时钟面板 |

字体来自系统 PSF 控制台字体（经典 VGA 8×16）：

```bash
python3 scripts/genfont.py /usr/share/consolefonts/Uni2-VGA16.psf.gz > kernel/font.zig
```

## 4. 输入：PS/2 鼠标（kernel/mouse.zig）

- 8042 控制器两口复用：键盘（IRQ1）与 aux 鼠标（IRQ12）；
  使能三步：`0xA8` 开 aux 口 → 控制器命令字置 bit1/清 bit5 →
  `0xD4` 前缀发 `0xF6`(默认) + `0xF4`(开始上报)，各等 ACK 0xFA。
- **重写命令字必须保留 bit6** 的 scancode 转换——键盘驱动依赖
  set 1 扫码，动错了键盘全乱。
- 数据包 3 字节 `[flags, dx, dy]`：bit3 恒 1 是同步锚点（初始化期间
  的 ACK 残留字节没有 bit3，进不了状态机）；bit4/5 是 dx/dy 符号；
  屏幕 y 向下、PS/2 y 向上 → 取反。
- **0x60 端口之争**：键盘 IRQ1 处理必须先查状态字 bit5（aux），
  鼠标字节留给 IRQ12——否则 IRQ12 晚到时字节被键盘吞掉、丢包。

## 5. 时钟

任务栏时钟读 **CMOS RTC**（端口 0x70/0x71：等 regA bit7 更新位清零，
处理 BCD 与 12/24 小时制），QEMU 默认给宿主机 UTC。IRQ0 里秒级对比、
变化才记脏区重绘；RTC 读失败退化为开机 分:秒。

## 6. 交互模型（命中测试与输入路由）

左键按下自顶向下：**菜单**（开着时本次点击只作用于它，点外收起）→
**窗口**（沿 z 序找最先命中的；关闭盒 = 隐藏；标题栏 = 开始拖拽；
客户区交给 `apps.onPress` 并记录【鼠标捕获】；任何命中先把窗口提到
z 序顶端）→ **任务栏**（ZOS 按钮 = 弹出菜单；窗口按钮 = 最小化/
还原/提层三态）→ 桌面无操作。右键只转发给最顶层窗口的客户区
（扫雷插旗）。窗口几何与命中共用同一组 Rect 函数（`titleRect`/
`closeBoxRect`/`clientRect`...），绘制和交互永不脱节。

两个超越"点击"的输入模型：

- **鼠标捕获**（paint 用）：左键按下落在某窗口客户区 →
  `app_capture = wi`，按住期间的所有移动事件（`apps.onMove`）
  都归这个窗口，即使光标划出窗口边界——画图连续笔划的基础。
  松开时 `apps.onRelease` 收尾（直线/矩形的橡皮筋此刻定稿）。
- **键盘焦点**（note 用）：keyboard.zig 的所有按键统一进
  `gui.onKey`：活动窗口是记事本时按键归它，否则原样进 tty 行规程
  （串口 shell 的回显/控制字符行为完全不变）。方向键被映射成
  0xF0..0xF3 私有键码，不进 tty（0x11/0x13 是 XON/XOFF，串口
  终端会炸流控）。点任何别的窗口把键盘还给 shell。

## 7. 用户态应用与窗口服务（kernel/winsys.zig + userland/{fm,note,paint,calc,mine}.zig）

ZOS 0.2 起 GUI 应用是**真正的用户进程**：菜单点击在 IRQ12 里
`proc.spawnKernel("/bin/paint")`（中断门 IF=0，与调度器天然互斥），
应用 main() 里 `win_create(w,h,title)` 拿到一块【共享表面】——
一组 pmm 页帧双映射：用户态 RW（syscall 返回的虚拟地址，应用往
里画像素）+ 内核经物理帧直访（合成时逐行搬运，帧不必物理连续，
行跨帧按段拷贝）。权威状态（窗口位置/z 序/可见性）全在内核，
应用无法欺骗合成器——微内核窗口服务的教学缩影。

```
应用主循环（lib/win.zig）           内核
  win.create(w,h,"标题")     ──→   分配表面帧 + 用户映射 + 窗口入表
  loop {                     ←──   事件队列（IRQ12/IRQ1 生产）
    n = win.wait(ev, 500ms)        空队列 → 进程 blocked
    处理事件（press/move/key…）     事件/超时 → 唤醒
    画表面; win.present()    ──→   记脏区，IRQ0 合成上屏
  }
```

**事件路由**：鼠标按下落在用户窗口客户区 → EV_PRESS（客户区坐标）
+ 鼠标捕获（按住期间 EV_MOVE 持续投递，划出窗口也不断——画图连笔）；
右键 EV_RPRESS；松开 EV_RELEASE；**键盘归活动窗口**（EV_KEY，
方向键 0xF0..0xF3 私有码）——点别的窗口即归还串口 shell。
win_wait 空队列时进程 `blocked`（新调度状态），事件到达由 IRQ
唤醒；带 timeout_ms 则到点也醒（记事本光标闪烁、扫雷计时用）。

**生命周期**：关闭盒 → 窗口即刻隐藏 + EV_CLOSE 通知应用退出；
进程 exit（`ppid=0` 的内核孤儿，新 `dying` 状态）由调度器在切走
它的栈后收割（内核栈/页表/表面帧全回收）。

留在内核的只有两个窗口：**Terminal**（控制台三路输出的镜像，
环形行缓冲天然属于内核）与 **About ZOS**（窗口管理器自己的对话框）。

### 五个用户态应用（kernel/apps/ 已清空，全部迁往 userland/）

**fm**（按需拉取）：单击目录进入、`..` 返回、单击文件右栏预览。
目录枚举走 getdents64、内容走 open+read——普通用户进程的一切；
状态栏显示选中项的 `rwxr-xr-x uid:gid` 权限串。条目超 13 行出
滚动条（箭头滚一行、滑轨翻页）。

**term（内核窗口，事件镜像）**：GUI 不另起 shell 会话，而是镜像控制台：

```
键盘 IRQ1 → tty 行规程 → shell(用户态) read/exec
shell printf → console.putChar ─┬─ 串口（无头测试/日志）
                               └─ gui.onConsoleChar → 环形行缓冲
tty 回显同样走 putChar → 敲的字符自动出现在窗口里
```

行缓冲 128 行 × 72 列环形数组，支持硬换行、退格（tty 的
`0x08 ' ' 0x08` 三连回显净效果正确）、TAB、`clear` 的 `ESC[2J`
（极简 ANSI 状态机）。开机日志从第一个字符就在收集，任何时刻打开
Terminal 都能看到完整回滚。光标 0.5s 闪烁（IRQ0 相位）。

这是唯一打破"GUI 状态只在中断上下文触碰"约定的地方：shell printf
发生在进程上下文。两道防线：每字符追加用**关中断的极短临界区**
（`gui.irqSave/irqRestore`，IRQ 上下文里 IF 本来就关，零开销）；
环形缓冲按 SPSC 语义使用。重绘仍只发生在 IRQ0/IRQ12（100Hz tick
保证终端输出最迟 10ms 上屏），`addDamage` 自身也用同一对 cli/sti
保住"读-改-写"的原子性。

**paint**（用户态，位图 + 捕获）：画布是应用自己 .bss 里的位图
（300×200，每像素 1 字节 = 16 色调色板下标）。工具：画笔/橡皮
（Bresenham）、直线/矩形（快照+恢复的橡皮筋预览）、油漆桶（洪泛）。
事件全来自 win_wait，内核捕获语义保证划出窗口也连续画。

**calc**（用户态，f64）：四则/链式/退格/取负/CE/C，浮点显示自写
（整数部分 + 6 位小数去尾零，除零 → Error）。用户态浮点成立的前
提是陷入与上下文切换都保存 XMM 现场（idt.zig 的 TrapFrame XMM 区
块 + proc.zig 的 Context.fpu）——"浮点寄存器归谁"的经典教学点。

**note**（用户态，键盘焦点）：定长行数组 + 光标，Enter 拆行、退格
并行动方向键、滚动跟随、Ln/Col 状态栏、win_wait 超时驱动光标闪烁。

**mine**（用户态，状态机）：9×9/10 雷、首击保护（首格及 8 邻不
布雷）、空白洪泛、右键插旗、雷数/笑脸/计时 LED（SYS_time 计秒，
win_wait(1000) 低频定时）。

## 8. 自动化截图（scripts/guishot.py）

无头验证 GUI 的工具链：QEMU `-monitor unix:…` + HMP 命令
（`mouse_move`/`mouse_button`/`sendkey`/`screendump`），PPM 用纯
Python zlib 转 PNG，光标位置由脚本按相对位移累计（起点 = gui.zig
初始光标 (300,200)）。默认流程覆盖全部七个应用：开机 → 开始菜单 →
File Manager（进 /etc、预览）→ Terminal（`sendkey` 真打一条 `ls`）
→ Paint（选色 + 拖笔划）→ Calculator（1+2=3）→ Notepad（打两行
字，键盘焦点归它、串口不回显）→ Minesweeper（翻格、右键插旗）→
About + 标题栏拖动。

```bash
python3 scripts/guishot.py   # 产物 /tmp/zos-shot-*.png
```

两个坑（都踩过）：HMP `mouse_button` 的位掩码是 PS/2 位序
**1=左 2=右 4=中**（4 会被当忽略的中键）；菜单开着时再点 ZOS 按钮
是"关菜单"而不是"保持打开"，连续开应用要先点桌面收起。

## 9. 已知边界与练习

- 只支持 640×480×32（后备缓冲静态定长；改分辨率 → 按 pitch 动态
  分配帧映射，或改静态尺寸）。
- 窗口固定 7 槽（每应用单例）；无最大化/Alt-Tab。
- Terminal 无输入焦点概念（键盘始终归串口 shell 或记事本），
  不支持翻回滚；记事本不保存（tarfs 只读）。
- 文件浏览器只读；无双击、无超长文件名省略号。
- 练习方向：① 桌面图标 + 双击打开；② 窗口槽动态化（同时开两个
  Terminal）；③ Terminal 回滚（PageUp 翻历史）；④ 记事本保存到
  ramfs + 文件浏览器联动刷新；⑤ 扫雷难度选择与最佳成绩；
  ⑥ 画图工具扩展（刷子形状/填充矩形/撤销栈）。
