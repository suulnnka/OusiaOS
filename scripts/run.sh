#!/usr/bin/env bash
# 在 QEMU 中启动 ZOS（串口接到当前终端，Ctrl-A X 退出）
set -euo pipefail
cd "$(dirname "$0")/.."

exec qemu-system-x86_64 \
    -cdrom build/zos.iso \
    -m 256M \
    -display none \
    -serial stdio \
    -no-reboot \
    -netdev user,id=n0 \
    -device e1000,netdev=n0 \
    "$@"
