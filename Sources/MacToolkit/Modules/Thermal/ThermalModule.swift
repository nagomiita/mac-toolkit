import SwiftUI
import Observation

/// 温度とファンを表示する。
///
/// macOS 標準では見えない SoC・バッテリー・ストレージの温度と、ファンの
/// 回転数を出す。ファンレス機（MacBook Air など）では「ファンなし」と示す。
@MainActor
@Observable
final class ThermalModule: ToolModule {
    let id = "thermal"
    let title = "温度"
    let systemImage = "thermometer.medium"

    private(set) var snapshot: ThermalSensors.Snapshot?
    /// SoC 温度の履歴（グラフ用・0.0〜1.0 に正規化）。末尾が最新。
    private(set) var history: [Double] = []

    private let sensors = ThermalSensors()
    private var isReading = false
    private var tickCount = 0

    static let historyLength = 60
    /// 何ティックに 1 回センサーを読むか。温度はゆっくり変わるうえ全センサーの
    /// 読み取りは 40ms 前後かかるため、毎ティックは読まない。
    private static let readEveryTicks = 3

    /// 温度もファンも読めない機種（多くの Intel 機など）ではモジュールごと隠す。
    var isAvailable: Bool { sensors.isAvailable }

    func stop() {
        snapshot = nil
        history = []
        tickCount = 0
    }

    func tick() {
        tickCount += 1
        guard tickCount % Self.readEveryTicks == 1 else { return }
        guard !isReading else { return }
        isReading = true

        // センサー読み取りは重いのでバックグラウンドへ逃がす。
        Task.detached(priority: .utility) { [sensors] in
            let snapshot = sensors.read()
            await MainActor.run {
                self.publish(snapshot)
                self.isReading = false
            }
        }
    }

    private func publish(_ snapshot: ThermalSensors.Snapshot) {
        self.snapshot = snapshot

        // 取得できたときだけ履歴に積む（0 を積むと「0℃」と誤読されるため）。
        if let soc = snapshot.socTemperature {
            history.append(min(1, max(0, soc / 100)))
            if history.count > Self.historyLength {
                history.removeFirst(history.count - Self.historyLength)
            }
        }
    }

    func statusItemView() -> AnyView? {
        AnyView(
            Text(Self.formatTemperature(snapshot?.socTemperature) ?? "--")
                .menuBarValueStyle()
                .frame(minWidth: 40, alignment: .trailing)
        )
    }

    func detailView() -> AnyView {
        AnyView(
            ModuleSection(
                title: title,
                systemImage: systemImage,
                summary: Self.formatTemperature(snapshot?.socTemperature)
            ) {
                if let snapshot {
                    if !history.isEmpty {
                        UsageHistoryChart(values: history)
                            .frame(height: 30)
                            .padding(.bottom, 2)
                    }

                    if let soc = snapshot.socTemperature {
                        MetricRow(label: "SoC", value: Self.formatTemperature(soc)!)
                    }
                    if let battery = snapshot.batteryTemperature {
                        MetricRow(label: "バッテリー", value: Self.formatTemperature(battery)!)
                    }
                    if let storage = snapshot.storageTemperature {
                        MetricRow(label: "ストレージ", value: Self.formatTemperature(storage)!)
                    }
                    MetricRow(label: "ファン", value: Self.fanText(snapshot))
                } else {
                    // 初回読み取りが返るまで、または取得できない場合。
                    Text("取得できません").metricCaptionStyle()
                }
            }
        )
    }

    /// 温度を「39℃」の形にする。nil なら nil。
    static func formatTemperature(_ celsius: Double?) -> String? {
        guard let celsius else { return nil }
        return "\(Int(celsius.rounded()))°C"
    }

    /// ファンの表示。ファンレス機は「ファンなし」、複数ファンは平均を出す。
    private static func fanText(_ snapshot: ThermalSensors.Snapshot) -> String {
        guard snapshot.fanCount > 0 else { return "ファンなし" }
        guard !snapshot.fanRPM.isEmpty else { return "取得できません" }
        let average = snapshot.fanRPM.reduce(0, +) / Double(snapshot.fanRPM.count)
        return "\(Int(average.rounded())) rpm"
    }
}
