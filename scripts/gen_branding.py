#!/usr/bin/env python3
"""从像素小章鱼 Tako 的网格生成 logo.svg 和 menubar.svg（与 App 内 Pet.swift 的造型保持一致）。

    python3 scripts/gen_branding.py
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

HEAD = [
    "......BBBB......",
    "....BBBBBBBB....",
    "...BHHBBBBBBB...",
    "..BHHBBBBBBBBB..",
    "..BHBBBBBBBBBB..",
    ".BBBBBBBBBBBBBB.",
    ".BBBBBBBBBBBBBB.",
    ".BBBBBBBBBBBBBB.",
    ".BBBBBBBBBBBBBB.",
    "..SBBBBBBBBBBS..",
]
LEGS = [
    ".SBB.BB..BB.BBS.",
    ".BB..BB..BB..BB.",
    "BB..BB....BB..BB",
    "B...B......B...B",
]


def sprite():
    g = [list(r) for r in HEAD + LEGS]
    # 眼睛（带高光）、腮红、小嘴
    for c in (4, 10):
        g[6][c], g[6][c + 1], g[7][c], g[7][c + 1] = "W", "E", "E", "E"
    g[8][3] = g[8][12] = "C"
    g[8][7] = g[8][8] = "M"
    return g


COLORS = {
    "B": "#5CE6B5", "S": "#2EAD87", "H": "#BDF9DF",
    "E": "#0A0F1F", "W": "#FFFFFF", "C": "#FF8FAB", "M": "#0A0F1F",
}


def rects(grid, x0, y0, px, colors, skip=(), bleed=0.6):
    out = []
    for r, row in enumerate(grid):
        for c, ch in enumerate(row):
            if ch == "." or ch in skip or ch not in colors:
                continue
            out.append(f'<rect x="{x0 + c * px:.1f}" y="{y0 + r * px:.1f}" width="{px + bleed:.1f}" '
                       f'height="{px + bleed:.1f}" fill="{colors[ch]}"/>')
    return "\n    ".join(out)


# 5x7 像素字体（只包含 "ServerIsland" 用到的字母），与 Tako 的像素风格一致，渲染不依赖系统字体。
FONT = {
    "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
    "e": [".....", ".....", ".###.", "#...#", "#####", "#....", ".###."],
    "r": [".....", ".....", "#.##.", "##..#", "#....", "#....", "#...."],
    "v": [".....", ".....", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
    "I": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "#####"],
    "s": [".....", ".....", ".####", "#....", ".###.", "....#", "####."],
    "l": [".##..", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "a": [".....", ".....", ".###.", "....#", ".####", "#...#", ".####"],
    "n": [".....", ".....", "#.##.", "##..#", "#...#", "#...#", "#...#"],
    "d": ["....#", "....#", ".##.#", "#..##", "#...#", "#...#", ".####"],
}


def text_cells(text, gap=1):
    """返回 [(列, 行)] 以及总列数。每个字母去掉左右空列，字间隔 gap 列。"""
    cells, x = [], 0
    for ch in text:
        g = FONT[ch]
        cols = [c for c in range(5) if any(row[c] == "#" for row in g)]
        lo, hi = min(cols), max(cols)
        for r, row in enumerate(g):
            for c in range(lo, hi + 1):
                if row[c] == "#":
                    cells.append((x + c - lo, r))
        x += hi - lo + 1 + gap
    return cells, x - gap


def logo():
    g = sprite()
    px = 26
    w = 16 * px
    x0 = 512 - w / 2
    y0 = 226
    # 文字：ServerIsland
    cells, cols = text_cells("ServerIsland")
    tp = 10
    tx0 = 512 - cols * tp / 2
    ty0 = 650
    word = "\n    ".join(f'<rect x="{tx0 + c * tp:.1f}" y="{ty0 + r * tp:.1f}" width="{tp + 0.5:.1f}" height="{tp + 0.5:.1f}"/>'
                         for c, r in cells)
    # 像素海浪：两行错落的小方块
    waves = []
    for i, x in enumerate(range(100, 924, 36)):
        y = 826 + (12 if i % 4 in (1, 2) else 0)
        waves.append(f'<rect x="{x}" y="{y}" width="24" height="12" rx="2" fill="#7FD8FF" opacity="0.30"/>')
    for i, x in enumerate(range(118, 924, 36)):
        y = 864 + (12 if i % 4 in (0, 3) else 0)
        waves.append(f'<rect x="{x}" y="{y}" width="24" height="12" rx="2" fill="#5CE6B5" opacity="0.16"/>')
    stars = "".join(
        f'<rect x="{x}" y="{y}" width="{s}" height="{s}" fill="#FFFFFF" opacity="{o}"/>'
        for x, y, s, o in [(214, 236, 10, 0.55), (800, 214, 8, 0.45), (752, 300, 6, 0.35),
                           (246, 452, 6, 0.3), (812, 470, 10, 0.4), (180, 560, 6, 0.3), (858, 360, 6, 0.3)])
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <!-- ServerIsland 图标：像素小章鱼 Tako + 像素字 ServerIsland。由 scripts/gen_branding.py 生成。 -->
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#151A3A"/>
      <stop offset="0.6" stop-color="#112B4A"/>
      <stop offset="1" stop-color="#0D4A57"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.4" r="0.42">
      <stop offset="0" stop-color="#5CE6B5" stop-opacity="0.40"/>
      <stop offset="1" stop-color="#5CE6B5" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="word" gradientUnits="userSpaceOnUse" x1="{tx0:.0f}" y1="0" x2="{tx0 + cols * tp:.0f}" y2="0">
      <stop offset="0" stop-color="#5CE6B5"/>
      <stop offset="1" stop-color="#7CCBFF"/>
    </linearGradient>
    <filter id="shadow" x="-20%" y="-40%" width="140%" height="200%">
      <feDropShadow dx="0" dy="16" stdDeviation="20" flood-color="#000" flood-opacity="0.55"/>
    </filter>
    <filter id="wordglow" x="-10%" y="-60%" width="120%" height="220%">
      <feDropShadow dx="0" dy="6" stdDeviation="10" flood-color="#000" flood-opacity="0.5"/>
    </filter>
    <clipPath id="squircle"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
  </defs>
  <g clip-path="url(#squircle)">
    <rect x="100" y="100" width="824" height="824" fill="url(#bg)"/>
    <rect x="100" y="100" width="824" height="824" fill="url(#glow)"/>
    {stars}
    {"".join(waves)}

    <!-- Tako -->
    <g filter="url(#shadow)">
    {rects(g, x0, y0, px, COLORS)}
    </g>
    <!-- ServerIsland -->
    <g fill="url(#word)" filter="url(#wordglow)">
    {word}
    </g>
  </g>
  <rect x="101.5" y="101.5" width="821" height="821" rx="184" fill="none" stroke="#FFFFFF" stroke-opacity="0.1" stroke-width="3"/>
</svg>
'''


def menubar():
    g = sprite()
    black = {k: "#000" for k in "BSHCM"}
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="0 0 36 36">
  <!-- 菜单栏模板图标（只用 alpha）：Tako 剪影，眼睛镂空。由 scripts/gen_branding.py 生成。 -->
  {rects(g, 2, 3, 2, black, bleed=0)}
</svg>
'''


if __name__ == "__main__":
    with open(os.path.join(ROOT, "Branding/logo.svg"), "w") as f:
        f.write(logo())
    with open(os.path.join(ROOT, "Branding/menubar.svg"), "w") as f:
        f.write(menubar())
    print("wrote Branding/logo.svg, Branding/menubar.svg")
