import AppKit

/// pasteboard の変更を拾う。
///
/// macOS には pasteboard 変更の公開通知が無いため、`changeCount` の
/// ポーリングが唯一の手段。変化が無ければ何もしないので `tick()` に載せられる。
/// 詳細は docs/CLIPBOARD.md を参照。
@MainActor
final class ClipboardWatcher {
    private let pasteboard: NSPasteboard
    private var lastChangeCount: Int

    /// このアプリ自身が履歴から書き戻したときの changeCount。
    /// 自分の書き戻しを新しいコピーとして拾い直さないために覚えておく。
    private var selfWriteChangeCount: Int?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        // 起動前にコピーされていた内容は履歴に入れない。
        self.lastChangeCount = pasteboard.changeCount
    }

    /// 変化があれば新しい項目を返す。無ければ nil。
    ///
    /// `changeCount` の読み取りだけなら µs オーダーで、tick の予算に収まる。
    func poll(now: Date = Date()) -> ClipboardItem? {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return nil }
        lastChangeCount = count

        // 自分で戻した内容なら、履歴の先頭へ入れ直す必要はない。
        if selfWriteChangeCount == count {
            selfWriteChangeCount = nil
            return nil
        }

        return ClipboardItem.read(
            from: pasteboard,
            sourceBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            now: now
        )
    }

    /// 履歴の項目をクリップボードへ戻す。
    @discardableResult
    func writeBack(_ item: ClipboardItem) -> Bool {
        let written = item.writeBack(to: pasteboard)
        if written {
            selfWriteChangeCount = pasteboard.changeCount
            lastChangeCount = pasteboard.changeCount
        }
        return written
    }

    /// 現在の内容を履歴の起点として捨てる（履歴消去時に使う）。
    func resync() {
        lastChangeCount = pasteboard.changeCount
    }
}
