//! miniGL —— OusiaOS 自研的 OpenGL 1.x 风格软件光栅化器
//!
//! 设计约束（教学定位）：
//!   - 纯 Zig、零内核依赖、零第三方依赖：它是 libousia 的一部分，被
//!     用户态 GUI 应用（userland/glview.zig、glcube.c）直接使用；
//!     因为不碰任何内核设施，还能在 host 上跑单元测试（zig build test）。
//!   - freestanding 环境：没有 libm，sin/cos 自己实现；没有堆，
//!     一切缓冲都是固定大小静态数组。
//!   - 渲染目标由调用方传入（beginFrame）：通常就是 winsys 的共享
//!     表面（win_create 返回的内存）。miniGL 不知道屏幕的存在——只往
//!     u32 数组里写像素，上屏靠 win_present 记脏区 + IRQ0 合成器搬运。
//!
//! 实现的 API 子集（OpenGL 1.x 立即模式 + 固定功能管线）：
//!   glBegin/glEnd（TRIANGLES/QUADS/LINES/POINTS）
//!   glVertex2f/3f  glColor3f/4f  glNormal3f  glTexCoord2f
//!   矩阵栈：MODELVIEW/PROJECTION 各 16 层
//!     glMatrixMode/LoadIdentity/LoadMatrixf/MultMatrixf/Push/Pop/
//!     Translatef/Rotatef/Scalef/Ortho/Frustum + perspective/lookAt
//!   glViewport/glClear/glClearColor/glClearDepth
//!   glEnable/glDisable（DEPTH_TEST/LIGHTING/CULL_FACE/TEXTURE_2D）
//!   glDepthFunc(GL_LESS/LEQUAL/ALWAYS/NEVER/EQUAL/GREATER)/glDepthMask
//!   glShadeModel(FLAT/SMOOTH)、glCullFace/glFrontFace
//!   glLightfv(GL_LIGHT0, GL_POSITION/GL_DIFFUSE)（单方向光 Lambert）
//!   纹理：glGenTextures/BindTexture/TexImage2D/TexParameteri
//!     （RGBA8、nearest 采样、REPEAT/CLAMP_TO_EDGE、MODULATE）
//!   glGetError
//!
//! 与桌面 OpenGL 的刻意差异（详见 docs/gl.md）：
//!   - 视口原点在【左上角、y 向下】——与帧缓冲内存行序一致，画布可
//!     直接 blit 上屏；NDC 仍是标准数学约定（+y 向上），所以世界
//!     坐标里的"上"在屏幕上也是"上"。
//!   - 背面剔除按 NDC x-y 平面的数学绕向判定（CCW=正面），与视口
//!     的 y 翻转无关。
//!   - 法线只用模型视矩阵线性部分的转置后归一化（未做完整逆矩阵）：
//!     非均匀缩放/剪切下的法线不严格正确，演示场景不受影响。
//!
//! 调用约定：一次 makeCurrent 后任意调用；用户态程序单线程使用即可。
//! 用户进程的浮点渲染依赖内核的 FPU 上下文切换（TrapFrame 的 XMM
//! 保存 + swtchImpl 的 Context.fpu）——时钟中断会打断渲染循环，而
//! IRQ0 里跑的合成器也在用 SSE，双方现场互不践踏。

const std = @import("std");

// ================= GL 常量（取真实值，方便对照手册） =================

pub const GLenum = u32;
pub const GLbitfield = u32;
pub const GLboolean = bool;

pub const GL_NO_ERROR: GLenum = 0;
pub const GL_INVALID_ENUM: GLenum = 0x0500;
pub const GL_INVALID_VALUE: GLenum = 0x0501;
pub const GL_INVALID_OPERATION: GLenum = 0x0502;
pub const GL_STACK_OVERFLOW: GLenum = 0x0503;
pub const GL_OUT_OF_MEMORY: GLenum = 0x0505;

// 图元
pub const GL_POINTS: GLenum = 0x0000;
pub const GL_LINES: GLenum = 0x0001;
pub const GL_TRIANGLES: GLenum = 0x0004;
pub const GL_QUADS: GLenum = 0x0007;

// 矩阵
pub const GL_MODELVIEW: GLenum = 0x1700;
pub const GL_PROJECTION: GLenum = 0x1701;

// clear 位
pub const GL_DEPTH_BUFFER_BIT: GLbitfield = 0x00000100;
pub const GL_COLOR_BUFFER_BIT: GLbitfield = 0x00004000;

// enable/disable 开关
pub const GL_CULL_FACE: GLenum = 0x0B44;
pub const GL_LIGHTING: GLenum = 0x0B50;
pub const GL_DEPTH_TEST: GLenum = 0x0B71;
pub const GL_TEXTURE_2D: GLenum = 0x0DE1;
pub const GL_LIGHT0: GLenum = 0x4000;

// 深度比较函数
pub const GL_NEVER: GLenum = 0x0200;
pub const GL_LESS: GLenum = 0x0201;
pub const GL_EQUAL: GLenum = 0x0202;
pub const GL_LEQUAL: GLenum = 0x0203;
pub const GL_GREATER: GLenum = 0x0204;
pub const GL_ALWAYS: GLenum = 0x0207;

// 着色/剔除
pub const GL_FLAT: GLenum = 0x1D00;
pub const GL_SMOOTH: GLenum = 0x1D01;
pub const GL_FRONT: GLenum = 0x0404;
pub const GL_BACK: GLenum = 0x0405;
pub const GL_CCW: GLenum = 0x0901;
pub const GL_CW: GLenum = 0x0900;

// 光照参数
pub const GL_POSITION: GLenum = 0x1203;
pub const GL_DIFFUSE: GLenum = 0x1201;

// 纹理参数
pub const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
pub const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
pub const GL_TEXTURE_WRAP_S: GLenum = 0x2802;
pub const GL_TEXTURE_WRAP_T: GLenum = 0x2803;
pub const GL_NEAREST: GLenum = 0x2600;
pub const GL_REPEAT: GLenum = 0x2901;
pub const GL_CLAMP_TO_EDGE: GLenum = 0x812F;
pub const GL_RGBA: GLenum = 0x1908;
pub const GL_RGB: GLenum = 0x1907;
pub const GL_UNSIGNED_BYTE: GLenum = 0x1401;

// ================= mini 数学库 =================

/// 三角函数：范围归约（Cody-Waite 双常数分解 π/2）+ 多项式。
/// freestanding 下运行时 @sin 会链接失败（llvm.sin → libm），所以
/// 自己实现；系数取 musl 的 float 版本，|误差| < 1e-6。
const PIO2_HI: f32 = 1.57079625129699707031; // π/2 的高位（f32 可精确表示）
const PIO2_LO: f32 = 7.54978941586159635335e-08; // + 低位（补齐差值）
const INV_PIO2: f32 = 6.36619772367581382433e-01; // 2/π

pub fn sinf(x: f32) f32 {
    const k: i32 = f2i(roundf(x * INV_PIO2));
    const kf: f32 = @floatFromInt(k);
    const r = x - kf * PIO2_HI - kf * PIO2_LO;
    return switch (@mod(k, 4)) {
        0 => sinPoly(r),
        1 => cosPoly(r), // sin(π/2 + r) = cos(r)
        2 => -sinPoly(r),
        else => -cosPoly(r),
    };
}

pub fn cosf(x: f32) f32 {
    const k: i32 = f2i(roundf(x * INV_PIO2));
    const kf: f32 = @floatFromInt(k);
    const r = x - kf * PIO2_HI - kf * PIO2_LO;
    return switch (@mod(k, 4)) {
        0 => cosPoly(r),
        1 => -sinPoly(r),
        2 => -cosPoly(r),
        else => sinPoly(r),
    };
}

/// sin(r) ≈ r + r³·(S1 + z·(S2 + z·(S3 + z·S4)))，z = r²，|r| ≤ π/4
fn sinPoly(r: f32) f32 {
    const z = r * r;
    return r + r * z * (-1.6666667163e-01 + z * (8.3333337680e-03 + z * (-1.9841270114e-04 + z * 2.7557314297e-07)));
}

