import Foundation
import IOKit

/// バッテリーの状態を AppleSmartBattery から読む。
///
/// macOS 標準のアイコンが出さない健康度・サイクル数・電力・温度も含める。
final class BatteryCounters {
    struct Snapshot {
        /// 充電レベル（0.0〜1.0）。
        var charge: Double
        var isCharging: Bool
        var isPluggedIn: Bool
        var isFullyCharged: Bool
        /// バッテリー健康度（0.0〜1.0）。設計容量に対する現在の最大容量。
        var health: Double?
        var cycleCount: Int?
        /// セ氏温度。
        var temperature: Double?
        /// 現在の電力（W）。放電で正、充電で負、としてそのまま符号を保つより
        /// 大きさと向きを分けた方が扱いやすいので絶対値と充放電の別で持つ。
        var watts: Double?
        /// 接続中の電源アダプタの W 数。
        var adapterWatts: Int?
        /// 残り時間（分）。算出中・不明なときは nil。
        var minutesRemaining: Int?
    }

    /// バッテリー非搭載機（Mac mini / Studio など）では false。
    var isPresent: Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")
        )
        defer { if service != 0 { IOObjectRelease(service) } }
        return service != 0
    }

    func read() -> Snapshot? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service, &properties, kCFAllocatorDefault, 0
        ) == KERN_SUCCESS,
            let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else { return nil }

        // CurrentCapacity は MaxCapacity=100 のとき百分率。
        let currentCapacity = dictionary["CurrentCapacity"] as? Int ?? 0
        let charge = Double(currentCapacity) / 100

        // 健康度は設計容量に対する実効最大容量。
        // NominalChargeCapacity を使うと macOS 標準の「最大容量 %」と一致する
        // （AppleRawMaxCapacity だと数ポイント低く出て表示が食い違う）。
        var health: Double?
        if let design = dictionary["DesignCapacity"] as? Int, design > 0,
           let nominal = (dictionary["NominalChargeCapacity"] as? Int)
            ?? (dictionary["AppleRawMaxCapacity"] as? Int) {
            health = min(1, Double(nominal) / Double(design))
        }

        // 温度は 1/100 ℃ 単位。
        let temperature = (dictionary["Temperature"] as? Int).map { Double($0) / 100 }

        // 電力 = 電圧(mV) × 電流(mA)。InstantAmperage は放電で負。
        var watts: Double?
        if let milliVolts = dictionary["Voltage"] as? Int,
           let milliAmps = dictionary["InstantAmperage"] as? Int {
            watts = abs(Double(milliVolts) * Double(milliAmps)) / 1_000_000
        }

        let adapter = dictionary["AdapterDetails"] as? [String: Any]

        // TimeRemaining は 65535 が「算出中/不明」を表す番兵値。
        var minutesRemaining: Int?
        if let value = dictionary["TimeRemaining"] as? Int, value > 0, value < 65535 {
            minutesRemaining = value
        }

        return Snapshot(
            charge: charge,
            isCharging: (dictionary["IsCharging"] as? Bool) ?? false,
            isPluggedIn: (dictionary["ExternalConnected"] as? Bool) ?? false,
            isFullyCharged: (dictionary["FullyCharged"] as? Bool) ?? false,
            health: health,
            cycleCount: dictionary["CycleCount"] as? Int,
            temperature: temperature,
            watts: watts,
            adapterWatts: adapter?["Watts"] as? Int,
            minutesRemaining: minutesRemaining
        )
    }
}
