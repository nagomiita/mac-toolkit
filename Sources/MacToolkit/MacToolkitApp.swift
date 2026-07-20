import SwiftUI
import AppKit

@main
struct MacToolkitApp: App {
    @State private var registry: ModuleRegistry

    init() {
        let registry = ModuleRegistry(modules: [
            CPUModule(),
            NetworkSpeedModule()
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
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.33percent")
            ForEach(registry.activeModules, id: \.id) { module in
                if let view = module.statusItemView() { view }
            }
        }
    }
}

private struct MenuBarContentView: View {
    let registry: ModuleRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if registry.activeModules.isEmpty {
                Text("有効なモジュールがありません")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(registry.activeModules, id: \.id) { module in
                    module.detailView()
                }
            }

            Divider()

            HStack {
                SettingsLink { Text("設定…") }
                Spacer()
                Button("終了") {
                    registry.stopAll()
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}
