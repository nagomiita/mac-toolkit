import Foundation

/// コアごとの CPU 使用ティックを読む。
///
/// カーネルが返すのは起動からの累積ティック数なので、使用率を出すには
/// 必ず前回スナップショットとの差分を取ること。
final class CPUCounters {
    /// 1 コア分の累積ティック。
    struct Ticks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32

        var total: UInt64 {
            UInt64(user) + UInt64(system) + UInt64(idle) + UInt64(nice)
        }
    }

    /// 1 コア分の使用率（0.0〜1.0）。
    struct Usage {
        var user: Double
        var system: Double
        var nice: Double

        var total: Double { user + system + nice }
    }

    /// 高性能コアの数。Apple Silicon 以外や取得失敗時は nil。
    let performanceCoreCount: Int?
    /// 高効率コアの数。
    let efficiencyCoreCount: Int?

    init() {
        performanceCoreCount = Self.sysctlInt("hw.perflevel0.logicalcpu")
        efficiencyCoreCount = Self.sysctlInt("hw.perflevel1.logicalcpu")
    }

    /// 全論理コアの累積ティックを返す。添字がコア番号。
    func read() -> [Ticks] {
        var count = natural_t(0)
        var info: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &count,
            &info,
            &infoCount
        )

        guard result == KERN_SUCCESS, let info else { return [] }

        // host_processor_info はカーネルから受け取ったメモリを呼び出し側に
        // 渡す。解放しないと毎ティックリークするので必ず deallocate する。
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        return (0..<Int(count)).map { core in
            let base = core * Int(CPU_STATE_MAX)
            return Ticks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            )
        }
    }

    /// 2 つのスナップショットの差分からコアごとの使用率を求める。
    ///
    /// コア数が変わった場合（起こらないはずだが）は空を返す。
    static func usage(from previous: [Ticks], to current: [Ticks]) -> [Usage] {
        guard previous.count == current.count else { return [] }

        return zip(previous, current).map { old, new in
            // ティックは 32 ビットで折り返す。差が負になったら
            // そのコアの値は捨てる（次のティックで正常に戻る）。
            let total = new.total >= old.total ? new.total - old.total : 0
            guard total > 0 else { return Usage(user: 0, system: 0, nice: 0) }

            let divisor = Double(total)
            return Usage(
                user: delta(old.user, new.user) / divisor,
                system: delta(old.system, new.system) / divisor,
                nice: delta(old.nice, new.nice) / divisor
            )
        }
    }

    private static func delta(_ old: UInt32, _ new: UInt32) -> Double {
        new >= old ? Double(new - old) : 0
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
