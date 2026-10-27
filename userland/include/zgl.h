/* zgl.h —— ZOS miniGL 的 C 接口（实现见 lib/zglabi.zig）
 *
 * OpenGL 1.x 立即模式子集 + winsys 窗口。常量取真实 GL 值，
 * 但符号加 zgl_/ZGL_/zwin_ 前缀：这是 ZOS 的软件子集，不是 libGL。
 *
 * 典型用法（见 userland/glcube.c）：
 *   zwin_create(w, h, "标题");
 *   zgl_begin_frame();
 *   zgl_clear_color(...); zgl_clear(ZGL_COLOR|ZGL_DEPTH);
 *   zgl_matrix_mode(ZGL_PROJECTION); zgl_load_identity();
 *   zgl_perspective(60, aspect, 0.5, 30);
 *   ... zgl_begin(ZGL_QUADS); zgl_tex_coord2f(...); zgl_vertex3f(...); zgl_end();
 *   zwin_present();  zwin_wait(ev, 8, 40);   // 40ms 节拍 + 事件
 */
#ifndef ZGL_H
#define ZGL_H

#ifdef __cplusplus
extern "C" {
#endif

/* 窗口尺寸上限（静态深度缓冲决定） */
#define ZGL_MAX_W 512
#define ZGL_MAX_H 384

/* 图元（真实 GL 值） */
#define ZGL_POINTS         0x0000
#define ZGL_LINES          0x0001
#define ZGL_TRIANGLES      0x0004
#define ZGL_QUADS          0x0007

/* 矩阵 */
#define ZGL_MODELVIEW      0x1700
#define ZGL_PROJECTION     0x1701

/* clear 位 */
#define ZGL_DEPTH_BUFFER_BIT 0x0100
#define ZGL_COLOR_BUFFER_BIT 0x4000

/* 开关 */
#define ZGL_CULL_FACE      0x0B44
#define ZGL_LIGHTING       0x0B50
#define ZGL_DEPTH_TEST     0x0B71
#define ZGL_TEXTURE_2D     0x0DE1

/* 深度函数 / 着色 / 剔除 */
#define ZGL_LESS           0x0201
#define ZGL_LEQUAL         0x0203
#define ZGL_FLAT           0x1D00
#define ZGL_SMOOTH         0x1D01
#define ZGL_FRONT          0x0404
#define ZGL_BACK           0x0405

/* 窗口事件（布局与内核 winsys.WinEvent 一致，共 8 字节） */
#define ZWIN_EV_PRESS      1
#define ZWIN_EV_RPRESS     2
#define ZWIN_EV_RELEASE    3
#define ZWIN_EV_MOVE       4
#define ZWIN_EV_KEY        5
#define ZWIN_EV_CLOSE      6

typedef struct {
    unsigned char kind; /* +1 pad */
    short x, y;         /* 客户区坐标 */
    unsigned char code; /* EV_KEY: ASCII */
} zwin_event_t;

/* ---- 窗口 ---- */
int  zwin_create(int w, int h, const char *title); /* 0 成功 */
void zwin_present(void);
int  zwin_wait(zwin_event_t *buf, int n, int timeout_ms); /* 返回事件数 */
int  zwin_width(void);
int  zwin_height(void);

/* ---- 帧 ---- */
int  zgl_begin_frame(void); /* 0 成功；须在 zwin_create 之后 */

/* ---- 状态 ---- */
void zgl_viewport(int x, int y, int w, int h);
void zgl_clear_color(float r, float g, float b, float a);
void zgl_clear(unsigned mask);
void zgl_enable(unsigned cap);
void zgl_disable(unsigned cap);
void zgl_depth_func(unsigned fn);
void zgl_shade_model(unsigned m);
void zgl_cull_face(unsigned m);
void zgl_light_dir(float x, float y, float z);
void zgl_light_color(float r, float g, float b);

/* ---- 矩阵 ---- */
void zgl_matrix_mode(unsigned m);
void zgl_load_identity(void);
void zgl_push_matrix(void);
void zgl_pop_matrix(void);
void zgl_translate(float x, float y, float z);
void zgl_rotate(float deg, float x, float y, float z);
void zgl_scale(float x, float y, float z);
void zgl_perspective(float fovy_deg, float aspect, float near, float far);

/* ---- 立即模式 ---- */
void zgl_begin(unsigned mode);
void zgl_end(void);
void zgl_vertex2f(float x, float y);
void zgl_vertex3f(float x, float y, float z);
void zgl_color3f(float r, float g, float b);
void zgl_color4f(float r, float g, float b, float a);
void zgl_normal3f(float x, float y, float z);
void zgl_tex_coord2f(float u, float v);

/* ---- 纹理 ---- */
unsigned zgl_gen_texture(void);
void zgl_bind_texture(unsigned name);
void zgl_tex_image(int w, int h, const unsigned char *rgba);

#ifdef __cplusplus
}
#endif

#endif /* ZGL_H */
