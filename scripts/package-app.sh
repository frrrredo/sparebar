#!/bin/bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"
output_dir=${1:-"$project_root/dist"}
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)
app="$output_dir/Sparebar.app"
if pgrep -f "^$app/Contents/MacOS/Sparebar( |$)" >/dev/null; then
  echo "Quit the existing local Sparebar app before replacing its bundle." >&2
  exit 1
fi
swift build -c release --arch arm64
binary_dir=$(swift build -c release --arch arm64 --show-bin-path)
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/Sparebar" "$app/Contents/MacOS/Sparebar"
cp Resources/Info.plist "$app/Contents/Info.plist"
plutil -insert SparebarSourceRevision -string "$(git rev-parse HEAD)" "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE"
swift scripts/make-icon.swift "$project_root/.build/Sparebar.iconset"
iconutil -c icns "$project_root/.build/Sparebar.iconset" -o "$app/Contents/Resources/Sparebar.icns"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
plutil -lint "$app/Contents/Info.plist"
echo "$app"
