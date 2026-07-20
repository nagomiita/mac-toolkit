import AppKit

/// 画面全体を覆って、ドラッグで範囲を選ばせる。
///
/// 全スクリーンに 1 枚ずつ覆いを出し、最初にドラッグが始まったスクリーンの
/// 選択だけを採用する。Esc かどこかを右クリックで取り消す。
@MainActor
final class RegionSelector {
    /// 選択が終わったら、選ばれた矩形（グローバル座標・左下原点）とスクリーンを返す。
    /// 取り消されたら nil。
    private var completion: ((CGRect, NSScreen)?) -> Void = { _ in }
    private var windows: [NSWindow] = []

    /// 覆いを出して選択を待つ。すでに出ているときは何もしない。
    func begin(completion: @escaping ((CGRect, NSScreen)?) -> Void) {
        guard windows.isEmpty else { return }
        self.completion = completion

        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen)
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screen_ = screen
            view.onFinish = { [weak self] rect in
                self?.finish(rect: rect, screen: screen)
            }
            view.onCancel = { [weak self] in
                self?.finish(rect: nil, screen: nil)
            }
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
            // キー入力（Esc）を受けられるようにする。
            window.makeFirstResponder(view)
        }

        // 覆いにキーボードを届けるにはアプリを前面に出す必要がある。
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
    }

    private func finish(rect: CGRect?, screen: NSScreen?) {
        // 撮影前に覆いを確実に消す。残っていると覆い自身が写り込む。
        for window in windows { window.orderOut(nil) }
        windows.removeAll()

        if let rect, let screen, rect.width >= 1, rect.height >= 1 {
            completion((rect, screen))
        } else {
            completion(nil)
        }
        completion = { _ in }
    }
}

/// 覆い用のウィンドウ。メニューバーの上にも出す。
private final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.setFrame(screen.frame, display: true)
        isOpaque = false
        backgroundColor = .clear
        // メニューバー・Dock より前に出す。
        level = .screenSaver
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hasShadow = false
    }

    // borderless でもキー入力を受け取れるようにする。
    override var canBecomeKey: Bool { true }
}

/// ドラッグで矩形を選ばせるビュー。
private final class SelectionView: NSView {
    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    /// このビューが載っているスクリーン。ローカル座標をグローバルに直すのに使う。
    var screen_: NSScreen?

    /// ドラッグ中の始点と終点（このビューのローカル座標）。
    private var origin: CGPoint?
    private var current: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        // 範囲選択中であることをカーソルでも示す。
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 画面全体を薄く暗くして、選択範囲だけ元の明るさに戻す。
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard let rect = localSelection else { return }

        // 選択範囲は暗転を消して、下の画面をそのまま見せる。
        NSColor.clear.set()
        rect.fill(using: .copy)

        // 枠線を引いて範囲を明示する。
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2
        border.stroke()

        drawSizeLabel(for: rect)
    }

    /// 選択範囲の寸法をピクセルで出す。撮る前に大きさが分かるようにする。
    private func drawSizeLabel(for rect: NSRect) {
        let scale = screen_?.backingScaleFactor ?? 2
        let text = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let padding: CGFloat = 6

        // 既定は選択範囲の上。画面上端に近いときは中に入れて見切れを防ぐ。
        var labelY = rect.maxY + 6
        if labelY + size.height + padding * 2 > bounds.maxY {
            labelY = rect.maxY - size.height - padding * 2 - 6
        }

        let box = NSRect(
            x: rect.minX,
            y: labelY,
            width: size.width + padding * 2,
            height: size.height + padding
        )
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: box.minX + padding, y: box.minY + padding / 2), withAttributes: attributes)
    }

    /// ドラッグ中の矩形（ローカル座標）。始点と終点はどちら向きでもよい。
    private var localSelection: NSRect? {
        guard let origin, let current else { return nil }
        return NSRect(
            x: min(origin.x, current.x),
            y: min(origin.y, current.y),
            width: abs(current.x - origin.x),
            height: abs(current.y - origin.y)
        )
    }

    override func mouseDown(with event: NSEvent) {
        origin = convert(event.locationInWindow, from: nil)
        current = origin
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            origin = nil
            current = nil
            needsDisplay = true
        }
        guard let rect = localSelection, let screen = screen_ else {
            onCancel?()
            return
        }
        // クリックしただけ（ドラッグしていない）は取り消し扱いにする。
        guard rect.width >= 3, rect.height >= 3 else {
            onCancel?()
            return
        }
        // ローカル座標をグローバル座標（左下原点）へ直す。
        let global = CGRect(
            x: rect.minX + screen.frame.minX,
            y: rect.minY + screen.frame.minY,
            width: rect.width,
            height: rect.height
        )
        onFinish?(global)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        // Esc で取り消し。
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}
