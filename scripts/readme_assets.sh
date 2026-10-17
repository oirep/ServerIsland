#!/bin/bash
# 生成 README 用的素材（演示数据，虚构的用户名 / 路径 / 主机名），中英文各一份：
#   docs/demo-{en,zh}.gif          顶部动图：收起 → 完成提示 → 展开
#   docs/screenshots/{en,zh}/*.png 只有面板本身的截图（透明背景，裁掉空白）
#   docs/architecture[-zh]-{dark,light}.png  工作原理图（由 docs/architecture[.zh].svg 渲染）
set -euo pipefail
cd "$(dirname "$0")/.."
swift build 2>&1 | grep -v PlatformPath | tail -1
TMP=$(mktemp -d)
SHOTS="expanded detail-nep detail partitions history toast toast-failed settings-rule-editor"
for l in en zh; do
  # 1) 动图：带桌面背景的三帧
  .build/debug/ServerIsland --render-preview "$TMP/$l" "$l" > /dev/null
  F="$TMP/$l"
  ffmpeg -loglevel error -y \
    -loop 1 -t 1.8 -i "$F/gif-1-collapsed.png" \
    -loop 1 -t 2.6 -i "$F/gif-2-toast.png" \
    -loop 1 -t 1.2 -i "$F/gif-1-collapsed.png" \
    -loop 1 -t 3.6 -i "$F/gif-3-expanded.png" \
    -filter_complex "\
      [0][1]xfade=transition=fade:duration=0.35:offset=1.45[a];\
      [a][2]xfade=transition=fade:duration=0.35:offset=3.7[b];\
      [b][3]xfade=transition=fade:duration=0.35:offset=4.55,fps=15,scale=760:-1:flags=lanczos,split[s0][s1];\
      [s0]palettegen=max_colors=160:stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
    "docs/demo-$l.gif"
  # 2) 截图：不画桌面，裁掉透明边
  SI_BARE=1 .build/debug/ServerIsland --render-preview "$TMP/bare-$l" "$l" > /dev/null
  mkdir -p "docs/screenshots/$l"
  python3 - "$TMP/bare-$l" "docs/screenshots/$l" $SHOTS <<'PY'
import sys
from PIL import Image
src, dst, names = sys.argv[1], sys.argv[2], sys.argv[3:]
for n in names:
    im = Image.open(f"{src}/{n}.png").convert("RGBA")
    box = im.split()[3].getbbox()
    pad = 8
    if box:
        box = (max(box[0] - pad, 0), max(box[1] - pad, 0), min(box[2] + pad, im.width), min(box[3] + pad, im.height))
        im = im.crop(box)
    im.save(f"{dst}/{n}.png", optimize=True)
PY
done
# 3) 工作原理图（英文 docs/architecture.svg、中文 docs/architecture.zh.svg；各出深色 / 浅色两版）
for lang in en zh; do
  src=docs/architecture.svg; suffix=""
  if [ "$lang" = zh ]; then src=docs/architecture.zh.svg; suffix="-zh"; fi
  for theme in dark light; do
    sed "1s/data-theme=\"[a-z]*\"/data-theme=\"$theme\"/" "$src" > "$TMP/arch.svg"
    swift scripts/render_svg.swift "$TMP/arch.svg" "$TMP/arch.png" 2000 > /dev/null
    # render_svg 输出正方形，裁掉上下的透明边
    python3 -c "from PIL import Image; im=Image.open('$TMP/arch.png'); im.crop(im.split()[3].getbbox()).save('docs/architecture$suffix-$theme.png', optimize=True)"
  done
done
rm -rf "$TMP"
du -sh docs/demo-*.gif docs/screenshots docs/architecture-*.png
