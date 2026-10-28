//! rm —— 删除文件；空目录用 -d（目录走 rmdir 语义）
//!
//! 教学要点：unlink 只对普通文件有效——删目录要确认它是空的再 rmdir，
//! 这是 Unix 的防呆设计（防止误删整棵子树）

const ousia = @import("lib/ousia.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

export fn main() i32 {
    var dir_only = false;
    var target: ?[]const u8 = null;
    var i: usize = 1;
    while (i < ousia.argc()) : (i += 1) {
        const a = ousia.arg(i);
        if (ousia.eql(a, "-d")) {
            dir_only = true;
        } else if (a.len > 0 and a[0] != '-') {
            target = a;
        }
    }
    const path = target orelse {
        ousia.printf("usage: rm [-d] <path>   (-d 删空目录)\n", .{});
        return 1;
    };

    const r = if (dir_only) ousia.rmdir(path) else ousia.unlink(path);
    if (r != 0) {
        // 39 = ENOTEMPTY：目录非空（Unix 的防呆）
        if (r == -39) {
            ousia.printf("rm: {s}: directory not empty\n", .{path});
        } else {
            ousia.printf("rm: {s}: failed ({d})\n", .{ path, r });
        }
        return 1;
    }
    return 0;
}
