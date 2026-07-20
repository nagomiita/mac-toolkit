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

    /// ディスク I/O の速度（バイト/秒）。取れないときは nil。
    private(set) var readRate: Double?
    private(set) var writeRate: Double?

    /// 起動ボリューム。メニューバーにはこれだけを出す。
    var bootVolume: DiskCounters.Volume? {
        volumes.first { $0.path == "/" } ?? volumes.first
    }

    private var tickCount = 0
    private var previousIO: DiskIOCounters.Sample?
    private var lastSampledAt: Date?

    func start() {
        volumes = DiskCounters.read()
    }

    func stop() {
        volumes = []
        readRate = nil
        writeRate = nil
        previousIO = nil
        lastSampledAt = nil
        tickCount = 0
    }

    func tick() {
        sampleIO()

        // 容量は秒単位では動かないうえ、全ボリュームの問い合わせは
        // ネットワークボリュームがあると待たされることがある。5 秒に 1 回で十分。
        tickCount += 1
        guard tickCount % 5 == 0 else { return }
        volumes = DiskCounters.read()
    }

    /// ディスク I/O の速度を毎ティック更新する。累積カウンタの差分を取る。
    private func sampleIO() {
        let now = Date()
        defer { lastSampledAt = now }

        guard let current = DiskIOCounters.read() else {
            readRate = nil
            writeRate = nil
            previousIO = nil
            return
        }

        guard let last = previousIO, let lastAt = lastSampledAt else {
            previousIO = current
            readRate = nil
            writeRate = nil
            return
        }

        // 実際の経過時間で割る（Timer は tolerance の分ずれるため）。
        let elapsed = now.timeIntervalSince(lastAt)
        guard elapsed > 0 else { return }

        readRate = rate(from: last.read, to: current.read, seconds: elapsed)
        writeRate = rate(from: last.written, to: current.written, seconds: elapsed)
        previousIO = current
    }

    /// ドライブの抜き差しで合計が減ることがある。減っていたらその 1 回は捨てる。
    private func rate(from previous: UInt64, to current: UInt64, seconds: TimeInterval) -> Double {
        guard current >= previous else { return 0 }
        return Double(current - previous) / seconds
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
                systemImage: systemImage,
                summary: bootVolume.map { "空き \(Self.format($0.available))" }
            ) {
                // 読み書き速度。取得できたときだけ出す。
                if let readRate, let writeRate {
                    MetricRow(label: "読み込み", value: ByteRate.format(bytesPerSecond: readRate))
                    MetricRow(label: "書き込み", value: ByteRate.format(bytesPerSecond: writeRate))
                }

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
