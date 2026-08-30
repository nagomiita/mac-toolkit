import SwiftUI

/// mac-toolkit の全機能はこのプロトコルに準拠した「モジュール」として実装する。
///
/// 計画では `associatedtype MenuContent: View` を持たせる想定だったが、
/// `ModuleRegistry` が異種のモジュールを一つの配列で保持できなくなるため、
/// View は型消去して返す。
/// 全ての実装は UI から直接読まれるため MainActor 上で動く。
@MainActor
protocol ToolModule: AnyObject, Identifiable {
    /// UserDefaults のキーにも使う安定した識別子。
    var id: String { get }
    var title: String { get }
    /// メニューバーのアイコン（SF Symbols 名）。
    var systemImage: String { get }

    /// この Mac でモジュールが利用可能か。
    /// 例: バッテリー非搭載機では BatteryModule が `false` を返す。
    var isAvailable: Bool { get }

    /// サンプリングの開始／停止。`ModuleRegistry` から呼ばれる。
    func start()
    func stop()

    /// `Sampler` のティックごとに呼ばれる。ここで値を更新する。
    func tick()

    /// メニューバー本体に出す小さな表示（速度の数値など）。不要なら nil。
    func statusItemView() -> AnyView?
    /// ポップオーバー内に出す詳細表示。
    func detailView() -> AnyView
    /// 設定画面に出すこのモジュール固有の設定。不要なら nil。
    func settingsView() -> AnyView?
}

extension ToolModule {
    var isAvailable: Bool { true }
    func statusItemView() -> AnyView? { nil }
    func settingsView() -> AnyView? { nil }
    func start() {}
    func stop() {}
}
