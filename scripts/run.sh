#!/usr/bin/env bash
# 在 QEMU 中启动 ZOS（串口接到当前终端，Ctrl-A X 退出）
set -euo pipefail
cd "$(dirname "$0")/.."

# 远程服务端口映射：4321→guest:23（telnet 式 shell），3122→:3122（zfile 推拉）
exec qemu-system-x86_64 \
    -cdrom build/zos.iso \
    -drive file=build/disk.img,format=raw,if=ide \
    -netdev user,id=n0,hostfwd=tcp::4321-:23,hostfwd=tcp::3122-:3122 \
    -display none \
    -serial stdio \
    -no-reboot \
    -device e1000,netdev=n0 \
    -audiodev none,id=snd0 \
    -device AC97,audiodev=snd0 \
    "$@"
# -drive：ext2 磁盘（主通道主盘，内核挂到 /mnt；写入持久保存在镜像里）
# 听声音：把 -audiodev none 换成你的后端，例如（录音到文件）：
#   -audiodev wav,id=snd0,path=/tmp/zos.wav,out.frequency=48000
# 或（WSLg/PulseAudio）：
#   -audiodev pa,id=snd0
