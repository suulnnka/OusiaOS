//! OusiaOS libc —— C ABI 兼容层
//!
//! 目标：让普通 C 程序（`zig cc -nostdlib` 编译）几乎零修改移植到 OusiaOS：
//!   - 导出 string.h / ctype.h / stdlib.h / errno.h / unistd.h / stdio.h /
//!     dirent.h / sys/stat.h / time.h 的标准符号
//!   - 语义遵循 C/POSIX 惯例：失败返回 -1 并设置 errno（内核层是 -errno）
//!   - printf 族在 clib.c 中用 C va_list 实现（本文件导出其依赖的原语）
//!
//! 头文件在 userland/include/，C 代码 `#include <stdio.h>` 原样可用。
//!
//! 注：memcpy/memset/memmove 不在此导出——zig 的 compiler_rt 已提供，
//! 重复定义反而会导致链接冲突。

const std = @import("std");
const ousia = @import("ousia.zig");

// 作为静态库的根模块：panic 走 ousia.zig 的自定义处理器
// （std 默认 panic 打印器在裸机上自身会崩，吞掉真实错误信息）
pub const panic = ousia.panic;

// miniGL 的 C ABI（ogl.h）：comptime 引用强制分析整个文件——
// 否则 export fn 会被惰性分析跳过，静态库里没有这些符号
comptime {
    _ = @import("oglabi.zig");
}

// ================= errno =================

export var errno: c_int = 0;

export fn __errno_location() *c_int {
    return &errno;
}

/// 内核返回 -errno → C 惯例 -1 + errno
fn check(r: isize) isize {
    if (r < 0 and r >= -200) {
        errno = @intCast(-r);
        return -1;
    }
    return r;
}

const ErrnoMsg = struct { no: c_int, msg: [:0]const u8 };

const errno_table = [_]ErrnoMsg{
    .{ .no = 1, .msg = "Operation not permitted" },
    .{ .no = 2, .msg = "No such file or directory" },
    .{ .no = 9, .msg = "Bad file descriptor" },
    .{ .no = 10, .msg = "No child processes" },
    .{ .no = 11, .msg = "Resource temporarily unavailable" },
    .{ .no = 12, .msg = "Cannot allocate memory" },
    .{ .no = 13, .msg = "Permission denied" },
    .{ .no = 14, .msg = "Bad address" },
    .{ .no = 20, .msg = "Not a directory" },
    .{ .no = 21, .msg = "Is a directory" },
    .{ .no = 22, .msg = "Invalid argument" },
    .{ .no = 25, .msg = "Inappropriate ioctl for device" },
    .{ .no = 29, .msg = "Illegal seek" },
    .{ .no = 30, .msg = "Read-only file system" },
    .{ .no = 38, .msg = "Function not implemented" },
};

var strerror_buf: [64]u8 = undefined;

export fn strerror(e: c_int) [*:0]const u8 {
    for (errno_table) |e2| {
        if (e2.no == e) return e2.msg.ptr;
    }
    const prefix = "Unknown error ";
    @memcpy(strerror_buf[0..prefix.len], prefix);
    const n = fmtDec(e, strerror_buf[prefix.len..]);
    strerror_buf[prefix.len + n] = 0;
    return strerror_buf[0 .. prefix.len + n :0].ptr;
}

fn fmtDec(v: c_int, buf: []u8) usize {
    var tmp: [24]u8 = undefined;
    var u: u64 = @intCast(if (v < 0) -v else v);
    var n: usize = 0;
    if (u == 0) {
        buf[0] = '0';
        return 1;
    }
    while (u > 0) : (u /= 10) {
        tmp[n] = '0' + @as(u8, @intCast(u % 10));
        n += 1;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) buf[i] = tmp[n - 1 - i];
    return n;
}

// ================= string.h =================

export fn strlen(s: [*:0]const u8) usize {
    return ousia.strlenZ(s);
}

export fn strcmp(a: [*:0]const u8, b: [*:0]const u8) c_int {
    var i: usize = 0;
    while (a[i] != 0 and a[i] == b[i]) i += 1;
    return @as(c_int, a[i]) - @as(c_int, b[i]);
}

export fn strncmp(a: [*:0]const u8, b: [*:0]const u8, n: usize) c_int {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i] or a[i] == 0) return @as(c_int, a[i]) - @as(c_int, b[i]);
    }
    return 0;
}

