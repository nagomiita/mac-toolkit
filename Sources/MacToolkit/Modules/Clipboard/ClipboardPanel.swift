import SwiftUI
import AppKit
import Observation
import Carbon.HIToolbox  // kVK_* のキーコード定数

/// ホットキーで出す履歴パネル（Win+V 相当）。
///
/// `.nonactivatingPanel` にするのが肝で、これで**前面アプリのフォーカスを
/// 奪わずに**出せる。奪ってしまうと、選んだあとユーザーが元のアプリへ
/// 戻ってから ⌘V を押す羽目になり、体感が大きく落ちる。
@MainActor
final class ClipboardPanelController {
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private let state = PanelState()

    private unowned let module: ClipboardModule

    init(module: ClipboardModule) {
        self.module = module
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        // 押した直後のコピーを取りこぼさないよう、出す前に 1 回だけ拾い直す。
        // タイマーを増やすのではなく操作を起点にした追加サンプリング。
        module.refresh()

        state.items = module.items
        state.selection = 0

        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func hide() {
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    // MARK: - 組み立て

    private func makePanel() -> NSPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 320),
            // nonactivating で前面アプリを切り替えない。閉じるボタン等は出さない。
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        // 全画面アプリの上にも出す。
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        panel.contentView = NSHostingView(
            rootView: ClipboardPanelView(
                state: state,
                onChoose: { [weak self] item in self?.choose(item) },
                onClose: { [weak self] in self?.hide() }
            )
        )
        return panel
    }

    /// マウスのある画面の中央よりやや上に出す。
    /// カーソル直下だと、テキストを選択した直後の位置と重なって隠れることがある。
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2 + frame.height * 0.1
            )
        )
    }

    private func choose(_ item: ClipboardItem) {
        // 先に閉じて、キー入力が元のアプリに戻ってから貼り付けを送る。
        hide()
        module.restore(item, andPaste: true)
    }

    // MARK: - キー操作

    /// パネルが開いている間だけ ↑↓ / Return / Esc を見る。
    ///
    /// SwiftUI 側の `onKeyPress` はフォーカス状態に左右されるため、
    /// 確実に拾えるローカルモニタで処理する。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // NSEvent 自体は Sendable でないので、境界を越えるのはキーコードだけにする。
            let keyCode = Int(event.keyCode)
            let consumed = MainActor.assumeIsolated { self.handle(keyCode: keyCode) }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// 処理したら true（そのキーは他へ渡さない）。
    private func handle(keyCode: Int) -> Bool {
        // 開いていないときのキー入力には触らない。
        guard isVisible else { return false }

        switch keyCode {
        case kVK_Escape:
            hide()
        case kVK_UpArrow:
            state.moveSelection(-1)
        case kVK_DownArrow:
            state.moveSelection(1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let item = state.selectedItem { choose(item) }
        default:
            return false
        }
        return true
    }
}

/// nonactivating でもキーボード入力を受けるためにはこの 2 つが要る。
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 表示

@MainActor
@Observable
private final class PanelState {
    var items: [ClipboardItem] = []
    var selection = 0

    var selectedItem: ClipboardItem? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    /// 端で止める（巡回させると今どこにいるか分からなくなる）。
    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = min(max(0, selection + delta), items.count - 1)
    }
}

private struct ClipboardPanelView: View {
    @Bindable var state: PanelState
    let onChoose: (ClipboardItem) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if state.items.isEmpty {
                empty
            } else {
                list
            }

            Divider()
            footer
        }
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack {
            Label("クリップボード履歴", systemImage: "doc.on.clipboard")
                .moduleTitleStyle()
            Spacer()
            Text("\(state.items.count) 件").metricCaptionStyle()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                        PanelRow(
                            item: item,
                            isSelected: index == state.selection,
                            action: { onChoose(item) }
                        )
                        .id(index)
                        // マウスを動かしただけで選択が飛ぶと、キーボードで
                        // 選んでいる最中に邪魔になるのでホバーでは変えない。
                    }
                }
                .padding(6)
            }
            .onChange(of: state.selection) { _, new in
                proxy.scrollTo(new, anchor: .center)
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("履歴はまだありません").metricLabelStyle()
            Text("コピーするとここに残ります").metricCaptionStyle()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("↑↓ で選ぶ").metricCaptionStyle()
            Text("Return でコピー").metricCaptionStyle()
            Spacer()
            Button("閉じる", action: onClose)
                .buttonStyle(.accessoryBar)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct PanelRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ClipboardItemIcon(item: item, size: 22)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.preview)
                        .font(.system(.callout))
                        .lineLimit(2)
                    if !item.isRestorable {
                        Text("大きすぎるため戻せません").metricCaptionStyle()
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isRestorable)
    }
}
