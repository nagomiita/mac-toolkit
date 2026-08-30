import SwiftUI
import Observation

/// GPU 使用率を表示する。
@MainActor
@Observable
final class GPUModule: ToolModule {
    let id = "gpu"
    let title = "GPU"
    let systemImage = "cpu.fill"

    /// 使用率（0.0〜1.0）。取得できない場合は nil。
    private(set) var utilization: Double?
    private(set) var inUseMemory: UInt64?
    /// 直近の履歴（グラフ用）。末尾が最新。
    private(set) var history: [Double] = []

    private let counters = GPUCounters()

    static let historyLength = 60

    var deviceName: String? { counters.deviceName }

    func stop() {
        utilization = nil
        inUseMemory = nil
        history = []
    }

    func tick() {
        let snapshot = counters.read()
        utilization = snapshot.utilization
        inUseMemory = snapshot.inUseMemory

        // 取得できたときだけ履歴に積む。取得できない環境で 0 を積むと
        // 「使用率 0%」と誤読されるため。
        if let value = snapshot.utilization {
            history.append(value)
            if history.count > Self.historyLength {
                history.removeFirst(history.count - Self.historyLength)
            }
        }
    }

    func statusItemView() -> AnyView? {
        AnyView(
            Text(utilization.map { "\(Int(($0 * 100).rounded()))%" } ?? "--")
                .menuBarValueStyle()
                .frame(minWidth: 32, alignment: .trailing)
        )
    }

    func detailView() -> AnyView {
        AnyView(
            ModuleSection(
                title: title,
                systemImage: systemImage,
                summary: utilization.map { "\(Int(($0 * 100).rounded()))%" }
            ) {
                if utilization == nil {
                    // キーが見つからない環境でもクラッシュせず、その旨を出す。
                    Text("使用率を取得できません").metricCaptionStyle()
                } else {
                    UsageHistoryChart(values: history)
                        .frame(height: 30)
                        .padding(.bottom, 2)

                    if let memory = inUseMemory {
                        MetricRow(label: "使用メモリ", value: MemoryModule.megabytes(memory))
                    }
                }

                if let name = deviceName {
                    Text(name).metricCaptionStyle()
                }
            }
        )
    }
}
