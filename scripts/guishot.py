#!/usr/bin/env python3
"""ZOS GUI 截图/操作工具：无头 QEMU + HMP monitor 驱动鼠标。

用法:
    python3 scripts/guishot.py            # 开机截图 + 菜单/About/拖动全套
产物: /tmp/zos-shot-*.png
"""

import os
import socket
import struct
import subprocess
import sys
import time
import zlib

ISO = "build/zos.iso"
MON = "/tmp/zos-mon.sock"
SER = "/tmp/zos-serial.log"
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
    # 清理上次运行可能残留的 QEMU（占着 monitor socket 会让新实例起不来）
    subprocess.run(["pkill", "-f", "zos-mon.sock"], check=False)
    for _ in range(10):
        if subprocess.run(["pgrep", "-f", "zos-mon.sock"], capture_output=True).returncode != 0:
            break
        time.sleep(0.3)
    try:
        os.unlink(MON)
    except FileNotFoundError:
        pass
    open(SER, "w").close()
    errf = open("/tmp/zos-qemu-err.txt", "w")
    proc = subprocess.Popen(QEMU, stdout=subprocess.DEVNULL, stderr=errf)
    errf.close()
    deadline = time.time() + 40
    while time.time() < deadline:
        data = open(SER, "rb").read()
        if b"compositor up" in data or b"$ " in data:
            time.sleep(2)  # 等 GUI 首帧 + 时钟稳定
            return True
        if proc.poll() is not None:
            print("[FAIL] QEMU 提前退出 rc=%d" % proc.returncode)
            return False
        time.sleep(0.5)
    return False


def shot(name):
    hmp("screendump /tmp/zos-shot-%s.ppm" % name, 0.5)
    ppm_to_png("/tmp/zos-shot-%s.ppm" % name, "/tmp/zos-shot-%s.png" % name)
    print("shot:", name)


def ppm_to_png(src, dst):
    data = open(src, "rb").read()
    if not data.startswith(b"P6"):
        raise SystemExit("not P6: " + src)
    parts = data.split(b"\n", 3)
    w, h = map(int, parts[1].split())
    raw = parts[3]
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
    """相对移动到绝对坐标（光标起点在屏幕中心附近 (300,200)）"""
    # 查当前光标位置：从最近一次 screendump 找不到，直接累计已知状态
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


mouse_goto.pos = (300, 200)  # gui.zig 的光标初始位置


def click(x, y):
    mouse_goto(x, y)
    hmp("mouse_button 1", 0.1)
    hmp("mouse_button 0", 0.2)


def drag(x0, y0, x1, y1):
    mouse_goto(x0, y0)
    hmp("mouse_button 1", 0.1)
    mouse_goto(x1, y1)
    hmp("mouse_button 0", 0.2)


def main():
    try:
        os.unlink(MON)
    except FileNotFoundError:
        pass
    if not boot():
        print("[FAIL] GUI 未启动（看 /tmp/zos-serial.log）")
        return 1
    try:
        shot("0-boot")
        mouse_goto(30, 466)
        shot("1-hover-button")
        click(30, 466)
        shot("2-menu")
        click(40, 414)  # 菜单第一项 About ZOS
        shot("3-about")
        drag(320, 152, 400, 260)  # 拖标题栏
        shot("4-drag")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
        subprocess.run(["pkill", "-9", "-f", "zos-mon.sock"], check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
