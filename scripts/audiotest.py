#!/usr/bin/env python3
"""OusiaOS 音频子系统验证：QEMU wav 后端录音 + 波形分析。

原理：QEMU 的 wav audiodev 把 guest 播放的 PCM 写进宿主机 wav 文件
（退出时才完整落盘，故经 monitor 'quit' 干净关机后再分析）。
脚本用 PTY 驱动串口 shell 执行 beep，随后校验录音：
  - 时长（与请求的时长比对）
  - 非零 RMS（DMA 真的在送数据）
  - 主频（过零率估计 → DDS 合成频率是否正确）

用法: python3 scripts/audiotest.py
"""

import os
import pty
import select
import socket
import struct
import subprocess
import sys
import time

WAV = "/tmp/ousia-audio.wav"
MON = "/tmp/ousia-audio-mon.sock"
QEMU = [
    "qemu-system-x86_64",
    "-cdrom", "build/ousia.iso",
    "-m", "256M",
    "-display", "none",
    "-no-reboot",
    "-serial", "stdio",
    "-monitor", "unix:" + MON + ",server,nowait",
    "-netdev", "user,id=n0", "-device", "e1000,netdev=n0",
    "-audiodev", "wav,id=s0,path=" + WAV + ",out.frequency=48000",
    "-device", "AC97,audiodev=s0",
]


def hmp_quit():
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(MON)
        time.sleep(0.2)
        s.settimeout(2)
        try:
            s.recv(65536)
        except Exception:
            pass
        s.sendall(b"quit\n")
        s.close()
        return True
    except OSError:
        return False


def analyze(path):
    """手写 wav 解析（容忍异常头），返回 (时长, 主频, rms)"""
    data = open(path, "rb").read()
    if len(data) < 44 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise SystemExit("not a wave file (%d bytes)" % len(data))
    off = 12
    fmt = None
    pcm = b""
    while off + 8 <= len(data):
        tag = data[off:off + 4]
        sz = struct.unpack("<I", data[off + 4:off + 8])[0]
        if tag == b"fmt ":
            fmt = struct.unpack("<HHIIHH", data[off + 8:off + 8 + sz])
        elif tag == b"data":
            pcm = data[off + 8:off + 8 + sz]
            break
        off += 8 + sz + (sz & 1)
    if not pcm:
        pcm = data[44:]
    channels = fmt[1] if fmt else 2
    rate = fmt[2] if fmt else 48000
    n = len(pcm) // (2 * channels)
    if n == 0:
        return 0, 0, 0
    samples = struct.unpack_from("<%dh" % (n * channels), pcm, 0)[::channels]
    dur = n / rate
    rms = (sum(s * s for s in samples) / n) ** 0.5
    # 过零率 → 主频（取能量稳定的中段估计）
    zc = 0
    start, end = int(n * 0.2), int(n * 0.8)
    for i in range(start + 1, end):
        if (samples[i - 1] < 0 <= samples[i]) or (samples[i - 1] >= 0 > samples[i]):
            zc += 1
    freq = zc / 2 / ((end - start) / rate) if end > start else 0
    return dur, freq, rms


def main():
    try:
        os.unlink(MON)
    except FileNotFoundError:
        pass
    open(WAV, "wb").close()

    master, slave = pty.openpty()
    proc = subprocess.Popen(QEMU, stdin=slave, stdout=slave,
                            stderr=subprocess.DEVNULL, close_fds=True)
    os.close(slave)
    ok = True
    try:
        buf = b""
        deadline = time.time() + 40
        while time.time() < deadline:
            r, _, _ = select.select([master], [], [], 0.5)
            if r:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                buf += chunk
                sys.stdout.write(chunk.decode(errors="replace"))
                sys.stdout.flush()
                if b"$ " in buf:
                    break
        if b"$ " not in buf:
            print("\n[FAIL] 未等到 shell")
            return 1
        time.sleep(1)

        os.write(master, b"beep 440 500\n")
        buf = b""
        deadline = time.time() + 15
        while time.time() < deadline:
            r, _, _ = select.select([master], [], [], 0.5)
            if r:
                chunk = os.read(master, 4096)
                if chunk:
                    buf += chunk
                    if b"$ " in buf:
                        break
        if b"$ " not in buf:
            print("\n[FAIL] beep 未返回")
            return 1
        time.sleep(0.5)
    finally:
        if not hmp_quit():
            proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()

    dur, freq, rms = analyze(WAV)
    print("\n[analysis] duration=%.2fs freq=%.0fHz rms=%.0f" % (dur, freq, rms))
    if not (0.40 <= dur <= 0.70):
        print("[FAIL] 时长 %.2fs 偏离预期 ~0.51s" % dur)
        ok = False
    if not (400 <= freq <= 480):
        print("[FAIL] 主频 %.0fHz 偏离 440Hz" % freq)
        ok = False
    if rms < 500:
        print("[FAIL] RMS=%.0f，几乎静音——DMA 没送数据" % rms)
        ok = False
    if ok:
        print("[PASS] audio: 440Hz/500ms 录音校验通过")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
