#!/usr/bin/env python3
"""ZOS 自动化测试：用 PTY 驱动 QEMU 串口 shell。

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
    "-cdrom", "build/zos.iso",
    "-m", "256M",
    "-display", "none",
    "-no-reboot",
    "-netdev", "user,id=n0",
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
    fd, path = tempfile.mkstemp(prefix="zos_disk_", suffix=".img")
    os.close(fd)
    shutil.copyfile(src, path)
    return path


def start_fixture_httpd():
    """起一个桩 HTTP 服务器（宿主机 8099 = guest 眼中的 10.0.2.2:8099）"""
    import http.server, socketserver, tempfile, threading
    d = tempfile.mkdtemp(prefix="zos_www_")
    with open(d + "/hello.txt", "w") as f:
        f.write("hello from host httpd - ZOS networking works!\n")
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


def run_session(commands, disk):
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
        # ext2 磁盘（/mnt）：读、建、写、改权限、删——落盘证据可事后用
        # debugfs/e2fsck 检查镜像（这里用临时副本，不动 build/disk.img）
        "ls /mnt", "cat /mnt/hello.txt", "cat /mnt/README",
        "mkdir /mnt/demo", "echo hello-ext2 > /mnt/demo/a.txt",
        "cat /mnt/demo/a.txt", "ls /mnt/demo", "chmod 600 /mnt/demo/a.txt",
        "rm /mnt/demo/a.txt", "rm -d /mnt/demo", "ls /mnt", "df",
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
