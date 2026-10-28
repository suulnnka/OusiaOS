//! glview —— miniGL 三场景演示（用户态 GUI 应用）
//!
//! 展示 OusiaOS 的软件 OpenGL 子集在真实窗口系统里的样子：
//!   1. Checker Cube  —— 透视校正纹理映射（comptime 棋盘纹理）
//!   2. Gouraud Torus —— 逐顶点光照 + 平滑着色 + 背面剔除
//!   3. Wave Grid     —— 动态线框地形（GL_LINES + 深度测试）
//!
//! 渲染循环是纯用户态浮点代码：时钟中断随时打断（IRQ0 合成器也在用
//! SSE），全靠内核的 XMM 现场保存兜底——fputest 验证的正是这件事。
//!
//! 交互：点击画面 / 左右方向键切换场景；q 或关闭盒退出。

const std = @import("std");
const ousia = @import("lib/ousia.zig");
const win = @import("lib/win.zig");
const gl = @import("lib/gl.zig");

comptime {
    _ = @import("lib/crt0.zig");
}

const CW: i32 = 320;
const CH: i32 = 240;

// miniGL 上下文 + 深度缓冲：静态分配（用户态 ELF 的 .bss 由加载器清零）
var gctx: gl.Context = .{};
var depth_buf: [CW * CH]f32 = @splat(1.0);

// ---------------- 棋盘纹理（comptime 生成 64×64 RGBA） ----------------

const TEX: usize = 64;
const checker_tex = blk: {
    @setEvalBranchQuota(100000);
    var t: [TEX * TEX * 4]u8 = undefined;
    var y: usize = 0;
    while (y < TEX) : (y += 1) {
        var x: usize = 0;
        while (x < TEX) : (x += 1) {
            const cell = ((x / 8) + (y / 8)) & 1;
            const cell_border = (x % 8 == 0) or (y % 8 == 0);
            const i = (y * TEX + x) * 4;
            if (cell_border) {
                t[i] = 255;
                t[i + 1] = 255;
                t[i + 2] = 255;
            } else if (cell == 1) {
                t[i] = 255;
                t[i + 1] = 140;
                t[i + 2] = 30; // 橙
            } else {
                t[i] = 25;
                t[i + 1] = 45;
                t[i + 2] = 140; // 藏青
            }
            t[i + 3] = 255;
        }
    }
    break :blk t;
};

// ---------------- 场景 1：纹理立方体 ----------------

fn drawCube(t: f32) void {
    gl.disable(gl.GL_LIGHTING);
    gl.enable(gl.GL_TEXTURE_2D);
    gl.enable(gl.GL_CULL_FACE);
    gl.color3f(1, 1, 1);

    gl.pushMatrix();
    gl.rotatef(t * 40.0, 1.0, 0.6, 0.3);
    gl.rotatef(t * 17.0, 0.0, 1.0, 0.0);

    gl.begin(gl.GL_QUADS);
    // 每面 uv 走 0..2：REPEAT 寻址让棋盘重复 2×2
    quadFace(-1, -1, -1, 1, -1, -1, 1, 1, -1, -1, 1, -1); // 后 z=-1
    quadFace(1, -1, 1, -1, -1, 1, -1, 1, 1, 1, 1, 1); // 前 z=+1
    quadFace(-1, -1, 1, -1, -1, -1, -1, 1, -1, -1, 1, 1); // 左 x=-1
    quadFace(1, -1, -1, 1, -1, 1, 1, 1, 1, 1, 1, -1); // 右 x=+1
    quadFace(-1, 1, -1, 1, 1, -1, 1, 1, 1, -1, 1, 1); // 上 y=+1
    quadFace(-1, -1, 1, 1, -1, 1, 1, -1, -1, -1, -1, -1); // 下 y=-1
    gl.end();
    gl.popMatrix();
}

/// 一个面：4 顶点按外部看去的 CCW 顺序传入，自动配 uv
fn quadFace(x0: f32, y0: f32, z0: f32, x1: f32, y1: f32, z1: f32, x2: f32, y2: f32, z2: f32, x3: f32, y3: f32, z3: f32) void {
    gl.texCoord2f(0, 0);
    gl.vertex3f(x0, y0, z0);
    gl.texCoord2f(2, 0);
    gl.vertex3f(x1, y1, z1);
    gl.texCoord2f(2, 2);
    gl.vertex3f(x2, y2, z2);
    gl.texCoord2f(0, 2);
    gl.vertex3f(x3, y3, z3);
}

// ---------------- 场景 2：Gouraud 圆环 ----------------

const RING_R: usize = 22; // 环向分段
const TUBE_R: usize = 12; // 管向分段

/// 圆环面点：(θ 绕 y 轴, φ 绕管) —— y 向上
fn torusP(theta: f32, phi: f32, out: *gl.Vec3) void {
    const R: f32 = 1.45;
    const r: f32 = 0.55;
    const cp = gl.cosf(phi);
    out.* = .{
        .x = (R + r * cp) * gl.cosf(theta),
        .y = r * gl.sinf(phi),
        .z = (R + r * cp) * gl.sinf(theta),
    };
}

