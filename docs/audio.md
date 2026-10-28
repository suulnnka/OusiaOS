# 音频子系统：AC'97

OusiaOS 的音频是**内核内**的 AC'97 驱动（`kernel/audio.zig`）+ DDS 正弦
合成器：`beep`/`music` 命令经 `ousia_beep` 扩展系统调用（nr 505）触发
内核阻塞播放。QEMU 侧用 `-device AC97` 提供设备（Intel 82801AA），
任何 audiodev 后端皆可（无后端时静音，驱动靠超时兜底安全返回）。

```
用户态                          内核
──────                          ────
beep 440 500 / music            syscall 505 ousia_beep(freq, ms)
                                  └ audio.playTone（阻塞会话，net 同款）
                                      ├ Synth：DDS 相位累加 → 16bit 立体声 PCM
                                      ├ 播放环：武装 BDL 缓冲、推进 LVI
                                      └ sti/hlt 等时钟醒来看 CIV
                                           │ NABM（总线主控 DMA）
                                           ▼
                                codec(NAM mixer: 音量/48kHz) → 扬声器/wav 后端
```

## 1. 硬件模型：mixer + 总线主控

AC'97 控制器暴露两块 **I/O 端口** BAR（和 e1000 的 MMIO 不同）：

| BAR | 名称 | 作用 |
|---|---|---|
| BAR0 | NAM | 原生音频 mixer：复位(0x00)、主音量(0x02)、PCM 音量(0x18)、DAC 采样率(0x2C) |
| BAR1 | NABM | 原生音频总线主控：三组流（PCM-in/PCM-out/Mic），每组一组 DMA 寄存器 |

PCM-out 流的 NABM 寄存器（本驱动唯一使用的流）：

| 偏移 | 名 | 说明 |
|---|---|---|
| 0x10 | BDBAR | BDL（缓冲描述符表）的物理地址 |
| 0x14 | CIV | 当前描述符索引（只读，DMA 推进，**按 32 取模**） |
| 0x15 | LVI | 最后有效索引：播完此条即停（DCH），写它可以续流 |
| 0x16 | SR | 状态：bit0 DCH=DMA 停机（写 1 清其它位） |
| 0x1B | CR | 控制：**bit0=启动（RPBM）**，bit1=复位流 |

**BDL 条目**（8 字节）：`u32 缓冲物理地址 + u32 ctl_len`
（低 16 位 = 16-bit 样本总数，**原始值不减一**；高 16 位是 IOC/BUP 标志，
本驱动轮询模式不用）。表固定 32 条。

## 2. 与 e1000 的同构性

网卡和声卡是同一类问题的两个方向：**设备按描述符环从内存搬数据**。
e1000 收网络帧，AC'97 送采样。初始化同样三件事：PCI 找设备 →
使能总线主控（DMA 前提，老坑）→ 建描述符环 + 缓冲。区别只在
寄存器访问是端口 I/O（`serial.in16/out16`），以及"流"有启停语义。

## 3. 播放协议（实测校准的三个坑）

```
CR=0 停流 → CR=bit1 复位流 →【重写 BDBAR】→ 预填 buf[0..1]，LVI=1
→ CR=bit0 启动 → 循环{ 读 CIV/SR；补位；sti;hlt;cli } → 播完 DCH → CR=0
```

1. **run 位是 bit0（0x01），复位位是 bit1（0x02）**——想当然按
   "bit7=run" 写了 0x80，DMA 纹丝不动（wav 只剩 44 字节文件头）。
2. **复位流会清掉 BDBAR**——init 时写的基址被 playTone 里的复位抹零，
   必须在复位之后重写。
3. **描述符索引按 32 取模**——BDL 只填 8 条的话，9..31 是未清零的
   垃圾条目（len 随机巨大），DMA 在垃圾里漫游、永不停止（实测录出
   15 秒连续噪音）。正确做法：直接把 32 条全部用满。

（以上均以 QEMU `hw/audio/ac97.c` 实现为 ground truth 校准，
`scripts/audiotest.py` 是回归。）

