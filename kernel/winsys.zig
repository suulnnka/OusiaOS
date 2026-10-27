//! winsys —— 窗口服务：用户态 GUI 应用与内核合成器之间的协议层
//!
//! 教学要点（微内核思想的缩影）：
//!   - 应用是普通用户进程：不能碰帧缓冲/别的窗口，只能画进自己的
//!     【共享表面】——一组 pmm 页帧，双映射：用户态 RW（syscall 返回
//!     的虚拟地址）+ 内核经物理帧直访（合成时逐行搬运）
//!   - 事件队列：IRQ12/IRQ1 生产（把全局鼠标/键盘事件换算成窗口
//!     客户区坐标），syscall 消费；win_wait 空队列时进程 blocked，
//!     事件到达由 IRQ 唤醒——经典的"阻塞等事件"GUI 主循环
//!   - 权威状态（窗口位置/大小/z 序/可见性）全在内核：应用只是
//!     "往自己的表面画画并对输入做反应"，无法欺骗合成器
//!
//! 系统调用（510..515）：
//!   win_create(w,h,title) -> 表面虚拟地址   win_present() 记脏区
//!   win_poll(buf,n) -> 事件数（不阻塞）      win_wait(buf,n,timeout_ms)
//!   win_color(r,g,b) -> 帧缓冲格式的颜色值
//!   win_fmt() -> 像素格式通道移位（miniGL 逐像素打包用）
//!
//! 线程模型：事件环的生产者在 IRQ 上下文、消费者在 syscall 上下文，
//! 与 gui.addDamage 相同的 cli 短临界区保护索引"读-改-写"。

