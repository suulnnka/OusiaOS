#!/usr/bin/env bash
# 制作 GRUB (BIOS) 启动 ISO
set -euo pipefail
cd "$(dirname "$0")/.."

ISO_DIR=build/isodir
mkdir -p "$ISO_DIR/boot/grub"
cp zig-out/bin/ousia-kernel.elf "$ISO_DIR/boot/"

# initrd 已废除：ext2 磁盘（build/disk.img）即根文件系统
./scripts/mkdisk.sh

cp grub.cfg "$ISO_DIR/boot/grub/grub.cfg"
grub-mkrescue -o build/ousia.iso "$ISO_DIR" 2>/dev/null
echo "ISO ready: build/ousia.iso"
