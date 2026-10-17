#!/usr/bin/env python3
"""ServerIsland v0.1 发布视频配乐（纯代码合成，无版权素材）。

    python3 promo/music.py  ->  promo/out/music.wav

120 BPM，C 大调 I–V–vi–IV。像素风 chiptune：脉冲波琶音 + 方波旋律 + 方波贝斯 + 失谐锯齿 pad，
鼓组带 sidechain"泵感"。段落和音效点全部来自 timeline.js（与画面共用同一套节拍）。
"""
import json
import os
import re

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, sosfilt

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(HERE, "out")

src = open(os.path.join(HERE, "timeline.js"), encoding="utf-8").read()
TL = json.loads(re.search(r"window\.TIMELINE = (\{.*?\})\s*// TIMELINE_JSON_END", src, re.S).group(1))

SR = 44100
BPM = TL["bpm"]
BEAT = 60.0 / BPM
TOTAL_BEATS = TL["durationBeats"]
N = int(TOTAL_BEATS * BEAT * SR)
L = np.zeros(N)
R = np.zeros(N)
rng = np.random.default_rng(7)


def s(beat):
    return int(round(beat * BEAT * SR))


def mtof(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def lp(x, hz, order=2):
    return sosfilt(butter(order, min(hz, SR * 0.45), "low", fs=SR, output="sos"), x)


def hp(x, hz, order=2):
    return sosfilt(butter(order, hz, "high", fs=SR, output="sos"), x)


def bp(x, lo, hi, order=2):
    return sosfilt(butter(order, [lo, hi], "band", fs=SR, output="sos"), x)


def add(sig, beat, gain=1.0, pan=0.0, buf=None):
    """在 beat 处叠加单声道信号；pan -1..1。"""
    i = s(beat)
    if i >= N:
        return
    sig = sig[: N - i] * gain
    lg = np.cos((pan + 1) * np.pi / 4)
    rg = np.sin((pan + 1) * np.pi / 4)
    (buf or (L, R))[0][i:i + len(sig)] += sig * lg * 1.4142
    (buf or (L, R))[1][i:i + len(sig)] += sig * rg * 1.4142


def env(n, a=0.005, d=0.1, sus=0.7, r=0.08, hold=None):
    """ADSR；hold 为按住时长（秒），之后释放。"""
    t = np.arange(n) / SR
    hold = hold if hold is not None else n / SR - r
    e = np.where(t < a, t / max(a, 1e-6),
                 np.where(t < a + d, 1 - (1 - sus) * (t - a) / max(d, 1e-6), sus))
    rel = np.clip(1 - (t - hold) / max(r, 1e-6), 0, 1)
    return e * np.where(t > hold, rel, 1)


def phase(freq, n, detune_cents=0.0):
    f = freq * 2 ** (detune_cents / 1200)
    return np.cumsum(np.full(n, f / SR)) % 1.0


def saw(f, n, det=0.0):
    return 2 * phase(f, n, det) - 1


def pulse(f, n, duty=0.5):
    return np.where(phase(f, n) < duty, 1.0, -1.0)


def tri(f, n):
    p = phase(f, n)
    return 4 * np.abs(p - 0.5) - 1


def sine(f, n):
    return np.sin(2 * np.pi * phase(f, n))


def noise(n):
    return rng.uniform(-1, 1, n)


# ---------------------------------------------------------------- 和声
CHORDS = {  # pad 音（中音区）, 贝斯根音
    "C": ([60, 64, 67, 74], 36), "G": ([59, 62, 67, 74], 43),
    "Am": ([57, 60, 64, 71], 45), "F": ([57, 60, 65, 72], 41),
}
PROG = ["F", "G", "C", "G", "Am", "F", "C", "G", "Am", "F", "C", "G", "Am", "F",
        "Am", "F", "G", "C", "G", "Am", "F", "G", "C", "G", "C"]


def section(bar):
    if bar < 2: return "intro"
    if bar < 8: return "A"
    if bar < 14: return "B"
    if bar < 17: return "break"
    if bar < 20: return "drop"
    if bar < 24: return "outro"
    return "end"


# 独立的 pad / 贝斯 / 琶音总线：之后整体做 sidechain
pad_bus = (np.zeros(N), np.zeros(N))
bass_bus = (np.zeros(N), np.zeros(N))
arp_bus = (np.zeros(N), np.zeros(N))
lead_bus = (np.zeros(N), np.zeros(N))

for bar, ch in enumerate(PROG):
    b0 = bar * 4
    sec = section(bar)
    notes, root = CHORDS[ch]
    # ---- pad：失谐锯齿，慢起
    dur_beats = 8 if sec == "end" else 4
    n = s(dur_beats) + int(0.6 * SR)
    e = env(n, a=0.25 if sec != "intro" else 0.8, d=0.4, sus=0.8, r=0.6, hold=dur_beats * BEAT)
    for m in notes:
        f = mtof(m)
        for det, pan in ((-9, -0.5), (9, 0.5)):
            sig = lp(saw(f, n, det), 1800 if sec in ("intro", "break") else 2600) * e
            add(sig, b0, 0.045, pan, pad_bus)
    if sec == "end":
        continue
    # ---- 贝斯
    if sec != "intro":
        steps = range(8)
        for k in steps:
            if sec == "A" and k % 2 == 1:
                continue
            if sec == "break" and k not in (0,):
                continue
            m = root + (12 if (sec in ("B", "drop", "outro") and k % 2 == 1) else 0)
            n = int(BEAT / 2 * SR * (0.9 if sec != "break" else 7.5))
            sig = (0.6 * pulse(mtof(m), n, 0.5) + 0.8 * sine(mtof(m), n))
            sig = lp(sig, 700 if sec != "break" else 400) * env(n, 0.003, 0.08, 0.6, 0.04)
            add(sig, b0 + k * 0.5, 0.30, 0.0, bass_bus)
    # ---- 琶音（16 分音符，脉冲波）
    arp_pat = [0, 1, 2, 3, 2, 1, 2, 3] * 2
    arp_notes = [m + 12 for m in notes]
    for k in range(16):
        if sec == "break" and k % 4 != 0:
            continue
        m = arp_notes[arp_pat[k]] + (12 if (sec in ("drop",) and k % 8 >= 4) else 0)
        n = int(0.11 * SR)
        sig = pulse(mtof(m), n, 0.25) * env(n, 0.002, 0.06, 0.25, 0.03)
        cut = {"intro": 900 + 2200 * (bar + k / 16) / 2, "break": 2200}.get(sec, 4200)
        add(lp(sig, cut), b0 + k * 0.25, 0.085 if sec != "intro" else 0.07, -0.35 if k % 2 else 0.35, arp_bus)

# ---- 旋律（8 分音符；None = 延音）
MEL = {
    "C": [76, None, 79, None, 81, 79, 76, None],
    "G": [74, None, None, 79, 74, None, 71, None],
    "Am": [72, None, 76, None, 81, None, 79, 76],
    "F": [77, None, 76, None, 72, None, None, None],
}
RUN_G = [74, 76, 79, 81, 83, 84, 86, None]


def play_lead(bar, line, gain=0.12, octave=0, harmony=False):
    b0 = bar * 4
    for k, m in enumerate(line):
        if m is None:
            continue
        hold = 1
        while k + hold < 8 and line[k + hold] is None and hold < 3:
            hold += 1
        n = int((hold * 0.5 * BEAT + 0.12) * SR)
        f = mtof(m + octave)
        t = np.arange(n) / SR
        vib = 1 + 0.006 * np.sin(2 * np.pi * 5.5 * t) * np.clip((t - 0.15) / 0.2, 0, 1)
        ph = np.cumsum(f * vib / SR) % 1
        sig = np.where(ph < 0.5, 1.0, -1.0) * 0.7 + np.sin(2 * np.pi * ph) * 0.5
        sig = lp(sig, 4200) * env(n, 0.004, 0.12, 0.65, 0.1, hold=hold * 0.5 * BEAT)
        add(sig, b0 + k * 0.5, gain, 0.1, lead_bus)
        if harmony:
            f2 = mtof(m + octave - 3 if m % 12 in (4, 9, 11) else m + octave - 4)
            ph2 = np.cumsum(f2 * vib / SR) % 1
            sig2 = lp(np.where(ph2 < 0.5, 1.0, -1.0), 3000) * env(n, 0.004, 0.12, 0.6, 0.1, hold=hold * 0.5 * BEAT)
            add(sig2, b0 + k * 0.5, gain * 0.35, -0.3, lead_bus)


for bar, ch in enumerate(PROG):
    sec = section(bar)
    if sec == "B":
        play_lead(bar, MEL[ch])
    elif sec == "drop":
        play_lead(bar, MEL[ch], gain=0.12, harmony=True)
    elif sec == "outro":
        play_lead(bar, RUN_G if bar == 23 else MEL[ch], gain=0.12, harmony=bar >= 22)
# 结尾长音
n = int(3.6 * SR)
sig = lp(pulse(mtof(84), n, 0.5) * 0.6 + sine(mtof(84), n) * 0.5, 3500) * env(n, 0.005, 0.4, 0.4, 1.6, hold=1.6)
add(sig, 96, 0.10, 0.1, lead_bus)


# ---------------------------------------------------------------- 鼓
def kick():
    n = int(0.45 * SR)
    t = np.arange(n) / SR
    f = 48 + 95 * np.exp(-t / 0.035)
    sig = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.28)
    click = lp(noise(n), 4000) * np.exp(-t / 0.004) * 0.4
    return np.tanh((sig + click) * 1.4)


