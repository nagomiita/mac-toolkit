import SwiftUI
import Observation

/// メモリ使用量とメモリプレッシャーを表示する。
@MainActor
@Observable
final class MemoryModule: ToolModule {
    let id = "memory"
    let title = "メモリ"
    let systemImage = "memorychip"

    private(set) var snapshot: MemoryCounters.Snapshot?
    /// メモリ使用量の多いアプリ。
    private(set) var topApps: [ProcessMemory.Entry] = []

    private let counters = MemoryCounters()
    private var tickCount = 0
    private var isScanningProcesses = false

    private static let topAppCount = 5

    func stop() {
        snapshot = nil
        topApps = []
        tickCount = 0
    }

    func tick() {
        snapshot = counters.read()

        // 全プロセスの走査は 10ms 前後かかり、tick() を 1ms 未満に保つ方針に
        // 反する。10 ティックに 1 回、バックグラウンドで実行する。
        tickCount += 1
        if tickCount % 10 == 1 { scanTopApplications() }
    }

    private func scanTopApplications() {
        guard !isScanningProcesses else { return }
        isScanningProcesses = true

        Task.detached(priority: .utility) { [limit = Self.topAppCount] in
            let apps = ProcessMemory.topApplications(limit: limit)
            await MainActor.run {
                self.topApps = apps
                self.isScanningProcesses = false
            }
        }
    }

    func statusItemView() -> AnyView? {
        AnyView(
            Text(snapshot.map { Self.gigabytes($0.used) } ?? "--")
                .menuBarValueStyle()
                .frame(minWidth: 44, alignment: .trailing)
        )
    }

    func detailView() -> AnyView {
        AnyView(
            ModuleSection(
                title: title,
                systemImage: systemImage,
                summary: snapshot.map { "\(Self.gigabytes($0.used)) / \(Self.gigabytes($0.total))" }
            ) {
                if let snapshot {
                    MemoryBreakdownBar(snapshot: snapshot)
                        .frame(height: 8)
                        .padding(.bottom, 2)

                    MetricRow(label: "Wired", value: Self.gigabytes(snapshot.wired))
                    MetricRow(label: "アクティブ", value: Self.gigabytes(snapshot.active))
                    MetricRow(label: "圧縮", value: Self.gigabytes(snapshot.compressed))
                    MetricRow(label: "キャッシュ", value: Self.gigabytes(snapshot.cached))

                    if snapshot.swapTotal > 0 {
                        MetricRow(
                            label: "スワップ",
                            value: "\(Self.gigabytes(snapshot.swapUsed)) / \(Self.gigabytes(snapshot.swapTotal))"
                        )
                    }

                    // 色だけに意味を持たせず、必ず数値と併記する。
                    HStack(spacing: 5) {
                        StatusDot(color: Self.pressureColor(snapshot.pressure))
                        Text("メモリプレッシャー \(Int((snapshot.pressure * 100).rounded()))%")
                            .metricCaptionStyle()
                    }
                    .padding(.top, 1)

                    if !topApps.isEmpty {
                        TopApplicationsList(entries: topApps)
                            .padding(.top, 6)
                    }
                } else {
                    Text("取得できません").metricCaptionStyle()
                }
            }
        )
    }

    /// アプリ単位の使用量は GB だと桁が潰れるので、1GB 未満は MB で出す。
    static func megabytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    static func pressureColor(_ pressure: Double) -> Color {
        switch pressure {
        case ..<0.6: .green
        case ..<0.8: .yellow
        default: .red
        }
    }
}

/// メモリ使用量の多いアプリの一覧。
///
/// 既に情報量の多いセクションなので、行ごとに棒を足すと騒がしくなる。
/// 名前と数値だけを並べ、最大のアプリだけ相対量が分かるよう
/// 背景に控えめな帯を敷く。
private struct TopApplicationsList: View {
    let entries: [ProcessMemory.Entry]

    private var maximum: Double {
        Double(entries.map(\.bytes).max() ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("使用量の多いアプリ")
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(entries) { entry in
                row(entry)
            }
        }
    }

    private func row(_ entry: ProcessMemory.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Text(MemoryModule.megabytes(entry.bytes))
                .font(.system(.callout, weight: .medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(alignment: .leading) {
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 4)
                    .fill(.tint.opacity(0.14))
                    .frame(width: geometry.size.width * CGFloat(Double(entry.bytes) / maximum))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name) \(MemoryModule.megabytes(entry.bytes))")
    }
}

/// メモリの内訳を積み上げバーで表す。
private struct MemoryBreakdownBar: View {
    let snapshot: MemoryCounters.Snapshot

    private var segments: [(value: UInt64, color: Color)] {
        [
            (snapshot.wired, .orange),
            (snapshot.active, .blue),
            (snapshot.compressed, .purple),
            (snapshot.cached, .gray.opacity(0.5)),
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: width(for: segment.value, in: geometry.size.width))
                }
                Spacer(minLength: 0)
            }
        }
        .background(.quaternary.opacity(0.5))
        .clipShape(Capsule())
    }

    private func width(for value: UInt64, in total: CGFloat) -> CGFloat {
        guard snapshot.total > 0 else { return 0 }
        return total * CGFloat(Double(value) / Double(snapshot.total))
    }
}
