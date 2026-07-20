import AppKit

/// 撮影した画像に四角の囲みを引いて、クリップボードへコピーする窓。
///
/// 常駐アプリ（LSUIElement）は通常アプリのように前面へ出ないため、
/// この窓を出している間だけ活性化ポリシーを `.regular` に上げ、
/// 閉じるときに `.accessory` へ戻す。
@MainActor
final class ScreenshotEditor: NSObject, NSWindowDelegate {
    /// 開いている編集窓。閉じるまで保持しないと解放されてしまう。
    private static var editors: [ScreenshotEditor] = []

    private var window: NSWindow?

    /// 撮影画像を編集窓で開く。
    static func open(image: CGImage) {
        let editor = ScreenshotEditor()
        editor.show(image: image)
        editors.append(editor)
    }

    private func show(image: CGImage) {
        let canvas = AnnotationCanvas(image: image)

        // 画像の実ピクセルではなく論理サイズで窓を作る（Retina で巨大化しないように）。
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)

        // 画面に収まらない大きさなら縮めて開く。
        if let visible = NSScreen.main?.visibleFrame {
            let maxSize = NSSize(width: visible.width * 0.9, height: visible.height * 0.9)
            let ratio = min(1, min(maxSize.width / size.width, maxSize.height / size.height))
            size = NSSize(width: size.width * ratio, height: size.height * ratio)
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "スクリーンショット"
        window.contentView = canvas
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        // 常駐アプリのままだと窓が前面に出ないので、通常アプリに切り替える。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        Self.editors.removeAll { $0 === self }

        // 編集窓が全部閉じたらメニューバー常駐に戻る。
        if Self.editors.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// 画像の上に四角の囲みを描くビュー。
///
/// 注釈は「画像のピクセル座標」で持つ。窓のリサイズで表示倍率が変わっても
/// 注釈が画像からずれないようにするため、描画時に毎回変換する。
private final class AnnotationCanvas: NSView {
    private let image: CGImage
    /// 確定した囲み（画像のピクセル座標）。
    private var rectangles: [CGRect] = []
    /// ドラッグ中の始点・終点（ビューのローカル座標）。
    private var origin: CGPoint?
    private var current: CGPoint?

    /// 囲みの線の太さ（画像のピクセル基準）。
    private static let lineWidth: CGFloat = 3

    init(image: CGImage) {
        self.image = image
        super.init(frame: NSRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: 描画

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.draw(image, in: bounds)

        context.setStrokeColor(NSColor.systemRed.cgColor)

        // 確定済みの囲みは画像座標なのでビュー座標へ直して描く。
        for rect in rectangles {
            context.setLineWidth(Self.lineWidth * viewToImageScale.inverted)
            context.stroke(imageToView(rect))
        }

        // ドラッグ中のものはローカル座標のまま描く。
        if let dragging = localSelection {
            context.setLineWidth(Self.lineWidth * viewToImageScale.inverted)
            context.stroke(dragging)
        }
    }

    /// ビュー座標 1 に対する画像ピクセル数。
    private var viewToImageScale: CGFloat {
        guard bounds.width > 0 else { return 1 }
        return CGFloat(image.width) / bounds.width
    }

    private func viewToImage(_ rect: CGRect) -> CGRect {
        let scale = viewToImageScale
        return CGRect(
            x: rect.minX * scale, y: rect.minY * scale,
            width: rect.width * scale, height: rect.height * scale
        )
    }

    private func imageToView(_ rect: CGRect) -> CGRect {
        let scale = viewToImageScale
        guard scale > 0 else { return rect }
        return CGRect(
            x: rect.minX / scale, y: rect.minY / scale,
            width: rect.width / scale, height: rect.height / scale
        )
    }

    private var localSelection: CGRect? {
        guard let origin, let current else { return nil }
        return CGRect(
            x: min(origin.x, current.x), y: min(origin.y, current.y),
            width: abs(current.x - origin.x), height: abs(current.y - origin.y)
        )
    }

    // MARK: 入力

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
        guard let rect = localSelection, rect.width >= 3, rect.height >= 3 else { return }
        rectangles.append(viewToImage(rect))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:
            // Delete / Backspace で直前の囲みを取り消す。
            if !rectangles.isEmpty {
                rectangles.removeLast()
                needsDisplay = true
            }
        default:
            super.keyDown(with: event)
        }
    }

    /// ⌘C / ⌘Z を受ける。メニューを持たない常駐アプリなので自前で拾う。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers {
        case "c":
            copyToPasteboard()
            return true
        case "z":
            if !rectangles.isEmpty {
                rectangles.removeLast()
                needsDisplay = true
            }
            return true
        default:
            return false
        }
    }

    // MARK: コピー

    /// 注釈を焼き込んだ画像をクリップボードへ入れる。
    private func copyToPasteboard() {
        guard let flattened = flattenedImage() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([flattened])

        // コピーできたことを示す。常駐アプリなので窓の外に通知は出さず、
        // タイトルを一瞬変えるだけに留める。
        window?.title = "コピーしました"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            self.window?.title = "スクリーンショット"
        }
    }

    /// 画像と囲みを 1 枚にまとめる。原寸（実ピクセル）で書き出す。
    private func flattenedImage() -> NSImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: full)
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setLineWidth(Self.lineWidth)
        for rect in rectangles {
            context.stroke(rect)
        }

        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: width, height: height))
    }
}

private extension CGFloat {
    /// 0 除算を避けた逆数。
    var inverted: CGFloat { self == 0 ? 1 : 1 / self }
}
