#!/bin/bash
# 打包 Windows / Linux 版（在 macOS / Linux / Windows 上都能运行，只需要 .NET 10 SDK）。
#   cross/scripts/publish.sh            # 默认：win-x64 + linux-x64
#   cross/scripts/publish.sh win-arm64  # 指定目标
# 输出：build/ServerIsland-<版本>-<目标>.zip / .tar.gz（单文件、自带运行时，不需要另装 .NET）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJ="$ROOT/cross/src/ServerIsland.Desktop"
VERSION="$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' "$ROOT/cross/Directory.Build.props")"
TARGETS=("$@")
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(win-x64 linux-x64)

for RID in "${TARGETS[@]}"; do
  OUT="$ROOT/build/cross/$RID"
  rm -rf "$OUT"
  echo "==> $RID"
  dotnet publish "$PROJ" -c Release -r "$RID" --self-contained true \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:EnableCompressionInSingleFile=true -p:DebugType=None -o "$OUT" | grep -E "error|->" || true
  cp "$ROOT/LICENSE" "$OUT/LICENSE.txt"
  case "$RID" in
    win-*)
      ZIP="$ROOT/build/ServerIsland-$VERSION-$RID.zip"
      rm -f "$ZIP"
      if command -v zip >/dev/null; then (cd "$OUT" && zip -q -9 "$ZIP" ServerIsland.exe LICENSE.txt)
      else powershell -NoProfile -Command "Compress-Archive -Path '$(cygpath -w "$OUT")\*' -DestinationPath '$(cygpath -w "$ZIP")'"; fi
      echo "    build/ServerIsland-$VERSION-$RID.zip" ;;
    *)
      cp "$ROOT/cross/packaging/serverisland.desktop" "$ROOT/cross/src/ServerIsland.Desktop/Assets/AppIcon.png" "$OUT/"
      tar -czf "$ROOT/build/ServerIsland-$VERSION-$RID.tar.gz" -C "$OUT" .
      echo "    build/ServerIsland-$VERSION-$RID.tar.gz" ;;
  esac
done
