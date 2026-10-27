# 网络栈

ZOS 内置一套可在 QEMU user 网络下**真实工作**的教学网络栈：
`ping` 与 `curl http://example.com/` 都能跑通。分三层实现——
PCI 枚举（`kernel/pci.zig`）→ e1000 驱动（`kernel/e1000.zig`）→
协议栈（`kernel/net.zig`）。

```
用户态                          内核
──────                          ────
ping / curl                     zos_ping(501) / zos_http_get(502)
  │                               │
  │                            net.zig：会话大锁 + 阻塞等待
  │                              ├ HTTP：拼请求/找 \r\n\r\n
  │                              ├ TCP：三次握手/停等/重传/挥手
  │                              ├ DNS：UDP 查 A 记录
  │                              ├ ICMP：echo request/reply
  │                              ├ ARP：MAC 解析（8 项缓存）
  │                              └ IPv4：校验和/分发
  │                            e1000.zig：描述符环 DMA 收发
  │                            pci.zig：找设备/映射 BAR/总线主控
  ▼
QEMU user 网络：guest 10.0.2.15/24  gw 10.0.2.2(=宿主回环)  dns 10.0.2.3
```

## 1. 地址模型（QEMU user 网络固定值）

| 地址 | 值 | 说明 |
|---|---|---|
| 本机 IP | 10.0.2.15/24 | `net.IP_OUR`，硬编码 |
| 网关 | 10.0.2.2 | **即宿主机回环**：宿主上起服务，guest 直接访问 |
| DNS | 10.0.2.3 | QEMU 内置 DNS 代理 |

- IP 常量用**主机序 u32，首段在最高字节**（10.0.2.15 = 0x0A00020F）；
  `parseIp` 遵循同一约定。两处约定不一致时症状极其迷惑
  （README 踩坑 14：ICMP 能通而 ARP 全歪）。
- `nextHop(ip)`：同网段直连，否则走网关。

**本机与宿主互访的最短实验**：

```bash
# 宿主机
python3 -m http.server 8099
# ZOS shell（10.0.2.2 就是宿主机）
curl http://10.0.2.2:8099/hello.txt
```

`scripts/test.py` 的集成测试正是这么做的（自动起桩 httpd）。

## 2. PCI 枚举（pci.zig）

- 配置空间访问：0xCF8 写 32 位地址（bit31 使能 | 总线 | 设备 |
  功能 | 偏移），0xCFC 读写数据；
- 扫描 0 号总线 32 设备 × 8 功能，找 **vendor 0x8086 / device
  0x100E**（QEMU 默认 e1000）；
- BAR0 探测：写全 1 读回，数低位零个数即尺寸
  （`barSize`，只支持 32 位 MMIO BAR）；
- `vmm.mapMMIO` 把 BAR 物理地址映射进内核 MMIO 窗口；
- **`enableBusMaster`**：PCI COMMAND 寄存器置 bit2。
  不开的话寄存器一切正常、描述符也"被消费"，但 DMA 数据全空——
  README 踩坑 10，经典中的经典。

## 3. e1000 驱动（e1000.zig）

### 3.1 描述符环

网卡与 CPU 通过**环形数组**协作，环与缓冲区都在物理内存，
网卡经 DMA 直接读写：

```
TX（发送）                              RX（接收）
CPU: 填描述符{addr,len,cmd}             网卡: DMA 收包进缓冲区
     写 TDT "踢"网卡                        置 DD 位(完成)
网卡: 读描述符 → DMA 取数 → 发送         CPU: 轮询发现 DD → 取包
     完成后回写状态                          写 RDT 归还缓冲区
```

- 规模：RX 64 描述符 × 2KB 缓冲；TX 16 描述符；缓冲区逐个
  从 PMM 分配整页帧；
- 描述符环静态分配于 .bss（`align(4096)`，物理连续性由链接保证，
  RDBAL/TDBAL 只填低 32 位——地址必须 <4GB）；
- 发送用 `tx_bounce` 私有副本：DMA 期间调用者的缓冲不能变；
- 收包路径 `recv()/reclaim()`：返回**驻留在驱动缓冲里的切片**，
  处理完（`poll` 里调 `net.handleFrame`）后归还。

### 3.2 初始化寄存器序列

```
CTRL.RST 复位 → 读 RAL/RAH 出厂 MAC → 多播表清零
RDBAL/RDLEN/RDH/RDT   配 RX 环（RDT=N-1：0..N-2 可用）
TDBAL/TDLEN/TDH/TDT    配 TX 环
RCTL = 0x04008002      EN|BAM(接收广播)|SECRC(硬件去 CRC)
TCTL = 0x0004010A      EN|PSP|最小碰撞参数
TIPG  = 0x0060200A     标准帧间隔
```

### 3.3 轮询模式

收包不靠网卡中断，而是在 **IRQ0 时钟中断里 `poll()`**（每次最多
64 帧）；阻塞等待路径上也轮询（见 §4.2）。原因：
QEMU 的设备中断在连续字节/包场景有投递竞态，教学内核干脆
用 100Hz 轮询兜底——延迟对交互无感知。改成真中断是经典练习。

**初始化时序的坑**：QEMU 的 e1000 模型在写 RCTL 后武装一个
1 秒 flush 定时器，期间收包在网络层排队不投递（读 QEMU 的
e1000.c 才知道）——`main.zig` 开机等 2 秒再做网络自检正是等它过期。

## 4. 协议栈（net.zig）

### 4.1 分层与分发

发送逐层封装 `sendEth ← sendIp ← sendTcp/Udp/Icmp`；
接收在 `handleFrame` 里按 ethertype → 协议号逐层剥开分发：