/// cos(r) ≈ 1 + z·(-1/2 + z·(C1 + z·(C2 + z·C3)))，z = r²
fn cosPoly(r: f32) f32 {
    const z = r * r;
    return 1.0 + z * (-0.5 + z * (4.1666518680e-02 + z * (-1.3877697670e-03 + z * 2.4433157118e-05)));
}

pub fn tanf(x: f32) f32 {
    return sinf(x) / cosf(x);
}

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Vec3 = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.y * b.z - a.z * b.y, .y = a.z * b.x - a.x * b.z, .z = a.x * b.y - a.y * b.x };
    }

    pub fn normalized(a: Vec3) Vec3 {
        const len = @sqrt(dot(a, a));
        if (len < 1e-12) return .{};
        return .{ .x = a.x / len, .y = a.y / len, .z = a.z / len };
    }
};

pub const Vec4 = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 1,
};

/// 4×4 矩阵，列主序（OpenGL 约定）：m[col*4 + row]
pub const Mat4 = struct {
    m: [16]f32 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },

    pub fn identity() Mat4 {
        return .{};
    }

    /// 矩阵乘法 a·b（OpenGL 语义：v' = a·(b·v)，先应用 b）
    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var r: Mat4 = undefined;
        var col: usize = 0;
        while (col < 4) : (col += 1) {
            var row: usize = 0;
            while (row < 4) : (row += 1) {
                var s: f32 = 0;
                var k: usize = 0;
                while (k < 4) : (k += 1) s += a.m[k * 4 + row] * b.m[col * 4 + k];
                r.m[col * 4 + row] = s;
            }
        }
        return r;
    }

    pub fn transformPoint(self: Mat4, v: Vec4) Vec4 {
        return .{
            .x = self.m[0] * v.x + self.m[4] * v.y + self.m[8] * v.z + self.m[12] * v.w,
            .y = self.m[1] * v.x + self.m[5] * v.y + self.m[9] * v.z + self.m[13] * v.w,
            .z = self.m[2] * v.x + self.m[6] * v.y + self.m[10] * v.z + self.m[14] * v.w,
            .w = self.m[3] * v.x + self.m[7] * v.y + self.m[11] * v.z + self.m[15] * v.w,
        };
    }
};

// ================= 上下文 =================

pub const MAX_VERTS = 8192; // 一次 glBegin 的顶点上限（一帧全部图元）
pub const MAX_STACK = 16; // 矩阵栈深度（OpenGL 规范的最低要求）
pub const MAX_TEXTURES = 4;
pub const MAX_TEX_W = 256;
pub const MAX_TEX_H = 256;

pub const Vertex = struct {
    pos: Vec3 = .{},
    col: [4]f32 = .{ 1, 1, 1, 1 },
    norm: Vec3 = .{ .x = 0, .y = 0, .z = 1 },
    uv: Vec2 = .{},
};

const Texture = struct {
    valid: bool = false,
    w: u32 = 0,
    h: u32 = 0,
    wrap_s: GLenum = GL_REPEAT,
    wrap_t: GLenum = GL_REPEAT,
    /// 纹理像素打包为 0xRRGGBBAA（与目标画布格式无关，采样时拆开）
    pix: [MAX_TEX_W * MAX_TEX_H]u32 = @splat(0),
};

const MatrixMode = enum { modelview, projection };
const ShadeModel = enum { flat, smooth };
const DepthFunc = enum { never, less, equal, lequal, greater, always };

/// miniGL 上下文：一切状态的归宿。内核 demo 与每个用户进程各持一份。
/// 注意体积：纹理槽 ~1MB， verts ~1.5MB——放 .bss，别放内核栈。
pub const Context = struct {
    // ---- 帧目标（beginFrame 绑定）----
    target: []u32 = &.{},
    depth: []f32 = &.{},
    fb_w: i32 = 0,
    fb_h: i32 = 0,
    rsh: u5 = 16, // 目标像素格式的通道移位（QEMU VBE 为 BGR：r16 g8 b0）
    gsh: u5 = 8,
    bsh: u5 = 0,

    // ---- 视口 ----
    vp_x: i32 = 0,
    vp_y: i32 = 0, // 左上角原点，y 向下（见文件头说明）
    vp_w: i32 = 0,
    vp_h: i32 = 0,

    // ---- clear ----
    clear_col: [4]u8 = .{ 0, 0, 0, 255 },
    clear_depth: f32 = 1.0,

    // ---- 使能位与状态 ----
    depth_test: bool = false,
    depth_mask: bool = true,
    depth_func: DepthFunc = .less,
    lighting: bool = false,
    cull_face_en: bool = false,
    cull_what: GLenum = GL_BACK,
    front_ccw: bool = true, // glFrontFace(GL_CCW)
    tex_enabled: bool = false,
    shade: ShadeModel = .smooth,

    // ---- 光照（单方向光，eye space）----
    to_light: Vec3 = .{ .x = 0, .y = 0, .z = 1 }, // 指向光源的正规化方向
    light_col: Vec3 = .{ .x = 1, .y = 1, .z = 1 },
    ambient: f32 = 0.2,

    // ---- 矩阵 ----
    mat_mode: MatrixMode = .modelview,
    mv_stack: [MAX_STACK]Mat4 = @splat(Mat4.identity()),
    mv_top: u32 = 0,
    pr_stack: [MAX_STACK]Mat4 = @splat(Mat4.identity()),
    pr_top: u32 = 0,

    // ---- 纹理 ----
    tex: [MAX_TEXTURES]Texture = @splat(.{}),
    bound_tex: u32 = 0, // 纹理名（1..MAX_TEXTURES），0 = 未绑定

    // ---- 立即模式 ----
    imm_mode: GLenum = 0, // 0 = 不在 glBegin/glEnd 里
    imm_count: u32 = 0,
    verts: [MAX_VERTS]Vertex = @splat(.{}),
    cur_col: [4]f32 = .{ 1, 1, 1, 1 },
    cur_norm: Vec3 = .{ .x = 0, .y = 0, .z = 1 },
    cur_uv: Vec2 = .{},

    // ---- 粘滞错误码（glGetError 读后清零）----
    err: GLenum = GL_NO_ERROR,
};

/// 当前上下文。makeCurrent 之前调用任何绘制函数是编程错误（断言）。
var current: ?*Context = null;

fn ctx() *Context {
    return current orelse unreachable;
}

fn setErr(e: GLenum) void {
    if (ctx().err == GL_NO_ERROR) ctx().err = e;
}

pub fn makeCurrent(c: *Context) void {
    current = c;
}

/// 绑定渲染目标：color/depth 数组长度必须 ≥ w*h。
/// rsh/gsh/bsh 是目标像素格式的通道移位——miniGL 直接按硬件帧缓冲
/// 格式打包像素，上屏路径零转换。内核侧传 gui 的移位，用户态从
/// owin_open 系统调用的返回值里拿。
pub fn beginFrame(color: []u32, depth: []f32, w: i32, h: i32, rsh: u5, gsh: u5, bsh: u5) void {
    const c = ctx();
    std.debug.assert(w > 0 and h > 0);
    std.debug.assert(color.len >= @as(usize, @intCast(w)) * @as(usize, @intCast(h)));
    std.debug.assert(depth.len >= @as(usize, @intCast(w)) * @as(usize, @intCast(h)));
    c.target = color;
    c.depth = depth;
    c.fb_w = w;
    c.fb_h = h;
    c.rsh = rsh;
    c.gsh = gsh;
    c.bsh = bsh;
    if (c.vp_w == 0 or c.vp_h == 0) viewport(0, 0, w, h); // 首次默认全画布
}

pub fn getError() GLenum {
    const c = ctx();
    const e = c.err;
    c.err = GL_NO_ERROR;
    return e;
}

// ================= 帧与状态 =================

pub fn clearColor(r: f32, g: f32, b: f32, a: f32) void {
    const c = ctx();
    c.clear_col = .{ toByte(r), toByte(g), toByte(b), toByte(a) };
}

pub fn clearDepth(d: f32) void {
    ctx().clear_depth = d;
}

