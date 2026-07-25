import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 履歴のディスク側。索引の読み書きと、画像の退避・サムネイル生成を持つ。
///
/// 置き場所は `~/Library/Application Support/MacToolkit/ClipboardHistory/`。
/// UserDefaults を使わないのは、plist が起動時に一括ロードされることと、
/// 履歴が `defaults read` で平文で覗けてしまうため（docs/CLIPBOARD.md §3）。
///
/// メインアクターから切り離して `Task.detached` で呼ぶため、
/// 状態を持たない値型として作る。
struct ClipboardStore: Sendable {
    /// サムネイルの最大辺。一覧に出す以上の解像度は持たない。
    static let thumbnailMaxPixel = 128

    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.directory = base
                .appendingPathComponent("MacToolkit", isDirectory: true)
                .appendingPathComponent("ClipboardHistory", isDirectory: true)
        }
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var blobDirectory: URL { directory.appendingPathComponent("blobs", isDirectory: true) }

    // MARK: - 索引

    /// 保存済みの履歴を読む。壊れていたら黙って空から始める
    /// （履歴が読めないだけでアプリを止める価値は無い）。
    func loadIndex() -> [ClipboardItem] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        do {
            return try JSONDecoder().decode([ClipboardItem].self, from: data)
        } catch {
            NSLog("[clipboard] failed to decode history index: \(error)")
            return []
        }
    }

    /// 索引を書く。画像は「セッション内のみ」の方針なので保存しない。
    func saveIndex(_ items: [ClipboardItem]) {
        // 画像・上限超過・中身を持たないものは書かない。
        let persistable = items.filter { $0.kind != .image && $0.isRestorable }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(persistable)
            // 書き込み途中で落ちても壊れた索引を残さない。
            try data.write(to: indexURL, options: .atomic)
        } catch {
            NSLog("[clipboard] failed to save history index: \(error)")
        }
    }

    func removeIndex() {
        try? FileManager.default.removeItem(at: indexURL)
    }

    // MARK: - 画像の退避

    /// 前回のセッションで残った画像を消す。
    ///
    /// 画像は永続化しない方針なので、起動時に必ず空にする。
    /// 消し忘れると、消したはずの画像がディスクに残り続ける。
    func clearBlobs() {
        try? FileManager.default.removeItem(at: blobDirectory)
    }

    /// 画像データをディスクへ退避し、置き場所とサムネイルを返す。
    /// 失敗したら nil（呼び出し側はメモリに持ったままにする）。
    func storeImage(_ data: Data, id: UUID) -> (blobURL: URL, thumbnailPNG: Data?)? {
        do {
            try FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
            let url = blobDirectory.appendingPathComponent("\(id.uuidString).png")
            try data.write(to: url, options: .atomic)
            return (url, Self.makeThumbnail(from: data))
        } catch {
            NSLog("[clipboard] failed to store image blob: \(error)")
            return nil
        }
    }

    func removeBlob(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// ImageIO で縮小する。NSImage を経由しないので main actor から切り離せる。
    static func makeThumbnail(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
