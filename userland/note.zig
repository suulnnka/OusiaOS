//! note —— 记事本（用户态 GUI 应用）
//!
//! 键盘焦点的最大受益者，也是 lib/win 三件套的完整展示：
//!   - MenuBar 控件：File（New/Save/Reload/Exit）+ Edit（全选/复制/剪切/粘贴）
//!   - 剪贴板：Ctrl+C/X/V（内核 keyboard.zig 把 Ctrl+字母折成控制码
//!     0x03/0x18/0x16 投进 EV_KEY），Ctrl+A(0x01) 全选
//!   - 选区：鼠标拖动（按下定锚 → EV_MOVE 延伸）或键盘 Shift 是没有的
//!     （EV_KEY 不带修饰键，教学取舍：全选/拖选二选一够用）
//!   - 保存：Ctrl+S 或菜单 → open(O_CREAT|O_TRUNC|O_WRONLY) + write
//!     ——练习④"记事本保存到 ramfs"（文件管理器里双击即回读）
//!   - 启动参数：`note <文件>` 直接打开（File Manager 双击的入口）
//!   - EV_ACTIVATE/DEACTIVATE：非活动窗口不画光标；EV_RESIZE：行数
//!     列数随窗口现算
//!
//! 光标闪烁靠 win_wait 的超时参数：没事件就 500ms 醒一次翻相位。

