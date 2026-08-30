import Foundation

/// 物理メモリとスワップの使用状況を読む。
///
/// CPU やネットワークと違い、こちらは累積値ではなく現在値なので差分は不要。
final class MemoryCounters {
    struct Snapshot {
        /// 搭載物理メモリ（バイト）。
        var total: UInt64
        /// カーネルが確保して解放できない領域。
        var wired: UInt64
        /// 使用中で最近アクセスされた領域。
        var active: UInt64
        /// 圧縮済みの領域。
        var compressed: UInt64
        /// ファイルキャッシュなど、必要なら解放できる領域。
        var cached: UInt64
        var swapUsed: UInt64
        var swapTotal: UInt64

        /// アクティビティモニタの「使用済みメモリ」に相当する。
        /// キャッシュは解放可能なので含めない。
        var used: UInt64 { wired + active + compressed }

        /// メモリプレッシャー（0.0〜1.0）。
        ///
        /// 解放しづらい領域が物理メモリに占める割合。アクティビティモニタの
        /// 圧力グラフと厳密に同じ計算ではないが、緑/黄/赤の判断には十分。
        var pressure: Double {
            guard total > 0 else { return 0 }
            return min(1, Double(wired + compressed) / Double(total))
        }
    }

    /// 搭載物理メモリ。起動中に変わらないので一度だけ読む。
    private let physicalMemory: UInt64

    init() {
        physicalMemory = ProcessInfo.processInfo.physicalMemory
    }

    func read() -> Snapshot? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        // ページサイズは機種依存（Apple Silicon は 16KB、Intel は 4KB）。
        // ハードコードすると値が 4 倍ずれるので必ず実行時に取得する。
        let pageSize = UInt64(vm_kernel_page_size)
        let swap = readSwapUsage()

        return Snapshot(
            total: physicalMemory,
            wired: UInt64(stats.wire_count) * pageSize,
            active: UInt64(stats.active_count) * pageSize,
            compressed: UInt64(stats.compressor_page_count) * pageSize,
            cached: UInt64(stats.external_page_count) * pageSize,
            swapUsed: swap.used,
            swapTotal: swap.total
        )
    }

    private func readSwapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]

        guard sysctl(&mib, 2, &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }
}
