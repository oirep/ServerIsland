#!/usr/bin/env python3
"""ServerIsland 使用教程的声音：中文配音 + 背景音乐 + 音效。

1. 读 script.js，用 edge-tts（微软神经网络语音）逐句合成配音（按文本缓存在 out/tutorial/tts/）；
2. 按每句的实际时长排出时间轴，写进 timing.js（画面读它来对齐动画和字幕）；
3. 合成一段轻柔的 chiptune 背景音乐，配音出现时自动压低（ducking）；
4. 叠加音效（叮咚 / 咚咚直接用 App 自己的 Resources/Sounds），输出 out/tutorial/audio.wav。

    python3 promo/tutorial/audio.py
"""
import hashlib
import json
import os
import re
import subprocess

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, sosfilt

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(HERE, "..", "out", "tutorial")
TTS_DIR = os.path.join(OUT, "tts")
os.makedirs(TTS_DIR, exist_ok=True)

src = open(os.path.join(HERE, "script.js"), encoding="utf-8").read()
m = re.search(r"SCRIPT_JSON_BEGIN\s*window\.SCRIPT\s*=\s*(\{.*\})\s*//\s*SCRIPT_JSON_END", src, re.S)
SC = json.loads(m.group(1))

SR = 44100
rng = np.random.default_rng(11)


# ---------------------------------------------------------------- 配音
# engine = "edge"：微软的神经网络语音（edge-tts，需要联网；`pip install edge-tts`，或用 EDGE_TTS 指定可执行文件）。
#          自然、有语气，默认用 zh-CN-XiaoxiaoNeural。
# engine = "say"：macOS 自带的 say（离线，但一个字一个字地念，只作为没有网络时的后备）。
EDGE = os.environ.get("EDGE_TTS", "edge-tts")


