#!/usr/bin/env python3
"""oterm —— 连接 OusiaOS 远程 shell（明文 telnet 式）

用法:
    python3 scripts/oterm.py [host] [port]     # 默认 127.0.0.1 4321

QEMU 需 -hostfwd tcp::4321-:23（run.sh 已带）。回显/行编辑在 OusiaOS 侧
完成（终端保持本地行缓冲即可）。Ctrl-C 或 Ctrl-D 断开——guest 里的
会话 shell 会随连接关闭自动退出。
"""

import socket
import sys
import threading


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 4321
    sock = socket.create_connection((host, port), timeout=10)
    sock.settimeout(None)

    def rx():
        try:
            while True:
                data = sock.recv(4096)
                if not data:
                    print("\n[oterm: connection closed]", file=sys.stderr)
                    sys.exit(0)
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
        except OSError:
            pass

    threading.Thread(target=rx, daemon=True).start()
    try:
        while True:
            line = sys.stdin.buffer.readline()
            if not line:
                break
            sock.sendall(line)
    except KeyboardInterrupt:
        print("\n[oterm: bye]", file=sys.stderr)
    finally:
        sock.close()


if __name__ == "__main__":
    main()
