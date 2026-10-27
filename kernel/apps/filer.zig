//! File Manager —— tarfs 文件浏览器（按需拉取型应用）
//!
//! 布局（窗口 460x300）：
//!   ┌ / ────────────────────────────────┐  ← 路径栏（凹）
//!   │ [icon] name        size │▲│ ┌预览┐ │  ← 列表 13 行 + 滚动条 + 预览
//!   │ ...                  │█│ │     │ │
//!   └ 5 items ──────────────────────────┘  ← 状态栏
//!
//! 交互约定（教学取舍：单击即动作，不做双击）：
//!   单击目录行 → 进入；单击 ".." → 上一级；单击文件行 → 右栏预览内容
//!
//! 点击时同步遍历 vfs（tarfs 在内存里，目录枚举/读文件都是纯内存
//! 操作，中断上下文安全）。

const gui = @import("../gui.zig");
const vfs = @import("../vfs.zig");

const Rect = gui.Rect;
const mkRect = gui.mkRect;
const inRect = gui.inRect;

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

/// 窗口每次打开时调用（gui.showWindow）：首次列根目录，之后保持位置
pub fn onOpen() void {
    if (fm_path_len == 0) fmGo("/");
}

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

pub fn press(w: *const gui.Win, x: i32, y: i32) void {
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

pub fn paint(w: *const gui.Win) void {
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
