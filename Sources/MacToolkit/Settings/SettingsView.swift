import SwiftUI

struct SettingsView: View {
    @Bindable var registry: ModuleRegistry

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("一般", systemImage: "gearshape") }
            modulesTab
                .tabItem { Label("モジュール", systemImage: "square.grid.2x2") }
        }
        .frame(width: 420, height: 300)
    }

    private var generalTab: some View {
        Form {
            Picker("更新間隔", selection: $registry.interval) {
                Text("0.5 秒").tag(0.5)
                Text("1 秒").tag(1.0)
                Text("2 秒").tag(2.0)
                Text("5 秒").tag(5.0)
            }
        }
        .formStyle(.grouped)
    }

    private var modulesTab: some View {
        Form {
            ForEach(registry.modules, id: \.id) { module in
                Toggle(isOn: Binding(
                    get: { registry.isEnabled(module) },
                    set: { registry.setEnabled($0, for: module) }
                )) {
                    Label(module.title, systemImage: module.systemImage)
                }
            }
        }
        .formStyle(.grouped)
    }
}
