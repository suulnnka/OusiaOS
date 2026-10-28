//! forkdemo —— fork/wait 演示：父子进程并发执行

const ousia = @import("lib/ousia.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

export fn main() i32 {
    ousia.printf("forkdemo: parent pid={d}, forking...\n", .{ousia.getpid()});

    const pid = ousia.fork();
    if (pid < 0) {
        ousia.printf("forkdemo: fork failed\n", .{});
        return 1;
    }
    if (pid == 0) {
        // 子进程：独立地址空间，打印 3 次后退出
        for (1..4) |i| {
            ousia.printf("  [child ] pid={d} round {d}\n", .{ ousia.getpid(), i });
            ousia.sleepMs(200);
        }
        ousia.printf("  [child ] exiting with code 7\n", .{});
        ousia.exit(7);
    }
    // 父进程同时打印
    for (1..4) |i| {
        ousia.printf("[parent] pid={d} round {d} (child={d})\n", .{ ousia.getpid(), i, pid });
        ousia.sleepMs(200);
    }
    var status: i32 = 0;
    const w = ousia.waitpid(pid, &status);
    ousia.printf("[parent] child {d} exited with {d} (wait={d})\n", .{ pid, status, w });
    return 0;
}
