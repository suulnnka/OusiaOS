#!/usr/bin/env bash
# 打包 initrd：rootfs 静态内容 + 编译好的用户程序(zig-out/bin/user)
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build/rootfs
cp -r rootfs/. build/rootfs/

# 用户程序（构建系统产出；存在才合并）
if [ -d zig-out/bin/user ]; then
    cp -f zig-out/bin/user/* build/rootfs/bin/
fi

# Linux 风格权限位（tar 原样带进文件系统，内核 tarfs 解析 mode/uid/gid）：
#   程序 0755（可执行）；普通文件 0644；shadow 演示 root-only 0600
chmod 755 build/rootfs/bin/* 2>/dev/null || true
chmod 644 build/rootfs/etc/issue build/rootfs/etc/motd \
          build/rootfs/etc/passwd build/rootfs/etc/group build/rootfs/hello.txt 2>/dev/null || true
chmod 600 build/rootfs/etc/shadow 2>/dev/null || true
chmod 644 build/rootfs/etc/ousia.conf build/rootfs/etc/sounds/*.wav 2>/dev/null || true
chmod 755 build/rootfs/etc build/rootfs/bin build/rootfs/dev build/rootfs/tmp build/rootfs/etc/sounds 2>/dev/null || true

# ustar 格式；-C 保证条目无 "./" 前缀
# --owner/--group=0：文件全部记为 root:root（宿主 uid 会带进 tar！）
tar --format=ustar --owner=0 --group=0 --numeric-owner -cf build/initrd.tar -C build/rootfs etc dev bin tmp hello.txt
echo "initrd: build/initrd.tar ($(du -h build/initrd.tar | cut -f1), $(tar -tf build/initrd.tar | wc -l) entries)"
