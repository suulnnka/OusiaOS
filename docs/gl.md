# miniGL：OusiaOS 的软件 OpenGL 子集

OusiaOS 的 3D 图形是**纯软件光栅化器** `userland/lib/gl.zig`（约 1100
行 Zig，零第三方依赖、零内核依赖）：实现 OpenGL 1.x 立即模式的一个
教学子集——矩阵栈、深度测试、Gouraud 光照、背面剔除、透视校正纹理
采样。它不知道屏幕的存在，只往一块 u32 数组（winsys 的共享表面）里
写像素；上屏靠 `win_present` 记脏区 + IRQ0 合成器搬运。

```
用户进程（glview.zig / glcube.c）
   │  gl.begin/gl.vertex3f/gl.end ...   纯用户态浮点代码
   ▼
miniGL（libousia 的一部分，每进程一份 Context）
   │  变换 → 光照 → 近平面裁剪 → 透视除法 → 视口 → 光栅化
   ▼
共享表面（win_create 双映射的页帧）──win_present──► 内核合成器 ──► 帧缓冲
```

为什么软件光栅化而不是"真"OpenGL 驱动？QEMU 默认机器没有任何 GPU；
virtio-gpu 的 virgl 3D 协议相当于要实现一整个 GPU 前端，而 TCG（无
KVM）下收益为负。软件管线把每一步都摊开在几百行代码里——这正是教学
内核想要的。同一份 `gl.zig` 还能在宿主机上跑单元测试（`zig build
test`）：逐像素断言三角形覆盖、深度遮挡、透视校正颜色、纹理采样、
近平面裁剪、正反面剔除，共 12 个用例。

## 1. 坐标空间：一个顶点的旅程

```
object ──MODELVIEW──► eye ──PROJECTION──► clip ──÷w──► NDC ──视口──► 窗口
 世界里摆物体        相机坐标系         裁剪空间      单位立方体      像素坐标
```

- **clip 空间**是唯一"属性仍然线性"的空间：近平面裁剪（Sutherland-
  Hodgman 对 `w ≥ 1e-3`）在这一步插值顶点属性才严格正确。
- **NDC 的 z 在屏幕空间是线性的**（透视除法后的深度可以直接用重心
  坐标插值、直接进 z-buffer）；颜色/UV 不是——见 §2。
- 视口变换刻意做成**左上角原点、y 向下**，与帧缓冲内存行序一致，
  画布可以零翻转直接 blit。NDC 的 +y（世界的"上"）映射到屏幕上方，
  所以场景看起来不是倒的。背面剔除在 NDC 的 x-y 平面按数学绕向
  （CCW=正面）判定，与视口翻转无关。

## 2. 透视校正：为什么屏幕上近处的颜色"占地更大"

屏幕空间的线性插值直接lerp颜色是错的。正确做法（硬件经典公式）：

```
重心坐标 l0,l1,l2（屏幕空间）        iw = 1/w（每顶点，屏幕空间线性）

color(P) = (Σ li·ci·iwi) / (Σ li·iwi)
uv(P)    = (Σ li·uvi·iwi) / (Σ li·iwi)      ← 采样纹理前先除
z(P)     = Σ li·zi                           ← 直接线性，不除
```

直觉：把 1/w 也当成一个属性插值，它在屏幕空间恰好线性（平面方程的
商）。除完再除回去，就是"按可见面积加权"的颜色。单测
`透视校正：近端颜色在屏幕上占更多` 验证：近端黄色在屏幕上占据明显
超过一半的长度——屏幕空间 lerp 会得到恰好一半，一眼就能区分对错。

## 3. 光栅化：边缘函数 + 统一判内规则

三角形用三条**边缘函数** `e(a,b,q) = (b-a)×(q-a)` 的增量步进
（∂e/∂x = a.y-b.y，∂e/∂y = b.x-a.x，每像素 2 次加法）求重心坐标，
包围盒 ∩ 画布裁剪。绕向先归一化为正面积，然后**三条边全部 ≥ 0 判
内**：相邻三角形共享边上的像素恰好归属第一个画的（GL_LESS 拒绝同
深度的第二个），不裂缝也不闪烁。严格的工业做法是 top-left rule，
教学实现从简（注释里写明了取舍）。

纹理：固定 4 槽 ≤256×256 的 RGBA8、nearest 采样、REPEAT/CLAMP_TO_EDGE
寻址、GL_MODULATE（顶点色 × 纹素）。没有 mipmap 和双线性——都是
一两页代码就能加的练习。

## 4. FPU 上下文：用户态浮点的地基（本次一并补齐）

