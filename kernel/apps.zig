//! ZOS 内核小应用：文件浏览器 / 终端镜像 / 扫雷 —— gui.zig 的"住户"
//!
//! 教学要点：
//!   - 窗口管理（gui.zig）与应用分层：wm 负责窗口外框、z 序、任务栏与
//!     输入分发；应用只实现 paintClient（画客户区）/ onPress（左键）/
//!     onRightPress（右键，目前只有扫雷用）三个回调
//!   - 三个应用代表内核 GUI 的三种典型数据流：
//!       File Manager：按需拉取——点击时同步遍历 vfs（tarfs 在内存里，
//!                     目录枚举/读文件都是纯内存操作，中断上下文安全）
//!       Terminal：    事件镜像——console.putChar 把每个字符灌进环形
//!                     行缓冲；GUI 终端窗口就是控制台（串口 shell 会话）
//!                     的一面镜子，键盘输入早已由 IRQ1→tty 通路送达 shell
//!       Minesweeper： 自包含状态机——纯输入驱动 + IRQ0 计秒
//!   - 线程模型延续 gui.zig 的约定：onPress/onTick 在中断上下文调用；
//!     唯一例外是 termPutChar（shell printf 时处于进程上下文），每字符
//!     追加用极短的关中断临界区保护，环形缓冲按 SPSC 语义使用

const gui = @import("gui.zig");
const vfs = @import("vfs.zig");
const pit = @import("pit.zig");

const Rect = gui.Rect;
const mkRect = gui.mkRect;
const inRect = gui.inRect;

// ---------------- 生命周期 ----------------

/// gui.init 末尾调用（此刻 tarfs 还没解析，文件浏览器延迟到首次打开）
pub fn init() void {
    msReset();
}

/// 窗口每次打开时调用（gui.showWindow）
pub fn onOpen(w: *const gui.Win) void {
    switch (w.kind) {
        // 首次打开列根目录；之后记住上次所在目录
        .filer => if (fm_path_len == 0) fmGo("/"),
        else => {},
    }
}

/// 客户区绘制（repaint 内调用，clip 已设好）
pub fn paintClient(w: *const gui.Win) void {
    switch (w.kind) {
        .about => paintAbout(w),
        .filer => paintFiler(w),
        .terminal => paintTerminal(w),
        .mine => paintMine(w),
    }
}

/// 客户区左键（IRQ12 上下文；gui 已先把窗口提到 z 序顶端）
pub fn onPress(w: *gui.Win, x: i32, y: i32) void {
    switch (w.kind) {
        .about => aboutPress(w, x, y),
        .filer => fmPress(w, x, y),
        .terminal => {},
        .mine => msPress(w, x, y),
    }
}

/// 客户区右键（只有扫雷用：插旗）
pub fn onRightPress(w: *const gui.Win, x: i32, y: i32) void {
    if (w.kind == .mine) msPressCell(w, x, y, true);
}

/// IRQ0 每拍调用：终端光标闪烁、扫雷计秒（只记脏区，重绘留给 repaint）
pub fn onTick() void {
    if (gui.windowByKind(.terminal).visible) {
        const ph: u1 = @intCast((pit.uptimeMs() / 500) & 1);
        if (ph != term_blink) {
            term_blink = ph;
            gui.addDamage(cursorCellRect());
        }
    }
    if (ms_state == .playing and gui.windowByKind(.mine).visible) {
        const sec: u32 = @intCast(@min((pit.uptimeMs() - ms_start_ms) / 1000, 999));
        if (sec != ms_shown_sec) {
            ms_shown_sec = sec;
            gui.addDamage(msTimerRect());
        }
    }
}

/// console.putChar → GUI 终端镜像（可能处于进程上下文：shell printf）
pub fn termPutChar(c: u8) void {
    const flags = gui.irqSave();
    switch (term_ansi) {
        .plain => {
            if (c == 0x1B) {
                term_ansi = .esc;
            } else {
                termPutPlain(c);
            }
        },
        // 只认 CSI（ESC [ 参数 final）；其余转义整段吞掉
        .esc => {
            if (c == '[') {
                term_ansi = .csi;
                term_param_len = 0;
            } else {
                term_ansi = .plain;
            }
        },
        .csi => {
            if (c >= 0x40 and c <= 0x7E) { // final 字节，序列结束
                // 唯一实现的语义：sh 内建 clear 发的 ESC[2J（清屏）
                if (c == 'J' and termParamHas('2')) {
                    term_head = 0;
                    term_count = 1;
                    termCur().len = 0;
                }
                term_ansi = .plain;
            } else if (term_param_len < term_param.len) {
                term_param[term_param_len] = c;
                term_param_len += 1;
            }
        },
    }
    gui.irqRestore(flags);
}

// ---------------- About ZOS（从 gui.zig 迁来，最小应用范例） ----------------

fn paintAbout(w: *const gui.Win) void {
    const lines = [_][]const u8{
        "ZOS 0.1.0 -- teaching kernel in Zig",
        "Compositor: damage-rect repaint",
        "Input: PS/2 mouse (IRQ12)",
        "VBE 640x480x32 via GRUB gfxpayload",
    };
    var ty = w.y + 36;
    for (lines) |l| {
        gui.text(w.x + 18, ty, l, gui.pal.black);
        ty += 18;
    }

    // 按钮区上方的凹分隔线
    const dy = w.y + w.h - 38;
    gui.hline(w.x + 8, w.x + w.w - 9, dy, gui.pal.shadow);
    gui.hline(w.x + 8, w.x + w.w - 9, dy + 1, gui.pal.white);

    const ok = aboutOkRect(w);
    gui.fillRect(ok, gui.pal.chrome);
    gui.bevel2(ok, true);
    gui.textBold(ok.x + 28, ok.y + 3, "OK", gui.pal.black);
}

