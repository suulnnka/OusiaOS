#!/usr/bin/env python3
"""OusiaOS 自动化测试：用 PTY 驱动 QEMU 串口 shell。

用法: python3 scripts/test.py [命令行数...]

PTY 模拟真实终端，避免 stdio 管道与 QEMU chardev 的兼容性问题；
命令按序发送，检查每条命令的预期输出。
"""

import os
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import time

QEMU_CMD = [
    "qemu-system-x86_64",
    "-cdrom", "build/ousia.iso",
    "-m", "256M",
    "-display", "none",
    "-no-reboot",
    # 远程服务端口映射：4321→guest:23（telnet shell），3122→:3122（ofile）
    "-netdev", "user,id=n0,hostfwd=tcp::4321-:23,hostfwd=tcp::3122-:3122",
    "-device", "e1000,netdev=n0",
    # 声卡在场（无音频后端，静音）——回归顺便覆盖 audio.init 路径
    "-audiodev", "none,id=snd0",
    "-device", "AC97,audiodev=snd0",
]

BOOT_TIMEOUT = 30  # 等待 shell 提示的最长秒数
CMD_TIMEOUT = 15


def prepare_disk() -> str:
    """复制一份干净的 ext2 镜像作为测试盘（不污染 build/disk.img 的持久内容）"""
    src = "build/disk.img"
    if not os.path.exists(src):
        sys.exit("[FAIL] 缺少 build/disk.img —— 先跑 zig build iso（mkiso.sh 会调 mkdisk.sh）")
    fd, path = tempfile.mkstemp(prefix="ousia_disk_", suffix=".img")
    os.close(fd)
    shutil.copyfile(src, path)
    return path


def start_fixture_httpd():
    """起一个桩 HTTP 服务器（宿主机 8099 = guest 眼中的 10.0.2.2:8099）"""
    import http.server, socketserver, tempfile, threading
    d = tempfile.mkdtemp(prefix="ousia_www_")
    with open(d + "/hello.txt", "w") as f:
        f.write("hello from host httpd - OusiaOS networking works!\n")
    handler = http.server.SimpleHTTPRequestHandler
    class Quiet(handler):
        def log_message(self, *a): pass
    import functools

    class Reusable(socketserver.TCPServer):
        allow_reuse_address = True  # 上次的连接 TIME_WAIT 不阻塞重跑
    httpd = Reusable(("127.0.0.1", 8099), functools.partial(Quiet, directory=d))
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    return httpd


def remote_phase(master):
    """远程服务验证：telnet shell（:4321→23）+ ofile 推拉（:3122）。

    注意：这里用独立的串口读取缓冲（不复用外层累积缓冲——里面的旧
    "$ " 会造成假匹配，测试抢在命令执行前跑完，全绿假象）。
    """
    import socket
    ok = True

    def fail(msg):
        nonlocal ok
        print(f"\n[FAIL] {msg}")
        ok = False

    def ser(cmd):
        """串口执行一条命令：发 → 收新输出直到提示符。返回期间输出。"""
        os.write(master, cmd.encode() + b"\n")
        acc = b""
        end = time.time() + CMD_TIMEOUT
        while time.time() < end:
            r, _, _ = select.select([master], [], [], 0.5)
            if r:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                acc += chunk
                if b"$ " in acc:
                    break
        time.sleep(0.2)
        return acc

    def ocp(*args):
        return subprocess.run([sys.executable, "scripts/ocp.py", *args],
                              capture_output=True, text=True, timeout=60)

    # ---- 1) 远程 shell：提示符 / 回显 / 退格行编辑 / 读盘 ----
    try:
        s = socket.create_connection(("127.0.0.1", 4321), timeout=15)
        s.settimeout(15)
        buf = b""

        def until(pat, tmo=15):
            nonlocal buf
            end = time.time() + tmo
            while time.time() < end:
                r, _, _ = select.select([s], [], [], 0.5)
                if r:
                    chunk = s.recv(4096)
                    if not chunk:
                        return False
                    buf += chunk
                    if pat in buf:
                        return True
            return False

        if not until(b"$ "):
            fail("远程 shell 未出现提示符")
        s.sendall(b"echo remote-shell-works\n")
        if not until(b"remote-shell-works"):
            fail("远程 echo 未回显")
        # 退格：abc + BS + def → echo abdef（行编辑在 OusiaOS 侧完成）
        s.sendall(b"echo abc\x7fdef\n")
        if not until(b"abdef"):
            fail("远程退格行编辑未生效")
        s.sendall(b"cat /etc/issue\n")
        if not until(b"OusiaOS"):
            fail("远程 cat 未读到 /etc/issue")
        s.sendall(b"exit\n")
        until(b"[connection closed]", 10)
        s.close()
    except OSError as e:
        fail(f"远程 shell 连接失败: {e}")

    # ---- 2) ofile push：宿主 → OusiaOS 落盘，串口 cat 验证内容 ----
    payload = b"hello-from-ocp\n" + (b"ousia-payload-line\n" * 12)
    with open("/tmp/znet-up.txt", "wb") as f:
        f.write(payload)
    r = ocp("put", "/tmp/znet-up.txt", "/net-up.txt")
    if r.returncode != 0:
        fail(f"ocp put 失败: {r.stdout}{r.stderr}")
    else:
        out = ser("cat /net-up.txt")
        if b"hello-from-ocp" in out and b"ousia-payload-line" in out:
            print("[OK] ofile put 内容经串口核对一致")
        else:
            fail("ofile put 内容不一致（串口 cat）")

    # ---- 3) ofile pull：串口 cp → 宿主 get → 逐字节比对 ----
    ser("cp /etc/motd /net-dl.txt")
    r = ocp("get", "/net-dl.txt", "/tmp/znet-dl.txt")
    if r.returncode != 0:
        fail(f"ocp get 失败: {r.stdout}{r.stderr}")
    else:
        want = open("rootfs/etc/motd", "rb").read()
        got = open("/tmp/znet-dl.txt", "rb").read()
        if got == want:
            print("[OK] ofile get 与磁盘内容逐字节一致")
        else:
            fail(f"ofile get 内容不一致 ({len(got)} vs {len(want)})")

    ser("rm /net-up.txt /net-dl.txt")
    return ok


