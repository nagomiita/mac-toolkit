import Foundation
import SystemConfiguration

/// ネットワークインターフェースの累積送受信バイト数を読む。
///
/// カーネルが返すのは起動からの累積値なので、速度を出すには必ず
/// 前回スナップショットとの差分を取ること。
///
/// なお `if_data64.ifi_ibytes` は 64 ビット型だが、実測すると値は 2^32 で
/// 折り返す（`netstat -ib` の表示と正確に 2^32 ずれる）。差分計算側で
/// 前回値より小さくなるケースを必ず扱うこと。
final class InterfaceCounters {
    struct Sample {
        var received: UInt64
        var sent: UInt64
    }

    /// `SCDynamicStore` の生成は毎ティックやるには重いので使い回す。
    private let store: SCDynamicStore?

    init() {
        store = SCDynamicStoreCreate(nil, "mac-toolkit" as CFString, nil, nil)
    }

    /// 全インターフェースの累積バイト数を名前引きで返す。
    func readAll() -> [String: Sample] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0

        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return [:] }

        var buffer = [UInt8](repeating: 0, count: size)
        // 1 回目と 2 回目の sysctl の間にインターフェースが増減すると ENOMEM に
        // なる。常駐アプリでは実際に起きるので、失敗しても空を返して次の
        // ティックに任せる。
        guard sysctl(&mib, 6, &buffer, &size, nil, 0) == 0 else { return [:] }

        var result: [String: Sample] = [:]

        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0

            while offset + MemoryLayout<if_msghdr>.size <= size {
                // メッセージ長は 8 の倍数とは限らず、構造体が 8 バイト境界に
                // 揃っている保証がない。アライメントを要求する load を使うと
                // 値が壊れるので、必ず loadUnaligned を使う。
                let header = base.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                defer { offset += messageLength }

                guard header.ifm_type == RTM_IFINFO2,
                      offset + MemoryLayout<if_msghdr2>.size <= size else { continue }

                let info = base.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)

                // sockaddr_dl は if_msghdr2 の直後に続く。
                let linkOffset = offset + MemoryLayout<if_msghdr2>.size
                guard linkOffset + MemoryLayout<sockaddr_dl>.size <= size else { continue }
                let link = base.loadUnaligned(fromByteOffset: linkOffset, as: sockaddr_dl.self)

                let nameLength = Int(link.sdl_nlen)
                // sdl_data は sockaddr_dl の先頭から 8 バイト目から始まる。
                let nameOffset = linkOffset + 8
                guard nameLength > 0, nameOffset + nameLength <= size else { continue }

                let nameBytes = UnsafeRawBufferPointer(start: base + nameOffset, count: nameLength)
                guard let name = String(bytes: nameBytes, encoding: .utf8) else { continue }

                result[name] = Sample(
                    received: info.ifm_data.ifi_ibytes,
                    sent: info.ifm_data.ifi_obytes
                )
            }
        }

        return result
    }

    /// デフォルトルートが向いているインターフェース名（例: `en0`）。
    ///
    /// Wi-Fi と有線を切り替えるとここが変わるので、毎回引き直す。
    func primaryInterfaceName() -> String? {
        guard let store,
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
                as? [String: Any]
        else { return nil }

        return global["PrimaryInterface"] as? String
    }
}
