#!/bin/bash
# 生成 README 用的素材（演示数据，虚构的用户名 / 路径 / 主机名），中英文各一份：
#   docs/hero-{en,zh}.png          顶部大图：左边"收起 → 提醒 → 悬停"三步，右边 Mac 刘海里展开的面板
#   docs/screenshots/{en,zh}/*.png 截图：统一尺寸的壁纸画面，面板挂在刘海下 / 设置窗口居中（scripts/readme_compose.py）
#   docs/screenshots/{en,zh}/windows-pet.png  Windows / Linux 版的桌面小章鱼（需要 dotnet；没有就跳过）
#   docs/architecture[-zh]-{dark,light}.png  工作原理图（由 docs/architecture[.zh].svg 渲染）
set -euo pipefail
cd "$(dirname "$0")/.."
swift build 2>&1 | grep -v PlatformPath | tail -1
TMP=$(mktemp -d)
for l in en zh; do
  # 1) 面板截图（透明背景）
  SI_BARE=1 .build/debug/ServerIsland --render-preview "$TMP/bare-$l" "$l" > /dev/null
  # 2) Windows / Linux 版（可选）
  CROSS=""
  if command -v dotnet > /dev/null; then
    (cd cross/src/ServerIsland.Desktop && dotnet run -- --render-preview "$TMP/cross-$l" "$l" > /dev/null) && CROSS="$TMP/cross-$l"
  fi
  # 3) 合成顶部大图和截图
  python3 scripts/readme_compose.py "$TMP/bare-$l" "$l" $CROSS
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
du -sh docs/hero-*.png docs/screenshots docs/architecture-*.png