pub fn clear(mask: GLbitfield) void {
    const c = ctx();
    if (mask & GL_COLOR_BUFFER_BIT != 0) {
        const px = (@as(u32, c.clear_col[0]) << c.rsh) |
            (@as(u32, c.clear_col[1]) << c.gsh) |
            (@as(u32, c.clear_col[2]) << c.bsh);
        @memset(c.target, px);
    }
    if (mask & GL_DEPTH_BUFFER_BIT != 0) {
        @memset(c.depth, c.clear_depth);
    }
}

pub fn enable(cap: GLenum) void {
    setCap(cap, true);
}

pub fn disable(cap: GLenum) void {
    setCap(cap, false);
}

fn setCap(cap: GLenum, on: bool) void {
    const c = ctx();
    switch (cap) {
        GL_DEPTH_TEST => c.depth_test = on,
        GL_LIGHTING => c.lighting = on,
        GL_CULL_FACE => c.cull_face_en = on,
        GL_TEXTURE_2D => c.tex_enabled = on,
        else => setErr(GL_INVALID_ENUM),
    }
}

pub fn depthFunc(func_: GLenum) void {
    const c = ctx();
    c.depth_func = switch (func_) {
        GL_NEVER => .never,
        GL_LESS => .less,
        GL_EQUAL => .equal,
        GL_LEQUAL => .lequal,
        GL_GREATER => .greater,
        GL_ALWAYS => .always,
        else => return setErr(GL_INVALID_ENUM),
    };
}

pub fn depthMask(w: GLboolean) void {
    ctx().depth_mask = w;
}

pub fn shadeModel(m: GLenum) void {
    const c = ctx();
    c.shade = switch (m) {
        GL_FLAT => .flat,
        GL_SMOOTH => .smooth,
        else => return setErr(GL_INVALID_ENUM),
    };
}

pub fn cullFace(m: GLenum) void {
    switch (m) {
        GL_FRONT, GL_BACK => ctx().cull_what = m,
        else => setErr(GL_INVALID_ENUM),
    }
}

pub fn frontFace(m: GLenum) void {
    switch (m) {
        GL_CCW => ctx().front_ccw = true,
        GL_CW => ctx().front_ccw = false,
        else => setErr(GL_INVALID_ENUM),
    }
}

/// 视口：原点左上角、y 向下（见文件头）。NDC 的"上"（+y）仍然显示
/// 在屏幕上方——y 分量做了镜像变换。
pub fn viewport(x: i32, y: i32, w: i32, h: i32) void {
    const c = ctx();
    if (w <= 0 or h <= 0) return setErr(GL_INVALID_VALUE);
    c.vp_x = x;
    c.vp_y = y;
    c.vp_w = w;
    c.vp_h = h;
}

// ================= 矩阵 =================

fn curMatPtr(c: *Context) *Mat4 {
    return switch (c.mat_mode) {
        .modelview => &c.mv_stack[c.mv_top],
        .projection => &c.pr_stack[c.pr_top],
    };
}

fn matStack(c: *Context) struct { stack: *[MAX_STACK]Mat4, top: *u32 } {
    return switch (c.mat_mode) {
        .modelview => .{ .stack = &c.mv_stack, .top = &c.mv_top },
        .projection => .{ .stack = &c.pr_stack, .top = &c.pr_top },
    };
}

pub fn matrixMode(m: GLenum) void {
    const c = ctx();
    c.mat_mode = switch (m) {
        GL_MODELVIEW => .modelview,
        GL_PROJECTION => .projection,
        else => return setErr(GL_INVALID_ENUM),
    };
}

pub fn loadIdentity() void {
    curMatPtr(ctx()).* = Mat4.identity();
}

pub fn loadMatrixf(m: *const [16]f32) void {
    curMatPtr(ctx()).m = m.*;
}

pub fn multMatrixf(m: *const [16]f32) void {
    var rhs: Mat4 = undefined;
    rhs.m = m.*;
    const p = curMatPtr(ctx());
    p.* = p.mul(rhs);
}

pub fn pushMatrix() void {
    const c = ctx();
    const s = matStack(c);
    if (s.top.* + 1 >= MAX_STACK) return setErr(GL_STACK_OVERFLOW);
    s.stack[s.top.* + 1] = s.stack[s.top.*];
    s.top.* += 1;
}

pub fn popMatrix() void {
    const c = ctx();
    const s = matStack(c);
    if (s.top.* == 0) return setErr(GL_STACK_OVERFLOW);
    s.top.* -= 1;
}

pub fn translatef(x: f32, y: f32, z: f32) void {
    var t = Mat4.identity();
    t.m[12] = x;
    t.m[13] = y;
    t.m[14] = z;
    const p = curMatPtr(ctx());
    p.* = p.mul(t);
}

pub fn scalef(x: f32, y: f32, z: f32) void {
    var s = Mat4.identity();
    s.m[0] = x;
    s.m[5] = y;
    s.m[10] = z;
    const p = curMatPtr(ctx());
    p.* = p.mul(s);
}

/// 绕任意轴旋转 angle 度（Rodrigues 公式）
pub fn rotatef(deg: f32, ax: f32, ay: f32, az: f32) void {
    const axis = (Vec3{ .x = ax, .y = ay, .z = az }).normalized();
    const rad = deg * std.math.pi / 180.0;
    const co = cosf(rad);
    const si = sinf(rad);
    const t = 1.0 - co;
    const x = axis.x;
    const y = axis.y;
    const z = axis.z;
    var r = Mat4.identity();
    // 行主序写出，按列主序存放：m[col*4+row] = R[row][col]
    r.m[0] = t * x * x + co;
    r.m[1] = t * x * y + si * z;
    r.m[2] = t * x * z - si * y;
    r.m[4] = t * x * y - si * z;
    r.m[5] = t * y * y + co;
    r.m[6] = t * y * z + si * x;
    r.m[8] = t * x * z + si * y;
    r.m[9] = t * y * z - si * x;
    r.m[10] = t * z * z + co;
    const p = curMatPtr(ctx());
    p.* = p.mul(r);
}

pub fn frustum(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) void {
    const A = 2.0 * near / (right - left);
    const B = 2.0 * near / (top - bottom);
    const C = (right + left) / (right - left);
    const D = (top + bottom) / (top - bottom);
    const E = -(far + near) / (far - near);
    const F = -2.0 * far * near / (far - near);
    var f = Mat4.identity();
    f.m[0] = A;
    f.m[5] = B;
    f.m[8] = C;
    f.m[9] = D;
    f.m[10] = E;
    f.m[11] = -1.0;
    f.m[14] = F;
    f.m[15] = 0.0;
    const p = curMatPtr(ctx());
    p.* = p.mul(f);
}

pub fn ortho(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) void {
    var o = Mat4.identity();
    o.m[0] = 2.0 / (right - left);
    o.m[5] = 2.0 / (top - bottom);
    o.m[10] = -2.0 / (far - near);
    o.m[12] = -(right + left) / (right - left);
    o.m[13] = -(top + bottom) / (top - bottom);
    o.m[14] = -(far + near) / (far - near);
    const p = curMatPtr(ctx());
    p.* = p.mul(o);
}

/// glu 风格：透视投影（fovy 单位度）
pub fn perspective(fovy_deg: f32, aspect: f32, near: f32, far: f32) void {
    const fh = tanf(fovy_deg * std.math.pi / 360.0);
    frustum(-fh * aspect * near, fh * aspect * near, -fh * near, fh * near, near, far);
}

/// glu 风格：相机矩阵（eye 看 center，up 为"上"方向）
pub fn lookAt(eye: Vec3, center: Vec3, up: Vec3) void {
    const f = (Vec3{ .x = center.x - eye.x, .y = center.y - eye.y, .z = center.z - eye.z }).normalized();
    const s = f.cross(up).normalized();
    const u = s.cross(f);
    var m = Mat4.identity();
    m.m[0] = s.x;
    m.m[4] = s.y;
    m.m[8] = s.z;
    m.m[1] = u.x;
    m.m[5] = u.y;
    m.m[9] = u.z;
    m.m[2] = -f.x;
    m.m[6] = -f.y;
    m.m[10] = -f.z;
    m.m[12] = -s.dot(eye);
    m.m[13] = -u.dot(eye);
    m.m[14] = f.dot(eye);
    const p = curMatPtr(ctx());
    p.* = p.mul(m);
}

