#!/usr/bin/env python3
"""OusiaOS miniGL 视觉回归：无头 QEMU + HMP 驱动鼠标，验证 GL 演示。

流程:
    开机 → 开始菜单 → "3D Demos"（用户态 glview 进程）
    → 截两帧断言动画在跑（画面有变化）且画布非纯背景
    → 点击切到 Gouraud Torus、Wave Grid 各截一帧 → 关窗
产物: /tmp/ousia-gl-*.png
"""

import os
import socket
import struct
import subprocess
import sys
import time
import zlib

ISO = "build/ousia.iso"
MON = "/tmp/ousia-gl-mon.sock"
SER = "/tmp/ousia-gl-serial.log"
QEMU = [
    "qemu-system-x86_64",
    "-cdrom", ISO, "-m", "256M",
    "-display", "none",
    "-no-reboot",
    "-serial", "file:" + SER,
    "-monitor", "unix:" + MON + ",server,nowait",
    "-netdev", "user,id=n0", "-device", "e1000,netdev=n0",
]

proc = None
failures = []


def fail(msg):
    failures.append(msg)
    print("[FAIL]", msg)


def hmp(cmd, wait=0.3):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(MON)
    time.sleep(0.05)
    s.settimeout(2)
    try:
        s.recv(65536)
    except Exception:
        pass
    s.sendall((cmd + "\n").encode())
    time.sleep(wait)
    out = b""
    try:
        out = s.recv(65536)
    except Exception:
        pass
    s.close()
    return out.decode(errors="replace")


def boot():
    global proc
    subprocess.run(["pkill", "-f", "ousia-gl-mon.sock"], check=False)
    for _ in range(10):
        if subprocess.run(["pgrep", "-f", "ousia-gl-mon.sock"], capture_output=True).returncode != 0:
            break
        time.sleep(0.3)
    try:
        os.unlink(MON)
    except FileNotFoundError:
        pass
    open(SER, "w").close()
    errf = open("/tmp/ousia-gl-qemu-err.txt", "w")
    proc = subprocess.Popen(QEMU, stdout=subprocess.DEVNULL, stderr=errf)
    errf.close()
    deadline = time.time() + 40
    while time.time() < deadline:
        data = open(SER, "rb").read()
        if b"compositor up" in data or b"$ " in data:
            time.sleep(2)
            return True
        if proc.poll() is not None:
            print("[FAIL] QEMU 提前退出 rc=%d" % proc.returncode)
            return False
        time.sleep(0.5)
    return False


def read_ppm(path):
    data = open(path, "rb").read()
    assert data.startswith(b"P6"), "not P6: " + path
    parts = data.split(b"\n", 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]


def shot(name):
    hmp("screendump /tmp/ousia-gl-%s.ppm" % name, 0.5)
    ppm_to_png("/tmp/ousia-gl-%s.ppm" % name, "/tmp/ousia-gl-%s.png" % name)
    print("shot:", name)
    return "/tmp/ousia-gl-%s.ppm" % name


def ppm_to_png(src, dst):
    w, h, raw = read_ppm(src)
    rows = b"".join(b"\x00" + raw[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(tag, payload):
        c = struct.pack(">I", len(payload)) + tag + payload
        return c + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(rows, 6))
           + chunk(b"IEND", b""))
    open(dst, "wb").write(png)


def mouse_goto(x, y, step=25):
    cur = mouse_goto.pos
    dx, dy = x - cur[0], y - cur[1]
    while dx or dy:
        mx = max(-step, min(step, dx))
        my = max(-step, min(step, dy))
        hmp("mouse_move %d %d" % (mx, my), 0.02)
        dx -= mx
        dy -= my
        cur = (cur[0] + mx, cur[1] + my)
    mouse_goto.pos = cur
    time.sleep(0.15)


mouse_goto.pos = (300, 200)  # gui.zig 光标初始位置


