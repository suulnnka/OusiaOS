//! POSIX 系统调用子集（int 0x80 软中断）
//!
//! 教学要点：
//!   - 系统调用 = 受控的"用户态→内核态"入口：IDT 0x80 号门 DPL=3，
//!     CPU 自动切到 TSS.rsp0 的内核栈，压入返回现场
//!   - 约定与 Linux x86_64 一致：nr=RAX，参数 RDI/RSI/RDX，
//!     返回值 RAX（负数 = -errno）
//!   - 用户指针在当前 CR3（用户页表）下直接有效，内核可直接访问——
//!     因为陷入时 CR3 就是该进程的页表，且内核半区共享
//!
//! 已实现的调用（Linux x86_64 编号）：
//!   read(0) write(1) open(2) close(3) fstat(5) mmap(9, 仅匿名)
//!   mprotect(10,空操作) munmap(11,空操作) brk(12) ioctl(16) lseek(19)
//!   nanosleep(35) getpid(39) fork(57) execve(59) exit(60) wait4(61)
//!   uname(63) getcwd(79) chdir(80) getdents64(217)

const std = @import("std");
const console = @import("console.zig");
const idt = @import("idt.zig");
const proc = @import("proc.zig");
const vfs = @import("vfs.zig");
const pit = @import("pit.zig");
const gdt = @import("gdt.zig");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");

const TrapFrame = idt.TrapFrame;

// ---- Linux x86_64 系统调用号 ----
const SYS_read = 0;
const SYS_write = 1;
const SYS_open = 2;
const SYS_close = 3;
const SYS_fstat = 5;
const SYS_mmap = 9;
const SYS_mprotect = 10;
const SYS_munmap = 11;
const SYS_brk = 12;
const SYS_ioctl = 16;
const SYS_lseek = 19;
const SYS_nanosleep = 35;
const SYS_getpid = 39;
const SYS_fork = 57;
const SYS_execve = 59;
const SYS_exit = 60;
const SYS_wait4 = 61;
const SYS_uname = 63;
const SYS_getcwd = 79;
const SYS_chdir = 80;
const SYS_dup = 32;
const SYS_getdents64 = 217;
const SYS_time = 201;
const SYS_zos_psinfo = 500; // ZOS 自定义：读取进程表（ps 命令用）
const SYS_zos_ping = 501; // ZOS 自定义：ICMP ping
const SYS_zos_http = 502; // ZOS 自定义：阻塞式 HTTP GET
const SYS_zos_net_info = 503; // ZOS 自定义：网络配置字符串
const SYS_zos_beep = 505; // ZOS 自定义：AC'97 蜂鸣（正弦单音）

// ---- errno ----
const EPERM: isize = -1;
const ENOENT: isize = -2;
const EBADF: isize = -9;
const ECHILD: isize = -10;
const EAGAIN: isize = -11;
const ENOMEM: isize = -12;
const ENOTDIR: isize = -20;
const EACCES: isize = -13;
const EFAULT: isize = -14;
const EEXIST: isize = -17;
const EISDIR: isize = -21;
const EINVAL: isize = -22;
const ENOTTY: isize = -25;
const EROFS: isize = -30;
const ESPIPE: isize = -29;
const ENOSYS: isize = -38;

// ---- 常量 ----
const O_RDONLY: usize = 0;
const O_WRONLY: usize = 1;
const O_RDWR: usize = 2;
const O_DIRECTORY: usize = 0o200000;

const PROT_READ: usize = 1;
const PROT_WRITE: usize = 2;
const MAP_PRIVATE: usize = 2;
const MAP_ANONYMOUS: usize = 0x20;