/// 解析法线（圆环的精确法向：从管心指向外）
fn torusN(theta: f32, phi: f32) gl.Vec3 {
    return .{
        .x = gl.cosf(phi) * gl.cosf(theta),
        .y = gl.sinf(phi),
        .z = gl.cosf(phi) * gl.sinf(theta),
    };
}

fn drawTorus(t: f32) void {
    gl.disable(gl.GL_TEXTURE_2D);
    gl.enable(gl.GL_LIGHTING);
    gl.enable(gl.GL_CULL_FACE);
    gl.shadeModel(gl.GL_SMOOTH);

    // 方向光在世界系固定（lightfv 按【当前】模型视矩阵变换——此刻
    // 还是单位阵；之后圆环自己转，光源不动，这就是 glLightfv 的时机语义）
    const lpos = [4]f32{ 0.35, 0.6, 1.0, 0 };
    gl.lightfv(gl.GL_LIGHT0, gl.GL_POSITION, &lpos);

    gl.pushMatrix();
    gl.rotatef(t * 50.0, 0.4, 1.0, 0.25);
    gl.rotatef(t * 13.0, 0.0, 0.0, 1.0);

    const d_theta: f32 = 2.0 * std.math.pi / @as(f32, RING_R);
    const d_phi: f32 = 2.0 * std.math.pi / @as(f32, TUBE_R);

    var p0: gl.Vec3 = undefined;
    var p1: gl.Vec3 = undefined;
    var p2: gl.Vec3 = undefined;
    var p3: gl.Vec3 = undefined;

    gl.begin(gl.GL_QUADS);
    var i: usize = 0;
    while (i < RING_R) : (i += 1) {
        const th0 = @as(f32, @floatFromInt(i)) * d_theta;
        const th1 = th0 + d_theta;
        var j: usize = 0;
        while (j < TUBE_R) : (j += 1) {
            const ph0 = @as(f32, @floatFromInt(j)) * d_phi;
            const ph1 = ph0 + d_phi;
            torusP(th0, ph0, &p0);
            torusP(th0, ph1, &p1);
            torusP(th1, ph1, &p2);
            torusP(th1, ph0, &p3);
            // 顶点色：沿环向的色相渐变（光照会再调制它）
            const hue = @as(f32, @floatFromInt(i)) / RING_R;
            gl.color3f(0.35 + 0.6 * hue, 0.9 - 0.5 * hue, 0.75 - 0.35 * hue);
            const n0 = torusN(th0, ph0);
            gl.normal3f(n0.x, n0.y, n0.z);
            gl.vertex3f(p0.x, p0.y, p0.z);
            const n1 = torusN(th0, ph1);
            gl.normal3f(n1.x, n1.y, n1.z);
            gl.vertex3f(p1.x, p1.y, p1.z);
            const n2 = torusN(th1, ph1);
            gl.normal3f(n2.x, n2.y, n2.z);
            gl.vertex3f(p2.x, p2.y, p2.z);
            const n3 = torusN(th1, ph0);
            gl.normal3f(n3.x, n3.y, n3.z);
            gl.vertex3f(p3.x, p3.y, p3.z);
        }
    }
    gl.end();
    gl.popMatrix();
}

// ---------------- 场景 3：线框波浪地形 ----------------

const GRID: usize = 24; // 24×24 网格，覆盖 [-2.4, 2.4]²

fn waveH(x: f32, z: f32, t: f32) f32 {
    return 0.35 * gl.sinf(x * 2.1 + t * 1.7) + 0.22 * gl.cosf(z * 1.8 - t * 1.1);
}

fn drawGrid(t: f32) void {
    gl.disable(gl.GL_TEXTURE_2D);
    gl.disable(gl.GL_LIGHTING);
    gl.disable(gl.GL_CULL_FACE);

    gl.pushMatrix();
    gl.rotatef(-62.0, 1.0, 0.0, 0.0); // 俯视倾角
    gl.translatef(0.0, 0.0, -1.1);

    const step: f32 = 4.8 / @as(f32, GRID);
    const x0w: f32 = -2.4;
    const z0w: f32 = -2.4;
    gl.begin(gl.GL_LINES);
    var gz: usize = 0;
    while (gz <= GRID) : (gz += 1) {
        const z = z0w + @as(f32, @floatFromInt(gz)) * step;
        var gx: usize = 0;
        while (gx < GRID) : (gx += 1) {
            const xa = x0w + @as(f32, @floatFromInt(gx)) * step;
            const xb = xa + step;
            heightColor(waveH(xa, z, t));
            gl.vertex3f(xa, waveH(xa, z, t), z);
            gl.vertex3f(xb, waveH(xb, z, t), z);
        }
    }
    var gx: usize = 0;
    while (gx <= GRID) : (gx += 1) {
        const x = x0w + @as(f32, @floatFromInt(gx)) * step;
        var gz2: usize = 0;
        while (gz2 < GRID) : (gz2 += 1) {
            const za = z0w + @as(f32, @floatFromInt(gz2)) * step;
            const zb = za + step;
            heightColor(waveH(x, za, t));
            gl.vertex3f(x, waveH(x, za, t), za);
            gl.vertex3f(x, waveH(x, zb, t), zb);
        }
    }
    gl.end();
    gl.popMatrix();
}