// ================= 光照 =================

/// 单方向光（miniGL 只实现 GL_LIGHT0）。语义与 OpenGL 相同：
/// GL_POSITION 在调用时刻按【当前模型视矩阵】变换；w=0 即方向光。
pub fn lightfv(light: GLenum, pname: GLenum, params: [*]const f32) void {
    const c = ctx();
    if (light != GL_LIGHT0) return setErr(GL_INVALID_ENUM);
    switch (pname) {
        GL_POSITION => {
            const d = c.mv_stack[c.mv_top].transformPoint(.{ .x = params[0], .y = params[1], .z = params[2], .w = 0 });
            c.to_light = (Vec3{ .x = d.x, .y = d.y, .z = d.z }).normalized();
        },
        GL_DIFFUSE => {
            c.light_col = .{ .x = params[0], .y = params[1], .z = params[2] };
        },
        else => setErr(GL_INVALID_ENUM),
    }
}

/// 全局环境光系数（简化版 glLightModelfv）
pub fn ambientLight(a: f32) void {
    ctx().ambient = a;
}

// ================= 纹理 =================

pub fn genTextures(n: i32, names: [*]u32) void {
    if (n < 0) return setErr(GL_INVALID_VALUE);
    var i: u32 = 0;
    while (i < @as(u32, @intCast(n))) : (i += 1) {
        // miniGL：纹理名 = 槽位号 + 1，0 保留为"未绑定"
        names[i] = (i % MAX_TEXTURES) + 1;
    }
}

pub fn bindTexture(target: GLenum, name: u32) void {
    if (target != GL_TEXTURE_2D) return setErr(GL_INVALID_ENUM);
    if (name > MAX_TEXTURES) return setErr(GL_INVALID_VALUE);
    ctx().bound_tex = name;
}

/// 上传纹理。format 支持 GL_RGBA / GL_RGB，type 只支持 GL_UNSIGNED_BYTE。
pub fn texImage2D(
    target: GLenum,
    level: i32,
    internalformat: GLenum,
    w: i32,
    h: i32,
    format: GLenum,
    ty: GLenum,
    data: ?[*]const u8,
) void {
    _ = internalformat; // miniGL 内部固定 RGBA8
    if (target != GL_TEXTURE_2D or level != 0) return setErr(GL_INVALID_ENUM);
    if (ty != GL_UNSIGNED_BYTE) return setErr(GL_INVALID_ENUM);
    if (w <= 0 or h <= 0 or w > MAX_TEX_W or h > MAX_TEX_H) return setErr(GL_INVALID_VALUE);
    const c = ctx();
    if (c.bound_tex == 0) return setErr(GL_INVALID_OPERATION);
    const t = &c.tex[c.bound_tex - 1];
    t.valid = true;
    t.w = @intCast(w);
    t.h = @intCast(h);
    const n: usize = @intCast(w * h);
    switch (format) {
        GL_RGBA => {
            if (data) |d| {
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    t.pix[i] = (@as(u32, d[i * 4]) << 24) | (@as(u32, d[i * 4 + 1]) << 16) |
                        (@as(u32, d[i * 4 + 2]) << 8) | d[i * 4 + 3];
                }
            } else @memset(t.pix[0..n], 0);
        },
        GL_RGB => {
            if (data) |d| {
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    t.pix[i] = 0xFF000000 | (@as(u32, d[i * 3]) << 16) |
                        (@as(u32, d[i * 3 + 1]) << 8) | d[i * 3 + 2];
                }
            } else @memset(t.pix[0..n], 0);
        },
        else => setErr(GL_INVALID_ENUM),
    }
}

pub fn texParameteri(target: GLenum, pname: GLenum, param: GLenum) void {
    if (target != GL_TEXTURE_2D) return setErr(GL_INVALID_ENUM);
    const c = ctx();
    if (c.bound_tex == 0) return setErr(GL_INVALID_OPERATION);
    const t = &c.tex[c.bound_tex - 1];
    switch (pname) {
        GL_TEXTURE_WRAP_S => t.wrap_s = param,
        GL_TEXTURE_WRAP_T => t.wrap_t = param,
        GL_TEXTURE_MAG_FILTER, GL_TEXTURE_MIN_FILTER => {
            if (param != GL_NEAREST) setErr(GL_INVALID_VALUE); // 只支持最近邻
        },
        else => setErr(GL_INVALID_ENUM),
    }
}

// ================= 立即模式 =================

pub fn begin(mode: GLenum) void {
    const c = ctx();
    switch (mode) {
        GL_POINTS, GL_LINES, GL_TRIANGLES, GL_QUADS => {},
        else => return setErr(GL_INVALID_ENUM),
    }
    c.imm_mode = mode;
    c.imm_count = 0;
    // 注意：不重置当前颜色/法线/UV——OpenGL 的 glBegin 不动这些
    // 状态， glColor 可以（也常常）在 glBegin 之前调用。
}

pub fn end() void {
    const c = ctx();
    if (c.imm_mode == 0) return;
    const n = c.imm_count;
    switch (c.imm_mode) {
        GL_POINTS => {
            var i: u32 = 0;
            while (i < n) : (i += 1) drawPoint(c.verts[i]);
        },
        GL_LINES => {
            var i: u32 = 0;
            while (i + 2 <= n) : (i += 2) drawLine(c.verts[i], c.verts[i + 1]);
        },
        GL_TRIANGLES => {
            var i: u32 = 0;
            while (i + 3 <= n) : (i += 3) drawTri(c.verts[i], c.verts[i + 1], c.verts[i + 2]);
        },
        GL_QUADS => {
            var i: u32 = 0;
            while (i + 4 <= n) : (i += 4) {
                // 四边形拆 012 + 023，保持绕向
                drawTri(c.verts[i], c.verts[i + 1], c.verts[i + 2]);
                drawTri(c.verts[i], c.verts[i + 2], c.verts[i + 3]);
            }
        },
        else => {},
    }
    c.imm_mode = 0;
    c.imm_count = 0;
}

fn emitVert(c: *Context, pos: Vec3) void {
    if (c.imm_count >= MAX_VERTS) {
        setErr(GL_OUT_OF_MEMORY);
        return;
    }
    c.verts[c.imm_count] = .{ .pos = pos, .col = c.cur_col, .norm = c.cur_norm, .uv = c.cur_uv };
    c.imm_count += 1;
}

pub fn vertex2f(x: f32, y: f32) void {
    emitVert(ctx(), .{ .x = x, .y = y, .z = 0 });
}

pub fn vertex3f(x: f32, y: f32, z: f32) void {
    emitVert(ctx(), .{ .x = x, .y = y, .z = z });
}

pub fn color3f(r: f32, g: f32, b: f32) void {
    ctx().cur_col = .{ r, g, b, 1.0 };
}

pub fn color4f(r: f32, g: f32, b: f32, a: f32) void {
    ctx().cur_col = .{ r, g, b, a };
}

pub fn normal3f(x: f32, y: f32, z: f32) void {
    ctx().cur_norm = .{ .x = x, .y = y, .z = z };
}

pub fn texCoord2f(u: f32, v: f32) void {
    ctx().cur_uv = .{ .x = u, .y = v };
}

// ================= 管线：变换 → 裁剪 → 投影 → 光栅化 =================

/// 裁剪空间的顶点：属性在裁剪空间是线性的（透视除法之前）——这是
/// 近平面裁剪插值保持正确性的关键。
const ClipV = struct {
    pos: Vec4, // 裁剪坐标
    col: [4]f32,
    uv: Vec2,
};

const NEAR_W: f32 = 1e-3; // w 至少要这么大，透视除法才安全

