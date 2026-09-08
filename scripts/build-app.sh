#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$project_dir/dist}"
identity="${CODEX_ISLAND_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | awk '/Apple Development:|Developer ID Application:/ {print $2; exit}')"
fi
if [[ -z "$identity" ]]; then
  echo '没有可用的 Apple 签名证书。请在本机配置 Apple Development 或 Developer ID Application 后重试；仅检查源码可运行 swift build 或 swift test。' >&2
  exit 1
fi
cd "$project_dir"
swift build -c release --arch arm64 --arch x86_64
bin_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
app_dir="$output_dir/Codex Island.app"
if [[ -e "$app_dir" ]]; then
  existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_dir/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$existing_id" != 'local.codex-island.app' ]]; then
    echo '输出目录已有不同应用，停止覆盖。' >&2
    exit 1
  fi
fi
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/CodexIsland" "$app_dir/Contents/MacOS/CodexIsland"
cp "$project_dir/resources/Info.plist" "$app_dir/Contents/Info.plist"
xcrun swift "$project_dir/scripts/make-icon.swift" "$project_dir/.build/island.iconset"
iconutil -c icns "$project_dir/.build/island.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --options runtime --sign "$identity" "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
lipo -archs "$app_dir/Contents/MacOS/CodexIsland"
echo "$app_dir"
