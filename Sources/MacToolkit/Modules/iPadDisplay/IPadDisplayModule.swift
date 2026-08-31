import AppKit
import Observation
import SwiftUI

/// iPad をサブディスプレイとして使うための画面配信。
///
/// Mac 側は Bonjour で自分を広告して待ち受けるだけで、接続の操作は
/// すべて iPad 側アプリ（ipad/MacToolkitDisplay.swiftpm）から行う。
/// Sidecar の代替ではなく「映像を低遅延で送る」ことに絞った PoC。
@MainActor
@Observable
final class IPadDisplayModule: ToolModule {
    let id = "ipaddisplay"
    let title = "iPad ディスプレイ"
    let systemImage = "ipad.landscape"

    /// 配信対象の種類。
    enum CaptureMode: String {
        case display
        case window
    }

    /// ウインドウ選択の候補。
    struct TargetWindow: Identifiable, Hashable {
        let id: CGWindowID
        let appName: String
        let title: String

        var displayName: String { "\(appName) — \(title)" }
    }

    /// 待ち受け中か（iPad が接続しているかは isClientConnected）。
    private(set) var isServing = false
    private(set) var isClientConnected = false
    /// hello で受け取った iPad の端末名。
    private(set) var clientName: String?
    /// iPad 側で計測した遅延。未計測なら nil。
    private(set) var latencyMs: Double?
    private(set) var receivedFPS: Double?

    private(set) var message: String?
    private(set) var needsPermission = false
    /// 開始・停止の非同期処理中の二重操作を防ぐ。
    private(set) var isBusy = false

    private(set) var windows: [TargetWindow] = []

    var captureMode: CaptureMode {
        didSet { UserDefaults.standard.set(captureMode.rawValue, forKey: Self.modeKey) }
    }
    var selectedWindowID: CGWindowID?
    var fps: Int {
        didSet { UserDefaults.standard.set(fps, forKey: Self.fpsKey) }
    }
    var bitrateMbps: Int {
        didSet { UserDefaults.standard.set(bitrateMbps, forKey: Self.bitrateKey) }
    }
    var usesRetina: Bool {
        didSet { UserDefaults.standard.set(usesRetina, forKey: Self.retinaKey) }
    }

    @ObservationIgnored private let streamer = DisplayStreamer()

    private static let modeKey = "ipaddisplay.mode"
    private static let fpsKey = "ipaddisplay.fps"
    private static let bitrateKey = "ipaddisplay.bitrateMbps"
    private static let retinaKey = "ipaddisplay.retina"

    init() {
        let defaults = UserDefaults.standard
        captureMode = CaptureMode(
            rawValue: defaults.string(forKey: Self.modeKey) ?? ""
        ) ?? .display
        let fps = defaults.integer(forKey: Self.fpsKey)
        self.fps = fps > 0 ? fps : 60
        let bitrate = defaults.integer(forKey: Self.bitrateKey)
        bitrateMbps = bitrate > 0 ? bitrate : 8
        usesRetina = defaults.bool(forKey: Self.retinaKey)
    }

    func stop() {
        // モジュールが無効化されたら配信も止める。
        if isServing { stopServing() }
    }

    /// 配信の状態はすべてイベント駆動で更新されるので tick では何もしない。
    func tick() {}

    // MARK: - 操作

    func toggle() {
        if isServing { stopServing() } else { startServing() }
    }

