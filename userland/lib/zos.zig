//! ZOS 用户态库：系统调用封装 + 常用函数（printf/malloc/字符串）
//!
//! 用户程序统一 `const zos = @import("lib/zos.zig");`
//! 并在文件末尾 `comptime { _ = @import("lib/crt0.zig"); }` 拉入 _start。

const std = @import("std");

// ---------------- 裸系统调用 ----------------

pub inline fn syscall0(nr: usize) isize {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> isize),
        : [nr] "{rax}" (nr),
        : .{ .memory = true });
}

pub inline fn syscall1(nr: usize, a1: usize) isize {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> isize),
        : [nr] "{rax}" (nr),
          [a] "{rdi}" (a1),
        : .{ .memory = true });
}

pub inline fn syscall2(nr: usize, a1: usize, a2: usize) isize {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> isize),
        : [nr] "{rax}" (nr),
          [a] "{rdi}" (a1),
          [b] "{rsi}" (a2),
        : .{ .memory = true });
}

pub inline fn syscall3(nr: usize, a1: usize, a2: usize, a3: usize) isize {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> isize),
        : [nr] "{rax}" (nr),
          [a] "{rdi}" (a1),
          [b] "{rsi}" (a2),
          [c] "{rdx}" (a3),
        : .{ .memory = true });
}

pub inline fn syscall5(nr: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) isize {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> isize),
        : [nr] "{rax}" (nr),
          [a] "{rdi}" (a1),
          [b] "{rsi}" (a2),
          [c] "{rdx}" (a3),
          [d] "{r10}" (a4),
          [e] "{r8}" (a5),
        : .{ .memory = true });
}

/// ICMP ping：返回 RTT(ms) 或 -errno
pub fn netPing(ip: u32, seq: u32) isize {
    return syscall3(501, ip, seq, 0);
}

/// 阻塞式 HTTP GET
pub fn httpGet(host: []const u8, port: u16, path: []const u8, out: []u8) isize {
    var hbuf: [256]u8 = undefined;
    var pbuf: [256]u8 = undefined;
    if (host.len >= hbuf.len or path.len >= pbuf.len) return -22;
    @memcpy(hbuf[0..host.len], host);
    hbuf[host.len] = 0;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    return syscall5(502, @intFromPtr(&hbuf), port, @intFromPtr(&pbuf), @intFromPtr(out.ptr), out.len);
}

