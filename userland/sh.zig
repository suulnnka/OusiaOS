//! sh —— ZOS 交互式 shell（init 进程，PID 1）
//!
//! 教学要点：
//!   - shell 的本质：read(行) → fork → exec(命令) → waitpid 的循环
//!   - 内建命令（cd/exit/help）在 shell 进程内直接完成，不 fork

const zos = @import("lib/zos.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

var line: [512]u8 = undefined;

export fn main() i32 {
    zos.printf("\nZOS shell (pid={d}) -- type 'help' for commands\n\n", .{zos.getpid()});

    while (true) {
        var cwd: [256]u8 = undefined;
        _ = zos.getcwd(&cwd);
        zos.printf("{s} $ ", .{cstr(&cwd)});

        const n = zos.read(0, &line);
        if (n <= 0) continue;
        var args_buf: [8][64]u8 = undefined;
        const argv = split(cstr(line[0..@intCast(n)]), &args_buf);
        if (argv.len == 0) continue;

        const cmd = argv[0];

        // ---- 内建命令 ----
        if (zos.eql(cmd, "help")) {
            zos.printf(
                \\commands: ls [-l] [dir]  cat <file>  echo <text>  ps  uname
                \\          sleep <sec>  hello  forkdemo  wc [-c|-l|-w]  cdemo
                \\          ifconfig  ping <ip> [n]  curl http://host[:port]/path
                \\          beep [hz] [ms]  music
                \\perms:    id  whoami  su <user>  chmod <octal> <file>
                \\          chown <user> <file>
                \\builtins: cd <dir>  pwd  help  exit
                \\note: 10.0.2.2 = 宿主机（QEMU user 网络）
                \\
            , .{});
            continue;
        }
        if (zos.eql(cmd, "id")) {
            const uid = zos.getuid();
            const gid = zos.getgid();
            var nb: [16]u8 = undefined;
            const un = userByUid(uid, &nb);
            var gb: [16]u8 = undefined;
            const gn = userByUid(gid, &gb); // 教学简化：group 名也走 passwd
            zos.printf("uid={d}({s}) gid={d}({s})\n", .{ uid, un, gid, gn });
            continue;
        }
        if (zos.eql(cmd, "whoami")) {
            var nb: [16]u8 = undefined;
            zos.printf("{s}\n", .{cstrN(&nb, userByUid(zos.getuid(), &nb))});
            continue;
        }
        if (zos.eql(cmd, "su")) {
            const target = if (argv.len >= 2) argv[1] else "root";
            const uid = uidByUser(target) orelse {
                zos.printf("su: unknown user {s}\n", .{target});
                continue;
            };
            // passwd 第 4 列是该用户的主组：一并切换（教学版 su）
            const gid = gidOfUser(target);
            if (gid >= 0) _ = zos.setgid(@intCast(gid));
            const r = zos.setuid(uid);
            if (r != 0) {
                zos.printf("su: setuid({d}) failed: {d} (only root can su others)\n", .{ uid, r });
            } else {
                // 与 id 相同的分步写法：先取名字再打印
                var nb: [16]u8 = undefined;
                const un = userByUid(uid, &nb);
                zos.printf("now uid={d} ({s})\n", .{ uid, un });
            }
            continue;
        }
        if (zos.eql(cmd, "chmod")) {
            if (argv.len < 3) {
                zos.printf("usage: chmod <octal> <file>  e.g. chmod 600 /etc/shadow\n", .{});
                continue;
            }
            const mode = parseOctal(argv[1]);
            const r = zos.chmod(argv[2], mode);
            if (r != 0) zos.printf("chmod: {s}: failed ({d})\n", .{ argv[2], r });
            continue;
        }
        if (zos.eql(cmd, "chown")) {
            if (argv.len < 3) {
                zos.printf("usage: chown <user|uid> <file>\n", .{});
                continue;
            }
            const uid = uidByUser(argv[1]) orelse parseDec(argv[1]);
            const r = zos.chown(argv[2], @intCast(uid), -1);
            if (r != 0) zos.printf("chown: {s}: failed ({d})\n", .{ argv[2], r });
            continue;
        }
        if (zos.eql(cmd, "cd")) {
            if (argv.len < 2) {
                zos.printf("cd: missing argument\n", .{});
            } else {
                const r = zos.chdir(argv[1]);
                if (r < 0) zos.printf("cd: {s}: failed ({d})\n", .{ argv[1], r });
            }
            continue;
        }
        if (zos.eql(cmd, "pwd")) {
            var b: [256]u8 = undefined;
            _ = zos.getcwd(&b);
            zos.printf("{s}\n", .{cstr(&b)});
            continue;
        }
        if (zos.eql(cmd, "exit")) {
            zos.printf("shell exit -- system idle\n", .{});
            return 0;
        }
        if (zos.eql(cmd, "clear")) {
            zos.printf("\x1b[2J\x1b[H", .{}); // 串口 ANSI；VGA 下原样显示
            continue;
        }

        // ---- 外部命令：fork + exec + wait ----
        var path: [80]u8 = undefined;
        const full = if (cmd[0] == '/')
            cmd
        else
            joinPath(&path, "/bin/", cmd);

        const pid = zos.fork();
        if (pid < 0) {
            zos.printf("sh: fork failed\n", .{});
            continue;
        }
        if (pid == 0) {
            // 子进程：执行命令（失败则退出）
            const r = zos.execve(full, argv);
            zos.printf("sh: {s}: not found ({d})\n", .{ full, r });
            zos.exit(127);
        }
        // 父进程：等待子进程
        var status: i32 = 0;
        const wpid = zos.waitpid(pid, &status);
        if (wpid < 0) {
            zos.printf("sh: waitpid failed\n", .{});
        }
    }
    return 0;
}

// ---------------- /etc/passwd 辅助（权限演示） ----------------

/// 读 /etc/passwd 找 uid → 用户名；找不到用数字（buf: [16]u8）
fn userByUid(uid: u32, buf: *[16]u8) []const u8 {
    const fd = zos.open("/etc/passwd", 0);
    if (fd < 0) return numStr(uid, buf);
    defer _ = zos.close(@intCast(fd));
    var pb: [2048]u8 = undefined;
    const n = zos.read(@intCast(fd), pb[0..]);
    if (n <= 0) return numStr(uid, buf);
    // 行格式 name:x:uid:gid:...
    var it = LineIt{ .s = pb[0..@intCast(n)] };
    while (it.next()) |ln| {
        var f: [8][]const u8 = undefined;
        var fn_: usize = 0;
        var i: usize = 0;
        while (i < ln.len and fn_ < f.len) {
            const start = i;
            while (i < ln.len and ln[i] != ':') i += 1;
            f[fn_] = ln[start..i];
            fn_ += 1;
            i += 1;
        }
        if (fn_ >= 3 and parseDec(f[2]) == uid) {
            const l = @min(f[0].len, buf.len);
            @memcpy(buf[0..l], f[0][0..l]);
            return buf[0..l];
        }
    }
    return numStr(uid, buf);
}

/// 用户名 → uid
fn uidByUser(name: []const u8) ?u32 {
    const fd = zos.open("/etc/passwd", 0);
    if (fd < 0) return null;
    defer _ = zos.close(@intCast(fd));
    var pb: [2048]u8 = undefined;
    const n = zos.read(@intCast(fd), pb[0..]);
    if (n <= 0) return null;
    var it = LineIt{ .s = pb[0..@intCast(n)] };
    while (it.next()) |ln| {
        var col: usize = 0;
        var i: usize = 0;
        var uid: u32 = 0;
        var name_ok = false;
        while (i < ln.len) {
            const start = i;
            while (i < ln.len and ln[i] != ':') i += 1;
            const field = ln[start..i];
            if (col == 0) {
                name_ok = zos.eql(field, name);
            } else if (col == 2) {
                uid = parseDec(field);
                break;
            }
            col += 1;
            i += 1;
        }
        if (name_ok) return uid;
    }
    return null;
}

/// 用户名 → 主组 gid（passwd 第 4 列）；找不到 -1
fn gidOfUser(name: []const u8) i64 {
    const fd = zos.open("/etc/passwd", 0);
    if (fd < 0) return -1;
    defer _ = zos.close(@intCast(fd));
    var pb: [2048]u8 = undefined;
    const n = zos.read(@intCast(fd), pb[0..]);
    if (n <= 0) return -1;
    var it = LineIt{ .s = pb[0..@intCast(n)] };
    while (it.next()) |ln| {
        var col: usize = 0;
        var i: usize = 0;
        var gid: i64 = -1;
        var name_ok = false;
        while (i < ln.len) {
            const start = i;
            while (i < ln.len and ln[i] != ':') i += 1;
            const field = ln[start..i];
            if (col == 0) {
                name_ok = zos.eql(field, name);
            } else if (col == 3) {
                gid = @intCast(parseDec(field));
                break;
            }
            col += 1;
            i += 1;
        }
        if (name_ok) return gid;
    }
    return -1;
}

fn numStr(v: u32, buf: *[16]u8) []const u8 {
    var tmp: [12]u8 = undefined;
    var n: usize = 0;
    var x = v;
    if (x == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    while (x > 0) {
        tmp[n] = '0' + @as(u8, @intCast(x % 10));
        n += 1;
        x /= 10;
    }
    var k: usize = 0;
    while (k < n) : (k += 1) buf[k] = tmp[n - 1 - k];
    return buf[0..n];
}

fn parseDec(s: []const u8) u32 {
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn parseOctal(s: []const u8) u32 {
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '7') break;
        v = v * 8 + (c - '0');
    }
    return v;
}

/// 复制到临时缓冲再交给 printf 的 {s}（避免生命周期问题）
fn cstrN(buf: *[16]u8, s: []const u8) []const u8 {
    const n = @min(s.len, 15);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
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

/// 把 NUL 结尾的行按空白切成参数
fn split(s: []const u8, out: *[8][64]u8) [][]const u8 {    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) i += 1;
        if (i >= s.len) break;
        var j = i;
        while (j < s.len and s[j] != ' ' and s[j] != '\t' and s[j] != '\n' and s[j] != '\r') j += 1;
        if (n < out.len) {
            const l = @min(j - i, out[n].len - 1);
            @memcpy(out[n][0..l], s[i .. i + l]);
            out[n][l] = 0;
            n += 1;
        }
        i = j;
    }
    // 返回切片（借用 out）
    var result: [8][]const u8 = undefined;
    for (0..n) |k| result[k] = out[k][0..strlen(&out[k])];
    return @as([][]const u8, result[0..n]);
}

fn strlen(buf: []const u8) usize {
    var i: usize = 0;
    while (i < buf.len and buf[i] != 0) i += 1;
    return i;
}

/// 找到 NUL 截断（read 返回的字节里带 \n）
fn cstr(bytes: []const u8) []const u8 {
    var i: usize = 0;
    while (i < bytes.len and bytes[i] != 0 and bytes[i] != '\n') i += 1;
    return bytes[0..i];
}

/// 极简路径拼接（结果 NUL 结尾）
fn joinPath(buf: []u8, pre: []const u8, s: []const u8) []const u8 {
    const n = @min(pre.len + s.len, buf.len - 1);
    @memcpy(buf[0 .. @min(pre.len, n)], pre[0..@min(pre.len, n)]);
    if (n > pre.len) @memcpy(buf[pre.len..n], s[0 .. n - pre.len]);
    buf[n] = 0;
    return buf[0..n];
}