fn aboutOkRect(w: *const gui.Win) Rect {
    return mkRect(w.x + @divTrunc(w.w - 70, 2), w.y + w.h - 32, 70, 22);
}

fn aboutPress(w: *gui.Win, x: i32, y: i32) void {
    if (inRect(x, y, aboutOkRect(w))) gui.closeWin(w);
}

// ---------------- File Manager：tarfs 文件浏览器 ----------------
//
// 布局（窗口 460x300）：
//   ┌ / ────────────────────────────────┐  ← 路径栏（凹）
//   │ [icon] name        size │▲│ ┌预览┐ │  ← 列表 13 行 + 滚动条 + 预览
//   │ ...                  │█│ │     │ │
//   └ 5 items ──────────────────────────┘  ← 状态栏
//
// 交互约定（教学取舍：单击即动作，不做双击）：
//   单击目录行 → 进入；单击 ".." → 上一级；单击文件行 → 右栏预览内容

const FM_MAX = 48;
const FM_ROWS = 13; // 可见行数
const FM_LIST_W: i32 = 264;
const FM_SB_W: i32 = 16;
const FM_ROW_H: i32 = 16;

const FmEntry = struct {
    name: [28]u8 = undefined,
    nlen: u8 = 0,
    node: usize = 0,
    is_dir: bool = false,
    size: u32 = 0,

    fn label(self: *const FmEntry) []const u8 {
        return self.name[0..self.nlen];
    }
};

var fm_path: [128]u8 = undefined; // 当前目录规范路径（"" = 未初始化）
var fm_path_len: usize = 0;
var fm_entries: [FM_MAX]FmEntry = undefined;
var fm_count: usize = 0;
var fm_sel: ?usize = null; // 选中的条目下标
var fm_top: usize = 0; // 滚动偏移
var fm_prev: [3072]u8 = undefined; // 预览内容
var fm_prev_len: usize = 0;
var fm_prev_total: usize = 0; // 文件总大小（可能 > 预览缓冲）

fn fmHasParent() bool {
    return fm_path_len > 1;
}

/// 列表可见总行数（非根目录多一行 ".."）
fn fmVisualRows() usize {
    return fm_count + @intFromBool(fmHasParent());
}

fn fmPathRect(w: *const gui.Win) Rect {
    const cr = gui.clientRect(w);
    return mkRect(cr.x + 2, cr.y + 2, cr.w - 4, 18);
}

fn fmListRect(w: *const gui.Win) Rect {
    const cr = gui.clientRect(w);
    return mkRect(cr.x + 2, cr.y + 24, FM_LIST_W, FM_ROWS * FM_ROW_H + 2);
}

fn fmPrevRect(w: *const gui.Win) Rect {
    const cr = gui.clientRect(w);
    const x = cr.x + 2 + FM_LIST_W + 6;
    return mkRect(x, cr.y + 24, cr.x + cr.w - 4 - x, FM_ROWS * FM_ROW_H + 2);
}

fn fmStatusRect(w: *const gui.Win) Rect {
    const cr = gui.clientRect(w);
    return mkRect(cr.x + 2, cr.y + cr.h - 18, cr.w - 4, 16);
}

fn fmSbUpRect(w: *const gui.Win) Rect {
    const l = fmListRect(w);
    return mkRect(l.x + l.w - FM_SB_W - 1, l.y + 1, FM_SB_W, FM_SB_W);
}

fn fmSbDownRect(w: *const gui.Win) Rect {
    const l = fmListRect(w);
    return mkRect(l.x + l.w - FM_SB_W - 1, l.y + l.h - FM_SB_W - 1, FM_SB_W, FM_SB_W);
}

/// 滚动条滑块（位置 = top / (总行数-可见行数)；不可滚时返回空矩形）
fn fmSbThumbRect(w: *const gui.Win) Rect {
    const l = fmListRect(w);
    const track_y0 = l.y + 1 + FM_SB_W;
    const track_h = l.h - 2 - 2 * FM_SB_W;
    const total = fmVisualRows();
    if (total <= FM_ROWS) return mkRect(0, 0, 0, 0);
    const th = @max(@divTrunc(track_h * FM_ROWS, @as(i32, @intCast(total))), 14);
    const movable = track_h - th;
    const y = track_y0 + @divTrunc(movable * @as(i32, @intCast(fm_top)), @as(i32, @intCast(total - FM_ROWS)));
    return mkRect(l.x + l.w - FM_SB_W - 1, y, FM_SB_W, th);
}

fn fmGo(path: []const u8) void {
    if (path.len == 0 or path.len > fm_path.len) return;
    @memcpy(fm_path[0..path.len], path);
    fm_path_len = path.len;
    fmList();
}

fn fmUp() void {
    if (fm_path_len <= 1) return;
    fm_path_len -= 1; // 去掉尾段："a/b/c" → "a/b"
    while (fm_path_len > 1 and fm_path[fm_path_len - 1] != '/') fm_path_len -= 1;
    if (fm_path_len > 1) fm_path_len -= 1; // 去掉残留 '/'
    fmList();
}

fn fmEnter(name: []const u8) void {
    if (name.len == 0) return;
    const extra: usize = if (fm_path_len > 1) name.len + 1 else name.len;
    if (fm_path_len + extra > fm_path.len) return;
    if (fm_path_len > 1) {
        fm_path[fm_path_len] = '/';
        fm_path_len += 1;
    }
    @memcpy(fm_path[fm_path_len .. fm_path_len + name.len], name);
    fm_path_len += name.len;
    fmList();
}

