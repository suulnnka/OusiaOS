//! hello —— 第一个 OusiaOS 用户程序
//! 编译为静态 ELF，放进 initrd 的 /bin/hello，由内核 execve 加载

const ousia = @import("lib/ousia.zig");

comptime {
    _ = @import("lib/crt0.zig"); // 拉入 _start
}

export fn main() i32 {
    ousia.printf("Hello from OusiaOS userspace!\n", .{});
    ousia.printf("  pid = {d}, argc = {d}\n", .{ ousia.getpid(), ousia.argc() });
    for (0..ousia.argc()) |i| {
        ousia.printf("  argv[{d}] = {s}\n", .{ i, ousia.arg(i) });
    }
    ousia.printf("back to kernel in 1 second...\n", .{});
    ousia.sleepMs(1000);
    ousia.printf("bye!\n", .{});
    return 42;
}
