//! fm —— File Manager（用户态 GUI 应用）
//!
//! 内核 GUI 时代的 apps/filer.zig 移植：同一套界面（路径栏/列表/
//! 滚动条/预览/状态栏），但现在它是普通用户进程——目录枚举走
//! getdents64、文件内容走 open+read、权限走内核 vfs 检查（本进程由
//! 内核以 root 直启，/root 旁路；非 root 版本会被 EACCES 拦住）。
//! 单击目录进入、.. 返回、单击文件右栏预览；状态栏显示权限串与属主。

const zos = @import("lib/zos.zig");
const win = @import("lib/win.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

const CW = 454;
const CH = 269;
const MAX_ENTRIES = 48;
const ROWS = 13; // 可见行数
const LIST_W = 264;
const SB_W = 16;
const ROW_H = 16;
const PATH_H = 20;

const Entry = struct {
    name: [28]u8 = undefined,
    nlen: u8 = 0,
    is_dir: bool = false,
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    size: u32 = 0,
};

var path: [128]u8 = undefined;
var path_len: usize = 0;
var entries: [MAX_ENTRIES]Entry = undefined;
var count: usize = 0;
var sel: ?usize = null;
var top: usize = 0;
var prev: [3072]u8 = undefined;
var prev_len: usize = 0;
var prev_total: usize = 0;
var dirty = true;

fn label(e: *const Entry) []const u8 {
    return e.name[0..e.nlen];
}

fn hasParent() bool {
    return path_len > 1;
}

fn visualRows() usize {
    return count + @intFromBool(hasParent());
}

fn go(p: []const u8) void {
    if (p.len == 0 or p.len > path.len) return;
    @memcpy(path[0..p.len], p);
    path_len = p.len;
    list();
}

fn up() void {
    if (path_len <= 1) return;
    path_len -= 1;
    while (path_len > 1 and path[path_len - 1] != '/') path_len -= 1;
    if (path_len > 1) path_len -= 1;
    list();
}

fn enter(name: []const u8) void {
    if (name.len == 0) return;
    const extra: usize = if (path_len > 1) name.len + 1 else name.len;
    if (path_len + extra > path.len) return;
    if (path_len > 1) {
        path[path_len] = '/';
        path_len += 1;
    }
    @memcpy(path[path_len .. path_len + name.len], name);
    path_len += name.len;
    list();
}

fn less(a: *const Entry, b: *const Entry) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    const la = a.name[0..a.nlen];
    const lb = b.name[0..b.nlen];
    const n = @min(la.len, lb.len);
    for (la[0..n], lb[0..n]) |x, y| {
        if (x != y) return x < y;
    }
    return la.len < lb.len;
}

fn list() void {
    count = 0;
    sel = null;
    top = 0;
    prev_len = 0;
    prev_total = 0;

    var zpath: [256]u8 = undefined;
    const zp = withNul(&zpath, path[0..path_len]);
    var dirents: [48]zos.Dirent = undefined;
    const n = zos.listDir(zp[0..path_len], &dirents);
    if (n > 0) {
        for (dirents[0..@intCast(n)]) |*d| {
            if (count >= MAX_ENTRIES) break;
            const e = &entries[count];
            e.* = .{};
            const nl = @min(d.name_len, e.name.len);
            @memcpy(e.name[0..nl], d.nameSlice()[0..nl]);
            e.nlen = @intCast(nl);
            e.is_dir = d.is_dir;
            // stat 取 mode/uid/gid/size
            var full: [300]u8 = undefined;
            const fl = joinPath(&full, zp[0..path_len], d.nameSlice());
            if (zos.stat(fl)) |st| {
                e.mode = st.mode;
                e.uid = st.uid;
                e.gid = st.gid;
                e.size = @intCast(@min(st.size, 0xFFFF_FFFF));
            }
            count += 1;
        }
        // 插入排序：目录在前，同类字典序
        var i: usize = 1;
        while (i < count) : (i += 1) {
            const key = entries[i];
            var j = i;
            while (j > 0 and less(&key, &entries[j - 1])) : (j -= 1) entries[j] = entries[j - 1];
            entries[j] = key;
        }
    }
    dirty = true;
}

