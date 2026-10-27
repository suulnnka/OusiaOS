//! TTY 行规程（line discipline）—— 字符设备的输入缓冲与回显
//!
//! 教学要点：
//!   - 键盘/串口中断产生"裸字节"，行规程负责：
//!       回显(echo)、退格处理、行缓冲，向上层 read() 提供完整行
//!   - 环形缓冲区：生产者（中断上下文）与消费者（进程）解耦

const console = @import("console.zig");

const BUF_SIZE = 1024;

var buf: [BUF_SIZE]u8 = undefined;
var head: usize = 0; // 消费位置
var count: usize = 0; // 当前存量

/// 行模式下已收到换行符的完整行数（read 按行消费）
var complete_lines: usize = 0;
var echo_on = true;

/// 输入源（键盘/串口中断）调用；负责回显与退格
pub fn onInput(c: u8) void {
    if (c == '\r') return; // 忽略 CR，统一用 LF

    if (c == 0x08 or c == 0x7F) { // 退格/删除
        if (count > 0 and !atLineStart()) {
            count -= 1;
            if (echo_on) console.putChar(0x08); // 退格 + 空格 + 退格
            if (echo_on) console.putChar(' ');
            if (echo_on) console.putChar(0x08);
        }
        return;
    }

    if (count >= BUF_SIZE) return; // 缓冲满，丢弃

    buf[(head + count) % BUF_SIZE] = c;
    count += 1;
    if (echo_on) console.putChar(c);
    if (c == '\n' or c == 0x03) complete_lines += 1; // Ctrl+C 也终结一行
}

fn atLineStart() bool {
    if (count == 0) return true;
    return buf[(head + count - 1) % BUF_SIZE] == '\n';
}

/// 非阻塞读一个字节
pub fn readByte() ?u8 {
    if (count == 0) return null;
    const c = buf[head];
    head = (head + 1) % BUF_SIZE;
    count -= 1;
    return c;
}

/// 阻塞读：等待至少一个完整行（或缓冲区满）后按行返回数据
/// 返回拷贝到 dst 的字节数（至少 1；不含未终结行的尾巴）
pub fn read(dst: []u8) usize {
    // 无完整行时休眠等待（调度器就绪前用 hlt 轮询）
    while (complete_lines == 0 and count < BUF_SIZE) {
        if (!hasScheduler()) {
            asm volatile ("hlt");
        } else {
            @import("proc.zig").yieldCpu();
        }
    }

    var n: usize = 0;
    while (n < dst.len) {
        const c = readByte() orelse break;
        dst[n] = c;
        n += 1;
        if (c == '\n' or c == 0x03) {
            complete_lines -|= 1;
            break;
        }
        // 行还没完但缓冲区空了 → 本行未终结，不应发生（除非 BUF 满）
        if (count == 0) break;
    }
    return n;
}

var scheduler_ready = false;
pub fn setSchedulerReady() void {
    scheduler_ready = true;
}
fn hasScheduler() bool {
    return scheduler_ready;
}
