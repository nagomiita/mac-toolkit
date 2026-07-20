import SwiftUI
import Observation

/// 基盤の動作確認用のダミーモジュール。
/// 実際の計測モジュール（Issue #2 以降）が揃ったら削除する。
@MainActor
@Observable
final class PlaceholderModule: ToolModule {
    // id は UserDefaults のキーなので英語。title は画面に出るので日本語。
    let id = "placeholder"
    let title = "動作確認"
    let systemImage = "gauge.with.dots.needle.33percent"

    private(set) var ticks = 0
    private(set) var isRunning = false

    func start() {
        isRunning = true
        NSLog("[\(id)] start")
    }

    func stop() {
        isRunning = false
        NSLog("[\(id)] stop")
    }

    func tick() {
        ticks += 1
    }

    func statusItemView() -> AnyView? {
        AnyView(
            Text("\(ticks)")
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()
        )
    }

    func detailView() -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text("カウント: \(ticks)").monospacedDigit()
                Text(isRunning ? "動作中" : "停止中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        )
    }
}