def snare():
    n = int(0.3 * SR)
    t = np.arange(n) / SR
    return bp(noise(n), 1500, 7000) * np.exp(-t / 0.12) * 0.8 + np.sin(2 * np.pi * 190 * t) * np.exp(-t / 0.05) * 0.5


def clap():
    n = int(0.35 * SR)
    t = np.arange(n) / SR
    e = np.zeros(n)
    for off in (0, 0.011, 0.022):
        e += np.where(t >= off, np.exp(-(t - off) / 0.008), 0)
    e += np.where(t >= 0.03, np.exp(-(t - 0.03) / 0.12) * 0.6, 0)
    return bp(noise(n), 900, 3200) * e


def hat(open_=False):
    n = int((0.3 if open_ else 0.06) * SR)
    t = np.arange(n) / SR
    return hp(noise(n), 7500) * np.exp(-t / (0.12 if open_ else 0.018))


K, SN, CL, HC, HO = kick(), snare(), clap(), hat(), hat(True)
kick_times = []

for bar in range(len(PROG)):
    b0 = bar * 4
    sec = section(bar)
    if sec in ("intro", "end"):
        continue
    if sec == "A":
        for k in (0, 2):
            add(K, b0 + k, 0.85); kick_times.append(b0 + k)
        if bar % 2 == 1:
            add(K, b0 + 2.75, 0.55); kick_times.append(b0 + 2.75)
        for k in range(8):
            add(HC, b0 + k * 0.5, 0.16 if k % 2 else 0.09, 0.3)
        if bar >= 4:
            for k in (1, 3):
                add(SN, b0 + k, 0.33, -0.05)
        if bar == 7:
            for k in range(4):
                add(SN, b0 + 3 + k * 0.25, 0.12 + 0.05 * k, -0.05)
    elif sec in ("B", "drop", "outro"):
        for k in range(4):
            add(K, b0 + k, 0.9); kick_times.append(b0 + k)
        for k in (1, 3):
            add(CL, b0 + k, 0.36, 0.08)
            add(SN, b0 + k, 0.18, -0.05)
        for k in range(16):
            if k % 4 == 2:
                add(HO, b0 + k * 0.25, 0.10, 0.25)
            else:
                add(HC, b0 + k * 0.25, 0.10 if k % 2 == 0 else 0.06, 0.3)
        if bar == 23:
            for k in range(8):
                add(SN, b0 + 2 + k * 0.25, 0.10 + 0.03 * k, -0.05)
    elif sec == "break":
        add(K, b0, 0.6); kick_times.append(b0)
        if bar == 16:
            for k in range(8):
                add(SN, b0 + k * 0.5, 0.06 + 0.02 * k, -0.05)
            for k in range(8):
                add(SN, b0 + 2 + k * 0.25, 0.12 + 0.03 * k, -0.05)

