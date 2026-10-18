#!/usr/bin/env bash
# 一次打出三个平台的安装包，并把本机的 Mac 版换成新版
#   ./scripts/package_all.sh
# 输出（版本号来自 Resources/Info.plist 和 cross/Directory.Build.props，两个要一致）：
#   build/ServerIsland-<版本>.dmg               macOS（通用二进制，ad-hoc 签名）
#   build/ServerIsland-<版本>-win-x64.zip       Windows
#   build/ServerIsland-<版本>-linux-x64.tar.gz  Linux
# 需要：Command Line Tools、.NET 10 SDK（brew install dotnet）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MAC_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
CROSS_VERSION="$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' cross/Directory.Build.props)"
if [[ "$MAC_VERSION" != "$CROSS_VERSION" ]]; then
  echo "✗ 版本号不一致：Info.plist 是 $MAC_VERSION，cross/Directory.Build.props 是 $CROSS_VERSION" >&2
  exit 1
fi
V="$MAC_VERSION"

echo "━━ 1/3 macOS DMG"
./scripts/make_dmg.sh

echo "━━ 2/3 Windows / Linux"
./cross/scripts/publish.sh

echo "━━ 3/3 替换本机的 Mac 版"
./scripts/install_local.sh --no-build

echo
echo "安装包（版本 $V）："
for f in "build/ServerIsland-$V.dmg" "build/ServerIsland-$V-win-x64.zip" "build/ServerIsland-$V-linux-x64.tar.gz"; do
  printf '  %-42s %6s  %s\n' "$f" "$(du -h "$f" | cut -f1)" "$(shasum -a 256 "$f" | cut -d' ' -f1)"
done
