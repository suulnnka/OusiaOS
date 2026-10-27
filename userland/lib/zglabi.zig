//! zglabi —— miniGL + winsys 的 C ABI（userland/include/zgl.h 的实现）
//!
//! 让 C 程序也能用 ZOS 的软件 OpenGL：同一份 gl.zig，Zig 应用直接
//! @import，C 应用链接 libzos.a 后调 zgl* 函数。前缀取 zgl/zwin 而
//! 不是 gl——避免与桌面系统的 libGL 符号混淆，也明确这是 ZOS 子集。
//!
//! 上下文与深度缓冲是本库的静态单例（每进程一份，链接进来才存在），
//! 窗口尺寸上限 ZGL_MAX_W/H——C 侧不需要懂"静态分配"这件事。

const std = @import("std");
const win = @import("win.zig");
const gl = @import("gl.zig");

pub const MAX_W = 512;
pub const MAX_H = 384;

var gctx: gl.Context = .{};
var gdepth: [MAX_W * MAX_H]f32 = @splat(1.0);

// ---------------- 窗口（winsys 的 C 封装） ----------------

export fn zwin_create(w: c_int, h: c_int, title: [*:0]const u8) c_int {
    if (w <= 0 or h <= 0 or w > MAX_W or h > MAX_H) return -1;
    if (!win.create(w, h, std.mem.span(title))) return -1;
    return 0;
}

export fn zwin_present() void {
    win.present();
}

/// 等事件（buf 是 zwin_event_t 数组）；返回事件数，0 = 超时
export fn zwin_wait(buf: [*]win.Event, n: c_int, timeout_ms: c_int) c_int {
    if (n <= 0 or n > 16) return 0;
    return @intCast(win.wait(buf[0..@intCast(n)], timeout_ms));
}

export fn zwin_width() c_int {
    return win.sw;
}

export fn zwin_height() c_int {
    return win.sh;
}

// ---------------- GL 帧 ----------------

/// 绑定窗口表面为渲染目标（内部完成 makeCurrent + beginFrame，
/// 含像素格式移位查询）。C 侧不需要知道表面在哪。
export fn zgl_begin_frame() c_int {
    if (win.sw == 0) return -1; // 先 zwin_create
    gl.makeCurrent(&gctx);
    const f = win.fmt();
    gl.beginFrame(win.surface(), &gdepth, win.sw, win.sh, f.rsh, f.gsh, f.bsh);
    return 0;
}

// ---------------- 状态 ----------------

export fn zgl_viewport(x: c_int, y: c_int, w: c_int, h: c_int) void {
    gl.viewport(x, y, w, h);
}

export fn zgl_clear_color(r: f32, g: f32, b: f32, a: f32) void {
    gl.clearColor(r, g, b, a);
}

export fn zgl_clear(mask: u32) void {
    gl.clear(mask);
}

export fn zgl_enable(cap: u32) void {
    gl.enable(cap);
}

export fn zgl_disable(cap: u32) void {
    gl.disable(cap);
}

export fn zgl_depth_func(f: u32) void {
    gl.depthFunc(f);
}

export fn zgl_shade_model(m: u32) void {
    gl.shadeModel(m);
}

export fn zgl_cull_face(m: u32) void {
    gl.cullFace(m);
}

/// 方向光（在模型变换【之前】调用 = 世界系光源；对应 glLightfv 的
/// GL_POSITION，C 侧省掉数组参数）
export fn zgl_light_dir(x: f32, y: f32, z: f32) void {
    const p = [4]f32{ x, y, z, 0 };
    gl.lightfv(gl.GL_LIGHT0, gl.GL_POSITION, &p);
}

export fn zgl_light_color(r: f32, g: f32, b: f32) void {
    const p = [4]f32{ r, g, b, 1 };
    gl.lightfv(gl.GL_LIGHT0, gl.GL_DIFFUSE, &p);
}

// ---------------- 矩阵 ----------------

export fn zgl_matrix_mode(m: u32) void {
    gl.matrixMode(m);
}

export fn zgl_load_identity() void {
    gl.loadIdentity();
}

export fn zgl_push_matrix() void {
    gl.pushMatrix();
}

export fn zgl_pop_matrix() void {
    gl.popMatrix();
}

export fn zgl_translate(x: f32, y: f32, z: f32) void {
    gl.translatef(x, y, z);
}

export fn zgl_rotate(deg: f32, x: f32, y: f32, z: f32) void {
    gl.rotatef(deg, x, y, z);
}

export fn zgl_scale(x: f32, y: f32, z: f32) void {
    gl.scalef(x, y, z);
}

export fn zgl_perspective(fovy_deg: f32, aspect: f32, near: f32, far: f32) void {
    gl.perspective(fovy_deg, aspect, near, far);
}

// ---------------- 立即模式 ----------------

export fn zgl_begin(mode: u32) void {
    gl.begin(mode);
}

export fn zgl_end() void {
    gl.end();
}

export fn zgl_vertex2f(x: f32, y: f32) void {
    gl.vertex2f(x, y);
}

export fn zgl_vertex3f(x: f32, y: f32, z: f32) void {
    gl.vertex3f(x, y, z);
}

export fn zgl_color3f(r: f32, g: f32, b: f32) void {
    gl.color3f(r, g, b);
}

export fn zgl_color4f(r: f32, g: f32, b: f32, a: f32) void {
    gl.color4f(r, g, b, a);
}

export fn zgl_normal3f(x: f32, y: f32, z: f32) void {
    gl.normal3f(x, y, z);
}

export fn zgl_tex_coord2f(u: f32, v: f32) void {
    gl.texCoord2f(u, v);
}

// ---------------- 纹理 ----------------

export fn zgl_gen_texture() u32 {
    var name: u32 = 0;
    gl.genTextures(1, @ptrCast(&name));
    return name;
}

export fn zgl_bind_texture(name: u32) void {
    gl.bindTexture(gl.GL_TEXTURE_2D, name);
}

/// RGBA8 纹理（w×h×4 字节，nearest 采样）
export fn zgl_tex_image(w: c_int, h: c_int, rgba: [*]const u8) void {
    gl.texImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, w, h, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, rgba);
}