const zos = @import("lib/zos.zig");
const win = @import("lib/win.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

const MAX_LINES = 128;
const MAX_COLS = 62;
const MENUBAR_H = 18;

const Line = struct {
    len: u8 = 0,
    buf: [MAX_COLS]u8 = undefined,
};

var lines: [MAX_LINES]Line = undefined;
var nlines: usize = 1;
var row: usize = 0;
var col: usize = 0;
var top: usize = 0;
// 选区（字符坐标 (row,col) 的线性化下标，线性行进）
var sel_a: usize = 0;
var sel_b: usize = 0;

var blink = false;
var dirty = true;
var file_path: [160]u8 = undefined;
var path_len: usize = 0;
var modified = false;

// ---- 菜单定义 ----
const file_items = [_][]const u8{ "New", "Save  Ctrl+S", "Reload", "", "Exit" };
const edit_items = [_][]const u8{ "Select All  Ctrl+A", "Copy  Ctrl+C", "Cut  Ctrl+X", "Paste  Ctrl+V" };
const menu_defs = [_]win.MenuDef{
    .{ .label = "File", .items = &file_items },
    .{ .label = "Edit", .items = &edit_items },
};
var menubar = win.MenuBar{ .defs = &menu_defs };

fn filePath() []const u8 {
    return file_path[0..path_len];
}

fn setPath(p: []const u8) void {
    path_len = @min(p.len, file_path.len);
    @memcpy(file_path[0..path_len], p[0..path_len]);
}

fn updateTitle() void {
    var t: [60]u8 = undefined;
    var n: usize = 0;
    n += put(&t, n, "Notepad");
    if (path_len > 0) {
        n += put(&t, n, " - ");
        n += put(&t, n, filePath());
    }
    if (modified) n += put(&t, n, " *");
    win.setTitle(t[0..n]);
}

fn put(buf: []u8, pos: usize, s: []const u8) usize {
    const n = @min(s.len, buf.len - pos);
    @memcpy(buf[pos .. pos + n], s[0..n]);
    return n;
}

// ---- 线性坐标（选区用） ----

fn lineStart(r: usize) usize {
    var s: usize = 0;
    var i: usize = 0;
    while (i < r) : (i += 1) s += lines[i].len + 1;
    return s;
}

fn posOf(r: usize, c: usize) usize {
    return lineStart(r) + c;
}

fn selLo() usize {
    return @min(sel_a, sel_b);
}
fn selHi() usize {
    return @max(sel_a, sel_b);
}
fn hasSel() bool {
    return sel_a != sel_b;
}

fn clearSel() void {
    sel_a = posOf(row, col);
    sel_b = sel_a;
}

fn selectAll() void {
    sel_a = 0;
    sel_b = posOf(nlines - 1, lines[nlines - 1].len);
}

// ---- 剪贴板 ----

fn copySel(cut: bool) void {
    if (!hasSel()) return;
    var cb: [1024]u8 = undefined;
    var n: usize = 0;
    var r: usize = 0;
    var c: usize = 0;
    // 线性扫描到 selHi，落在 [lo,hi) 的字符进缓冲
    while (r < nlines and n < cb.len) {
        while (c < lines[r].len and n < cb.len) {
            const p = posOf(r, c);
            if (p >= selHi()) {
                flushCopy(&cb, n);
                if (!cut) return;
                deleteSel();
                return;
            }
            if (p >= selLo()) {
                cb[n] = lines[r].buf[c];
                n += 1;
            }
            c += 1;
        }
        const p = posOf(r, c);
        if (p >= selHi()) break;
        if (p >= selLo() and r + 1 < nlines and n < cb.len) {
            cb[n] = '\n';
            n += 1;
        }
        r += 1;
        c = 0;
    }
    flushCopy(&cb, n);
    if (cut) deleteSel();
}

fn flushCopy(cb: []const u8, n: usize) void {
    if (n > 0) _ = win.clipSet(cb[0..n]);
}

/// 用剪贴板内容替换选区（无选区则插入）
fn paste() void {
    var cb: [1024]u8 = undefined;
    const n = win.clipGet(&cb);
    if (n <= 0) return;
    deleteSel();
    for (cb[0..@intCast(n)]) |c| {
        if (c == '\n') {
            key('\n');
        } else {
            key(c);
        }
    }
}

fn deleteSel() void {
    if (!hasSel()) return;
    // 把 selLo 折成 (row,col)
    var p: usize = 0;
    var r: usize = 0;
    var c: usize = 0;
    var found = false;
    while (r < nlines) : (r += 1) {
        c = 0;
        while (c <= lines[r].len) : (c += 1) {
            if (p == selLo()) {
                found = true;
                break;
            }
            p += 1;
        }
        if (found) break;
        p += 1; // 换行符
    }
    if (!found) return;
    row = r;
    col = c;
    sel_a = posOf(row, col);
    sel_b = sel_a;
    // 退格 deleteSel 次数 = 选区长度
    const n = selHi() - selLo();
    var i: usize = 0;
    while (i < n) : (i += 1) backspace();
    clearSel();
}

fn backspace() void {
    if (col > 0) {
        const l = &lines[row];
        var i = col - 1;
        while (i < l.len - 1) : (i += 1) l.buf[i] = l.buf[i + 1];
        l.len -= 1;
        col -= 1;
    } else if (row > 0) {
        const prev_len = lines[row - 1].len;
        const cur_len = lines[row].len;
        if (prev_len + cur_len <= MAX_COLS) {
            @memcpy(lines[row - 1].buf[prev_len .. prev_len + cur_len], lines[row].buf[0..cur_len]);
            lines[row - 1].len = prev_len + cur_len;
            var i = row;
            while (i + 1 < nlines) : (i += 1) lines[i] = lines[i + 1];
            nlines -= 1;
            row -= 1;
            col = prev_len;
        } else {
            row -= 1;
            col = prev_len;
        }
    }
}

// ---- 编辑核心 ----

fn scrollFollow() void {
    if (row < top) top = row;
    if (row >= top + visRows()) top = row - visRows() + 1;
}

fn visRows() usize {
    const h: usize = @intCast(@max(win.sh - 28 - MENUBAR_H, 40));
    return @max(h / 16, 1);
}

fn visCols() usize {
    const w: usize = @intCast(@max(win.sw - 8, 40));
    return @min(@max(w / 8, 8), MAX_COLS + 1);
}

fn key(c: u8) void {
    switch (c) {
        win.KEY_UP => {
            if (row > 0) row -= 1;
            col = @min(col, lines[row].len);
            clearSel();
        },
        win.KEY_DOWN => {
            if (row + 1 < nlines) row += 1;
            col = @min(col, lines[row].len);
            clearSel();
        },
        win.KEY_LEFT => {
            if (col > 0) {
                col -= 1;
            } else if (row > 0) {
                row -= 1;
                col = lines[row].len;
            }
            clearSel();
        },
        win.KEY_RIGHT => {
            if (col < lines[row].len) {
                col += 1;
            } else if (row + 1 < nlines) {
                row += 1;
                col = 0;
            }
            clearSel();
        },
        win.KEY_HOME => {
            col = 0;
            clearSel();
        },
        win.KEY_END => {
            col = lines[row].len;
            clearSel();
        },
        win.CTRL_A => selectAll(),
        win.CTRL_C, win.CTRL_X => copySel(c == win.CTRL_X),
        win.CTRL_V => paste(),
        win.CTRL_S => saveFile(),
        '\n' => {
            if (nlines < MAX_LINES) {
                var i = nlines;
                while (i > row + 1) : (i -= 1) lines[i] = lines[i - 1];
                nlines += 1;
                const l = &lines[row];
                const tail: u8 = l.len - @as(u8, @intCast(col));
                @memcpy(lines[row + 1].buf[0..tail], l.buf[col..l.len]);
                lines[row + 1].len = tail;
                l.len = @intCast(col);
                row += 1;
                col = 0;
            }
            clearSel();
            modified = true;
        },
        win.KEY_DEL => {
            if (hasSel()) {
                deleteSel();
            } else if (col < lines[row].len) {
                const l = &lines[row];
                var i = col;
                while (i < l.len - 1) : (i += 1) l.buf[i] = l.buf[i + 1];
                l.len -= 1;
            } else if (row + 1 < nlines) {
                key(win.KEY_RIGHT);
                backspace();
            }
            modified = true;
        },
        0x08 => {
            if (hasSel()) {
                deleteSel();
            } else {
                backspace();
            }
            clearSel();
            modified = true;
        },
        else => {
            if (c < 32 or c >= 127) return;
            if (col >= MAX_COLS) {
                if (nlines < MAX_LINES) key('\n') else return;
            }
            deleteSel();
            const l = &lines[row];
            var i = l.len;
            while (i > col) : (i -= 1) l.buf[i] = l.buf[i - 1];
            l.buf[col] = c;
            l.len += 1;
            col += 1;
            clearSel();
            modified = true;
        },
    }
    scrollFollow();
    dirty = true;
}

// ---- 文件 IO ----

fn loadFile(p: []const u8) bool {
    var zbuf: [256]u8 = undefined;
    const zp = withNul(&zbuf, p);
    const fd = zos.open(zp[0..p.len], win.O_RDONLY);
    if (fd < 0) return false;
    defer _ = zos.close(@intCast(fd));
    var data: [4096]u8 = undefined;
    const n = zos.read(@intCast(fd), &data);
    if (n < 0) return false;

    nlines = 1;
    lines[0] = .{};
    row = 0;
    col = 0;
    top = 0;
    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) {
        const c = data[i];
        if (c == '\n' or c == 0x0D) {
            if (nlines >= MAX_LINES) break;
            nlines += 1;
            lines[nlines - 1] = .{};
            row = nlines - 1;
            col = 0;
        } else if (c >= 32 and c < 127) {
            if (col < MAX_COLS) {
                lines[row].buf[col] = c;
                col += 1;
                lines[row].len = @intCast(col);
            }
        }
    }
    row = 0;
    col = 0;
    clearSel();
    modified = false;
    setPath(p);
    updateTitle();
    dirty = true;
    return true;
}

