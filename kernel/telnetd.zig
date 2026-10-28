//! telnetd —— 明文远程 shell（:23）+ ofile 文件服务（:3122）
//!
//! 教学要点：
//!   - inetd 模型的最小版：内核 TCP 服务器收到连接 → 拉起一个用户进程，
//!     把它的 stdin/stdout 接到网络连接上（fds 直接指向 sock 节点）。
//!     sh 自己不知道自己在跟"网络那头"的人说话——fd 抽象的胜利
//!   - 远程 shell 需要行规程：远端一个字节一个字节地来（真实 telnet
//!     客户端逐字符发送），sh 却要整行 read——中间做回显、退格、
//!     CRLF 归一。这正是 tty 行规程存在的理由（这里是极简复刻）
//!   - telnet 协议里 0xFF 是转义（IAC 命令序列），必须解析剥离，
//!     否则会被当成数据
//!   - ofile 协议（类 scp）：一行的 ASCII 命令头 + 原始字节流——
//!     "GET /path\n" → "OK <size>\n" + 内容；"PUT /path <size>\n" +
//!     内容 → "OK\n"。内核以 root 读写 vfs（ext2 真落盘）
//!
//! 安全声明：这是 1971 年的明文世界——无认证无加密，任何能连上端口
//! 的人就是 root。SSH 是课后练习（见 docs/fs.md 取舍清单）。
//!
//! 并发：data_hook 在收包路径（IRQ 或轮询）被调；spawn 会话/文件写
//! 都在其中同步完成（教学内核的 ATA PIO 一次毫秒级，可接受）。
//! poll 由时钟钩子驱动：排空发送环（回显/提示符/文件流）+ 会话收割。

const std = @import("std");
const console = @import("console.zig");
const net = @import("net.zig");
const vfs = @import("vfs.zig");
const proc = @import("proc.zig");
const pit = @import("pit.zig");

const SHELL_CONN: usize = 0;
const FILE_CONN: usize = 1;
const TELNET_PORT: u16 = 23;
const FILE_PORT: u16 = 3122;

// ---------------- shell 会话 ----------------

// 行装配缓冲（远端逐字符 → 完整行）
var line_buf: [511]u8 = undefined;
var line_len: usize = 0;
// 完整行队列（sh 的 read 从这里取）
var ready_buf: [1024]u8 = undefined;
var ready_head: usize = 0;
var ready_tail: usize = 0;
var session_pid: u32 = 0;
var banner_sent = false;

// telnet IAC 转义状态机（0xFF 后跟命令字节）
const IAC: u8 = 0xFF;

pub fn init() void {
    if (!net.ready()) return;
    if (!vfs.ext2Mounted()) return;
    net.data_hook = &onData;
    net.established_hook = &onEstablished;
    _ = net.listen(SHELL_CONN, TELNET_PORT, .shell);
    _ = net.listen(FILE_CONN, FILE_PORT, .file);
    pit.srv_hook = &poll;
    console.kprintf("telnetd: remote shell :23 / ofile :3122 (plaintext, no auth)\n", .{});
}

fn onData(idx: usize, bytes: []const u8) void {
    if (idx == SHELL_CONN) {
        shellData(bytes);
    } else {
        fileData(bytes);
    }
}

fn onEstablished(idx: usize) void {
    if (idx == SHELL_CONN) {
        // 连接建立即拉起远程 sh（此刻在收包路径；exec 是同步毫秒级）
        spawnShell();
        banner_sent = false;
    }
}

/// 拉起远程 sh：stdin/stdout 都指向 sock 节点（stderr 也走网络，
/// 方便看到错误；pid 交给 init 收割）
fn spawnShell() void {
    if (session_pid != 0) return;
    line_len = 0;
    ready_head = 0;
    ready_tail = 0;
    const p = proc.spawnSession(vfs.SOCK_BASE + SHELL_CONN, "sh@telnet") orelse {
        _ = net.srvWrite(SHELL_CONN, "telnetd: cannot spawn /bin/sh\r\n");
        return;
    };
    session_pid = p.pid;
    net.srvSetCookie(SHELL_CONN, p.pid);
}

