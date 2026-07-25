# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

macOS のメニューバーに常駐するオールインワンツールキット（Stats + Shottr 相当を 1 プロセスに統合）。
Swift 6 / SwiftUI `MenuBarExtra`、SwiftPM のみ（Xcode 不要）、外部依存ゼロ、最低 OS は macOS 14。

`docs/ARCHITECTURE.md` が設計の判断基準。方針を変えるときはコードより先にそのファイルを更新する。

## コマンド

```sh
swift build                    # 警告ゼロを常に維持する（strict concurrency 有効のまま）
swift run MacToolkit           # 開発中の起動。Dock には出ない
./scripts/bundle.sh [release]  # build/MacToolkit.app を生成（Info.plist + ad-hoc 署名）
./scripts/install.sh           # /Applications にインストールして起動
```

テストターゲットは無い。動作確認は実機で標準ツール（アクティビティモニタ、`powermetrics`、Finder の空き容量）と突き合わせる。

権限が絡む機能（画面収録＝スクリーンショット、位置情報＝Wi-Fi SSID、`SMAppService` の自動起動）は
`swift run` では検証できない。必ず `./scripts/install.sh` で `/Applications` から起動して確認する
（`LoginItem.canToggle` は `/Applications` 配下でないと false になる）。

## アーキテクチャ

3 つの Core 型が全体を規定する。

- **`Core/ToolModule.swift`** — 全機能が準拠する唯一の抽象。`id`/`title`/`systemImage`/`isAvailable`、
  `start()`/`stop()`/`tick()`、`statusItemView()`/`detailView()`/`settingsView()`。
  View は `AnyView` で型消去する（`associatedtype` にすると Registry が異種モジュールを 1 配列で持てない）。
  デフォルト実装があるので、必須の実装は `id`/`title`/`systemImage`/`tick()`/`detailView()` だけ。
- **`Core/ModuleRegistry.swift`** — `@Observable` な唯一の真実の情報源。`isAvailable` で登録時にふるい落とし、
  有効 id 集合・メニューバー表示 id 集合・更新間隔を `UserDefaults` に永続化。
- **`Core/Sampler.swift`** — **アプリ全体で唯一のタイマー**。`.common` モード、tolerance は間隔の 10%。
  モジュール側で `Timer`/`DispatchSourceTimer` を作ることは禁止。

モジュールは全て `@MainActor`（UI から直接読まれるため）。モジュール同士は互いを参照しない。

各モジュールは `Modules/<機能>/` に「値の取得を担う `*Counters`/`*Sensors`（UI 非依存の値型）」と
「`ToolModule` 準拠の `*Module`」に分けるのが既存の形。新規追加は
`Modules/` にクラスを作り、`MacToolkitApp.init` の登録配列に 1 行足すだけ（登録順＝表示順）。

`UI/DesignSystem.swift` の `Metrics` と `*Style()` モディファイアを必ず経由する。
モジュールが生の `Text` を直接組まない。

## 低レベル API を触るときの鉄則

IOKit / SMC / GPU 統計は機種・OS で普通に取得できない。

- 強制アンラップ `!` / `try!` を低レベル API 周りで使わない。1 モジュールの失敗が他を巻き込まない
- 取れない値は 0 ではなく「N/A」と表示する（0 は「正常に 0」と誤読される）
- センサーのキー名はフォールバック候補のリストで持つ
- `vm_deallocate` / `IOObjectRelease` を必ず呼ぶ（常駐アプリではリークが致命的）
- プライベート API（`IOHIDEventSystemClient` など）は `dlsym` で解決し、CLT のみでビルドできる状態を保つ

## tick() の設計

`tick()` は 1ms 未満を目安に軽く保つ。重い取得（`ThermalSensors` の全センサー読みは約 40ms）は
モジュール側でキャッシュし、`Task.detached` で数周期に 1 回だけ実際に取りに行く。

ポーリングは「連続的に変化する数値」（速度・使用率・温度）のみ。
イベントで取れるもの（Wi-Fi の接続変化、電源の抜き差し）は OS の通知を使う。

## 文言は日本語（確定方針）

ユーザーに見える文字列は全て日本語。英語版は作らない。`Localizable.strings` は作らず、
日本語リテラルを `Text` / `Label` に直接渡す（将来 `String(localized:)` に機械置換できる形を保つ）。
`Info.plist` の `NS*UsageDescription` も日本語。

- 定着した技術用語（CPU / GPU / Wi-Fi / SSID / RSSI / OCR）と単位（`MB/s`、`dBm`、`58°C`）は英字のまま
- 迷ったらアクティビティモニタとシステム設定の日本語表記に合わせる
- 常体・体言止め、句点なし（「取得できません」）。ボタンは「設定…」「終了」
- **識別子・コメント・`NSLog` は英語のまま**（開発者向けであってユーザー向けではない）
- README と Issue も日本語

## UI

- メニューバー本体は幅が揺れないことを最優先。数値は `.monospacedDigit()`、単位込みで桁数を固定
- `MenuBarExtra` は `.menuBarExtraStyle(.window)`
- ポップオーバーは 1 モジュール 1 セクションを縦に並べるだけ
- 既定でメニューバーに数値を出すのは CPU とネットワークのみ（`ModuleRegistry.defaultMenuBarIDs`）