# ---------------------------------------------------------------- sidechain
duck = np.ones(N)
t_ax = np.arange(N) / SR
for kb in kick_times:
    t0 = kb * BEAT
    i0 = s(kb)
    i1 = min(N, i0 + int(0.35 * SR))
    tt = t_ax[i0:i1] - t0
    duck[i0:i1] = np.minimum(duck[i0:i1], 1 - 0.55 * np.exp(-tt / 0.11))
for bus in (pad_bus, bass_bus, arp_bus):
    L += bus[0] * duck
    R += bus[1] * duck
L += lead_bus[0] * (0.6 + 0.4 * duck)
R += lead_bus[1] * (0.6 + 0.4 * duck)

# 琶音 / 旋律的 3/8 拍乒乓延迟
d = s(0.75)
for bus, g in ((arp_bus, 0.28), (lead_bus, 0.22)):
    L[d:] += bus[1][:-d] * g
    R[2 * d:] += bus[0][:-2 * d] * g * 0.7


# ---------------------------------------------------------------- 音效（与画面卡点）
def fx_whoosh():
    n = int(0.5 * SR)
    t = np.arange(n) / SR
    e = np.sin(np.pi * np.clip(t / 0.5, 0, 1)) ** 2
    return bp(noise(n), 400, 5000) * e


