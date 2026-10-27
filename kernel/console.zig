//! 控制台：VGA 文本模式 + 串口双通道输出，并提供内核打印函数 kprintf
//!
//! 教学要点：
//!   - VGA 文本模式：0xB8000 起的显存，每字符 2 字节（ASCII + 颜色属性）
//!   - 简易 printf 的 comptime 实现（体会 Zig 的编译期元编程）
//!
//! 注意：VGA 文本模式只支持 ASCII/CP437，非 ASCII 字符显示为 '?'；
//! 串口则原样输出（支持 UTF-8）。

const serial = @import("serial.zig");
const gui = @import("gui.zig");

const VGA_PHYS = 0xB8000;
const KERNEL_VIRT_BASE: usize = 0xFFFF_FFFF_8000_0000;
const WIDTH = 80;
const HEIGHT = 25;

/// VGA 显存（高端虚拟地址 = 物理地址 + 直接映射偏移）
const vga: [*]volatile u16 = @ptrFromInt(VGA_PHYS + KERNEL_VIRT_BASE);

var row: usize = 0;
var col: usize = 0;
/// 默认属性：黑底浅灰字
var attr: u8 = 0x07;

/// 图形模式（VBE）标志：由 main 在 console.init 前根据 multiboot
/// framebuffer 标签设置。图形模式下 VGA 文本显存(0xB8000)不再是文本屏
/// （A0000 窗口别名到帧缓冲开头），写入会画出垃圾像素 → 全部跳过，
/// 只保留串口通道。
var graphical = false;

pub fn init(graphics_mode: bool) void {
    graphical = graphics_mode;
    serial.init();
    if (!graphical) clear();
}

pub fn clear() void {
    row = 0;
    col = 0;
    for (0..WIDTH * HEIGHT) |i| vga[i] = (@as(u16, attr) << 8) | ' ';
    updateCursor();
}

/// 输出一个字节：串口始终输出；VGA 仅文本模式（图形模式下由 gui.zig 接管屏幕）
pub fn putChar(c: u8) void {
    serial.writeByte(c); // 串口通道（日志/无头测试）
    if (!graphical) putVga(if (c >= 0x80) '?' else c);
    // GUI 终端镜像（第三条通道）：图形模式下 GUI 的 Terminal 窗口显示
    // 与串口完全同源的字节流；gui 未激活时该调用只入环形缓冲，零副作用
    gui.onConsoleChar(c);
}

fn putVga(c: u8) void {
    switch (c) {
        '\n' => {
            row += 1;
            col = 0;
        },
        '\r' => col = 0,
        0x08 => { // 退格
            if (col > 0) col -= 1;
            vga[row * WIDTH + col] = (@as(u16, attr) << 8) | ' ';
        },
        '\t' => {
            col = (col + 8) & ~@as(usize, 7);
            if (col >= WIDTH) {
                col = 0;
                row += 1;
            }
        },
        else => {
            vga[row * WIDTH + col] = (@as(u16, attr) << 8) | c;
            col += 1;
            if (col >= WIDTH) {
                col = 0;
                row += 1;
            }
        },
    }
    if (row >= HEIGHT) scroll();
    updateCursor();
}

fn scroll() void {
    // 整屏上移一行，末行清空
    for (0..(HEIGHT - 1) * WIDTH) |i| vga[i] = vga[i + WIDTH];
    for ((HEIGHT - 1) * WIDTH..HEIGHT * WIDTH) |i| vga[i] = (@as(u16, attr) << 8) | ' ';
    row = HEIGHT - 1;
}

/// 用 CRT 索引/数据端口(0x3D4/0x3D5)更新硬件光标
fn updateCursor() void {
    const pos: u16 = @intCast(row * WIDTH + col);
    serial.outb(0x3D4, 0x0F);
    serial.outb(0x3D5, @truncate(pos));
    serial.outb(0x3D4, 0x0E);
    serial.outb(0x3D5, @truncate(pos >> 8));
}

pub fn writeStr(s: []const u8) void {
    for (s) |c| putChar(c);
}

// ---------------- kprintf：极简格式化 ----------------
// 支持：{s} 字符串、{d} 十进制、{x} 十六进制小写、{X} 大写、{c} 字符
// 数值类型自动选择十进制（含 {}）。教学：comptime 展开格式串。

pub fn kprintf(comptime fmt: []const u8, args: anytype) void {
    @setEvalBranchQuota(10000);
    const info = @typeInfo(@TypeOf(args)).@"struct";
    comptime var arg_i: usize = 0;
    comptime var i: usize = 0;

    inline while (i < fmt.len) {
        if (fmt[i] == '{' and i + 1 < fmt.len and fmt[i + 1] == '{') {
            putChar('{');
            i += 2;
            continue;
        }
        if (fmt[i] == '}') {
            putChar('}');
            i += 1;
            continue;
        }
        if (fmt[i] == '{') {
            // 解析占位符 "{spec}"
            comptime var j = i + 1;
            comptime var spec: u8 = 0;
            inline while (j < fmt.len and fmt[j] != '}') : (j += 1) {
                spec = fmt[j];
            }
            if (j >= fmt.len) @compileError("kprintf: 缺少 '}'");
            emit(arg_i, spec, info, args);
            arg_i += 1;
            i = j + 1;
            continue;
        }
        putChar(fmt[i]);
        i += 1;
    }
    comptime {
        if (arg_i != info.field_names.len)
            @compileError("kprintf: 参数数量与占位符不一致");
    }
}

fn emit(comptime idx: usize, comptime spec: u8, comptime info: anytype, args: anytype) void {
    if (idx >= info.field_names.len) @compileError("kprintf: 参数不足");
    const val = @field(args, info.field_names[idx]);
    const T = @TypeOf(val);
    switch (spec) {
        's' => writeStr(val),
        'c' => putChar(val),
        'd' => putNumber(val, 10, false),
        'x' => putNumber(val, 16, false),
        'X' => putNumber(val, 16, true),
        0 => switch (@typeInfo(T)) {
            .pointer => writeStr(val),
            else => putNumber(val, 10, false),
        },
        else => @compileError("kprintf: 不支持的格式 {" ++ .{spec} ++ "}"),
    }
}

fn putNumber(val: anytype, base: u8, upper: bool) void {
    const T = @TypeOf(val);
    const is_signed = switch (@typeInfo(T)) {
        .int => |ti| ti.signedness == .signed,
        .comptime_int => false,
        else => @compileError("kprintf: 数值格式需要整数, 得到 " ++ @typeName(T)),
    };

    var buf: [24]u8 = undefined;
    var len: usize = 0;

    var u: u64 = undefined;
    if (is_signed) {
        const sv: i64 = @intCast(val);
        if (sv < 0) {
            putChar('-');
            u = @intCast(-sv);
        } else u = @intCast(sv);
    } else u = @intCast(val);

    if (u == 0) {
        putChar('0');
        return;
    }
    while (u > 0) {
        const digit: u8 = @intCast(u % base);
        buf[len] = if (digit < 10)
            '0' + digit
        else
            (if (upper) @as(u8, 'A') else 'a') + (digit - 10);
        len += 1;
        u /= base;
    }
    // 逆序输出
    var k: usize = len;
    while (k > 0) {
        k -= 1;
        putChar(buf[k]);
    }
}
