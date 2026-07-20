import Foundation

/// 温度センサーとファンをまとめて読む。
///
/// 温度は Apple Silicon の `IOHIDEventSystemClient` から、ファンは
/// `AppleSMC` から取る。どちらも公開ヘッダに無いプライベート API なので、
/// シンボルは dlsym で解決し、Xcode 無し（CLT のみ）でもビルドできるようにする。
///
/// センサーの列挙は 1 回だけ行い、以降は event 読み取りだけを繰り返す。
/// 全センサー（約 40 個）の読み取りは 40ms 前後かかるため、`tick()` から
/// 直接は呼ばず、モジュール側が `Task.detached` で数秒に 1 回だけ叩く。
///
/// CF リファレンスを保持するが、読み取りは単一フライト（同時に 1 回だけ）で
/// 直列化するので `@unchecked Sendable` とする。
final class ThermalSensors: @unchecked Sendable {
    struct Snapshot: Sendable {
        /// SoC（CPU/GPU クラスタ）のダイ温度。die センサーの平均。
        var socTemperature: Double?
        /// バッテリー温度。
        var batteryTemperature: Double?
        /// 内蔵ストレージ（NAND）温度。
        var storageTemperature: Double?
        /// ファンの数（0 ならファンレス機）。
        var fanCount: Int = 0
        /// 各ファンの現在の回転数（rpm）。
        var fanRPM: [Double] = []
    }

    // MARK: プライベート API の解決

    /// `kIOHIDEventTypeTemperature`。event の種別番号。
    private static let temperatureEventType: Int64 = 15

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject?, CFDictionary?) -> Void
    private typealias CopyServicesFn = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (AnyObject?, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn = @convention(c) (AnyObject?, UInt32) -> Double

    private struct HIDFunctions {
        let create: CreateFn
        let setMatching: SetMatchingFn
        let copyServices: CopyServicesFn
        let copyProperty: CopyPropertyFn
        let copyEvent: CopyEventFn
        let getFloat: GetFloatFn
    }

    /// IOKit のプライベート関数を dlsym で 1 度だけ引く。1 つでも欠けたら nil。
    private static let hid: HIDFunctions? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW
        ) else { return nil }

        func resolve<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        guard
            let create = resolve("IOHIDEventSystemClientCreate", CreateFn.self),
            let setMatching = resolve("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
            let copyServices = resolve("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
            let copyProperty = resolve("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
            let copyEvent = resolve("IOHIDServiceClientCopyEvent", CopyEventFn.self),
            let getFloat = resolve("IOHIDEventGetFloatValue", GetFloatFn.self)
        else { return nil }

        return HIDFunctions(
            create: create, setMatching: setMatching, copyServices: copyServices,
            copyProperty: copyProperty, copyEvent: copyEvent, getFloat: getFloat
        )
    }()

    // MARK: 起動時にセンサーを分類してキャッシュ

    /// 温度センサー 1 個。名前は起動時に 1 度だけ引いて保持する。
    private struct Sensor {
        let service: AnyObject
        let name: String
    }

    private let dieSensors: [Sensor]
    private let batterySensors: [Sensor]
    private let storageSensors: [Sensor]

    /// サービスは client が生きている間だけ有効。解放されると event が読めなく
    /// なるため、モジュールと同じ寿命で保持し続ける。
    private let client: AnyObject?

    private let fans: FanSensors

    init() {
        var die: [Sensor] = []
        var battery: [Sensor] = []
        var storage: [Sensor] = []
        var createdClient: AnyObject?

        if let hid = Self.hid,
           let client = hid.create(kCFAllocatorDefault)?.takeRetainedValue() {
            createdClient = client
            // AppleVendor（0xff00）の温度センサー（usage 5）だけを対象にする。
            let matching: [String: Int] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
            hid.setMatching(client, matching as CFDictionary)

            if let services = hid.copyServices(client)?.takeRetainedValue() as? [AnyObject] {
                for service in services {
                    let name = hid.copyProperty(service, "Product" as CFString)?
                        .takeRetainedValue() as? String ?? ""
                    let lower = name.lowercased()
                    // 較正定数（tcal）は温度に見えるが実測値ではないので除外する。
                    if lower.contains("tcal") { continue }
                    let sensor = Sensor(service: service, name: name)
                    if lower.contains("tdie") {
                        die.append(sensor)
                    } else if lower.contains("battery") {
                        battery.append(sensor)
                    } else if lower.contains("nand") {
                        storage.append(sensor)
                    }
                }
            }
        }

        client = createdClient
        dieSensors = die
        batterySensors = battery
        storageSensors = storage
        fans = FanSensors()
    }

    /// この Mac で温度かファンのどちらかが読めるか。両方だめならモジュールごと隠す。
    var isAvailable: Bool {
        !dieSensors.isEmpty || !batterySensors.isEmpty
            || !storageSensors.isEmpty || fans.fanCount > 0
    }

    /// 温度とファンをまとめて読む。40ms 前後かかるのでバックグラウンドで呼ぶこと。
    func read() -> Snapshot {
        Snapshot(
            socTemperature: average(dieSensors),
            batteryTemperature: average(batterySensors),
            storageTemperature: average(storageSensors),
            fanCount: fans.fanCount,
            fanRPM: fans.read()
        )
    }

    /// センサー群の平均温度。妥当な範囲（0〜150℃）の値だけを使う。
    private func average(_ sensors: [Sensor]) -> Double? {
        guard let hid = Self.hid else { return nil }
        var sum = 0.0
        var count = 0
        for sensor in sensors {
            guard let event = hid.copyEvent(
                sensor.service, Self.temperatureEventType, 0, 0
            )?.takeRetainedValue() else { continue }
            let value = hid.getFloat(event, UInt32(Self.temperatureEventType) << 16)
            // 未接続センサーは負値やノイズを返すので弾く。
            guard value.isFinite, value > 0, value < 150 else { continue }
            sum += value
            count += 1
        }
        return count > 0 ? sum / Double(count) : nil
    }
}