def fx_impact():
    n = int(1.6 * SR)
    t = np.arange(n) / SR
    boom = np.sin(2 * np.pi * np.cumsum(40 + 60 * np.exp(-t / 0.08)) / SR) * np.exp(-t / 0.5)
    crash = hp(noise(n), 3000) * np.exp(-t / 0.6) * 0.35
    return np.tanh(boom * 1.2) + crash


def fx_pop(pitch=0):
    n = int(0.16 * SR)
    t = np.arange(n) / SR
    f = mtof(84 + pitch) * (1 + 0.5 * np.exp(-t / 0.01))
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.05)


def fx_boing():
    n = int(0.35 * SR)
    t = np.arange(n) / SR
    f = 330 * (1 + 0.45 * np.sin(2 * np.pi * 14 * t) * np.exp(-t / 0.12)) * (1 + 0.6 * np.exp(-t / 0.03))
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.12)


def fx_bloop():
    n = int(0.3 * SR)
    t = np.arange(n) / SR
    f = 950 * np.exp(-t / 0.08) + 180
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.12)


def fx_click():
    n = int(0.05 * SR)
    t = np.arange(n) / SR
    return (hp(noise(n), 3000) * np.exp(-t / 0.003) * 0.7 + np.sin(2 * np.pi * 2200 * t) * np.exp(-t / 0.01) * 0.4)


def fx_shimmer():
    n = int(1.4 * SR)
    out = np.zeros(n)
    for k, m in enumerate([84, 88, 91, 96, 100]):
        off = int(k * 0.05 * SR)
        nn = n - off
        t = np.arange(nn) / SR
        out[off:] += np.sin(2 * np.pi * mtof(m) * t) * np.exp(-t / 0.45) * (1 + 0.3 * np.sin(2 * np.pi * 6 * t)) * 0.3
    return out


def load_wav(name):
    sr, data = wavfile.read(os.path.join(ROOT, "Resources", "Sounds", name))
    x = data.astype(np.float64) / 32768.0
    return x if x.ndim == 1 else x.mean(axis=1)


DING, DONG = load_wav("success.wav"), load_wav("failure.wav")

# 每种音效的 (信号, 音量, 声像)
for c in TL["cues"]:
    b, kind = c["beat"], c["type"]
    if kind == "whoosh": add(fx_whoosh(), b - 0.25, 0.22, 0.0)
    elif kind == "impact": add(fx_impact(), b, 0.55, 0.0)
    elif kind == "pop": add(fx_pop(c.get("pitch", 0)), b, 0.22, 0.15)
    elif kind == "boing": add(fx_boing(), b, 0.18, -0.15)
    elif kind == "bloop": add(fx_bloop(), b, 0.22, 0.0)
    elif kind == "click": add(fx_click(), b, 0.25, 0.2)
    elif kind == "shimmer": add(fx_shimmer(), b, 0.22, 0.0)
    elif kind == "ding": add(DING, b, 0.75, 0.0)
    elif kind == "dong": add(DONG, b, 0.75, 0.0)

# 开头 riser（第 5–8 拍）
n = s(3)
t = np.arange(n) / SR
riser = hp(noise(n), 2000) * (t / t[-1]) ** 2 * 0.35 + np.sin(2 * np.pi * np.cumsum(200 * 2 ** (t / t[-1] * 2.5)) / SR) * (t / t[-1]) ** 3 * 0.15
add(riser, 5, 0.6)
# 掉落前 riser（第 64–68 拍）
n = s(4)
t = np.arange(n) / SR
add(hp(noise(n), 1500) * (t / t[-1]) ** 2.5 * 0.4, 64, 0.5)

# ---------------------------------------------------------------- 母带
mix = np.stack([L, R])
mix = hp(mix, 28)
mix = np.tanh(mix * 1.3) / np.tanh(1.3)
mix *= 0.9 / np.max(np.abs(mix))
fade_in = np.clip(np.arange(N) / (0.03 * SR), 0, 1)
fade_out = np.clip((N - np.arange(N)) / (1.2 * SR), 0, 1)
mix *= fade_in * fade_out

os.makedirs(OUT, exist_ok=True)
wavfile.write(os.path.join(OUT, "music.wav"), SR, (mix.T * 32767).astype(np.int16))
print(f"wrote promo/out/music.wav · {N / SR:.1f}s · {BPM} BPM · {len(TL['cues'])} cues")
