# iPad ディスプレイ（画面配信 PoC）

iPad を Mac のサブディスプレイ的に使うための低遅延画面配信（Issue #15）。
Sidecar の再実装ではなく、「ScreenCaptureKit → VideoToolbox(H.264) → Wi-Fi / USB-C → iPad でハードウェアデコード」という映像パスの実証が目的。

```
Mac (MacToolkit)                                iPad (MacToolkit Display)
┌─────────────────────────────────┐             ┌──────────────────────────────┐
│ ScreenCaptureKit (SCStream)     │             │ NWBrowser で Mac を発見       │
│   ↓ CVImageBuffer (420v)        │   Bonjour   │   ↓ タップで接続              │
│ VideoToolbox H.264 (低遅延 RC)  │ ──────────→ │ NWConnection (TCP, noDelay)  │
│   ↓ AVCC + SPS/PPS              │   TCP       │   ↓ CMSampleBuffer に組み立て │
│ NWListener (_mactoolkit-display)│ ──────────→ │ AVSampleBufferDisplayLayer   │
└─────────────────────────────────┘             └──────────────────────────────┘
```

## 使い方

### Mac 側

1. `./scripts/install.sh` でインストールして起動（画面収録権限が要るため `swift run` では検証できない）
2. ポップオーバーの「iPad ディスプレイ」→「配信を開始」
   - 初回は画面収録の許可 → アプリ再起動が必要（画面録画と同じ流れ）
   - 再インストールで許可が外れたときはチェックの入れ直しでは戻らない。`install.sh` が出す 4 手順に従う
   - macOS 15 以降ではローカルネットワークの許可ダイアログも出る
3. 設定（設定… → iPad ディスプレイ）で配信対象（画面全体 / ウインドウ）、30/60 fps、ビットレート、Retina 解像度を変更できる。反映は次回の配信開始から

### iPad 側

アプリは `ipad/MacToolkitDisplay.swiftpm/`。App Store 配布はしない（Non-Goal）ので、Swift Playgrounds で動かす。

1. `MacToolkitDisplay.swiftpm` フォルダを iPad へ転送する（AirDrop / iCloud Drive のどちらでも）
2. iPad の **Swift Playgrounds**（無料）で開き、実行する
   - Mac に Xcode がある場合はフォルダを Xcode で開いて通常のビルド・実機インストールも可
3. Mac と同じネットワークにいれば一覧に Mac 名が出るのでタップして接続（USB-C 直結でもよい。「経路」を参照）
   - 初回はローカルネットワークの許可ダイアログが出る。**拒否すると一覧が空のまま「検索中…」で止まる**
4. 視聴中は画面タップで情報バー（遅延 / FPS / 切断）の表示を切り替え

## 経路

Bonjour で見つけて TCP で繋ぐだけなので、**両者が同じリンクにいて相互に通信できれば経路は問わない**。
ただし実測すると差が大きい。PoC の検証は USB-C 直結で行った。

| 経路 | RTT | 備考 |
|---|---|---|
| **USB-C 直結** | 1.1 ms（±0.2） | 最も安定。検証はこれで実施 |
| 家庭内 Wi-Fi | 未計測 | 想定している通常の使い方 |
| iPhone のテザリング | 平均 35 ms（最大 171 ms） | ジッタが大きく、遅延の計測が成り立たない |

USB-C はケーブルを挿すだけでよい。macOS 側に NCM のインターフェース（`en7` など）が生えて
IPv4 リンクローカル（`169.254.x`）と IPv6 リンクローカル（`fe80::`）が振られ、mDNS もそのリンクを流れる。
アプリ側の設定は要らない。

**公衆 Wi-Fi では繋がらないことが多い。**ホテルやカフェのアクセスポイントは
クライアント分離（AP isolation）が有効で、同じ SSID にいても端末どうしが通信できない。
実際に踏んだ例では、Mac からゲートウェイへは 2.4 ms で届くのに
iPad の ARP エントリは `(incomplete)` のままで ICMP は 100% ロスした。
Bonjour の広告も相手に届かないため、iPad 側は原因が出ないまま「検索中…」で止まる。
この症状なら USB-C 直結に切り替える。