```
以太网 ethertype: 0x0806 → handleArp   0x0800 → IPv4 头校验
IPv4 proto:       1=ICMP → handleIcmp（echo 应答/被 ping 应答）
                  17=UDP → handleUdp（只认 dport 40000 的 DNS 应答）
                  6=TCP  → handleTcp（只认当前会话的四元组）
```

报文头用 `extern struct` 直接覆盖内存（`*align(1)` 指针转换），
**唯独 ARP 手工序列化**——sha[6]u8 后接 u32 会被 Zig 插 2 字节
对齐填充，字段全体错位（README 踩坑 11，抓包看到 0xAA 混进 SPA）。

**校验和的字节序**：Internet 校验和在大端"字空间"运算，
`checksum()` 返回的 u16 是大端语义值，写回 extern struct 字段
（小端落盘）必须再 `htons` 一次，否则"值对字节反"
（README 踩坑 12）。TCP 校验和还要拼 12 字节伪头。

### 4.2 阻塞等待模型（会话大锁）

内核侧网络是**同步阻塞**风格，一次只有一个会话持有 `net_lock`
（大内核锁的教科书案例）：

```zig
fn waitTick() void {          // "睡一个 tick 再看"
    e1000.poll();             // 睡前轮询
    asm sti; asm hlt; asm cli;// 等时钟中断唤醒
    e1000.poll();             // 醒后轮询
}
```

所有等待（ARP 应答、ping 回包、DNS、TCP ACK）都基于
`waitCond(ms, cond)`：`pit.ticks` 计时 + `waitTick` 轮询。
用户态视角是阻塞系统调用；内核视角是"关着中断的会话循环里
周期性醒来收包"。

### 4.3 ARP

- 8 项静态缓存表（ip/mac/valid）；
- `arpResolve`：查缓存未命中→广播请求，300ms 窗口重试 3 次；
- 收到请求（目标是本机 IP）→ 更新缓存 + 单播应答；
  收到应答 → 更新缓存。**ZOS 也能被 ping**（应答 ICMP echo）。

### 4.4 ICMP（ping）

- 请求载荷塞 8 字节发送时刻（`pit.uptimeMs()`），应答原样带回，
  差值即 RTT；
- `ping(ip, seq)`：先 ARP，再发 echo，1 秒窗口等匹配的
  (ip, seq) 应答；返回 RTT 毫秒或 -110。

### 4.5 UDP + DNS

- UDP 发送校验和填 0（IPv4 允许不校验）；
- DNS 客户端：本地端口 40000，事务 id 0x1234，查询 A/IN 记录；
  应答解析跳过 QNAME（处理 0xC0 压缩指针），取第一条 A 记录；
  500ms × 2 次重试；
- `resolve(host)`：像点分 IP 直接 `parseIp`，否则走 DNS。

### 4.6 TCP（停等教学实现）

单会话状态机（`TcpState`），不做滑动窗口/拥塞控制：

```
idle → syn_sent →(SYN+ACK)→ established →(对端 FIN)→ fin_wait → done
```

- **握手**：发 SYN（iss 由时钟生成），500ms×3 重试；收到 SYN+ACK
  回 ACK；
- **发送**：每段最多 536 字节数据；发出后记入 `unacked`，
  1 秒等 ACK，超时序号退回重发（最多 4 次）——**停等**：
  同一时刻只有一段未确认；
- **接收**：只收按序段（seq==rcv_nxt），乱序丢弃（停等世界里少见）；
  追加进 64KB 接收缓冲；每收一段（含 FIN）立即回 ACK；
- **挥手**：主动发 FIN|ACK，等对端 ACK 或自身进入 done；
  收 RST 直接放弃（-111）。

### 4.7 HTTP

`httpGet(host, port, path, out)` 一条龙：

```
lock → resolve(host)（IP 或 DNS）→ ARP 网关
    → 三次握手 → 发 "GET path HTTP/1.0\r\nHost: host\r\n\r\n"（带重传）
    → 收响应直到 FIN/缓冲满/15s 超时 → 挥手 → unlock
    → 拷贝 out 返回长度（失败 -110/-111/-11）
```

用 HTTP/1.0 是为了依赖"响应结束=连接关闭"的简单语义。
`curl`（C 程序）解析 `\r\n\r\n` 分离头与 body。

## 5. 收包的两条入口

| 入径 | 时机 | 路径 |
|---|---|---|
| 时钟轮询 | IRQ0 每 10ms | `trapDispatch → e1000.poll() → net.handleFrame` |
| 阻塞等待 | 网络会话内 | `waitTick → e1000.poll() → net.handleFrame` |

这意味着**空闲时到达的包**（如测试机发的 ARP）也能进协议栈，
不只服务于当前会话。

## 6. 常量速查

| 常量 | 值 | 位置 |
|---|---|---|
| RX/TX 描述符 | 64 / 16 | e1000.zig |
| 缓冲区 | 2048B/帧（覆盖 MTU 1514） | e1000.zig |
| ARP 缓存 | 8 项；解析 300ms×3 | net.zig |
| ping 超时 | 1s | net.zig |
| DNS | 端口 40000→53，500ms×2 | net.zig |
| TCP 段上限 | 536B 数据；发送窗口通告 4096 | net.zig |
| TCP 重传 | 1s 等 ACK ×4；接收缓冲 64KB | net.zig |
| HTTP 总超时 | 15s | net.zig |

## 7. 扩展练习方向

1. **中断驱动收包**：e1000 挂 IRQ（PCI 配置空间 0x3C 读中断线），
   IMS 开 RXDMT0/RXT0，IDT 挂处理程序；
2. **滑动窗口**：把停等改成 Go-Back-N，`unacked` 变窗口数组；
3. **多会话**：TcpState 变表，支持并发连接（需要锁细化）；
4. **socket 系统调用**：把 501-503 泛化成 socket/connect/send/recv。
