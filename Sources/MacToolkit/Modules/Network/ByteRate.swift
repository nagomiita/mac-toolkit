import Foundation

/// 毎秒バイト数を、メニューバーで桁が揺れない固定幅の文字列にする。
enum ByteRate {
    private static let units = ["B/s", "KB/s", "MB/s", "GB/s"]

    /// 例: `1.2 MB/s`、`340 KB/s`、`0 B/s`
    ///
    /// メニューバーは幅が揺れると隣のアイコンごと動いて目障りなので、
    /// 有効数字 3 桁に丸めて表示幅を一定に保つ。
    static func format(bytesPerSecond: Double) -> String {
        var value = max(0, bytesPerSecond)
        var unit = 0

        while value >= 1000, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }

        let text: String
        if unit == 0 {
            text = String(format: "%.0f", value)
        } else if value < 10 {
            text = String(format: "%.1f", value)
        } else {
            text = String(format: "%.0f", value)
        }

        return "\(text) \(units[unit])"
    }
}
