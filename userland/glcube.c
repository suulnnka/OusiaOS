/* glcube —— miniGL 的 C 演示：旋转纹理立方体
 *
 * 证明 zgl.h/zglabi 的 C ABI 可用：与 Zig 版 glview 同一份 gl.zig
 * 光栅化器，纯 C 写渲染循环。60 帧后自动退出（供串口集成测试），
 * 点击关闭盒提前退出。
 */

#include <stdio.h>
#include <zgl.h>

#define W 240
#define H 200
#define TEXSZ 32

static unsigned char checker[TEXSZ * TEXSZ * 4];

static void make_checker(void)
{
    for (int y = 0; y < TEXSZ; y++) {
        for (int x = 0; x < TEXSZ; x++) {
            int cell = ((x / 4) + (y / 4)) & 1;
            int border = (x % 4 == 0) || (y % 4 == 0);
            unsigned char *p = &checker[(y * TEXSZ + x) * 4];
            if (border) {
                p[0] = 255; p[1] = 255; p[2] = 255;
            } else if (cell) {
                p[0] = 30; p[1] = 200; p[2] = 90; /* 绿 */
            } else {
                p[0] = 180; p[1] = 40; p[2] = 60; /* 红紫 */
            }
            p[3] = 255;
        }
    }
}

/* 一个立方体面：4 顶点（外部看 CCW），uv 0..2 走 REPEAT */
static void face(float x0, float y0, float z0,
                 float x1, float y1, float z1,
                 float x2, float y2, float z2,
                 float x3, float y3, float z3)
{
    zgl_tex_coord2f(0, 0); zgl_vertex3f(x0, y0, z0);
    zgl_tex_coord2f(2, 0); zgl_vertex3f(x1, y1, z1);
    zgl_tex_coord2f(2, 2); zgl_vertex3f(x2, y2, z2);
    zgl_tex_coord2f(0, 2); zgl_vertex3f(x3, y3, z3);
}

int main(void)
{
    if (zwin_create(W, H, "glcube (C)") != 0) {
        printf("glcube: win_create failed\n");
        return 1;
    }
    if (zgl_begin_frame() != 0) {
        printf("glcube: begin_frame failed\n");
        return 1;
    }
    make_checker();
    zgl_bind_texture(zgl_gen_texture());
    zgl_tex_image(TEXSZ, TEXSZ, checker);

    for (int frame = 0; frame < 60; frame++) {
        zwin_event_t ev[4];
        int n = zwin_wait(ev, 4, 40);
        for (int i = 0; i < n; i++) {
            if (ev[i].kind == ZWIN_EV_CLOSE) {
                printf("glcube: closed by user at frame %d\n", frame);
                return 0;
            }
        }

        zgl_matrix_mode(ZGL_PROJECTION);
        zgl_load_identity();
        zgl_perspective(58.0f, (float)W / (float)H, 0.4f, 30.0f);
        zgl_matrix_mode(ZGL_MODELVIEW);
        zgl_load_identity();
        zgl_translate(0.0f, 0.0f, -4.5f);
        zgl_enable(ZGL_DEPTH_TEST);
        zgl_enable(ZGL_TEXTURE_2D);
        zgl_enable(ZGL_CULL_FACE);
        zgl_clear_color(0.06f, 0.10f, 0.14f, 1.0f);
        zgl_clear(ZGL_COLOR_BUFFER_BIT | ZGL_DEPTH_BUFFER_BIT);

        zgl_push_matrix();
        float t = (float)frame * 0.05f;
        zgl_rotate(t * 40.0f, 1.0f, 0.7f, 0.3f);
        zgl_rotate(t * 15.0f, 0.0f, 1.0f, 0.0f);
        zgl_begin(ZGL_QUADS);
        face(-1, -1, -1,  1, -1, -1,  1,  1, -1, -1,  1, -1);
        face( 1, -1,  1, -1, -1,  1, -1,  1,  1,  1,  1,  1);
        face(-1, -1,  1, -1, -1, -1, -1,  1, -1, -1,  1,  1);
        face( 1, -1, -1,  1, -1,  1,  1,  1,  1,  1,  1, -1);
        face(-1,  1, -1,  1,  1, -1,  1,  1,  1, -1,  1,  1);
        face(-1, -1,  1,  1, -1,  1,  1, -1, -1, -1, -1, -1);
        zgl_end();
        zgl_pop_matrix();

        zwin_present();
    }
    printf("glcube: 60 frames done (C ABI ok)\n");
    return 0;
}
