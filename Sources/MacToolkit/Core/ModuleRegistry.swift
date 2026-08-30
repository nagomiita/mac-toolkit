import Foundation
import Observation

/// 全モジュールの登録・有効/無効・ライフサイクルを管理する。
@MainActor
@Observable
final class ModuleRegistry {
    /// 登録順＝メニューバーでの表示順。
    private(set) var modules: [any ToolModule] = []

    /// 有効なモジュールの id 集合。UserDefaults に永続化する。
    private(set) var enabledIDs: Set<String> = []

    /// メニューバー本体に数値を出すモジュールの id 集合。
    ///
    /// 全部を出すとメニューバーが埋まるため、既定では常に動き続ける値
    /// （CPU とネットワーク）だけを出し、残りはポップオーバーに置く。
    private(set) var menuBarIDs: Set<String> = []

    var interval: TimeInterval {
        didSet {
            UserDefaults.standard.set(interval, forKey: Self.intervalKey)
            sampler.setInterval(interval)
        }
    }

    private let sampler: Sampler
    private static let enabledKey = "enabledModuleIDs"
    private static let menuBarKey = "menuBarModuleIDs"
    private static let intervalKey = "sampleInterval"
    /// recording と lidsleep は動作中しか描画しない（待機中は statusItemView が
    /// nil）ので、既定に入れても平常時のメニューバーの幅は変わらない。
    /// lidsleep は「スリープ抑止がオンのまま」を見えるようにする警告なので既定に含める。
    private static let defaultMenuBarIDs: Set<String> = ["cpu", "network", "recording", "lidsleep"]

    init(modules: [any ToolModule]) {
        let saved = UserDefaults.standard.double(forKey: Self.intervalKey)
        let interval = saved > 0 ? saved : 1.0
        self.interval = interval
        self.sampler = Sampler(interval: interval)

        self.modules = modules.filter(\.isAvailable)

        if let stored = UserDefaults.standard.stringArray(forKey: Self.enabledKey) {
            enabledIDs = Set(stored)
        } else {
            // 初回起動時は利用可能なモジュールを全て有効にする。
            enabledIDs = Set(self.modules.map(\.id))
        }

        if let stored = UserDefaults.standard.stringArray(forKey: Self.menuBarKey) {
            menuBarIDs = Set(stored)
        } else {
            menuBarIDs = Self.defaultMenuBarIDs
        }
    }

    /// メニューバー本体に数値を出すモジュール。
    var menuBarModules: [any ToolModule] {
        activeModules.filter { menuBarIDs.contains($0.id) }
    }

    func isShownInMenuBar(_ module: any ToolModule) -> Bool {
        menuBarIDs.contains(module.id)
    }

    func setShownInMenuBar(_ shown: Bool, for module: any ToolModule) {
        guard shown != isShownInMenuBar(module) else { return }
        if shown {
            menuBarIDs.insert(module.id)
        } else {
            menuBarIDs.remove(module.id)
        }
        UserDefaults.standard.set(Array(menuBarIDs), forKey: Self.menuBarKey)
    }

    /// 有効かつ利用可能なモジュール。
    var activeModules: [any ToolModule] {
        modules.filter { enabledIDs.contains($0.id) }
    }

    func isEnabled(_ module: any ToolModule) -> Bool {
        enabledIDs.contains(module.id)
    }

    func setEnabled(_ enabled: Bool, for module: any ToolModule) {
        guard enabled != isEnabled(module) else { return }
        if enabled {
            enabledIDs.insert(module.id)
            module.start()
        } else {
            enabledIDs.remove(module.id)
            module.stop()
        }
        UserDefaults.standard.set(Array(enabledIDs), forKey: Self.enabledKey)
    }

    /// アプリ起動時に一度だけ呼ぶ。
    func startAll() {
        for module in activeModules { module.start() }
        sampler.start { [weak self] in
            guard let self else { return }
            for module in self.activeModules { module.tick() }
        }
    }

    func stopAll() {
        sampler.stop()
        for module in activeModules { module.stop() }
    }
}
