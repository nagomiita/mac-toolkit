import AppKit
import Carbon.HIToolbox

/// 履歴から選んだあと、前面のアプリへ ⌘V を送って貼り付ける。
///
/// 既定はオフ。キー入力の合成には**アクセシビリティ権限**が要るうえ、
/// 失敗の仕方が分かりにくい（パスワード欄では黙って無視される）ため、
/// 「クリップボードに戻すだけ」を標準の動作にしている（docs/CLIPBOARD.md §5）。
@MainActor
enum ClipboardPaster {
    /// 貼り付けを試みなかった理由。UI でそのまま伝える。
    enum Failure: Equatable {
        case noPermission
        case secureInput

        var message: String {
            switch self {
            case .noPermission:
                return "自動で貼り付けるにはアクセシビリティの権限が必要です"
            case .secureInput:
                return "パスワード入力中は自動で貼り付けできません"
            }
        }
    }

    /// 権限を持っているか。ダイアログは出さない。
    static var hasPermission: Bool {
        AXIsProcessTrusted()
    }

    /// 権限を要求する。システムのダイアログが出る。
    ///
    /// 「その機能を初めて使うとき」に呼ぶ。起動時には呼ばない。
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openPermissionSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 前面のアプリへ ⌘V を送る。送れなければ理由を返す。
    ///
    /// パネルは nonactivating なので、この時点でも前面アプリは
    /// ユーザーが元々使っていたアプリのままになっている。
    static func paste() -> Failure? {
        guard hasPermission else { return .noPermission }
        // パスワード欄などセキュア入力中は OS がキー合成を無視する。
        // 黙って何も起きないより、できないと伝える方がよい。
        guard !IsSecureEventInputEnabled() else { return .secureInput }

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return nil }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return nil
    }
}
