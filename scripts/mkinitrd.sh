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

# ustar 格式；-C 保证条目无 "./" 前缀
tar --format=ustar -cf build/initrd.tar -C build/rootfs etc dev bin hello.txt
echo "initrd: build/initrd.tar ($(du -h build/initrd.tar | cut -f1), $(tar -tf build/initrd.tar | wc -l) entries)"
