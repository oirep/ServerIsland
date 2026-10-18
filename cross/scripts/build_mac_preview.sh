#!/bin/bash
# 把跨平台版打包成一个 Mac App，方便在 Mac 上试用 Windows / Linux 版的界面和逻辑。
# 正式的 Mac 版仍然是 Swift（scripts/build_app.sh）。两者 Bundle ID 和配置目录都不同，可以并存（但不要同时运行，两个刘海会重叠）。
#   cross/scripts/build_mac_preview.sh [--run]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' "$ROOT/cross/Directory.Build.props")"
RID="osx-$(uname -m | sed 's/x86_64/x64/')"
APP="$ROOT/build/ServerIsland Preview.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
dotnet publish "$ROOT/cross/src/ServerIsland.Desktop" -c Release -r "$RID" --self-contained true -p:DebugType=None \
  -o "$APP/Contents/MacOS" | grep -E "error|->" || true
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ServerIsland</string>
  <key>CFBundleIdentifier</key><string>io.github.zhyan0603.serverisland.cross-preview</string>
  <key>CFBundleName</key><string>ServerIsland Preview</string>
  <key>CFBundleDisplayName</key><string>ServerIsland Preview</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP" 2>/dev/null || true
echo "→ $APP"
if [ "${1:-}" = "--run" ]; then
  osascript -e 'quit app "ServerIsland"' 2>/dev/null || true
  pkill -f "ServerIsland Preview.app/Contents/MacOS/ServerIsland" 2>/dev/null || true
  sleep 1
  open "$APP"
fi