pub fn parseIp(s: []const u8) ?u32 {
    if (s.len == 0 or s.len > 15) return null;
    var ip: u32 = 0;
    var part: u32 = 0;
    var dots: u8 = 0;
    var digits: u8 = 0;
    for (s) |c| {
        if (c == '.') {
            if (dots == 3 or digits == 0 or part > 255) return null;
            ip |= part << @intCast((3 - dots) * 8);
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
    ip |= part;
    return ip;
}

// 系统调用号（Linux x86_64）
pub const SYS_read = 0;
pub const SYS_write = 1;
pub const SYS_open = 2;
pub const SYS_close = 3;
pub const SYS_fstat = 5;
pub const SYS_mmap = 9;
pub const SYS_brk = 12;
pub const SYS_ioctl = 16;
pub const SYS_lseek = 19;
pub const SYS_nanosleep = 35;
pub const SYS_getpid = 39;
pub const SYS_fork = 57;
pub const SYS_execve = 59;
pub const SYS_exit = 60;
pub const SYS_wait4 = 61;
pub const SYS_uname = 63;
pub const SYS_getcwd = 79;
pub const SYS_chdir = 80;
pub const SYS_dup = 32;
pub const SYS_dup2 = 33;
pub const SYS_getdents64 = 217;
pub const SYS_time = 201;
pub const SYS_chmod = 90;
pub const SYS_chown = 92;
pub const SYS_getuid = 102;
pub const SYS_getgid = 104;
pub const SYS_setuid = 105;
pub const SYS_setgid = 106;
pub const SYS_mkdir = 83;
pub const SYS_rmdir = 84;
pub const SYS_unlink = 87;
pub const SYS_zos_wav = 506;
pub const SYS_zos_sound = 507;
pub const SYS_zos_fsinfo = 508;

// ---------------- POSIX 风格 API ----------------

pub fn exit(code: i32) noreturn {
    _ = syscall1(SYS_exit, @as(usize, @as(u32, @bitCast(code))));
    unreachable;
}

pub fn read(fd: i32, buf: []u8) isize {
    return syscall3(SYS_read, @intCast(fd), @intFromPtr(buf.ptr), buf.len);
}

pub fn write(fd: i32, buf: []const u8) isize {
    return syscall3(SYS_write, @intCast(fd), @intFromPtr(buf.ptr), buf.len);
}

/// open(path) 封装（flags：0 读 / 1 写 / 2 读写 | O_CREAT(0o100) 等）
pub fn open(path: []const u8, flags: i32) isize {
    return openMode(path, flags, 0);
}

/// open 带创建权限位（O_CREAT 时新文件的 mode，八进制如 0o644）
pub fn openMode(path: []const u8, flags: i32, mode: u32) isize {
    var zbuf: [256]u8 = undefined;
    const p = withNul(&zbuf, path);
    return syscall3(SYS_open, @intFromPtr(p.ptr), @intCast(@as(u32, @bitCast(flags))), mode);
}

// open flags（与内核/ Linux 一致）
pub const O_RDONLY: i32 = 0;
pub const O_WRONLY: i32 = 1;
pub const O_RDWR: i32 = 2;
pub const O_CREAT: i32 = 0o100;
pub const O_TRUNC: i32 = 0o1000;
pub const O_DIRECTORY: i32 = 0o200000;

/// dup2(oldfd, newfd)：把 oldfd 复制到指定槽位（shell 重定向 `>` 的基础）
pub fn dup2(oldfd: i32, newfd: i32) isize {
    return syscall2(SYS_dup2, @intCast(oldfd), @intCast(newfd));
}

/// fsinfo(buf)：文件系统概要一行（df 命令用），返回字节数；<0 = 无磁盘
pub fn fsinfo(buf: []u8) isize {
    return syscall2(SYS_zos_fsinfo, @intFromPtr(buf.ptr), buf.len);
}

/// mkdir(path, perm)：创建目录（练习 5 的可写文件系统）
pub fn mkdir(path: []const u8, perm: u32) isize {
    var zbuf: [256]u8 = undefined;
    const p = withNul(&zbuf, path);
    return syscall2(SYS_mkdir, @intFromPtr(p.ptr), perm);
}

/// rmdir(path)：删除空目录
pub fn rmdir(path: []const u8) isize {
    var zbuf: [256]u8 = undefined;
    const p = withNul(&zbuf, path);
    return syscall1(SYS_rmdir, @intFromPtr(p.ptr));
}

/// unlink(path)：删除文件
pub fn unlink(path: []const u8) isize {
    var zbuf: [256]u8 = undefined;
    const p = withNul(&zbuf, path);
    return syscall1(SYS_unlink, @intFromPtr(p.ptr));
}

/// 播放 WAV 文件（48k 之外的采样率由内核重采样；阻塞至播完）
pub fn playWav(path: []const u8) isize {
    var zbuf: [256]u8 = undefined;
    const p = withNul(&zbuf, path);
    return syscall1(SYS_zos_wav, @intFromPtr(p.ptr));
}

pub fn close(fd: i32) isize {
    return syscall1(SYS_close, @intCast(fd));
}

pub fn lseek(fd: i32, off: isize, whence: i32) isize {
    return syscall3(SYS_lseek, @intCast(fd), @bitCast(off), @intCast(whence));
}

pub fn isatty(fd: i32) bool {
    return syscall3(SYS_ioctl, @intCast(fd), 0x5401, 0) == 0;
}

pub fn getpid() i32 {
    return @intCast(syscall0(SYS_getpid));
}

/// 自开机起的秒数（教学内核的"墙上时钟"）
pub fn time() i64 {
    return syscall1(SYS_time, 0);
}

pub fn dup(fd: i32) isize {
    return syscall1(SYS_dup, @intCast(fd));
}

pub fn fork() i32 {
    return @intCast(syscall0(SYS_fork));
}

pub fn execve(path: []const u8, argv: []const []const u8) isize {
    var pbuf: [256]u8 = undefined;
    var abuf: [16][256]u8 = undefined;
    var ptrs: [17]usize = undefined; // 16 个指针 + NULL
    for (argv, 0..) |a, i| {
        @memcpy(abuf[i][0..a.len], a);
        abuf[i][a.len] = 0;
        ptrs[i] = @intFromPtr(&abuf[i]);
    }
    ptrs[argv.len] = 0;
    const p = withNul(&pbuf, path);
    return syscall3(SYS_execve, @intFromPtr(p.ptr), @intFromPtr(&ptrs[0]), 0);
}

pub fn waitpid(pid: i32, status: *i32) isize {
    return syscall3(SYS_wait4, @intCast(pid), @intFromPtr(status), 0);
}

pub fn sleepMs(ms: u64) void {
    var ts: [2]i64 = .{ @intCast(ms / 1000), @intCast((ms % 1000) * 1_000_000) };
    _ = syscall1(SYS_nanosleep, @intFromPtr(&ts));
}

pub fn getcwd(buf: []u8) isize {
    return syscall3(SYS_getcwd, @intFromPtr(buf.ptr), buf.len, 0);
}

pub fn chdir(path: []const u8) isize {
    var zbuf: [256]u8 = undefined;
    const p = withNul(&zbuf, path);
    return syscall1(SYS_chdir, @intFromPtr(p.ptr));
}

pub const Dirent = struct {
    name: [256]u8 = undefined,
    name_len: usize = 0,
    is_dir: bool = false,

    pub fn nameSlice(self: *const Dirent) []const u8 {
        return self.name[0..self.name_len];
    }
};

// ---------------- Linux 权限 ----------------
//
// st_mode 的类型位：S_IFREG=0100000 S_IFDIR=040000 S_IFCHR=020000；
// 权限位 rwxrwxrwx 与 Linux 相同（owner/group/other 各 3 位）。

pub const Stat = struct {
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    size: u64 = 0,
};

/// fstat 封装：x86_64 struct stat 关键字段 mode@24 uid@28 gid@32 size@48
pub fn fstat(fd: i32) ?Stat {
    var buf: [144]u8 = undefined;
    const r = syscall3(SYS_fstat, @intCast(fd), @intFromPtr(&buf), 0);
    if (r != 0) return null;
    const rd32 = struct {
        fn f(b: []const u8, off: usize) u32 {
            return b[off] | (@as(u32, b[off + 1]) << 8) | (@as(u32, b[off + 2]) << 16) | (@as(u32, b[off + 3]) << 24);
        }
    }.f;
    const rd64 = struct {
        fn f(b: []const u8, off: usize) u64 {
            var v: u64 = 0;
            for (0..8) |i| v |= @as(u64, b[off + i]) << @intCast(8 * i);
            return v;
        }
    }.f;
    return .{ .mode = rd32(&buf, 24), .uid = rd32(&buf, 28), .gid = rd32(&buf, 32), .size = rd64(&buf, 48) };
}

/// stat(path) 封装（open+fstat+close）
pub fn stat(path: []const u8) ?Stat {
    const fd = open(path, 0);
    if (fd < 0) return null;
    defer _ = close(@intCast(fd));
    return fstat(@intCast(fd));
}

pub fn getuid() u32 {
    return @intCast(@max(0, syscall0(SYS_getuid)));
}

pub fn getgid() u32 {
    return @intCast(@max(0, syscall0(SYS_getgid)));
}

/// root 可切任意 uid；普通用户只能切到自己（Linux 同款限制）
pub fn setuid(uid: u32) isize {
    return syscall1(SYS_setuid, uid);
}

pub fn setgid(gid: u32) isize {
    return syscall1(SYS_setgid, gid);
}

pub fn chmod(path: []const u8, mode: u32) isize {
    var zbuf: [256]u8 = undefined;
    const p = withNul(&zbuf, path);
    return syscall3(SYS_chmod, @intFromPtr(p.ptr), mode, 0);
}

/// chown(path, uid, gid)；gid 传 -1 表示不改 gid
pub fn chown(path: []const u8, uid: u32, gid: i64) isize {
    var zbuf: [256]u8 = undefined;
    const p = withNul(&zbuf, path);
    return syscall3(SYS_chown, @intFromPtr(p.ptr), uid, @as(usize, @bitCast(gid)));
}

/// "rwxr-x--t" 风格权限串（含类型位 d/-/c）
pub fn modeString(mode: u32, out: *[10]u8) []const u8 {
    out[0] = switch (mode & 0o170000) {
        0o040000 => 'd',
        0o020000 => 'c',
        else => '-',
    };
    const bits = "rwxrwxrwx";
    for (bits, 1..) |b, i| {
        const bitpos: u5 = @intCast(9 - i);
        out[i] = if ((mode >> bitpos) & 1 != 0) b else '-';
    }
    return out[0..10];
}

/// 列目录（getdents64 封装，一次取全部）
pub fn listDir(path: []const u8, out: []Dirent) isize {
    const fd = open(path, 0); // O_RDONLY
    if (fd < 0) return fd;
    defer _ = close(@intCast(fd));

    var buf: [4096]u8 = undefined;
    const n = syscall3(SYS_getdents64, @intCast(fd), @intFromPtr(&buf), buf.len);
    if (n <= 0) return n;

    var cnt: usize = 0;
    var off: usize = 0;
    while (off < @as(usize, @intCast(n))) {
        const rec: *align(1) const extern struct {
            ino: u64,
            off: i64,
            reclen: u16,
            dtype: u8,
        } = @ptrFromInt(@intFromPtr(&buf) + off);
        const name_ptr: [*]const u8 = @ptrFromInt(@intFromPtr(&buf) + off + 19);
        var l: usize = 0;
        while (name_ptr[l] != 0) l += 1;
        if (cnt < out.len) {
            @memcpy(out[cnt].name[0..l], name_ptr[0..l]);
            out[cnt].name_len = l;
            out[cnt].is_dir = rec.dtype == 4;
            cnt += 1;
        }
        off += rec.reclen;
    }
    return @intCast(cnt);
}

// ---------------- 命令行参数 ----------------

extern var __argc: i64;
extern var __argv: [*]const ?[*:0]const u8;

pub fn argc() usize {
    return @intCast(__argc);
}

/// 取第 i 个参数（副本，静态缓冲轮换）
pub fn arg(i: usize) []const u8 {
    if (i >= argc()) return "";
    const p = __argv[i] orelse return "";
    var l: usize = 0;
    while (p[l] != 0) l += 1;
    return p[0..l];
}

// ---------------- printf ----------------

var out_buf: [4096]u8 = undefined;
var out_len: usize = 0;

pub fn printf(comptime fmt: []const u8, args: anytype) void {
    out_len = 0;
    formatTo(fmt, args);
    flush();
}

fn flush() void {
    if (out_len > 0) _ = write(1, out_buf[0..out_len]);
    out_len = 0;
}

fn putc(c: u8) void {
    if (out_len >= out_buf.len) flush();
    out_buf[out_len] = c;
    out_len += 1;
}

fn puts(s: []const u8) void {
    for (s) |c| putc(c);
}

fn formatTo(comptime fmt: []const u8, args: anytype) void {
    @setEvalBranchQuota(100000);
    const info = @typeInfo(@TypeOf(args)).@"struct";
    comptime var ai: usize = 0;
    comptime var i: usize = 0;
    inline while (i < fmt.len) {
        if (fmt[i] == '{') {
            comptime var j = i + 1;
            // 占位符: {type} 或 {type:<w} / {type:>w}
            comptime var spec: u8 = 0;
            comptime var width: usize = 0;
            comptime var align_left = false;
            inline while (j < fmt.len and fmt[j] != '}') : (j += 1) {
                if (fmt[j] == ':') {
                    // 忽略分隔符
                } else if (fmt[j] == '<' or fmt[j] == '>') {
                    align_left = fmt[j] == '<';
                } else if (fmt[j] >= '0' and fmt[j] <= '9') {
                    width = width * 10 + (fmt[j] - '0');
                } else {
                    spec = fmt[j];
                }
            }
            emitArg(ai, spec, width, align_left, info, args);
            ai += 1;
            i = j + 1;
        } else {
            putc(fmt[i]);
            i += 1;
        }
    }
    comptime {
        if (ai != info.field_names.len) @compileError("printf: 参数数量不匹配");
    }
}

var pad_buf: [256]u8 = undefined;

fn emitArg(comptime idx: usize, comptime spec: u8, comptime width: usize, comptime align_left: bool, comptime info: anytype, args: anytype) void {
    const v = @field(args, info.field_names[idx]);
    const kind: u8 = switch (spec) {
        's', 'c', 'd', 'x' => spec,
        0 => switch (@typeInfo(@TypeOf(v))) {
            .pointer => 's',
            else => 'd',
        },
        else => 0xFF,
    };
    if (kind == 0xFF) {
        puts("{?}");
        return;
    }
    if (width == 0) {
        switch (kind) {
            's' => puts(v),
            'c' => putc(v),
            else => putNum(v, if (kind == 'x') 16 else 10),
        }
        return;
    }
    // 带宽度：先渲染到 pad_buf 再对齐输出
    var plen: usize = 0;
    switch (kind) {
        's' => {
            for (v) |c| {
                if (plen < pad_buf.len) {
                    pad_buf[plen] = c;
                    plen += 1;
                }
            }
        },
        'c' => {
            pad_buf[0] = v;
            plen = 1;
        },
        else => {
            plen = renderNum(&pad_buf, v, if (kind == 'x') 16 else 10);
        },
    }
    const w = @min(width, pad_buf.len);
    if (plen >= w) {
        puts(pad_buf[0..plen]);
        return;
    }
    if (align_left) {
        puts(pad_buf[0..plen]);
        var k: usize = plen;
        while (k < w) : (k += 1) putc(' ');
    } else {
        var k: usize = plen;
        while (k < w) : (k += 1) putc(' ');
        puts(pad_buf[0..plen]);
    }
}

/// 渲染数字到 buf，返回长度
fn renderNum(buf: []u8, v: anytype, base: u8) usize {
    const T = @TypeOf(v);
    var u: u64 = 0;
    var neg = false;
    switch (@typeInfo(T)) {
        .int => |ti| {
            if (ti.signedness == .signed) {
                const sv: i64 = @intCast(v);
                if (sv < 0) {
                    neg = true;
                    u = @intCast(-(sv + 1));
                    u += 1;
                } else u = @intCast(sv);
            } else u = @intCast(v);
        },
        .comptime_int => u = @intCast(v),
        else => return 0,
    }
    var n: usize = 0;
    if (u == 0) {
        buf[0] = '0';
        return 1;
    }
    while (u > 0) {
        const d: u8 = @intCast(u % base);
        buf[n] = if (d < 10) '0' + d else 'a' + d - 10;
        n += 1;
        u /= base;
    }
    if (neg) {
        buf[n] = '-';
        n += 1;
    }
    var a: usize = 0;
    var b: usize = n - 1;
    while (a < b) {
        const t = buf[a];
        buf[a] = buf[b];
        buf[b] = t;
        a += 1;
        b -= 1;
    }
    return n;
}

fn putNum(v: anytype, base: u8) void {
    var b: [24]u8 = undefined;
    const n = renderNum(&b, v, base);
    puts(b[0..n]);
}

// ---------------- malloc（首次适应 + 空闲链表）----------------
//
// 教学要点：经典 K&R 风格分配器——块头记录大小与空闲位，块按地址序
// 链接；malloc 找首个够大的空闲块（可分裂），free 标记空闲并与
// 前后相邻空闲块合并，堆不足时用 brk 向内核要新页。
//
//   [Header|数据...][Header|数据...]...   ← brk 堆区

const HeapHeader = extern struct {
    size: usize, // 含头在内的整块字节数
    free: bool,
    next: ?*HeapHeader, // 地址序单链表
};

const HEAP_MIN_BLOCK = @sizeOf(HeapHeader) + 16;
const HEAP_ALIGN: usize = 16;
const HEAP_ALIGN_MASK: usize = HEAP_ALIGN - 1;

var heap_head: ?*HeapHeader = null;
var heap_end: usize = 0; // brk 当前顶

fn brkGrow(nbytes: usize) bool {
    if (heap_end == 0) {
        heap_end = @intCast(@as(u64, @bitCast(syscall1(SYS_brk, 0))));
        if (heap_end == 0) return false;
    }
    const want = (heap_end + nbytes + 0xFFF) & ~@as(usize, 0xFFF);
    const r = syscall1(SYS_brk, want);
    if (@as(usize, @intCast(r)) < want) return false;
    return true;
}

pub fn malloc(n: usize) ?[*]u8 {
    const need = (n + HEAP_ALIGN_MASK) & ~HEAP_ALIGN_MASK;
    const want = need + @sizeOf(HeapHeader);

    // 1) 空闲链表里找首个够大的块（first fit）
    var it = heap_head;
    while (it) |h| : (it = h.next) {
        if (!h.free or h.size < want) continue;
        // 剩余部分足够放下一个最小块 → 分裂
        if (h.size >= want + HEAP_MIN_BLOCK) {
            const rest: *HeapHeader = @ptrFromInt(@intFromPtr(h) + want);
            rest.* = .{
                .size = h.size - want,
                .free = true,
                .next = h.next,
            };
            h.size = want;
            h.next = rest;
        }
        h.free = false;
        return @ptrFromInt(@intFromPtr(h) + @sizeOf(HeapHeader));
    }

    // 2) 顶部扩展：若尾块空闲则就地扩容，否则追加新块
    if (!brkGrow(want)) return null;
    const nb: *HeapHeader = @ptrFromInt(heap_end);
    nb.* = .{ .size = want, .free = false, .next = null };
    heap_end += want;

    // 接到链尾
    if (heap_head == null) {
        heap_head = nb;
    } else {
        var tail = heap_head.?;
        while (tail.next) |t| tail = t;
        tail.next = nb;
    }
    return @ptrFromInt(@intFromPtr(nb) + @sizeOf(HeapHeader));
}

pub fn free(p: anytype) void {
    const addr = @intFromPtr(p);
    if (addr == 0) return;
    const h: *HeapHeader = @ptrFromInt(addr - @sizeOf(HeapHeader));
    h.free = true;

    // 与相邻空闲块合并（链表按地址序，一遍扫描做全部合并）
    var it = heap_head;
    while (it) |a| : (it = a.next) {
        const b = a.next orelse break;
        if (a.free and @intFromPtr(a) + a.size == @intFromPtr(b) and b.free) {
            a.size += b.size;
            a.next = b.next;
        }
    }
}

pub fn calloc(n: usize, sz: usize) ?[*]u8 {
    const total = std.math.mul(usize, n, sz) catch return null;
    const p = malloc(total) orelse return null;
    @memset(p[0..total], 0);
    return p;
}

pub fn realloc(old: anytype, n: usize) ?[*]u8 {
    const addr = @intFromPtr(old);
    if (addr == 0) return malloc(n);
    const h: *HeapHeader = @ptrFromInt(addr - @sizeOf(HeapHeader));
    const old_len = h.size - @sizeOf(HeapHeader);
    const p = malloc(n) orelse return null;
    const copy_len = @min(old_len, n);
    @memcpy(p[0..copy_len], @as([*]const u8, @ptrFromInt(addr))[0..copy_len]);
    free(old);
    return p;
}

// ---------------- 字符串工具 ----------------

pub fn strlenZ(p: [*:0]const u8) usize {
    var i: usize = 0;
    while (p[i] != 0) i += 1;
    return i;
}

pub fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

pub fn startsWith(s: []const u8, pre: []const u8) bool {
    if (s.len < pre.len) return false;
    return eql(s[0..pre.len], pre);
}

fn withNul(buf: []u8, s: []const u8) []u8 {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return buf[0 .. n + 1];
}

// ---------------- panic ----------------

fn userPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    printf("!!! PANIC: {s} (at {x})\n", .{ msg, ret_addr });
    exit(99);
}

/// 自定义 panic 命名空间：所有安全检查（越界/溢出/空指针解引用等）
/// 都路由到我们自己的 printf。不能用 std.debug.FullPanic——它的派生
/// 钩子会调用 std 的默认打印器，在裸机上直接 @trap 吞掉错误信息。
pub const panic = struct {
    pub const call = userPanic;

    pub fn sentinelMismatch(expected: anytype, found: @TypeOf(expected)) noreturn {
        printf("!!! PANIC: sentinelMismatch (found {d})\n", .{found});
        exit(99);
    }

    pub fn inactiveUnionField(active: anytype, accessed: @TypeOf(active)) noreturn {
        printf("!!! PANIC: inactiveUnionField {s}/{s}\n", .{ @typeName(@TypeOf(active)), @typeName(@TypeOf(accessed)) });
        exit(99);
    }

    pub fn unwrapError(err: anyerror) noreturn {
        printf("!!! PANIC: unwrapError\n", .{});
        _ = .{ err };
        exit(99);
    }

    pub fn outOfBounds(index: usize, len: usize) noreturn {
        printf("!!! PANIC: outOfBounds\n", .{});
        _ = .{ index, len };
        exit(99);
    }

    pub fn startGreaterThanEnd(start: usize, end: usize) noreturn {
        printf("!!! PANIC: startGreaterThanEnd\n", .{});
        _ = .{ start, end };
        exit(99);
    }

    pub fn sliceCastLenRemainder(src_len: usize) noreturn {
        printf("!!! PANIC: sliceCastLenRemainder\n", .{});
        _ = .{ src_len };
        exit(99);
    }

    pub fn reachedUnreachable() noreturn {
        printf("!!! PANIC: reachedUnreachable\n", .{});
        exit(99);
    }

    pub fn unwrapNull() noreturn {
        printf("!!! PANIC: unwrapNull\n", .{});
        exit(99);
    }

    pub fn castToNull() noreturn {
        printf("!!! PANIC: castToNull\n", .{});
        exit(99);
    }

    pub fn incorrectAlignment() noreturn {
        printf("!!! PANIC: incorrectAlignment\n", .{});
        exit(99);
    }

    pub fn invalidErrorCode() noreturn {
        printf("!!! PANIC: invalidErrorCode\n", .{});
        exit(99);
    }

    pub fn unexpectedErrorCode(err: anyerror) noreturn {
        printf("!!! PANIC: unexpectedErrorCode\n", .{});
        _ = .{ err };
        exit(99);
    }

    pub fn integerOutOfBounds() noreturn {
        printf("!!! PANIC: integerOutOfBounds\n", .{});
        exit(99);
    }

    pub fn integerOverflow() noreturn {
        printf("!!! PANIC: integerOverflow\n", .{});
        exit(99);
    }

    pub fn shlOverflow() noreturn {
        printf("!!! PANIC: shlOverflow\n", .{});
        exit(99);
    }

    pub fn shrOverflow() noreturn {
        printf("!!! PANIC: shrOverflow\n", .{});
        exit(99);
    }

    pub fn divideByZero() noreturn {
        printf("!!! PANIC: divideByZero\n", .{});
        exit(99);
    }

    pub fn exactDivisionRemainder() noreturn {
        printf("!!! PANIC: exactDivisionRemainder\n", .{});
        exit(99);
    }

    pub fn integerPartOutOfBounds() noreturn {
        printf("!!! PANIC: integerPartOutOfBounds\n", .{});
        exit(99);
    }

    pub fn corruptSwitch() noreturn {
        printf("!!! PANIC: corruptSwitch\n", .{});
        exit(99);
    }

    pub fn shiftRhsTooBig() noreturn {
        printf("!!! PANIC: shiftRhsTooBig\n", .{});
        exit(99);
    }

    pub fn invalidEnumValue() noreturn {
        printf("!!! PANIC: invalidEnumValue\n", .{});
        exit(99);
    }

    pub fn forLenMismatch() noreturn {
        printf("!!! PANIC: forLenMismatch\n", .{});
        exit(99);
    }

    pub fn copyLenMismatch() noreturn {
        printf("!!! PANIC: copyLenMismatch\n", .{});
        exit(99);
    }

    pub fn memcpyAlias() noreturn {
        printf("!!! PANIC: memcpyAlias\n", .{});
        exit(99);
    }

    pub fn noreturnReturned() noreturn {
        printf("!!! PANIC: noreturnReturned\n", .{});
        exit(99);
    }

    pub fn loadUninstantiableType() noreturn {
        printf("!!! PANIC: loadUninstantiableType\n", .{});
        exit(99);
    }

};

