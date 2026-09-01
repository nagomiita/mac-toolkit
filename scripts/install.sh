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

# The ad-hoc signature is part of the app's TCC identity (the designated
# requirement is a bare cdhash), so a rebuilt binary looks like a different app
# and silently loses Screen Recording. Re-ticking the checkbox does NOT bring it
# back: macOS 26 refuses to prompt for kTCCServiceScreenCapture and rewrites the
# record to "Denied (System Set)". The stale record has to be dropped first.
#
# The cdhash only changes when the built binary changes, so compare against the
# last install and stay quiet when there is nothing to re-approve.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist")"
CDHASH_FILE="$ROOT/build/.installed-cdhash"
CDHASH="$(codesign -dvvv "$DEST" 2>&1 | awk -F= '/^CDHash=/{print $2}')"
PREV="$(cat "$CDHASH_FILE" 2>/dev/null || true)"
printf '%s' "$CDHASH" > "$CDHASH_FILE"

if [ -n "$PREV" ] && [ "$CDHASH" = "$PREV" ]; then
    echo "署名は前回のインストールと同じ。画面収録の許可はそのまま有効"
    exit 0
fi

echo
if [ -n "$PREV" ]; then
    echo "署名が変わったので画面収録の許可が外れている。"
else
    echo "前回のインストール記録が無いので、画面収録の許可が残っているかは判定できない。"
fi

cat <<EOS
スクリーンショット・録画・iPad ディスプレイが無反応なら、
システム設定でチェックを入れ直すだけでは戻らないので、次の順で復旧する。

  1. tccutil reset ScreenCapture $BUNDLE_ID
  2. MacToolkit でスクリーンショットか「配信を開始」を一度実行する（拒否レコードが作り直される）
  3. システム設定 → プライバシーとセキュリティ → 画面収録 で MacToolkit を ON
  4. MacToolkit を再起動する
EOS