export fn strcpy(dst: [*:0]u8, src: [*:0]const u8) [*:0]u8 {
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) dst[i] = src[i];
    dst[i] = 0;
    return dst;
}

export fn strncpy(dst: [*:0]u8, src: [*:0]const u8, n: usize) [*:0]u8 {
    var i: usize = 0;
    while (i < n and src[i] != 0) : (i += 1) dst[i] = src[i];
    while (i < n) : (i += 1) dst[i] = 0;
    return dst;
}

export fn strcat(dst: [*:0]u8, src: [*:0]const u8) [*:0]u8 {
    var i: usize = 0;
    while (dst[i] != 0) i += 1;
    var j: usize = 0;
    while (src[j] != 0) : (j += 1) dst[i + j] = src[j];
    dst[i + j] = 0;
    return dst;
}

export fn strncat(dst: [*:0]u8, src: [*:0]const u8, n: usize) [*:0]u8 {
    var i: usize = 0;
    while (dst[i] != 0) i += 1;
    var j: usize = 0;
    while (j < n and src[j] != 0) : (j += 1) dst[i + j] = src[j];
    dst[i + j] = 0;
    return dst;
}

export fn strchr(s: [*:0]const u8, c: c_int) ?[*:0]const u8 {
    const ch: u8 = @truncate(@as(u32, @bitCast(c)));
    var i: usize = 0;
    while (true) : (i += 1) {
        if (s[i] == ch) return s + i;
        if (s[i] == 0) return null;
    }
}

export fn strrchr(s: [*:0]const u8, c: c_int) ?[*:0]const u8 {
    const ch: u8 = @truncate(@as(u32, @bitCast(c)));
    var last: ?usize = null;
    var i: usize = 0;
    while (true) : (i += 1) {
        if (s[i] == ch) last = i;
        if (s[i] == 0) break;
    }
    if (last) |l| return s + l;
    return null;
}

export fn strstr(hay: [*:0]const u8, needle: [*:0]const u8) ?[*:0]const u8 {
    const nlen = ousia.strlenZ(needle);
    if (nlen == 0) return hay;
    var i: usize = 0;
    while (hay[i] != 0) : (i += 1) {
        var j: usize = 0;
        while (j < nlen and hay[i + j] == needle[j]) j += 1;
        if (j == nlen) return hay + i;
    }
    return null;
}

export fn strdup(s: [*:0]const u8) ?[*:0]u8 {
    const len = ousia.strlenZ(s);
    const p = ousia.malloc(len + 1) orelse return null;
    @memcpy(p[0 .. len + 1], @as([*]const u8, @ptrCast(s))[0 .. len + 1]);
    return @ptrCast(p);
}

var strtok_save: [*:0]u8 = undefined;
var strtok_started = false;

export fn strtok(s: ?[*:0]u8, delim: [*:0]const u8) ?[*:0]u8 {
    var p: [*:0]u8 = undefined;
    if (s != null) {
        p = s.?;
        strtok_started = true;
    } else {
        if (!strtok_started) return null;
        p = strtok_save;
    }
    // 跳过分隔符
    var i: usize = 0;
    while (p[i] != 0 and strchr(delim, p[i]) != null) i += 1;
    if (p[i] == 0) return null;
    const start = p + i;
    var j: usize = 0;
    while (start[j] != 0 and strchr(delim, start[j]) == null) j += 1;
    if (start[j] != 0) {
        start[j] = 0;
        strtok_save = start + j + 1;
    } else {
        strtok_save = start + j;
    }
    return start;
}

export fn memcmp(a: ?*const anyopaque, b: ?*const anyopaque, n: usize) c_int {
    const pa: [*]const u8 = @ptrCast(a);
    const pb: [*]const u8 = @ptrCast(b);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (pa[i] != pb[i]) return @as(c_int, pa[i]) - @as(c_int, pb[i]);
    }
    return 0;
}

export fn memchr(s: ?*const anyopaque, c: c_int, n: usize) ?*anyopaque {
    const p: [*]const u8 = @ptrCast(s);
    const ch: u8 = @truncate(@as(u32, @bitCast(c)));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (p[i] == ch) return @constCast(@as(*const anyopaque, @ptrCast(p + i)));
    }
    return null;
}

