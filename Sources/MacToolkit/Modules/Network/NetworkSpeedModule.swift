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

    /// 直近 10 分に出た最大ダウンロード速度。回線の速さの判定に使う。
    private(set) var peakDownloadRate: Double?
    /// 回線の速さ。材料が足りなければ nil。
    private(set) var rating: ThroughputRating?

    private let counters = InterfaceCounters()
    private var previous: InterfaceCounters.Sample?
    private var previousInterface: String?
    private var lastSampledAt: Date?
    private var peakWindow = PeakWindow()

    func stop() {
        previous = nil
        previousInterface = nil
        lastSampledAt = nil
        downloadRate = 0
        uploadRate = 0
        resetPeak()
    }

    private func resetPeak() {
        peakWindow.reset()
        peakDownloadRate = nil
        rating = nil
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
            // オフラインの間の 0 を「遅い回線」として残さない。
            resetPeak()
            return
        }

        interfaceName = name

        // インターフェースが変わったら（Wi-Fi ↔ 有線）前回値は無意味。
        guard name == previousInterface, let last = previous, let lastAt = lastSampledAt else {
            previous = current
            previousInterface = name
            downloadRate = 0
            uploadRate = 0
            // 有線で出た値で Wi-Fi を判定してしまわないよう、切り替わりで捨てる。
            resetPeak()
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

        // 判定は下り基準。上りは回線の契約上そもそも細いことが多く、
        // 「遅い」と読ませてしまう。
        peakWindow.record(downloadRate, at: now)
        peakDownloadRate = peakWindow.peak
        rating = ThroughputRating.rating(peakBytesPerSecond: peakDownloadRate)
    }

    /// カウンタは 2^32 で折り返し、インターフェースの up/down でもリセットされる。
    /// 減っていたらその 1 回分の値は捨てる（次のティックで正常に戻る）。
    private func rate(from previous: UInt64, to current: UInt64, seconds: TimeInterval) -> Double {
        guard current >= previous else { return 0 }
        return Double(current - previous) / seconds
    }

    func statusItemView() -> AnyView? {
        AnyView(
            // 2 段組みはメニューバーの高さでは窮屈なので、矢印付きで横に並べる。
            // 幅を固定して、桁が変わっても隣のアイコンが動かないようにする。
            HStack(spacing: 5) {
                label("arrow.down", ByteRate.format(bytesPerSecond: downloadRate))
                label("arrow.up", ByteRate.format(bytesPerSecond: uploadRate))
            }
            .menuBarValueStyle()
        )
    }

    private func label(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 8, weight: .semibold))
            Text(text).frame(minWidth: 54, alignment: .leading)
        }
    }

    /// 折りたたみ時にも速度が分かるよう、見出しに要約を出す。
    private var summary: String? {
        guard interfaceName != nil else { return nil }
        return "↓\(ByteRate.format(bytesPerSecond: downloadRate))"
    }

    func detailView() -> AnyView {
        AnyView(
            ModuleSection(title: title, systemImage: systemImage, summary: summary) {
                if let interfaceName {
                    MetricRow(
                        label: "ダウンロード",
                        value: ByteRate.format(bytesPerSecond: downloadRate)
                    )
                    MetricRow(
                        label: "アップロード",
                        value: ByteRate.format(bytesPerSecond: uploadRate)
                    )

                    if let peakDownloadRate {
                        MetricRow(
                            label: "直近の最大",
                            value: ByteRate.format(bytesPerSecond: peakDownloadRate)
                        )
                    }

                    if let rating {
                        RatingRow(rating: rating)
                        Text("直近 10 分の最大値から判定").metricCaptionStyle()
                    } else {
                        Text("判定するには通信量が足りません").metricCaptionStyle()
                    }

                    Text("インターフェース \(interfaceName)").metricCaptionStyle()
                } else {
                    Text("接続されていません").metricCaptionStyle()
                }
            }
        )
    }
}

/// 回線の速さを、色付きの丸と語で示す。
///
/// 数値の行と違い「良し悪し」を伝えるのが目的なので、
/// 信号強度（`MeterBar`）と同じく色を先に読ませる。
private struct RatingRow: View {
    let rating: ThroughputRating

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("回線の速さ").metricLabelStyle()
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(rating.label)
            }
            .metricValueStyle()
        }
    }

    private var color: Color {
        switch rating {
        case .slow: .red
        case .normal: .yellow
        case .fast: .green
        }
    }
}