/// 变换一个顶点到裁剪空间（含光照）。法线用模型视线性部分的转置
/// （近似说明见文件头）。
fn transformVert(v: Vertex, mv: Mat4, pr: Mat4, c: *Context) ClipV {
    var col = v.col;
    if (c.lighting) {
        const m = &mv.m;
        const n = (Vec3{
            .x = m[0] * v.norm.x + m[1] * v.norm.y + m[2] * v.norm.z,
            .y = m[4] * v.norm.x + m[5] * v.norm.y + m[6] * v.norm.z,
            .z = m[8] * v.norm.x + m[9] * v.norm.y + m[10] * v.norm.z,
        }).normalized();
        const diff = @max(0.0, n.dot(c.to_light)); // Lambert 漫反射项
        col[0] = v.col[0] * @min(1.0, c.ambient + c.light_col.x * diff);
        col[1] = v.col[1] * @min(1.0, c.ambient + c.light_col.y * diff);
        col[2] = v.col[2] * @min(1.0, c.ambient + c.light_col.z * diff);
    }
    const eye = mv.transformPoint(.{ .x = v.pos.x, .y = v.pos.y, .z = v.pos.z, .w = 1.0 });
    return .{ .pos = pr.transformPoint(eye), .col = col, .uv = v.uv };
}

/// Sutherland-Hodgman 对近平面（w ≥ NEAR_W）裁剪多边形。
/// in/out 长度相同且 ≥ in.len+1；返回输出顶点数（0..in.len+1）。
fn clipNear(in: []const ClipV, out: []ClipV) usize {
    var n: usize = 0;
    const cnt = in.len;
    var i: usize = 0;
    while (i < cnt) : (i += 1) {
        const a = in[i];
        const b = in[(i + 1) % cnt];
        const ain = a.pos.w >= NEAR_W;
        const bin = b.pos.w >= NEAR_W;
        if (ain) {
            out[n] = a;
            n += 1;
        }
        if (ain != bin) {
            // 交点：t 使 w 恰好等于 NEAR_W（w 在裁剪空间是线性的）
            const t = (a.pos.w - NEAR_W) / (a.pos.w - b.pos.w);
            out[n] = .{
                .pos = .{
                    .x = a.pos.x + t * (b.pos.x - a.pos.x),
                    .y = a.pos.y + t * (b.pos.y - a.pos.y),
                    .z = a.pos.z + t * (b.pos.z - a.pos.z),
                    .w = NEAR_W,
                },
                .col = .{
                    a.col[0] + t * (b.col[0] - a.col[0]),
                    a.col[1] + t * (b.col[1] - a.col[1]),
                    a.col[2] + t * (b.col[2] - a.col[2]),
                    a.col[3] + t * (b.col[3] - a.col[3]),
                },
                .uv = .{
                    .x = a.uv.x + t * (b.uv.x - a.uv.x),
                    .y = a.uv.y + t * (b.uv.y - a.uv.y),
                },
            };
            n += 1;
        }
    }
    return n;
}

/// 屏幕空间三角形（光栅化输入）
const ScreenTri = struct {
    p: [3]Vec2, // 像素坐标（视口变换后）
    col: [3][4]f32,
    uv: [3]Vec2,
    iw: [3]f32, // 1/w —— 透视校正用
    z: [3]f32, // NDC 深度（在屏幕空间是线性的！）
};

fn drawTri(va: Vertex, vb: Vertex, vc: Vertex) void {
    const c = ctx();
    const mv = c.mv_stack[c.mv_top];
    const pr = c.pr_stack[c.pr_top];

    var cv: [3]ClipV = undefined;
    cv[0] = transformVert(va, mv, pr, c);
    cv[1] = transformVert(vb, mv, pr, c);
    cv[2] = transformVert(vc, mv, pr, c);

    // guard band：三顶点在某个裁剪平面的同一外侧 → 整体丢弃
    if (outsideAll(cv[0].pos, cv[1].pos, cv[2].pos)) return;

    // 近平面裁剪：三角形 → 最多 4 顶点多边形
    var poly: [4]ClipV = undefined;
    const pn = clipNear(&cv, &poly);
    if (pn < 3) return;

    // 背面剔除：用 NDC x-y 平面带符号面积判绕向（数学约定 CCW 为正）。
    // 裁剪不改变绕向，用裁剪后的前三个顶点（w 均为正）判即可。
    {
        const a = ndcOf(poly[0].pos);
        const b = ndcOf(poly[1].pos);
        const d = ndcOf(poly[2].pos);
        const area = (b.x - a.x) * (d.y - a.y) - (b.y - a.y) * (d.x - a.x);
        const front = if (c.front_ccw) area > 0 else area < 0;
        if (c.cull_face_en and front == (c.cull_what == GL_FRONT)) return;
    }

    // 扇形三角化 + 投影到屏幕坐标
    var i: usize = 1;
    while (i + 1 < pn) : (i += 1) {
        var st: ScreenTri = undefined;
        const idx = [3]usize{ 0, i, i + 1 };
        for (idx, 0..) |k, j| {
            const ndc = ndcOf(poly[k].pos);
            st.p[j] = .{
                .x = ndcToScreenX(ndc.x),
                .y = ndcToScreenY(ndc.y),
            };
            st.col[j] = poly[k].col;
            st.uv[j] = poly[k].uv;
            st.iw[j] = 1.0 / poly[k].pos.w;
            st.z[j] = ndc.z;
        }
        // FLAT 着色：整个三角形用最后一个顶点的颜色（provoking vertex）
        if (c.shade == .flat) {
            st.col[0] = st.col[2];
            st.col[1] = st.col[2];
        }
        rasterTri(st);
    }
}

fn ndcOf(p: Vec4) Vec3 {
    const iw = 1.0 / p.w;
    return .{ .x = p.x * iw, .y = p.y * iw, .z = p.z * iw };
}

inline fn ndcToScreenX(nx: f32) f32 {
    const c = ctx();
    return @as(f32, @floatFromInt(c.vp_x)) + (nx * 0.5 + 0.5) * @as(f32, @floatFromInt(c.vp_w));
}

/// y 镜像：NDC +1（世界的"上"）→ 视口顶部（视口 y 向下）
inline fn ndcToScreenY(ny: f32) f32 {
    const c = ctx();
    return @as(f32, @floatFromInt(c.vp_y)) + (1.0 - (ny * 0.5 + 0.5)) * @as(f32, @floatFromInt(c.vp_h));
}

fn outsideAll(a: Vec4, b: Vec4, d: Vec4) bool {
    if (a.x < -a.w and b.x < -b.w and d.x < -d.w) return true;
    if (a.x > a.w and b.x > b.w and d.x > d.w) return true;
    if (a.y < -a.w and b.y < -b.w and d.y < -d.w) return true;
    if (a.y > a.w and b.y > b.w and d.y > d.w) return true;
    if (a.z < -a.w and b.z < -b.w and d.z < -d.w) return true;
    if (a.z > a.w and b.z > b.w and d.z > d.w) return true;
    return false;
}

fn depthPass(c: *const Context, z: f32, ref: f32) bool {
    return switch (c.depth_func) {
        .never => false,
        .less => z < ref,
        .equal => z == ref,
        .lequal => z <= ref,
        .greater => z > ref,
        .always => true,
    };
}

