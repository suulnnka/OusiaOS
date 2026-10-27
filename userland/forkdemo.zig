//! forkdemo —— fork/wait 演示：父子进程并发执行

const zos = @import("lib/zos.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

export fn main() i32 {
    zos.printf("forkdemo: parent pid={d}, forking...\n", .{zos.getpid()});

    const pid = zos.fork();
    if (pid < 0) {
        zos.printf("forkdemo: fork failed\n", .{});
        return 1;
    }
    if (pid == 0) {
        // 子进程：独立地址空间，打印 3 次后退出
        for (1..4) |i| {
            zos.printf("  [child ] pid={d} round {d}\n", .{ zos.getpid(), i });
            zos.sleepMs(200);
        }
        zos.printf("  [child ] exiting with code 7\n", .{});
        zos.exit(7);
    }
    // 父进程同时打印
    for (1..4) |i| {
        zos.printf("[parent] pid={d} round {d} (child={d})\n", .{ zos.getpid(), i, pid });
        zos.sleepMs(200);
    }
    var status: i32 = 0;
    const w = zos.waitpid(pid, &status);
    zos.printf("[parent] child {d} exited with {d} (wait={d})\n", .{ pid, status, w });
    return 0;
}