def click(x, y):
    mouse_goto(x, y)
    hmp("mouse_button 1", 0.1)
    hmp("mouse_button 0", 0.2)


def region_stats(path, x0, y0, x1, y1):
    """区域像素：不同颜色的个数 + 与另一帧的差异像素数"""
    w, h, raw = read_ppm(path)
    colors = set()
    for y in range(y0, y1, 3):  # 抽样步进 3，够快也够准
        base = y * w * 3
        for x in range(x0, x1, 3):
            i = base + x * 3
            colors.add((raw[i], raw[i + 1], raw[i + 2]))
    return colors


def region_diff(a, b, x0, y0, x1, y1):
    w, h, ra = read_ppm(a)
    _, _, rb = read_ppm(b)
    diff = 0
    total = 0
    for y in range(y0, y1, 2):
        ba = y * w * 3
        for x in range(x0, x1, 2):
            i = ba + x * 3
            total += 1
            if (ra[i], ra[i + 1], ra[i + 2]) != (rb[i], rb[i + 1], rb[i + 2]):
                diff += 1
    return diff, total


# glview 窗口几何：createUserWindow 级联首位 → 窗口 (24,14)，客户区
# 起点 (27,42)，320x240。（若改了级联参数，记得同步这里）
CX0, CY0, CX1, CY1 = 30, 45, 30 + 310, 45 + 200

# 菜单坐标：menuRect 顶 275，"3D Demos" 是第 7 项（0 起 6），中心 y=395
MENU_3D_Y = 395


def main():
    try:
        os.unlink(MON)
    except FileNotFoundError:
        pass
    if not boot():
        print("[FAIL] GUI 未启动（看 /tmp/ousia-gl-serial.log）")
        return 1
    rc = 0
    try:
        shot("0-boot")

        # 打开 3D Demos（用户态 glview 进程）
        click(30, 466)                 # OusiaOS 按钮
        shot("1-menu")
        click(40, MENU_3D_Y)           # "3D Demos"
        time.sleep(1.5)                # spawn + 首帧
        a = shot("2-cube-a")
        time.sleep(0.8)
        b = shot("3-cube-b")

        # 串口日志确认进程活着
        serial = open(SER, "rb").read()
        if b"glview: miniGL demos up" not in serial:
            fail("串口未见 glview 启动消息")
        if b"EXCEPTION" in serial or b"killed" in serial:
            fail("串口出现异常/崩溃: " + serial[-400:].decode(errors="replace"))

        # 断言 1：动画在跑（两帧不同）
        diff, total = region_diff(a, b, CX0, CY0, CX1, CY1)
        print("帧差异: %d/%d 像素" % (diff, total))
        if diff < total // 50:
            fail("两帧几乎相同——动画没在跑？")

        # 断言 2：棋盘立方体的三种纹理色齐全（正确光栅化下区域里恰好
        # 只有纹素的精确颜色——出现杂色反而是插值错了）
        colors = region_stats(a, CX0, CY0, CX1, CY1)
        print("画布颜色数(抽样): %d -> %s" % (len(colors), sorted(colors)))
        need = {(255, 140, 30), (25, 45, 140), (255, 255, 255)}
        if not need <= colors:
            fail("棋盘立方体三色不全——纹理没画出来？")

        # 切场景：torus / grid（点击客户区中心）
        click(187, 162)
        time.sleep(0.8)
        shot("4-torus")
        click(187, 162)
        time.sleep(0.8)
        shot("5-grid")

        # 关窗（关闭盒）
        click(334, 23)
        time.sleep(0.5)
        shot("6-closed")
        serial = open(SER, "rb").read()
        if b"EXCEPTION" in serial:
            fail("关窗后串口出现异常")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
        subprocess.run(["pkill", "-9", "-f", "ousia-gl-mon.sock"], check=False)

    if failures:
        print("\n%d 项失败" % len(failures))
        rc = 1
    else:
        print("\n全部通过")
    return rc


if __name__ == "__main__":
    sys.exit(main())
