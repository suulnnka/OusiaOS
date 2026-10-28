//! ping —— ICMP 回显探测（经系统调用 501）

const ousia = @import("lib/ousia.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

export fn main() i32 {
    if (ousia.argc() < 2) {
        ousia.printf("usage: ping <ip> [count]\n", .{});
        return 1;
    }
    const host = ousia.arg(1);
    const count = if (ousia.argc() > 2) parseNum(ousia.arg(2)) else 4;
    const ip = ousia.parseIp(host) orelse {
        ousia.printf("ping: invalid ip: {s}\n", .{host});
        return 1;
    };

    ousia.printf("PING {s} ({d}.{d}.{d}.{d}) {d} packets:\n", .{
        host, (ip >> 24) & 0xFF, (ip >> 16) & 0xFF, (ip >> 8) & 0xFF, ip & 0xFF, count,
    });

    var sent: usize = 0;
    var recv: usize = 0;
    var total_ms: u64 = 0;
    while (sent < count) : (sent += 1) {
        const seq: u32 = @intCast(sent + 1);
        const rtt = ousia.netPing(ip, seq);
        if (rtt >= 0) {
            recv += 1;
            total_ms += @intCast(rtt);
            ousia.printf("64 bytes from {s}: seq={d} ttl=64 time={d}ms\n", .{ host, seq, rtt });
        } else {
            ousia.printf("request timeout for seq {d}\n", .{seq});
        }
        if (sent + 1 < count) ousia.sleepMs(700);
    }
    ousia.printf("--- {s} ping statistics ---\n", .{host});
    ousia.printf("{d} transmitted, {d} received, {d}% loss\n", .{
        sent, recv, if (recv == 0) @as(u64, 100) else (100 * (sent - recv)) / sent,
    });
    if (recv > 0) ousia.printf("rtt avg = {d}ms\n", .{total_ms / recv});
    return if (recv == 0) 1 else 0;
}

fn parseNum(s: []const u8) usize {
    var v: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        v = v * 10 + (c - '0');
    }
    return if (v == 0) 4 else v;
}
