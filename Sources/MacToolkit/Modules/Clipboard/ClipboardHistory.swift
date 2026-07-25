import Foundation
import Observation

/// 上限付きの履歴。新しいものが先頭。
///
/// PR1 の時点ではメモリのみで、アプリを終了すると消える。
/// ディスク永続化は PR3（docs/CLIPBOARD.md §3）。
@MainActor
@Observable
final class ClipboardHistory {
    private(set) var items: [ClipboardItem] = []

    /// 保持する件数。常駐アプリなので既定は控えめにする。
    var limit: Int {
        didSet {
            UserDefaults.standard.set(limit, forKey: Self.limitKey)
            trim()
        }
    }

    /// この bundle ID からのコピーは記録しない。
    /// 既定で主要なパスワードマネージャを入れておく。
    private(set) var excludedBundleIDs: Set<String>

    static let limitRange = 20...200
    private static let limitKey = "clipboard.maxItems"
    private static let excludedKey = "clipboard.excludedBundleIDs"
    private static let defaultExcluded: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.apple.keychainaccess",
        "com.bitwarden.desktop",
        "in.sinew.Enpass-Desktop",
    ]

    init() {
        let saved = UserDefaults.standard.integer(forKey: Self.limitKey)
        limit = Self.limitRange.contains(saved) ? saved : 50
        if let stored = UserDefaults.standard.stringArray(forKey: Self.excludedKey) {
            excludedBundleIDs = Set(stored)
        } else {
            excludedBundleIDs = Self.defaultExcluded
        }
    }

    /// 記録する。除外アプリ由来なら黙って捨てる。
    func append(_ item: ClipboardItem) {
        if let bundleID = item.sourceBundleID, excludedBundleIDs.contains(bundleID) { return }

        // 同じ内容を続けてコピーしたときは古い方を消して先頭へ上げる。
        items.removeAll { $0.dedupeKey == item.dedupeKey }
        items.insert(item, at: 0)
        trim()
    }

    func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        items.removeAll()
    }

    func setExcluded(_ ids: Set<String>) {
        excludedBundleIDs = ids
        UserDefaults.standard.set(Array(ids), forKey: Self.excludedKey)
    }

    private func trim() {
        if items.count > limit {
            items.removeLast(items.count - limit)
        }
    }
}
