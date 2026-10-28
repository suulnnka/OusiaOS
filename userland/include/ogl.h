/* ogl.h —— OusiaOS miniGL 的 C 接口（实现见 lib/oglabi.zig）
 *
 * OpenGL 1.x 立即模式子集 + winsys 窗口。常量取真实 GL 值，
 * 但符号加 ogl_/OGL_/owin_ 前缀：这是 OusiaOS 的软件子集，不是 libGL。
 *
 * 典型用法（见 userland/glcube.c）：
 *   owin_create(w, h, "标题");
 *   ogl_begin_frame();
 *   ogl_clear_color(...); ogl_clear(OGL_COLOR|OGL_DEPTH);
 *   ogl_matrix_mode(OGL_PROJECTION); ogl_load_identity();
 *   ogl_perspective(60, aspect, 0.5, 30);
 *   ... ogl_begin(OGL_QUADS); ogl_tex_coord2f(...); ogl_vertex3f(...); ogl_end();
 *   owin_present();  owin_wait(ev, 8, 40);   // 40ms 节拍 + 事件
 */
#ifndef OGL_H
#define OGL_H

#ifdef __cplusplus
extern "C" {
#endif

/* 窗口尺寸上限（静态深度缓冲决定） */
#define OGL_MAX_W 512
#define OGL_MAX_H 384

/* 图元（真实 GL 值） */
#define OGL_POINTS         0x0000
#define OGL_LINES          0x0001
#define OGL_TRIANGLES      0x0004
#define OGL_QUADS          0x0007

/* 矩阵 */
#define OGL_MODELVIEW      0x1700
#define OGL_PROJECTION     0x1701

/* clear 位 */
#define OGL_DEPTH_BUFFER_BIT 0x0100
#define OGL_COLOR_BUFFER_BIT 0x4000

/* 开关 */
#define OGL_CULL_FACE      0x0B44
#define OGL_LIGHTING       0x0B50
#define OGL_DEPTH_TEST     0x0B71
#define OGL_TEXTURE_2D     0x0DE1

/* 深度函数 / 着色 / 剔除 */
#define OGL_LESS           0x0201
#define OGL_LEQUAL         0x0203
#define OGL_FLAT           0x1D00
#define OGL_SMOOTH         0x1D01
#define OGL_FRONT          0x0404
#define OGL_BACK           0x0405

/* 窗口事件（布局与内核 winsys.WinEvent 一致，共 8 字节） */
#define OWIN_EV_PRESS      1
#define OWIN_EV_RPRESS     2
#define OWIN_EV_RELEASE    3
#define OWIN_EV_MOVE       4
#define OWIN_EV_KEY        5
#define OWIN_EV_CLOSE      6

typedef struct {
    unsigned char kind; /* +1 pad */
    short x, y;         /* 客户区坐标 */
    unsigned char code; /* EV_KEY: ASCII */
} owin_event_t;

/* ---- 窗口 ---- */
int  owin_create(int w, int h, const char *title); /* 0 成功 */
void owin_present(void);
int  owin_wait(owin_event_t *buf, int n, int timeout_ms); /* 返回事件数 */
int  owin_width(void);
int  owin_height(void);

/* ---- 帧 ---- */
int  ogl_begin_frame(void); /* 0 成功；须在 owin_create 之后 */

/* ---- 状态 ---- */
void ogl_viewport(int x, int y, int w, int h);
void ogl_clear_color(float r, float g, float b, float a);
void ogl_clear(unsigned mask);
void ogl_enable(unsigned cap);
void ogl_disable(unsigned cap);
void ogl_depth_func(unsigned fn);
void ogl_shade_model(unsigned m);
void ogl_cull_face(unsigned m);
void ogl_light_dir(float x, float y, float z);
void ogl_light_color(float r, float g, float b);

/* ---- 矩阵 ---- */
void ogl_matrix_mode(unsigned m);
void ogl_load_identity(void);
void ogl_push_matrix(void);
void ogl_pop_matrix(void);
void ogl_translate(float x, float y, float z);
void ogl_rotate(float deg, float x, float y, float z);
void ogl_scale(float x, float y, float z);
void ogl_perspective(float fovy_deg, float aspect, float near, float far);

/* ---- 立即模式 ---- */
void ogl_begin(unsigned mode);
void ogl_end(void);
void ogl_vertex2f(float x, float y);
void ogl_vertex3f(float x, float y, float z);
void ogl_color3f(float r, float g, float b);
void ogl_color4f(float r, float g, float b, float a);
void ogl_normal3f(float x, float y, float z);
void ogl_tex_coord2f(float u, float v);

/* ---- 纹理 ---- */
unsigned ogl_gen_texture(void);
void ogl_bind_texture(unsigned name);
void ogl_tex_image(int w, int h, const unsigned char *rgba);

#ifdef __cplusplus
}
#endif

#endif /* OGL_H */