fn saveFile() void {
    if (path_len == 0) setPath("/tmp/untitled.txt");
    var zbuf: [256]u8 = undefined;
    const zp = withNul(&zbuf, filePath());
    const fd = zos.open(zp[0..path_len], win.O_WRONLY | win.O_CREAT | win.O_TRUNC);
    if (fd < 0) {
        win.sound(5); // error
        return;
    }
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    var r: usize = 0;
    while (r < nlines) : (r += 1) {
        const l = lines[r];
        if (n + l.len > buf.len) break;
        @memcpy(buf[n .. n + l.len], l.buf[0..l.len]);
        n += l.len;
        if (r + 1 < nlines and n < buf.len) {
            buf[n] = '\n';
            n += 1;
        }
    }
    const w = zos.write(@intCast(fd), buf[0..n]);
    _ = zos.close(@intCast(fd));
    if (w >= 0) {
        modified = false;
        win.sound(4); // ding = 保存成功
    } else {
        win.sound(5);
    }
    updateTitle();
    dirty = true;
}

fn newFile() void {
    nlines = 1;
    lines[0] = .{};
    row = 0;
    col = 0;
    top = 0;
    clearSel();
    path_len = 0;
    modified = false;
    updateTitle();
    dirty = true;
}

fn withNul(buf: []u8, s: []const u8) [:0]u8 {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}

