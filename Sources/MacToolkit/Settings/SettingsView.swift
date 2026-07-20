import SwiftUI

struct SettingsView: View {
    @Bindable var registry: ModuleRegistry

    var body: some View {
        TabView {
            ModuleSettingsTab(registry: registry)
                // 「一般」のような曖昧な名前ではなく中身で名づける。
                .tabItem { Label("表示項目", systemImage: "square.grid.2x2") }

            UpdateSettingsTab(registry: registry)
                .tabItem { Label("更新間隔", systemImage: "timer") }
        }
        .frame(width: 460, height: 340)
    }
}

/// どのモジュールを使い、どれをメニューバーに出すかを 1 画面で決める。
/// 関係する設定は離さず隣に置く。
private struct ModuleSettingsTab: View {
    @Bindable var registry: ModuleRegistry

    var body: some View {
        Form {
            Section {
                ForEach(registry.modules, id: \.id) { module in
                    ModuleRow(registry: registry, module: module)
                }
            } header: {
                Text("表示する項目と、メニューバーに数値を出すかどうかを選べます")
            } footer: {
                Text("メニューバーに出さない項目も、アイコンをクリックすれば確認できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModuleRow: View {
    @Bindable var registry: ModuleRegistry
    let module: any ToolModule

    private var isEnabled: Bool { registry.isEnabled(module) }

    var body: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { isEnabled },
                set: { registry.setEnabled($0, for: module) }
            )) {
                Label(module.title, systemImage: module.systemImage)
            }

            Spacer()

            // メニューバーに出せるのは数値を持つモジュールだけ。
            if module.statusItemView() != nil {
                Toggle(isOn: Binding(
                    get: { registry.isShownInMenuBar(module) },
                    set: { registry.setShownInMenuBar($0, for: module) }
                )) {
                    Text("メニューバー")
                }
                .toggleStyle(.checkbox)
                // 無効な項目のメニューバー設定は触れないようにする。
                .disabled(!isEnabled)
                .foregroundStyle(isEnabled ? .primary : .secondary)
            }
        }
    }
}

private struct UpdateSettingsTab: View {
    @Bindable var registry: ModuleRegistry

    var body: some View {
        Form {
            Section {
                Picker("更新間隔", selection: $registry.interval) {
                    Text("0.5 秒").tag(0.5)
                    Text("1 秒").tag(1.0)
                    Text("2 秒").tag(2.0)
                    Text("5 秒").tag(5.0)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("間隔を短くすると表示は滑らかになりますが、電力を多く消費します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
