#!/usr/bin/env bash
# 制作 GRUB (BIOS) 启动 ISO
set -euo pipefail
cd "$(dirname "$0")/.."

ISO_DIR=build/isodir
mkdir -p "$ISO_DIR/boot/grub"
cp zig-out/bin/zos-kernel.elf "$ISO_DIR/boot/"

# initrd：rootfs 静态内容 + 用户程序
./scripts/mkinitrd.sh
cp build/initrd.tar "$ISO_DIR/boot/"

cp grub.cfg "$ISO_DIR/boot/grub/grub.cfg"
grub-mkrescue -o build/zos.iso "$ISO_DIR" 2>/dev/null
echo "ISO ready: build/zos.iso"
