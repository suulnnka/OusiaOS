//! ps —— 进程列表（ZOS 扩展系统调用 500）

const zos = @import("lib/zos.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

const PsEntry = extern struct {
    pid: u32,
    ppid: u32,
    state: u32,
    _pad: u32,
    name: [16]u8,
};

const state_names = [_][]const u8{ "unused", "runnable", "running", "sleeping", "waiting", "zombie" };

export fn main() i32 {
    var entries: [32]PsEntry = undefined;
    const n = zos.syscall3(500, @intFromPtr(&entries), entries.len, 0);
    if (n <= 0) {
        zos.printf("ps: failed ({d})\n", .{n});
        return 1;
    }
    zos.printf("{d:>4}  {d:>4}  {s:<9} {s}\n", .{ "PID", "PPID", "STATE", "NAME" });
    for (entries[0..@intCast(n)]) |*e| {
        const st = if (e.state < state_names.len) state_names[e.state] else "?";
        var l: usize = 0;
        while (l < e.name.len and e.name[l] != 0) l += 1;
        zos.printf("{d:>4}  {d:>4}  {s:<9} {s}\n", .{ e.pid, e.ppid, st, e.name[0..l] });
    }
    return 0;
}
