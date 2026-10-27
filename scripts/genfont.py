#!/usr/bin/env python3
"""从 PSF 控制台字体生成 kernel/font.zig（8x16 位图，ASCII 32..126）。

用法:
    python3 scripts/genfont.py /usr/share/consolefonts/Uni2-VGA16.psf.gz > kernel/font.zig

输出约定：每字节一行扫描线，MSB = 最左像素（与 VGA 硬件字体一致）。
"""
import gzip
import sys


def parse_psf(path):
    data = gzip.open(path, "rb").read() if path.endswith(".gz") else open(path, "rb").read()
    if data[:2] == b"\x36\x04":  # PSF1（charsize = 高度，宽度固定 8）
        mode, charsize = data[2], data[3]
        nglyphs = 512 if (mode & 1) else 256
        return data[4:], nglyphs, charsize, charsize, 8
    if data[:4] == b"\x72\xb5\x4a\x86":  # PSF2
        import struct
        (hdr, length, charsize, height, width) = struct.unpack_from("<IIIII", data, 8)
        return data[hdr:], length, charsize, height, width
    raise SystemExit("not a PSF font: " + path)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "/usr/share/consolefonts/Uni2-VGA16.psf.gz"
    glyphs, length, charsize, height, width = parse_psf(src)
    if width != 8 or height not in (8, 14, 16):
        raise SystemExit(f"unsupported geometry {width}x{height}")
    rows = []
    for code in range(32, 127):
        off = code * charsize
        g = glyphs[off:off + height]
        if len(g) < height:
            raise SystemExit("truncated font")
        rows.append("    .{ %s },  // %s" % (
            ", ".join(str(b) for b in g),
            chr(code) if chr(code) != "\\" else "\\\\",
        ))
    print("//! 8x%d 位图字体（由 scripts/genfont.py 从 PSF 控制台字体生成）" % height)
    print("//! 每字节一行扫描线，MSB = 最左像素。仅 ASCII 32..126。")
    print("")
    print("pub const W = 8;")
    print("pub const H = %d;" % height)
    print("pub const FIRST = 32;")
    print("pub const COUNT = 95;")
    print("pub const glyphs = [COUNT][H]u8{")
    print("\n".join(rows))
    print("};")


if __name__ == "__main__":
    main()
