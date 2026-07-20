import SwiftUI

/// ポップオーバー内の見た目を統一するための部品。
///
/// 「同じに見えるものは同じように振る舞い、同じ場所にある」ことを守るため、
/// 各モジュールは直接 Text を並べず必ずここの部品を使う。
enum Metrics {
    /// モジュール間の余白。
    static let sectionSpacing: CGFloat = 14
    /// セクション内の行間。
    static let rowSpacing: CGFloat = 5
    static let popoverWidth: CGFloat = 272
    static let popoverPadding: CGFloat = 14
}

// MARK: - タイポグラフィ

extension View {
    /// 見出し。大きい文字ほど字間を詰める（トラッキングはサイズ固有）。
    func moduleTitleStyle() -> some View {
        font(.system(.subheadline, weight: .semibold))
            .tracking(-0.1)
    }

    /// 項目名。半透明の背景に載るので、薄いグレーではなく
    /// やや太さを足して可読性を確保する。
    func metricLabelStyle() -> some View {
        font(.system(.callout, weight: .regular))
            .foregroundStyle(.secondary)
    }

    /// 数値。桁の揺れを防ぐため常に等幅数字。
    /// 太さで階層を作る（サイズを上げると情報密度が落ちるため）。
    func metricValueStyle() -> some View {
        font(.system(.callout, weight: .medium))
            .monospacedDigit()
    }

    /// 補足。小さい文字はわずかに字間を開けた方が読みやすい。
    func metricCaptionStyle() -> some View {
        font(.system(.caption, weight: .regular))
            .tracking(0.1)
            .foregroundStyle(.secondary)
    }

    /// メニューバーの数値。
    func menuBarValueStyle() -> some View {
        font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
    }
}

// MARK: - 部品

/// モジュール 1 つ分のまとまり。見出しと右肩の要約値。
struct ModuleSection<Content: View>: View {
    let title: String
    var summary: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).moduleTitleStyle()
                Spacer(minLength: 8)
                if let summary {
                    Text(summary).metricValueStyle()
                }
            }
            content
        }
    }
}

/// 項目名と値の 1 行。ラベルは左、値は右に揃える。
struct MetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).metricLabelStyle()
            Spacer(minLength: 12)
            Text(value).metricValueStyle()
        }
    }
}

/// 使用率などを表す横棒。
///
/// 半透明の上にさらに半透明を重ねると可読性が崩れるため、
/// 溝の色は「透明度を下げる」設定時に不透明へ切り替える。
struct MeterBar: View {
    let value: Double
    var tint: Color = .accentColor
    var height: CGFloat = 6

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(trackStyle)
                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * clamped)
            }
        }
        .frame(height: height)
        .accessibilityValue(Text("\(Int((clamped * 100).rounded()))パーセント"))
    }

    private var clamped: CGFloat { CGFloat(min(1, max(0, value))) }

    private var trackStyle: AnyShapeStyle {
        reduceTransparency
            ? AnyShapeStyle(Color.secondary.opacity(0.35))
            : AnyShapeStyle(.quaternary)
    }
}

/// 状態を表す小さな色付きの点。色だけに意味を持たせないよう、
/// 必ずテキストと組で使う。
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }
}
