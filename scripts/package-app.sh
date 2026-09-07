#!/bin/bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"
swift build -c release --arch arm64
binary_dir=$(swift build -c release --arch arm64 --show-bin-path)
app="$project_root/dist/Sparebar.app"
if pgrep -f "^$app/Contents/MacOS/Sparebar( |$)" >/dev/null; then
  echo "Quit the existing local Sparebar app before replacing its bundle." >&2
  exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/Sparebar" "$app/Contents/MacOS/Sparebar"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE"
swift scripts/make-icon.swift "$project_root/.build/Sparebar.iconset"
iconutil -c icns "$project_root/.build/Sparebar.iconset" -o "$app/Contents/Resources/Sparebar.icns"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
plutil -lint "$app/Contents/Info.plist"
echo "$app"
