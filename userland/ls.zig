//! ls —— 列目录（-l 显示 Linux 风格权限串/属主/大小）

const ousia = @import("lib/ousia.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

export fn main() i32 {
    var long = false;
    var path: []const u8 = "/";

    var i: usize = 1;
    while (i < ousia.argc()) : (i += 1) {
        const a = ousia.arg(i);
        if (ousia.eql(a, "-l")) {
            long = true;
        } else if (a.len > 0 and a[0] != '-') {
            path = a;
        }
    }

    var entries: [32]ousia.Dirent = undefined;
    const n = ousia.listDir(path, &entries);
    if (n < 0) {
        ousia.printf("ls: {s}: cannot list ({d})\n", .{ path, n });
        return 1;
    }
    for (entries[0..@intCast(n)]) |*e| {
        if (!long) {
            if (e.is_dir) {
                ousia.printf("{s:<10} <dir>\n", .{e.nameSlice()});
            } else {
                ousia.printf("{s}\n", .{e.nameSlice()});
            }
            continue;
        }
        // -l：open + fstat 拿 mode/uid/gid/size
        var full: [300]u8 = undefined;
        const fl = join(&full, path, e.nameSlice());
        if (ousia.stat(fl)) |st| {
            var ms: [10]u8 = undefined;
            ousia.printf("{s} {d:>3} {d:>4} {d:>7}  {s}\n", .{
                ousia.modeString(st.mode, &ms),
                st.uid,
                st.gid,
                st.size,
                e.nameSlice(),
            });
        } else {
            ousia.printf("??????????  ?    ?       ?  {s}\n", .{e.nameSlice()});
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
