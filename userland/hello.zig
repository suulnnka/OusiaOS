//! hello —— 第一个 ZOS 用户程序
//! 编译为静态 ELF，放进 initrd 的 /bin/hello，由内核 execve 加载

const zos = @import("lib/zos.zig");

comptime {
    _ = @import("lib/crt0.zig"); // 拉入 _start
}

export fn main() i32 {
    zos.printf("Hello from ZOS userspace!\n", .{});
    zos.printf("  pid = {d}, argc = {d}\n", .{ zos.getpid(), zos.argc() });
    for (0..zos.argc()) |i| {
        zos.printf("  argv[{d}] = {s}\n", .{ i, zos.arg(i) });
    }
    zos.printf("back to kernel in 1 second...\n", .{});
    zos.sleepMs(1000);
    zos.printf("bye!\n", .{});
    return 42;
}