// ---- 鼠标 ----

fn textArea() [4]i32 {
    return .{ 4, MENUBAR_H + 4, win.sw - 8, win.sh - 28 - MENUBAR_H };
}

fn mouseToPos(mx: i32, my: i32) struct { r: usize, c: usize } {
    const ta = textArea();
    const vr = @divTrunc(my - ta[1] - 2, 16);
    var r: usize = top + @as(usize, @intCast(@max(0, vr)));
    r = @min(r, nlines - 1);
    const vc = @divTrunc(mx - ta[0] - 2, 8);
    var c: usize = @intCast(@max(0, vc));
    c = @min(c, lines[r].len);
    return .{ .r = r, .c = c };
}

fn press(x: i32, y: i32, dbl: bool) void {
    // 菜单栏优先
    if (menubar.press(x, y, &menu_item_out)) {
        if (menu_item_out.menu == 0) { // File
            switch (menu_item_out.idx) {
                0 => newFile(),
                1 => saveFile(),
                2 => {
                    if (path_len > 0) _ = loadFile(filePath());
                },
                3 => {},
                4 => zos.exit(0),
                else => {},
            }
        } else { // Edit
            switch (menu_item_out.idx) {
                0 => selectAll(),
                1 => copySel(false),
                2 => copySel(true),
                3 => paste(),
                else => {},
            }
        }
        dirty = true;
        return;
    }
    const ta = textArea();
    if (x < ta[0] or y < ta[1] or x >= ta[0] + ta[2] or y >= ta[1] + ta[3]) return;
    const p = mouseToPos(x, y);
    row = p.r;
    col = p.c;
    if (dbl) {
        selectAll();
        sel_a = 0;
        sel_b = posOf(nlines - 1, lines[nlines - 1].len);
    } else {
        sel_a = posOf(row, col);
        sel_b = sel_a;
    }
    scrollFollow();
    dirty = true;
}

fn dragMove(x: i32, y: i32) void {
    const ta = textArea();
    if (x < ta[0] or y < ta[1]) return;
    const p = mouseToPos(x, y);
    row = p.r;
    col = p.c;
    sel_b = posOf(row, col);
    scrollFollow();
    dirty = true;
}

var menu_item_out: win.MenuHit = .{ .menu = 0, .idx = 0 };

// ---- 绘制 ----

