import AppKit

/// 画像に囲みやマーカーを引いて、クリップボードへコピーする窓。
///
/// 撮影直後の画像だけでなく、クリップボード履歴の画像もここで開く。
///
/// 常駐アプリ（LSUIElement）は通常アプリのように前面へ出ないため、
/// この窓を出している間だけ活性化ポリシーを `.regular` に上げ、
/// 閉じるときに `.accessory` へ戻す。
@MainActor
final class ScreenshotEditor: NSObject, NSWindowDelegate {
    /// 開いている編集窓。閉じるまで保持しないと解放されてしまう。
    private static var editors: [ScreenshotEditor] = []

    private var window: NSWindow?
    private var canvas: AnnotationCanvas?

    /// ツールバーが収まる最小の幅。
    private static let minimumWidth: CGFloat = 340

    /// 画像を編集窓で開く。
    static func open(image: CGImage) {
        let editor = ScreenshotEditor()
        editor.show(image: image)
        editors.append(editor)
    }

    private func show(image: CGImage) {
        let canvas = AnnotationCanvas(image: image)
        self.canvas = canvas

        // 画像の実ピクセルではなく論理サイズで窓を作る（Retina で巨大化しないように）。
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)

        // 画面に収まらない大きさなら縮めて開く。
        if let visible = NSScreen.main?.visibleFrame {
            let maxSize = NSSize(width: visible.width * 0.9, height: visible.height * 0.9)
            let ratio = min(1, min(maxSize.width / size.width, maxSize.height / size.height))
            size = NSSize(width: size.width * ratio, height: size.height * ratio)
        }