/// 高度 → 颜色：低谷深蓝，峰顶亮青
fn heightColor(h: f32) void {
    const s = @min(1.0, @max(0.0, (h + 0.6) / 1.2));
    gl.color3f(0.1 + 0.2 * s, 0.3 + 0.5 * s, 0.5 + 0.5 * s);
}

// ---------------- 渲染循环 ----------------

const demo_names = [_][]const u8{ "Checker Cube", "Gouraud Torus", "Wave Grid" };
var demo: u32 = 0;
var sim_t: f32 = 0;
var fps: u32 = 0;
var fps_frames: u32 = 0;
var fps_sec: i64 = -1;

fn nextDemo() void {
    demo = (demo + 1) % @as(u32, demo_names.len);
    sim_t = 0; // 场景从头播
}

fn render() void {
    // 相机：所有场景共用
    gl.matrixMode(gl.GL_PROJECTION);
    gl.loadIdentity();
    gl.perspective(58.0, @as(f32, CW) / CH, 0.4, 30.0);
    gl.matrixMode(gl.GL_MODELVIEW);
    gl.loadIdentity();
    gl.translatef(0.0, 0.0, -5.0);
    gl.enable(gl.GL_DEPTH_TEST);

    gl.clearColor(0.07, 0.09, 0.16, 1.0);
    gl.clear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);

    switch (demo) {
        0 => drawCube(sim_t),
        1 => drawTorus(sim_t),
        else => drawGrid(sim_t),
    }

    // 叠加信息条（直接写共享表面，不过 GL 管线）
    var buf: [64]u8 = undefined;
    const line1 = fmtLine(&buf, demo_names[demo]);
    win.fillRect(4, CH - 34, win.sw - 8, 30, win.color(0, 0, 0));
    win.text(8, CH - 32, line1, win.C_WHITE);
    win.text(8, CH - 16, "click / arrows: scene   q: quit", win.C_SHADOW);
}

/// "名字  fps=N" 拼进 buf（无 snprintf：手写十进制）
fn fmtLine(buf: []u8, name: []const u8) []const u8 {
    var n: usize = 0;
    for (name) |c| {
        buf[n] = c;
        n += 1;
    }
    const tail = "  fps=";
    for (tail) |c| {
        buf[n] = c;
        n += 1;
    }
    var digits: [10]u8 = undefined;
    var v = fps;
    var dn: usize = 0;
    if (v == 0) {
        digits[0] = '0';
        dn = 1;
    }
    while (v > 0) {
        digits[dn] = '0' + @as(u8, @intCast(v % 10));
        dn += 1;
        v /= 10;
    }
    while (dn > 0) {
        dn -= 1;
        buf[n] = digits[dn];
        n += 1;
    }
    return buf[0..n];
}

fn fpsTick() void {
    fps_frames += 1;
    const s: i64 = @bitCast(ousia.syscall0(201));
    if (s != fps_sec) {
        if (fps_sec >= 0) fps = fps_frames;
        fps_frames = 0;
        fps_sec = s;
    }
}

export fn main() i32 {
    if (!win.create(CW, CH, "GL Demos - miniGL")) {
        ousia.printf("glview: win_create failed (GUI on?)\n", .{});
        return 1;
    }
    win.initColors();

    gl.makeCurrent(&gctx);
    const f = win.fmt();
    gl.beginFrame(win.surface(), &depth_buf, CW, CH, f.rsh, f.gsh, f.bsh);

    // 棋盘纹理 → 槽 1
    var name: u32 = 0;
    gl.genTextures(1, @ptrCast(&name));
    gl.bindTexture(gl.GL_TEXTURE_2D, name);
    gl.texImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, TEX, TEX, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, &checker_tex);

    ousia.printf("glview: miniGL demos up (glerr={d})\n", .{@as(u32, gl.getError())});

    while (true) {
        var evs: [8]win.Event = undefined;
        const n = win.wait(&evs, 40); // 40ms 超时 ≈ 25fps 的渲染节拍
        for (evs[0..n]) |ev| {
            switch (ev.kind) {
                win.EV_CLOSE => return 0,
                win.EV_PRESS => nextDemo(),
                win.EV_KEY => {
                    if (ev.code == 'q') return 0;
                    if (ev.code == win.KEY_LEFT or ev.code == win.KEY_RIGHT) nextDemo();
                },
                else => {},
            }
        }
        sim_t += 0.05;
        render();
        win.present();
        fpsTick();
    }
}