def tts(text):
    """合成一句，返回单声道 float 数组。按 (引擎, 声音, 语速, 文本) 缓存。"""
    eng = SC.get("engine", "say")
    voice, rate = (SC["voice"], SC["rate"]) if eng == "edge" else (SC["sayVoice"], SC["sayRate"])
    key = hashlib.sha1(f"{eng}|{voice}|{rate}|{text}".encode()).hexdigest()[:16]
    wav = os.path.join(TTS_DIR, key + ".wav")
    if not os.path.exists(wav):
        raw = os.path.join(TTS_DIR, key + (".mp3" if eng == "edge" else ".aiff"))
        if eng == "edge":
            subprocess.run([EDGE, "--voice", voice, f"--rate={rate}", "--text", text, "--write-media", raw], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            subprocess.run(["say", "-v", voice, "-r", str(rate), "-o", raw, text], check=True)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", raw, "-ac", "1", "-ar", str(SR), wav], check=True)
        os.remove(raw)
    sr, d = wavfile.read(wav)
    x = d.astype(np.float64) / 32768.0
    # 去掉首尾的静音，时长才准
    nz = np.nonzero(np.abs(x) > 0.004)[0]
    x = x[nz[0]:nz[-1] + 1] if len(nz) else x
    # 首尾各 15 毫秒淡入淡出，避免咔哒声
    f = min(len(x) // 2, int(0.015 * SR))
    x[:f] *= np.linspace(0, 1, f); x[-f:] *= np.linspace(1, 0, f)
    return x


voices = {}
timing = {"chapters": [], "lines": {}, "cues": []}
t = 0.0
for ch in SC["chapters"]:
    c0 = t
    t += ch.get("lead", 0.8)
    for ln in ch["lines"]:
        t += ln.get("gap", 0.0)
        v = tts(ln.get("tts", ln["text"]))
        dur = len(v) / SR
        voices[ln["id"]] = (t, v)
        slot = max(dur, ln.get("min", 0))
        timing["lines"][ln["id"]] = {"start": round(t, 3), "dur": round(dur, 3), "end": round(t + slot, 3),
                                     "text": ln["text"], "chapter": ch["id"]}
        over = "" if dur <= ln.get("min", 0) else f"  (比 min 长 {dur - ln.get('min', 0):.2f}s)"
        print(f"{ln['id']:>3}  {t:6.2f}s  语音 {dur:4.2f}s  占 {slot:4.2f}s{over}")
        t += slot + SC["lineGap"]
    t += ch.get("tail", 0.5) - SC["lineGap"]
    timing["chapters"].append({"id": ch["id"], "title": ch["title"], "from": round(c0, 3), "to": round(t, 3)})
TOTAL = t
timing["total"] = round(TOTAL, 3)
for c in SC["cues"]:
    timing["cues"].append({"t": round(timing["lines"][c["at"]]["start"] + c["off"], 3), "type": c["type"], "dur": c.get("dur", 0)})

with open(os.path.join(HERE, "timing.js"), "w", encoding="utf-8") as f:
    f.write("// 由 audio.py 生成，不要手改：每句旁白的起止时间（秒）、各章节的范围、音效时刻。\n")
    f.write("window.TIMING = " + json.dumps(timing, ensure_ascii=False, indent=1) + ";\n")
print(f"总长 {TOTAL:.1f}s（{int(TOTAL // 60)}:{TOTAL % 60:04.1f}）")

N = int((TOTAL + 0.5) * SR)


# ---------------------------------------------------------------- 合成工具（和 ../music.py 同一套写法）
def mtof(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def lp(x, hz, order=2):
    return sosfilt(butter(order, min(hz, SR * 0.45), "low", fs=SR, output="sos"), x)


def hp(x, hz, order=2):
    return sosfilt(butter(order, hz, "high", fs=SR, output="sos"), x)


def bp(x, lo, hi, order=2):
    return sosfilt(butter(order, [lo, hi], "band", fs=SR, output="sos"), x)


def noise(n):
    return rng.uniform(-1, 1, n)


def phase(f, n, det=0.0):
    return np.cumsum(np.full(n, f * 2 ** (det / 1200) / SR)) % 1.0


def add(buf, sig, t0, gain=1.0, pan=0.0):
    i = int(round(t0 * SR))
    if i < 0:
        sig, i = sig[-i:], 0
    if i >= N:
        return
    sig = sig[: N - i] * gain
    buf[0][i:i + len(sig)] += sig * np.cos((pan + 1) * np.pi / 4) * 1.4142
    buf[1][i:i + len(sig)] += sig * np.sin((pan + 1) * np.pi / 4) * 1.4142


# ---------------------------------------------------------------- 背景音乐：92 BPM，C 大调 I–V–vi–IV，轻柔不抢话
BPM = 92
BEAT = 60 / BPM
BAR = 4 * BEAT
MUS = (np.zeros(N), np.zeros(N))
CHORDS = {"C": ([60, 64, 67, 71], 36), "G": ([59, 62, 67, 69], 43), "Am": ([57, 60, 64, 67], 45), "F": ([57, 60, 65, 69], 41)}
PROG = ["C", "G", "Am", "F"]
bars = int(TOTAL / BAR) + 2
for b in range(bars):
    t0 = b * BAR
    notes, root = CHORDS[PROG[b % 4]]
    n = int(BAR * SR) + int(0.6 * SR)
    tt = np.arange(n) / SR
    e = np.clip(tt / 0.4, 0, 1) * np.clip((BAR + 0.6 - tt) / 0.6, 0, 1)
    pad = sum(2 * phase(mtof(m), n, d) - 1 for m in notes for d in (-7, 7)) / 8
    add(MUS, lp(pad, 900) * e, t0, 0.10)
    # 贝斯：每拍一个柔和的正弦
    for k in range(4):
        nn = int(BEAT * SR)
        tb = np.arange(nn) / SR
        add(MUS, np.sin(2 * np.pi * mtof(root) * tb) * np.exp(-tb / 0.35), t0 + k * BEAT, 0.16)
    # 琶音：三角波拨弦，8 分音符
    arp = [notes[0] + 12, notes[1] + 12, notes[2] + 12, notes[3] + 12, notes[2] + 12, notes[1] + 12, notes[2] + 12, notes[3] + 12]
    for k, mm in enumerate(arp):
        nn = int(0.5 * SR)
        tb = np.arange(nn) / SR
        p = phase(mtof(mm), nn)
        tone = (4 * np.abs(p - 0.5) - 1) * np.exp(-tb / 0.16)
        add(MUS, tone, t0 + k * BEAT / 2, 0.05, 0.3 if k % 2 else -0.3)
    # 鼓：很轻的 kick（1、3 拍）+ 反拍闭镲
    for k in range(4):
        if k % 2 == 0:
            nn = int(0.3 * SR)
            tb = np.arange(nn) / SR
            kick = np.sin(2 * np.pi * np.cumsum(45 + 90 * np.exp(-tb / 0.03)) / SR) * np.exp(-tb / 0.12)
            add(MUS, kick, t0 + k * BEAT, 0.20)
        nn = int(0.06 * SR)
        hat = hp(noise(nn), 7000) * np.exp(-np.arange(nn) / SR / 0.015)
        add(MUS, hat, t0 + k * BEAT + BEAT / 2, 0.035, 0.2)

# 开头淡入、结尾淡出
fade = np.ones(N)
fi = int(1.2 * SR)
fade[:fi] = np.linspace(0, 1, fi)
fo = int(3.0 * SR)
fade[-fo:] = np.linspace(1, 0, fo) ** 1.5
for ch in MUS:
    ch *= fade

# ---------------------------------------------------------------- 配音轨 + ducking
VOX = np.zeros(N)
for _, (t0, v) in voices.items():
    i = int(round(t0 * SR))
    VOX[i:i + len(v)] += v[: N - i]
VOX *= 0.9 / max(1e-9, np.max(np.abs(VOX)))
# 包络：有声的地方音乐压到 40%，前后各留 0.25 秒的过渡
act = (np.abs(VOX) > 0.02).astype(float)
win = int(0.35 * SR)
act = np.convolve(act, np.ones(win) / win, mode="same") > 0.001
duck = act.astype(float)
sm = int(0.25 * SR)
duck = np.convolve(duck, np.ones(sm) / sm, mode="same")
mgain = 1 - 0.6 * np.clip(duck, 0, 1)


# ---------------------------------------------------------------- 音效
def fx_whoosh():
    n = int(0.5 * SR)
    t = np.arange(n) / SR
    return bp(noise(n), 400, 5000) * np.sin(np.pi * np.clip(t / 0.5, 0, 1)) ** 2


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


def fx_click():
    n = int(0.05 * SR)
    t = np.arange(n) / SR
    return hp(noise(n), 3000) * np.exp(-t / 0.003) * 0.7 + np.sin(2 * np.pi * 2200 * t) * np.exp(-t / 0.01) * 0.4


def fx_key():
    n = int(0.035 * SR)
    t = np.arange(n) / SR
    return bp(noise(n), 1500, 6000) * np.exp(-t / 0.006)


def fx_shimmer():
    n = int(1.4 * SR)
    out = np.zeros(n)
    for k, mm in enumerate([84, 88, 91, 96, 100]):
        off = int(k * 0.05 * SR)
        t = np.arange(n - off) / SR
        out[off:] += np.sin(2 * np.pi * mtof(mm) * t) * np.exp(-t / 0.45) * (1 + 0.3 * np.sin(2 * np.pi * 6 * t)) * 0.3
    return out


def fx_hold(dur):
    """按住确认：音高缓慢上升的柔和长音，结束时一声 pop。"""
    n = int(dur * SR)
    t = np.arange(n) / SR
    f = 440 * 2 ** (t / dur)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.clip(t / 0.05, 0, 1) * 0.5


def load_wav(name):
    sr, data = wavfile.read(os.path.join(ROOT, "Resources", "Sounds", name))
    x = data.astype(np.float64) / (32768.0 if data.dtype == np.int16 else 1.0)
    return x if x.ndim == 1 else x.mean(axis=1)


DING, DONG = load_wav("success.wav"), load_wav("failure.wav")
FX = (np.zeros(N), np.zeros(N))
pops = 0
for c in timing["cues"]:
    t0, kind = c["t"], c["type"]
    if kind == "whoosh": add(FX, fx_whoosh(), t0 - 0.2, 0.16)
    elif kind == "pop": add(FX, fx_pop([0, 4, 7, 12][pops % 4]), t0, 0.16, 0.15); pops += 1
    elif kind == "click": add(FX, fx_click(), t0, 0.22, 0.1)
    elif kind == "boing": add(FX, fx_boing(), t0, 0.16, -0.1)
    elif kind == "shimmer": add(FX, fx_shimmer(), t0, 0.22)
    elif kind == "ding": add(FX, DING, t0, 0.55)
    elif kind == "dong": add(FX, DONG, t0, 0.55)
    elif kind == "hold": add(FX, fx_hold(c["dur"]), t0, 0.06)
    elif kind == "type":
        k = 0
        while k * 0.11 < c["dur"]:
            add(FX, fx_key(), t0 + k * 0.11 + rng.uniform(-0.02, 0.02), 0.12, rng.uniform(-0.3, 0.3)); k += 1

# ---------------------------------------------------------------- 母带
Lc = MUS[0] * mgain + VOX * 1.0 + FX[0]
Rc = MUS[1] * mgain + VOX * 1.0 + FX[1]
mix = np.stack([Lc, Rc], axis=1)
mix = hp(mix.T, 30).T
mix = np.tanh(mix * 1.1) / np.tanh(1.1)
mix *= 0.9 / np.max(np.abs(mix))
wavfile.write(os.path.join(OUT, "audio.wav"), SR, (mix * 32767).astype(np.int16))
print("✓", os.path.join(OUT, "audio.wav"))
