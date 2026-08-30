import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// 画面を録画する。システム音声（会議相手の声）も一緒に録れる。
///
/// 突発的に録りたいときに一撃で始められることを最優先にしているので、
/// 開始も停止も同じホットキー（⌥⌘R）で、範囲選択などの手数を挟まない。
@MainActor
@Observable
final class RecordingModule: ToolModule {
    let id = "recording"
    let title = "画面録画"
    let systemImage = "record.circle"

    private(set) var isRecording = false
    /// 録画を始めた時刻。経過時間の計算に使う。
    private(set) var startedAt: Date?
    /// `tick()` が更新する経過秒。View はこれを見る。
    private(set) var elapsed: TimeInterval = 0
    /// 直近に書き出せたファイル。Finder で表示する導線に使う。
    private(set) var lastOutput: URL?

    private(set) var message: String?
    private(set) var needsPermission = false
    private(set) var hotKeyFailed = false

    /// マイクも録るか。macOS 15 以降のみ有効。
    var capturesMicrophone: Bool {
        didSet {
            UserDefaults.standard.set(capturesMicrophone, forKey: Self.micKey)
        }
    }

    /// マイク収録は macOS 15 の API に依存する。
    var supportsMicrophone: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    @ObservationIgnored private let recorder = ScreenRecorder()
    /// 開始・停止の非同期処理が走っている間の二重操作を防ぐ。
    ///
    /// ストリームの開始には数秒かかることがある。その間ボタンの見た目が
    /// 変わらないと「押せていない」ように見えるので、UI から読めるようにする。
    private(set) var isBusy = false

    private static let hotKeyName = "recording.toggle"
    private static let micKey = "recording.capturesMicrophone"

    init() {
        // 権限が要るので既定はオフ。相手の声だけならマイクは不要。
        capturesMicrophone = UserDefaults.standard.bool(forKey: Self.micKey)
    }

    func start() {
        // ⌥⌘R。⇧⌘5（標準の収録ツールバー）とは別に持つ。
        let registered = HotKeyCenter.shared.register(
            name: Self.hotKeyName,
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: [.command, .option]
        ) { [weak self] in
            self?.toggle()
        }
        hotKeyFailed = !registered
    }

    func stop() {
        HotKeyCenter.shared.unregister(name: Self.hotKeyName)
        // 録画中に無効化されてもファイルは壊さず閉じる。
        if isRecording { finish() }
    }

    /// 経過秒を進めるだけ。録画していないときは何もしない。
    func tick() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
    }

    // MARK: - 操作

    func toggle() {
        if isRecording { finish() } else { begin() }
    }

    func begin() {
        guard !isRecording, !isBusy else { return }
        message = nil

        guard ScreenCapturer.hasPermission else {
            ScreenCapturer.requestPermission()
            // 許可は再起動後に効くことがあるため、その場では録画に進まない。
            needsPermission = true
            message = "画面収録の権限が必要です"
            return
        }
        needsPermission = false

        // マウスのあるスクリーンを録る。作業中の画面がそこにある可能性が高い。
        guard let screen = Self.screenUnderMouse else {
            message = "録画するディスプレイが見つかりません"
            return
        }

        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            do {
                _ = try await recorder.start(
                    screen: screen,
                    capturesMicrophone: capturesMicrophone
                ) { error in
                    // ストリーム側の都合で落ちたとき。状態を戻して理由を残す。
                    Task { @MainActor [weak self] in
                        self?.handleUnexpectedStop(error)
                    }
                }
                startedAt = Date()
                elapsed = 0
                isRecording = true
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func finish() {
        guard isRecording, !isBusy else { return }
        isBusy = true
        // 経過表示はすぐ止める。書き出しの待ち時間に数字が進むと紛らわしい。
        isRecording = false
        startedAt = nil

        Task { @MainActor in
            defer { isBusy = false }
            if let url = await recorder.stop() {
                lastOutput = url
                message = nil
            } else {
                lastOutput = nil
                message = "書き出せませんでした"
            }
        }
    }

    /// アプリを再起動する。
    ///
    /// 画面収録の許可は、承認した時点では動いているプロセスに反映されない。
    /// また ad-hoc 署名は再インストールのたびに変わるため、
    /// `install.sh` の後は毎回この再承認＋再起動が必要になる。
    func relaunch() {
        guard !isRecording else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        // 現プロセスを終了する前に新しいインスタンスを立てる。
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: configuration
        ) { _, _ in
            Task { @MainActor in
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// 直近のファイルを Finder で選択状態にする。
    func revealLastOutput() {
        guard let lastOutput else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastOutput])
    }

    private func handleUnexpectedStop(_ error: Error) {
        guard isRecording else { return }
        message = "録画が中断されました"
        finish()
    }

    /// マウスカーソルが載っているスクリーン。見つからなければ主ディスプレイ。
    private static var screenUnderMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
            ?? NSScreen.main
    }

    /// `00:00` 形式。1 時間を超えたら `1:02:03`。
    var elapsedText: String {
        let total = Int(elapsed)
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - View

    /// 録画中だけメニューバーに出す。待機中は幅を取らない。
    func statusItemView() -> AnyView? {
        guard isRecording else { return nil }
        return AnyView(
            HStack(spacing: 3) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                Text(elapsedText)
                    // 桁が変わっても幅が揺れないようにする。
                    .monospacedDigit()
            }
            .menuBarValueStyle()
        )
    }

    func detailView() -> AnyView {
        AnyView(RecordingSectionView(module: self))
    }

    func settingsView() -> AnyView? {
        AnyView(RecordingSettingsView(module: self))
    }
}