/// 枚举当前目录 + 排序（目录在前，同类按字典序）
fn fmList() void {
    fm_count = 0;
    fm_sel = null;
    fm_top = 0;
    fm_prev_len = 0;
    fm_prev_total = 0;

    const node = vfs.resolve(fm_path[0..fm_path_len], "/") orelse vfs.ROOT_NODE;
    const Ctx = struct { entries: []FmEntry, count: *usize };
    var ctx = Ctx{ .entries = fm_entries[0..], .count = &fm_count };
    vfs.listDir(node, &ctx, struct {
        fn cb(c: *Ctx, name: []const u8, child: usize) void {
            if (c.count.* >= FM_MAX) return;
            const e = &c.entries[c.count.*];
            e.* = .{};
            const n = @min(name.len, e.name.len);
            @memcpy(e.name[0..n], name[0..n]);
            e.nlen = @intCast(n);
            e.node = child;
            const inf = vfs.info(child);
            e.is_dir = inf.is_dir;
            e.size = @intCast(@min(inf.size, 0xFFFF_FFFF));
            c.count.* += 1;
        }
    }.cb);

    // 插入排序：目录优先，同类按字节字典序（内核里手写 strcmp 的教学点）
    var i: usize = 1;
    while (i < fm_count) : (i += 1) {
        const key = fm_entries[i];
        var j = i;
        while (j > 0 and fmLess(&key, &fm_entries[j - 1])) : (j -= 1) {
            fm_entries[j] = fm_entries[j - 1];
        }
        fm_entries[j] = key;
    }
}

fn fmLess(a: *const FmEntry, b: *const FmEntry) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    const la = a.label();
    const lb = b.label();
    const n = @min(la.len, lb.len);
    for (la[0..n], lb[0..n]) |x, y| {
        if (x != y) return x < y;
    }
    return la.len < lb.len;
}

fn fmSelect(i: usize) void {
    fm_sel = i;
    const e = &fm_entries[i];
    fm_prev_len = 0;
    fm_prev_total = e.size;
    if (!e.is_dir) {
        const n = vfs.read(e.node, 0, fm_prev[0..]);
        if (n > 0) fm_prev_len = @intCast(n);
    }
}

fn fmPress(w: *const gui.Win, x: i32, y: i32) void {
    // 滚动条：上下箭头各滚一行，滑轨上下半区翻页
    const total = fmVisualRows();
    if (total > FM_ROWS) {
        if (inRect(x, y, fmSbUpRect(w))) {
            if (fm_top > 0) fm_top -= 1;
            gui.addDamage(fmListRect(w));
            return;
        }
        if (inRect(x, y, fmSbDownRect(w))) {
            if (fm_top < total - FM_ROWS) fm_top += 1;
            gui.addDamage(fmListRect(w));
            return;
        }
        const thumb = fmSbThumbRect(w);
        const l = fmListRect(w);
        const track = mkRect(thumb.x, l.y + 1 + FM_SB_W, FM_SB_W, l.h - 2 - 2 * FM_SB_W);
        if (inRect(x, y, track)) {
            const page: i32 = if (y < thumb.y) -@as(i32, FM_ROWS) else FM_ROWS;
            const t: i32 = @as(i32, @intCast(fm_top)) + page;
            fm_top = @intCast(@max(0, @min(t, @as(i32, @intCast(total - FM_ROWS)))));
            gui.addDamage(fmListRect(w));
            return;
        }
    }

    // 列表行：视排行号 → 条目下标（非根目录第 0 视排行是 ".."）
    const l = fmListRect(w);
    if (!inRect(x, y, l)) return;
    const vy = @divTrunc(y - l.y - 1, FM_ROW_H);
    if (vy < 0 or vy >= FM_ROWS) return;
    const vr = fm_top + @as(usize, @intCast(vy));
    if (fmHasParent()) {
        if (vr == 0) {
            fmUp();
            gui.addDamage(gui.clientRect(w)); // 路径栏+列表+状态栏全变
            return;
        }
        if (vr - 1 < fm_count) fmRowClick(w, vr - 1);
    } else if (vr < fm_count) {
        fmRowClick(w, vr);
    }
}

fn fmRowClick(w: *const gui.Win, i: usize) void {
    const e = &fm_entries[i];
    if (e.is_dir) {
        fmEnter(e.label());
        gui.addDamage(gui.clientRect(w));
    } else {
        fmSelect(i);
        gui.addDamage(fmListRect(w));
        gui.addDamage(fmPrevRect(w));
        gui.addDamage(fmStatusRect(w));
    }
}

