import SwiftUI
import Observation

/// スクリーンショットを撮り、囲みを引いてコピーする。
///
/// 他のモジュールと違い数値を監視しないので `tick()` では何もしない。
/// ポップオーバーから撮影を始める入口だけを持つ。
@MainActor
@Observable
final class ScreenshotModule: ToolModule {
    let id = "screenshot"
    let title = "スクリーンショット"
    let systemImage = "camera.viewfinder"

    /// 権限が無い、撮影に失敗したなどの状態。正常時は nil。
    private(set) var message: String?
    /// 権限が拒否されているとき、システム設定への導線を出すため。
    private(set) var needsPermission = false

    private let selector = RegionSelector()

    func stop() {
        message = nil
    }

    /// 監視する値が無いので何もしない。
    func tick() {}

    /// メニューバーには数値を出さない（撮影の入口はポップオーバーに置く）。
    func statusItemView() -> AnyView? { nil }

    /// 範囲を選んで撮影し、編集窓を開く。
    func capture() {
        message = nil

        // 権限は「その機能を初めて使うとき」に要求する。
        guard ScreenCapturer.hasPermission else {
            ScreenCapturer.requestPermission()
            // 許可は再起動後に効くことがあるため、その場では撮影に進まない。
            needsPermission = true
            message = "画面収録の権限が必要です"
            return
        }
        needsPermission = false

        selector.begin { [weak self] result in
            guard let self else { return }
            guard let (rect, screen) = result else { return }

            Task { @MainActor in
                // 覆いを消した直後だと、消える前の画面が写ることがある。
                // 1 フレーム分待ってから撮る。
                try? await Task.sleep(for: .milliseconds(120))
                do {
                    let image = try await ScreenCapturer.capture(rect: rect, on: screen)
                    ScreenshotEditor.open(image: image)
                } catch {
                    self.message = "撮影できません"
                }
            }
        }
    }

    func detailView() -> AnyView {
        AnyView(
            ModuleSection(
                title: title,
                systemImage: systemImage
            ) {
                Button {
                    self.capture()
                } label: {
                    Label("範囲を選んで撮影", systemImage: "viewfinder")
                }
                .buttonStyle(.accessoryBar)

                Text("ドラッグで範囲を選ぶ　Esc で取り消し")
                    .metricCaptionStyle()

                if let message {
                    Text(message).metricCaptionStyle()
                }

                if needsPermission {
                    Button("システム設定を開く") {
                        ScreenCapturer.openPermissionSettings()
                    }
                    .buttonStyle(.accessoryBar)
                }
            }
        )
    }
}