fn withNul(buf: []u8, s: []const u8) [:0]u8 {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}

fn joinPath(buf: []u8, base: []const u8, name: []const u8) []const u8 {
    if (base.len == 1 and base[0] == '/') {
        const n = @min(name.len, buf.len);
        @memcpy(buf[0..n], name[0..n]);
        return buf[0..n];
    }
    const n = @min(base.len + 1 + name.len, buf.len);
    @memcpy(buf[0..base.len], base);
    buf[base.len] = '/';
    const ml = n - base.len - 1;
    @memcpy(buf[base.len + 1 .. n], name[0..ml]);
    return buf[0..n];
}

fn selectEntry(i: usize) void {
    sel = i;
    const e = &entries[i];
    prev_len = 0;
    prev_total = e.size;
    if (!e.is_dir) {
        var full: [300]u8 = undefined;
        var zpath: [256]u8 = undefined;
        _ = withNul(&zpath, path[0..path_len]);
        const fl = joinPath(&full, zpath[0..path_len], label(e));
        const fd = zos.open(fl, 0);
        if (fd >= 0) {
            const n = zos.read(@intCast(fd), prev[0..]);
            if (n > 0) prev_len = @intCast(n);
            _ = zos.close(@intCast(fd));
        }
    }
    dirty = true;
}

fn press(x: i32, y: i32) void {
    // 滚动条
    const total = visualRows();
    if (total > ROWS) {
        if (inBox(x, y, LIST_W - SB_W - 1, 24, SB_W, SB_W)) { // ▲
            if (top > 0) top -= 1;
            dirty = true;
            return;
        }
        if (inBox(x, y, LIST_W - SB_W - 1, 24 + ROWS * ROW_H - SB_W - 1, SB_W, SB_W)) { // ▼
            if (top < total - ROWS) top += 1;
            dirty = true;
            return;
        }
        const track_y = 24 + SB_W;
        const track_h = ROWS * ROW_H + 2 - 2 - 2 * SB_W;
        if (inBox(x, y, LIST_W - SB_W - 1, track_y, SB_W, track_h)) {
            const page: i32 = if (y < thumbY()) -ROWS else ROWS;
            const t: i32 = @as(i32, @intCast(top)) + page;
            top = @intCast(@max(0, @min(t, @as(i32, @intCast(total - ROWS)))));
            dirty = true;
            return;
        }
    }
    // 列表行
    if (!inBox(x, y, 0, 24, LIST_W, ROWS * ROW_H + 2)) return;
    const vy = @divTrunc(y - 24 - 1, ROW_H);
    if (vy < 0 or vy >= ROWS) return;
    const vr = top + @as(usize, @intCast(vy));
    if (hasParent()) {
        if (vr == 0) {
            up();
            return;
        }
        if (vr - 1 < count) clickRow(vr - 1);
    } else if (vr < count) {
        clickRow(vr);
    }
}

fn clickRow(i: usize) void {
    const e = &entries[i];
    if (e.is_dir) {
        enter(label(e));
    } else {
        selectEntry(i);
    }
}

fn inBox(x: i32, y: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return x >= bx and y >= by and x < bx + bw and y < by + bh;
}

fn thumbY() i32 {
    const total = visualRows();
    if (total <= ROWS) return 0;
    const track_h = ROWS * ROW_H - 2 * SB_W;
    const th = @max(@divTrunc(track_h * ROWS, @as(i32, @intCast(total))), 14);
    const movable = track_h - th;
    return 24 + SB_W + @divTrunc(movable * @as(i32, @intCast(top)), @as(i32, @intCast(total - ROWS)));
}

// ---------------- 绘制 ----------------