const console = @import("console.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const proc = @import("proc.zig");
const pit = @import("pit.zig");
const multiboot = @import("multiboot.zig");
const gui = @import("gui.zig");

// ---------------- 事件 ----------------

pub const EV_PRESS: u8 = 1; // 左键按下（x,y = 客户区坐标）
pub const EV_RPRESS: u8 = 2; // 右键按下
pub const EV_RELEASE: u8 = 3; // 左键松开
pub const EV_MOVE: u8 = 4; // 移动（含按住拖动；捕获期间划出窗口也有）
pub const EV_KEY: u8 = 5; // 键盘（code = ASCII/控制码 或 0xF0..0xF8 私有键码）
pub const EV_CLOSE: u8 = 6; // 用户点了关闭盒：应用应尽快 exit
pub const EV_RESIZE: u8 = 7; // 表面已重分配（x,y = 新客户区尺寸）；重画全窗口
pub const EV_DBL: u8 = 8; // 双击（快速二次左键，x,y = 客户区坐标）
pub const EV_ACTIVATE: u8 = 9; // 窗口成为活动窗口（键盘焦点到手，可画光标）
pub const EV_DEACTIVATE: u8 = 10; // 失去活动状态（藏起光标/选区高亮）

/// 与用户态 lib/win.zig 的 WinEvent 二进制布局一致
pub const WinEvent = extern struct {
    kind: u8,
    x: i16,
    y: i16,
    code: u8,
    _pad: u8,
    _pad2: u8,
};

const EV_RING = 32;

// ---------------- 窗口槽位 ----------------
//
// gui.zig 的窗口表前两个槽位是内核窗口（Terminal/About），用户窗口
// 从 GUI_USER_SLOT_BASE 起分配。窗口几何/绘制权威在 gui.zig；本模块
// 管：表面帧、事件环、属主进程。

pub const MAX_USER_WINDOWS = 10; // 同时打开的用户态应用窗口数
const SURF_MAX_FRAMES = 160; // 单窗口表面上限 640KB

const Win = struct {
    used: bool = false,
    owner_pid: u32 = 0,
    cw: i32 = 0, // 客户区尺寸（像素）
    ch: i32 = 0,
    frames: [SURF_MAX_FRAMES]usize = @splat(0), // 表面物理帧
    nframes: usize = 0,
    surf_user_va: usize = 0, // 用户侧映射起始虚拟地址

    ev: [EV_RING]WinEvent = undefined,
    ev_head: usize = 0,
    ev_count: usize = 0,
};

var wins: [MAX_USER_WINDOWS]Win = @splat(.{});
var next_user_va: usize = 0x0000_4000_0000_0000; // 用户表面映射区（避开 mmap 区）

/// gui 窗口表里用户窗口的槽位号 → 本模块下标
pub fn winAtSlot(slot: usize) ?*Win {
    if (slot < gui.USER_SLOT_BASE) return null;
    const i = slot - gui.USER_SLOT_BASE;
    if (i >= wins.len) return null;
    if (!wins[i].used) return null;
    return &wins[i];
}

fn freeWindow(w: *Win) void {
    // 关键顺序：先把表面页从属主的用户页表【摘映射】再释放帧。
    // 否则随后的 destroyUserSpace 遍历页表时会把这些还映射着的帧
    // 再释放一遍——GUI 应用一退出就是成片的 pmm double free
    // （表面 320×240×4 字节 = 75 帧，正好对上日志里的 75 连报）。
    if (proc.findByPid(w.owner_pid)) |p| {
        for (0..w.nframes) |i| {
            vmm.unmapPage(p.page_map, w.surf_user_va + i * 4096);
        }
    }
    for (w.frames[0..w.nframes]) |f| pmm.freeFrame(f);
    w.* = .{};
}

/// 进程退出钩子（proc.exit 调用，进程上下文）：拆掉它名下的窗口。
/// 表面帧与地址空间无关联（用户映射随页表销毁），直接释放安全。
pub fn onProcExit(pid: u32) void {
    for (&wins, 0..) |*w, i| {
        if (w.used and w.owner_pid == pid) {
            freeWindow(w);
            gui.destroyUserWindow(gui.USER_SLOT_BASE + i);
        }
    }
}

// ---------------- 事件环（IRQ 生产 / syscall 消费） ----------------

/// IRQ 上下文调用：把事件推给窗口属主（队列满则丢——GUI 事件可丢，
/// 教学取舍；鼠标移动事件优先被挤掉的是最老的）
pub fn push(slot: usize, ev: WinEvent) void {
    const w = winAtSlot(slot) orelse return;
    const flags = gui.irqSave();
    asm volatile ("cli");
    if (w.ev_count == EV_RING) {
        w.ev_head = (w.ev_head + 1) % EV_RING; // 挤掉最老
        w.ev_count -= 1;
    }
    w.ev[(w.ev_head + w.ev_count) % EV_RING] = ev;
    w.ev_count += 1;
    gui.irqRestore(flags);
    proc.wake(w.owner_pid); // blocked → runnable
}

fn popEvents(w: *Win, buf: usize, n: usize) usize {
    const flags = gui.irqSave();
    asm volatile ("cli");
    const cnt = @min(n, w.ev_count);
    const out: [*]WinEvent = @ptrFromInt(buf);
    for (0..cnt) |i| out[i] = w.ev[(w.ev_head + i) % EV_RING];
    w.ev_head = (w.ev_head + cnt) % EV_RING;
    w.ev_count -= cnt;
    gui.irqRestore(flags);
    return cnt;
}

// ---------------- 内核侧合成访问 ----------------

/// 表面一行像素的内核直访：行可能跨两个物理帧，按段拷贝。
/// x0/x1 是表面坐标范围，dst 是表面 x=x0 处的屏幕坐标。
/// 仅在 repaint（IRQ0/IRQ12，IF=0）里调用。
pub fn blitRow(slot: usize, y: i32, x0: i32, x1: i32, dst_x: i32, dst_y: i32) void {
    const w = winAtSlot(slot) orelse return;
    if (y < 0 or y >= w.ch) return;
    const xs = @max(x0, 0);
    const xe = @min(x1, w.cw);
    if (xe <= xs) return;

    var x = xs;
    while (x < xe) {
        const off: usize = @intCast(y * w.cw + x);
        const byte_off = off * 4;
        const fi = byte_off >> 12;
        if (fi >= w.nframes) return;
        const in_page = byte_off & 0xFFF;
        const n = @min(@as(usize, 4096 - in_page) / 4, @as(usize, @intCast(xe - x)));
        const src: [*]const u32 = @ptrFromInt(vmm.physToVirt(w.frames[fi]) + in_page);
        gui.blitRun(src[0..n], dst_x + (x - xs), dst_y);
        x += @intCast(n);
    }
}

/// 关闭盒被点：通知应用退出（事件），窗口立即隐藏。
/// 若应用赖着不退，表面与槽位在它 exit 时由 onProcExit 回收。
pub fn requestClose(slot: usize) void {
    push(slot, .{ .kind = EV_CLOSE, .x = 0, .y = 0, .code = 0, ._pad = 0, ._pad2 = 0 });
}

// ---------------- 系统调用实现 ----------------

/// win_create(w, h, title) → 表面用户虚拟地址；失败 -errno
pub fn sysCreate(cw: usize, ch: usize, title: usize) isize {
    const p = proc.current() orelse return -1;
    if (cw == 0 or ch == 0 or cw > 1024 or ch > 700) return -22; // EINVAL
    if (title == 0) return -22;

    // 每进程一个窗口（教学简化；多窗口是练习）
    for (&wins) |*w| {
        if (w.used and w.owner_pid == p.pid) return -17; // EEXIST
    }

    // 找空槽（gui 侧与 winsys 侧一一对应）
    var idx: ?usize = null;
    for (&wins, 0..) |*w, i| {
        if (!w.used) {
            idx = i;
            break;
        }
    }
    const i = idx orelse return -12; // ENOMEM
    const w = &wins[i];

    // 标题（用户字符串）
    const t: [*]const u8 = @ptrFromInt(title);
    var tlen: usize = 0;
    while (tlen < 40 and t[tlen] != 0) tlen += 1;

    const bytes = cw * ch * 4;
    const pages = (bytes + 0xFFF) >> 12;
    if (pages > SURF_MAX_FRAMES) return -12;

    // 用户虚拟地址区：2MB 对齐步进（简单且永不错位）
    const vbase = next_user_va;
    const vsize = (pages * 4096 + 0x1F_FFFF) & ~@as(usize, 0x1F_FFFF);
    if (vbase + vsize > 0x0000_5000_0000_0000) return -12; // 撞 mmap 区

    // 分配帧 + 双映射：用户 RW + 内核（经物理直访，无需映射）
    var got: usize = 0;
    while (got < pages) : (got += 1) {
        const f = pmm.allocFrame() orelse break;
        @memset(@as([*]u8, @ptrFromInt(vmm.physToVirt(f)))[0..4096], 0); // 清零=黑
        if (!vmm.mapPage(p.page_map, vbase + got * 4096, f, vmm.P | vmm.W | vmm.U)) {
            pmm.freeFrame(f);
            break;
        }
        w.frames[got] = f;
    }
    if (got < pages) {
        // 回滚同样先摘映射再释放（映射残留会让 destroyUserSpace 二次释放）
        for (0..got) |k| {
            vmm.unmapPage(p.page_map, vbase + k * 4096);
            pmm.freeFrame(w.frames[k]);
        }
        w.frames = @splat(0);
        return -12;
    }

    w.used = true;
    w.owner_pid = p.pid;
    w.cw = @intCast(cw);
    w.ch = @intCast(ch);
    w.nframes = pages;
    w.surf_user_va = vbase;
    w.ev_head = 0;
    w.ev_count = 0;
    next_user_va += vsize;

    // gui 侧登记窗口（标题/几何/z 序由它管）
    gui.createUserWindow(i, @intCast(cw), @intCast(ch), p.pid, t[0..tlen]);
    return @intCast(vbase);
}

fn myWindow() ?*Win {
    const p = proc.current() orelse return null;
    for (&wins) |*w| {
        if (w.used and w.owner_pid == p.pid) return w;
    }
    return null;
}

fn slotOf(w: *Win) usize {
    const base = @intFromPtr(w) - @intFromPtr(&wins);
    return gui.USER_SLOT_BASE + base / @sizeOf(Win);
}

/// win_present()：整块客户区记脏（重绘由 IRQ0 完成）
pub fn sysPresent() isize {
    const w = myWindow() orelse return -9;
    const wi = slotOf(w);
    gui.damageUserWindow(wi);
    return 0;
}

/// win_poll(buf, n)：非阻塞取事件
pub fn sysPoll(buf: usize, n: usize) isize {
    if (n == 0 or n > 16) return -22;
    const w = myWindow() orelse return -9;
    return @intCast(popEvents(w, buf, n));
}

/// win_wait(buf, n, timeout_ms=0无限)：空队列则 blocked 睡到事件/超时
pub fn sysWait(buf: usize, n: usize, timeout_ms: i32) isize {
    if (n == 0 or n > 16) return -22;
    const p = proc.current() orelse return -1;
    const w = myWindow() orelse return -9;
    const deadline: u64 = if (timeout_ms > 0) pit.ticks + @as(u64, @intCast(timeout_ms)) / 10 else 0;

    while (true) {
        const cnt = popEvents(w, buf, n);
        if (cnt > 0) return @intCast(cnt);
        if (timeout_ms > 0 and pit.ticks >= deadline) return 0; // 超时：0 个事件
        p.state = .blocked;
        p.wake_tick = deadline; // 0 = 只等事件唤醒
        proc.switchAway();
    }
}

/// win_color(r,g,b)：帧缓冲像素格式打包（BGR 位移由 GRUB 决定，应用不该猜）
pub fn sysColor(r: usize, g: usize, b: usize) isize {
    if (r > 255 or g > 255 or b > 255) return -22;
    return @intCast(gui.px(@intCast(r), @intCast(g), @intCast(b)));
}

/// win_fmt() → (rsh<<10)|(gsh<<5)|bsh：像素格式的通道移位。
/// miniGL 这类自绘光栅库需要移位而不是逐像素调 win_color——
/// 一次查询，之后每像素纯用户态打包，零陷入。
pub fn sysFmt() isize {
    const s = gui.pixelShifts();
    return (@as(isize, s.rsh) << 10) | (@as(isize, s.gsh) << 5) | s.bsh;
}

// ---------------- 系统剪贴板 ----------------
//
// 全局一块缓冲（教学版单选区、纯文本）：EV_KEY 里的 Ctrl+C/X/V
// (0x03/0x18/0x16) 由应用解释——Edit 控件把它们翻译成 get/set。

const CLIP_MAX = 1024;
var clip: [CLIP_MAX]u8 = undefined;
var clip_len: usize = 0;

pub fn sysClipSet(ptr: usize, len: usize) isize {
    if (len > CLIP_MAX) return -22;
    const src: [*]const u8 = @ptrFromInt(ptr);
    @memcpy(clip[0..len], src[0..len]);
    clip_len = len;
    return @intCast(len);
}

pub fn sysClipGet(ptr: usize, cap: usize) isize {
    if (clip_len == 0) return 0; // 空剪贴板
    const n = @min(clip_len, cap);
    const dst: [*]u8 = @ptrFromInt(ptr);
    @memcpy(dst[0..n], clip[0..n]);
    return @intCast(n);
}

// ---------------- 表面重分配（resize/最大化） ----------------
//
// 教学要点：表面是一组物理帧 + 一段用户虚拟区。重分配 = 申请新帧、
// 新映射（新的 VA 槽，避免与旧映射撞车）、逐像素搬共同区域、再拆旧
// 映射还旧帧。搬完推一条 EV_RESIZE，应用重画新尺寸的全窗口。

/// 读表面像素（x,y 为表面坐标；越界返回 0）
fn surfGet(frames: []const usize, cw: usize, x: usize, y: usize) u32 {
    const byte_off = (y * cw + x) * 4;
    const fi = byte_off >> 12;
    if (fi >= frames.len) return 0;
    const in_page = byte_off & 0xFFF;
    const src: *const u32 = @ptrFromInt(vmm.physToVirt(frames[fi]) + in_page);
    return src.*;
}

fn surfSet(frames: []const usize, cw: usize, x: usize, y: usize, v: u32) void {
    const byte_off = (y * cw + x) * 4;
    const fi = byte_off >> 12;
    if (fi >= frames.len) return;
    const in_page = byte_off & 0xFFF;
    const dst: *u32 = @ptrFromInt(vmm.physToVirt(frames[fi]) + in_page);
    dst.* = v;
}

/// 把窗口表面重分配为 cw×ch（调用方：应用自身 syscall 或 WM 的
/// 最大化/还原）。成功返回 true 并推 EV_RESIZE。
///
/// 关键设计：**用户虚拟地址保持不变**，只换背后的物理帧——
/// 应用缓存的表面指针（lib/win.zig 的 px）永远有效，WM 替它 resize
/// （最大化）也不会踩出页错误。2MB 对齐的 VA 槽位装得下上限 160 页
/// 的任何表面，原位重映射总是可行。
/// 可在 IRQ 上下文调用（WM 侧）：进程此刻阻塞在 win_wait，它的页表
/// 不是活跃 CR3，unmap/map 只是在改页表内存。
pub fn resizeSlot(wi: usize, cw: i32, ch: i32) bool {
    if (cw <= 0 or ch <= 0 or cw > 1024 or ch > 700) return false;
    const w = winAtSlot(wi) orelse return false;
    const p = proc.findByPid(w.owner_pid) orelse return false;
    const ncw: usize = @intCast(cw);
    const nch: usize = @intCast(ch);
    const pages = (ncw * nch * 4 + 0xFFF) >> 12;
    if (pages > SURF_MAX_FRAMES) return false;

    // 1) 分配新帧
    var nf: [SURF_MAX_FRAMES]usize = @splat(0);
    var got: usize = 0;
    while (got < pages) : (got += 1) {
        const f = pmm.allocFrame() orelse break;
        nf[got] = f;
    }
    if (got < pages) {
        for (nf[0..got]) |f| pmm.freeFrame(f);
        return false;
    }

    // 2) 搬共同区域（旧帧还在手里，按物理地址直读直写）
    const copy_w = @min(@as(usize, @intCast(w.cw)), ncw);
    const copy_h = @min(@as(usize, @intCast(w.ch)), nch);
    var y: usize = 0;
    while (y < copy_h) : (y += 1) {
        var x: usize = 0;
        while (x < copy_w) : (x += 1) {
            surfSet(nf[0..got], ncw, x, y, surfGet(w.frames[0..w.nframes], @intCast(w.cw), x, y));
        }
    }

    // 3) 拆旧映射、还旧帧（顺序同 freeWindow：先摘映射再释放）
    for (0..w.nframes) |k| {
        vmm.unmapPage(p.page_map, w.surf_user_va + k * 4096);
        pmm.freeFrame(w.frames[k]);
    }

    // 4) 新帧映射到【同一个】用户 VA 槽位
    for (0..got) |k| {
        if (!vmm.mapPage(p.page_map, w.surf_user_va + k * 4096, nf[k], vmm.P | vmm.W | vmm.U)) {
            // 理论不可达（刚拆掉的 VA 原位重装）；兜底：标记表面失效
            for (0..got) |m| {
                if (m >= k) pmm.freeFrame(nf[m]);
            }
            console.kprintf("winsys: resize remap failed, surface lost\n", .{});
            return false;
        }
    }

    w.frames = nf;
    w.nframes = got;
    w.cw = cw;
    w.ch = ch;

    gui.resizeUserWindow(wi, cw, ch);
    push(wi, .{ .kind = EV_RESIZE, .x = @intCast(cw), .y = @intCast(ch), .code = 0, ._pad = 0, ._pad2 = 0 });
    return true;
}

/// 应用主动 resize 自己的表面（win_resize syscall）
pub fn sysResize(cw: usize, ch: usize) isize {
    const w = myWindow() orelse return -9;
    if (!resizeSlot(slotOf(w), @intCast(cw), @intCast(ch))) return -22;
    return 0;
}

/// win_title(ptr)：改窗口标题（任务栏/标题栏联动）
pub fn sysTitle(ptr: usize) isize {
    const w = myWindow() orelse return -9;
    const s: [*]const u8 = @ptrFromInt(ptr);
    var len: usize = 0;
    while (len < 40 and s[len] != 0) len += 1;
    gui.setWindowTitle(slotOf(w), s[0..len]);
    return 0;
}

/// IRQ 上下文：菜单/图标点击启动应用（proc.spawnKernel 在 IF=0 下安全）。
/// 多实例语义：已开着的应用再点 = 再开一个（窗口槽动态化练习②；
/// proc 表满时 spawn 失败，静默忽略）。
pub fn launchApp(path: []const u8) void {
    if (!proc.spawnKernel(path)) {
        console.kprintf("winsys: spawn {s} failed\n", .{path});
    }
}