    func startServing() {
        guard !isServing, !isBusy else { return }
        message = nil

        guard ScreenCapturer.hasPermission else {
            ScreenCapturer.requestPermission()
            // 許可は再起動後に効くことがあるため、その場では配信に進まない。
            needsPermission = true
            message = "画面収録の権限が必要です"
            return
        }
        needsPermission = false

        let target: DisplayStreamer.Target
        switch captureMode {
        case .display:
            target = .display
        case .window:
            guard let windowID = selectedWindowID else {
                message = "配信するウインドウを選択"
                return
            }
            target = .window(windowID)
        }

        let configuration = DisplayStreamer.Configuration(
            target: target,
            fps: fps,
            bitrate: bitrateMbps * 1_000_000,
            usesRetina: usesRetina
        )
        // iPad の一覧に出る名前。Mac 本体の名前をそのまま使う。
        let serviceName = Host.current().localizedName ?? "Mac"

        do {
            try streamer.start(
                configuration: configuration, serviceName: serviceName
            ) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handle(event)
                }
            }
            isServing = true
        } catch {
            message = error.localizedDescription
        }
    }

    func stopServing() {
        guard isServing, !isBusy else { return }
        isBusy = true
        isServing = false
        isClientConnected = false
        clientName = nil
        latencyMs = nil
        receivedFPS = nil

        Task { @MainActor in
            defer { isBusy = false }
            await streamer.stop()
        }
    }

    private func handle(_ event: DisplayStreamer.Event) {
        guard isServing else { return }
        switch event {
        case .clientConnected:
            isClientConnected = true
            clientName = nil
            latencyMs = nil
            receivedFPS = nil
            message = nil
        case .clientNamed(let name):
            clientName = name
        case .clientDisconnected:
            isClientConnected = false
            clientName = nil
            latencyMs = nil
            receivedFPS = nil
        case .stats(let latency, let fps):
            latencyMs = latency >= 0 ? latency : nil
            receivedFPS = fps
        case .captureFailed(let detail):
            message = "配信が中断されました（\(detail)）"
        case .serverFailed(let detail):
            message = detail
            stopServing()
        }
    }

    // MARK: - ウインドウ一覧

    /// 配信候補のウインドウを列挙し直す。
    ///
    /// ウインドウ ID は再起動で変わる使い捨ての値なので永続化しない。
    /// タイトルの取得（kCGWindowName）には画面収録の権限が必要。
    func refreshWindows() {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] else {
            windows = []
            return
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        windows = raw.compactMap { info in
            guard let layer = info[kCGWindowLayer] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID] as? pid_t, pid != ownPID,
                  let number = info[kCGWindowNumber] as? Int,
                  let boundsDict = info[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 100, bounds.height >= 100,
                  let appName = info[kCGWindowOwnerName] as? String,
                  let title = info[kCGWindowName] as? String, !title.isEmpty
            else { return nil }
            return TargetWindow(id: CGWindowID(number), appName: appName, title: title)
        }

        // 選択していたウインドウが閉じられていたら選択を外す。
        if let selected = selectedWindowID,
           !windows.contains(where: { $0.id == selected }) {
            selectedWindowID = nil
        }
    }

    /// アプリを再起動する。画面収録の許可は再起動後に反映されるため。
    func relaunch() {
        guard !isServing else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: configuration
        ) { _, _ in
            Task { @MainActor in
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // MARK: - 表示用テキスト

    var latencyText: String {
        guard let latencyMs else { return "N/A" }
        return String(format: "%.0f ms", latencyMs)
    }

    var receivedFPSText: String {
        guard let receivedFPS else { return "N/A" }
        return String(format: "%.0f fps", receivedFPS)
    }

    var statusText: String {
        if !isServing { return "停止中" }
        return isClientConnected ? "配信中" : "接続待ち"
    }

    // MARK: - View

    /// iPad が接続している間だけメニューバーに出す。待機中は幅を取らない。
    func statusItemView() -> AnyView? {
        guard isClientConnected else { return nil }
        return AnyView(
            Image(systemName: "ipad.landscape")
                .menuBarValueStyle()
        )
    }

    func detailView() -> AnyView {
        AnyView(IPadDisplaySectionView(module: self))
    }

    func settingsView() -> AnyView? {
        AnyView(IPadDisplaySettingsView(module: self))
    }
}

// MARK: - ポップオーバー

private struct IPadDisplaySectionView: View {
    @Bindable var module: IPadDisplayModule

    var body: some View {
        ModuleSection(
            title: module.title,
            systemImage: module.systemImage,
            summary: module.isServing ? module.statusText : nil
        ) {
            Button {
                module.toggle()
            } label: {
                if module.isBusy {
                    Label("停止中…", systemImage: "hourglass")
                } else if module.isServing {
                    Label("配信を停止", systemImage: "stop.circle")
                } else {
                    Label("配信を開始", systemImage: "play.circle")
                }
            }
            .buttonStyle(.accessoryBar)
            .disabled(module.isBusy)

            if module.isServing {
                MetricRow(label: "状態", value: module.statusText)
                if module.isClientConnected {
                    MetricRow(label: "接続先", value: module.clientName ?? "iPad")
                    MetricRow(label: "遅延", value: module.latencyText)
                    MetricRow(label: "受信 FPS", value: module.receivedFPSText)
                }
            }

            Text("iPad 側で MacToolkit Display を開いて接続する")
                .metricCaptionStyle()

            if let message = module.message {
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
        }
    }
}

// MARK: - 設定

private struct IPadDisplaySettingsView: View {
    @Bindable var module: IPadDisplayModule

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            Picker("配信対象", selection: $module.captureMode) {
                Text("画面全体").tag(IPadDisplayModule.CaptureMode.display)
                Text("ウインドウ").tag(IPadDisplayModule.CaptureMode.window)
            }

            if module.captureMode == .window {
                Picker("ウインドウ", selection: $module.selectedWindowID) {
                    Text("未選択").tag(CGWindowID?.none)
                    ForEach(module.windows) { window in
                        Text(window.displayName)
                            .lineLimit(1)
                            .tag(CGWindowID?.some(window.id))
                    }
                }
                Button("一覧を更新") {
                    module.refreshWindows()
                }
                .buttonStyle(.accessoryBar)
            }

            Picker("フレームレート", selection: $module.fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }

            Picker("ビットレート", selection: $module.bitrateMbps) {
                Text("4 Mbps").tag(4)
                Text("8 Mbps").tag(8)
                Text("12 Mbps").tag(12)
                Text("20 Mbps").tag(20)
            }

            Toggle("Retina 解像度で送る", isOn: $module.usesRetina)
            Text("オンにするとデータ量が約 4 倍になる。文字の細さ優先のときだけ")
                .metricCaptionStyle()

            if module.isServing {
                Text("設定は次回の配信開始から反映される")
                    .metricCaptionStyle()
            }
        }
        .onAppear {
            if module.captureMode == .window, module.windows.isEmpty {
                module.refreshWindows()
            }
        }
        // 配信中に変えても既に走っているストリームには効かないため触らせない。
        .disabled(module.isServing)
    }
}
