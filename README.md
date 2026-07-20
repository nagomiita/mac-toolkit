# mac-toolkit

macOS のメニューバーに常駐するオールインワンツールキット。
通信速度・Wi-Fi 情報・CPU/GPU・温度・メモリ・スクリーンショットなどを 1 つのアプリにまとめることを目指しています。

Swift 6 / SwiftUI (`MenuBarExtra`) 製。Xcode は不要で、SwiftPM だけでビルドできます。

## 必要環境

- macOS 14 以降
- Swift 6.x（Command Line Tools に同梱）

## ビルドと実行

```sh
# 開発中: そのまま起動（Dock には出ません）
swift run MacToolkit

# .app として生成（LSUIElement / バンドル ID / ad-hoc 署名が有効になる）
./scripts/bundle.sh
open build/MacToolkit.app
```

権限（画面収録・位置情報）を伴う機能を使う場合は `.app` の方で実行してください。

## アーキテクチャ

設計方針の詳細は [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) を参照してください。

全機能は `ToolModule`（`Sources/MacToolkit/Core/ToolModule.swift`）に準拠したモジュールとして実装します。

- `ModuleRegistry` — 全モジュールの登録・有効/無効・永続化・ライフサイクル
- `Sampler` — 全モジュール共通の 1 本のタイマー。モジュール個別に Timer を持たせない（常駐アプリの省電力のため）
- `Modules/` — 各機能。現在は動作確認用の `PlaceholderModule` のみ

新しい機能を足すときは `Modules/` にモジュールを作り、`MacToolkitApp.init` の登録配列に追加します。

## ロードマップ

実装予定の機能は [Issues](https://github.com/nagomiita/mac-toolkit/issues) を参照してください。
