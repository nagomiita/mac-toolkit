import Foundation

/// 全モジュール共通のティッカー。
///
/// モジュールごとに Timer を持つと、常駐アプリでウェイクアップ回数が増えて
/// 電力効率が悪くなるため、更新は必ずここに集約する。
@MainActor
final class Sampler {
    private var timer: Timer?
    private var handler: (() -> Void)?

    /// 更新間隔（秒）。設定画面から変更される。
    private(set) var interval: TimeInterval

    init(interval: TimeInterval = 1.0) {
        self.interval = interval
    }

    func start(handler: @escaping () -> Void) {
        self.handler = handler
        schedule()
    }

    func setInterval(_ newValue: TimeInterval) {
        guard newValue != interval else { return }
        interval = newValue
        if timer != nil { schedule() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.handler?() }
        }
        // メニュー操作中も更新を止めないため .common モードで登録する。
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