fn draw() void {
    win.fillRect(0, 0, CW, CH, win.C_CHROME);

    // 路径栏（凹白）
    win.fillRect(2, 2, CW - 4, PATH_H, win.C_WHITE);
    win.bevel(2, 2, CW - 4, PATH_H, false);
    win.text(6, 3, path[0..path_len], win.C_BLACK);

    // 列表区
    const ly = 24;
    const lh = ROWS * ROW_H + 2;
    win.fillRect(2, ly, LIST_W, lh, win.C_WHITE);
    win.bevel(2, ly, LIST_W, lh, false);

    const rows = visualRows();
    const name_col: i32 = 24;
    var vr: usize = top;
    var yy: i32 = ly + 1;
    while (vr < rows and vr < top + ROWS) : (vr += 1) {
        // ".." 行不算条目下标（先算 vr-1 会在 vr=0 时 usize 下溢）
        const is_parent = hasParent() and vr == 0;
        const ei: usize = if (is_parent) 0 else if (hasParent()) vr - 1 else vr;
        const s = !is_parent and sel == ei;
        if (s) win.fillRect(3, yy, LIST_W - 2 - SB_W, ROW_H, win.C_NAVY);
        const fg: u32 = if (s) win.C_WHITE else win.C_BLACK;
        if (is_parent) {
            drawFolder(6, yy + 4);
            win.text(name_col, yy, "..", fg);
        } else {
            const e = &entries[ei];
            if (e.is_dir) {
                drawFolder(6, yy + 4);
                win.text(name_col, yy, label(e), fg);
                win.text(LIST_W - SB_W - 48, yy, "<dir>", fg);
            } else {
                drawFile(7, yy + 3);
                win.text(name_col, yy, label(e), fg);
                var sb: [7]u8 = undefined;
                const sl = fmtSize(e.size, &sb);
                win.text(LIST_W - SB_W - 8 - @as(i32, @intCast(sl.len)) * 8, yy, sl, fg);
            }
        }
        yy += ROW_H;
    }

    // 滚动条
    if (rows > ROWS) {
        const sx = LIST_W - SB_W - 1 + 2;
        const ty0 = ly + 1 + SB_W;
        const thh = lh - 2 - 2 * SB_W;
        win.fillRect(sx, ty0, SB_W, thh, win.C_CHROME);
        win.vline(sx, ly + 1, ly + lh - 2, win.C_SHADOW);
        const ty = thumbY();
        const th = @max(@divTrunc(thh * ROWS, @as(i32, @intCast(rows))), 14);
        win.fillRect(sx, ty, SB_W, th, win.C_CHROME);
        win.bevel(sx, ty, SB_W, th, true);
        arrow(sx, ly + 1, top == 0, false);
        arrow(sx, ly + lh - SB_W - 1, top >= rows - ROWS, true);
    }

    // 预览栏
    const px0 = LIST_W + 8;
    const pw = CW - px0 - 4;
    win.fillRect(px0, ly, pw, lh, win.C_WHITE);
    win.bevel(px0, ly, pw, lh, false);
    const pv_cols: usize = @intCast(@divTrunc(pw - 6, 8));
    const pv_rows: usize = @intCast(@divTrunc(lh - 4, 16));
    const sel_file = sel != null and !entries[sel.?].is_dir;
    if (sel_file) {
        var pos: usize = 0;
        var ry: usize = 0;
        while (pos < prev_len and ry < pv_rows) : (ry += 1) {
            const start = pos;
            while (pos < prev_len and prev[pos] != '\n') pos += 1;
            const line = prev[start..pos];
            if (pos < prev_len) pos += 1;
            win.text(px0 + 3, ly + 2 + @as(i32, @intCast(ry)) * 16, line[0..@min(line.len, pv_cols)], win.C_BLACK);
        }
        if (prev_total > prev.len) win.text(px0 + 3, ly + lh - 18, "...", win.C_SHADOW);
    } else if (sel != null) {
        win.text(px0 + 3, ly + 2, "directory", win.C_SHADOW);
    } else {
        win.text(px0 + 3, ly + 2, "no file selected", win.C_SHADOW);
    }

    // 状态栏：条目数 + 选中项的权限串/属主/大小
    win.fillRect(2, CH - 18, CW - 4, 16, win.C_CHROME);
    win.bevel(2, CH - 18, CW - 4, 16, false);
    var buf: [128]u8 = undefined;
    var n: usize = putNum(&buf, 0, count);
    n += putSlice(&buf, n, " items");
    if (sel) |i| {
        const e = &entries[i];
        var ms: [10]u8 = undefined;
        const mss = zos.modeString(e.mode, &ms);
        n += putSlice(&buf, n, "  |  ");
        n += putSlice(&buf, n, mss);
        n += putSlice(&buf, n, " ");
        n += putNum(&buf, n, e.uid);
        n += putSlice(&buf, n, ":");
        n += putNum(&buf, n, e.gid);
        n += putSlice(&buf, n, " ");
        n += putNum(&buf, n, prev_total);
        n += putSlice(&buf, n, " B");
    }
    win.text(6, CH - 18, buf[0..n], win.C_BLACK);
}

