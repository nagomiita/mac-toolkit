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
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .frame(minWidth: 42, alignment: .trailing)
        )
    }

    func detailView() -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if let snapshot {
                        Text("\(Self.gigabytes(snapshot.used)) / \(Self.gigabytes(snapshot.total))")
                            .monospacedDigit()
                    }
                }

                if let snapshot {
                    MemoryBreakdownBar(snapshot: snapshot)
                        .frame(height: 10)

                    LabeledContent("Wired", value: Self.gigabytes(snapshot.wired))
                    LabeledContent("アクティブ", value: Self.gigabytes(snapshot.active))
                    LabeledContent("圧縮", value: Self.gigabytes(snapshot.compressed))
                    LabeledContent("キャッシュ", value: Self.gigabytes(snapshot.cached))

                    if snapshot.swapTotal > 0 {
                        LabeledContent(
                            "スワップ",
                            value: "\(Self.gigabytes(snapshot.swapUsed)) / \(Self.gigabytes(snapshot.swapTotal))"
                        )
                    }

                    HStack(spacing: 4) {
                        Circle()
                            .fill(Self.pressureColor(snapshot.pressure))
                            .frame(width: 8, height: 8)
                        Text("メモリプレッシャー \(Int((snapshot.pressure * 100).rounded()))%")
                            .font(.caption)
                    }
                } else {
                    Text("取得できません")
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
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
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func width(for value: UInt64, in total: CGFloat) -> CGFloat {
        guard snapshot.total > 0 else { return 0 }
        return total * CGFloat(Double(value) / Double(snapshot.total))
    }
}