// ---- mem 三兄弟：C 程序经 zig cc -nostdlib 链接时没有 compiler_rt，
//      必须由 libc 提供（静态库语义下强符号不会与 compiler_rt 冲突）。
//      关键：写入必须经由 volatile 指针——普通指针写入会被 LLVM 的
//      死存储消除当作"不可观察"而整段删除（踩过的真实坑：memset 被
//      优化成跳回自己的空循环，调用者带着参数永远打转）----
export fn memcpy(dst: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque {
    const d: [*]volatile u8 = @ptrCast(dst);
    const s: [*]const u8 = @ptrCast(src);
    var i: usize = 0;
    while (i < n) : (i += 1) d[i] = s[i];
    return dst;
}

export fn memmove(dst: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque {
    const d: [*]volatile u8 = @ptrCast(dst);
    const s: [*]const u8 = @ptrCast(src);
    if (@intFromPtr(dst) < @intFromPtr(src)) {
        var i: usize = 0;
        while (i < n) : (i += 1) d[i] = s[i];
    } else {
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            d[i] = s[i];
        }
    }
    return dst;
}

export fn memset(s: ?*anyopaque, c: c_int, n: usize) ?*anyopaque {
    const p: [*]volatile u8 = @ptrCast(s);
    const ch: u8 = @truncate(@as(u32, @bitCast(c)));
    var i: usize = 0;
    while (i < n) : (i += 1) p[i] = ch;
    return s;
}

// ================= ctype.h =================

fn inRange(c: u8, lo: u8, hi: u8) bool {
    return c >= lo and c <= hi;
}

export fn isalpha(c: c_int) c_int {
    const ch: u8 = @truncate(@as(u32, @bitCast(c)));
    return @intFromBool(inRange(ch, 'a', 'z') or inRange(ch, 'A', 'Z'));
}
export fn isdigit(c: c_int) c_int {
    const ch: u8 = @truncate(@as(u32, @bitCast(c)));
    return @intFromBool(inRange(ch, '0', '9'));
}
export fn isalnum(c: c_int) c_int {
    return @intFromBool(isalpha(c) != 0 or isdigit(c) != 0);
}
export fn isspace(c: c_int) c_int {
    const ch: u8 = @truncate(@as(u32, @bitCast(c)));
    return @intFromBool(ch == ' ' or (ch >= 9 and ch <= 13));
}
export fn isupper(c: c_int) c_int {
    const ch: u8 = @truncate(@as(u32, @bitCast(c)));
    return @intFromBool(inRange(ch, 'A', 'Z'));
}
export fn islower(c: c_int) c_int {
    const ch: u8 = @truncate(@as(u32, @bitCast(c)));
    return @intFromBool(inRange(ch, 'a', 'z'));
}
export fn isprint(c: c_int) c_int {
    const ch: u8 = @truncate(@as(u32, @bitCast(c)));
    return @intFromBool(ch >= 0x20 and ch < 0x7F);
}
export fn isxdigit(c: c_int) c_int {
    const ch: u8 = @truncate(@as(u32, @bitCast(c)));
    return @intFromBool(isdigit(c) != 0 or inRange(ch, 'a', 'f') or inRange(ch, 'A', 'F'));
}
export fn toupper(c: c_int) c_int {
    const ch: u8 = @truncate(@as(u32, @bitCast(c)));
    if (inRange(ch, 'a', 'z')) return ch - 'a' + 'A';
    return ch;
}
export fn tolower(c: c_int) c_int {
    const ch: u8 = @truncate(@as(u32, @bitCast(c)));
    if (inRange(ch, 'A', 'Z')) return ch - 'A' + 'a';
    return ch;
}

// ================= stdlib.h =================

export fn atoi(s: [*:0]const u8) c_int {
    return @intCast(atol(s));
}

export fn atol(s: [*:0]const u8) c_long {
    var i: usize = 0;
    var neg = false;
    var v: i64 = 0;
    while (s[i] == ' ' or (s[i] >= 9 and s[i] <= 13)) i += 1;
    if (s[i] == '-') {
        neg = true;
        i += 1;
    } else if (s[i] == '+') {
        i += 1;
    }
    while (s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = v * 10 + (s[i] - '0');
    }
    return if (neg) -v else v;
}

export fn abs(x: c_int) c_int {
    return if (x < 0) -x else x;
}

export fn labs(x: c_long) c_long {
    return if (x < 0) -x else x;
}

export fn malloc(n: usize) ?*anyopaque {
    const p = ousia.malloc(n) orelse {
        errno = 12;
        return null;
    };
    return @ptrCast(p);
}

export fn calloc(n: usize, sz: usize) ?*anyopaque {
    const p = ousia.calloc(n, sz) orelse {
        errno = 12;
        return null;
    };
    return @ptrCast(p);
}

export fn realloc(old: ?*anyopaque, n: usize) ?*anyopaque {
    if (old == null) return malloc(n);
    const p = ousia.realloc(old.?, n) orelse {
        errno = 12;
        return null;
    };
    return @ptrCast(p);
}

export fn free(p: ?*anyopaque) void {
    if (p != null) ousia.free(p.?);
}

/// 快速排序（教学实现：Lomuto 分区 + 尾递归优化右半）
const CompareFn = *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int;

fn swapBytes(a: [*]u8, b: [*]u8, size: usize) void {
    var i: usize = 0;
    while (i < size) : (i += 1) {
        const t = a[i];
        a[i] = b[i];
        b[i] = t;
    }
}

fn qsSort(arr: [*]u8, lo: usize, hi: usize, size: usize, cmp: CompareFn) void {
    var l = lo;
    var h = hi;
    while (h > l) {
        // Lomuto 分区：以最后一个元素为基准，i 为"小值区"边界
        var i = l;
        var j = l;
        while (j < h) : (j += 1) {
            if (cmp(arr + j * size, arr + h * size) <= 0) {
                swapBytes(arr + i * size, arr + j * size, size);
                i += 1;
            }
        }
        swapBytes(arr + i * size, arr + h * size, size);
        // 递归较小的一半，另一半用循环（防止递归栈退化）。
        // 注意 usize 边界：i==l 时左半为空、i==h 时右半为空
        if (i - l < h - i) {
            if (i > l) qsSort(arr, l, i - 1, size, cmp);
            l = i + 1;
        } else {
            if (i < h) qsSort(arr, i + 1, h, size, cmp);
            h = i - 1;
        }
    }
}

export fn qsort(base: ?*anyopaque, nmemb: usize, size: usize, compar: CompareFn) void {
    if (base == null or nmemb <= 1 or size == 0) return;
    qsSort(@ptrCast(base), 0, nmemb - 1, size, compar);
}

// rand：线性同余（教学用，非密码学安全）
var rand_state: u64 = 1;

export fn srand(seed: c_uint) void {
    rand_state = seed;
}

export fn rand() c_int {
    rand_state = rand_state *% 6364136223846793005 +% 1442695040888963407;
    return @intCast((rand_state >> 33) & 0x7FFFFFFF);
}

// ---- exit / atexit ----

const ATEXIT_MAX = 32;
var atexit_fns: [ATEXIT_MAX]*const fn () callconv(.c) void = undefined;
var atexit_count: usize = 0;

export fn atexit(fn_: ?*const fn () callconv(.c) void) c_int {
    if (fn_ == null or atexit_count >= ATEXIT_MAX) return -1;
    atexit_fns[atexit_count] = fn_.?;
    atexit_count += 1;
    return 0;
}

/// C 的 exit：先逆序执行 atexit 处理器，再系统调用退出
export fn exit(code: c_int) noreturn {
    while (atexit_count > 0) {
        atexit_count -= 1;
        atexit_fns[atexit_count]();
    }
    _ = ousia.syscall1(ousia.SYS_exit, @as(usize, @as(u32, @bitCast(code))));
    unreachable;
}

export fn _exit(code: c_int) noreturn {
    exit(code);
}

export fn abort() noreturn {
    _ = ousia.write(2, "abort() called\n");
    exit(134);
}

export fn __ousia_assert_fail(expr: [*:0]const u8, file: [*:0]const u8, line: c_int) noreturn {
    _ = ousia.printf("Assertion failed: {s} ({s}:{d})\n", .{
        expr[0..ousia.strlenZ(expr)], file[0..ousia.strlenZ(file)], line,
    });
    abort();
}

// 环境变量：内核 execve 不传递 envp，environ 恒为空表
var empty_environ: [2]?[*:0]const u8 = .{ null, null };
export var environ: [*:null]const ?[*:0]const u8 = @ptrCast(&empty_environ);

export fn getenv(name: [*:0]const u8) ?[*:0]const u8 {
    _ = name;
    return null; // 见上：无环境变量支持
}

// ================= unistd.h =================

export fn read(fd: c_int, buf: ?*anyopaque, count: usize) isize {
    return check(ousia.syscall3(ousia.SYS_read, @intCast(fd), @intFromPtr(buf), count));
}

export fn write(fd: c_int, buf: ?*const anyopaque, count: usize) isize {
    return check(ousia.syscall3(ousia.SYS_write, @intCast(fd), @intFromPtr(buf), count));
}

/// 注意：C 侧 <fcntl.h> 把 open 声明为变参 open(path, flags, ...mode)；
/// SysV ABI 下被调函数忽略多余实参，这里按两参数定义即可。
export fn open(path: [*:0]const u8, flags: c_int) isize {
    return check(ousia.syscall3(ousia.SYS_open, @intFromPtr(path), @as(usize, @as(u32, @bitCast(flags))), 0));
}

export fn close(fd: c_int) isize {
    return check(ousia.syscall1(ousia.SYS_close, @intCast(fd)));
}

export fn lseek(fd: c_int, off: c_long, whence: c_int) c_long {
    return @intCast(check(ousia.syscall3(ousia.SYS_lseek, @intCast(fd), @bitCast(off), @intCast(whence))));
}

export fn dup(fd: c_int) isize {
    return check(ousia.syscall1(ousia.SYS_dup, @intCast(fd)));
}

export fn isatty(fd: c_int) c_int {
    const r = ousia.syscall3(ousia.SYS_ioctl, @intCast(fd), 0x5401, 0);
    if (r == 0) return 1;
    errno = 25;
    return 0;
}

export fn getpid() c_int {
    return @intCast(ousia.getpid());
}

export fn fork() c_int {
    return @intCast(ousia.fork());
}

export fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: ?*anyopaque) c_int {
    _ = envp;
    const r = ousia.syscall3(ousia.SYS_execve, @intFromPtr(path), @intFromPtr(argv), 0);
    if (r < 0) {
        errno = @intCast(-r);
        return -1;
    }
    return 0;
}

export fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int {
    _ = options;
    return @intCast(ousia.syscall3(ousia.SYS_wait4, @intCast(pid), @intFromPtr(status), 0));
}

export fn sleep(seconds: c_uint) c_uint {
    ousia.sleepMs(@as(u64, seconds) * 1000);
    return 0;
}

export fn usleep(usec: c_uint) c_int {
    ousia.sleepMs((usec + 999) / 1000);
    return 0;
}

export fn chdir(path: [*:0]const u8) c_int {
    const r = ousia.syscall1(ousia.SYS_chdir, @intFromPtr(path));
    if (r < 0) {
        errno = @intCast(-r);
        return -1;
    }
    return 0;
}

export fn getcwd(buf: [*:0]u8, size: usize) ?[*:0]u8 {
    const r = ousia.syscall3(ousia.SYS_getcwd, @intFromPtr(buf), size, 0);
    if (r < 0) {
        errno = @intCast(-r);
        return null;
    }
    return buf;
}

// ================= fcntl.h / sys/stat.h =================

export fn fstat(fd: c_int, buf: ?*anyopaque) c_int {
    const r = ousia.syscall3(ousia.SYS_fstat, @intCast(fd), @intFromPtr(buf), 0);
    if (r < 0) {
        errno = @intCast(-r);
        return -1;
    }
    return 0;
}

