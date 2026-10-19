#!/usr/bin/env python3
"""README 用的图片：把 `--render-preview` 的面板截图（SI_BARE=1，透明背景）摆进统一的画面里。

    python3 scripts/readme_compose.py <bare 截图目录> <en|zh> [Windows 版截图目录]

输出（都是 2 倍图，PNG，圆角外透明，在 GitHub 浅色 / 深色主题下都好看）：
- docs/hero-<lang>.png               顶部大图：夜空 + 一台 Mac，刘海里展开的面板，旁边一条"完成"提示
- docs/screenshots/<lang>/<名字>.png 截图：统一 1600×1000 的壁纸画面，面板挂在刘海下（和真机一样），设置窗口居中
只用演示数据（DemoData），不会出现真实的用户名、主机、路径。
"""
import glob
import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

SRC, LANG = sys.argv[1], sys.argv[2]
CROSS = sys.argv[3] if len(sys.argv) > 3 else None
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(ROOT, "docs", "screenshots", LANG)
os.makedirs(OUT, exist_ok=True)
ZH = LANG == "zh"


def font(size, weight="regular"):
    """中文用苹方（找不到就用冬青黑体），英文用 SF。"""
    if ZH:
        cands = glob.glob("/System/Library/AssetsV2/*/*/AssetData/PingFang.ttc") + ["/System/Library/Fonts/Hiragino Sans GB.ttc"]
        idx = {"regular": 0, "medium": 4, "bold": 8}.get(weight, 0) if "PingFang" in cands[0] else 0
        try:
            return ImageFont.truetype(cands[0], size, index=idx)
        except OSError:
            return ImageFont.truetype(cands[0], size)
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    try:
        f.set_variation_by_name({"regular": "Regular", "medium": "Medium", "bold": "Bold"}[weight])
    except Exception:
        pass
    return f


def lerp(a, b, k):
    return a + (b - a) * k


def hex2rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def gradient(w, h, stops, angle=0.0):
    """多段线性渐变；angle：0 = 从上到下，正值向右倾斜。用小图放大，速度快也足够平滑。"""
    sw, sh = max(2, w // 8), max(2, h // 8)
    im = Image.new("RGB", (sw, sh))
    px = im.load()
    ca, sa = math.cos(angle), math.sin(angle)
    cols = [(p, hex2rgb(c)) for p, c in stops]
    for y in range(sh):
        for x in range(sw):
            t = ((y / (sh - 1)) * ca + (x / (sw - 1)) * sa) / (ca + abs(sa))
            t = min(1, max(0, t))
            for i in range(1, len(cols)):
                if t <= cols[i][0]:
                    p0, c0 = cols[i - 1]; p1, c1 = cols[i]
                    k = (t - p0) / max(1e-6, p1 - p0)
                    px[x, y] = tuple(int(lerp(c0[j], c1[j], k)) for j in range(3))
                    break
            else:
                px[x, y] = cols[-1][1]
    return im.resize((w, h), Image.BICUBIC).convert("RGBA")


def glow(base, cx, cy, r, color, alpha):
    """柔和的圆形光斑（和 App / 官网的壁纸一样的感觉）。"""
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=hex2rgb(color) + (alpha,))
    layer = layer.filter(ImageFilter.GaussianBlur(r * 0.55))
    base.alpha_composite(layer)


def wallpaper(w, h, seed=0):
    """App 演示里那张紫到橙的壁纸。"""
    im = gradient(w, h, [(0, "#3C4C8F"), (0.45, "#8D6FB1"), (0.75, "#D99A9C"), (1, "#F2C89A")], angle=0.35)
    rnd = random.Random(seed)
    for col, a in [("#5A82FF", 110), ("#FF96C8", 80), ("#FFC88C", 90), ("#7A5AC8", 80)]:
        glow(im, rnd.uniform(0.1, 0.9) * w, rnd.uniform(0.1, 0.9) * h, rnd.uniform(0.25, 0.4) * max(w, h), col, a)
    return im


def rounded(im, r):
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, im.width - 1, im.height - 1), r, fill=255)
    out = Image.new("RGBA", im.size, (0, 0, 0, 0))
    out.paste(im, (0, 0), mask)
    return out


