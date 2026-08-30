import SwiftUI

/// ポップオーバー内の見た目を統一するための部品。
///
/// 「同じに見えるものは同じように振る舞い、同じ場所にある」ことを守るため、
/// 各モジュールは直接 Text を並べず必ずここの部品を使う。
enum Metrics {
    /// モジュール間の余白。区切り線と併用するので、線がなかった頃より狭くする
    /// （線と余白で二重に離すと間延びする）。
    static let sectionSpacing: CGFloat = 10
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

/// モジュール 1 つ分のまとまり。折りたたみ式。
///
/// 既定では見出し行（アイコン・タイトル・要約値）だけを見せ、クリックで
/// 詳細を開く。7 モジュールを全部展開するとポップオーバーが縦に伸びすぎる
/// ため、「共通の道を先に、詳細は一段深く」に従って畳んでおく。
/// 開閉状態はモジュールごとに永続化する。
///
/// 見出しにアイコンを添えるのは、区切り線と合わせて
/// 「どこで領域が変わったか」を形でも拾えるようにするため。
struct ModuleSection<Content: View>: View {
    let title: String
    var systemImage: String?
    var summary: String?
    @ViewBuilder var content: Content

    @AppStorage private var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        title: String,
        systemImage: String? = nil,
        summary: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.summary = summary
        self.content = content()
        // タイトルをキーにして開閉を覚える。既定は畳んだ状態。
        _isExpanded = AppStorage(wrappedValue: false, "section.expanded.\(title)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            Button(action: toggle) {
                header
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
                    .transition(.opacity)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    // アイコンの幅を揃えて見出しの左端を一直線にする。
                    .frame(width: 14, alignment: .center)
            }
            Text(title).moduleTitleStyle()
            Spacer(minLength: 8)
            if let summary {
                Text(summary).metricValueStyle()
            }
            // 開閉の向きを示す。畳んでいるときは右向き。
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
        }
        // 見出し行全体をクリック対象にする。
        .contentShape(Rectangle())
    }

    private func toggle() {
        // reduce-motion 時は開閉のアニメーションを避け、即座に切り替える。
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
        }
    }
}

/// モジュール間の区切り。
///
/// ポップオーバー自体が半透明のマテリアルなので、カード状の面を重ねると
/// 可読性が落ちる。面ではなく細い線で区切り、線は控えめにして
/// 余白との合わせ技で領域を示す。
struct SectionSeparator: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Divider()
            .opacity(contrast == .increased ? 1 : 0.6)
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

/// 直近の使用率（0.0〜1.0）の折れ線グラフ。CPU と GPU で共用する。
///
/// 面で塗ると半透明の上に半透明が重なって読みづらくなるため、
/// 線と控えめな塗りに留める。
struct UsageHistoryChart: View {
    let values: [Double]
    /// 横軸に確保する点数。値がこれに満たない間はグラフが右へ伸びていく。
    var capacity: Int = 60

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let step = width / CGFloat(max(1, capacity - 1))

            let line = Path { path in
                for (index, value) in values.enumerated() {
                    let point = CGPoint(
                        x: CGFloat(index) * step,
                        y: height * (1 - CGFloat(min(1, max(0, value))))
                    )
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }

            ZStack {
                if values.count > 1 {
                    var area = line
                    let _ = {
                        area.addLine(to: CGPoint(x: CGFloat(values.count - 1) * step, y: height))
                        area.addLine(to: CGPoint(x: 0, y: height))
                        area.closeSubpath()
                    }()
                    area.fill(.tint.opacity(0.18))
                }
                line.stroke(.tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 5))
    }

    private var backgroundStyle: AnyShapeStyle {
        reduceTransparency
            ? AnyShapeStyle(Color.secondary.opacity(0.25))
            : AnyShapeStyle(.quaternary.opacity(0.5))
    }
}