/// stat = open + fstat + close（tarfs 只读，够用）
export fn stat(path: [*:0]const u8, buf: ?*anyopaque) c_int {
    const fd = open(path, 0);
    if (fd < 0) return -1;
    const r = fstat(@intCast(fd), buf);
    _ = close(@intCast(fd));
    return r;
}

// ================= time.h =================

export fn time(t: ?*c_long) c_long {
    const sec: c_long = @intCast(ousia.time());
    if (t != null) t.?.* = sec;
    return sec;
}

export fn clock() c_long {
    return 0; // 教学简化：未实现 CPU 时间
}

// ================= stdio.h（FILE 层，printf 族在 clib.c）=================

/// 极简 FILE：直接包装 fd（无用户态缓冲；内核 tty 自带行缓冲）
pub const FILE = extern struct {
    fd: c_int,
    eof: c_int = 0,
    err: c_int = 0,
};

var stdin_file = FILE{ .fd = 0 };
var stdout_file = FILE{ .fd = 1 };
var stderr_file = FILE{ .fd = 2 };

export var stdin: *FILE = &stdin_file;
export var stdout: *FILE = &stdout_file;
export var stderr: *FILE = &stderr_file;

export fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE {
    var flags: c_int = 0;
    var m: usize = 0;
    while (mode[m] != 0) : (m += 1) {
        switch (mode[m]) {
            'r' => flags = 0,
            'w', 'a' => flags = 1, // O_WRONLY（只对 console 有效）
            '+', 'b' => {},
            else => {},
        }
    }
    const fd = open(path, flags);
    if (fd < 0) return null;
    const f: *FILE = @ptrCast(@alignCast(ousia.malloc(@sizeOf(FILE)) orelse {
        _ = close(@intCast(fd));
        return null;
    }));
    f.* = .{ .fd = @intCast(fd) };
    return f;
}

