import SwiftUI
import AppKit

@main
struct MacToolkitApp: App {
    @State private var registry: ModuleRegistry

    init() {
        let registry = ModuleRegistry(modules: [
            CPUModule(),
            GPUModule(),
            MemoryModule(),
            DiskModule(),
            BatteryModule(),
            ThermalModule(),
            NetworkSpeedModule(),
            WiFiModule(),
        ])
        registry.startAll()
        _registry = State(initialValue: registry)

        // .app バンドル外から `swift run` した場合でも Dock に出さない。
        // （バンドル実行時は Info.plist の LSUIElement が効く）
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(registry: registry)
        } label: {
            MenuBarLabelView(registry: registry)
        }
        // 後々グラフなどリッチな UI を置けるよう window スタイルにする。
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(registry: registry)
        }
    }
}

private struct MenuBarLabelView: View {
    let registry: ModuleRegistry

    var body: some View {
        HStack(spacing: 6) {
            // 数値を 1 つも出さない設定でもクリック対象が残るようアイコンは常に出す。
            if registry.menuBarModules.isEmpty {
                Image(systemName: "gauge.with.dots.needle.33percent")
            }
            ForEach(registry.menuBarModules, id: \.id) { module in
                if let view = module.statusItemView() { view }
            }
        }
    }
}

private struct MenuBarContentView: View {
    let registry: ModuleRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            if registry.activeModules.isEmpty {
                emptyState
            } else {
                let modules = registry.activeModules
                ForEach(Array(modules.enumerated()), id: \.element.id) { index, module in
                    module.detailView()
                    // 最後のモジュールの下は Divider が続くので線を重ねない。
                    if index < modules.count - 1 {
                        SectionSeparator()
                    }
                }
            }

            Divider()
            footer
        }
        .padding(Metrics.popoverPadding)
        .frame(width: Metrics.popoverWidth)
    }

    /// 「どこにいるか・どうすれば出られるか」に必ず答える。
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("表示中の項目はありません").moduleTitleStyle()
            Text("設定でモジュールを有効にしてください").metricCaptionStyle()
        }
    }

    private var footer: some View {
        HStack {
            SettingsLink {
                Text("設定…")
            }
            Spacer()
            Button("終了") {
                registry.stopAll()
                NSApplication.shared.terminate(nil)
            }
        }
        .buttonStyle(.accessoryBar)
        .font(.callout)
    }
}
