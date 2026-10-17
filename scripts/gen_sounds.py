#!/usr/bin/env python3
"""合成 ServerIsland 的提示音（纯标准库，无需任何音频素材）。

    python3 scripts/gen_sounds.py   -> Resources/Sounds/{success,failure,warning}.wav

- success：明亮的上行两音"叮咚"（E6 → B6），钟琴般的泛音，干净利落。
- failure：低沉的下行两音（A4 → E4），柔和的方波质感，一听就知道"出事了"但不刺耳。
- warning：同一个中音轻敲两下（D5），用于磁盘快满等提醒。
"""
import math
import os
import struct
import wave

RATE = 44100
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources", "Sounds")


def note(freq, start, dur, partials, decay, gain=1.0, attack=0.004):
    """返回 (起始采样, 采样列表)。partials: [(倍频, 幅度)]，decay: 指数衰减时间常数（秒）。"""
    n = int(dur * RATE)
    out = []
    for i in range(n):
        t = i / RATE
        env = (min(1.0, t / attack)) * math.exp(-t / decay)
        v = sum(a * math.sin(2 * math.pi * freq * m * t) for m, a in partials)
        out.append(gain * env * v)
    return int(start * RATE), out


def render(notes, total):
    buf = [0.0] * int(total * RATE)
    for start, samples in notes:
        for i, v in enumerate(samples):
            if start + i < len(buf):
                buf[start + i] += v
    # 结尾 30ms 淡出，避免爆音；归一化到 -3 dB 左右
    fade = int(0.03 * RATE)
    for i in range(fade):
        buf[-1 - i] *= i / fade
    peak = max(abs(v) for v in buf) or 1
    return [v / peak * 0.7 for v in buf]


def write(name, samples):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name + ".wav")
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, v)) * 32767)) for v in samples))
    print("wrote", os.path.relpath(path, ROOT))


BELL = [(1, 1.0), (2.0, 0.35), (3.01, 0.12), (4.2, 0.05)]       # 钟琴：带一点非整数泛音
SOFT_SQUARE = [(1, 1.0), (3, 0.28), (5, 0.12), (7, 0.05)]      # 柔化的方波：低沉、略"闷"

success = render([
    note(1318.5, 0.00, 0.30, BELL, decay=0.10, gain=0.8),        # E6
    note(1975.5, 0.10, 0.45, BELL, decay=0.16, gain=1.0),        # B6
], total=0.58)

failure = render([
    note(440.0, 0.00, 0.26, SOFT_SQUARE, decay=0.10, gain=1.0),   # A4
    note(329.6, 0.17, 0.40, SOFT_SQUARE, decay=0.15, gain=1.0),   # E4
], total=0.60)

warning = render([
    note(587.3, 0.00, 0.16, BELL, decay=0.06, gain=1.0),          # D5
    note(587.3, 0.14, 0.26, BELL, decay=0.09, gain=0.9),
], total=0.42)

write("success", success)
write("failure", failure)
write("warning", warning)