// MARK: - ポップオーバー

private struct RecordingSectionView: View {
    @Bindable var module: RecordingModule

    var body: some View {
        ModuleSection(
            title: module.title,
            systemImage: module.systemImage,
            summary: module.isRecording ? module.elapsedText : nil
        ) {
            Button {
                module.toggle()
            } label: {
                if module.isBusy {
                    // 開始・停止の待ち時間を無反応に見せない。
                    Label("準備中…", systemImage: "hourglass")
                } else if module.isRecording {
                    Label("録画を停止", systemImage: "stop.circle")
                } else {
                    Label("録画を開始", systemImage: "record.circle")
                }
            }
            .buttonStyle(.accessoryBar)
            .disabled(module.isBusy)

            Text(module.hotKeyFailed ? "⌥⌘R は他のアプリが使用中" : "⌥⌘R で開始と停止")
                .metricCaptionStyle()

            if let message = module.message {
                // 権限切れは見落とすと「押しても無反応」に見えるので、
                // 補足文と同じ灰色ではなく警告として出す。
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(
                        module.needsPermission
                            ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
                    )
            }

            if module.needsPermission {
                Text("許可した後はアプリの再起動が必要。再インストール後も再承認が要る")
                    .metricCaptionStyle()

                HStack(spacing: 6) {
                    Button("システム設定を開く") {
                        ScreenCapturer.openPermissionSettings()
                    }
                    Button("再起動") {
                        module.relaunch()
                    }
                }
                .buttonStyle(.accessoryBar)
            }

            if module.lastOutput != nil, !module.isRecording {
                Button {
                    module.revealLastOutput()
                } label: {
                    Label("Finder で表示", systemImage: "folder")
                }
                .buttonStyle(.accessoryBar)
            }
        }
    }
}

// MARK: - 設定

private struct RecordingSettingsView: View {
    @Bindable var module: RecordingModule

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            if module.supportsMicrophone {
                Toggle("マイクの音声も録る", isOn: $module.capturesMicrophone)
                    // 録画中に切り替えても次回まで効かないので触らせない。
                    .disabled(module.isRecording)
                Text("会議相手の声は設定に関わらず録れる。これは自分の声を足すかどうか")
                    .metricCaptionStyle()
            } else {
                Text("マイクの同時収録は macOS 15 以降が必要")
                    .metricCaptionStyle()
            }

            Text("保存先は ~/Movies/MacToolkit")
                .metricCaptionStyle()
        }
    }
}
