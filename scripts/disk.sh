#!/usr/bin/env bash
# 宿主机 ↔ ext2 镜像 文件互拷（debugfs 封装）
#
# QEMU 未运行时直接操作 build/disk.img：
#   拷入：scripts/disk.sh put <宿主文件> <盘上路径>     # 如 put app.tar /home/app.tar
#   拷出：scripts/disk.sh get <盘上路径> <宿主文件>     # 如 get /etc/ousia.conf ./ousia.conf
#   旁路：ls / rm / mkdir / stat / check（e2fsck）
#
# 教学要点：镜像就是块设备的全部内容，宿主机的 ext2 工具能直接读
# 写它——"拷入拷出"不需要任何内核配合。系统运行中的另一种拷入是
# 网络通道（curl 只做 GET 下载；上传需 HTTP PUT，是很好的练习）。
#
# 注意：QEMU 正在运行时不要操作镜像（两个"进程"同时写一个块设备）。
set -euo pipefail
cd "$(dirname "$0")/.."

IMG=build/disk.img
[ -f "$IMG" ] || { echo "no $IMG (run: zig build iso)"; exit 1; }

cmd="${1:-}"
shift || true

case "$cmd" in
put)
    [ $# -eq 2 ] || { echo "usage: disk.sh put <hostfile> <guestpath>"; exit 1; }
    src=$1
    case "$src" in /*) ;; *) src=$PWD/$src ;; esac
    debugfs -w -R "write $src $2" "$IMG" > /dev/null
    debugfs -w -R "sif $2 mode 0100644" "$IMG" > /dev/null 2>&1 || true
    echo "put: $1 -> $2"
    ;;
get)
    [ $# -eq 2 ] || { echo "usage: disk.sh get <guestpath> <hostfile>"; exit 1; }
    dst=$2
    case "$dst" in /*) ;; *) dst=$PWD/$dst ;; esac
    debugfs -R "dump $1 $dst" "$IMG" > /dev/null
    echo "get: $1 -> $2"
    ;;
ls)
    debugfs -R "ls -l ${1:-/}" "$IMG" 2>/dev/null
    ;;
rm)
    [ $# -eq 1 ] || { echo "usage: disk.sh rm <guestpath>"; exit 1; }
    debugfs -w -R "rm $1" "$IMG" > /dev/null
    echo "rm: $1"
    ;;
mkdir)
    [ $# -eq 1 ] || { echo "usage: disk.sh mkdir <dir>"; exit 1; }
    debugfs -w -R "mkdir $1" "$IMG" > /dev/null
    echo "mkdir: $1"
    ;;
stat)
    [ $# -eq 1 ] || { echo "usage: disk.sh stat <path>"; exit 1; }
    debugfs -R "stat $1" "$IMG" 2>/dev/null
    ;;
check)
    e2fsck -fn "$IMG"
    ;;
*)
    grep '^#' "$0" | sed -n '2,14p' | sed 's/^# //'
    exit 1
    ;;
esac
