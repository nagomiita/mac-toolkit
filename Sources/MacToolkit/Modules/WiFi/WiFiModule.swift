import SwiftUI
import CoreWLAN
import CoreLocation
import Observation

/// 接続中の Wi-Fi の詳細を表示する。
///
/// このモジュールは `tick()` でポーリングせず、CoreWLAN のイベント通知で
/// 更新する（方針: 離散的に変化する情報はイベント駆動）。RSSI の変動も
/// linkQualityDidChange で通知される。
@MainActor
@Observable
final class WiFiModule: NSObject, ToolModule {
    let id = "wifi"
    let title = "Wi-Fi"
    let systemImage = "wifi"

    private(set) var info: WiFiInfo?
    private(set) var locationAuthorization: CLAuthorizationStatus

    private let client = CWWiFiClient.shared()
    private let locationManager = CLLocationManager()
    private var isMonitoring = false

    /// Wi-Fi インターフェースを持たない Mac ではモジュールごと出さない。
    var isAvailable: Bool { client.interface() != nil }

    override init() {
        locationAuthorization = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self
    }

    /// SSID の取得には位置情報の許可が要る。他の項目は許可なしで取得できる。
    var needsLocationPermission: Bool {
        switch locationAuthorization {
        case .authorized, .authorizedAlways: false
        default: true
        }
    }

    func start() {
        refresh()
        guard !isMonitoring else { return }

        client.delegate = self
        // 監視できるイベントだけ登録する。1 つ失敗しても他は登録を続ける。
        for event in [CWEventType.ssidDidChange, .bssidDidChange, .linkDidChange,
                      .linkQualityDidChange, .powerDidChange] {
            do {
                try client.startMonitoringEvent(with: event)
            } catch {
                NSLog("[\(id)] failed to monitor \(event.rawValue): \(error)")
            }
        }
        isMonitoring = true
    }

    func stop() {
        if isMonitoring {
            try? client.stopMonitoringAllEvents()
            client.delegate = nil
            isMonitoring = false
        }
        info = nil
    }

    /// イベント駆動なので毎ティックの取得はしない。
    ///
    /// ただし IP アドレスの変更（DHCP の更新など）は CoreWLAN のイベントでは
    /// 通知されないため、接続中は時々だけ取り直す。
    func tick() {
        guard info != nil else { return }
        tickCount += 1
        if tickCount % 10 == 0 { refresh() }
    }

    private var tickCount = 0

    private func refresh() {
        guard let interface = client.interface() else {
            info = nil
            return
        }
        info = WiFiReader.read(from: interface)
    }

    /// ユーザー操作で位置情報の許可を求める。
    func requestLocationPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    func openLocationSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        )
        if let url { NSWorkspace.shared.open(url) }
    }

    func detailView() -> AnyView {
        AnyView(WiFiDetailView(module: self))
    }
}

// MARK: - CoreWLAN のイベント

extension WiFiModule: CWEventDelegate {
    // CoreWLAN のコールバックは背景スレッドで来るので MainActor へ移す。
    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in refresh() }
    }

    nonisolated func bssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in refresh() }
    }

    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in refresh() }
    }

    nonisolated func linkQualityDidChangeForWiFiInterface(
        withName interfaceName: String,
        rssi: Int,
        transmitRate: Double
    ) {
        Task { @MainActor in refresh() }
    }

    nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in refresh() }
    }
}

// MARK: - 位置情報の許可

extension WiFiModule: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            locationAuthorization = status
            // 許可された直後は SSID が取れるようになるので読み直す。
            refresh()
        }
    }
}

// MARK: - 表示

private struct WiFiDetailView: View {
    let module: WiFiModule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(module.title).font(.headline)

            if let info = module.info {
                connected(info)
            } else {
                Text("Wi-Fi はオフです")
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
    }

    @ViewBuilder
    private func connected(_ info: WiFiInfo) -> some View {
        if let ssid = info.ssid {
            LabeledContent("ネットワーク", value: ssid)
        } else if module.needsLocationPermission {
            permissionNotice
        }

        LabeledContent("信号強度", value: "\(info.rssi) dBm")
        LabeledContent("ノイズ", value: "\(info.noise) dBm (SN \(info.signalToNoise) dB)")

        if let channel = info.channel, let band = info.band {
            LabeledContent("チャンネル", value: "\(channel) / \(band) / \(info.channelWidth ?? "-")")
        }

        LabeledContent("規格", value: info.phyMode)
        LabeledContent("送信レート", value: String(format: "%.0f Mbps", info.transmitRate))
        LabeledContent("セキュリティ", value: info.security)

        if let ip = info.ipAddress {
            LabeledContent("IP アドレス", value: ip)
        }
    }

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ネットワーク名の表示には位置情報の許可が必要です")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if module.locationAuthorization == .notDetermined {
                Button("許可する") { module.requestLocationPermission() }
            } else {
                Button("システム設定を開く") { module.openLocationSettings() }
            }
        }
    }
}
