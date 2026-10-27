//! fm —— File Manager（用户态 GUI 应用）
//!
//! 内核 GUI 时代的 apps/filer.zig 移植 + 可写文件系统的完整 UI：
//!   - File 菜单：New File / New Folder / Delete / Exit；Edit：Copy；
//!     View：Refresh——菜单栏是 lib/win.MenuBar 控件
//!   - New File/Folder 用【Edit 控件】行内对话框收名字（"Edit 控件"
//!     特性的首个真实用户），open(O_CREAT) / zos.mkdir 落盘
//!   - 双击（EV_DBL）：目录进入；文本文件 fork+execve 交给 Notepad
//!     （窗口多实例练习②的另一半：同一应用可以同时开多个）
//!   - Delete：unlink 文件 / rmdir 空目录（内核查权限，失败在状态栏报错）
//!   - Copy + Paste：Ctrl+C 把选中路径放系统剪贴板，Paste 读回并把
//!     文件内容复制到 "Copy of <名字>"——纯用户态 read+write 组合
//!   - 焦点回到窗口（EV_ACTIVATE）自动重列目录（练习④的"联动刷新"：
//!     Notepad 保存后切回来立即看到新大小）
//!   - 标题栏实时显示当前路径（win_title 系统调用）

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
const MENUBAR_H = 18;

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

// ---- 行内对话框状态（New File / New Folder 共用）----
const Dialog = enum { none, new_file, new_folder };
var dialog: Dialog = .none;
var dlg_edit: win.Edit = .{};
var status_msg: [64]u8 = undefined;
var status_len: usize = 0;

// ---- 菜单 ----
const file_items = [_][]const u8{ "New File...", "New Folder...", "Delete", "", "Exit" };
const edit_items = [_][]const u8{"Copy  Ctrl+C"};
const view_items = [_][]const u8{"Refresh  F5"};
const menu_defs = [_]win.MenuDef{
    .{ .label = "File", .items = &file_items },
    .{ .label = "Edit", .items = &edit_items },
    .{ .label = "View", .items = &view_items },
};
var menubar = win.MenuBar{ .defs = &menu_defs };
var menu_item_out: win.MenuHit = .{ .menu = 0, .idx = 0 };

fn label(e: *const Entry) []const u8 {
    return e.name[0..e.nlen];
}

fn hasParent() bool {
    return path_len > 1;
}

fn visualRows() usize {
    return count + @intFromBool(hasParent());
}

fn setStatus(s: []const u8) void {
    status_len = @min(s.len, status_msg.len);
    @memcpy(status_msg[0..status_len], s[0..status_len]);
    dirty = true;
}

fn go(p: []const u8) void {
    if (p.len == 0 or p.len > path.len) return;
    @memcpy(path[0..p.len], p);
    path_len = p.len;
    list();
    updateTitle();
}

fn up() void {
    if (path_len <= 1) return;
    path_len -= 1;
    while (path_len > 1 and path[path_len - 1] != '/') path_len -= 1;
    if (path_len > 1) path_len -= 1;
    list();
    updateTitle();
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
    updateTitle();
}

