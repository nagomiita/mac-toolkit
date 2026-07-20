#!/bin/bash
# MacToolkit.app を /Applications にインストールして起動する。
#
# ログイン時の自動起動（SMAppService）は、アプリが安定した場所に
# あることを前提にするため、開発中でも一度ここへ入れる必要がある。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="/Applications/MacToolkit.app"

# 最新のバンドルを作る
"$ROOT/scripts/bundle.sh" release

# 動作中なら終了してから置き換える
pkill -x MacToolkit 2>/dev/null || true
sleep 1

rm -rf "$DEST"
cp -R "$ROOT/build/MacToolkit.app" "$DEST"
# コピーで署名が無効化されることがあるので入れ先で署名し直す
codesign --force --sign - "$DEST"

open "$DEST"
echo "installed and launched: $DEST"