fn paintFiler(w: *const gui.Win) void {
    // 路径栏
    const pr = fmPathRect(w);
    gui.fillRect(pr, gui.pal.white);
    gui.bevel1(pr, false);
    gui.text(pr.x + 4, pr.y + 1, fm_path[0..fm_path_len], gui.pal.black);

    // 列表区（凹白底）
    const l = fmListRect(w);
    gui.fillRect(l, gui.pal.white);
    gui.bevel1(l, false);

    const rows = fmVisualRows();
    const name_col: i32 = l.x + 22;
    var vr: usize = fm_top;
    var y = l.y + 1;
    while (vr < rows and vr < fm_top + FM_ROWS) : (vr += 1) {
        // 非根目录的第 0 视排行是 ".."；条目下标只在非 ".." 行才有意义
        // （先算 ei 再判断会在 ".." 行对 usize 做 0-1 下溢——教学示例：
        //   Zig 的安全检查把这种"算了但没用"的下溢也当场拦下）
        const is_parent = fmHasParent() and vr == 0;
        const ei: usize = if (is_parent) 0 else if (fmHasParent()) vr - 1 else vr;
        const sel = !is_parent and fm_sel == ei;
        const row = mkRect(l.x + 1, y, l.w - 2 - FM_SB_W, FM_ROW_H);
        if (sel) gui.fillRect(row, gui.pal.navy);
        const fg: u32 = if (sel) gui.pal.white else gui.pal.black;

        if (is_parent) {
            paintFolderIcon(l.x + 4, y + 4);
            gui.text(name_col, y, "..", fg);
        } else {
            const e = &fm_entries[ei];
            if (e.is_dir) {
                paintFolderIcon(l.x + 4, y + 4);
                gui.text(name_col, y, e.label(), fg);
                gui.text(l.x + l.w - FM_SB_W - 46, y, "<dir>", fg);
            } else {
                paintFileIcon(l.x + 5, y + 3);
                gui.text(name_col, y, e.label(), fg);
                var sb: [7]u8 = undefined;
                const sl = fmFormatSize(e.size, &sb);
                const sx = l.x + l.w - FM_SB_W - 6 - @as(i32, @intCast(sl.len)) * 8;
                gui.text(sx, y, sl, fg);
            }
        }
        y += FM_ROW_H;
    }

    // 滚动条（凹轨 + 凸滑块 + 箭头）
    if (rows > FM_ROWS) {
        const sx = l.x + l.w - FM_SB_W - 1;
        const ty0 = l.y + 1 + FM_SB_W;
        const thh = l.h - 2 - 2 * FM_SB_W;
        gui.fillRect(mkRect(sx, ty0, FM_SB_W, thh), gui.pal.chrome);
        gui.vline(sx, l.y + 1, l.y + l.h - 2, gui.pal.shadow);
        const thumb = fmSbThumbRect(w);
        gui.fillRect(thumb, gui.pal.chrome);
        gui.bevel1(thumb, true);
        fmArrow(fmSbUpRect(w), fm_top == 0, false);
        fmArrow(fmSbDownRect(w), fm_top >= rows - FM_ROWS, true);
    }

    // 预览栏：选中文件的前 N 行（按 '\n' 硬切，超宽截断）
    const pv = fmPrevRect(w);
    gui.fillRect(pv, gui.pal.white);
    gui.bevel1(pv, false);
    const pv_cols: usize = @intCast(@divTrunc(pv.w - 6, 8));
    const pv_rows: usize = @intCast(@divTrunc(pv.h - 4, 16));
    const sel_file = fm_sel != null and !fm_entries[fm_sel.?].is_dir;
    if (sel_file) {
        var it = LineIter{ .s = fm_prev[0..fm_prev_len] };
        var ry: usize = 0;
        while (it.next()) |line| {
            if (ry >= pv_rows) break;
            gui.text(pv.x + 3, pv.y + 2 + @as(i32, @intCast(ry)) * 16, line[0..@min(line.len, pv_cols)], gui.pal.black);
            ry += 1;
        }
        if (fm_prev_total > fm_prev.len) {
            gui.text(pv.x + 3, pv.y + pv.h - 18, "...", gui.pal.shadow);
        }
    } else if (fm_sel != null) {
        gui.text(pv.x + 3, pv.y + 2, "directory", gui.pal.shadow);
    } else {
        gui.text(pv.x + 3, pv.y + 2, "no file selected", gui.pal.shadow);
    }

    // 状态栏
    const st = fmStatusRect(w);
    gui.fillRect(st, gui.pal.chrome);
    gui.bevel1(st, false);
    var buf: [96]u8 = undefined;
    var len = fmFmt(&buf, 0, "{d} items", .{fm_count});
    if (fm_sel) |i| {
        len += fmFmt(&buf, len, "  |  {s}: {d} B", .{ fm_entries[i].label(), fm_prev_total });
    }
    gui.text(st.x + 4, st.y, buf[0..len], gui.pal.black);
}

// ---- 极简 sprintf（apps 内部用；内核 kprintf 只输出不返回字符串） ----

/// 往 buf 的 pos 处格式化，返回写入长度
fn fmFmt(buf: []u8, pos: usize, comptime fmt: []const u8, args: anytype) usize {
    var f = Fmt{ .buf = buf, .pos = pos };
    @setEvalBranchQuota(10000);
    const info = @typeInfo(@TypeOf(args)).@"struct";
    comptime var arg_i: usize = 0;
    comptime var i: usize = 0;
    inline while (i < fmt.len) {
        if (fmt[i] == '{' and i + 1 < fmt.len and fmt[i + 1] == '{') {
            f.put('{');
            i += 2;
            continue;
        }
        if (fmt[i] == '{') {
            comptime var j = i + 1;
            inline while (j < fmt.len and fmt[j] != '}') : (j += 1) {}
            const val = @field(args, info.field_names[arg_i]);
            switch (fmt[i + 1]) {
                's' => f.puts(val),
                'd' => f.num(@intCast(val)),
                else => {},
            }
            arg_i += 1;
            i = j + 1;
            continue;
        }
        f.put(fmt[i]);
        i += 1;
    }
    comptime {
        if (arg_i != info.field_names.len) @compileError("fmFmt: 参数数量不符");
    }
    return f.pos - pos;
}

const Fmt = struct {
    buf: []u8,
    pos: usize,

    fn put(self: *Fmt, c: u8) void {
        if (self.pos < self.buf.len) {
            self.buf[self.pos] = c;
            self.pos += 1;
        }
    }

    fn puts(self: *Fmt, s: []const u8) void {
        for (s) |c| self.put(c);
    }

    fn num(self: *Fmt, v: u64) void {
        var tmp: [20]u8 = undefined;
        var n: usize = 0;
        var x = v;
        if (x == 0) return self.put('0');
        while (x > 0) {
            tmp[n] = '0' + @as(u8, @intCast(x % 10));
            n += 1;
            x /= 10;
        }
        while (n > 0) {
            n -= 1;
            self.put(tmp[n]);
        }
    }
};

/// 文件大小：>=1M 显示 "NM"，>=1K 显示 "NK"，否则字节数（右对齐用）
fn fmFormatSize(v: u32, buf: *[7]u8) []const u8 {
    var len: usize = 0;
    if (v >= 1024 * 1024) {
        len = putDec(buf, v / (1024 * 1024));
        buf[len] = 'M';
        len += 1;
    } else if (v > 99_999) { // 6 位数字以内直接显示字节数
        len = putDec(buf, v);
    } else if (v >= 1024) {
        len = putDec(buf, v / 1024);
        buf[len] = 'K';
        len += 1;
    } else {
        len = putDec(buf, v);
    }
    return buf[0..len];
}

