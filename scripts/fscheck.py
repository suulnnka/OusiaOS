#!/usr/bin/env python3
"""ZOS ext2 落盘验证：QEMU 里写文件 → 宿主机 e2fsck + debugfs 检查镜像。

用法: python3 scripts/fscheck.py

流程：
  1. 复制 build/disk.img 到临时文件
  2. QEMU 无头启动，通过 shell 执行一组写操作：重定向写、追加、
     curl 下载 20KB（跨间接块的文件）、mkdir、chmod、删除
  3. 退出后用 e2fsck -fn 检查一致性（位图/空闲计数/inode 引用）
  4. 用 debugfs 验证内容与权限确实落盘（大文件逐字节比对）
"""
import functools
import http.server
import os
import pty
import select
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

QEMU_CMD = [
    "qemu-system-x86_64",
    "-cdrom", "build/zos.iso",
    "-m", "256M",
    "-display", "none",
    "-no-reboot",
    # curl 下载测试需要 e1000（无网卡时 curl 会阻塞，shell 随之卡住）
    "-netdev", "user,id=n0",
    "-device", "e1000,netdev=n0",
    "-audiodev", "none,id=snd0",
    "-device", "AC97,audiodev=snd0",
    "-serial", "stdio",
]

BOOT_TIMEOUT = 30
CMD_TIMEOUT = 30

BIG_KB = 20  # 20KB > 12 直接块 → 必走一重间接块


def start_fixture():
    """宿主机 8123 端口提供 big.bin（patterned 20KB，供逐字节比对）。
    （不用 8099——test.py 刚用过，TIME_WAIT 会让 curl 连不上而挂起）"""
    d = tempfile.mkdtemp(prefix="zos_www_")
    blob = bytes((i * 7 + 13) & 0xFF for i in range(BIG_KB * 1024))
    with open(os.path.join(d, "big.bin"), "wb") as f:
        f.write(blob)

    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a):
            pass

    class Reusable(socketserver.TCPServer):
        allow_reuse_address = True

    httpd = Reusable(("127.0.0.1", 8123), functools.partial(Quiet, directory=d))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, blob


def run(commands, disk):
    master, slave = pty.openpty()
    proc = subprocess.Popen(
        QEMU_CMD + ["-drive", f"file={disk},format=raw,if=ide"],
        stdin=slave, stdout=slave,
        stderr=subprocess.DEVNULL, close_fds=True)
    os.close(slave)

    def read_until(pattern, timeout, acc=None):
        end = time.time() + timeout
        while time.time() < end:
            r, _, _ = select.select([master], [], [], 0.5)
            if r:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    return False
                if not chunk:
                    return False
                if acc is not None:
                    acc.append(chunk)
                if pattern in chunk:
                    return True
        return False

    ok = read_until(b"$ ", BOOT_TIMEOUT)
    time.sleep(0.5)
    for cmd in commands:
        # 累积匹配：提示符 "$ " 可能被 PTY 拆到两次读里（逐 chunk 匹配会漏）
        buf = b""
        os.write(master, cmd.encode() + b"\n")
        deadline = time.time() + CMD_TIMEOUT
        matched = False
        while time.time() < deadline:
            r, _, _ = select.select([master], [], [], 0.5)
            if not r:
                continue
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            if b"$ " in buf:
                matched = True
                break
        if not matched:
            print(f"[WARN] 命令未返回提示符: {cmd}")
            print("  期间输出:", buf[-300:])
        time.sleep(0.2)
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
    return ok


def main():
    src = "build/disk.img"
    if not os.path.exists(src):
        sys.exit("缺少 build/disk.img —— 先跑 zig build iso")
    fd, disk = tempfile.mkstemp(prefix="zos_fsck_", suffix=".img")
    os.close(fd)
    shutil.copyfile(src, disk)
    httpd, blob = start_fixture()
    try:
        cmds = [
            "echo persist-me > /mnt/p.txt",
            "echo line-two >> /mnt/p.txt",
            "curl http://10.0.2.2:8123/big.bin > /mnt/big.bin",
            "mkdir /mnt/sub",
            "echo nested > /mnt/sub/n.txt",
            "chmod 600 /mnt/p.txt",
            "rm /mnt/sub/n.txt",
            "rm -d /mnt/sub",
            "df",
        ]
        if not run(cmds, disk):
            sys.exit("[FAIL] 未等到 shell 提示符")

        print("== e2fsck -fn（一致性：位图/空闲计数/目录项链）==")
        r = subprocess.run(["e2fsck", "-fn", disk], capture_output=True, text=True)
        print(r.stdout.strip())
        # 干净时输出只有 5 个 pass + 汇总行，判断靠退出码（0 = 无错）
        if r.returncode != 0:
            sys.exit("[FAIL] e2fsck 报告问题")

        print("== debugfs（内容与权限落盘验证）==")
        for cmd, expect, label in [
            ("cat /p.txt", "persist-me\nline-two\n", "重定向+追加内容"),
            ("stat /p.txt", "Mode:  0600", "chmod 落盘"),
        ]:
            r = subprocess.run(["debugfs", "-R", cmd, disk], capture_output=True, text=True)
            got = r.stdout
            status = "OK " if expect in got else "FAIL"
            print(f"  [{status}] {label} ({cmd})")
            if expect not in got:
                print(got[:400])
                sys.exit(f"[FAIL] debugfs {cmd}")

        r = subprocess.run(["debugfs", "-R", "cat /big.bin", disk],
                           capture_output=True)
        # curl 写进文件的是 "HTTP 头 + 响应体 + 统计尾行"——定位响应体
        # 起点后逐字节比对（间接块映射正确 = body 与源完全一致）
        out = r.stdout
        idx = out.find(blob[:64])
        if idx > 0 and out[idx:idx + len(blob)] == blob:
            print("  [OK ] 20KB 多块文件逐字节一致（含间接块映射）")
        else:
            print(f"  [FAIL] big.bin 内容不一致：file {len(out)} bytes, blob {len(blob)}")
            sys.exit("[FAIL] big.bin")

        r = subprocess.run(["debugfs", "-R", "ls -l /", disk], capture_output=True, text=True)
        print(r.stdout.strip())
        print("PASS: ext2 落盘内容与元数据一致")
    finally:
        httpd.shutdown()
        os.unlink(disk)


if __name__ == "__main__":
    main()