/// 行规程：回显 + 退格 + CRLF 归一 + IAC 剥离；完整行进 ready 队列
fn shellData(bytes: []const u8) void {
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];

        // ---- telnet IAC：最小解析（不回应 WILL/DO——客户端会自己放弃）----
        if (c == IAC) {
            if (i + 1 >= bytes.len) break; // 序列跨段：丢弃（教学简化）
            const cmd = bytes[i + 1];
            if (cmd == IAC) {
                i += 1; // IAC IAC = 字面 0xFF
                continue;
            }
            if (cmd >= 0xFA) { // SB/WILL/WONT/DO/DONT 带一个参数字节
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }

        // ---- 退格：行内删一个字符，回显 "\b \b" 把终端也擦掉 ----
        if (c == 0x7F or c == 0x08) {
            if (line_len > 0) {
                line_len -= 1;
                _ = net.srvWrite(SHELL_CONN, "\x08 \x08");
            }
            continue;
        }

        // ---- CR/LF：行结束（远端 Enter 通常是 CRLF，归一成一个）----
        if (c == '\r' or c == '\n') {
            // 跳过 CRLF 的另一半
            if (c == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') i += 1;
            if (line_len == 0 and ready_head == ready_tail) {
                // 空行也照常提交（sh 把它当"再显示一次提示符"）
            }
            if (line_len + 1 <= line_buf.len) {
                line_buf[line_len] = '\n';
                line_len += 1;
                appendReady(line_buf[0..line_len]);
            }
            line_len = 0;
            _ = net.srvWrite(SHELL_CONN, "\r\n");
            continue;
        }

        // ---- 普通字符：回显 + 入行缓冲 ----
        if (c >= 0x20 and c != 0x7F and line_len < line_buf.len) {
            line_buf[line_len] = c;
            line_len += 1;
            _ = net.srvWrite(SHELL_CONN, &[1]u8{c});
        }
    }
    if (ready_head != ready_tail) net.wakeWaiter(SHELL_CONN);
}

fn appendReady(bytes: []const u8) void {
    for (bytes) |c| {
        const next = (ready_tail + 1) % ready_buf.len;
        if (next == ready_head) return; // 队列满：丢（正常交互远小于 1KB）
        ready_buf[ready_tail] = c;
        ready_tail = next;
    }
}

/// sh 的 read(0)/read(1)：阻塞等完整行。EOF（连接被对端关了）返回 0
pub fn sockRead(idx: usize, buf: []u8) isize {
    while (true) {
        asm volatile ("cli");
        // 取一行（最多到 buf 容量；sh 的行缓冲 512B 足够容纳）
        if (ready_head != ready_tail) {
            var n: usize = 0;
            while (ready_head != ready_tail and n < buf.len) {
                buf[n] = ready_buf[ready_head];
                ready_head = (ready_head + 1) % ready_buf.len;
                n += 1;
                if (buf[n - 1] == '\n') break; // 整行交付（sh 按行处理）
            }
            asm volatile ("sti");
            return @intCast(n);
        }
        if (net.srvClosed(idx)) {
            asm volatile ("sti");
            return 0; // EOF：sh 退出，会话收割
        }
        const p = proc.current() orelse {
            asm volatile ("sti");
            return -5;
        };
        p.state = .blocked;
        p.wake_tick = 0;
        net.setWaiter(idx, p.pid);
        proc.switchAway();
        // 醒来（数据到达或关闭）后循环重试
    }
}

pub fn sockWrite(idx: usize, bytes: []const u8) isize {
    return @intCast(net.srvWrite(idx, bytes));
}

/// 每拍：排空网络发送环（回显/提示符/文件流）+ 收割死会话 + 文件流推进
fn poll() void {
    net.srvPoll();

    // 会话进程死了（exit 或被连接关闭饿死）→ 关连接、复位状态
    if (session_pid != 0 and proc.isGone(session_pid)) {
        if (!net.srvClosed(SHELL_CONN)) _ = net.srvWrite(SHELL_CONN, "\r\n[connection closed]\r\n");
        net.srvClose(SHELL_CONN);
        session_pid = 0;
        line_len = 0;
        ready_head = 0;
        ready_tail = 0;
    }
    // 对端已断而槽还开着 → 复位（等下一个连接）
    if (net.srvClosed(SHELL_CONN) and session_pid == 0) {
        net.srvReset(SHELL_CONN);
        banner_sent = false;
    }

    filePoll();
}

// ---------------- ofile：类 scp 的文件推拉协议 ----------------
//
//   客户端 → 服务端：一行命令 + 可能紧跟的字节流
//     "GET /path\n"                → "OK <size>\n" + <size> 字节 | "ERR <why>\n"
//     "PUT /path <size>\n" + 字节  → "OK\n" | "ERR <why>\n"
//
// 一条连接一次操作，完成后关闭。内核以 root 身份读写 vfs（ext2 落盘）。

const FState = enum { cmd, put_body, get_body };

var f_state: FState = .cmd;
var f_cmd: [300]u8 = undefined;
var f_cmd_len: usize = 0;
var f_node: usize = 0;
var f_remaining: u64 = 0;
var f_offset: u64 = 0;
var f_close_after_drain = false;
var get_buf: [4096]u8 = undefined;

fn fileData(bytes: []const u8) void {
    // 流式状态机：一个包里可能同时有"命令头 + 正文开头"（curl/nc 常见），
    // 解析完头必须把剩余字节交给正文——这是流协议解析的经典错（踩过）
    var off: usize = 0;
    while (off < bytes.len) {
        switch (f_state) {
            .cmd => {
                const nl = std.mem.indexOfScalar(u8, bytes[off..], '\n') orelse {
                    appendCmd(bytes[off..]);
                    return;
                };
                appendCmd(bytes[off .. off + nl]);
                parseFileCmd();
                f_cmd_len = 0;
                off += nl + 1;
            },
            .put_body => {
                filePutBody(bytes[off..]); // 吃掉全部剩余（出错/完成在内部切状态）
                return;
            },
            .get_body => return, // GET 流向是服务端→客户端
        }
    }
}

