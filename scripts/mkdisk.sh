#!/usr/bin/env bash
# 生成 ext2 根文件系统镜像 build/disk.img
#
# ZOS 0.3 起 ext2 是【唯一的根文件系统】：/bin（用户程序）、/etc（系统
# 配置）全部在这块盘上，内核引导即挂载为 /，initrd/tarfs 不再参与引导。
# 镜像用宿主机 mke2fs 建空盘 + debugfs 填充——镜像文件本身就是标准
# ext2，可用 debugfs/e2fsck 直接检查。
#
# 用法：scripts/mkdisk.sh [--force]
#   已存在则跳过（QEMU 重启/重跑 zig build run 时保留盘上的用户文件）；
#   改过用户程序后请 --force 重建，否则盘上是旧的 /bin。
set -euo pipefail
cd "$(dirname "$0")/.."

IMG=build/disk.img

if [ -f "$IMG" ]; then
    if [ "${1:-}" != "--force" ]; then
        if [ -d zig-out/bin/user ] && [ -n "$(find zig-out/bin/user -newer "$IMG" -print -quit 2>/dev/null)" ]; then
            echo "disk: $IMG 已存在，但用户程序比它新（盘上 /bin 是旧的；--force 重建）"
        else
            echo "disk: $IMG 已存在（内容跨重启保留）"
        fi
        exit 0
    fi
    echo "disk: --force 重建（盘上原有内容将清空）"
fi

mkdir -p build
rm -f "$IMG"

# 96MB = 98304 个 1KB 块 = 12 个块组；装下全部用户程序 + 用户可写空间
# -b 1024 -I 128：经典 ext2 布局；-O ^resize_inode：去掉内核不支持的
# 在线扩容特性（挂载时校验 incompat 特性集）
mke2fs -q -F -t ext2 -b 1024 -I 128 -O ^resize_inode "$IMG" 96m

# 填充。不用 mke2fs -d：它会把宿主的 uid 带进镜像（1.47 已无视
# root_owner=0:0），而 debugfs 的 write/mkdir 天然建出 root:root 文件，
# 与内核里 root 旁路权限的行为一致。权限用 sif mode 逐个设置。
CMDS=$(mktemp)
trap 'rm -f "$CMDS"' EXIT
{
    echo "mkdir bin"
    echo "mkdir dev"
    echo "mkdir tmp"
    echo "mkdir notes"
    echo "mkdir etc"
    echo "mkdir etc/sounds"

    # /bin：全部用户程序（可执行 0755）
    if [ -d zig-out/bin/user ]; then
        for f in zig-out/bin/user/*; do
            b=$(basename "$f")
            echo "write $PWD/$f bin/$b"
            echo "sif bin/$b mode 0100755"
        done
    fi

    # /etc：系统配置（shadow 仅 root 可读 0600，其余 0644）
    for f in rootfs/etc/*; do
        [ -f "$f" ] || continue
        b=$(basename "$f")
        echo "write $PWD/$f etc/$b"
    done
    echo "sif etc/shadow mode 0100600"
    for f in rootfs/etc/sounds/*; do
        [ -f "$f" ] || continue
        echo "write $PWD/$f etc/sounds/$(basename "$f")"
    done

    # 根目录与 ext2 教学注释
    echo "write $PWD/rootfs/hello.txt hello.txt"
    echo "write $PWD/diskroot/README README"
    echo "write $PWD/diskroot/notes/ext2.txt notes/ext2.txt"
} > "$CMDS"
debugfs -w -f "$CMDS" "$IMG" > /dev/null 2>&1

echo "disk: $IMG (ext2 96MB root filesystem: /bin /etc + diskroot 注释)"
