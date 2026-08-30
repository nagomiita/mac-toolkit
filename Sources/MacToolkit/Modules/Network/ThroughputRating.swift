import Foundation

/// 直近しばらくの間に出た最大スループットを覚えておく。
///
/// 瞬間の速度は「今どれだけ流しているか」でしかなく、回線の速さを表さない
/// （何もしていなければ 0 B/s になる）。実測だけで回線を語るには、
/// **負荷がかかった瞬間に出た最大値**を拾うしかない。
///
/// 全体で 1 つの最大値を持ち続けると、一度出た値が永遠に残って古くなる。
/// 短いバケットに区切って窓から出たものを捨てることで、
/// 「直近 10 分の最大」を安い計算で保つ。
struct PeakWindow {
    /// 判定に使う期間。
    static let window: TimeInterval = 600
    /// この粒度ごとに最大値を 1 つ持つ。20 個で 10 分。
    static let bucketDuration: TimeInterval = 30

    /// 開始時刻とその区間の最大値。常に時刻順で、要素数は 21 を超えない。
    private var buckets: [(start: Date, peak: Double)] = []

    /// 直近の窓に出た最大値。まだ 1 度も記録していなければ nil。
    var peak: Double? {
        buckets.map(\.peak).max()
    }

    mutating func record(_ rate: Double, at now: Date) {
        if let last = buckets.last, now.timeIntervalSince(last.start) < Self.bucketDuration {
            buckets[buckets.count - 1].peak = max(last.peak, rate)
        } else {
            buckets.append((start: now, peak: rate))
        }

        // 窓から出たバケットを捨てる。バケット単位なので判定は最大 30 秒粗くなるが、
        // 1 サンプルずつ持つより桁違いに安い。
        let cutoff = now.addingTimeInterval(-Self.window)
        buckets.removeAll { $0.start < cutoff }
    }

    /// インターフェースが変わったときなど、過去の値が無意味になったら捨てる。
    mutating func reset() {
        buckets.removeAll()
    }
}

/// 回線の速さの判定。
///
/// **実測の最大値が根拠なので、これは常に下限**であることに注意。
/// 「速い」は信用してよい（実際にその速度が出た証拠がある）が、
/// 「遅い」は「大きな通信をしていないだけ」かもしれない。
/// UI 側でその旨を添えること。
enum ThroughputRating {
    case slow
    case normal
    case fast

    var label: String {
        switch self {
        case .slow: "遅い"
        case .normal: "普通"
        case .fast: "速い"
        }
    }

    // しきい値は bytes/s。回線の表記は Mbps が一般的なので換算を併記する。
    /// 10 Mbps。これを下回ると会議やファイル共有で体感できる遅さになる。
    private static let slowCeiling: Double = 10_000_000 / 8
    /// 100 Mbps。家庭用の光回線で普通に出る水準。
    private static let normalCeiling: Double = 100_000_000 / 8

    /// 判定の材料と認めない最大値。1 Mbps 未満しか流れていない状態は
    /// 「回線が遅い」ではなく「まだ分からない」。
    private static let meaningfulFloor: Double = 1_000_000 / 8

    /// 直近の最大値から判定する。材料が足りなければ nil。
    static func rating(peakBytesPerSecond peak: Double?) -> ThroughputRating? {
        guard let peak, peak >= meaningfulFloor else { return nil }
        if peak >= normalCeiling { return .fast }
        if peak >= slowCeiling { return .normal }
        return .slow
    }
}