/// 入口：由 idt.trapDispatch 调用（intno == 0x80）
pub fn handle(frame: *TrapFrame) void {
    if (!idt.fromUser(frame)) {
        // 内核态发出的 int 0x80：TrapFrame 布局不同（无 rsp/ss），拒绝
        frame.rax = @bitCast(ENOSYS);
        return;
    }

    const nr: usize = @intCast(frame.rax);
    const a1: usize = @intCast(frame.rdi);
    const a2: usize = @intCast(frame.rsi);
    const a3: usize = @intCast(frame.rdx);

    const ret: isize = switch (nr) {
        SYS_read => sysRead(a1, a2, a3),
        SYS_write => sysWrite(a1, a2, a3),
        SYS_open => sysOpen(a1, a2, a3),
        SYS_close => sysClose(a1),
        SYS_fstat => sysFstat(a1, a2),
        SYS_mmap => sysMmap(a1, a2, a3),
        SYS_mprotect => 0,
        SYS_munmap => 0,
        SYS_brk => sysBrk(a1),
        SYS_ioctl => sysIoctl(a1, a2, a3),
        SYS_lseek => sysLseek(a1, a2, a3),
        SYS_nanosleep => sysNanosleep(a1),
        SYS_getpid => @intCast(proc.current().?.pid),
        SYS_fork => sysFork(),
        SYS_execve => sysExecve(a1, a2),
        SYS_exit => sysExit(a1),
        SYS_wait4 => sysWait4(a1, a2),
        SYS_uname => sysUname(a1),
        SYS_getcwd => sysGetcwd(a1, a2),
        SYS_chdir => sysChdir(a1),
        SYS_dup => sysDup(a1),
        SYS_getdents64 => sysGetdents64(a1, a2, a3),
        SYS_time => @intCast(pit.uptimeMs() / 1000),
        SYS_zos_psinfo => sysPsinfo(a1, a2),
        SYS_zos_ping => @import("net.zig").ping(@truncate(a1), @truncate(a2)),
        SYS_zos_http => sysHttpGet(a1, @truncate(a2), a3, frame),
        SYS_zos_net_info => sysNetInfo(a1, a2),
        SYS_zos_beep => sysBeep(a1, a2),
        else => ENOSYS,
    };

    frame.rax = @bitCast(ret);
}

// ================= 文件 IO =================

fn getFd(p: *proc.Proc, fd: usize) ?*proc.OpenFile {
    if (fd >= proc.MAX_FD) return null;
    if (!p.fds[fd].used) return null;
    return &p.fds[fd];
}

fn userSlice(ptr: usize, len: usize) []u8 {
    return @as([*]u8, @ptrFromInt(ptr))[0..len];
}

fn userSliceConst(ptr: usize, len: usize) []const u8 {
    return @as([*]const u8, @ptrFromInt(ptr))[0..len];
}

/// C 字符串 → 长度（带上限防越界）
fn cstrLen(ptr: usize, max: usize) usize {
    const s: [*]const u8 = @ptrFromInt(ptr);
    var i: usize = 0;
    while (i < max and s[i] != 0) i += 1;
    return i;
}

fn sysRead(fd: usize, buf: usize, count: usize) isize {
    const p = proc.current().?;
    const f = getFd(p, fd) orelse return EBADF;
    const inf = vfs.info(f.node);
    if (inf.is_dir) return EISDIR;
    if (count == 0) return 0;
    const n = vfs.read(f.node, f.pos, userSlice(buf, @min(count, 65536)));
    if (n > 0) f.pos += @intCast(n);
    return n;
}

fn sysWrite(fd: usize, buf: usize, count: usize) isize {
    const p = proc.current().?;
    const f = getFd(p, fd) orelse return EBADF;
    return vfs.write(f.node, userSliceConst(buf, @min(count, 65536)));
}

fn sysOpen(path: usize, flags: usize, mode: usize) isize {
    _ = mode;
    const p = proc.current().?;
    const plen = cstrLen(path, 255);
    if (plen == 0) return EINVAL;
    const path_s = userSliceConst(path, plen);

    const node = vfs.resolve(path_s, p.cwd()) orelse return ENOENT;
    const inf = vfs.info(node);

    // 只读文件系统：写打开只允许 console
    if ((flags & 3) != O_RDONLY and !inf.is_console) return EROFS;
    if (inf.is_dir and (flags & 3) != O_RDONLY) return EISDIR;

    // 分配 fd
    var fd: ?usize = null;
    for (0..proc.MAX_FD) |i| {
        if (!p.fds[i].used) {
            fd = i;
            break;
        }
    }
    const fdi = fd orelse return EAGAIN;
    p.fds[fdi] = .{ .used = true, .node = node, .pos = 0 };
    return @intCast(fdi);
}

/// dup：复制 fd（shell 重定向的基础）
fn sysDup(fd: usize) isize {
    const p = proc.current().?;
    if (getFd(p, fd) == null) return EBADF;
    var slot: ?usize = null;
    for (0..proc.MAX_FD) |i| {
        if (!p.fds[i].used) {
            slot = i;
            break;
        }
    }
    const i = slot orelse return EAGAIN;
    p.fds[i] = p.fds[fd];
    return @intCast(i);
}

