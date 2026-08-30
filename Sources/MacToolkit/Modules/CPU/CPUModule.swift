import SwiftUI
import Observation

/// CPU 使用率をメニューバーとポップオーバーに表示する。
@MainActor
@Observable
final class CPUModule: ToolModule {
    let id = "cpu"
    let title = "CPU"
    let systemImage = "cpu"

    /// 全体の使用率（0.0〜1.0）。
    private(set) var total: Double = 0
    private(set) var user: Double = 0
    private(set) var system: Double = 0
    /// コアごとの使用率。添字がコア番号。
    private(set) var perCore: [Double] = []
    /// 直近の履歴（グラフ用）。末尾が最新。
    private(set) var history: [Double] = []

    private let counters = CPUCounters()
    private var previous: [CPUCounters.Ticks]?

    static let historyLength = 60

    var coreLayoutDescription: String? {
        guard let p = counters.performanceCoreCount,
              let e = counters.efficiencyCoreCount, p > 0, e > 0
        else { return nil }
        return "高性能 \(p) + 高効率 \(e)"
    }

    func start() {
        previous = counters.read()
    }

    func stop() {
        previous = nil
        total = 0
        user = 0
        system = 0
        perCore = []
        history = []
    }

    func tick() {
        let current = counters.read()
        guard !current.isEmpty else { return }

        defer { previous = current }
        guard let last = previous else { return }

        let usage = CPUCounters.usage(from: last, to: current)
        guard !usage.isEmpty else { return }

        let cores = Double(usage.count)
        user = usage.reduce(0) { $0 + $1.user } / cores
        system = usage.reduce(0) { $0 + $1.system } / cores
        // nice は user 側に含めて表示する（アクティビティモニタと同じ扱い）。
        user += usage.reduce(0) { $0 + $1.nice } / cores
        total = min(1, user + system)
        perCore = usage.map { min(1, $0.total) }

        history.append(total)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }

    func statusItemView() -> AnyView? {
        AnyView(
            Text("\(Int((total * 100).rounded()))%")
                .menuBarValueStyle()
                // 3 桁ぶん確保して 9% と 100% で幅が変わらないようにする。
                .frame(minWidth: 32, alignment: .trailing)
        )
    }

    func detailView() -> AnyView {
        AnyView(
            ModuleSection(
                title: title,
                systemImage: systemImage,
                summary: "\(Int((total * 100).rounded()))%"
            ) {
                UsageHistoryChart(values: history, capacity: Self.historyLength)
                    .frame(height: 30)
                    .padding(.bottom, 2)

                MetricRow(label: "ユーザ", value: percent(user))
                MetricRow(label: "システム", value: percent(system))

                CPUCoreBars(values: perCore)
                    .padding(.top, 2)

                if let layout = coreLayoutDescription {
                    Text(layout).metricCaptionStyle()
                }
            }
        )
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}

/// コアごとの使用率を縦棒で並べる。
private struct CPUCoreBars: View {
    let values: [Double]

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(.tint)
                            .frame(height: geometry.size.height * CGFloat(min(1, max(0, value))))
                    }
                }
                .background(trackStyle)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .accessibilityLabel("コア \(index + 1)")
                .accessibilityValue("\(Int((value * 100).rounded()))パーセント")
            }
        }
        .frame(height: 20)
    }

    private var trackStyle: AnyShapeStyle {
        reduceTransparency
            ? AnyShapeStyle(Color.secondary.opacity(0.25))
            : AnyShapeStyle(.quaternary.opacity(0.5))
    }
}