fn appendCmd(bytes: []const u8) void {
    for (bytes) |c| {
        if (f_cmd_len < f_cmd.len - 1) {
            f_cmd[f_cmd_len] = c;
            f_cmd_len += 1;
        }
    }
}

/// 解析命令行。路径用 root 凭证（uid 0 旁路一切权限位——这是管理通道）
fn parseFileCmd() void {
    const cmd = f_cmd[0..f_cmd_len];

    if (std.mem.startsWith(u8, cmd, "GET ")) {
        const path = std.mem.trim(u8, cmd[4..], " ");
        var norm: [256]u8 = undefined;
        const n = vfs.normalizePath(path, "/", &norm) orelse return fileErr("badpath");
        const node = vfs.resolveCred(norm[0..n], "/", 0, 0) catch return fileErr("noent");
        const inf = vfs.info(node);
        if (inf.is_dir) return fileErr("isdir");

        var hdr: [64]u8 = undefined;
        const h = std.fmt.bufPrint(&hdr, "OK {d}\n", .{inf.size}) catch return fileErr("io");
        _ = net.srvWrite(FILE_CONN, h);
        f_node = node;
        f_remaining = inf.size;
        f_offset = 0;
        f_state = .get_body;
        f_close_after_drain = false;
        return;
    }

    if (std.mem.startsWith(u8, cmd, "PUT ")) {
        // "PUT /path <size>"
        const rest = std.mem.trim(u8, cmd[4..], " ");
        const sp = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse return fileErr("usage");
        const path = std.mem.trim(u8, rest[0..sp], " ");
        const size = std.fmt.parseInt(u64, std.mem.trim(u8, rest[sp + 1 ..], " "), 10) catch return fileErr("badsize");
        if (size > 64 * 1024 * 1024) return fileErr("toobig");

        var norm: [256]u8 = undefined;
        const n = vfs.normalizePath(path, "/", &norm) orelse return fileErr("badpath");
        const node = vfs.createFile(norm[0..n], 0o644, 0, 0) catch return fileErr("noent");
        vfs.ext2TruncateNode(node); // 覆盖写：已有文件清零

        f_node = node;
        f_remaining = size;
        f_offset = 0;
        f_state = .put_body;
        return;
    }

    fileErr("usage");
}

fn fileErr(why: []const u8) void {
    _ = net.srvWrite(FILE_CONN, "ERR ");
    _ = net.srvWrite(FILE_CONN, why);
    _ = net.srvWrite(FILE_CONN, "\n");
    f_close_after_drain = true;
    f_state = .cmd;
}

fn filePutBody(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len and f_remaining > 0) {
        const take = @min(bytes.len - off, f_remaining);
        const w = vfs.write(f_node, f_offset, bytes[off .. off + take]);
        if (w <= 0) {
            fileErr("write");
            return;
        }
        f_offset += @intCast(w);
        f_remaining -= @intCast(w);
        off += @intCast(w);
    }
    if (f_remaining == 0) {
        _ = net.srvWrite(FILE_CONN, "OK\n");
        f_close_after_drain = true;
        f_state = .cmd;
    }
}

/// GET 的字节流推进：每拍写一点进发送环（环有空间才写，由停等节流）
fn filePoll() void {
    if (f_state != .get_body) {
        // 错误路径/PUT 完成后：等发送环排空再关连接（保证尾部字节出门）
        if (f_close_after_drain and net.srvTxSpace(FILE_CONN) == net.txCapacity(FILE_CONN)) {
            net.srvClose(FILE_CONN);
        }
        if (net.srvClosed(FILE_CONN)) {
            net.srvReset(FILE_CONN);
            f_state = .cmd;
            f_cmd_len = 0;
            f_close_after_drain = false;
        }
        return;
    }

    if (net.srvClosed(FILE_CONN)) {
        // 客户端中途断开：放弃
        f_state = .cmd;
        f_close_after_drain = false;
        return;
    }
    while (f_remaining > 0 and net.srvTxSpace(FILE_CONN) > get_buf.len + 512) {
        const want = @min(get_buf.len, f_remaining);
        const n = vfs.read(f_node, f_offset, get_buf[0..want]);
        if (n <= 0) {
            // 文件比说的短（被并发改了）：EOF 即收尾
            f_remaining = 0;
            break;
        }
        _ = net.srvWrite(FILE_CONN, get_buf[0..@intCast(n)]);
        f_offset += @intCast(n);
        f_remaining -= @intCast(n);
    }
    if (f_remaining == 0) {
        f_state = .cmd;
        f_close_after_drain = true;
    }
}
