//! 网络栈：以太网 / ARP / IPv4 / ICMP / UDP+DNS / TCP(停等) / HTTP GET
//!
//! 教学要点：
//!   - 分层逐字节构造/解析报文（这是理解协议的最短路径）
//!   - 校验和（Internet checksum）：16 位字反码求和再取反
//!   - TCP 用"停等"教学实现：发一段等 ACK，收数据立即 ACK；
//!     完整滑动窗口/拥塞控制是练习
//!   - 阻塞等待用 sti+hlt+cli 模式（时钟醒来后轮询网卡），
//!     一次只有一个进程能持有 net 锁（大内核锁的教科书案例）
//!
//! 地址约定（QEMU user 网络固定值）：
//!   guest 10.0.2.15/24  网关 10.0.2.2（= 宿主机回环）  DNS 10.0.2.3

const console = @import("console.zig");
const e1000 = @import("e1000.zig");
const pit = @import("pit.zig");

// ---------------- 配置 ----------------

const IP_OUR: u32 = 0x0A00_020F; // 10.0.2.15（主机字节序）
const IP_MASK: u32 = 0xFF00_0000 - 0x0100_0000; // 255.255.255.0
const IP_GW: u32 = 0x0A00_0202; // 10.0.2.2
const IP_DNS: u32 = 0x0A00_0203; // 10.0.2.3

const ETH_ARP: u16 = 0x0806;
const ETH_IP: u16 = 0x0800;
const BROADCAST_MAC = [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

var net_lock: bool = false;
var our_mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };
var inited = false;

pub fn init() bool {
    if (!e1000.init()) return false;
    our_mac = e1000.mac();
    inited = true;
    console.kprintf("net: ip 10.0.2.15/24 gw 10.0.2.2 dns 10.0.2.3\n", .{});
    return true;
}

pub fn ready() bool {
    return inited;
}

// ---------------- 小工具 ----------------

inline fn htons(v: u16) u16 {
    return @byteSwap(v);
}
inline fn htonl(v: u32) u32 {
    return @byteSwap(v);
}