fn updateTitle() void {
    var t: [60]u8 = undefined;
    var n: usize = put(&t, 0, "File Manager: ");
    n += put(&t, n, path[0..path_len]);
    win.setTitle(t[0..n]);
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
            const k = entries[i];
            var j = i;
            while (j > 0 and less(&k, &entries[j - 1])) : (j -= 1) entries[j] = entries[j - 1];
            entries[j] = k;
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

fn fullPath(buf: []u8, name: []const u8) []const u8 {
    var zpath: [256]u8 = undefined;
    _ = withNul(&zpath, path[0..path_len]);
    return joinPath(buf, zpath[0..path_len], name);
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

/// 双击/回车打开：目录进入；文件 → 交给 Notepad（fork+execve，
/// 子进程重新变成自己的窗口——File Manager 继续活着）
fn openEntry(i: usize) void {
    const e = &entries[i];
    if (e.is_dir) {
        enter(label(e));
        return;
    }
    var full: [300]u8 = undefined;
    var zfull: [320]u8 = undefined;
    const fl = fullPath(&full, label(e));
    const zf = withNul(&zfull, fl);
    const pid = zos.fork();
    if (pid == 0) {
        // 子进程：变成 Notepad（失败就退出，不留孤儿命令进程）
        const argv = [_][]const u8{ "/bin/note", zf[0..fl.len] };
        const r = zos.execve("/bin/note", &argv);
        _ = r;
        zos.exit(1);
    }
    setStatus("opened in Notepad");
    win.sound(2); // open
}

// ---- 文件操作（可写文件系统的 UI 面） ----

fn startDialog(d: Dialog) void {
    dialog = d;
    dlg_edit = .{};
    dlg_edit.setText(if (d == .new_file) "untitled.txt" else "folder");
    // 预全选默认名：直接打字即替换（双击对话框也能改）
    dlg_edit.sel_a = 0;
    dlg_edit.sel_b = dlg_edit.len;
    dirty = true;
}

fn dialogOk() void {
    const name = dlg_edit.content();
    defer dialog = .none;
    if (name.len == 0) return;
    var full: [300]u8 = undefined;
    const fl = fullPath(&full, name);
    var zfl: [320]u8 = undefined;
    const zf = withNul(&zfl, fl);
    var msg: [96]u8 = undefined;
    switch (dialog) {
        .new_file => {
            // O_CREAT|O_EXCL：已存在报 EEXIST，不覆盖
            const fd = zos.open(zf[0..fl.len], win.O_WRONLY | win.O_CREAT | win.O_EXCL);
            if (fd >= 0) {
                _ = zos.close(@intCast(fd));
                setStatus("file created");
                win.sound(2);
            } else {
                setStatus(fmtErr("create failed", fd, &msg));
                win.sound(5);
            }
        },
        .new_folder => {
            const r = zos.mkdir(zf[0..fl.len], 0o755);
            if (r == 0) {
                setStatus("folder created");
                win.sound(2);
            } else {
                setStatus(fmtErr("mkdir failed", r, &msg));
                win.sound(5);
            }
        },
        .none => {},
    }
    list();
}

fn deleteSel() void {
    const i = sel orelse return;
    const e = &entries[i];
    var full: [300]u8 = undefined;
    var zfl: [320]u8 = undefined;
    const fl = fullPath(&full, label(e));
    const zf = withNul(&zfl, fl);
    var msg: [96]u8 = undefined;
    const r = if (e.is_dir) zos.rmdir(zf[0..fl.len]) else zos.unlink(zf[0..fl.len]);
    if (r == 0) {
        setStatus(if (e.is_dir) "folder removed" else "file deleted");
        win.sound(3); // close
    } else {
        // 常见失败：目录非空 / 权限——内核的 errno 直接透出
        setStatus(fmtErr("delete failed", r, &msg));
        win.sound(5);
    }
    sel = null;
    list();
}

fn copySelToClip() void {
    const i = sel orelse return;
    var full: [300]u8 = undefined;
    const fl = fullPath(&full, label(&entries[i]));
    _ = win.clipSet(fl);
    setStatus("path copied");
}

/// 剪贴板里的路径 → 复制文件内容到当前目录 "Copy of <name>"
fn pasteFromClip() void {
    var cb: [1024]u8 = undefined;
    const n = win.clipGet(&cb);
    if (n <= 0) {
        setStatus("clipboard empty");
        return;
    }
    const src = cb[0..@intCast(n)];
    // 找文件名（最后一个 '/' 后）
    var base: usize = 0;
    for (src, 0..) |c, k| {
        if (c == '/') base = k + 1;
    }
    const name = src[base..];
    if (name.len == 0) {
        setStatus("clipboard has no file path");
        return;
    }
    var dst: [300]u8 = undefined;
    var dn: usize = 0;
    dn += put(&dst, dn, "Copy of ");
    dn += put(&dst, dn, name);
    var zsrc: [320]u8 = undefined;
    var zdst: [320]u8 = undefined;
    const zs = withNul(&zsrc, src);
    const zd = withNul(&zdst, dst[0..dn]);

    const sfd = zos.open(zs[0..src.len], win.O_RDONLY);
    if (sfd < 0) {
        setStatus("cannot open clipboard file");
        win.sound(5);
        return;
    }
    defer _ = zos.close(@intCast(sfd));
    const dfd = zos.open(zd[0..dn], win.O_WRONLY | win.O_CREAT | win.O_TRUNC);
    if (dfd < 0) {
        setStatus("create Copy of ... failed");
        win.sound(5);
        return;
    }
    defer _ = zos.close(@intCast(dfd));
    var buf: [2048]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const r = zos.read(@intCast(sfd), &buf);
        if (r <= 0) break;
        var off: usize = 0;
        while (off < @as(usize, @intCast(r))) {
            const w = zos.write(@intCast(dfd), buf[off..@intCast(r)]);
            if (w <= 0) break;
            off += @intCast(w);
            total += @intCast(w);
        }
    }
    var msg: [64]u8 = undefined;
    var mn: usize = 0;
    mn += put(&msg, 0, "copied ");
    mn += putNum(&msg, mn, total);
    mn += put(&msg, mn, " bytes");
    setStatus(msg[0..mn]);
    win.sound(4);
    list();
}

fn fmtErr(prefix: []const u8, code: isize, buf: []u8) []const u8 {
    var n: usize = put(buf, 0, prefix);
    n += put(buf, n, " (err ");
    n += putNum(buf, n, @intCast(-code));
    n += put(buf, n, ")");
    return buf[0..n];
}

fn put(buf: []u8, pos: usize, s: []const u8) usize {
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

// ---- 鼠标/键盘 ----

const DIALOG_Y = 24 + ROWS * ROW_H + 6;

fn press(x: i32, y: i32, dbl: bool) void {
    // 菜单栏
    if (menubar.press(x, y, &menu_item_out)) {
        handleMenu();
        return;
    }
    // 行内对话框：Edit + OK/Cancel
    if (dialog != .none) {
        if (inBox(x, y, 8, DIALOG_Y, LIST_W - 120, 20)) {
            _ = dlg_edit.content();
            dlg_edit.click(x - 8 - 3, dbl);
            dirty = true;
            return;
        }
        if (inBox(x, y, LIST_W - 108, DIALOG_Y, 48, 20)) {
            dialogOk();
            return;
        }
        if (inBox(x, y, LIST_W - 56, DIALOG_Y, 48, 20)) {
            dialog = .none;
            dirty = true;
            return;
        }
        return;
    }

    // 滚动条
    const total = visualRows();
    if (total > ROWS) {
        if (inBox(x, y, LIST_W - SB_W - 1, MENUBAR_H + 24, SB_W, SB_W)) { // ▲
            if (top > 0) top -= 1;
            dirty = true;
            return;
        }
        if (inBox(x, y, LIST_W - SB_W - 1, MENUBAR_H + 24 + ROWS * ROW_H - SB_W - 1, SB_W, SB_W)) { // ▼
            if (top < total - ROWS) top += 1;
            dirty = true;
            return;
        }
        const track_y = MENUBAR_H + 24 + SB_W;
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
    if (!inBox(x, y, 0, MENUBAR_H + 24, LIST_W, ROWS * ROW_H + 2)) return;
    const vy = @divTrunc(y - MENUBAR_H - 24 - 1, ROW_H);
    if (vy < 0 or vy >= ROWS) return;
    const vr = top + @as(usize, @intCast(vy));
    if (hasParent()) {
        if (vr == 0) {
            up();
            return;
        }
        if (vr - 1 < count) {
            if (dbl) openEntry(vr - 1) else clickRow(vr - 1);
        }
    } else if (vr < count) {
        if (dbl) openEntry(vr) else clickRow(vr);
    }
}

fn handleMenu() void {
    switch (menu_item_out.menu) {
        0 => switch (menu_item_out.idx) {
            0 => startDialog(.new_file),
            1 => startDialog(.new_folder),
            2 => deleteSel(),
            3 => {},
            4 => zos.exit(0),
            else => {},
        },
        1 => copySelToClip(), // Edit: Copy
        2 => list(), // View: Refresh
        else => {},
    }
    dirty = true;
}

fn clickRow(i: usize) void {
    const e = &entries[i];
    if (e.is_dir) {
        enter(label(e));
    } else {
        selectEntry(i);
    }
}

fn key(c: u8) void {
    if (dialog != .none) {
        switch (c) {
            '\n', 0x0D => dialogOk(),
            0x1B => dialog = .none,
            else => {
                if (dlg_edit.key(c)) dirty = true;
            },
        }
        dirty = true;
        return;
    }
    switch (c) {
        win.CTRL_C => copySelToClip(),
        win.CTRL_V => pasteFromClip(),
        '\n', 0x0D => {
            if (sel) |i| openEntry(i);
        },
        0x1B => {},
        else => {},
    }
    dirty = true;
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
    return MENUBAR_H + 24 + SB_W + @divTrunc(movable * @as(i32, @intCast(top)), @as(i32, @intCast(total - ROWS)));
}

// ---------------- 绘制 ----------------

fn draw() void {
    const CWV = win.sw; // 窗口可能被最大化：按实际表面画
    const CHV = win.sh;
    win.fillRect(0, 0, CWV, CHV, win.C_CHROME);
    menubar.draw(CWV);
    const MB = MENUBAR_H;

    // 路径栏（凹白）
    win.fillRect(2, MB + 2, CWV - 4, PATH_H, win.C_WHITE);
    win.bevel(2, MB + 2, CWV - 4, PATH_H, false);
    win.text(6, MB + 3, path[0..path_len], win.C_BLACK);

    // 列表区
    const ly = MB + 24;
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
    const pw = CWV - px0 - 4;
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

    // 行内对话框（New File/Folder）
    if (dialog != .none) {
        win.fillRect(6, DIALOG_Y - 2, CWV - 12, 26, win.C_CHROME);
        win.bevel2(6, DIALOG_Y - 2, CWV - 12, 26, true);
        win.text(10, DIALOG_Y + 2, if (dialog == .new_file) "Name:" else "Dir :", win.C_BLACK);
        dlg_edit.focused = true;
        dlg_edit.draw(52, DIALOG_Y, LIST_W - 130, 20);
        // OK / Cancel
        win.fillRect(LIST_W - 108, DIALOG_Y, 48, 20, win.C_CHROME);
        win.bevel2(LIST_W - 108, DIALOG_Y, 48, 20, true);
        win.text(LIST_W - 108 + 14, DIALOG_Y + 2, "OK", win.C_BLACK);
        win.fillRect(LIST_W - 56, DIALOG_Y, 48, 20, win.C_CHROME);
        win.bevel2(LIST_W - 56, DIALOG_Y, 48, 20, true);
        win.text(LIST_W - 56 + 6, DIALOG_Y + 2, "Cancel", win.C_BLACK);
    }

    // 状态栏：条目数 + 选中项的权限串/属主/大小 + 操作消息
    win.fillRect(2, CHV - 18, CWV - 4, 16, win.C_CHROME);
    win.bevel(2, CHV - 18, CWV - 4, 16, false);
    var buf: [128]u8 = undefined;
    var n: usize = putNum(&buf, 0, count);
    n += put(&buf, n, " items");
    if (status_len > 0) {
        n += put(&buf, n, "  |  ");
        n += put(&buf, n, status_msg[0..status_len]);
    } else if (sel) |i| {
        const e = &entries[i];
        var ms: [10]u8 = undefined;
        const mss = zos.modeString(e.mode, &ms);
        n += put(&buf, n, "  |  ");
        n += put(&buf, n, mss);
        n += put(&buf, n, " ");
        n += putNum(&buf, n, e.uid);
        n += put(&buf, n, ":");
        n += putNum(&buf, n, e.gid);
        n += put(&buf, n, " ");
        n += putNum(&buf, n, prev_total);
        n += put(&buf, n, " B");
    }
    win.text(6, CHV - 18, buf[0..n], win.C_BLACK);
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
    const yellow = win.C_YELLOW;
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
                win.EV_PRESS => press(e.x, e.y, false),
                win.EV_DBL => press(e.x, e.y, true),
                win.EV_KEY => key(e.code),
                win.EV_ACTIVATE => list(), // 焦点回来 → 重列（保存联动刷新）
                win.EV_RESIZE => { win.onResizeEvent(e); dirty = true; }, // 最大化/还原：按新表面重画
                win.EV_MOVE => {
                    if (menubar.motion(e.x, e.y)) dirty = true;
                },
                else => {},
            }
        }
    }
    return 0;
}
