#!/bin/bash
# swift build の成果物を MacToolkit.app にまとめる。
# Xcode を使わずに LSUIElement / バンドル ID を効かせるために必要。
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/MacToolkit.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/MacToolkit"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacToolkit"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# 未署名だと権限（画面収録・位置情報）の付与が安定しないため ad-hoc 署名する
codesign --force --sign - "$APP"

echo "built: $APP"
