import CoreWLAN
import Foundation

/// 接続中の Wi-Fi の状態。
struct WiFiInfo {
    /// SSID は位置情報の許可がないと nil になる（他の項目は取得できる）。
    var ssid: String?
    var bssid: String?
    var rssi: Int
    var noise: Int
    var channel: Int?
    var band: String?
    var channelWidth: String?
    var phyMode: String
    var transmitRate: Double
    var security: String
    var ipAddress: String?

    /// 信号品質（0.0〜1.0）。RSSI を実用的な範囲で正規化したもの。
    ///
    /// -50 dBm 以上を満点、-100 dBm を 0 とする。dBm は対数なので
    /// この線形マッピングは目安であり、アンテナ本数の表示用途に留める。
    var quality: Double {
        let clamped = min(-50, max(-100, Double(rssi)))
        return (clamped + 100) / 50
    }

    /// SN 比（dB）。大きいほど良い。
    var signalToNoise: Int { rssi - noise }
}

/// CoreWLAN から Wi-Fi の状態を読む。
enum WiFiReader {
    static func read(from interface: CWInterface) -> WiFiInfo? {
        guard interface.powerOn() else { return nil }

        let channel = interface.wlanChannel()

        return WiFiInfo(
            ssid: interface.ssid(),
            bssid: interface.bssid(),
            rssi: interface.rssiValue(),
            noise: interface.noiseMeasurement(),
            channel: channel?.channelNumber,
            band: channel.map { describe($0.channelBand) },
            channelWidth: channel.map { describe($0.channelWidth) },
            phyMode: describe(interface.activePHYMode()),
            transmitRate: interface.transmitRate(),
            security: describe(interface.security()),
            ipAddress: ipv4Address(of: interface.interfaceName)
        )
    }

    /// 指定インターフェースに割り当てられた IPv4 アドレス。
    static func ipv4Address(of interfaceName: String?) -> String? {
        guard let interfaceName else { return nil }

        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.ifa_name) == interfaceName
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0,
                NI_NUMERICHOST
            )
            if result == 0 { return String(cString: host) }
        }

        return nil
    }

    // MARK: - 表示名

    /// 定着した規格名なので日本語には訳さない。
    private static func describe(_ mode: CWPHYMode) -> String {
        switch mode {
        case .mode11a: "802.11a"
        case .mode11b: "802.11b"
        case .mode11g: "802.11g"
        case .mode11n: "Wi-Fi 4 (802.11n)"
        case .mode11ac: "Wi-Fi 5 (802.11ac)"
        case .mode11ax: "Wi-Fi 6 (802.11ax)"
        case .modeNone: "未接続"
        @unknown default: "不明"
        }
    }

    private static func describe(_ band: CWChannelBand) -> String {
        switch band {
        case .band2GHz: "2.4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        case .bandUnknown: "不明"
        @unknown default: "不明"
        }
    }

    private static func describe(_ width: CWChannelWidth) -> String {
        switch width {
        case .width20MHz: "20 MHz"
        case .width40MHz: "40 MHz"
        case .width80MHz: "80 MHz"
        case .width160MHz: "160 MHz"
        case .widthUnknown: "不明"
        @unknown default: "不明"
        }
    }

    private static func describe(_ security: CWSecurity) -> String {
        switch security {
        case .none: "なし"
        case .WEP: "WEP"
        case .wpaPersonal, .wpaPersonalMixed: "WPA"
        case .wpa2Personal: "WPA2 パーソナル"
        case .wpa3Personal: "WPA3 パーソナル"
        case .wpa3Transition: "WPA2/WPA3 移行"
        case .wpa3Enterprise: "WPA3 エンタープライズ"
        case .wpaEnterprise, .wpaEnterpriseMixed: "WPA エンタープライズ"
        case .wpa2Enterprise: "WPA2 エンタープライズ"
        case .personal: "パーソナル"
        case .enterprise: "エンタープライズ"
        case .dynamicWEP: "動的 WEP"
        // OWE（オープンネットワークの暗号化）。定着した略称なので訳さない。
        case .OWE: "OWE"
        case .oweTransition: "OWE 移行"
        case .unknown: "不明"
        @unknown default: "不明"
        }
    }
}
