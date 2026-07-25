import SwiftUI
import Observation

/// コピーした内容の履歴を残し、選んでクリップボードへ戻す。
///
/// Windows の「クリップボード履歴」(Win+V) に相当する。
/// PR1 の範囲はテキストとファイルのみ・メモリ保持のみ・ポップオーバーからの操作のみ。
/// ホットキーとフローティングパネルは PR2（docs/CLIPBOARD.md §8）。
@MainActor
@Observable
final class ClipboardModule: ToolModule {
    let id = "clipboard"
    let title = "クリップボード履歴"
    let systemImage = "doc.on.clipboard"

    private let watcher = ClipboardWatcher()
    private let history = ClipboardHistory()

    /// ポップオーバーに出す件数。全件はパネル（PR2）に譲る。
    private static let previewCount = 5

    /// 直前に戻した項目。押した手応えを返すために覚える。
    private var lastRestoredID: UUID?

    func stop() {
        // 無効化したら履歴をメモリに残さない。
        history.clear()
        lastRestoredID = nil
    }

    /// changeCount の比較だけなので変化が無ければほぼ何もしない。
    func tick() {
        guard let item = watcher.poll() else { return }
        history.append(item)
    }

    /// メニューバーには数値を出さない。
    func statusItemView() -> AnyView? { nil }

    func detailView() -> AnyView {
        AnyView(ClipboardSectionView(module: self))
    }

    // MARK: - View から使う操作

    var items: [ClipboardItem] { history.items }

    var previewItems: [ClipboardItem] { Array(history.items.prefix(Self.previewCount)) }

    var hiddenCount: Int { max(0, history.items.count - Self.previewCount) }

    func isRestored(_ item: ClipboardItem) -> Bool { lastRestoredID == item.id }

    /// 選んだ項目をクリップボードへ戻す。
    func restore(_ item: ClipboardItem) {
        guard watcher.writeBack(item) else { return }
        lastRestoredID = item.id
    }

    func clear() {
        history.clear()
        // 消した直後の内容を拾い直さないよう起点を取り直す。
        watcher.resync()
        lastRestoredID = nil
    }
}

// MARK: - 表示

private struct ClipboardSectionView: View {
    let module: ClipboardModule

    var body: some View {
        ModuleSection(
            title: module.title,
            systemImage: module.systemImage,
            summary: module.items.isEmpty ? nil : "\(module.items.count) 件"
        ) {
            if module.items.isEmpty {
                Text("コピーするとここに残ります").metricCaptionStyle()
            } else {
                ForEach(module.previewItems) { item in
                    ClipboardRow(item: item, isRestored: module.isRestored(item)) {
                        module.restore(item)
                    }
                }

                if module.hiddenCount > 0 {
                    Text("ほかに \(module.hiddenCount) 件").metricCaptionStyle()
                }

                Button("履歴をすべて消去") {
                    module.clear()
                }
                .buttonStyle(.accessoryBar)
            }
        }
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let isRestored: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: item.kind.systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    // 見出しのアイコンと左端を揃える。
                    .frame(width: 14, alignment: .center)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.preview)
                        .metricLabelStyle()
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isTruncated {
                        // 押しても何も起きない理由を必ず示す。
                        Text("大きすぎるため戻せません").metricCaptionStyle()
                    }
                }

                Spacer(minLength: 8)

                // 状態は色だけに持たせず言葉で示す。
                if isRestored {
                    Text("コピー済み").metricCaptionStyle()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.isTruncated)
        .help(item.preview)
    }
}
