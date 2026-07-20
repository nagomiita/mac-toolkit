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

    private static let historyLength = 60

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
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                // 3 桁ぶん確保して 9% と 100% で幅が変わらないようにする。
                .frame(minWidth: 34, alignment: .trailing)
        )
    }

    func detailView() -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text("\(Int((total * 100).rounded()))%").monospacedDigit()
                }

                CPUHistoryChart(values: history)
                    .frame(height: 32)

                LabeledContent("ユーザ", value: percent(user))
                LabeledContent("システム", value: percent(system))

                if let layout = coreLayoutDescription {
                    Text(layout)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                CPUCoreBars(values: perCore)
            }
            .monospacedDigit()
        )
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}

/// 直近の使用率の折れ線グラフ。
private struct CPUHistoryChart: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            // 常に一定時間ぶんの幅で描き、値が増えるたびに右から伸びるようにする。
            let step = width / CGFloat(max(1, 59))

            Path { path in
                for (index, value) in values.enumerated() {
                    let x = CGFloat(index) * step
                    let y = height * (1 - CGFloat(min(1, max(0, value))))
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(.tint, lineWidth: 1.5)
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// コアごとの使用率を縦棒で並べる。
private struct CPUCoreBars: View {
    let values: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(.tint)
                            .frame(height: geometry.size.height * CGFloat(min(1, max(0, value))))
                    }
                }
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 2))
            }
        }
        .frame(height: 24)
    }
}
