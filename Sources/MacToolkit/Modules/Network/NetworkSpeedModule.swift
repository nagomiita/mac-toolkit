import SwiftUI
import Observation

/// デフォルトルートのインターフェースの通信速度をメニューバーに表示する。
@MainActor
@Observable
final class NetworkSpeedModule: ToolModule {
    let id = "network"
    let title = "ネットワーク"
    let systemImage = "network"

    private(set) var downloadRate: Double = 0
    private(set) var uploadRate: Double = 0
    /// 監視中のインターフェース名。取得できない（オフライン）ときは nil。
    private(set) var interfaceName: String?

    private let counters = InterfaceCounters()
    private var previous: InterfaceCounters.Sample?
    private var previousInterface: String?
    private var lastSampledAt: Date?

    func stop() {
        previous = nil
        previousInterface = nil
        lastSampledAt = nil
        downloadRate = 0
        uploadRate = 0
    }

    func tick() {
        let now = Date()
        defer { lastSampledAt = now }

        guard let name = counters.primaryInterfaceName(),
              let current = counters.readAll()[name]
        else {
            // オフラインなど。速度は 0 にするが、値が「取れなかった」のか
            // 「本当に 0」なのかは interfaceName の有無で区別できる。
            interfaceName = nil
            previous = nil
            downloadRate = 0
            uploadRate = 0
            return
        }

        interfaceName = name

        // インターフェースが変わったら（Wi-Fi ↔ 有線）前回値は無意味。
        guard name == previousInterface, let last = previous, let lastAt = lastSampledAt else {
            previous = current
            previousInterface = name
            downloadRate = 0
            uploadRate = 0
            return
        }

        // 実際の経過時間で割る。Timer は tolerance の分ずれるため、
        // 設定間隔で割ると速度が最大 10% ずれる。
        let elapsed = now.timeIntervalSince(lastAt)
        guard elapsed > 0 else { return }

        downloadRate = rate(from: last.received, to: current.received, seconds: elapsed)
        uploadRate = rate(from: last.sent, to: current.sent, seconds: elapsed)

        previous = current
        previousInterface = name
    }

    /// カウンタは 2^32 で折り返し、インターフェースの up/down でもリセットされる。
    /// 減っていたらその 1 回分の値は捨てる（次のティックで正常に戻る）。
    private func rate(from previous: UInt64, to current: UInt64, seconds: TimeInterval) -> Double {
        guard current >= previous else { return 0 }
        return Double(current - previous) / seconds
    }

    func statusItemView() -> AnyView? {
        AnyView(
            VStack(alignment: .trailing, spacing: -2) {
                Text("↓ " + ByteRate.format(bytesPerSecond: downloadRate))
                Text("↑ " + ByteRate.format(bytesPerSecond: uploadRate))
            }
            .font(.system(size: 9, design: .monospaced))
            .monospacedDigit()
        )
    }

    func detailView() -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)

                if let interfaceName {
                    LabeledContent("ダウンロード", value: ByteRate.format(bytesPerSecond: downloadRate))
                    LabeledContent("アップロード", value: ByteRate.format(bytesPerSecond: uploadRate))
                    LabeledContent("インターフェース", value: interfaceName)
                } else {
                    Text("接続されていません")
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
        )
    }
}