fn putDec(buf: *[7]u8, v: u32) usize {
    var tmp: [10]u8 = undefined;
    var n: usize = 0;
    var x = v;
    if (x == 0) {
        buf[0] = '0';
        return 1;
    }
    while (x > 0) {
        tmp[n] = '0' + @as(u8, @intCast(x % 10));
        n += 1;
        x /= 10;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) buf[i] = tmp[n - 1 - i];
    return n;
}

const LineIter = struct {
    s: []const u8,
    pos: usize = 0,

    fn next(self: *LineIter) ?[]const u8 {
        if (self.pos >= self.s.len) return null;
        const start = self.pos;
        while (self.pos < self.s.len and self.s[self.pos] != '\n') self.pos += 1;
        const line = self.s[start..self.pos];
        self.pos += 1; // 跳过 '\n'
        return line;
    }
};

// ---- 图标（14x9 文件夹 / 9x11 页片，Win3.1 手绘风） ----

fn paintFolderIcon(x: i32, y: i32) void {
    const yellow = gui.px(0xFF, 0xE0, 0x60);
    const black = gui.pal.black;
    gui.fillRect(mkRect(x + 3, y, 8, 2), yellow); // 后片标签
    gui.fillRect(mkRect(x, y + 2, 14, 7), yellow); // 主体
    gui.fillRect(mkRect(x + 2, y - 1, 9, 1), black); // 标签描边
    gui.fillRect(mkRect(x + 1, y + 1, 1, 1), black);
    gui.fillRect(mkRect(x + 11, y + 1, 1, 1), black);
    gui.fillRect(mkRect(x - 1, y + 2, 1, 7), black); // 左描边
    gui.fillRect(mkRect(x + 14, y + 2, 1, 7), black); // 右描边
    gui.fillRect(mkRect(x - 1, y + 9, 16, 1), black); // 底描边
}

fn paintFileIcon(x: i32, y: i32) void {
    const black = gui.pal.black;
    gui.fillRect(mkRect(x, y, 9, 11), gui.pal.white);
    gui.fillRect(mkRect(x, y, 9, 1), black);
    gui.fillRect(mkRect(x, y + 10, 9, 1), black);
    gui.fillRect(mkRect(x, y, 1, 11), black);
    gui.fillRect(mkRect(x + 8, y, 1, 11), black);
    // 折角（右上）：斜线 + 下方灰色填充
    gui.setPx(x + 6, y + 1, black);
    gui.setPx(x + 5, y + 2, black);
    gui.setPx(x + 4, y + 3, black);
    gui.fillRect(mkRect(x + 6, y + 2, 2, 1), gui.pal.shadow);
    gui.fillRect(mkRect(x + 5, y + 3, 3, 1), gui.pal.shadow);
    // 两行"文字"
    gui.fillRect(mkRect(x + 2, y + 5, 4, 1), gui.pal.shadow);
    gui.fillRect(mkRect(x + 2, y + 7, 5, 1), gui.pal.shadow);
}

/// 滚动条箭头：4 行递减宽度的横条堆成 ▲ / ▼
fn fmArrow(r: Rect, disabled: bool, down: bool) void {
    gui.fillRect(r, gui.pal.chrome);
    gui.bevel1(r, true);
    const c: u32 = if (disabled) gui.pal.shadow else gui.pal.black;
    const cx = r.x + @divTrunc(FM_SB_W, 2);
    var i: i32 = 0;
    while (i < 4) : (i += 1) {
        const wdt = 7 - i * 2;
        const yy = if (down) r.y + 6 + i else r.y + 9 - i;
        gui.fillRect(mkRect(cx - @divTrunc(wdt, 2), yy, wdt, 1), c);
    }
}

// ---------------- Terminal：控制台镜像 ----------------
//
// 数据通路（与串口完全同源，GUI 不另起 shell 会话）：
//   键盘 IRQ1 → tty 行规程 → shell(用户态) read/exec
//   shell printf → console.putChar ─┬─ 串口（无头测试/日志）
//                                  └─ gui.onConsoleChar → 本缓冲 → 窗口
//   tty 回显同样走 console.putChar → 敲的字符自动出现在窗口里

const TERM_COLS = 72;
const TERM_VIS_ROWS = 15;
const TERM_LINES = 128; // 回滚行数（超出丢最老）

const TermLine = struct {
    len: u8 = 0,
    buf: [TERM_COLS]u8 = undefined,
};

var term_lines: [TERM_LINES]TermLine = undefined;
var term_head: usize = 0; // 最老行下标（环形）
var term_count: usize = 0; // 现存行数（0 = 尚无任何输出）
var term_ansi: enum { plain, esc, csi } = .plain;
var term_param: [4]u8 = undefined;
var term_param_len: usize = 0;
var term_blink: u1 = 0;

fn termCur() *TermLine {
    return &term_lines[(term_head + term_count - 1) % TERM_LINES];
}

fn termNewLine() void {
    if (term_count < TERM_LINES) {
        term_count += 1;
    } else {
        term_head = (term_head + 1) % TERM_LINES; // 挤掉最老行
    }
    termCur().len = 0;
}

fn termParamHas(digit: u8) bool {
    for (term_param[0..term_param_len]) |p| {
        if (p == digit) return true;
    }
    return false;
}