def run_session(commands, disk, remote=True):
    master, slave = pty.openpty()
    proc = subprocess.Popen(
        QEMU_CMD + ["-drive", f"file={disk},format=raw,if=ide", "-serial", "stdio"],
        stdin=slave,
        stdout=slave,
        stderr=subprocess.DEVNULL,
        close_fds=True,
    )
    os.close(slave)

    output = b""

    def read_until(pattern: bytes, timeout: float) -> bool:
        nonlocal output
        deadline = time.time() + timeout
        while time.time() < deadline:
            r, _, _ = select.select([master], [], [], 0.5)
            if r:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    return False
                if not chunk:
                    return False
                output += chunk
                sys.stdout.write(chunk.decode(errors="replace"))
                sys.stdout.flush()
                if pattern in output:
                    return True
        return False

    ok = True
    try:
        if not read_until(b"$ ", BOOT_TIMEOUT):
            print("\n[FAIL] 未等到 shell 提示符")
            ok = False
        time.sleep(1.0)  # 等 shell 完全就绪再发命令
        for cmd in commands:
            output = b""
            os.write(master, cmd.encode() + b"\n")
            if not read_until(b"$ ", CMD_TIMEOUT):
                print(f"\n[FAIL] 命令 '{cmd}' 未返回提示符")
                ok = False
                break
            time.sleep(0.2)
        if ok and remote:
            ok = remote_phase(master)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()

    return ok


if __name__ == "__main__":
    cmds = sys.argv[1:] or [
        "uname -a", "ls /", "cat /etc/motd", "echo ok", "ps", "forkdemo",
        "fputest", "hello", "cdemo", "wc /etc/motd",
        # ext2 根文件系统：读、建、写、改权限、删——落盘证据可事后用
        # debugfs/e2fsck 检查镜像（这里用临时副本，不动 build/disk.img）
        "ls /bin", "cat /hello.txt", "cat /README",
        "mkdir /demo", "echo hello-ext2 > /demo/a.txt",
        "cat /demo/a.txt", "ls /demo", "chmod 600 /demo/a.txt",
        "rm /demo/a.txt", "rm -d /demo", "df",
        # cp：文件→文件 与 文件→目录 两种形式
        "cp /etc/motd /copy.txt", "cat /copy.txt", "cp /etc/motd /tmp",
        "wc -c /tmp/motd", "rm /copy.txt /tmp/motd",
        "ifconfig", "ping 10.0.2.2 3", "curl http://10.0.2.2:8099/hello.txt",
        "glcube",
    ]
    disk = prepare_disk()
    httpd = start_fixture_httpd()
    try:
        sys.exit(0 if run_session(cmds, disk) else 1)
    finally:
        httpd.shutdown()
        try:
            os.unlink(disk)
        except OSError:
            pass
