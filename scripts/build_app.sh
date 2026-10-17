#!/usr/bin/env bash
# 编译并打包 ServerIsland.app（只需 Command Line Tools，不需要 Xcode）
#   ./scripts/build_app.sh          # release 构建 -> build/ServerIsland.app
#   ./scripts/build_app.sh --run    # 构建后重启 App
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/ServerIsland.app"
CONFIG="${CONFIG:-release}"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/ServerIsland"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ServerIsland"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
if [[ -d "$ROOT/Resources/Sounds" ]]; then
  cp -R "$ROOT/Resources/Sounds" "$APP/Contents/Resources/Sounds"
fi
if [[ -f "$ROOT/Branding/menubar.png" ]]; then
  cp "$ROOT/Branding/menubar.png" "$APP/Contents/Resources/menubar.png"
  cp "$ROOT/Branding/menubar@2x.png" "$APP/Contents/Resources/menubar@2x.png"
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "✓ 已生成 $APP"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x ServerIsland 2>/dev/null || true
  sleep 0.3
  open "$APP"
fi
