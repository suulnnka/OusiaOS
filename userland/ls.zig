//! ls —— 列目录（-l 显示 Linux 风格权限串/属主/大小）

const zos = @import("lib/zos.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

export fn main() i32 {
    var long = false;
    var path: []const u8 = "/";

    var i: usize = 1;
    while (i < zos.argc()) : (i += 1) {
        const a = zos.arg(i);
        if (zos.eql(a, "-l")) {
            long = true;
        } else if (a.len > 0 and a[0] != '-') {
            path = a;
        }
    }

    var entries: [32]zos.Dirent = undefined;
    const n = zos.listDir(path, &entries);
    if (n < 0) {
        zos.printf("ls: {s}: cannot list ({d})\n", .{ path, n });
        return 1;
    }
    for (entries[0..@intCast(n)]) |*e| {
        if (!long) {
            if (e.is_dir) {
                zos.printf("{s:<10} <dir>\n", .{e.nameSlice()});
            } else {
                zos.printf("{s}\n", .{e.nameSlice()});
            }
            continue;
        }
        // -l：open + fstat 拿 mode/uid/gid/size
        var full: [300]u8 = undefined;
        const fl = join(&full, path, e.nameSlice());
        if (zos.stat(fl)) |st| {
            var ms: [10]u8 = undefined;
            zos.printf("{s} {d:>3} {d:>4} {d:>7}  {s}\n", .{
                zos.modeString(st.mode, &ms),
                st.uid,
                st.gid,
                st.size,
                e.nameSlice(),
            });
        } else {
            zos.printf("??????????  ?    ?       ?  {s}\n", .{e.nameSlice()});
        }
    }
    return 0;
}

fn join(buf: []u8, base: []const u8, name: []const u8) []const u8 {
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