## 4. 武装协议：距离制

播放环维护"已武装且未播完"的距离 `dist = (LVI - CIV) mod 32`：

- 只在 `dist < 31` 时武装 `(LVI+1)`——该槽恰好是 **CIV 身后刚播完**
  的缓冲，绝不触碰 DMA 排队中的数据（无撕扯）；
- 填充节奏被播放天然限速（每缓冲 21ms，时钟 10ms 醒一次足够）；
- 合成完最后一个样本后停止武装，DMA 播完 LVI 置 DCH，会话结束；
- 停机态下写 LVI 会让设备从 PIV 续播——所以补位即唤醒。

## 5. DDS 正弦合成

```zig
inc = freq << 32 / 48000        // 相位步进：频率就是它
phase +%= inc                    // 32 位回绕天然取模 2π
v = SINE[phase >> 24]            // 256 项 comptime 正弦表
```

- 立体声：左右声道同值交错写（`L R L R ...`）；
- 首尾各 5ms 线性淡入淡出防"咔"声；
- 幅度 10000（约 -10 dBFS）留 headroom；
- `freq=0` 即休止符（相位步进为 0，输出直流 0）。

音量走 mixer：主音量(0x02)与 PCM(0x18) 各写 0x0000（每字节一声道，
0 = 不衰减）；采样率 48kHz 写 DAC rate（0x2C）与 wav 后端一致。

## 6. 用户态接口

| 命令/调用 | 说明 |
|---|---|
| `beep [freq] [ms]` | 单音，默认 440Hz 200ms；参数 20..8000Hz |
| `music` | 《欢乐颂》主题 28 音符（连续 beep + 50ms 气口） |
| `ousia_beep(freq, ms)`（nr 505） | 阻塞播放；返回 0 或 -errno（-19 无设备、-11 忙、-22 参数越界） |

会话互斥：`busy` 标志保证一次只有一个播放（-11 EAGAIN）。
无音频后端（`-audiodev none`）时 DMA 不消费数据，播放环靠
"时长 +1s" 硬超时兜底返回——驱动在任何 QEMU 配置下都不会卡死。

## 7. 验证方法（scripts/audiotest.py）

声音无法走串口断言，验证链是：**QEMU wav 后端把 guest 播的 PCM 录成
宿主机文件**（退出时才完整落盘，须干净关机），再用纯 Python 解析：
时长（↔ 请求时长）、过零率主频（↔ DDS 频率）、RMS（↔ 非静音）。

```bash
python3 scripts/audiotest.py
# [analysis] duration=0.51s freq=441Hz rms=6950
# [PASS] audio: 440Hz/500ms 录音校验通过
```

想亲耳听：`run.sh` 头部注释里给了 pa/wav 后端的配置示例。

## 8. 0.2.0 新增与剩余边界

- **WAV 播放**：playWav 解析 RIFF（只认线性 PCM），把 8/16bit、
  单/立体声、任意采样率归一化到 48kHz S16 立体声（16.16 定点步进
  最近邻重采样），再走与合成共用的 stream() 播放环；
  shell `play <file.wav>` / SYS_ousia_wav(506)。
- **系统音效**：playNotes 的音符序列合成（{频率,毫秒} comptime 表），
  playSystem(kind) 七种——GUI 开机音、FM 打开/删除、扫雷插旗/爆雷/
  新纪录/通关等；SYS_ousia_sound(507)。
- **音量**：mixer 衰减寄存器（0=最大 63=最小）线性换算，
  SYS_ousia_volume(509)；Control Panel 即时调节并写入 /etc/ousia.conf
  （gui.lateInit 开机读回）。
- 仍单会话：两个播放方竞争时后者 EAGAIN（系统音效忙时静默跳过）；
  多路混音器 = 多源求和 + 削波保护，仍是好练习。
- 无录音（PCM-in 流的 BDL 是现成的镜像工作）；
- 无中断驱动：BCIS + IOC 标志可把补位从 100Hz 轮询改成 IRQ。
