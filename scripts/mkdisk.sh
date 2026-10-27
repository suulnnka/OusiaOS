#!/usr/bin/env bash
# 生成 ext2 磁盘镜像 build/disk.img（宿主机 mke2fs 制作，内核挂载到 /mnt）
#
# 教学要点：ext2 的价值在于"格式在磁盘上"——镜像文件 build/disk.img
# 就是块设备的全部内容，可以用 debugfs/e2fsck 直接检查；QEMU 重启后
# 内核写进去的文件仍然在（对比 tarfs：RAM 里，重启即失）
#
# 用法：scripts/mkdisk.sh [--force]   （已存在则跳过，--force 重建清空）
set -euo pipefail
cd "$(dirname "$0")/.."

IMG=build/disk.img
SRC=diskroot

if [ -f "$IMG" ] && [ "${1:-}" != "--force" ]; then
    echo "disk: $IMG 已存在（内容跨重启保留；--force 重建）"
    exit 0
fi

mkdir -p build
rm -f "$IMG"

# 16MB 镜像 = 16384 个 1KB 块 = 2 个块组（顺带覆盖多组位图路径）
# -b 1024 -I 128：经典 ext2 布局（1KB 块 / 128B inode）
# -O ^resize_inode：去掉内核不支持的在线扩容特性
mke2fs -q -F -t ext2 -b 1024 -I 128 -O ^resize_inode "$IMG" 16m

# 填充 diskroot/ 的内容。不用 mke2fs -d：它会把宿主的 uid 带进镜像
# （1.47 已无视 root_owner=0:0），而 debugfs 的 write/mkdir 天然建出
# root:root 的文件——与内核里 root 旁路权限的行为一致。
CMDS=$(mktemp)
trap 'rm -f "$CMDS"' EXIT
{
    # 目录先建（find 前序遍历保证父目录在前）
    (cd "$SRC" && find . -type d) | while read -r d; do
        [ "$d" = "." ] && continue
        echo "mkdir ${d#./}"
    done
    (cd "$SRC" && find . -type f) | while read -r f; do
        echo "write $PWD/$SRC/${f#./} ${f#./}"
    done
} > "$CMDS"
debugfs -w -f "$CMDS" "$IMG" > /dev/null 2>&1

echo "disk: $IMG (ext2 16MB, populated from $SRC/)"
