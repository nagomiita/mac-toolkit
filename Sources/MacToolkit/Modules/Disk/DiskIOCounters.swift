import Foundation
import IOKit
import IOKit.storage

/// 内蔵・外付けドライブの累積読み書きバイト数を読む。
///
/// `IOBlockStorageDriver` の `Statistics` に、起動からの累積バイト数が入る。
/// 速度を出すには前回スナップショットとの差分を取ること（ネットワークと同じ）。
/// 値は 64 ビットの真のバイト数で 2^32 折り返しは起きないが、ドライブの
/// 抜き差しで合計が減ることはあるので、差分側で減少を必ず扱う。
enum DiskIOCounters {
    struct Sample {
        var read: UInt64
        var written: UInt64
    }

    // Statistics のキー。世代差は無いが、定数はプライベートなので文字列で持つ。
    private static let bytesReadKey = "Bytes (Read)"
    private static let bytesWriteKey = "Bytes (Write)"

    /// 全ドライブの累積読み書きバイト数を合計して返す。取れなければ nil。
    static func read() -> Sample? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWritten: UInt64 = 0
        var found = false

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            guard let stats = IORegistryEntryCreateCFProperty(
                service, "Statistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            // どちらか一方でも取れたドライブは集計対象にする。
            if let read = stats[bytesReadKey] as? UInt64 {
                totalRead += read
                found = true
            }
            if let written = stats[bytesWriteKey] as? UInt64 {
                totalWritten += written
                found = true
            }
        }

        return found ? Sample(read: totalRead, written: totalWritten) : nil
    }
}
