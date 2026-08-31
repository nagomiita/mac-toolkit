import AVFoundation
import Observation
import UIKit

/// 画面全体の状態。探索 → 接続 → 視聴 の一方向の流れだけを持つ。
@MainActor
@Observable
final class ViewerModel {
    enum Phase {
        case browsing
        case connecting
        case streaming
    }

    private(set) var phase: Phase = .browsing
    /// 接続中・視聴中の Mac の名前。
    private(set) var macName: String?
    private(set) var latencyText = "N/A"
    private(set) var fpsText = "N/A"
    /// 直前の切断理由。一覧画面に出す。
    private(set) var disconnectReason: String?

    let browser = MacBrowser()
    /// 圧縮フレームをそのまま流し込む表示レイヤー。
    let displayLayer = AVSampleBufferDisplayLayer()

    private var client: StreamClient?

    init() {
        displayLayer.videoGravity = .resizeAspect
    }

    func startBrowsing() {
        browser.start()
    }

    func connect(to mac: MacBrowser.Endpoint) {
        guard phase == .browsing else { return }
        disconnectReason = nil
        macName = mac.name
        phase = .connecting
        displayLayer.flushAndRemoveImage()

        let client = StreamClient(layer: displayLayer)
        self.client = client
        client.connect(
            to: mac.endpoint,
            deviceName: UIDevice.current.name
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        phase = .browsing
        resetStats()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func handle(_ event: StreamClient.Event) {
        guard client != nil else { return }
        switch event {
        case .connected:
            phase = .streaming
            // 視聴中に画面が消灯しないようにする。
            UIApplication.shared.isIdleTimerDisabled = true
        case .disconnected(let reason):
            client = nil
            phase = .browsing
            disconnectReason = reason
            resetStats()
            UIApplication.shared.isIdleTimerDisabled = false
        case .stats(let latencyMs, let fps):
            latencyText = latencyMs >= 0 ? String(format: "%.0f ms", latencyMs) : "N/A"
            fpsText = String(format: "%.0f fps", fps)
        }
    }

    private func resetStats() {
        latencyText = "N/A"
        fpsText = "N/A"
    }
}