/// 三角形光栅化：边缘函数（重心坐标）+ 包围盒，逐像素透视校正。
/// 相邻三角形共享边时统一用"归一化绕向后三条边 ≥ 0 判内"的规则——
/// 共享边像素归属第一个画的三角形（GL_LESS 拒绝同深度的第二个），
/// 既不裂缝也不闪烁。严格的无缝规则是 top-left rule，教学实现从简。
/// 极端离屏的细长三角形在 f32 边缘函数下可能有亚像素误差——包围盒
/// 裁剪保证不会越界，视觉上无感。
fn rasterTri(st: ScreenTri) void {
    const c = ctx();
    var p = st.p;
    var col = st.col;
    var uv = st.uv;
    var iw = st.iw;
    var z = st.z;

    // 归一化为正面积（顺时针也照画；剔除已在 drawTri 判过）
    const area = (p[1].x - p[0].x) * (p[2].y - p[0].y) - (p[1].y - p[0].y) * (p[2].x - p[0].x);
    if (@abs(area) < 1e-9) return; // 退化三角形
    if (area < 0) {
        swapVec2(&p[1], &p[2]);
        swapArr4(&col[1], &col[2]);
        swapVec2(&uv[1], &uv[2]);
        std.mem.swap(f32, &iw[1], &iw[2]);
        std.mem.swap(f32, &z[1], &z[2]);
    }
    const inv_area = 1.0 / @abs(area);

    // 包围盒（像素中心在整数 + 0.5）∩ 画布
    const fx0 = @max(0.0, floorf(@min(p[0].x, @min(p[1].x, p[2].x))));
    const fy0 = @max(0.0, floorf(@min(p[0].y, @min(p[1].y, p[2].y))));
    const fx1 = @min(@as(f32, @floatFromInt(c.fb_w - 1)), floorf(@max(p[0].x, @max(p[1].x, p[2].x))));
    const fy1 = @min(@as(f32, @floatFromInt(c.fb_h - 1)), floorf(@max(p[0].y, @max(p[1].y, p[2].y))));
    if (fx1 < fx0 or fy1 < fy0) return;
    const x0: i32 = f2i(fx0);
    const y0: i32 = f2i(fy0);
    const x1: i32 = f2i(fx1);
    const y1: i32 = f2i(fy1);

    // 边缘函数 e(a,b,q) = (b-a)×(q-a)：q 在 a→b 左侧为正。
    // e[i] 是顶点 i 的【对边】，锚定在边的起点 a[i]；
    // 这样 w[i]/area 恰好是顶点 i 的重心坐标（三边之和恒等于 2A）。
    // 每像素步进：∂e/∂x = a.y-b.y，∂e/∂y = b.x-a.x
    const e = [3]Vec2{
        .{ .x = p[1].y - p[2].y, .y = p[2].x - p[1].x }, // 对边 1→2 → l0
        .{ .x = p[2].y - p[0].y, .y = p[0].x - p[2].x }, // 对边 2→0 → l1
        .{ .x = p[0].y - p[1].y, .y = p[1].x - p[0].x }, // 对边 0→1 → l2
    };
    const anchor = [3]Vec2{ p[1], p[2], p[0] };
    var w_row: [3]f32 = undefined;
    {
        const px = @as(f32, @floatFromInt(x0)) + 0.5;
        const py = @as(f32, @floatFromInt(y0)) + 0.5;
        w_row[0] = edgeVal(e[0], anchor[0], px, py);
        w_row[1] = edgeVal(e[1], anchor[1], px, py);
        w_row[2] = edgeVal(e[2], anchor[2], px, py);
    }

    const texobj: ?*const Texture = if (c.tex_enabled and c.bound_tex != 0 and c.tex[c.bound_tex - 1].valid)
        &c.tex[c.bound_tex - 1]
    else
        null;

    var y = y0;
    while (y <= y1) : (y += 1) {
        var w0 = w_row[0];
        var w1 = w_row[1];
        var w2 = w_row[2];
        var x = x0;
        const row = @as(usize, @intCast(y)) * @as(usize, @intCast(c.fb_w));
        while (x <= x1) : (x += 1) {
            if (w0 >= 0 and w1 >= 0 and w2 >= 0) {
                const l0 = w0 * inv_area;
                const l1 = w1 * inv_area;
                const l2 = w2 * inv_area;
                putPixel(row + @as(usize, @intCast(x)), l0, l1, l2, col, uv, iw, z, texobj);
            }
            w0 += e[0].x;
            w1 += e[1].x;
            w2 += e[2].x;
        }
        w_row[0] += e[0].y;
        w_row[1] += e[1].y;
        w_row[2] += e[2].y;
    }
}

inline fn edgeVal(e: Vec2, a: Vec2, px: f32, py: f32) f32 {
    return e.x * (px - a.x) + e.y * (py - a.y);
}

/// 单像素着色：深度测试 → 透视校正插值 → 纹理 → 写入。
/// l0+l1+l2 = 1（重心坐标）。线/点复用本函数（l 退化为端点权重）。
fn putPixel(
    idx: usize,
    l0: f32,
    l1: f32,
    l2: f32,
    col: [3][4]f32,
    uv: [3]Vec2,
    iw: [3]f32,
    z: [3]f32,
    texobj: ?*const Texture,
) void {
    const c = ctx();
    const zf = l0 * z[0] + l1 * z[1] + l2 * z[2]; // NDC 深度在屏幕空间线性
    if (c.depth_test) {
        if (!depthPass(c, zf, c.depth[idx])) return;
    }
    // 透视校正：属性按"除以 w"插值，再除以 (1/w) 的插值（商即加权平均）
    const invw = l0 * iw[0] + l1 * iw[1] + l2 * iw[2];
    if (invw <= 0.0) return;
    const rcp = 1.0 / invw;
    var r = (l0 * col[0][0] * iw[0] + l1 * col[1][0] * iw[1] + l2 * col[2][0] * iw[2]) * rcp;
    var g = (l0 * col[0][1] * iw[0] + l1 * col[1][1] * iw[1] + l2 * col[2][1] * iw[2]) * rcp;
    var b = (l0 * col[0][2] * iw[0] + l1 * col[1][2] * iw[1] + l2 * col[2][2] * iw[2]) * rcp;

    if (texobj) |t| {
        const u = (l0 * uv[0].x * iw[0] + l1 * uv[1].x * iw[1] + l2 * uv[2].x * iw[2]) * rcp;
        const v = (l0 * uv[0].y * iw[0] + l1 * uv[1].y * iw[1] + l2 * uv[2].y * iw[2]) * rcp;
        const texel = sampleTex(t, u, v); // 0xRRGGBBAA
        const tr = @as(f32, @floatFromInt((texel >> 24) & 0xFF)) * (1.0 / 255.0);
        const tg = @as(f32, @floatFromInt((texel >> 16) & 0xFF)) * (1.0 / 255.0);
        const tb = @as(f32, @floatFromInt((texel >> 8) & 0xFF)) * (1.0 / 255.0);
        r *= tr; // GL_MODULATE：顶点色 × 纹素
        g *= tg;
        b *= tb;
    }

    if (c.depth_test and c.depth_mask) c.depth[idx] = zf;
    c.target[idx] = (@as(u32, toByte(r)) << c.rsh) |
        (@as(u32, toByte(g)) << c.gsh) |
        (@as(u32, toByte(b)) << c.bsh);
}

fn sampleTex(t: *const Texture, u: f32, v: f32) u32 {
    var uu = u;
    var vv = v;
    if (t.wrap_s == GL_REPEAT) {
        uu -= floorf(uu); // 周期回绕
    } else {
        uu = @min(0.9999, @max(0.0, uu)); // CLAMP_TO_EDGE
    }
    if (t.wrap_t == GL_REPEAT) {
        vv -= floorf(vv);
    } else {
        vv = @min(0.9999, @max(0.0, vv));
    }
    const tx: u32 = @intFromFloat(uu * @as(f32, @floatFromInt(t.w)));
    const ty: u32 = @intFromFloat(vv * @as(f32, @floatFromInt(t.h)));
    return t.pix[ty * t.w + tx];
}

// ---- 线与点（复用 putPixel 做深度/颜色）----

fn drawLine(va: Vertex, vb: Vertex) void {
    const c = ctx();
    const mv = c.mv_stack[c.mv_top];
    const pr = c.pr_stack[c.pr_top];
    var inbuf = [2]ClipV{ transformVert(va, mv, pr, c), transformVert(vb, mv, pr, c) };
    var out: [4]ClipV = undefined;
    const n = clipNear(&inbuf, &out);
    if (n < 2) return;
    const ca = out[0];
    const cb = out[1];

    const pa = ndcToScreenX(ndcOf(ca.pos).x);
    const pay = ndcToScreenY(ndcOf(ca.pos).y);
    const na = ndcOf(ca.pos);
    const nb = ndcOf(cb.pos);
    const pbx = ndcToScreenX(nb.x);
    const pby = ndcToScreenY(nb.y);

    const steps: i32 = f2i(@max(@abs(pbx - pa), @abs(pby - pay)));
    if (steps < 1) return;
    const inv_steps = 1.0 / @as(f32, @floatFromInt(steps));
    const iwa = 1.0 / ca.pos.w;
    const iwb = 1.0 / cb.pos.w;
    const dummy_uv = [3]Vec2{ .{}, .{}, .{} };

    var i: i32 = 0;
    while (i <= steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) * inv_steps;
        const l0 = 1.0 - t;
        const x = f2i(roundf(pa + t * (pbx - pa)));
        const y = f2i(roundf(pay + t * (pby - pay)));
        if (x < 0 or y < 0 or x >= c.fb_w or y >= c.fb_h) continue;
        const idx = @as(usize, @intCast(y)) * @as(usize, @intCast(c.fb_w)) + @as(usize, @intCast(x));
        putPixel(
            idx,
            l0,
            t,
            0,
            .{ ca.col, cb.col, cb.col },
            dummy_uv,
            .{ iwa, iwb, iwb },
            .{ l0 * na.z + t * nb.z, 0, 0 },
            null,
        );
    }
}