        // 小さい画像だと道具のツールバーの方が幅を要求し、その幅に合わせて
        // 画像が引き伸ばされる。先に最小幅を満たしておき、比率は保つ。
        if size.width < Self.minimumWidth {
            size = NSSize(
                width: Self.minimumWidth,
                height: size.height * (Self.minimumWidth / size.width)
            )
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "スクリーンショット"
        window.contentView = canvas
        // リサイズしても画像の縦横比を崩さない。
        window.contentAspectRatio = NSSize(width: image.width, height: image.height)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.addTitlebarAccessoryViewController(makeToolbar(for: canvas))
        self.window = window

        // 常駐アプリのままだと窓が前面に出ないので、通常アプリに切り替える。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    /// 道具の選択とコピーの導線。メニューを持たない常駐アプリなので、
    /// キー操作だけに頼らず窓の上に出す。
    private func makeToolbar(for canvas: AnnotationCanvas) -> NSTitlebarAccessoryViewController {
        let tools = NSSegmentedControl(
            labels: AnnotationTool.allCases.map(\.title),
            trackingMode: .selectOne,
            target: canvas,
            action: #selector(AnnotationCanvas.toolChanged(_:))
        )
        tools.selectedSegment = 0

        let copyButton = NSButton(
            title: "コピー", target: canvas, action: #selector(AnnotationCanvas.copyAction(_:))
        )
        copyButton.bezelStyle = .rounded

        let hint = NSTextField(labelWithString: "⌘Z で取り消し")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [tools, copyButton, hint])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

        let controller = NSTitlebarAccessoryViewController()
        controller.view = stack
        controller.layoutAttribute = .bottom
        return controller
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        canvas = nil
        Self.editors.removeAll { $0 === self }

        // 編集窓が全部閉じたらメニューバー常駐に戻る。
        if Self.editors.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// 引ける注釈の種類。
enum AnnotationTool: Int, CaseIterable {
    case box
    case marker

    var title: String {
        switch self {
        case .box: return "囲み"
        case .marker: return "マーカー"
        }
    }
}

/// 画像の上に注釈を描くビュー。
///
/// 注釈は「画像のピクセル座標」で持つ。窓のリサイズで表示倍率が変わっても
/// 注釈が画像からずれないようにするため、描画時に毎回変換する。
private final class AnnotationCanvas: NSView {
    /// 1 つの注釈。取り消しは種類を問わず新しい順に消したいので 1 つの配列に混ぜて持つ。
    private enum Annotation {
        /// 赤い囲み（画像座標の矩形）。
        case box(CGRect)
        /// マーカー（画像座標の点列）。なぞった線をそのまま残す。
        case marker([CGPoint])
    }

    private let image: CGImage
    private var annotations: [Annotation] = []
    private var tool: AnnotationTool = .box

    /// ドラッグ中の状態（ビューのローカル座標）。
    private var origin: CGPoint?
    private var current: CGPoint?
    private var strokePoints: [CGPoint] = []

    /// 囲みの線の太さ（画像のピクセル基準）。
    private static let lineWidth: CGFloat = 3
    /// マーカーの太さ（画像のピクセル基準）。蛍光ペンなので線より太くする。
    private static let markerWidth: CGFloat = 18

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

    // MARK: 道具

    @objc func toolChanged(_ sender: NSSegmentedControl) {
        tool = AnnotationTool(rawValue: sender.selectedSegment) ?? .box
    }

    @objc func copyAction(_ sender: Any?) {
        copyToPasteboard()
    }

    // MARK: 描画

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.draw(image, in: bounds)

        let scale = viewToImageScale.inverted
        for annotation in annotations {
            switch annotation {
            case .box(let rect):
                drawBox(imageToView(rect), lineWidth: Self.lineWidth * scale, in: context)
            case .marker(let points):
                drawMarker(points.map(imageToView), width: Self.markerWidth * scale, in: context)
            }
        }

        // ドラッグ中のものはローカル座標のまま描く。
        switch tool {
        case .box:
            if let dragging = localSelection {
                drawBox(dragging, lineWidth: Self.lineWidth * scale, in: context)
            }
        case .marker:
            if strokePoints.count > 1 {
                drawMarker(strokePoints, width: Self.markerWidth * scale, in: context)
            }
        }
    }

    private func drawBox(_ rect: CGRect, lineWidth: CGFloat, in context: CGContext) {
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setLineWidth(lineWidth)
        context.stroke(rect)
    }

    /// なぞった線を半透明の黄色で引く。
    ///
    /// 重ねると濃くなる普通の合成だと、往復してなぞったところだけ黒ずむ。
    /// 蛍光ペンらしく下の文字を残すため乗算で重ねる。
    private func drawMarker(_ points: [CGPoint], width: CGFloat, in context: CGContext) {
        guard points.count > 1 else { return }
        context.saveGState()
        context.setBlendMode(.multiply)
        context.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.45).cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addLines(between: points)
        context.strokePath()
        context.restoreGState()
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

    private func viewToImage(_ point: CGPoint) -> CGPoint {
        let scale = viewToImageScale
        return CGPoint(x: point.x * scale, y: point.y * scale)
    }

    private func imageToView(_ rect: CGRect) -> CGRect {
        let scale = viewToImageScale
        guard scale > 0 else { return rect }
        return CGRect(
            x: rect.minX / scale, y: rect.minY / scale,
            width: rect.width / scale, height: rect.height / scale
        )
    }

    private func imageToView(_ point: CGPoint) -> CGPoint {
        let scale = viewToImageScale
        guard scale > 0 else { return point }
        return CGPoint(x: point.x / scale, y: point.y / scale)
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
        let point = convert(event.locationInWindow, from: nil)
        origin = point
        current = point
        strokePoints = [point]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        current = point
        strokePoints.append(point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            origin = nil
            current = nil
            strokePoints = []
            needsDisplay = true
        }

        switch tool {
        case .box:
            // 誤クリックで点のような囲みが残らないようにする。
            guard let rect = localSelection, rect.width >= 3, rect.height >= 3 else { return }
            annotations.append(.box(viewToImage(rect)))
        case .marker:
            guard strokePoints.count > 1 else { return }
            annotations.append(.marker(strokePoints.map(viewToImage)))
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:
            // Delete / Backspace で直前の注釈を取り消す。
            undo()
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
            undo()
            return true
        default:
            return false
        }
    }

    private func undo() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        needsDisplay = true
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

    /// 画像と注釈を 1 枚にまとめる。原寸（実ピクセル）で書き出す。
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

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for annotation in annotations {
            switch annotation {
            case .box(let rect):
                drawBox(rect, lineWidth: Self.lineWidth, in: context)
            case .marker(let points):
                drawMarker(points, width: Self.markerWidth, in: context)
            }
        }

        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: width, height: height))
    }
}

private extension CGFloat {
    /// 0 除算を避けた逆数。
    var inverted: CGFloat { self == 0 ? 1 : 1 / self }
}