fn putSlice(buf: []u8, pos: usize, s: []const u8) usize {
    const n = @min(s.len, buf.len - pos);
    @memcpy(buf[pos .. pos + n], s[0..n]);
    return n;
}

fn putNum(buf: []u8, pos: usize, v: u64) usize {
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var x = v;
    if (x == 0) {
        if (pos < buf.len) buf[pos] = '0';
        return 1;
    }
    while (x > 0) {
        tmp[n] = '0' + @as(u8, @intCast(x % 10));
        n += 1;
        x /= 10;
    }
    var i: usize = 0;
    while (i < n and pos + i < buf.len) : (i += 1) buf[pos + i] = tmp[n - 1 - i];
    return i;
}

fn fmtSize(v: u32, buf: *[7]u8) []const u8 {
    var len: usize = 0;
    if (v >= 1024 * 1024) {
        len = dec(buf, v / (1024 * 1024));
        buf[len] = 'M';
        len += 1;
    } else if (v > 99_999) {
        len = dec(buf, v);
    } else if (v >= 1024) {
        len = dec(buf, v / 1024);
        buf[len] = 'K';
        len += 1;
    } else {
        len = dec(buf, v);
    }
    return buf[0..len];
}

fn dec(buf: *[7]u8, v: u32) usize {
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

fn drawFolder(x: i32, y: i32) void {
    const yellow = win.color(255, 224, 96);
    win.fillRect(x + 3, y, 8, 2, yellow);
    win.fillRect(x, y + 2, 14, 7, yellow);
    win.fillRect(x + 2, y - 1, 9, 1, win.C_BLACK);
    win.fillRect(x - 1, y + 2, 1, 7, win.C_BLACK);
    win.fillRect(x + 14, y + 2, 1, 7, win.C_BLACK);
    win.fillRect(x - 1, y + 9, 16, 1, win.C_BLACK);
}

fn drawFile(x: i32, y: i32) void {
    win.fillRect(x, y, 9, 11, win.C_WHITE);
    win.fillRect(x, y, 9, 1, win.C_BLACK);
    win.fillRect(x, y + 10, 9, 1, win.C_BLACK);
    win.fillRect(x, y, 1, 11, win.C_BLACK);
    win.fillRect(x + 8, y, 1, 11, win.C_BLACK);
    win.set(x + 6, y + 1, win.C_BLACK);
    win.set(x + 5, y + 2, win.C_BLACK);
    win.fillRect(x + 2, y + 5, 4, 1, win.C_SHADOW);
    win.fillRect(x + 2, y + 7, 5, 1, win.C_SHADOW);
}

fn arrow(x: i32, y: i32, disabled: bool, down: bool) void {
    win.fillRect(x, y, SB_W, SB_W, win.C_CHROME);
    win.bevel(x, y, SB_W, SB_W, true);
    const c: u32 = if (disabled) win.C_SHADOW else win.C_BLACK;
    const cx = x + @divTrunc(SB_W, 2);
    var i: i32 = 0;
    while (i < 4) : (i += 1) {
        const wdt = 7 - i * 2;
        const yy = if (down) y + 6 + i else y + 9 - i;
        win.fillRect(cx - @divTrunc(wdt, 2), yy, wdt, 1, c);
    }
}

// ---------------- 主循环 ----------------

export fn main() i32 {
    if (!win.create(CW, CH, "File Manager")) return 1;
    win.initColors();
    go("/");

    var evs: [8]win.Event = undefined;
    while (true) {
        if (dirty) {
            draw();
            win.present();
            dirty = false;
        }
        const n = win.wait(&evs, 0);
        for (evs[0..n]) |e| {
            switch (e.kind) {
                win.EV_CLOSE => zos.exit(0),
                win.EV_PRESS => press(e.x, e.y),
                else => {},
            }
        }
    }
    return 0;
}
