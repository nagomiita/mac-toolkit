import Foundation
import IOKit
import Metal

/// GPU の使用率と使用メモリを IOAccelerator から読む。
final class GPUCounters {
    struct Snapshot {
        /// 使用率（0.0〜1.0）。取得できない場合は nil。
        var utilization: Double?
        /// GPU が使用中のメモリ（バイト）。
        var inUseMemory: UInt64?
    }

    /// Metal から得た GPU 名（例: "Apple M2"）。起動中変わらないので一度だけ。
    let deviceName: String?

    init() {
        deviceName = MTLCreateSystemDefaultDevice()?.name
    }

    /// 使用率のキーは世代で名前が違うことがあるため、候補を順に探す。
    private static let utilizationKeys = [
        "Device Utilization %",
        "GPU Activity(%)",
        "Renderer Utilization %",
    ]
    private static let memoryKeys = [
        "In use system memory",
        "vramUsedBytes",
    ]

    func read() -> Snapshot {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else {
            return Snapshot(utilization: nil, inUseMemory: nil)
        }
        defer { IOObjectRelease(iterator) }

        // 最初に見つかった IOAccelerator（既定の GPU）を使う。
        // eGPU 対応は将来ここを全走査に広げる。
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return Snapshot(utilization: nil, inUseMemory: nil) }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service, &properties, kCFAllocatorDefault, 0
        ) == KERN_SUCCESS,
            let dictionary = properties?.takeRetainedValue() as? [String: Any],
            let stats = dictionary["PerformanceStatistics"] as? [String: Any]
        else {
            return Snapshot(utilization: nil, inUseMemory: nil)
        }

        let utilization = Self.utilizationKeys
            .lazy
            .compactMap { stats[$0] as? Int }
            .first
            .map { Double($0) / 100 }

        let memory = Self.memoryKeys
            .lazy
            .compactMap { stats[$0] as? Int }
            .first
            .map { UInt64($0) }

        return Snapshot(utilization: utilization, inUseMemory: memory)
    }
}
