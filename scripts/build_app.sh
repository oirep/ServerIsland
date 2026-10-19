#!/usr/bin/env bash
# 编译并打包 ServerIsland.app（只需 Command Line Tools，不需要 Xcode）
#   ./scripts/build_app.sh          # release 构建 -> build/ServerIsland.app
#   ./scripts/build_app.sh --run    # 构建后重启 App
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/ServerIsland.app"
CONFIG="${CONFIG:-release}"

cd "$ROOT"
# 新版 CLT 的默认 macOS 27 SDK 缺少 SwiftUI 宏插件时，使用本机仍安装的 26.5 SDK。
# 也可显式指定 SERVERISLAND_SDK；构建和查找产物必须使用同一组参数。
SDK="${SERVERISLAND_SDK:-}"
if [[ -z "$SDK" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
BUILD_ARGS=(--disable-sandbox --build-system native -c "$CONFIG")
if [[ -n "$SDK" ]]; then
  [[ -d "$SDK" ]] || { echo "SDK 不存在：$SDK" >&2; exit 1; }
  BUILD_ARGS+=(--scratch-path "$ROOT/.build-macos26"
    -Xswiftc -sdk -Xswiftc "$SDK" -Xcc -isysroot -Xcc "$SDK")
fi
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/ServerIsland"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ServerIsland"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/remote/si-deploy" "$APP/Contents/Resources/si-deploy"
cp "$ROOT/remote/docker-monitor.py" "$APP/Contents/Resources/docker-monitor.py"
cp "$ROOT/remote/docker-control.py" "$APP/Contents/Resources/docker-control.py"
if [[ -f "$ROOT/examples/deployment-progress-rules.json" ]]; then
  cp "$ROOT/examples/deployment-progress-rules.json" "$ROOT/build/deployment-progress-rules.json"
fi
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

codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "✓ 已生成 $APP"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x ServerIsland 2>/dev/null || true
  sleep 0.3
  open "$APP"
fi