fn termPutPlain(c: u8) void {
    if (term_count == 0) term_count = 1;
    switch (c) {
        '\n' => termNewLine(),
        '\r' => termCur().len = 0, // 回行首（本内核只有 clear 序列尾随）
        0x08 => { // 退格：tty 回显退格 = 0x08 ' ' 0x08 三连，净效果正确
            const l = termCur();
            if (l.len > 0) l.len -= 1;
        },
        '\t' => { // 补空格到 8 的倍数（与 VGA 文本模式一致）
            const l = termCur();
            while (l.len < TERM_COLS and l.len % 8 != 0) {
                l.buf[l.len] = ' ';
                l.len += 1;
            }
        },
        else => {
            const ch: u8 = if (c >= 32 and c < 127) c else '?';
            if (termCur().len >= TERM_COLS) termNewLine(); // 硬换行
            const l = termCur();
            l.buf[l.len] = ch;
            l.len += 1;
        },
    }
}

fn paintTerminal(w: *const gui.Win) void {
    const cr = gui.clientRect(w);
    gui.fillRect(cr, gui.pal.white);

    var shown: usize = TERM_VIS_ROWS;
    if (term_count < shown) shown = term_count;
    if (shown == 0) return;

    const first = term_head + term_count - shown; // 最老可见行的环形下标
    var i: usize = 0;
    while (i < shown) : (i += 1) {
        const l = &term_lines[(first + i) % TERM_LINES];
        gui.text(cr.x + 2, cr.y + 2 + @as(i32, @intCast(i)) * 16, l.buf[0..l.len], gui.pal.black);
    }

    // 块状光标：缓冲末尾，0.5s 闪烁（相位由 IRQ0 的 onTick 翻转）
    if (term_blink == 1) {
        const last = termCur();
        const col: i32 = if (last.len >= TERM_COLS) 0 else last.len;
        const row: i32 = @intCast(shown - 1);
        const fits = !(last.len >= TERM_COLS and shown >= TERM_VIS_ROWS);
        if (fits) gui.fillRect(mkRect(cr.x + 2 + col * 8, cr.y + 2 + row * 16, 7, 14), gui.pal.navy);
    }
}

/// 光标所在格（闪烁翻转时的脏区）
fn cursorCellRect() Rect {
    const w = gui.windowByKind(.terminal);
    const cr = gui.clientRect(w);
    var shown: usize = TERM_VIS_ROWS;
    if (term_count < shown) shown = term_count;
    if (shown == 0) return mkRect(cr.x, cr.y, cr.w, 16);
    const last = termCur();
    const col: i32 = if (last.len >= TERM_COLS) 0 else last.len;
    return mkRect(cr.x + 2 + col * 8 - 1, cr.y + 2 + @as(i32, @intCast(shown)) * 16 - 17, 9, 16);
}

// ---------------- Minesweeper：9x9 / 10 雷 ----------------
//
// 经典规则：左键翻开（首次点击保护：首格及其 8 邻不布雷，必有展开区），
// 空白格洪泛展开；右键插旗；翻开全部非雷格获胜；笑脸按钮重开。
// 布雷种子取 PIT 拍数（每次开局不同）；计秒由 IRQ0 驱动。

const MS_N = 9;
const MS_MINES = 10;
const MS_CELL: i32 = 20;
const MS_GRID_PX: i32 = MS_N * MS_CELL; // 180

const MsCell = struct {
    mine: bool = false,
    open: bool = false,
    flag: bool = false,
    adj: u8 = 0, // 周围雷数 0..8
};

const MsState = enum { ready, playing, won, lost };

var ms_cells: [MS_N * MS_N]MsCell = undefined;
var ms_state: MsState = .ready;
var ms_flags: u8 = 0;
var ms_opened: usize = 0;
var ms_start_ms: u64 = 0;
var ms_shown_sec: u32 = 0;
var ms_boom: usize = 0xFFFF; // 踩中的那颗雷（输时红底高亮）
var ms_rng: u32 = 1;

fn msGridRect(w: *const gui.Win) Rect {
    const cr = gui.clientRect(w);
    const gx = cr.x + @divTrunc(cr.w - MS_GRID_PX - 4, 2);
    return mkRect(gx, cr.y + 44, MS_GRID_PX + 4, MS_GRID_PX + 4);
}

fn msFaceRect(w: *const gui.Win) Rect {
    const cr = gui.clientRect(w);
    return mkRect(cr.x + @divTrunc(cr.w - 26, 2), cr.y + 6, 26, 26);
}

fn msMineLedRect(w: *const gui.Win) Rect {
    const cr = gui.clientRect(w);
    return mkRect(cr.x + 8, cr.y + 9, 36, 20);
}

fn msTimerRect() Rect {
    const w = gui.windowByKind(.mine);
    const cr = gui.clientRect(w);
    return mkRect(cr.x + cr.w - 8 - 36, cr.y + 9, 36, 20);
}

fn msReset() void {
    for (&ms_cells) |*c| c.* = .{};
    ms_state = .ready;
    ms_flags = 0;
    ms_opened = 0;
    ms_shown_sec = 0;
    ms_boom = 0xFFFF;
}

/// xorshift32（内核没有熵源，用 PIT 拍数做种子——每次开局都不同）
fn msRand() u32 {
    var x = ms_rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    ms_rng = x;
    return x;
}

fn msPlant(safe: usize) void {
    ms_rng = @truncate(pit.ticks | 1);
    const sx: i32 = @intCast(safe % MS_N);
    const sy: i32 = @intCast(safe / MS_N);
    var placed: usize = 0;
    while (placed < MS_MINES) {
        const idx = msRand() % (MS_N * MS_N);
        if (idx == safe) continue;
        const cx: i32 = @intCast(idx % MS_N);
        const cy: i32 = @intCast(idx / MS_N);
        if (@abs(cx - sx) <= 1 and @abs(cy - sy) <= 1) continue; // 首击安全区
        if (ms_cells[idx].mine) continue;
        ms_cells[idx].mine = true;
        placed += 1;
    }
    for (0..MS_N * MS_N) |i| {
        if (ms_cells[i].mine) continue;
        const cx: i32 = @intCast(i % MS_N);
        const cy: i32 = @intCast(i / MS_N);
        var n: u8 = 0;
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                if (dx == 0 and dy == 0) continue;
                const nx = cx + dx;
                const ny = cy + dy;
                if (nx < 0 or ny < 0 or nx >= MS_N or ny >= MS_N) continue;
                if (ms_cells[@intCast(ny * MS_N + nx)].mine) n += 1;
            }
        }
        ms_cells[i].adj = n;
    }
}

