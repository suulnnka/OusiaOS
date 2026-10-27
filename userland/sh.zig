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
                \\commands: ls [dir]  cat <file>  echo <text>  ps  uname
                \\          sleep <sec>  hello  forkdemo  wc [-c|-l|-w]  cdemo
                \\          ifconfig  ping <ip> [n]  curl http://host[:port]/path
                \\          beep [hz] [ms]  music
                \\builtins: cd <dir>  pwd  help  exit
                \\note: 10.0.2.2 = 宿主机（QEMU user 网络）
                \\
            , .{});
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

/// 把 NUL 结尾的行按空白切成参数
fn split(s: []const u8, out: *[8][64]u8) [][]const u8 {
    var n: usize = 0;
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