fn sysClose(fd: usize) isize {
    const p = proc.current().?;
    const f = getFd(p, fd) orelse return EBADF;
    f.used = false;
    return 0;
}

/// x86_64 struct stat 关键字段偏移：st_mode@16, st_size@48
fn sysFstat(fd: usize, buf: usize) isize {
    const p = proc.current().?;
    const f = getFd(p, fd) orelse return EBADF;
    const inf = vfs.info(f.node);
    const b = userSlice(buf, 144);
    @memset(b, 0);
    writeU32(b, 24, inf.mode);
    writeU64(b, 48, inf.size);
    writeU64(b, 8, @intCast(f.node)); // st_ino
    return 0;
}

fn writeU32(b: []u8, off: usize, v: u32) void {
    inline for (0..4) |i| b[off + i] = @truncate(v >> @intCast(8 * i));
}
fn writeU64(b: []u8, off: usize, v: u64) void {
    inline for (0..8) |i| b[off + i] = @truncate(v >> @intCast(8 * i));
}

/// 匿名 mmap：忽略 hint，从进程 mmap 游标分配（RW 用户页）
fn sysMmap(addr: usize, len: usize, prot: usize) isize {
    _ = addr;
    _ = prot;
    const p = proc.current().?;
    if (len == 0) return EINVAL;
    const pages = (len + 0xFFF) / 0x1000;
    if (pages > 1024) return ENOMEM;
    const vstart = p.mmap_next;
    var i: usize = 0;
    while (i < pages) : (i += 1) {
        const frame = pmm.allocFrame() orelse {
            // 回滚
            var j: usize = 0;
            while (j < i) : (j += 1) vmm.unmapPage(p.page_map, vstart + j * 0x1000);
            return ENOMEM;
        };
        @memset(@as([*]u8, @ptrFromInt(vmm.physToVirt(frame)))[0..4096], 0);
        if (!vmm.mapPage(p.page_map, vstart + i * 0x1000, frame, vmm.P | vmm.W | vmm.U)) {
            pmm.freeFrame(frame);
            return ENOMEM;
        }
    }
    p.mmap_next = vstart + pages * 0x1000 + 0x1000;
    return @intCast(vstart);
}

fn sysBrk(addr: usize) isize {
    const p = proc.current().?;
    if (addr == 0) return @intCast(p.brk);
    if (addr < 0x1000 or addr > p.brk + 32 * 1024 * 1024) return @intCast(p.brk); // 无效/超额：不动
    // 只增长（收缩不还页，教学简化）
    var va = (p.brk + 0xFFF) & ~@as(usize, 0xFFF);
    while (va < addr) : (va += 0x1000) {
        if (vmm.isMapped(p.page_map, va)) continue;
        const frame = pmm.allocFrame() orelse break;
        @memset(@as([*]u8, @ptrFromInt(vmm.physToVirt(frame)))[0..4096], 0);
        if (!vmm.mapPage(p.page_map, va, frame, vmm.P | vmm.W | vmm.U)) {
            pmm.freeFrame(frame);
            break;
        }
    }
    p.brk = addr;
    return @intCast(p.brk);
}

/// isatty 探测依赖它：console+TCGETS 返回 0
fn sysIoctl(fd: usize, req: usize, arg: usize) isize {
    _ = arg;
    const p = proc.current().?;
    const f = getFd(p, fd) orelse return EBADF;
    if (f.node == vfs.CONSOLE_NODE and req == 0x5401) return 0; // TCGETS
    return ENOTTY;
}

fn sysLseek(fd: usize, off: usize, whence: usize) isize {
    const p = proc.current().?;
    const f = getFd(p, fd) orelse return EBADF;
    if (f.node == vfs.CONSOLE_NODE) return ESPIPE;
    const inf = vfs.info(f.node);
    const base: i64 = switch (whence) {
        0 => 0, // SEEK_SET
        1 => @intCast(f.pos), // SEEK_CUR
        2 => @intCast(inf.size), // SEEK_END
        else => return EINVAL,
    };
    const o: i64 = base + @as(i64, @bitCast(off));
    if (o < 0) return EINVAL;
    f.pos = @intCast(o);
    return o;
}

