import AppKit
import Carbon.HIToolbox  // kVK_JIS_Eisu / kVK_JIS_Kana
import Observation
import SwiftUI

/// Windows App（RDP）の Unicode モードで日本語を打つときの入力ソース切り替え。
///
/// Windows App は JIS キーボードの英数・かなキーを飲み込んでしまい、
/// macOS 側の IME を切り替えられない。対象アプリが前面のときだけ
/// 英数・かなをホットキーとして横取りし、macOS の入力ソースを直接切り替える。
///
/// CGEventTap ではなく `RegisterEventHotKey` の付け外しで実装している。
/// 入力監視やアクセシビリティの権限が一切不要で、対象外のアプリでは
/// 登録自体を解除するので既存のキー挙動に干渉しない（docs/ARCHITECTURE.md §7）。
/// 前面アプリの変化はイベントで拾うため `tick()` では何もしない。
@MainActor
@Observable
final class RemoteInputModule: ToolModule {
    let id = "remoteinput"
    let title = "RDP入力"
    let systemImage = "keyboard"

    /// 英数・かなの横取りを行うか。挙動を変える機能なので既定はオフ（オプトイン）。
    var switchesInputSource: Bool {
        didSet {
            UserDefaults.standard.set(switchesInputSource, forKey: Self.enabledKey)
            if !switchesInputSource { message = nil }
            refreshHotKeys()
        }
    }

    /// 対象アプリが前面にいるか。
    private(set) var isTargetFrontmost = false
    /// 英数・かなをホットキーとして登録できなかった（他アプリが使用中など）。
    private(set) var hotKeyFailed = false
    /// 切り替え先の入力ソースが見つからなかったときの案内。正常時は nil。
    private(set) var message: String?

    /// 対象の RDP クライアント。RustDesk などを足すときはここに並べる。
    private static let targetBundleIDs: Set<String> = [
        "com.microsoft.rdc.macos"  // Windows App（旧 Microsoft Remote Desktop）
    ]

    private static let enabledKey = "remoteinput.switchesInputSource"
    private static let eisuHotKeyName = "remoteinput.eisu"
    private static let kanaHotKeyName = "remoteinput.kana"

    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    /// いま英数・かなを横取りしているか。登録・解除を差分だけ行うために持つ。
    @ObservationIgnored private var isIntercepting = false

    init() {
        switchesInputSource = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func start() {
        guard activationObserver == nil else { return }
        // アプリの切り替えはイベントで拾う（ポーリングしない）。
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            let bundleID = application?.bundleIdentifier
            Task { @MainActor [weak self] in
                self?.frontmostDidChange(to: bundleID)
            }
        }
        // 起動した時点で既に対象アプリが前面のことがある。
        frontmostDidChange(to: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        isTargetFrontmost = false
        refreshHotKeys()
        message = nil
    }

    /// キーイベント駆動なので毎ティックの処理は無い。
    func tick() {}

    /// 対象アプリが起動しているか。ポップオーバーの状態表示に使う。
    var isTargetRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            guard let bundleID = $0.bundleIdentifier else { return false }
            return Self.targetBundleIDs.contains(bundleID)
        }
    }

    // MARK: - 横取りの付け外し

    private func frontmostDidChange(to bundleID: String?) {
        isTargetFrontmost = bundleID.map(Self.targetBundleIDs.contains) ?? false
        refreshHotKeys()
    }

    /// 対象アプリが前面のときだけ英数・かなを横取りする。
    /// それ以外では登録を解除し、他アプリのキー挙動に干渉しない。
    private func refreshHotKeys() {
        let shouldIntercept = switchesInputSource && isTargetFrontmost
        guard shouldIntercept != isIntercepting else { return }
        isIntercepting = shouldIntercept

        if shouldIntercept {
            let eisu = HotKeyCenter.shared.register(
                name: Self.eisuHotKeyName,
                keyCode: UInt32(kVK_JIS_Eisu),
                modifiers: []
            ) { [weak self] in
                self?.switchInputSource(toJapanese: false)
            }
            let kana = HotKeyCenter.shared.register(
                name: Self.kanaHotKeyName,
                keyCode: UInt32(kVK_JIS_Kana),
                modifiers: []
            ) { [weak self] in
                self?.switchInputSource(toJapanese: true)
            }
            hotKeyFailed = !(eisu && kana)
        } else {
            HotKeyCenter.shared.unregister(name: Self.eisuHotKeyName)
            HotKeyCenter.shared.unregister(name: Self.kanaHotKeyName)
            hotKeyFailed = false
        }
    }

    private func switchInputSource(toJapanese japanese: Bool) {
        let switched = japanese
            ? InputSourceSwitcher.selectJapanese()
            : InputSourceSwitcher.selectABC()
        // 見つからなくても落とさない。理由だけ残して次の押下でまた試す。
        message = switched ? nil : "切り替え先の入力ソースが見つかりません"
    }

    // MARK: - View

    func detailView() -> AnyView {
        AnyView(RemoteInputSectionView(module: self))
    }
}

// MARK: - 表示

private struct RemoteInputSectionView: View {
    @Bindable var module: RemoteInputModule

    var body: some View {
        ModuleSection(
            title: module.title,
            systemImage: module.systemImage,
            summary: module.switchesInputSource ? "オン" : "オフ"
        ) {
            Toggle(isOn: $module.switchesInputSource) {
                Text("英数・かなで入力ソースを切り替え").metricLabelStyle()
            }
            .toggleStyle(.checkbox)

            Text("Windows App が前面のとき、かなで日本語・英数で ABC に切り替える")
                .metricCaptionStyle()
                .fixedSize(horizontal: false, vertical: true)

            if module.switchesInputSource {
                if module.hotKeyFailed {
                    // 押しても効かない理由を必ず示す。
                    Text("英数・かなキーを登録できません（他のアプリが使用中）")
                        .metricCaptionStyle()
                }

                if let message = module.message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                if !module.isTargetRunning {
                    Text("Windows App は起動していません")
                        .metricCaptionStyle()
                }
            }
        }
    }
}
