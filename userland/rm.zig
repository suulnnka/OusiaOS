//! rm —— 删除文件；空目录用 -d（目录走 rmdir 语义）
//!
//! 教学要点：unlink 只对普通文件有效——删目录要确认它是空的再 rmdir，
//! 这是 Unix 的防呆设计（防止误删整棵子树）

const zos = @import("lib/zos.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

export fn main() i32 {
    var dir_only = false;
    var target: ?[]const u8 = null;
    var i: usize = 1;
    while (i < zos.argc()) : (i += 1) {
        const a = zos.arg(i);
        if (zos.eql(a, "-d")) {
            dir_only = true;
        } else if (a.len > 0 and a[0] != '-') {
            target = a;
        }
    }
    const path = target orelse {
        zos.printf("usage: rm [-d] <path>   (-d 删空目录)\n", .{});
        return 1;
    };

    const r = if (dir_only) zos.rmdir(path) else zos.unlink(path);
    if (r != 0) {
        // 39 = ENOTEMPTY：目录非空（Unix 的防呆）
        if (r == -39) {
            zos.printf("rm: {s}: directory not empty\n", .{path});
        } else {
            zos.printf("rm: {s}: failed ({d})\n", .{ path, r });
        }
        return 1;
    }
    return 0;
}