fn draw() void {
    win.fillRect(0, 0, win.sw, win.sh, win.C_CHROME);
    menubar.draw(win.sw);

    // 文本区
    const ta = textArea();
    win.fillRect(ta[0], ta[1], ta[2], ta[3], win.C_WHITE);
    win.bevel(ta[0], ta[1], ta[2], ta[3], false);

    const cols = visCols();
    var i: usize = top;
    const vr = visRows();
    while (i < nlines and i < top + vr) : (i += 1) {
        const l = &lines[i];
        const ly = ta[1] + 2 + @as(i32, @intCast(i - top)) * 16;
        if (hasSel()) {
            // 行与选区求交：简单法——整行扫（行数少，教学取舍）
            var c: usize = 0;
            while (c <= l.len) : (c += 1) {
                const p = posOf(i, c);
                const in_sel = p >= selLo() and p < selHi();
                if (c < l.len) {
                    const fg: u32 = if (in_sel) win.C_WHITE else win.C_BLACK;
                    if (in_sel) {
                        win.fillRect(ta[0] + 2 + @as(i32, @intCast(c)) * 8, ly, 8, 16, win.C_NAVY);
                    }
                    const ch = [1]u8{l.buf[c]};
                    win.text(ta[0] + 2 + @as(i32, @intCast(c)) * 8, ly, &ch, fg);
                } else if (in_sel and i + 1 < nlines) {
                    win.fillRect(ta[0] + 2 + @as(i32, @intCast(c)) * 8, ly, 8, 16, win.C_NAVY);
                }
            }
        } else {
            win.text(ta[0] + 2, ly, l.buf[0..@min(l.len, cols)], win.C_BLACK);
        }
    }

    // 光标（闪烁；仅活动窗口）
    if (blink and active and row >= top and row < top + vr) {
        win.fillRect(ta[0] + 2 + @as(i32, @intCast(col)) * 8, ta[1] + 2 + @as(i32, @intCast(row - top)) * 16, 7, 14, win.C_NAVY);
    }

    // 状态栏
    const sy = win.sh - 18;
    win.fillRect(4, sy, win.sw - 8, 16, win.C_CHROME);
    win.bevel(4, sy, win.sw - 8, 16, false);
    var buf: [48]u8 = undefined;
    var n: usize = put(&buf, 0, "Ln ");
    n += num(&buf, n, row + 1);
    n += put(&buf, n, ", Col ");
    n += num(&buf, n, col + 1);
    if (hasSel()) {
        n += put(&buf, n, "  |  ");
        n += num(&buf, n, selHi() - selLo());
        n += put(&buf, n, " selected");
    }
    win.text(8, sy, buf[0..n], win.C_BLACK);
}

var active = true;

fn num(buf: []u8, pos: usize, v: usize) usize {
    var tmp: [8]u8 = undefined;
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

export fn main() i32 {
    if (!win.create(514, 245, "Notepad")) return 1;
    win.initColors();
    updateTitle();

    // 命令行参数：note <文件>
    if (zos.argc() >= 2) {
        const p = zos.arg(1);
        if (p.len > 0) {
            if (!loadFile(p)) {
                // 不存在：作为保存目标（File Manager "New File" 的路径）
                setPath(p);
                updateTitle();
            }
        }
    }

    var evs: [8]win.Event = undefined;
    while (true) {
        if (dirty) {
            draw();
            win.present();
            dirty = false;
        }
        const n = win.wait(&evs, 500); // 500ms：光标闪烁节拍
        if (n == 0) {
            blink = !blink;
            dirty = true;
            continue;
        }
        for (evs[0..n]) |e| {
            switch (e.kind) {
                win.EV_CLOSE => zos.exit(0),
                win.EV_KEY => key(e.code),
                win.EV_PRESS => press(e.x, e.y, false),
                win.EV_DBL => press(e.x, e.y, true),
                win.EV_MOVE => dragMove(e.x, e.y),
                win.EV_ACTIVATE => {
                    active = true;
                    dirty = true;
                },
                win.EV_DEACTIVATE => {
                    active = false;
                    dirty = true;
                },
                win.EV_RESIZE => {
                    // 表面原位重映射（VA 不变）；同步新尺寸，行列现算
                    win.onResizeEvent(e);
                    dirty = true;
                },
                else => {},
            }
        }
    }
    return 0;
}