miniGL 的渲染循环是**用户态 SSE 代码**，而 IRQ0 里跑的合成器也在用
SSE（`@memcpy` 的 SIMD 内联）。此前内核的 TrapFrame 只存通用寄存器、
调度切换不存 FPU——用户程序一用浮点就会坏。两个保存点，各堵一个
竞态：

| 保存点 | 防的问题 | 实现 |
|---|---|---|
| `idt.zig` trapCommon | 中断处理程序用 SSE 践踏被打断的浮点代码 | TrapFrame 增加 XMM0-15+MXCSR 区块（movups 免对齐要求，无条件保存换"显然正确"） |
| `proc.zig` swtchImpl | 每个进程各自拥有 FPU 现场 | Context 增加 264B fpu 区，切换时存旧取新 |

配套细节：`setupFirstEntry` 清零 TrapFrame 后要把 MXCSR 恢复成
0x1F80（清零值会打开全部浮点异常）。验证程序 `fputest`（forkdemo
风格）：父子进程各跑 5000 轮 f64 演算、每 500 轮 sleep 一次让对方
插进来，最后位级比对重算结果——IEEE 运算是确定性的，不一致即现场
被践踏。

## 5. 与 winsys 的接口

| 调用 | 说明 |
|---|---|
| `win_create(w,h,title)` | 共享表面（双映射页帧），就是 GL 的画布 |
| `win_fmt`（syscall 515） | 帧缓冲像素格式的 rsh/gsh/bsh 移位——miniGL 直接按硬件格式打包像素，上屏零转换 |
| `win_present` | 整块客户区记脏，IRQ0 合成 |

`win_color` 只够逐像素查询；miniGL 每帧几万次打包，所以给了移位
查询（一次陷入，渲染循环里零陷入）。

## 6. API 子集与刻意差异

实现（真实 GL 常量值）：`glBegin/glEnd`（POINTS/LINES/TRIANGLES/
QUADS）、`glVertex/glColor/glNormal/glTexCoord`、矩阵栈（16 层 ×
MODELVIEW/PROJECTION）、`glOrtho/glFrustum` + `perspective/lookAt`、
`glViewport/glClear/glClearColor`、`glEnable/glDisable`（DEPTH_TEST/
LIGHTING/CULL_FACE/TEXTURE_2D）、`glDepthFunc/glDepthMask`、
`glShadeModel(FLAT/SMOOTH)`、`glCullFace/glFrontFace`、
`glLightfv(GL_LIGHT0, POSITION/DIFFUSE)`（单方向光 Lambert + 环境光）、
纹理四件套、`glGetError`。

刻意不做（都写在文件头）：法线矩阵只用模型视线性部分的转置（非均匀
缩放下不严格）、无 alpha 混合、无显示列表/VBO/shader、纹理只 nearest。

**C ABI**：`userland/lib/oglabi.zig` 把同一份 gl.zig 导出成 `ogl_*`
符号（`userland/include/ogl.h`），C 程序 `glcube.c` 链接 libousia.a 即
可画 3D——与 Zig 版 glview 同一光栅化器。注意 libm 陷阱：`@floor/
@round` 在无 SSE4.1 的基线 CPU 上会退化成 libm 调用，C 程序链接没有
compiler_rt 兜底——所以 gl.zig 里 floor/round/sin/cos 全部自实现。

## 7. 演示与验证

- **glview**（开始菜单 "3D Demos"，Zig）：纹理棋盘立方体 / Gouraud
  光照圆环 / 线框波浪地形，点击或左右键切换，q 或关闭盒退出。
  TCG 下实测 320×240 约 18 fps。
- **glcube**（shell 运行，C）：60 帧旋转纹理立方体后退出，
  `glcube: 60 frames done (C ABI ok)`。
- `zig build test`：宿主机单测 12 例（数学库精度、逐像素光栅化断言、
  深度/剔除/裁剪/纹理行为、glGetError）。
- `python3 scripts/glishot.py`：无头 QEMU + HMP 鼠标驱动，开 GL 窗口
  截两帧断言动画在跑、棋盘三色齐全，切换场景截图，关窗无异常。
- `zig build test-run`：串口集成（fputest / glcube 在默认命令表）。

## 8. 扩展练习

- 双线性纹理过滤 + mipmap（采样器改造，观察摩尔纹消失）
- top-left fill rule 替换统一判内（共享边像素严格无重绘）
- scissor test（裁剪矩形栈）与 glReadPixels
- alpha 混合：putPixel 读改写 + 排序或 depth-peeling 的取舍讨论
- 法线矩阵做完整逆转置（伴随矩阵法），非均匀缩放的圆环对比