fn drawPoint(v: Vertex) void {
    const c = ctx();
    const mv = c.mv_stack[c.mv_top];
    const pr = c.pr_stack[c.pr_top];
    const cv = transformVert(v, mv, pr, c);
    if (cv.pos.w < NEAR_W) return;
    const n = ndcOf(cv.pos);
    const x = f2i(roundf(ndcToScreenX(n.x)));
    const y = f2i(roundf(ndcToScreenY(n.y)));
    if (x < 0 or y < 0 or x >= c.fb_w or y >= c.fb_h) return;
    const idx = @as(usize, @intCast(y)) * @as(usize, @intCast(c.fb_w)) + @as(usize, @intCast(x));
    const dummy_uv = [3]Vec2{ .{}, .{}, .{} };
    putPixel(
        idx,
        1,
        0,
        0,
        .{ cv.col, cv.col, cv.col },
        dummy_uv,
        .{ 1.0 / cv.pos.w, 0, 0 },
        .{ n.z, 0, 0 },
        null,
    );
}

// ================= 小工具 =================

fn toByte(v: f32) u8 {
    if (v <= 0.0) return 0;
    if (v >= 1.0) return 255;
    return @intFromFloat(v * 255.0 + 0.5);
}

/// 安全 float→int（夹取 + NaN 归零）。ReleaseSafe 下直接 @intFromFloat
/// 遇越界/NaN 会 panic——光栅化的所有坐标必须经过这里。
fn f2i(v: f32) i32 {
    if (v != v) return 0;
    if (v >= 2147483000.0) return 2147483000;
    if (v <= -2147483000.0) return -2147483000;
    return @intFromFloat(v);
}

/// 自实现 floor/round：@floor/@round 在无 SSE4.1 的基线 CPU 上会退
/// 化成 libm 调用（floorf/roundf），C 程序链接时没有 compiler_rt——
/// 索性自己写，miniGL 彻底零 libm。round 语义与 Zig 相同：ties away。
pub fn floorf(x: f32) f32 {
    if (x != x) return 0; // NaN
    if (x >= 1e9 or x <= -1e9) return x; // 大到取整无意义
    const i: f32 = @floatFromInt(f2i(x)); // f2i = 截断（向零）
    if (x < 0 and x != i) return i - 1.0;
    return i;
}

pub fn roundf(x: f32) f32 {
    if (x >= 0) return floorf(x + 0.5);
    return -floorf(-x + 0.5);
}

fn swapVec2(a: *Vec2, b: *Vec2) void {
    const t = a.*;
    a.* = b.*;
    b.* = t;
}

fn swapArr4(a: *[4]f32, b: *[4]f32) void {
    const t = a.*;
    a.* = b.*;
    b.* = t;
}

// ================= 单元测试（host 上 `zig build test`） =================

const testing = std.testing;

var t_ctx: Context = .{};
var t_color: [64 * 64]u32 = @splat(0);
var t_depth: [64 * 64]f32 = @splat(0);

/// 每个测试的起点：全新上下文 + 64×64 画布，固定 RGB 移位便于断言
fn tSetup() void {
    t_ctx = .{};
    makeCurrent(&t_ctx);
    t_color = @splat(0);
    t_depth = @splat(1.0);
    beginFrame(&t_color, &t_depth, 64, 64, 16, 8, 0);
}

/// 常用：ortho 把画布变成 2D 像素坐标系（左下角为原点，y 向上）
fn tOrtho2D() void {
    matrixMode(GL_PROJECTION);
    loadIdentity();
    ortho(0, 64, 0, 64, -1, 1);
    matrixMode(GL_MODELVIEW);
    loadIdentity();
}

test "sinf/cosf 精度" {
    var x: f32 = -10.0;
    while (x < 10.0) : (x += 0.037) {
        try testing.expectApproxEqAbs(@sin(x), sinf(x), 1e-6);
        try testing.expectApproxEqAbs(@cos(x), cosf(x), 1e-6);
    }
    // 大角度（demo 里会出现几百度的累计旋转角）
    try testing.expectApproxEqAbs(@as(f32, @floatCast(@sin(@as(f64, 765.0)))), sinf(765.0), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, @floatCast(@cos(@as(f64, -4200.0)))), cosf(-4200.0), 1e-4);
}

test "矩阵：单位阵与旋转" {
    var m = Mat4.identity();
    const v = m.transformPoint(.{ .x = 1, .y = 2, .z = 3, .w = 1 });
    try testing.expectEqual(@as(f32, 1), v.x);
    try testing.expectEqual(@as(f32, 2), v.y);

    tSetup();
    rotatef(90, 0, 0, 1); // 绕 z 转 90°：x 轴 → y 轴
    m = t_ctx.mv_stack[0];
    const r = m.transformPoint(.{ .x = 1, .y = 0, .z = 0, .w = 1 });
    try testing.expectApproxEqAbs(@as(f32, 0), r.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), r.y, 1e-6);
}

test "矩阵：perspective 的近/远平面映射" {
    tSetup();
    matrixMode(GL_PROJECTION);
    perspective(90, 1.0, 1.0, 10.0);
    const p = t_ctx.pr_stack[0];
    const n = ndcOf(p.transformPoint(.{ .x = 0, .y = 0, .z = -1, .w = 1 }));
    try testing.expectApproxEqAbs(@as(f32, -1), n.z, 1e-6); // 近平面 → NDC z=-1
    const f = ndcOf(p.transformPoint(.{ .x = 0, .y = 0, .z = -10, .w = 1 }));
    try testing.expectApproxEqAbs(@as(f32, 1), f.z, 1e-5); // 远平面 → NDC z=+1
}

test "clear 填充颜色与深度" {
    tSetup();
    clearColor(0.5, 0.25, 1.0, 1.0);
    clearDepth(0.75);
    clear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    const px = t_color[100];
    try testing.expectEqual(@as(u32, 128), (px >> 16) & 0xFF); // r=0.5 → 128
    try testing.expectEqual(@as(u32, 64), (px >> 8) & 0xFF); // g=0.25 → 64
    try testing.expectEqual(@as(u32, 255), px & 0xFF); // b=1 → 255
    try testing.expectEqual(@as(f32, 0.75), t_depth[100]);
}

test "2D 三角形：覆盖像素数与颜色" {
    tSetup();
    tOrtho2D();
    color3f(1, 0, 0);
    begin(GL_TRIANGLES);
    vertex2f(10, 10);
    vertex2f(50, 10);
    vertex2f(10, 50);
    end();

    // 像素 (15,45)（世界坐标）在三角形内部 → 纯红
    var found_red: usize = 0;
    for (t_color) |px| {
        if (px == 0xFF0000) found_red += 1;
    }
    // 直角边 40×40 的三角形：面积 800，加上斜边上的像素中心共 820
    try testing.expectEqual(@as(usize, 820), found_red);
    // 内部点：屏幕像素 (20,44) ≈ 世界 (20.5,19.5)，x+y=40 < 60 在三角形内
    try testing.expectEqual(@as(u32, 0xFF0000), t_color[44 * 64 + 20]);
    // 外部点
    try testing.expectEqual(@as(u32, 0x000000), t_color[60 * 64 + 60]);
}

