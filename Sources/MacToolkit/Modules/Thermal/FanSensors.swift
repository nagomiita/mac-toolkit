import Foundation
import IOKit

/// AppleSMC からファンの回転数を読む。
///
/// キーの読み書きは `IOConnectCallStructMethod` に固定レイアウトの構造体を
/// 渡す独特の作法で行う。構造体のバイト数（80）と各フィールドの位置を
/// C 定義と厳密に一致させないとカーネルが `kIOReturnBadArgument` を返すため、
/// レイアウトは変更しないこと（特に keyInfo と result の間の `padding`）。
///
/// 読み取りは単一フライトで直列化されるので `@unchecked Sendable` とする。
final class FanSensors: @unchecked Sendable {
    // MARK: SMC の構造体（レイアウト厳守・80 バイト）

    private struct SMCVersion {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0
        var reserved: UInt8 = 0, release: UInt16 = 0
    }
    private struct SMCPLimitData {
        var version: UInt16 = 0, length: UInt16 = 0
        var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
    }
    private struct SMCKeyInfoData {
        var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0
    }
    private struct SMCKeyData {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        // keyInfo（9 バイト）と result の間に入る詰め物。これが無いと構造体が
        // 76 バイトになりカーネルに弾かれる。C 定義に合わせて必ず置く。
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static let kKernelIndex: UInt32 = 2
    private static let kReadKeyInfo: UInt8 = 9
    private static let kReadBytes: UInt8 = 5

    private var connection: io_connect_t = 0
    /// ファンの数。起動時に 1 度だけ読む（実行中に変わらない）。
    let fanCount: Int

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { fanCount = 0; return }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else {
            fanCount = 0
            return
        }
        connection = conn

        // FNum（ui8）にファンの数が入る。取れなければ 0＝ファンレス扱い。
        if let bytes = Self.readKey("FNum", connection: conn), let first = bytes.first {
            fanCount = Int(first)
        } else {
            fanCount = 0
        }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// 各ファンの現在の回転数（rpm）。ファンレス機では空配列。
    func read() -> [Double] {
        guard fanCount > 0, connection != 0 else { return [] }
        var result: [Double] = []
        for index in 0..<fanCount {
            // F0Ac, F1Ac … が「現在の回転数」。
            if let bytes = Self.readKey("F\(index)Ac", connection: connection),
               let rpm = Self.decodeRPM(bytes) {
                result.append(rpm)
            }
        }
        return result
    }

    // MARK: SMC 呼び出し

    private static func fourCharCode(_ string: String) -> UInt32 {
        var code: UInt32 = 0
        for byte in string.utf8 { code = (code << 8) + UInt32(byte) }
        return code
    }

    private static func call(_ input: inout SMCKeyData, connection: io_connect_t) -> (kern_return_t, SMCKeyData) {
        var output = SMCKeyData()
        let inSize = MemoryLayout<SMCKeyData>.stride
        var outSize = MemoryLayout<SMCKeyData>.stride
        let kr = IOConnectCallStructMethod(connection, kKernelIndex, &input, inSize, &output, &outSize)
        return (kr, output)
    }

    /// キーの型情報を引いてからバイト列を読む。取れなければ nil。
    private static func readKey(_ key: String, connection: io_connect_t) -> [UInt8]? {
        var info = SMCKeyData()
        info.key = fourCharCode(key)
        info.data8 = kReadKeyInfo
        let (kr1, out1) = call(&info, connection: connection)
        guard kr1 == kIOReturnSuccess, out1.keyInfo.dataSize > 0 else { return nil }

        var read = SMCKeyData()
        read.key = fourCharCode(key)
        read.keyInfo = out1.keyInfo
        read.data8 = kReadBytes
        let (kr2, out2) = call(&read, connection: connection)
        guard kr2 == kIOReturnSuccess else { return nil }

        let size = Int(out1.keyInfo.dataSize)
        let all = Mirror(reflecting: out2.bytes).children.compactMap { $0.value as? UInt8 }
        return Array(all.prefix(size))
    }

    /// ファン回転数のバイト列を rpm に直す。
    /// 新しい Mac は `flt`（4 バイトの浮動小数）、古い Mac は `fpe2`（固定小数）。
    private static func decodeRPM(_ bytes: [UInt8]) -> Double? {
        switch bytes.count {
        case 4:
            // リトルエンディアンの IEEE754 float。
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float(bitPattern: bits))
            return value.isFinite && value >= 0 ? value : nil
        case 2:
            // fpe2: ビッグエンディアン 16bit を 2bit 右シフト。
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(raw >> 2)
        default:
            return nil
        }
    }
}