fn msPress(w: *const gui.Win, x: i32, y: i32) void {
    if (inRect(x, y, msFaceRect(w))) { // 笑脸 = 重开
        msReset();
        gui.addDamage(gui.clientRect(w));
        return;
    }
    msPressCell(w, x, y, false);
}

fn msPressCell(w: *const gui.Win, x: i32, y: i32, right: bool) void {
    if (ms_state == .won or ms_state == .lost) return; // 终局只能点笑脸重开
    const g = msGridRect(w);
    if (!inRect(x, y, g)) return;
    const cx = @divTrunc(x - g.x - 2, MS_CELL);
    const cy = @divTrunc(y - g.y - 2, MS_CELL);
    if (cx < 0 or cy < 0 or cx >= MS_N or cy >= MS_N) return;
    const idx: usize = @intCast(cy * MS_N + cx);
    const c = &ms_cells[idx];

    if (right) { // 插旗/拔旗（已翻开的格子无效）
        if (c.open) return;
        c.flag = !c.flag;
        if (c.flag) ms_flags += 1 else ms_flags -= 1; // 成对翻转，不会下溢
        gui.addDamage(cellRect(g, idx));
        return;
    }
    if (c.flag or c.open) return;

    if (ms_state == .ready) { // 首次点击：此刻才布雷（保证首击安全）
        msPlant(idx);
        ms_state = .playing;
        ms_start_ms = pit.uptimeMs();
    }

    if (c.mine) {
        c.open = true;
        ms_boom = idx;
        ms_state = .lost;
        gui.addDamage(gui.clientRect(w));
        return;
    }

    // 洪泛展开：显式栈（81 格的小深搜，避免内核栈上的递归）
    var stack: [MS_N * MS_N]u8 = undefined;
    var sp: usize = 0;
    stack[sp] = @intCast(idx);
    sp += 1;
    while (sp > 0) {
        sp -= 1;
        const cur: usize = stack[sp];
        const cc = &ms_cells[cur];
        if (cc.open or cc.flag) continue;
        cc.open = true;
        ms_opened += 1;
        if (cc.adj != 0) continue; // 数字格不扩散
        const px: i32 = @intCast(cur % MS_N);
        const py: i32 = @intCast(cur / MS_N);
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                if (dx == 0 and dy == 0) continue;
                const nx = px + dx;
                const ny = py + dy;
                if (nx < 0 or ny < 0 or nx >= MS_N or ny >= MS_N) continue;
                const ni: usize = @intCast(ny * MS_N + nx);
                if (!ms_cells[ni].open and sp < stack.len) {
                    stack[sp] = @intCast(ni);
                    sp += 1;
                }
            }
        }
    }

    if (ms_opened == MS_N * MS_N - MS_MINES) { // 胜利：所有雷自动插旗
        ms_state = .won;
        for (&ms_cells) |*mc| {
            if (mc.mine) mc.flag = true;
        }
        ms_flags = MS_MINES;
        gui.addDamage(gui.clientRect(w));
        return;
    }
    gui.addDamage(g);
}

fn cellRect(g: Rect, idx: usize) Rect {
    const cx: i32 = @intCast(idx % MS_N);
    const cy: i32 = @intCast(idx / MS_N);
    return mkRect(g.x + 2 + cx * MS_CELL, g.y + 2 + cy * MS_CELL, MS_CELL, MS_CELL);
}

fn paintMine(w: *const gui.Win) void {
    // 计数 LED：黑底红字
    const mines_left: i32 = @as(i32, MS_MINES) - ms_flags;
    paintLed(msMineLedRect(w), mines_left);
    const sec: i32 = if (ms_state == .ready) 0 else @intCast(ms_shown_sec);
    paintLed(msTimerRect(), sec);

    paintFace(msFaceRect(w));

    // 雷区：外凹框 + 9x9 格
    const g = msGridRect(w);
    gui.fillRect(g, gui.pal.chrome);
    gui.bevel2(g, false);
    var i: usize = 0;
    while (i < MS_N * MS_N) : (i += 1) {
        paintCell(g, i);
    }
}

fn paintLed(r: Rect, v: i32) void {
    gui.fillRect(r, gui.pal.black);
    gui.bevel1(r, false);
    const shown: i32 = @max(0, @min(v, 999));
    var buf: [3]u8 = .{
        '0' + @as(u8, @intCast(@divTrunc(shown, 100))),
        '0' + @as(u8, @intCast(@mod(@divTrunc(shown, 10), 10))),
        '0' + @as(u8, @intCast(@mod(shown, 10))),
    };
    gui.text(r.x + 6, r.y + 2, buf[0..3], gui.px(0xFF, 0x00, 0x00));
}

fn paintCell(g: Rect, idx: usize) void {
    const r = cellRect(g, idx);
    const c = &ms_cells[idx];
    const reveal = ms_state == .lost or ms_state == .won; // 终局亮出所有雷

    if (!c.open and !(reveal and c.mine)) {
        // 未翻开：凸起格子，插了旗画旗
        gui.fillRect(r, gui.pal.chrome);
        gui.bevel1(r, true);
        if (c.flag) paintFlag(r);
        return;
    }

    // 已翻开（或终局亮雷）：平底浅色格；踩中的那颗红底
    const bg: u32 = if (idx == ms_boom) gui.px(0xFF, 0x00, 0x00) else gui.pal.white;
    gui.fillRect(r, bg);
    gui.hline(r.x, r.x + r.w - 1, r.y + r.h - 1, gui.pal.shadow);
    gui.vline(r.x + r.w - 1, r.y, r.y + r.h - 1, gui.pal.shadow);

    if (c.mine) {
        paintMineIcon(r);
    } else if (c.adj > 0) {
        const digit = [1]u8{'0' + c.adj};
        gui.text(r.x + 6, r.y + 2, &digit, numColor(c.adj));
    }
}