def shadow(base, img, x, y, blur=40, offset=18, alpha=150):
    sh = Image.new("RGBA", base.size, (0, 0, 0, 0))
    a = img.split()[3].point(lambda v: v * alpha // 255)
    sh.paste((0, 0, 0, 255), (x, y + offset), a)
    base.alpha_composite(sh.filter(ImageFilter.GaussianBlur(blur)))


def menubar(base, h, notch_w=None, dark_text=False):
    """半透明菜单栏；左边 Finder 菜单，右边时间。刘海由面板自己的形状画出来。"""
    bar = Image.new("RGBA", (base.width, h), (255, 255, 255, 52))
    base.alpha_composite(bar, (0, 0))
    d = ImageDraw.Draw(base)
    fs = int(h * 0.42)
    y = h / 2
    x = int(h * 0.75)
    d.text((x, y), "", font=ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", int(fs * 1.15)), fill="white", anchor="lm")
    x += int(fs * 1.9)
    items = ["访达", "文件", "编辑", "显示"] if ZH else ["Finder", "File", "Edit", "View"]
    for i, s in enumerate(items):
        f = font(fs, "bold" if i == 0 else "regular")
        d.text((x, y), s, font=f, fill="white", anchor="lm")
        x += int(d.textlength(s, font=f) + fs * 1.3)
    clock = "10月19日 周一 14:26" if ZH else "Mon Oct 19  14:26"
    d.text((base.width - int(h * 0.75), y), clock, font=font(fs), fill="white", anchor="rm")


def load(name, src=None):
    im = Image.open(os.path.join(src or SRC, name + ".png")).convert("RGBA")
    box = im.split()[3].getbbox()
    return im.crop(box) if box else im


def trim_bottom(p, keep=40, radius=52):
    """详情页 / 分区页的高度是固定的，内容少时下面一大片黑。裁到内容下方 keep 像素，再把底部两个角做圆。"""
    rgb = p.convert("RGB")
    w, h = p.size
    px = rgb.load()
    alpha = p.split()[3]
    # 面板主体的左右边界（取中间一行：顶部两侧是刘海的"耳朵"，底部那一行已经是圆角）
    row = [alpha.getpixel((x, h // 2)) for x in range(w)]
    xs = [x for x, v in enumerate(row) if v > 200]
    if not xs:
        return p
    x0, x1 = xs[0], xs[-1]
    last = 0
    for y in range(h - 1, 0, -1):
        if any(sum(px[x, y]) > 90 for x in range(x0 + 24, x1 - 24, 3)):
            last = y
            break
    cut = last + keep
    if h - cut < 80:
        return p
    out = p.crop((0, 0, w, cut))
    mask = out.split()[3]
    body = Image.new("L", out.size, 0)
    ImageDraw.Draw(body).rounded_rectangle((x0, -400, x1, cut - 1), radius, fill=255)
    top = Image.new("L", out.size, 0)
    ImageDraw.Draw(top).rectangle((0, 0, w, cut - radius - 2), fill=255)
    from PIL import ImageChops
    mask = ImageChops.multiply(mask, ImageChops.lighter(top, body))
    out.putalpha(mask)
    return out


def fit(im, maxw, maxh):
    k = min(maxw / im.width, maxh / im.height, 1.0)
    return im.resize((round(im.width * k), round(im.height * k)), Image.LANCZOS) if k < 1 else im


# 截图的统一尺寸（2 倍图，README 里两列并排时每张约 430 点宽）
TW, TH, R = 1600, 1000, 34
MB = 52  # 菜单栏高度


def tile_panel(name, seed, panel=None, maxh=None, trim=True):
    """刘海里的面板：挂在画面顶部正中，耳朵和菜单栏连在一起，四周留出壁纸。"""
    bg = wallpaper(TW, TH, seed)
    menubar(bg, MB)
    p = panel or load(name)
    if trim:
        p = trim_bottom(p)
    p = fit(p, TW - 340, maxh or (TH - 110))
    x = (TW - p.width) // 2
    shadow(bg, p, x, 0, blur=36, offset=16, alpha=170)
    bg.alpha_composite(p, (x, 0))
    return rounded(bg, R)


def tile_window(name, seed, crop=None):
    """设置窗口：居中，带窗口阴影。"""
    bg = wallpaper(TW, TH, seed)
    menubar(bg, MB)
    w = load(name)
    if crop:
        w = w.crop(crop(w))
    w = rounded(w, 22)
    w = fit(w, TW - 200, TH - MB - 90)
    x, y = (TW - w.width) // 2, MB + (TH - MB - w.height) // 2 + 6
    shadow(bg, w, x, y, blur=40, offset=20, alpha=150)
    bg.alpha_composite(w, (x, y))
    return rounded(bg, R)


def tile_alerts(seed):
    """两条提示上下各占一半：上面"完成"，下面"失败"。"""
    bg = Image.new("RGBA", (TW, TH), (0, 0, 0, 0))
    half = (TH - 16) // 2
    for i, name in enumerate(["toast", "toast-failed"]):
        part = wallpaper(TW, half, seed + i)
        menubar(part, MB)
        t = fit(load(name), TW - 300, half - 40)
        t = t.resize((round(t.width * 1.25), round(t.height * 1.25)), Image.LANCZOS) if t.width * 1.25 < TW - 200 else t
        x = (TW - t.width) // 2
        shadow(part, t, x, 0, blur=30, offset=14, alpha=170)
        part.alpha_composite(t, (x, 0))
        bg.alpha_composite(rounded(part, R), (0, i * (half + 16)))
    return bg


def save(im, name):
    path = os.path.join(OUT, name + ".png")
    # 缩到 1.5 倍图，文件小一半，README 里依然清晰
    im = im.resize((im.width * 3 // 4, im.height * 3 // 4), Image.LANCZOS)
    im.save(path, optimize=True)
    print("wrote", os.path.relpath(path, ROOT))


# ------------------------------------------------------------------ 截图
save(tile_panel("expanded", 1, trim=False), "expanded")
save(tile_panel("detail-nep", 2), "detail-nep")
save(tile_panel("detail-vasp-cg", 3), "detail-vasp-relax")
save(tile_panel("detail-neb", 4), "detail-neb")
save(tile_panel("partitions", 6), "partitions")
save(tile_panel("history", 7), "history")
save(tile_alerts(8), "alerts")
save(tile_window("settings-rule-editor", 9), "settings-rule-editor")
save(tile_window("settings-host", 11), "settings-host")


def tile_windows(src):
    """Windows / Linux 版的桌面小章鱼（cross 的 --render-preview 只有 1 倍图，所以这张按 1 倍合成：800×500）。
    背景用它自己的桌面放大模糊后铺满，原图居中、边缘羽化，看不出接缝。"""
    w, h = TW // 2, TH // 2
    im = Image.open(os.path.join(src, "cross-pet.png")).convert("RGBA")
    bg = im.resize((w, h), Image.BICUBIC).filter(ImageFilter.GaussianBlur(30))
    k = min((w - 40) / im.width, (h - 16) / im.height, 1.0)
    if k < 1:
        im = im.resize((round(im.width * k), round(im.height * k)), Image.LANCZOS)
    m = Image.new("L", im.size, 0)
    ImageDraw.Draw(m).rectangle((18, 18, im.width - 19, im.height - 19), fill=255)
    m = m.filter(ImageFilter.GaussianBlur(10))
    bg.paste(im, ((w - im.width) // 2, (h - im.height) // 2), m)
    out = rounded(bg, R // 2)
    path = os.path.join(OUT, "windows-pet.png")
    out.save(path, optimize=True)
    print("wrote", os.path.relpath(path, ROOT))


if CROSS and os.path.exists(os.path.join(CROSS, "cross-pet.png")):
    tile_windows(CROSS)

# ------------------------------------------------------------------ 顶部大图
# 左边一列讲"收起 → 提醒 → 悬停展开"，右边是一台 Mac，刘海里展开着面板（代替原来那张卡顿的动图）。
HEAD = ["......BBBB......", "....BBBBBBBB....", "...BHHBBBBBBB...", "..BHHBBBBBBBBB..", "..BHBBBBBBBBBB..",
        ".BBBBBBBBBBBBBB.", ".BBBBBBBBBBBBBB.", ".BBBBBBBBBBBBBB.", ".BBBBBBBBBBBBBB.", "..SBBBBBBBBBBS.."]
LEGS = [".SBB.BB..BB.BBS.", ".BB..BB..BB..BB.", "BB..BB....BB..BB", "B...B......B...B"]
TCOL = {"B": "#5CE6B5", "S": "#2EAD87", "H": "#BDF9DF", "E": "#0A0F1F", "W": "#FFFFFF", "C": "#FF8FAB", "M": "#0A0F1F"}


def tako(px):
    """和 App 的 Pet.swift 同一张 16×14 网格（idle 表情），每格 px 像素。"""
    g = [list(r) for r in HEAD + LEGS]
    for c in (4, 10):
        g[6][c], g[6][c + 1], g[7][c], g[7][c + 1] = "W", "E", "E", "E"
    g[8][3] = g[8][12] = "C"
    g[8][7] = g[8][8] = "M"
    im = Image.new("RGBA", (16 * px, 14 * px), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    for r in range(14):
        for c in range(16):
            ch = g[r][c]
            if ch != ".":
                d.rectangle((c * px, r * px, c * px + px - 1, r * px + px - 1), fill=TCOL[ch])
    glow_l = Image.new("RGBA", (im.width + 80, im.height + 80), (0, 0, 0, 0))
    a = im.split()[3].point(lambda v: v * 120 // 255)
    glow_l.paste((91, 230, 181, 255), (40, 40), a)
    glow_l = glow_l.filter(ImageFilter.GaussianBlur(22))
    glow_l.alpha_composite(im, (40, 40))
    return glow_l


HW, HH = 2600, 1320
hero = gradient(HW, HH, [(0, "#121836"), (0.6, "#112B4A"), (1, "#0D4A57")])
glow(hero, HW * 0.62, HH * 0.6, HH * 0.6, "#5BE6B5", 55)
rnd = random.Random(42)
dots = Image.new("RGBA", hero.size, (0, 0, 0, 0))
d = ImageDraw.Draw(dots)
for i in range(130):
    x, y, sz = rnd.uniform(0, HW), rnd.uniform(0, HH * 0.8), rnd.choice([3, 4, 5, 6])
    d.rectangle((x, y, x + sz, y + sz), fill=(255, 255, 255, rnd.randint(60, 170)))
# 像素海浪（和官网、logo 同一个风格）
for row in range(3):
    y0 = HH - 140 + row * 40
    col = [(127, 216, 255, 70), (91, 230, 181, 45), (91, 230, 181, 26)][row]
    for k, x in enumerate(range(-60 + row * 20, HW + 60, 60)):
        dy = 14 if k % 4 in (1, 2) else 0
        d.rounded_rectangle((x, y0 + dy, x + 40, y0 + dy + 16), 3, fill=col)
hero.alpha_composite(dots)

# 右边：Mac 屏幕（壁纸 + 菜单栏 + 刘海里展开的面板）
SWd, SHd = 1480, 990
scr = wallpaper(SWd, SHd, 21)
menubar(scr, 56)
panel = fit(load("expanded"), SWd - 230, SHd - 30)
px0 = (SWd - panel.width) // 2
shadow(scr, panel, px0, 0, blur=40, offset=18, alpha=180)
scr.alpha_composite(panel, (px0, 0))
scr = rounded(scr, 26)
bez = 22
frame = Image.new("RGBA", (SWd + bez * 2, SHd + bez * 2), (0, 0, 0, 0))
ImageDraw.Draw(frame).rounded_rectangle((0, 0, frame.width - 1, frame.height - 1), 44, fill=(12, 12, 14, 255), outline=(255, 255, 255, 30), width=2)
frame.alpha_composite(scr, (bez, bez))
fx, fy = HW - frame.width - 120, (HH - frame.height) // 2 - 30
shadow(hero, frame, fx, fy, blur=60, offset=30, alpha=210)
hero.alpha_composite(frame, (fx, fy))

# 左边：三步
lx, colw = 130, fx - 130 - 110
steps = [("收起时", "Collapsed", "刘海两边：Tako、运行数和进度", "Tako, running jobs and progress beside the notch"),
         ("有事时", "When something happens", "完成叮咚，失败咚咚", "a chime when done, another when it fails"),
         ("悬停时", "On hover", "所有服务器的任务一眼看完  →", "every job on every server  →")]
d = ImageDraw.Draw(hero)
y = fy + 30
imgs = [fit(load("collapsed"), colw, 90), fit(rounded(load("toast"), 40), colw, 260), None]
for i, (zt, et, zs, es) in enumerate(steps):
    # 编号
    badge = Image.new("RGBA", hero.size, (0, 0, 0, 0))
    ImageDraw.Draw(badge).rounded_rectangle((lx, y, lx + 64, y + 44), 22, fill=(91, 230, 181, 48))
    hero.alpha_composite(badge)
    d = ImageDraw.Draw(hero)
    d.text((lx + 32, y + 22), str(i + 1), font=ImageFont.truetype("/System/Library/Fonts/SFNSMono.ttf", 28), fill="#5BE6B5", anchor="mm")
    d.text((lx + 84, y + 22), zt if ZH else et, font=font(40, "bold"), fill="white", anchor="lm")
    d.text((lx + 84, y + 74), zs if ZH else es, font=font(28), fill=(255, 255, 255, 170), anchor="lm")
    y += 116
    im = imgs[i]
    if im is not None:
        # 收起状态和提示本来贴着菜单栏，这里单独展示时给它们补上圆角和阴影
        im = rounded(im, 22 if i == 0 else 40)
        shadow(hero, im, lx, y, blur=24, offset=12, alpha=200)
        hero.alpha_composite(im, (lx, y))
        y += im.height + 70
t = tako(9)
hero.alpha_composite(t, (lx - 40, HH - t.height - 130))
hero = rounded(hero, 40)
hero = hero.resize((HW * 3 // 4, HH * 3 // 4), Image.LANCZOS)
hp = os.path.join(ROOT, "docs", f"hero-{LANG}.png")
hero.save(hp, optimize=True)
print("wrote", os.path.relpath(hp, ROOT))
