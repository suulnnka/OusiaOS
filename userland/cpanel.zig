//! cpanel —— Control Panel（用户态 GUI 应用）
//!
//! 收尾点缀类应用的样板，同时是"设置持久化"闭环的 UI 端：
//!   - Display：8 色壁纸色板，单击即改桌面底色（写 /etc/zos.conf）
//!   - Screen Saver：Off/15/30/60/120 秒单选（写 /etc/zos.conf）
//!   - Sounds：音量 +/- 与 Test（AC'97 mixer 衰减寄存器；Test 播 ding）
//!   - 保存 = open(/etc/zos.conf, O_CREAT|O_TRUNC|O_WRONLY) + write
//!     ——内核 gui.lateInit 开机读回。0.3 起 / 在 ext2 磁盘上，
//!     设置天然持久（掉电不丢）
//!
//! 布局：左列分区标题 + 右列控件；状态栏显示保存结果。

const zos = @import("lib/zos.zig");
const win = @import("lib/win.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

const CW = 360;
const CH = 280;
const CONF_FILE = "/etc/zos.conf";

const wallpaper_colors = [8][3]u8{
    .{ 0x00, 0x80, 0x80 }, // 经典青绿（默认）
    .{ 0x3A, 0x6E, 0xA5 }, // 钢蓝
    .{ 0x00, 0x40, 0x80 }, // 藏青
    .{ 0x40, 0x40, 0x40 }, // 石墨
    .{ 0x80, 0x50, 0x30 }, // 赭石
    .{ 0x30, 0x60, 0x30 }, // 苔绿
    .{ 0x60, 0x30, 0x60 }, // 紫檀
    .{ 0x20, 0x20, 0x20 }, // 近黑
};
const saver_opts = [_]i32{ 0, 15, 30, 60, 120 }; // 0 = 禁用
const saver_labels = [_][]const u8{ "Off", "15 sec", "30 sec", "60 sec", "120 sec" };

var wallpaper_sel: usize = 0;
var saver_sel: usize = 3; // 默认 60s（与内核初值一致）
var volume: i32 = 70; // 0..100
var status: [64]u8 = undefined;
var status_len: usize = 0;
var dirty = true;

fn setStatus(s: []const u8) void {
    status_len = @min(s.len, status.len);
    @memcpy(status[0..status_len], s[0..status_len]);
}

// ---- 几何 ----
const SEC_X = 12;
const CTL_X = 130;
const ROW_Y = [_]i32{ 26, 92, 158, 224 };

fn swatchRect(i: usize) struct { x: i32, y: i32 } {
    return .{ .x = CTL_X + @as(i32, @intCast(i % 4)) * 42, .y = ROW_Y[0] + @as(i32, @intCast(i / 4)) * 22 };
}

fn saverRect(i: usize) struct { x: i32, y: i32 } {
    return .{ .x = CTL_X + @as(i32, @intCast(i % 3)) * 72, .y = ROW_Y[1] + @as(i32, @intCast(i / 3)) * 22 };
}

fn inBox(x: i32, y: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return x >= bx and y >= by and x < bx + bw and y < by + bh;
}

// ---- 设置 IO ----

fn saveConf() void {
    const fd = zos.open(CONF_FILE, win.O_WRONLY | win.O_CREAT | win.O_TRUNC);
    if (fd < 0) {
        setStatus("save failed (fs?)");
        win.sound(5);
        return;
    }
    defer _ = zos.close(@intCast(fd));
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    const c = wallpaper_colors[wallpaper_sel];
    n += put(&buf, n, "wallpaper=");
    n += putNum(buf[n..], c[0]);
    n += put(&buf, n, ",");
    n += putNum(buf[n..], c[1]);
    n += put(&buf, n, ",");
    n += putNum(buf[n..], c[2]);
    n += put(&buf, n, "\n");
    n += put(&buf, n, "saver=");
    n += putNum(buf[n..], @intCast(saver_opts[saver_sel]));
    n += put(&buf, n, "\n");
    n += put(&buf, n, "volume=");
    n += putNum(buf[n..], @intCast(@max(volume, 0)));
    n += put(&buf, n, "\n");
    const w = zos.write(@intCast(fd), buf[0..n]);
    if (w >= 0) {
        setStatus("saved to " ++ CONF_FILE);
        win.sound(4);
    } else {
        setStatus("write failed");
        win.sound(5);
    }
}

fn loadConf() void {
    const fd = zos.open(CONF_FILE, win.O_RDONLY);
    if (fd < 0) return;
    defer _ = zos.close(@intCast(fd));
    var buf: [128]u8 = undefined;
    const n = zos.read(@intCast(fd), &buf);
    var it = LineIt{ .s = buf[0..@intCast(@max(n, 0))] };
    while (it.next()) |line| {
        const eq = indexOf(line, '=') orelse continue;
        const key = line[0..eq];
        const val = line[eq + 1 ..];
        if (eqlStr(key, "wallpaper")) {
            // 三个逗号分隔的十进制数
            var idx: usize = 0;
            var vals: [3]u32 = .{ 0, 0, 0 };
            var cur: u32 = 0;
            var any = false;
            var parts: usize = 0;
            for (val) |ch| {
                if (ch == ',') {
                    if (idx < 3) vals[idx] = cur;
                    idx += 1;
                    parts += 1;
                    cur = 0;
                    any = false;
                } else if (ch >= '0' and ch <= '9') {
                    cur = cur * 10 + (ch - '0');
                    any = true;
                }
            }
            if (any and idx < 3) vals[idx] = cur;
            // 找最近的预设色板（只认色板里的颜色；自定义色近似匹配）
            var bestj: usize = 0;
            var bestd: i64 = 1 << 30;
            for (wallpaper_colors, 0..) |wc, j| {
                const dr: i64 = @as(i64, wc[0]) - vals[0];
                const dg: i64 = @as(i64, wc[1]) - vals[1];
                const db: i64 = @as(i64, wc[2]) - vals[2];
                const d = dr * dr + dg * dg + db * db;
                if (d < bestd) {
                    bestd = d;
                    bestj = j;
                }
            }
            wallpaper_sel = bestj;
        } else if (eqlStr(key, "saver")) {
            const v: i32 = @intCast(parseNum(val));
            for (saver_opts, 0..) |o, k| {
                if (o == v) saver_sel = k;
            }
        }
    }
}

fn put(buf: []u8, pos: usize, s: []const u8) usize {
    const n = @min(s.len, buf.len - pos);
    @memcpy(buf[pos .. pos + n], s[0..n]);
    return n;
}

fn putNum(buf: []u8, v: u32) usize {
    var tmp: [12]u8 = undefined;
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

fn parseNum(s: []const u8) u32 {
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn eqlStr(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn indexOf(s: []const u8, c: u8) ?usize {
    for (s, 0..) |x, i| {
        if (x == c) return i;
    }
    return null;
}

const LineIt = struct {
    s: []const u8,
    pos: usize = 0,

    fn next(self: *LineIt) ?[]const u8 {
        if (self.pos >= self.s.len) return null;
        const start = self.pos;
        while (self.pos < self.s.len and self.s[self.pos] != '\n') self.pos += 1;
        const l = self.s[start..self.pos];
        self.pos += 1;
        return l;
    }
};

// ---- 事件 ----

fn press(x: i32, y: i32) void {
    // 壁纸色板
    for (wallpaper_colors, 0..) |_, i| {
        const r = swatchRect(i);
        if (inBox(x, y, r.x, r.y, 40, 20)) {
            wallpaper_sel = i;
            dirty = true;
            saveConf();
            return;
        }
    }
    // 屏保选项（单选按钮）
    for (saver_opts, 0..) |_, i| {
        const r = saverRect(i);
        if (inBox(x, y, r.x, r.y, 68, 20)) {
            saver_sel = i;
            dirty = true;
            saveConf();
            return;
        }
    }
    // 音量 - / +
    if (inBox(x, y, CTL_X, ROW_Y[2], 40, 22)) {
        volume = @max(volume - 10, 0);
        applyVolume();
        dirty = true;
        return;
    }
    if (inBox(x, y, CTL_X + 100, ROW_Y[2], 40, 22)) {
        volume = @min(volume + 10, 100);
        applyVolume();
        dirty = true;
        return;
    }
    // Test 音
    if (inBox(x, y, CTL_X + 60, ROW_Y[2], 36, 22)) {
        win.sound(4);
        return;
    }
}

fn applyVolume() void {
    // 立即生效：SYS_zos_volume(508) 直写 AC'97 mixer 衰减寄存器；
    // 同时落 conf（volume= 行，内核启动时恢复）——即时与持久各一份
    _ = zos.syscall1(509, @intCast(volume));
    saveConf();
}

// ---- 绘制 ----

fn sectionTitle(y: i32, t: []const u8) void {
    win.textBold(SEC_X, y, t, win.C_BLACK);
    win.hline(SEC_X, CW - 14, y + 14, win.C_SHADOW);
    win.hline(SEC_X, CW - 14, y + 15, win.C_WHITE);
}

fn radio(x: i32, y: i32, w: i32, sel_on: bool, label: []const u8) void {
    win.fillRect(x, y, w, 20, win.C_CHROME);
    win.bevel2(x, y, w, 20, !sel_on);
    const fg: u32 = if (sel_on) win.C_BLACK else win.C_SHADOW;
    win.text(x + 6, y + 2, label, fg);
}

fn draw() void {
    win.fillRect(0, 0, CW, CH, win.C_CHROME);
    win.textBold(CW - 120, 4, "Control Panel", win.C_BLACK);

    // Display
    sectionTitle(ROW_Y[0] - 14, "Display - wallpaper");
    for (wallpaper_colors, 0..) |c, i| {
        const r = swatchRect(i);
        win.fillRect(r.x, r.y, 40, 20, win.color(c[0], c[1], c[2]));
        if (wallpaper_sel == i) {
            win.rectStroke(r.x - 1, r.y - 1, 42, 22, win.C_BLACK);
            win.rectStroke(r.x - 2, r.y - 2, 44, 24, win.C_WHITE);
        }
    }

    // Screen Saver
    sectionTitle(ROW_Y[1] - 14, "Screen Saver");
    for (saver_opts, 0..) |_, i| {
        const r = saverRect(i);
        radio(r.x, r.y, 68, saver_sel == i, saver_labels[i]);
    }

    // Sounds
    sectionTitle(ROW_Y[2] - 14, "Sounds - volume");
    // 音量条（凹槽 + 实心条）
    win.fillRect(CTL_X, ROW_Y[2] + 6, 160, 10, win.C_WHITE);
    win.bevel(CTL_X, ROW_Y[2] + 6, 160, 10, false);
    const fill_w: i32 = @intCast(@divTrunc(@as(i32, @intCast(volume)) * 156, 100));
    win.fillRect(CTL_X + 2, ROW_Y[2] + 8, fill_w, 6, win.C_NAVY);
    // - Test + 按钮
    win.fillRect(CTL_X, ROW_Y[2] - 26, 40, 22, win.C_CHROME);
    win.bevel2(CTL_X, ROW_Y[2] - 26, 40, 22, true);
    win.text(CTL_X + 16, ROW_Y[2] - 24, "-", win.C_BLACK);
    win.fillRect(CTL_X + 60, ROW_Y[2] - 26, 36, 22, win.C_CHROME);
    win.bevel2(CTL_X + 60, ROW_Y[2] - 26, 36, 22, true);
    win.text(CTL_X + 66, ROW_Y[2] - 24, "Test", win.C_BLACK);
    win.fillRect(CTL_X + 100, ROW_Y[2] - 26, 40, 22, win.C_CHROME);
    win.bevel2(CTL_X + 100, ROW_Y[2] - 26, 40, 22, true);
    win.text(CTL_X + 116, ROW_Y[2] - 24, "+", win.C_BLACK);
    var vb: [8]u8 = undefined;
    const vs = numStr(volume, &vb);
    win.text(CTL_X + 146, ROW_Y[2] - 22, vs, win.C_BLACK);
    win.text(CTL_X + 146 + @as(i32, @intCast(vs.len)) * 8, ROW_Y[2] - 22, "%", win.C_BLACK);

    // About 文本（多档字号演示：小字页脚）
    win.text(SEC_X, ROW_Y[3], "ZOS settings persist in " ++ CONF_FILE, win.C_SHADOW);
    win.text(SEC_X, ROW_Y[3] + 14, "(ext2 disk: survives reboot)", win.C_SHADOW);

    // 状态栏
    win.fillRect(2, CH - 18, CW - 4, 16, win.C_CHROME);
    win.bevel(2, CH - 18, CW - 4, 16, false);
    win.text(6, CH - 17, status[0..status_len], win.C_BLACK);
}

fn numStr(v: i32, buf: *[8]u8) []const u8 {
    var x: u32 = @intCast(@max(v, 0));
    var tmp: [8]u8 = undefined;
    var n: usize = 0;
    if (x == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    while (x > 0) {
        tmp[n] = '0' + @as(u8, @intCast(x % 10));
        n += 1;
        x /= 10;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) buf[i] = tmp[n - 1 - i];
    return buf[0..n];
}

export fn main() i32 {
    if (!win.create(CW, CH, "Control Panel")) return 1;
    win.initColors();
    loadConf();
    setStatus("ready");

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
                win.EV_KEY => {},
                win.EV_RESIZE => { win.onResizeEvent(e); dirty = true; },
                else => {},
            }
        }
    }
    return 0;
}