export fn fclose(f: ?*FILE) c_int {
    if (f == null) {
        errno = 9;
        return -1;
    }
    const r = close(f.?.fd);
    ousia.free(f.?);
    return @intCast(r);
}

export fn fgetc(f: ?*FILE) c_int {
    if (f == null) return -1;
    var c: u8 = 0;
    const r = read(f.?.fd, &c, 1);
    if (r != 1) {
        if (r == 0) f.?.eof = 1;
        return -1; // EOF
    }
    return c;
}

export fn getc(f: ?*FILE) c_int {
    return fgetc(f);
}

export fn getchar() c_int {
    return fgetc(stdin);
}

export fn fgets(buf: [*:0]u8, size: usize, f: ?*FILE) ?[*:0]u8 {
    if (f == null or size == 0) return null;
    var i: usize = 0;
    while (i + 1 < size) {
        const c = fgetc(f);
        if (c < 0) break;
        buf[i] = @truncate(@as(u32, @bitCast(c)));
        i += 1;
        if (buf[i - 1] == '\n') break;
    }
    if (i == 0) return null;
    buf[i] = 0;
    return buf;
}

export fn fputc(c: c_int, f: ?*FILE) c_int {
    if (f == null) return -1;
    const ch: u8 = @truncate(@as(u32, @bitCast(c)));
    const r = write(f.?.fd, &ch, 1);
    return if (r == 1) c else -1;
}

export fn putc(c: c_int, f: ?*FILE) c_int {
    return fputc(c, f);
}

export fn putchar(c: c_int) c_int {
    return fputc(c, stdout);
}

export fn fputs(s: [*:0]const u8, f: ?*FILE) c_int {
    if (f == null) return -1;
    const r = write(f.?.fd, s, ousia.strlenZ(s));
    return if (r >= 0) 0 else -1;
}

export fn puts(s: [*:0]const u8) c_int {
    const r1 = fputs(s, stdout);
    const r2 = fputc('\n', stdout);
    return if (r1 >= 0 and r2 >= 0) 0 else -1;
}

export fn fwrite(ptr: ?*const anyopaque, size: usize, nmemb: usize, f: ?*FILE) usize {
    if (f == null) return 0;
    const r = write(f.?.fd, ptr, size * nmemb);
    if (r < 0) return 0;
    return @as(usize, @intCast(r)) / size;
}

export fn fread(ptr: ?*anyopaque, size: usize, nmemb: usize, f: ?*FILE) usize {
    if (f == null) return 0;
    const r = read(f.?.fd, ptr, size * nmemb);
    if (r < 0) {
        f.?.err = 1;
        return 0;
    }
    if (r == 0) f.?.eof = 1;
    return @as(usize, @intCast(r)) / size;
}

export fn fflush(f: ?*FILE) c_int {
    _ = f; // 无缓冲实现，恒成功
    return 0;
}

export fn feof(f: ?*FILE) c_int {
    return if (f != null) f.?.eof else 0;
}

export fn ferror(f: ?*FILE) c_int {
    return if (f != null) f.?.err else 0;
}

export fn fseek(f: ?*FILE, off: c_long, whence: c_int) c_int {
    if (f == null) return -1;
    const r = lseek(f.?.fd, off, whence);
    if (r < 0) return -1;
    f.?.eof = 0;
    return 0;
}

