import SwiftUI
import Observation

/// ストレージの空き容量を表示する。
@MainActor
@Observable
final class DiskModule: ToolModule {
    let id = "disk"
    let title = "ストレージ"
    let systemImage = "internaldrive"

    private(set) var volumes: [DiskCounters.Volume] = []

    /// 起動ボリューム。メニューバーにはこれだけを出す。
    var bootVolume: DiskCounters.Volume? {
        volumes.first { $0.path == "/" } ?? volumes.first
    }

    private var tickCount = 0

    func start() {
        volumes = DiskCounters.read()
    }

    func stop() {
        volumes = []
        tickCount = 0
    }

    /// 容量は秒単位では動かないうえ、全ボリュームの問い合わせは
    /// ネットワークボリュームがあると待たされることがある。5 秒に 1 回で十分。
    func tick() {
        tickCount += 1
        guard tickCount % 5 == 0 else { return }
        volumes = DiskCounters.read()
    }

    func statusItemView() -> AnyView? {
        guard let bootVolume else { return nil }
        return AnyView(
            Text(Self.format(bootVolume.available))
                .menuBarValueStyle()
                .frame(minWidth: 46, alignment: .trailing)
        )
    }

    func detailView() -> AnyView {
        AnyView(
            ModuleSection(
                title: title,
                summary: bootVolume.map { "空き \(Self.format($0.available))" }
            ) {
                if volumes.isEmpty {
                    Text("取得できません").metricCaptionStyle()
                } else {
                    ForEach(volumes) { volume in
                        VolumeRow(volume: volume)
                    }
                }
            }
        )
    }

    /// ストレージは 10 進（1 GB = 1000^3）で数える。Finder と同じ流儀。
    static func format(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1000 {
            return String(format: "%.2f TB", gb / 1000)
        }
        return String(format: "%.0f GB", gb)
    }
}

private struct VolumeRow: View {
    let volume: DiskCounters.Volume

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(volume.name).metricLabelStyle()
                } icon: {
                    Image(systemName: volume.isRemovable ? "externaldrive" : "internaldrive")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text(DiskModule.format(volume.available)).metricValueStyle()
            }

            // 残り 10% を切ったら赤にする。色だけでなく下の行に数値も出す。
            MeterBar(value: volume.usage, tint: volume.usage >= 0.9 ? .red : .accentColor)

            Text("\(DiskModule.format(volume.used)) / \(DiskModule.format(volume.total)) を使用")
                .metricCaptionStyle()
        }
    }
}