## 遅延の計測方法

「Mac でキャプチャした瞬間 → iPad でデコーダに渡す直前」の片道時間を出している。

1. iPad が 1 秒ごとに `ping`（自分の時刻入り）を送り、Mac は受信時刻を足した `pong` を即返す
2. iPad は **RTT が最小だったサンプル**から時計差を推定する（`offset = tMac − (t送信 + t受信) / 2`）。RTT が小さいほど行き帰りが対称に近く、推定が正確
3. 各フレームには Mac の壁時計でのキャプチャ時刻が入っており、iPad が時計差を補正して片道遅延を計算、指数移動平均（α = 0.2）でならす
4. 値は 1 秒ごとに `stats` パケットで Mac に送り返され、両側の UI に同じ数値が出る

デコード後の表示までの時間（数 ms〜1 フレーム）は含まれない。目安として使う。

## ワイヤプロトコル

TCP 上に「ヘッダ 5 バイト（type 1 + payload 長 4、ビッグエンディアン）＋ペイロード」を繰り返すだけの独自フレーミング。定義は `StreamProtocol.swift`（**Mac 側 `Sources/MacToolkit/Modules/iPadDisplay/` と iPad 側 `ipad/MacToolkitDisplay.swiftpm/Sources/` の 2 箇所にあり、完全に同一の内容を保つこと**）。

| type | 名前 | 向き | 内容 |
|---|---|---|---|
| 1 | hello | iPad → Mac | 端末名（UTF-8） |
| 2 | videoConfig | Mac → iPad | コーデック(1=H.264)、実寸、SPS/PPS。キーフレームの直前に送る |
| 3 | videoFrame | Mac → iPad | キャプチャ時刻(ms) + キーフレームフラグ + AVCC データ |
| 4 | ping | iPad → Mac | iPad の時刻(ms) |
| 5 | pong | Mac → iPad | ping の時刻 + Mac の時刻(ms) |
| 6 | stats | iPad → Mac | 遅延(ms, Float32) + 受信 FPS(Float32) |

Bonjour サービスタイプは `_mactoolkit-display._tcp`。同時接続は 1 台のみ（新しい接続が来たら古い方を切る）。

## 遅延を抑えるための決めごと

- **TCP の `noDelay`（Nagle 無効）**。小さいパケットの合流待ちがそのまま遅延になる
- **エンコーダは低遅延レートコントロール**（`EnableLowLatencyRateControl`）を優先し、非対応環境では通常セッションにフォールバック。B フレーム禁止・リアルタイム優先
- **背圧はエンコード前に効かせる**。送信の完了待ちが 4 個を超えたらフレームをキャプチャ段階で捨てる。エンコード後に捨てると参照フレームが欠けてデコーダが壊れるため、捨てるのは必ずエンコーダに入れる前
- **接続直後はキーフレームを強制**し、最初のキーフレームを送るまで通常フレームを止める（途中参加のデコーダに差分フレームを食わせない）
- **iPad 側はタイムスタンプ同期をしない**。`kCMSampleAttachmentKey_DisplayImmediately` を立てて届いた順に即表示する
- キャプチャは iPad が接続してきたときだけ動かす。誰も見ていないのに撮り続けない

## 制限（PoC の範囲）

- 仮想ディスプレイではない（ミラーリング／ウインドウ配信のみ。画面の「拡張」はしない）
- タッチ・Apple Pencil の入力は Mac へ返さない
- 音声は送らない
- 暗号化なし（USB-C 直結か家庭内 LAN が前提。`NWParameters.tcp` そのまま）
- 経路を選べない。インターフェースを指定していないので、Wi-Fi と USB-C の両方が生きていればどちらを通るかは OS 任せ
- 同時に受信できる iPad は 1 台
- ウインドウ配信はストリーム開始時の寸法で固定。大きくリサイズすると `scalesToFit` で枠内に収まる（解像度は変わらない）