// ================= 进程控制 =================

fn sysFork() isize {
    const child = proc.fork() orelse return EAGAIN;
    return @intCast(child.pid);
}

/// execve：argv 是用户空间里的 char* 数组（NULL 结尾）
fn sysExecve(path: usize, argv: usize) isize {
    const plen = cstrLen(path, 255);
    if (plen == 0) return EINVAL;
    const path_s = userSliceConst(path, plen);

    // 拷贝 argv 到内核暂存
    var argv_buf: [32][256]u8 = undefined; // 静态暂存（教学简化：单核、关中断窗口短）
    var argv_lens: [32]usize = undefined;
    var argc: usize = 0;
    const argv_arr: [*]const usize = @ptrFromInt(argv);
    while (argc < 32) : (argc += 1) {
        const s = argv_arr[argc];
        if (s == 0) break;
        const l = cstrLen(s, 255);
        @memcpy(argv_buf[argc][0..l], userSliceConst(s, l));
        argv_lens[argc] = l;
    }

    var argv_slices: [32][]const u8 = undefined;
    for (0..argc) |i| argv_slices[i] = argv_buf[i][0..argv_lens[i]];

    if (proc.execve(path_s, argv_slices[0..argc])) {
        return 0; // 不会到达：成功路径直接进入新程序
    }
    return ENOENT;
}

fn sysExit(code: usize) isize {
    proc.exit(@bitCast(@as(u32, @truncate(code))));
}

fn sysWait4(which: usize, status_ptr: usize) isize {
    var status: ?i32 = null;
    const r = proc.wait4(@bitCast(@as(u32, @truncate(which))), &status);
    if (r >= 0) {
        if (status_ptr != 0) {
            const b = userSlice(status_ptr, 4);
            b[0] = @truncate(@as(u32, @bitCast(status.?)));
            b[1] = @truncate(@as(u32, @bitCast(status.?)) >> 8);
            b[2] = @truncate(@as(u32, @bitCast(status.?)) >> 16);
            b[3] = @truncate(@as(u32, @bitCast(status.?)) >> 24);
        }
    }
    return r;
}

fn sysNanosleep(req: usize) isize {
    const tv_sec_ptr: *align(1) const i64 = @ptrFromInt(req);
    const tv_nsec_ptr: *align(1) const i64 = @ptrFromInt(req + 8);
    const ms: u64 = @intCast(@max(0, tv_sec_ptr.* * 1000 + @divTrunc(tv_nsec_ptr.*, 1_000_000)));
    proc.sleepMs(ms);
    return 0;
}

fn sysUname(buf: usize) isize {
    const b = userSlice(buf, 6 * 65);
    @memset(b, 0);
    copyStr(b[0..65], "ZOS"); // sysname
    copyStr(b[65..130], "zos"); // nodename
    copyStr(b[130..195], "0.1.0"); // release
    copyStr(b[195..260], "ZOS #1 teaching kernel (zig)"); // version
    copyStr(b[260..325], "x86_64"); // machine
    return 0;
}

fn copyStr(dst: []u8, s: []const u8) void {
    @memcpy(dst[0..s.len], s);
}

fn sysGetcwd(buf: usize, size: usize) isize {
    const p = proc.current().?;
    if (size < p.cwd_len + 1) return EINVAL;
    const b = userSlice(buf, p.cwd_len);
    @memcpy(b, p.cwd());
    const nul: [*]u8 = @ptrFromInt(buf + p.cwd_len);
    nul[0] = 0;
    return @intCast(p.cwd_len);
}

fn sysChdir(path: usize) isize {
    const p = proc.current().?;
    const plen = cstrLen(path, 255);
    if (plen == 0) return EINVAL;

    var norm: [256]u8 = undefined;
    const n = vfs.normalizePath(userSliceConst(path, plen), p.cwd(), &norm) orelse return EINVAL;

    const node = vfs.resolve(userSliceConst(path, plen), p.cwd()) orelse return ENOENT;
    if (!vfs.info(node).is_dir) return ENOTDIR;

    @memcpy(p.cwd_buf[0..n], norm[0..n]);
    p.cwd_len = n;
    return 0;
}

