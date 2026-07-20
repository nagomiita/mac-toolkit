import SwiftUI
import Observation

/// メモリ使用量とメモリプレッシャーを表示する。
@MainActor
@Observable
final class MemoryModule: ToolModule {
    let id = "memory"
    let title = "メモリ"
    let systemImage = "memorychip"

    private(set) var snapshot: MemoryCounters.Snapshot?

    private let counters = MemoryCounters()

    func stop() {
        snapshot = nil
    }

    func tick() {
        snapshot = counters.read()
    }

    func statusItemView() -> AnyView? {
        AnyView(
            Text(snapshot.map { Self.gigabytes($0.used) } ?? "--")
                .menuBarValueStyle()
                .frame(minWidth: 44, alignment: .trailing)
        )
    }

    func detailView() -> AnyView {
        AnyView(
            ModuleSection(
                title: title,
                summary: snapshot.map { "\(Self.gigabytes($0.used)) / \(Self.gigabytes($0.total))" }
            ) {
                if let snapshot {
                    MemoryBreakdownBar(snapshot: snapshot)
                        .frame(height: 8)
                        .padding(.bottom, 2)

                    MetricRow(label: "Wired", value: Self.gigabytes(snapshot.wired))
                    MetricRow(label: "アクティブ", value: Self.gigabytes(snapshot.active))
                    MetricRow(label: "圧縮", value: Self.gigabytes(snapshot.compressed))
                    MetricRow(label: "キャッシュ", value: Self.gigabytes(snapshot.cached))

                    if snapshot.swapTotal > 0 {
                        MetricRow(
                            label: "スワップ",
                            value: "\(Self.gigabytes(snapshot.swapUsed)) / \(Self.gigabytes(snapshot.swapTotal))"
                        )
                    }

                    // 色だけに意味を持たせず、必ず数値と併記する。
                    HStack(spacing: 5) {
                        StatusDot(color: Self.pressureColor(snapshot.pressure))
                        Text("メモリプレッシャー \(Int((snapshot.pressure * 100).rounded()))%")
                            .metricCaptionStyle()
                    }
                    .padding(.top, 1)
                } else {
                    Text("取得できません").metricCaptionStyle()
                }
            }
        )
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    static func pressureColor(_ pressure: Double) -> Color {
        switch pressure {
        case ..<0.6: .green
        case ..<0.8: .yellow
        default: .red
        }
    }
}

/// メモリの内訳を積み上げバーで表す。
private struct MemoryBreakdownBar: View {
    let snapshot: MemoryCounters.Snapshot

    private var segments: [(value: UInt64, color: Color)] {
        [
            (snapshot.wired, .orange),
            (snapshot.active, .blue),
            (snapshot.compressed, .purple),
            (snapshot.cached, .gray.opacity(0.5)),
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: width(for: segment.value, in: geometry.size.width))
                }
                Spacer(minLength: 0)
            }
        }
        .background(.quaternary.opacity(0.5))
        .clipShape(Capsule())
    }

    private func width(for value: UInt64, in total: CGFloat) -> CGFloat {
        guard snapshot.total > 0 else { return 0 }
        return total * CGFloat(Double(value) / Double(snapshot.total))
    }
}
