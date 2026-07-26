import Foundation
import Observation

/// 上限付きの履歴。新しいものが先頭。
///
/// テキスト系は `ClipboardStore` でディスクに保存し、次回起動でも残る。
/// 画像は退避先をセッション内でしか持たない（docs/CLIPBOARD.md §3）。
@MainActor
@Observable
final class ClipboardHistory {
    private(set) var items: [ClipboardItem] = []

    /// 保持する件数。常駐アプリなので既定は控えめにする。
    var limit: Int {
        didSet {
            UserDefaults.standard.set(limit, forKey: Self.limitKey)
            trim()
            save()
        }
    }

    /// この bundle ID からのコピーは記録しない。
    /// 既定で主要なパスワードマネージャを入れておく。
    private(set) var excludedBundleIDs: Set<String>

    static let limitRange = 20...200
    private static let limitKey = "clipboard.maxItems"
    private static let excludedKey = "clipboard.excludedBundleIDs"
    private static let persistKey = "clipboard.persistHistory"
    private static let defaultExcluded: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.apple.keychainaccess",
        "com.bitwarden.desktop",
        "in.sinew.Enpass-Desktop",
    ]

    @ObservationIgnored private let store = ClipboardStore()

    /// 終了後も履歴を残すか。オフなら索引を消してメモリだけで動く。
    var persists: Bool {
        didSet {
            UserDefaults.standard.set(persists, forKey: Self.persistKey)
            persists ? save() : store.removeIndex()
        }
    }

    init() {
        let saved = UserDefaults.standard.integer(forKey: Self.limitKey)
        limit = Self.limitRange.contains(saved) ? saved : 50
        if let stored = UserDefaults.standard.stringArray(forKey: Self.excludedKey) {
            excludedBundleIDs = Set(stored)
        } else {
            excludedBundleIDs = Self.defaultExcluded
        }
        // 既定は保存する（Windows の履歴も再起動で消えない）。
        persists = UserDefaults.standard.object(forKey: Self.persistKey) as? Bool ?? true

        // 前回のセッションで退避した画像は残さない。
        let store = self.store
        Task.detached { store.clearBlobs() }

        if persists {
            items = store.loadIndex()
            trim()
        }
    }

    /// 記録する。除外アプリ由来なら黙って捨てる。
    func append(_ item: ClipboardItem) {
        if let bundleID = item.sourceBundleID, excludedBundleIDs.contains(bundleID) { return }

        // 同じ内容を続けてコピーしたときは古い方を消して先頭へ上げる。
        removeAll(where: { $0.dedupeKey == item.dedupeKey })
        items.insert(item, at: 0)
        trim()

        if item.kind == .image {
            offloadImage(id: item.id)
        } else {
            save()
        }
    }

    func remove(_ item: ClipboardItem) {
        removeAll(where: { $0.id == item.id })
        save()
    }

    func clear() {
        removeAll(where: { _ in true })
        store.removeIndex()
    }

    func setExcluded(_ ids: Set<String>) {
        excludedBundleIDs = ids
        UserDefaults.standard.set(Array(ids), forKey: Self.excludedKey)
    }

    // MARK: - 画像の退避

    /// 画像の実データをディスクへ移し、メモリにはサムネイルだけ残す。
    ///
    /// 数 MB の書き出しと縮小を tick 上でやると更新が目に見えて詰まるため、
    /// メインアクターから外して行い、終わってから項目を差し替える。
    private func offloadImage(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let data = items[index].payload[ClipboardItem.pngType]
                  ?? items[index].payload[ClipboardItem.tiffType]
        else { return }

        let store = self.store
        Task.detached(priority: .utility) {
            let stored = store.storeImage(data, id: id)
            await MainActor.run { [weak self] in
                guard let self,
                      let index = self.items.firstIndex(where: { $0.id == id })
                else {
                    // 退避中に消された場合は、書いたファイルも残さない。
                    if let stored { store.removeBlob(at: stored.blobURL) }
                    return
                }
                guard let stored else { return }  // 失敗時はメモリに持ったままにする
                self.items[index].payload = [:]
                self.items[index].blobURL = stored.blobURL
                self.items[index].blobType = stored.type
                self.items[index].thumbnailPNG = stored.thumbnailPNG
                self.items[index].pixelWidth = stored.pixelWidth
                self.items[index].pixelHeight = stored.pixelHeight
                // 大きさが分かってから「画像 3840×2160」に差し替える。
                if let w = stored.pixelWidth, let h = stored.pixelHeight {
                    self.items[index].preview = "画像 \(w)×\(h)"
                }
            }
        }
    }

    // MARK: -

    /// 消えた項目が画像なら退避先のファイルも片付ける。
    private func removeAll(where shouldRemove: (ClipboardItem) -> Bool) {
        let removed = items.filter(shouldRemove)
        items.removeAll(where: shouldRemove)
        discardBlobs(of: removed)
    }

    private func trim() {
        guard items.count > limit else { return }
        let dropped = Array(items.suffix(items.count - limit))
        items.removeLast(items.count - limit)
        discardBlobs(of: dropped)
    }

    private func discardBlobs(of removed: [ClipboardItem]) {
        let urls = removed.compactMap(\.blobURL)
        guard !urls.isEmpty else { return }
        let store = self.store
        Task.detached(priority: .utility) {
            for url in urls { store.removeBlob(at: url) }
        }
    }

    private func save() {
        guard persists else { return }
        let snapshot = items
        let store = self.store
        // JSON の書き出しでメインアクターを止めない。
        Task.detached(priority: .utility) { store.saveIndex(snapshot) }
    }
}
