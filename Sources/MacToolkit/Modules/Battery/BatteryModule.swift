import SwiftUI
import Observation

/// バッテリーの状態を表示する。
///
/// macOS 標準のアイコンが出さない健康度・サイクル数・電力・温度を補う。
@MainActor
@Observable
final class BatteryModule: ToolModule {
    let id = "battery"
    let title = "バッテリー"
    let systemImage = "battery.100"

    private(set) var snapshot: BatteryCounters.Snapshot?

    private let counters = BatteryCounters()

    /// バッテリー非搭載機ではモジュールごと出さない。
    var isAvailable: Bool { counters.isPresent }

    func stop() {
        snapshot = nil
    }

    func tick() {
        snapshot = counters.read()
    }

    func statusItemView() -> AnyView? {
        AnyView(
            Text(snapshot.map { "\(Int(($0.charge * 100).rounded()))%" } ?? "--")
                .menuBarValueStyle()
                .frame(minWidth: 32, alignment: .trailing)
        )
    }

    func detailView() -> AnyView {
        AnyView(
            ModuleSection(
                title: title,
                systemImage: batterySymbol,
                summary: snapshot.map { "\(Int(($0.charge * 100).rounded()))%" }
            ) {
                if let snapshot {
                    // 状態は色だけでなく必ず言葉で示す。
                    Text(statusText(snapshot)).metricCaptionStyle()

                    if let health = snapshot.health {
                        MetricRow(label: "バッテリー状態", value: "\(Int((health * 100).rounded()))%")
                    }
                    if let cycles = snapshot.cycleCount {
                        MetricRow(label: "充放電回数", value: "\(cycles) 回")
                    }
                    if let watts = snapshot.watts {
                        MetricRow(
                            label: snapshot.isCharging ? "充電電力" : "消費電力",
                            value: String(format: "%.1f W", watts)
                        )
                    }
                    if let temperature = snapshot.temperature {
                        MetricRow(label: "温度", value: String(format: "%.1f °C", temperature))
                    }
                    if let adapter = snapshot.adapterWatts, snapshot.isPluggedIn {
                        MetricRow(label: "電源アダプタ", value: "\(adapter) W")
                    }
                } else {
                    Text("取得できません").metricCaptionStyle()
                }
            }
        )
    }

    private func statusText(_ s: BatteryCounters.Snapshot) -> String {
        if s.isCharging {
            if let minutes = s.minutesRemaining {
                return "充電中・満充電まで約 \(formatMinutes(minutes))"
            }
            return "充電中"
        }
        if s.isPluggedIn {
            return s.isFullyCharged ? "電源に接続済み（満充電）" : "電源に接続済み"
        }
        if let minutes = s.minutesRemaining {
            return "バッテリー駆動・残り約 \(formatMinutes(minutes))"
        }
        return "バッテリー駆動"
    }

    private func formatMinutes(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        return hours > 0 ? "\(hours) 時間 \(mins) 分" : "\(mins) 分"
    }

    /// 残量と充電状態に応じた SF Symbols のバッテリーアイコン。
    private var batterySymbol: String {
        guard let snapshot else { return "battery.100" }
        if snapshot.isCharging || (snapshot.isPluggedIn && !snapshot.isFullyCharged) {
            return "battery.100.bolt"
        }
        switch snapshot.charge {
        case ..<0.15: return "battery.25"
        case ..<0.45: return "battery.50"
        case ..<0.85: return "battery.75"
        default: return "battery.100"
        }
    }
}