export fn ftell(f: ?*FILE) c_long {
    if (f == null) return -1;
    return lseek(f.?.fd, 0, 1); // SEEK_CUR
}

export fn perror(s: [*:0]const u8) void {
    const msg: [*:0]const u8 = strerror(errno);
    _ = ousia.printf("{s}: {s}\n", .{ s[0..ousia.strlenZ(s)], msg[0..ousia.strlenZ(msg)] });
}

// ================= OusiaOS 网络扩展（C 侧包装）=================

export fn ousia_ping(ip: u32, seq: c_int) isize {
    return ousia.netPing(ip, @intCast(seq));
}

export fn ousia_http_get(host: [*:0]const u8, port: c_int, path: [*:0]const u8, buf: [*]u8, len: usize) isize {
    return ousia.syscall5(502, @intFromPtr(host), @as(usize, @bitCast(@as(isize, port))), @intFromPtr(path), @intFromPtr(buf), len);
}

export fn ousia_net_info(buf: [*]u8, len: usize) isize {
    return ousia.syscall3(503, @intFromPtr(buf), len, 0);
}

// ================= dirent.h =================

pub const Dirent = extern struct {
    ino: u64,
    off: i64,
    reclen: u16,
    dtype: u8,
    name: [256]u8,
};

pub const DIR = extern struct {
    fd: c_int,
    buf: [4096]u8,
    len: usize,
    pos: usize,
    ent: Dirent, // readdir 返回的静态槽位
};

export fn opendir(path: [*:0]const u8) ?*DIR {
    const fd = open(path, 0o200000); // O_DIRECTORY
    if (fd < 0) return null;
    const d: *DIR = @ptrCast(@alignCast(ousia.malloc(@sizeOf(DIR)) orelse {
        _ = close(@intCast(fd));
        return null;
    }));
    d.* = .{ .fd = @intCast(fd), .buf = undefined, .len = 0, .pos = 0, .ent = undefined };
    return d;
}

export fn readdir(d: ?*DIR) ?*Dirent {
    if (d == null) return null;
    const dir = d.?;
    if (dir.pos >= dir.len) {
        const r = check(ousia.syscall3(ousia.SYS_getdents64, @intCast(@as(u32, @bitCast(dir.fd))), @intFromPtr(&dir.buf), dir.buf.len));
        if (r <= 0) return null;
        dir.len = @intCast(r);
        dir.pos = 0;
    }
    const rec: *align(1) const Dirent = @ptrFromInt(@intFromPtr(&dir.buf) + dir.pos);
    dir.pos += rec.reclen;
    // 拷到静态槽（内核 dirent 的 name 是变长的）
    dir.ent = .{
        .ino = rec.ino,
        .off = rec.off,
        .reclen = rec.reclen,
        .dtype = rec.dtype,
        .name = undefined,
    };
    const nm: [*]const u8 = @ptrFromInt(@intFromPtr(rec) + 19);
    var i: usize = 0;
    while (i < 255 and nm[i] != 0) : (i += 1) dir.ent.name[i] = nm[i];
    dir.ent.name[i] = 0;
    return &dir.ent;
}

export fn closedir(d: ?*DIR) c_int {
    if (d == null) return -1;
    const r = close(d.?.fd);
    ousia.free(d.?);
    return @intCast(r);
}

// ---- __zig_probe_stack：zig 代码的栈探针（compiler_rt 未随 -nostdlib 链入，
//      需自备）。注意这是 zig 内部 ABI：探测长度经 rax 传入，不走 SysV！
//      实现对齐官方 compiler_rt：向下移动 rsp 逐页触碰，触发内核按需扩栈----
export fn __zig_probe_stack() callconv(.naked) void {
    asm volatile (
        \\push   %rcx
        \\mov    %rax, %rcx
        \\cmp    $0x1000, %rcx
        \\jb     2f
        \\1:
        \\sub    $0x1000, %rsp
        \\orl    $0, 16(%rsp)
        \\sub    $0x1000, %rcx
        \\cmp    $0x1000, %rcx
        \\ja     1b
        \\2:
        \\sub    %rcx, %rsp
        \\orl    $0, 16(%rsp)
        \\add    %rax, %rsp
        \\pop    %rcx
        \\ret
    );
}

comptime {
    _ = @import("crt0.zig");
}