fn numColor(n: u8) u32 {
    return switch (n) {
        1 => gui.px(0x00, 0x00, 0xFF), // 蓝
        2 => gui.px(0x00, 0x80, 0x00), // 绿
        3 => gui.px(0xFF, 0x00, 0x00), // 红
        4 => gui.pal.navy,
        5 => gui.px(0x80, 0x00, 0x00), // 褐
        6 => gui.px(0x00, 0x80, 0x80), // 青
        7 => gui.pal.black,
        else => gui.pal.shadow, // 8
    };
}

fn paintMineIcon(r: Rect) void {
    // 黑圆雷 + 白高光 + 两根触角（经典造型）
    const cx = r.x + 10;
    const cy = r.y + 10;
    const black = gui.pal.black;
    gui.fillRect(mkRect(cx - 2, cy - 5, 5, 11), black);
    gui.fillRect(mkRect(cx - 4, cy - 3, 9, 7), black);
    gui.fillRect(mkRect(cx - 5, cy - 1, 11, 3), black);
    gui.fillRect(mkRect(cx - 1, cy - 8, 1, 3), black); // 上触角
    gui.fillRect(mkRect(cx + 3, cy + 5, 3, 1), black); // 下左刺
    gui.fillRect(mkRect(cx - 5, cy + 5, 3, 1), black); // 下右刺
    gui.setPx(cx - 2, cy - 2, gui.pal.white); // 高光
    gui.setPx(cx - 1, cy - 2, gui.pal.white);
    gui.setPx(cx - 2, cy - 1, gui.pal.white);
}

fn paintFlag(r: Rect) void {
    const black = gui.pal.black;
    const red = gui.px(0xFF, 0x00, 0x00);
    gui.fillRect(mkRect(r.x + 9, r.y + 4, 1, 9), black); // 旗杆
    gui.fillRect(mkRect(r.x + 4, r.y + 12, 8, 2), black); // 底座
    gui.fillRect(mkRect(r.x + 4, r.y + 4, 5, 1), red); // 三角旗
    gui.fillRect(mkRect(r.x + 4, r.y + 5, 4, 1), red);
    gui.fillRect(mkRect(r.x + 4, r.y + 6, 3, 1), red);
    gui.fillRect(mkRect(r.x + 4, r.y + 7, 2, 1), red);
}

// 笑脸：半径 10 的圆（每行跨度 comptime 算好），三种表情
const FACE_R = 10;
const face_spans: [2 * FACE_R + 1]i32 = blk: {
    var spans: [2 * FACE_R + 1]i32 = undefined;
    var dy: i32 = -FACE_R;
    while (dy <= FACE_R) : (dy += 1) {
        const d: f64 = @floatFromInt(dy);
        const r: f64 = @floatFromInt(FACE_R);
        spans[@intCast(dy + FACE_R)] = @intFromFloat(@sqrt(r * r - d * d));
    }
    break :blk spans;
};

fn paintFace(r: Rect) void {
    gui.fillRect(r, gui.pal.chrome);
    gui.bevel2(r, true);
    const cx = r.x + 13;
    const cy = r.y + 13;
    const yellow = gui.px(0xFF, 0xFF, 0x00);
    const black = gui.pal.black;

    // 黑描边圆盘 + 黄芯
    for (face_spans, 0..) |span, i| {
        const yy = cy - FACE_R + @as(i32, @intCast(i));
        gui.fillRect(mkRect(cx - span, yy, 2 * span + 1, 1), black);
    }
    for (face_spans[1 .. face_spans.len - 1], 1..) |span, i| {
        const yy = cy - FACE_R + @as(i32, @intCast(i));
        const s = @max(span - 2, 0);
        gui.fillRect(mkRect(cx - s, yy, 2 * s + 1, 1), yellow);
    }

    switch (ms_state) {
        .lost => { // X 眼 + 苦嘴
            paintX(cx - 6, cy - 5);
            paintX(cx + 2, cy - 5);
            gui.fillRect(mkRect(cx - 2, cy + 4, 4, 1), black);
            gui.fillRect(mkRect(cx - 3, cy + 5, 6, 1), black);
        },
        .won => { // 墨镜 + 笑嘴
            gui.fillRect(mkRect(cx - 7, cy - 5, 6, 4), black);
            gui.fillRect(mkRect(cx + 1, cy - 5, 6, 4), black);
            gui.fillRect(mkRect(cx - 1, cy - 4, 2, 2), black); // 镜梁
            gui.fillRect(mkRect(cx - 5, cy + 3, 10, 1), black);
            gui.fillRect(mkRect(cx - 3, cy + 4, 6, 1), black);
            gui.fillRect(mkRect(cx - 1, cy + 5, 2, 1), black);
        },
        else => { // 常态：点眼 + 笑嘴
            gui.fillRect(mkRect(cx - 5, cy - 4, 2, 3), black);
            gui.fillRect(mkRect(cx + 3, cy - 4, 2, 3), black);
            gui.fillRect(mkRect(cx - 5, cy + 2, 10, 1), black);
            gui.fillRect(mkRect(cx - 4, cy + 3, 8, 1), black);
            gui.fillRect(mkRect(cx - 2, cy + 4, 4, 1), black);
        },
    }
}

fn paintX(x: i32, y: i32) void {
    var i: i32 = 0;
    while (i < 4) : (i += 1) {
        gui.setPx(x + i, y + i, gui.pal.black);
        gui.setPx(x + 3 - i, y + i, gui.pal.black);
    }
}
