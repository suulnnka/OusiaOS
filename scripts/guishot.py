#!/usr/bin/env python3
"""OusiaOS GUI 截图/操作工具：无头 QEMU + HMP monitor 驱动鼠标。

用法:
    python3 scripts/guishot.py            # 开机截图 + 菜单/About/拖动全套
产物: /tmp/oos-shot-*.png
"""

import os
import socket
import struct
import subprocess
import sys
import time
import zlib

ISO = "build/ousia.iso"
# 多个 ZCode 会话并行时会互相覆盖：可用环境变量隔离三件套
MON = os.environ.get("OUSIA_MON", "/tmp/oos-mon.sock")
SER = os.environ.get("OUSIA_SER", "/tmp/oos-serial.log")
SHOT = os.environ.get("OUSIA_SHOT", "/tmp/oos-shot")
QEMU = [
    "qemu-system-x86_64",
    "-cdrom", ISO,
    # GUI 应用（/bin/*）在 ext2 根文件系统上——必须挂盘
    "-drive", "file=build/disk.img,format=raw,if=ide",
    "-m", "256M",
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
    subprocess.run(["pkill", "-f", "oos-mon.sock"], check=False)
    for _ in range(10):
        if subprocess.run(["pgrep", "-f", "oos-mon.sock"], capture_output=True).returncode != 0:
            break
        time.sleep(0.3)
    try:
        os.unlink(MON)
    except FileNotFoundError:
        pass
    open(SER, "w").close()
    errf = open("/tmp/ousia-qemu-err.txt", "w")
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
    hmp("screendump %s-%s.ppm" % (SHOT, name), 0.5)
    ppm_to_png("%s-%s.ppm" % (SHOT, name), "%s-%s.png" % (SHOT, name))
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


def rightclick(x, y):
    mouse_goto(x, y)
    # HMP mouse_button 是 PS/2 位序：1=左 2=右 4=中（注意不是 1/2/4=L/M/R）
    hmp("mouse_button 2", 0.1)
    hmp("mouse_button 0", 0.2)


def drag(x0, y0, x1, y1):
    mouse_goto(x0, y0)
    hmp("mouse_button 1", 0.1)
    mouse_goto(x1, y1)
    hmp("mouse_button 0", 0.2)


# HMP sendkey 的键名与 ASCII 不同：空格=spc 回车=ret 斜杠=slash 减号=minus
KEYMAP = {" ": "spc", "\n": "ret", "/": "slash", "-": "minus", ".": "dot"}


def type_text(s):
    for ch in s:
        hmp("sendkey %s" % KEYMAP.get(ch, ch), 0.08)


def open_menu_item(item_y, name):
    click(30, 466)           # OusiaOS 按钮
    # 菜单项：item_y 是行顶（gui.zig menuRect 每项 18px）——点行中央，
    # 避开相对位移累积的 ±1px 与菜单 3px 内边距死区
    click(40, item_y + 9)
    time.sleep(0.3)
    print("open:", name)


# 菜单条目纵坐标（menuRect 顶 = TB_Y-menuHeight-3，每项 18px、分隔 5px；
# Control Panel 在 Minesweeper 之后——增删菜单项记得同步这里）
MENU = {
    "files": 260,
    "note": 278,
    "term": 296,
    "paint": 314,
    "calc": 332,
    "mine": 350,
    "cp": 368,
    "gl": 386,
    "about": 409,
}


def main():
    try:
        os.unlink(MON)
    except FileNotFoundError:
        pass
    if not boot():
        print("[FAIL] GUI 未启动（看 /tmp/ousia-serial.log）")
        return 1
    try:
        shot("0-boot")
        mouse_goto(30, 466)
        shot("1-hover-button")
        click(30, 466)
        shot("2-menu")
        click(320, 200)       # 点桌面收起菜单（否则 open_menu_item 的第一下会变成关菜单）

        # ---- 文件浏览器（用户进程 /bin/fm，级联摆位 (24,14)）----
        open_menu_item(MENU["files"], "File Manager")
        time.sleep(0.8)      # 等进程启动 + win_create + 首帧 present
        shot("3-files-root")
        click(60, 105)       # 根列表第 3 行 "etc"（客户区 (27,42)，列表 y=66）
        shot("4-files-etc")
        click(60, 90)        # /etc：".." 之后的第 1 个文件 "issue"
        shot("5-files-preview")

        # ---- 终端：镜像串口会话；sendkey 打一条命令（必须在记事本之前，
        #      记事本拿走键盘焦点后按键就不再进 shell 了）----
        open_menu_item(MENU["term"], "Terminal")
        time.sleep(0.4)
        shot("6-term-bootlog")
        type_text("ls\n")
        time.sleep(0.5)
        shot("7-term-ls")

        # ---- 画图（/bin/paint，级联 (96,74)→客户区 (99,102)）----
        open_menu_item(MENU["paint"], "Paint")
        time.sleep(0.8)
        shot("8-paint-new")
        click(75, 98)        # 红色色板 idx2（客户区 y72 + 6 + 14 → 92..105）
        drag(200, 180, 420, 270)  # 画布 (135..435, 76..276) 内拖动
        shot("9-paint-draw")

        # ---- 计算器（/bin/calc，级联 (132,104)→客户区 (135,132)）----
        open_menu_item(MENU["calc"], "Calculator")
        time.sleep(0.8)
        shot("10-calc-new")
        for (x, y) in [(131, 251), (251, 251), (171, 251), (251, 283)]:
            click(x, y)      # 1 + 2 = （键阵 gx=150 gy=172，34x26 键 + 6 缝）
        shot("11-calc-3")

        # ---- 记事本：键盘焦点（此刻 sendkey 进的是记事本，不是 shell）----
        open_menu_item(MENU["note"], "Notepad")
        time.sleep(0.8)      # /bin/note 启动；活动窗口=它 → 键盘归它
        shot("12-note-new")
        type_text("hello ousia\nsecond line")
        time.sleep(0.3)
        shot("13-note-text")

        # ---- 扫雷（/bin/mine，级联 (168,134)→客户区 (171,162)）----
        open_menu_item(MENU["mine"], "Minesweeper")
        time.sleep(0.8)
        shot("14-mine-new")
        click(268, 298)      # 棋盘 (4,4)：首次点击保证安全（gx=176 gy=206）
        time.sleep(0.5)
        shot("15-mine-open")
        rightclick(186, 218) # 棋盘 (0,0) 格心：插旗（远离首击洪泛区）
        time.sleep(0.5)
        shot("16-mine-flag")

        # ---- 控制面板（/bin/cpanel）----
        open_menu_item(MENU["cp"], "Control Panel")
        time.sleep(0.8)
        shot("17-cpanel")

        # ---- About + 拖拽（原有回归流程） ----
        open_menu_item(MENU["about"], "About OusiaOS")
        shot("18-about")
        drag(320, 152, 400, 260)  # 拖标题栏
        shot("19-drag")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
        subprocess.run(["pkill", "-9", "-f", "oos-mon.sock"], check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
