import Foundation
import ScreenCaptureKit
import AppKit
import CoreGraphics

/// 画面を撮影する。
///
/// 領域の切り出しは `SCStreamConfiguration.sourceRect` ではなく、
/// ディスプレイ全体を撮ってから CGImage を切り抜く方式にしている。
/// sourceRect は原点の取り方と Retina 倍率の解釈が環境で揺れるのに対し、
/// 全体を撮ってからの切り抜きは「撮れた画像の実ピクセル数」を基準に
/// 計算できるため、座標がずれない。
enum ScreenCapturer {
    enum CaptureError: Error {
        case noPermission
        case displayNotFound
        case cropFailed
    }

    /// 画面収録の権限があるか。ダイアログは出さない。
    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 画面収録の権限を要求する。初回だけシステムのダイアログが出る。
    ///
    /// 一度拒否されると以降ダイアログは出ないので、その場合は
    /// システム設定を開く導線を UI 側で出すこと。
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// システム設定の「画面収録」を開く。
    static func openPermissionSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 指定したスクリーンの、指定した矩形を撮影する。
    ///
    /// - Parameters:
    ///   - rect: 撮影したい範囲。**グローバル座標（左下原点）** で渡す。
    ///   - screen: その範囲が載っているスクリーン。
    static func capture(rect: CGRect, on screen: NSScreen) async throws -> CGImage {
        guard hasPermission else { throw CaptureError.noPermission }

        // 対象スクリーンに対応する SCDisplay を探す。
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let displayID = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { throw CaptureError.displayNotFound }

        // ディスプレイ全体を実ピクセルで撮る。
        let configuration = SCStreamConfiguration()
        configuration.width = display.width * Int(screen.backingScaleFactor)
        configuration.height = display.height * Int(screen.backingScaleFactor)
        // カーソルは注釈の邪魔になるので写さない。
        configuration.showsCursor = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let full = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        )

        return try crop(full, to: rect, on: screen)
    }

    /// グローバル座標（左下原点）の矩形を、撮影画像のピクセル座標（左上原点）に
    /// 直して切り抜く。
    private static func crop(_ image: CGImage, to rect: CGRect, on screen: NSScreen) throws -> CGImage {
        let frame = screen.frame

        // 撮影画像の実ピクセル数から倍率を出す。backingScaleFactor を直接使わず
        // 実測から求めることで、撮影側の解像度が想定と違っても破綻しない。
        let scaleX = CGFloat(image.width) / frame.width
        let scaleY = CGFloat(image.height) / frame.height

        // スクリーン内のローカル座標へ。Y は上下を反転する。
        let localX = rect.minX - frame.minX
        let localY = frame.maxY - rect.maxY

        let pixelRect = CGRect(
            x: (localX * scaleX).rounded(.down),
            y: (localY * scaleY).rounded(.down),
            width: (rect.width * scaleX).rounded(),
            height: (rect.height * scaleY).rounded()
        )

        // 画像の外にはみ出した分は切り詰める。
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = pixelRect.intersection(bounds)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1,
              let cropped = image.cropping(to: clamped)
        else { throw CaptureError.cropFailed }

        return cropped
    }
}

extension NSScreen {
    /// このスクリーンの CGDirectDisplayID。
    var displayID: CGDirectDisplayID? {
        deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID
    }
}
