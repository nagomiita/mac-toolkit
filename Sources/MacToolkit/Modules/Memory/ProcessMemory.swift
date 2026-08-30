import Foundation
import Darwin

/// プロセスごとのメモリ使用量を読み、アプリ単位にまとめる。
///
/// 使う値は `ri_phys_footprint`。アクティビティモニタの「メモリ」列と
/// 同じ指標で、圧縮済みのぶんも含む実質的な占有量。
enum ProcessMemory {
    struct Entry: Identifiable, Sendable {
        var id: String { name }
        var name: String
        var bytes: UInt64
        /// まとめられたプロセス数（Chrome のヘルパーなど）。
        var processCount: Int
    }

    /// 実行パスの解決で読み飛ばす、中身を表さないディレクトリ名。
    private static let genericComponents: Set<String> = [
        "versions", "bin", "sbin", "libexec", "Contents", "MacOS",
        "Current", "Resources", "Helpers", "local", "share", "opt",
    ]

    /// メモリ使用量の多い順にアプリを返す。
    ///
    /// 他ユーザー（root）のプロセスは権限がなく読めないため除外される。
    /// そのぶん合計は実際の使用量より小さくなる。
    static func topApplications(limit: Int) -> [Entry] {
        var totals: [String: (bytes: UInt64, count: Int)] = [:]

        for pid in allProcessIDs() where pid > 0 {
            guard let footprint = physicalFootprint(of: pid) else { continue }
            let name = displayName(of: pid)
            let current = totals[name] ?? (0, 0)
            totals[name] = (current.bytes + footprint, current.count + 1)
        }

        return totals
            .map { Entry(name: $0.key, bytes: $0.value.bytes, processCount: $0.value.count) }
            .sorted { $0.bytes > $1.bytes }
            .prefix(limit)
            .map { $0 }
    }

    private static func allProcessIDs() -> [pid_t] {
        let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard size > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, size)
        guard written > 0 else { return [] }

        return Array(pids.prefix(Int(written) / MemoryLayout<pid_t>.size))
    }

    private static func physicalFootprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        // 権限のないプロセスはここで落ちる。エラーではないので黙って除外する。
        guard result == 0 else { return nil }
        return info.ri_phys_footprint
    }

    /// プロセスを人が読める名前にする。
    ///
    /// ヘルパープロセスは所属アプリ名にまとめたいので、実行パスから
    /// 最も外側の `.app` を探す。`Chrome Helper` を個別に並べるより
    /// 「Google Chrome が 9 GB」と見える方が知りたいことに近い。
    private static func displayName(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return processName(of: pid)
        }

        let path = String(cString: buffer)

        if let range = path.range(of: ".app/") ?? path.range(of: ".app") {
            let head = path[path.startIndex..<range.lowerBound]
            if let name = head.split(separator: "/").last {
                return String(name)
            }
        }

        // .app に属さない実行ファイル。末尾がバージョン番号の場合
        // （例: .../claude/versions/2.1.212）は意味のある親を探す。
        let components = path.split(separator: "/").map(String.init)
        for component in components.reversed() {
            guard !looksLikeVersion(component),
                  !genericComponents.contains(component),
                  !component.hasPrefix(".")
            else { continue }
            return component
        }

        return processName(of: pid)
    }

    private static func looksLikeVersion(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func processName(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let name = String(cString: buffer)
        return name.isEmpty ? "pid \(pid)" : name
    }
}