/// Internet 校验和：16 位字反码求和取反（尾奇数字节补零）
fn checksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        sum +%= (@as(u32, bytes[i]) << 8) | bytes[i + 1];
    }
    if (i < bytes.len) sum +%= @as(u32, bytes[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

fn ipToString(ip: u32) []const u8 {
    // 10.0.2.15 之类 → 静态缓冲
    var buf: *[16]u8 = &ip_str_buf;
    var n: usize = 0;
    const parts = [4]u8{ (ip >> 24) & 0xFF, (ip >> 16) & 0xFF, (ip >> 8) & 0xFF, ip & 0xFF };
    for (parts, 0..) |p, k| {
        if (k > 0) {
            buf[n] = '.';
            n += 1;
        }
        var tmp: [3]u8 = undefined;
        var tn: usize = 0;
        var v = p;
        if (v == 0) {
            tmp[0] = '0';
            tn = 1;
        }
        while (v > 0) : (v /= 10) {
            tmp[tn] = '0' + @as(u8, @intCast(v % 10));
            tn += 1;
        }
        var j = tn;
        while (j > 0) {
            j -= 1;
            buf[n] = tmp[j];
            n += 1;
        }
    }
    return buf[0..n];
}
var ip_str_buf: [16]u8 = undefined;

/// 点分十进制 → u32（主机字节序），失败返回 null
pub fn parseIp(s: []const u8) ?u32 {
    var ip: u32 = 0;
    var part: u32 = 0;
    var dots: u8 = 0;
    var digits: u8 = 0;
    for (s) |c| {
        if (c == '.') {
            if (dots == 3 or digits == 0 or part > 255) return null;
            ip |= part << @intCast((3 - dots) * 8); // 首段在最高字节（网络序约定）
            dots += 1;
            part = 0;
            digits = 0;
        } else if (c >= '0' and c <= '9') {
            part = part * 10 + (c - '0');
            digits += 1;
            if (digits > 3) return null;
        } else return null;
    }
    if (dots != 3 or digits == 0 or part > 255) return null;
    ip |= part; // 末段在最低字节
    return ip;
}

// ---------------- 锁与等待 ----------------

/// 网络大锁：同一时刻只允许一个内核侧网络会话
fn lock() void {
    while (net_lock) {
        waitTick();
    }
    net_lock = true;
}
fn unlock() void {
    net_lock = false;
}

/// 开中断睡一个 tick 再回来（醒来前后都会轮询网卡）
fn waitTick() void {
    e1000.poll();
    asm volatile ("sti");
    asm volatile ("hlt");
    asm volatile ("cli");
    e1000.poll();
}

/// 等条件成立或超时；期间持续收包
fn waitCond(ms: u64, cond: *const fn () bool) bool {
    const t0 = pit.ticks;
    while (pit.ticks - t0 < ms / 10 + 1) {
        if (cond()) return true;
        waitTick();
    }
    return cond();
}

// ---------------- 发送路径 ----------------

var tx_frame: [1536]u8 = undefined;

const EthHeader = extern struct {
    dst: [6]u8,
    src: [6]u8,
    ethertype: u16,
};

fn sendEth(dst: [6]u8, ethertype: u16, payload: []const u8) bool {
    if (14 + payload.len > tx_frame.len) return false;
    const h: *align(1) EthHeader = @ptrCast(&tx_frame);
    h.* = .{ .dst = dst, .src = our_mac, .ethertype = htons(ethertype) };
    @memcpy(tx_frame[14 .. 14 + payload.len], payload);
    return e1000.send(tx_frame[0 .. 14 + payload.len]);
}

// ARP 报文不能用 extern struct：sha[6]u8 后接 u32 会插 2 字节对齐
// 填充导致字段错位（真实踩坑——抓包看到 aa aa 混进 SPA）。手工序列化。
const ArpPacket = struct {
    htype: u16,
    ptype: u16,
    hlen: u8,
    plen: u8,
    oper: u16,
    sha: [6]u8,
    spa: u32,
    tha: [6]u8,
    tpa: u32,

    fn marshal(self: *const ArpPacket, out: *[28]u8) void {
        out[0] = @truncate(self.htype >> 8);
        out[1] = @truncate(self.htype);
        out[2] = @truncate(self.ptype >> 8);
        out[3] = @truncate(self.ptype);
        out[4] = self.hlen;
        out[5] = self.plen;
        out[6] = @truncate(self.oper >> 8);
        out[7] = @truncate(self.oper);
        @memcpy(out[8..14], &self.sha);
        putU32(out[14..18], self.spa);
        @memcpy(out[18..24], &self.tha);
        putU32(out[24..28], self.tpa);
    }

    /// 从帧解析（帧偏移 14 起，28 字节）
    fn parse(frame: []const u8) ArpPacket {
        var p: ArpPacket = undefined;
        p.htype = (@as(u16, frame[14]) << 8) | frame[15];
        p.ptype = (@as(u16, frame[16]) << 8) | frame[17];
        p.hlen = frame[18];
        p.plen = frame[19];
        p.oper = (@as(u16, frame[20]) << 8) | frame[21];
        @memcpy(&p.sha, frame[22..28]);
        p.spa = getU32(frame[28..32]);
        @memcpy(&p.tha, frame[32..38]);
        p.tpa = getU32(frame[38..42]);
        return p;
    }
};

fn putU32(out: []u8, v: u32) void {
    out[0] = @truncate(v >> 24);
    out[1] = @truncate(v >> 16);
    out[2] = @truncate(v >> 8);
    out[3] = @truncate(v);
}
fn getU32(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

const IpHeader = extern struct {
    ver_ihl: u8,
    tos: u8,
    total_len: u16,
    id: u16,
    frag: u16,
    ttl: u8,
    proto: u8,
    checksum_: u16,
    src: u32,
    dst: u32,
};

const IcmpHeader = extern struct {
    type_: u8,
    code: u8,
    checksum_: u16,
    id: u16,
    seq: u16,
};

const UdpHeader = extern struct {
    sport: u16,
    dport: u16,
    len: u16,
    checksum_: u16,
};

const TcpHeader = extern struct {
    sport: u16,
    dport: u16,
    seq: u32,
    ack: u32,
    off_flags: u16, // 数据偏移(<<12) | 标志
    window: u16,
    checksum_: u16,
    urgptr: u16,
};

const PROTO_ICMP: u8 = 1;
const PROTO_TCP: u8 = 6;
const PROTO_UDP: u8 = 17;

const TCP_FIN: u16 = 0x01;
const TCP_SYN: u16 = 0x02;
const TCP_RST: u16 = 0x04;
const TCP_PSH: u16 = 0x08;
const TCP_ACK: u16 = 0x10;

var ip_id: u16 = 1;

fn sendIp(dst_ip: u32, proto: u8, payload: []const u8) bool {
    const next = nextHop(dst_ip);
    const dmac = arpLookup(next) orelse return false;
    if (20 + payload.len > tx_frame.len - 14) return false;

    // 在 tx_frame 里拼：payload 先落位再补头
    var ipbuf: [1536]u8 = undefined;
    const h: *align(1) IpHeader = @ptrCast(&ipbuf);
    h.* = .{
        .ver_ihl = 0x45,
        .tos = 0,
        .total_len = htons(@intCast(20 + payload.len)),
        .id = htons(ip_id),
        .frag = htons(0x4000), // DF
        .ttl = 64,
        .proto = proto,
        .checksum_ = 0,
        .src = htonl(IP_OUR),
        .dst = htonl(dst_ip),
    };
    ip_id +%= 1;
    h.checksum_ = htons(checksum(ipbuf[0..20])); // 校验和在大端字空间运算，落内存需转网络序
    @memcpy(ipbuf[20 .. 20 + payload.len], payload);
    return sendEth(dmac, ETH_IP, ipbuf[0 .. 20 + payload.len]);
}

// ---------------- ARP ----------------

const ArpEntry = struct { ip: u32, mac: [6]u8, valid: bool };
var arp_table: [8]ArpEntry = undefined;

fn arpLookup(ip: u32) ?[6]u8 {
    for (&arp_table) |e| {
        if (e.valid and e.ip == ip) return e.mac;
    }
    return null;
}

fn arpUpdate(ip: u32, mac: [6]u8) void {
    for (&arp_table) |*e| {
        if (e.valid and e.ip == ip) {
            e.mac = mac;
            return;
        }
    }
    for (&arp_table) |*e| {
        if (!e.valid) {
            e.* = .{ .ip = ip, .mac = mac, .valid = true };
            return;
        }
    }
}

fn sendArp(oper: u8, target_ip: u32, target_mac: [6]u8) bool {
    var p: [28]u8 = undefined;
    const a = ArpPacket{
        .htype = 1,
        .ptype = ETH_IP,
        .hlen = 6,
        .plen = 4,
        .oper = @as(u16, oper),
        .sha = our_mac,
        .spa = IP_OUR,
        .tha = target_mac,
        .tpa = target_ip,
    };
    a.marshal(&p);
    return sendEth(target_mac, ETH_ARP, &p);
}

/// 解析（必要时阻塞请求）目标 IP 的 MAC
fn arpResolve(ip: u32) ?[6]u8 {
    if (arpLookup(ip)) |m| return m;
    var tries: u32 = 0;
    while (tries < 3) : (tries += 1) {
        _ = sendArp(1, ip, BROADCAST_MAC);
        const t0 = pit.ticks;
        while (pit.ticks - t0 < 30) { // 300ms
            if (arpLookup(ip)) |m| return m;
            waitTick();

        }
    }
    return null;
}

fn nextHop(ip: u32) u32 {
    if ((ip & IP_MASK) == (IP_OUR & IP_MASK)) return ip;
    return IP_GW;
}

fn handleArp(frame: []const u8) void {
    if (frame.len < 14 + 28) return;
    const a = ArpPacket.parse(frame);
    if (a.oper == 1 and a.tpa == IP_OUR) {
        // 请求我们 → 应答
        arpUpdate(a.spa, a.sha);
        _ = sendArp(2, a.spa, a.sha);
    } else if (a.oper == 2) {
        arpUpdate(a.spa, a.sha);
    }
}

// ---------------- ICMP ----------------

var icmp_reply: struct {
    valid: bool = false,
    ip: u32 = 0,
    id: u16 = 0,
    seq: u16 = 0,
    rtt_ms: u64 = 0,
} = .{};

var ping_sent_tick: u64 = 0;

fn sendIcmpEcho(dst_ip: u32, id: u16, seq: u16) bool {
    var p: [20 + 16]u8 = undefined;
    @memset(&p, 0);
    const h: *align(1) IcmpHeader = @ptrCast(&p);
    h.* = .{ .type_ = 8, .code = 0, .checksum_ = 0, .id = htons(id), .seq = htons(seq) };
    // 载荷：时间戳低 64 位（回显原样返回）
    const stamp = pit.uptimeMs();
    inline for (0..8) |i| {
        p[8 + i] = @truncate(stamp >> @intCast(8 * i));
    }
    h.checksum_ = htons(checksum(&p));
    return sendIp(dst_ip, PROTO_ICMP, &p);
}

fn handleIcmp(src_ip: u32, ip_payload: []const u8) void {
    if (ip_payload.len < 8) return;
    const h: *align(1) const IcmpHeader = @ptrCast(ip_payload.ptr);
    if (h.type_ == 0) {
        // echo reply：算 RTT（载荷里带回发送时间戳）
        var stamp: u64 = 0;
        if (ip_payload.len >= 16) {
            inline for (0..8) |i| {
                stamp |= @as(u64, ip_payload[8 + i]) << @intCast(8 * i);
            }
        }
        icmp_reply = .{
            .valid = true,
            .ip = src_ip,
            .id = htons(h.id),
            .seq = htons(h.seq),
            .rtt_ms = pit.uptimeMs() -| stamp,
        };
    } else if (h.type_ == 8) {
        // echo request：被 ping → 构造应答（头换成 type 0）
        var buf: [64]u8 = undefined;
        const n = @min(ip_payload.len, buf.len);
        @memcpy(buf[0..n], ip_payload[0..n]);
        const rh: *align(1) IcmpHeader = @ptrCast(&buf);
        rh.type_ = 0;
        rh.checksum_ = 0;
        rh.checksum_ = htons(checksum(buf[0..n]));
        _ = sendIp(src_ip, PROTO_ICMP, buf[0..n]);
    }
}

/// ping 系统调用实现：返回 RTT(ms)，负值为 errno
pub fn ping(dst_ip: u32, seq: u32) isize {
    if (!inited) return -19; // ENODEV
    lock();
    defer unlock();

    if (arpResolve(nextHop(dst_ip)) == null) return -110; // ETIMEDOUT

    icmp_reply.valid = false;
    if (!sendIcmpEcho(dst_ip, 0x5A5A, @intCast(seq))) return -5; // EIO

    // 等匹配的应答
    const t0 = pit.ticks;
    while (pit.ticks - t0 < 100) { // 1s
        if (icmp_reply.valid and icmp_reply.seq == seq and icmp_reply.ip == dst_ip) {
            return @intCast(icmp_reply.rtt_ms);
        }
        waitTick();
    }
    return -110; // ETIMEDOUT
}

// ---------------- UDP + DNS ----------------

var dns_answer: struct {
    valid: bool = false,
    id: u16 = 0,
    ip: u32 = 0,
} = .{};

fn sendUdp(dst_ip: u32, sport: u16, dport: u16, payload: []const u8) bool {
    var p: [512]u8 = undefined;
    if (8 + payload.len > p.len) return false;
    const h: *align(1) UdpHeader = @ptrCast(&p);
    h.* = .{
        .sport = htons(sport),
        .dport = htons(dport),
        .len = htons(@intCast(8 + payload.len)),
        .checksum_ = 0, // IPv4 允许 0（不校验）
    };
    @memcpy(p[8 .. 8 + payload.len], payload);
    return sendIp(dst_ip, PROTO_UDP, p[0 .. 8 + payload.len]);
}

fn handleUdp(src_ip: u32, ip_payload: []const u8) void {
    _ = src_ip;
    if (ip_payload.len < 8) return;
    const h: *align(1) const UdpHeader = @ptrCast(ip_payload.ptr);
    const dport = htons(h.dport);
    const body = ip_payload[8..];
    if (dport == 40000 and body.len >= 8) {
        // DNS 应答：跳过问题段，找第一个 A 记录
        const id = (@as(u16, body[0]) << 8) | body[1];
        var i: usize = 12;
        // 跳过 QNAME
        while (i < body.len and body[i] != 0) {
            if (body[i] & 0xC0 != 0) {
                i += 1;
                break;
            }
            i += 1 + body[i];
        }
        i += 1 + 4; // QNULL + QTYPE/QCLASS
        // 答案段第一条（名字可能是指针 0xC0..）
        if (i + 12 <= body.len) {
            if (body[i] & 0xC0 != 0) {
                i += 2;
            } else {
                while (i < body.len and body[i] != 0) : (i += 1 + body[i] + 1) {}
            }
            if (i + 10 <= body.len) {
                i += 2 + 2 + 4; // TYPE CLASS TTL
                const rdlen = (@as(usize, body[i]) << 8) | body[i + 1];
                i += 2;
                if (rdlen == 4 and i + 4 <= body.len) {
                    var ip: u32 = 0;
                    inline for (0..4) |k| ip |= @as(u32, body[i + k]) << @intCast(8 * (3 - k));
                    dns_answer = .{ .valid = true, .id = id, .ip = ip };
                }
            }
        }
    }
}

/// 解析主机名：点分 IP 直用，否则查 DNS
fn resolve(host: []const u8) ?u32 {
    if (parseIp(host)) |ip| return ip;
    if (host.len > 60) return null;
    if (arpResolve(IP_DNS) == null) return null; // 先解析 DNS 服务器的 MAC

    // 构造 DNS 查询
    var q: [128]u8 = undefined;
    var n: usize = 0;
    q[0] = 0x12;
    q[1] = 0x34;
    q[2] = 0x01;
    q[3] = 0x00;
    q[4] = 0;
    q[5] = 1; // QDCOUNT=1
    @memset(q[6..12], 0);
    n = 12;
    // 域名编码：长度前缀标签
    var it = host;
    while (it.len > 0) {
        const dot = indexOf(it, '.') orelse it.len;
        if (dot == 0 or dot > 63 or n + 1 + dot + 5 > q.len) return null;
        q[n] = @intCast(dot);
        n += 1;
        @memcpy(q[n .. n + dot], it[0..dot]);
        n += dot;
        it = if (dot < it.len) it[dot + 1 ..] else it[it.len..];
    }
    q[n] = 0;
    n += 1;
    q[n] = 0;
    q[n + 1] = 1; // A
    q[n + 2] = 0;
    q[n + 3] = 1; // IN

    dns_answer.valid = false;
    var tries: u32 = 0;
    while (tries < 2) : (tries += 1) {
        if (!sendUdp(IP_DNS, 40000, 53, q[0 .. n + 4])) return null;
        const t0 = pit.ticks;
        while (pit.ticks - t0 < 50) { // 500ms
            if (dns_answer.valid and dns_answer.id == 0x1234) return dns_answer.ip;
            waitTick();
        }
    }
    return null;
}

fn indexOf(s: []const u8, c: u8) ?usize {
    for (s, 0..) |x, i| {
        if (x == c) return i;
    }
    return null;
}

// ---------------- TCP（停等教学实现）----------------

const TcpState = struct {
    state: enum { idle, syn_sent, established, fin_wait, done } = .idle,
    their_ip: u32 = 0,
    their_port: u16 = 0,
    our_port: u16 = 0,
    iss: u32 = 0, // 初始序号
    snd_nxt: u32 = 0, // 下一个发送序号
    rcv_nxt: u32 = 0, // 期待接收序号
    their_iss: u32 = 0,
    // 未确认段（重传用）
    unacked: [536]u8 = undefined,
    unacked_len: usize = 0,
    unacked_sent: u64 = 0,
    acked: bool = true,
    synacked: bool = false,
    fin_received: bool = false,
    rst: bool = false,
    // 接收缓冲
    recv: [64 * 1024]u8 = undefined,
    recv_len: usize = 0,
};

var tcp: TcpState = .{};

fn tcpChecksum(segment: []const u8, src: u32, dst: u32) u16 {
    // 伪头 + TCP 段
    var buf: [1280]u8 = undefined;
    const pseudo_len = 12 + segment.len;
    if (pseudo_len > buf.len) return 0;
    buf[0] = @truncate(src >> 24);
    buf[1] = @truncate(src >> 16);
    buf[2] = @truncate(src >> 8);
    buf[3] = @truncate(src);
    buf[4] = @truncate(dst >> 24);
    buf[5] = @truncate(dst >> 16);
    buf[6] = @truncate(dst >> 8);
    buf[7] = @truncate(dst);
    buf[8] = 0;
    buf[9] = PROTO_TCP;
    buf[10] = @truncate(segment.len >> 8);
    buf[11] = @truncate(segment.len);
    @memcpy(buf[12..pseudo_len], segment);
    return checksum(buf[0..pseudo_len]);
}

fn sendTcpSeg(flags: u16, seq: u32, ack: u32, data: []const u8, keep_retrans: bool) bool {
    var seg: [536 + 20]u8 = undefined;
    if (20 + data.len > seg.len) return false;
    const h: *align(1) TcpHeader = @ptrCast(&seg);
    h.* = .{
        .sport = htons(tcp.our_port),
        .dport = htons(tcp.their_port),
        .seq = htonl(seq),
        .ack = htonl(ack),
        .off_flags = htons((5 << 12) | flags),
        .window = htons(4096),
        .checksum_ = 0,
        .urgptr = 0,
    };
    @memcpy(seg[20 .. 20 + data.len], data);
    h.checksum_ = htons(tcpChecksum(seg[0 .. 20 + data.len], IP_OUR, tcp.their_ip));
    if (keep_retrans and data.len > 0) {
        @memcpy(tcp.unacked[0..data.len], data);
        tcp.unacked_len = data.len;
        tcp.unacked_sent = pit.ticks;
        tcp.acked = false;
    }
    return sendIp(tcp.their_ip, PROTO_TCP, seg[0 .. 20 + data.len]);
}

fn handleTcp(src_ip: u32, ip_payload: []const u8) void {
    if (ip_payload.len < 20 or tcp.state == .idle) return;
    const h: *align(1) const TcpHeader = @ptrCast(ip_payload.ptr);
    if (htons(h.sport) != tcp.their_port or htons(h.dport) != tcp.our_port) return;
    if (src_ip != tcp.their_ip) return;

    const off = (@as(usize, htons(h.off_flags) >> 12)) * 4;
    if (off < 20 or off > ip_payload.len) return;
    const flags = htons(h.off_flags) & 0x01FF;
    const seq = htonl(h.seq);
    const ack = htonl(h.ack);
    const data = ip_payload[off..];

    if (flags & TCP_RST != 0) {
        tcp.rst = true;
        tcp.state = .done;
        return;
    }
    if (flags & TCP_SYN != 0 and flags & TCP_ACK != 0 and tcp.state == .syn_sent) {
        tcp.their_iss = seq;
        tcp.rcv_nxt = seq + 1;
        tcp.synacked = true;
    }
    if (flags & TCP_ACK != 0) {
        // 停等：确认覆盖了整个未确认段才算数
        if (!tcp.acked and tcp.unacked_len > 0) {
            const sent_end = tcp.snd_nxt; // snd_nxt = 发送时 seq+len
            if (ack >= sent_end) {
                tcp.acked = true;
                tcp.unacked_len = 0;
            }
        }
        if (tcp.state == .fin_wait) tcp.state = .done;
    }
    if (data.len > 0 and seq == tcp.rcv_nxt) {
        // 按序数据 → 追加接收缓冲（乱序丢弃，停等世界少见）
        const space = tcp.recv.len - tcp.recv_len;
        const take = @min(data.len, space);
        @memcpy(tcp.recv[tcp.recv_len .. tcp.recv_len + take], data[0..take]);
        tcp.recv_len += take;
        tcp.rcv_nxt += @intCast(data.len);
    }
    // 每收到一段（含 FIN）都回 ACK
    if (flags & TCP_ACK != 0 or data.len > 0 or flags & TCP_FIN != 0) {
        if (tcp.state == .established or tcp.state == .fin_wait) {
            _ = sendTcpSeg(TCP_ACK, tcp.snd_nxt, tcp.rcv_nxt, &.{}, false);
        }
    }
    if (flags & TCP_FIN != 0) {
        tcp.fin_received = true;
        tcp.rcv_nxt = seq + 1;
        if (tcp.state == .established) tcp.state = .fin_wait;
    }
}

/// http_get 系统调用实现：阻塞完成 DNS/TCP/HTTP，返回响应长度
pub fn httpGet(host: []const u8, port: u16, path: []const u8, out: []u8) isize {
    if (!inited) return -19;
    lock();
    defer unlock();
    defer tcp.state = .idle;

    const dst = resolve(host) orelse return -11; // EAGAIN（解析失败）
    if (arpResolve(nextHop(dst)) == null) return -110;

    // ---- 三次握手 ----
    tcp.state = .syn_sent;
    tcp.their_ip = dst;
    tcp.their_port = port;
    tcp.our_port = @intCast(40000 + (pit.ticks & 0xFF));
    tcp.iss = @truncate(pit.uptimeMs() * 7919 + 12345);
    tcp.snd_nxt = tcp.iss + 1;
    tcp.rcv_nxt = 0;
    tcp.synacked = false;
    tcp.acked = true;
    tcp.fin_received = false;
    tcp.rst = false;
    tcp.recv_len = 0;

    var tries: u32 = 0;
    while (tries < 3) : (tries += 1) {
        _ = sendTcpSeg(TCP_SYN, tcp.iss, 0, &.{}, false);
        const t0 = pit.ticks;
        while (pit.ticks - t0 < 50) {
            if (tcp.synacked) break;
            if (tcp.rst) return -111; // ECONNREFUSED
            waitTick();
        }
        if (tcp.synacked) break;
    }
    if (!tcp.synacked) return -110;

    _ = sendTcpSeg(TCP_ACK, tcp.snd_nxt, tcp.rcv_nxt, &.{}, false);
    tcp.state = .established;

    // ---- 发 GET 请求（重传直到 ACK）----
    var req: [256]u8 = undefined;
    const host_str = host;
    const req_len = fmtGet(&req, host_str, port, path);
    var rtries: u32 = 0;
    while (rtries < 4) : (rtries += 1) {
        _ = sendTcpSeg(TCP_ACK | TCP_PSH, tcp.snd_nxt, tcp.rcv_nxt, req[0..req_len], true);
        tcp.snd_nxt += @intCast(req_len);
        const t0 = pit.ticks;
        while (pit.ticks - t0 < 100) { // 1s 等 ACK
            if (tcp.acked) break;
            if (tcp.rst) return -111;
            waitTick();
        }
        if (tcp.acked) break;
        // 超时重传：序号退回
        tcp.snd_nxt -= @intCast(req_len);
    }
    if (!tcp.acked) return -110;

    // ---- 收响应：直到 FIN / 缓冲满 / 15s 总超时 ----
    const t0 = pit.ticks;
    while (pit.ticks - t0 < 1500) {
        if (tcp.fin_received or tcp.rst) break;
        if (tcp.recv_len >= tcp.recv.len) break;
        waitTick();
    }

    // ---- 挥手：发 FIN 等 ACK ----
    if (!tcp.rst) {
        _ = sendTcpSeg(TCP_FIN | TCP_ACK, tcp.snd_nxt, tcp.rcv_nxt, &.{}, false);
        tcp.snd_nxt += 1;
        const tf = pit.ticks;
        while (pit.ticks - tf < 30) {
            if (tcp.state == .done) break;
            waitTick();
        }
    }

    if (tcp.recv_len == 0) return -110;
    const n = @min(out.len, tcp.recv_len);
    @memcpy(out[0..n], tcp.recv[0..n]);
    return @intCast(n);
}

fn fmtGet(buf: []u8, host: []const u8, port: u16, path: []const u8) usize {
    _ = port;
    var n: usize = 0;
    const w = struct {
        fn put(b: []u8, i: *usize, s: []const u8) void {
            const take = @min(s.len, b.len - i.*);
            @memcpy(b[i.* .. i.* + take], s[0..take]);
            i.* += take;
        }
    };
    w.put(buf, &n, "GET ");
    const p = if (path.len > 0) path else "/";
    w.put(buf, &n, p);
    w.put(buf, &n, " HTTP/1.0\r\nHost: ");
    w.put(buf, &n, host);
    w.put(buf, &n, "\r\nUser-Agent: zos-curl/0.1\r\n\r\n");
    return n;
}

// ---------------- 收包分发 ----------------

pub fn handleFrame(frame: []const u8) void {
    if (frame.len < 14) return;
    const eth: *align(1) const EthHeader = @ptrCast(frame.ptr);
    const ethertype = htons(eth.ethertype);
    const payload = frame[14..];

    if (ethertype == ETH_ARP) {
        handleArp(frame);
    } else if (ethertype == ETH_IP) {
        if (payload.len < 20) return;
        const ip: *align(1) const IpHeader = @ptrCast(payload.ptr);
        if ((ip.ver_ihl >> 4) != 4) return;
        const ihl = (@as(usize, ip.ver_ihl & 0xF)) * 4;
        if (ihl < 20 or ihl > payload.len) return;
        const total = htons(ip.total_len);
        if (total < ihl or total > payload.len) return;
        const src = htonl(ip.src);
        if (htonl(ip.dst) != IP_OUR) return; // 不是发给我们的
        const body = payload[ihl..total];
        switch (ip.proto) {
            PROTO_ICMP => handleIcmp(src, body),
            PROTO_UDP => handleUdp(src, body),
            PROTO_TCP => handleTcp(src, body),
            else => {},
        }
    }
}
