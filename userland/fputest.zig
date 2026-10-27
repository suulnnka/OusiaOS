//! fputest —— FPU/SSE 上下文切换验证：浮点代码必须经得起
//!   - 时钟中断抢占（TrapFrame 的 XMM 保存）
//!   - 进程切换（swtchImpl 的 Context.fpu 保存）
//!
//! 方法：父子进程各自累计 5000 轮 f64 运算（每 500 轮 sleep 一次强制
//! 让出 CPU，期间对方进程在跑自己的 f64 循环）；结束后再【紧凑地】
//! 重算一遍同样序列，位级比对。IEEE 运算是确定性的——两次结果不同，
//! 说明 XMM 现场被切换践踏了。

const zos = @import("lib/zos.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

/// 第 i 轮的 64 步 f64 演算：纯 +−×÷（SSE2，无 libm 依赖）
fn step(i: usize, tag: f64) f64 {
    var x: f64 = @floatFromInt(i);
    var j: usize = 0;
    while (j < 64) : (j += 1) {
        x = x * tag + 0.5;
        x = x / 3.0;
    }
    return x;
}

export fn main() i32 {
    zos.printf("fputest: pid={d} forking...\n", .{zos.getpid()});

    const pid = zos.fork();
    if (pid < 0) {
        zos.printf("fputest: fork failed\n", .{});
        return 1;
    }

    // 父子用不同常数，防止调度器"运气好"也看不出串扰
    const tag: f64 = if (pid == 0) 1.0000001 else 0.9999999;

    // 第一遍：每 500 轮 sleep 一次（yield → swtch 走 → 被调度回来，
    // sleep 期间另一进程正在跑自己的 f64 循环——正是要考验的场景）
    var acc: f64 = 0;
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        if (i % 500 == 0) zos.sleepMs(10);
        acc += step(i, tag);
    }

    // 第二遍：同样序列紧凑重算（仍有时钟中断，但语义上应位级相同）
    var acc2: f64 = 0;
    i = 0;
    while (i < 5000) : (i += 1) acc2 += step(i, tag);

    const who: []const u8 = if (pid == 0) "child " else "parent";
    if (@as(u64, @bitCast(acc)) == @as(u64, @bitCast(acc2))) {
        zos.printf("fputest: [{s}] OK (acc bits {d})\n", .{who, @as(u64, @bitCast(acc))});
    } else {
        zos.printf("fputest: [{s}] MISMATCH {d} != {d}\n", .{ who, @as(u64, @bitCast(acc)), @as(u64, @bitCast(acc2)) });
    }

    if (pid == 0) zos.exit(0);
    var status: i32 = 0;
    _ = zos.waitpid(pid, &status);
    zos.printf("fputest: done\n", .{});
    return 0;
}