// getdents64：一次性填入全部直接孩子（假设 buf 足够大——ls 用 4KB）
const Dirent64 = extern struct {
    ino: u64,
    off: i64,
    reclen: u16,
    dtype: u8,
    // name[] + NUL 紧随其后（注意：名字在偏移 19，不是 @sizeOf！
    // extern struct 的对齐填充会把 sizeof 撑到 24）
};
const DIRENT_NAME_OFF: usize = 19;

const Ctx = struct {
    buf: [*]u8,
    cap: usize,
    used: usize = 0,
    off: u64 = 1,
    fail: bool = false,
};

fn direntCb(ctx: *Ctx, name: []const u8, child: usize) void {
    const reclen: usize = DIRENT_NAME_OFF + name.len + 1;
    if (ctx.used + reclen > ctx.cap) {
        ctx.fail = true;
        return;
    }
    const d: *align(1) Dirent64 = @ptrFromInt(@intFromPtr(ctx.buf) + ctx.used);
    d.ino = child;
    d.off = @intCast(ctx.off + reclen);
    d.reclen = @intCast(reclen);
    d.dtype = if (vfs.info(child).is_dir) 4 else if (vfs.info(child).is_console) 2 else 8;
    const np: [*]u8 = @ptrFromInt(@intFromPtr(ctx.buf) + ctx.used + DIRENT_NAME_OFF);
    @memcpy(np[0..name.len], name);
    np[name.len] = 0;
    ctx.used += reclen;
    ctx.off += reclen;
}

fn sysGetdents64(fd: usize, buf: usize, count: usize) isize {
    const p = proc.current().?;
    const f = getFd(p, fd) orelse return EBADF;
    if (!vfs.info(f.node).is_dir) return ENOTDIR;

    if (f.pos == 1) return 0; // 已读完（教学简化：一次返回全部）
    var ctx = Ctx{ .buf = @ptrFromInt(buf), .cap = count };
    vfs.listDir(f.node, &ctx, direntCb);
    if (ctx.used == 0 and ctx.fail) return EINVAL;
    f.pos = 1;
    return @intCast(ctx.used);
}


// ================= ZOS 扩展 =================

/// 每项：pid/ppid/state/字段 + 名字，与用户态 zos.zig 的 PsInfo 对应
const PsEntry = extern struct {
    pid: u32,
    ppid: u32,
    state: u32,
    _pad: u32,
    name: [16]u8,
};

/// http_get(host, port, path, out, out_len)：第 4/5 参数走 r10/r8
fn sysHttpGet(host: usize, port: u16, path: usize, frame: *TrapFrame) isize {
    const net = @import("net.zig");
    const host_len = cstrLen(host, 255);
    if (host_len == 0) return EINVAL;
    const host_s = userSliceConst(host, host_len);
    const path_len = cstrLen(path, 255);
    const path_s = userSliceConst(path, path_len);
    const out = userSlice(@intCast(frame.r10), @intCast(@min(frame.r8, @as(usize, 63) * 1024)));
    return net.httpGet(host_s, port, path_s, out);
}

fn sysNetInfo(buf: usize, len: usize) isize {
    const e1000 = @import("e1000.zig");
    if (!e1000.ready()) return -19;
    const m = e1000.mac();
    const info = "ip=10.0.2.15 mask=255.255.255.0 gw=10.0.2.2 dns=10.0.2.3\n";
    if (len < info.len) return EINVAL;
    @memcpy(userSlice(buf, info.len), info);
    _ = m;
    return @intCast(info.len);
}

/// zos_beep(freq, ms)：阻塞播放一段正弦纯音（AC'97）
fn sysBeep(freq: usize, ms: usize) isize {
    if (freq < 20 or freq > 8000 or ms == 0 or ms > 10000) return EINVAL;
    return @import("audio.zig").playTone(@intCast(freq), @intCast(ms));
}

fn sysPsinfo(buf: usize, max: usize) isize {
    const out: [*]PsEntry = @ptrFromInt(buf);
    const nmax = @min(max, 32);
    var n: usize = 0;
    for (@import("proc.zig").procsExported()) |*p| {
        if (p.state == .unused) continue;
        if (n >= nmax) break;
        out[n] = .{
            .pid = p.pid,
            .ppid = p.ppid,
            .state = @intFromEnum(p.state),
            ._pad = 0,
            .name = p.name,
        };
        n += 1;
    }
    return @intCast(n);
}
