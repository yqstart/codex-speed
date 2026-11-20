#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

swift build -c release
binary_dir=$(swift build -c release --show-bin-path)
bundle=${1:-"$project_dir/dist/Codex Speed.app"}

mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
install -m 755 "$binary_dir/CodexSpeed" "$bundle/Contents/MacOS/CodexSpeed"
install -m 644 "$project_dir/Support/Info.plist" "$bundle/Contents/Info.plist"
install -m 644 "$project_dir/Support/AppIcon.icns" "$bundle/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$bundle"
printf '应用已构建到 %s\n' "$bundle"
