#!/usr/bin/env python3
"""生成 Windows / Linux 版用到的图标（需要 Pillow）：

- Assets/ServerIsland.ico：exe 图标（16~256，取自 Branding/logo-1024.png）
- Assets/AppIcon.png：窗口图标 / Linux .desktop 图标（256）
- Assets/Tray.png、Assets/TrayAlert.png：托盘图标（像素 Tako，彩色；有异常时变红）

    python3 cross/scripts/gen_icons.py
"""
import os
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ASSETS = os.path.join(ROOT, "cross", "src", "ServerIsland.Desktop", "Assets")

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
NORMAL = {"B": (0x5C, 0xE6, 0xB5), "S": (0x2E, 0xAD, 0x87), "H": (0xBD, 0xF9, 0xDF),
          "E": (0x0A, 0x0F, 0x1F), "W": (255, 255, 255), "C": (0xFF, 0x8F, 0xAB), "M": (0x0A, 0x0F, 0x1F)}
ALERT = dict(NORMAL, B=(0xFF, 0x8C, 0x8C), S=(0xCC, 0x54, 0x5C), H=(0xFF, 0xCC, 0xCC))


def sprite():
    g = [list(r) for r in HEAD + LEGS]
    for c in (4, 10):
        g[6][c], g[6][c + 1], g[7][c], g[7][c + 1] = "W", "E", "E", "E"
    g[8][3] = g[8][12] = "C"
    g[8][7] = g[8][8] = "M"
    return g


def tako(size, colors):
    """16x14 网格放进 size x size 的透明方块，整数倍放大保证像素清晰。"""
    g = sprite()
    px = max(1, size // 16)
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    x0 = (size - 16 * px) // 2
    y0 = (size - 14 * px) // 2
    for r, row in enumerate(g):
        for c, ch in enumerate(row):
            if ch in colors:
                for dy in range(px):
                    for dx in range(px):
                        img.putpixel((x0 + c * px + dx, y0 + r * px + dy), colors[ch] + (255,))
    return img


def main():
    os.makedirs(ASSETS, exist_ok=True)
    logo = Image.open(os.path.join(ROOT, "Branding", "logo-1024.png")).convert("RGBA")
    logo.save(os.path.join(ASSETS, "ServerIsland.ico"), sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])
    logo.resize((256, 256), Image.LANCZOS).save(os.path.join(ASSETS, "AppIcon.png"))
    tako(64, NORMAL).save(os.path.join(ASSETS, "Tray.png"))
    tako(64, ALERT).save(os.path.join(ASSETS, "TrayAlert.png"))
    print("ok:", sorted(os.listdir(ASSETS)))


if __name__ == "__main__":
    main()
