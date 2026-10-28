#!/usr/bin/env python3
"""ocp —— OusiaOS 文件推拉客户端（scp 风格；走 OusiaOS 的 ofile 协议 :3122）

用法:
    python3 scripts/ocp.py put <本地文件> <OusiaOS路径>
    python3 scripts/ocp.py get <OusiaOS路径> <本地文件>

环境变量: OusiaOS_HOST(默认127.0.0.1) OusiaOS_FILE_PORT(默认3122)
QEMU 需 -hostfwd tcp::3122-:3122（run.sh 已带）。
"""

import os
import socket
import sys


def read_line(sock, cap=256):
    buf = b""
    while b"\n" not in buf and len(buf) < cap:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
    i = buf.find(b"\n")
    if i < 0:
        raise IOError("connection closed before header line")
    return buf[:i].decode(errors="replace"), buf[i + 1:]


def cmd_get(host, port, rpath, lpath):
    sock = socket.create_connection((host, port), timeout=10)
    sock.settimeout(30)
    sock.sendall(f"GET {rpath}\n".encode())
    header, extra = read_line(sock)
    if not header.startswith("OK "):
        sys.exit(f"ocp: get {rpath}: {header}")
    size = int(header.split()[1])
    data = extra
    while len(data) < size:
        chunk = sock.recv(min(65536, size - len(data)))
        if not chunk:
            break
        data += chunk
    sock.close()
    if len(data) < size:
        sys.exit(f"ocp: get {rpath}: short read ({len(data)}/{size})")
    with open(lpath, "wb") as f:
        f.write(data)
    print(f"get: {rpath} -> {lpath} ({size} bytes)")


def cmd_put(host, port, lpath, rpath):
    with open(lpath, "rb") as f:
        data = f.read()
    sock = socket.create_connection((host, port), timeout=10)
    sock.settimeout(30)
    sock.sendall(f"PUT {rpath} {len(data)}\n".encode())
    sock.sendall(data)
    header, _ = read_line(sock)
    sock.close()
    if header != "OK":
        sys.exit(f"ocp: put {rpath}: {header}")
    print(f"put: {lpath} -> {rpath} ({len(data)} bytes)")


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)
    host = os.environ.get("OusiaOS_HOST", "127.0.0.1")
    port = int(os.environ.get("OusiaOS_FILE_PORT", "3122"))
    op, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
    if op == "get":
        cmd_get(host, port, a, b)
    elif op == "put":
        cmd_put(host, port, a, b)
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
