import Foundation
import ServiceManagement
import Observation

/// ログイン時の自動起動を管理する。
///
/// レガシーな LaunchAgent の plist ではなく `SMAppService` を使う。
/// 登録はアプリ自身のバンドルを対象にするため、安定した場所
/// （`/Applications` など）に置かれている必要がある。
@MainActor
@Observable
final class LoginItem {
    /// 現在の登録状態。
    private(set) var status: SMAppService.Status

    private let service = SMAppService.mainApp

    init() {
        status = service.status
    }

    var isEnabled: Bool { status == .enabled }

    /// 一時的な場所（ビルド生成物や DMG 内）から起動している間は、
    /// 登録しても不安定なので操作させない。
    var canToggle: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                // 既に登録済みで status が古い場合に備えて一度解除してから登録する。
                if service.status == .enabled { try? service.unregister() }
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            NSLog("[login-item] failed to \(enabled ? "register" : "unregister"): \(error)")
        }
        refresh()
    }

    func refresh() {
        status = service.status
    }
}