test "深度测试：近的赢，与绘制顺序无关" {
    tSetup();
    tOrtho2D();
    enable(GL_DEPTH_TEST);
    clear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    color3f(0, 0, 1); // 远（NDC z = 0）
    begin(GL_TRIANGLES);
    vertex2f(0, 0);
    vertex2f(64, 0);
    vertex2f(0, 64);
    end();
    color3f(1, 0, 0); // 近（z=0.25 → NDC -0.25）
    begin(GL_TRIANGLES);
    vertex3f(0, 0, 0.25);
    vertex3f(64, 0, 0.25);
    vertex3f(0, 64, 0.25);
    end();
    // 交叠区显示红（后画的更近）：像素 (20,44) ≈ 世界 (20.5,19.5)
    try testing.expectEqual(@as(u32, 0xFF0000), t_color[44 * 64 + 20]);

    // 反过来画：先近后远，远的应被深度测试拒绝
    tSetup();
    tOrtho2D();
    enable(GL_DEPTH_TEST);
    clear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    color3f(1, 0, 0);
    begin(GL_TRIANGLES);
    vertex3f(0, 0, 0.25);
    vertex3f(64, 0, 0.25);
    vertex3f(0, 64, 0.25);
    end();
    color3f(0, 0, 1);
    begin(GL_TRIANGLES);
    vertex2f(0, 0);
    vertex2f(64, 0);
    vertex2f(0, 64);
    end();
    try testing.expectEqual(@as(u32, 0xFF0000), t_color[44 * 64 + 20]);
}

test "透视校正：近端颜色在屏幕上占更多" {
    tSetup();
    matrixMode(GL_PROJECTION);
    loadIdentity();
    perspective(90, 1.0, 1.0, 100.0);
    matrixMode(GL_MODELVIEW);
    loadIdentity();
    clear(GL_COLOR_BUFFER_BIT);

    // 一条从近(z=-1.2, 黄)伸到远(z=-6, 蓝)的条带，拆成两个三角形。
    // 若插值不做透视校正，屏幕中点恰好黄蓝各半；做了校正，屏幕中点
    // 的颜色应大幅偏向近端（1/w 加权）→ 黄色像素明显多于蓝色。
    begin(GL_TRIANGLES);
    color3f(1, 1, 0);
    vertex3f(-0.5, -0.4, -1.2); // 近端左下（黄）
    color3f(1, 1, 0);
    vertex3f(-0.5, 0.4, -1.2); // 近端左上（黄）
    color3f(0, 0, 1);
    vertex3f(0.5, 0.6, -6.0); // 远端（蓝）
    end();
    begin(GL_TRIANGLES);
    color3f(1, 1, 0);
    vertex3f(-0.5, -0.4, -1.2);
    color3f(0, 0, 1);
    vertex3f(0.5, 0.6, -6.0);
    color3f(0, 0, 1);
    vertex3f(0.5, -0.6, -6.0);
    end();

    var yellow: usize = 0;
    var blue: usize = 0;
    for (t_color) |px| {
        const r = (px >> 16) & 0xFF;
        const g = (px >> 8) & 0xFF;
        const b = px & 0xFF;
        if (r > 128 and g > 128 and b < 128) yellow += 1;
        if (b > 128 and r < 128 and g < 128) blue += 1;
    }
    try testing.expect(yellow > blue * 2); // 校正的标志：黄色显著过半
}

test "纹理：nearest 采样四象限" {
    tSetup();
    tOrtho2D();
    clear(GL_COLOR_BUFFER_BIT);

    // 2×2 纹理：内存顺序 = [红 绿 / 蓝 白]（第一行是红、绿）
    const data = [16]u8{
        255, 0,   0, 255, // (u0,v0) 红
        0,   255, 0, 255, // (u1,v0) 绿
        0,   0,   255, 255, // (u0,v1) 蓝
        255, 255, 255, 255, // (u1,v1) 白
    };
    var name: u32 = 0;
    genTextures(1, @ptrCast(&name));
    bindTexture(GL_TEXTURE_2D, name);
    texImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 2, 2, GL_RGBA, GL_UNSIGNED_BYTE, &data);
    enable(GL_TEXTURE_2D);
    color3f(1, 1, 1);
    begin(GL_QUADS);
    texCoord2f(0, 0);
    vertex2f(0, 0); // 世界左下（屏幕左下）
    texCoord2f(1, 0);
    vertex2f(64, 0);
    texCoord2f(1, 1);
    vertex2f(64, 64);
    texCoord2f(0, 1);
    vertex2f(0, 64);
    end();

    // 屏幕坐标（y 向下）：世界 (0,0) 在屏幕左下 → 纹理 v=0 行在下。
    // 屏幕四象限中心：左上=蓝 右上=白 左下=红 右下=绿
    try testing.expect((t_color[16 * 64 + 16] & 0xFF) > 200); // 左上 蓝
    const tr = t_color[16 * 64 + 48];
    try testing.expect((tr >> 16 & 0xFF) > 200 and (tr >> 8 & 0xFF) > 200); // 右上 白
    try testing.expect((t_color[48 * 64 + 16] >> 16) > 200); // 左下 红
    try testing.expect((t_color[48 * 64 + 48] >> 8 & 0xFF) > 200); // 右下 绿
}

test "近平面裁剪：穿到相机身后的三角形" {
    tSetup();
    matrixMode(GL_PROJECTION);
    loadIdentity();
    perspective(90, 1.0, 0.5, 10.0);
    matrixMode(GL_MODELVIEW);
    loadIdentity();
    clear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    color3f(0, 1, 0);
    begin(GL_TRIANGLES);
    vertex3f(-1, -1, 0.3); // z>0：相机身后（w = -z < 0）
    vertex3f(1, -1, 0.3); // 同上
    vertex3f(0, 0.1, -3.0); // 前方远处
    end();
    var lit: usize = 0;
    for (t_color) |px| {
        if (px != 0) lit += 1;
    }
    try testing.expect(lit > 50); // 裁掉身后部分，剩余仍可见
}

test "背面剔除：绕向决定去留" {
    tSetup();
    tOrtho2D();
    enable(GL_CULL_FACE);
    clear(GL_COLOR_BUFFER_BIT);
    color3f(1, 0, 0);
    begin(GL_TRIANGLES);
    vertex2f(10, 10); // NDC 平面 CCW（数学绕向，y 向上）
    vertex2f(50, 10);
    vertex2f(10, 50);
    end();
    var lit: usize = 0;
    for (t_color) |px| {
        if (px != 0) lit += 1;
    }
    try testing.expectEqual(@as(usize, 820), lit); // CCW 正面：保留

    clear(GL_COLOR_BUFFER_BIT);
    begin(GL_TRIANGLES);
    vertex2f(10, 10); // 交换两个顶点 → CW 背面
    vertex2f(10, 50);
    vertex2f(50, 10);
    end();
    lit = 0;
    for (t_color) |px| {
        if (px != 0) lit += 1;
    }
    try testing.expectEqual(@as(usize, 0), lit); // 被剔除
}

test "光照：法线朝向光源亮，背光只剩环境光" {
    tSetup();
    tOrtho2D();
    enable(GL_LIGHTING);
    const pos = [4]f32{ 0, 0, 1, 0 }; // 方向光从 +z 打来
    lightfv(GL_LIGHT0, GL_POSITION, &pos);
    clear(GL_COLOR_BUFFER_BIT);
    color3f(1, 1, 1);

    begin(GL_TRIANGLES);
    normal3f(0, 0, 1); // 正对光源
    vertex2f(0, 0);
    vertex2f(30, 0);
    vertex2f(0, 30);
    end();
    begin(GL_TRIANGLES);
    normal3f(0, 0, -1); // 背对光源
    vertex2f(34, 0);
    vertex2f(64, 0);
    vertex2f(34, 30);
    end();

    const lit_px = t_color[54 * 64 + 10]; // 左三角形内部（世界 ≈ (10.5,9.2)）
    const dark_px = t_color[54 * 64 + 40]; // 右三角形内部（世界 ≈ (40.5,9.2)）
    try testing.expect((lit_px & 0xFF) > (dark_px & 0xFF));
    try testing.expect((dark_px & 0xFF) > 0); // 环境光 0.2 → ~51
    try testing.expect((lit_px & 0xFF) >= 253); // 全亮
}

test "glGetError 报告非法枚举" {
    tSetup();
    _ = getError(); // 清零
    matrixMode(0xDEAD); // 非法
    try testing.expectEqual(GL_INVALID_ENUM, getError());
    try testing.expectEqual(GL_NO_ERROR, getError()); // 读后清零
}
