import Foundation

/// マウント済みボリュームの容量を読む。
enum DiskCounters {
    struct Volume: Identifiable {
        var id: String { path }
        var name: String
        var path: String
        var total: Int64
        /// 空き容量。削除可能ファイル（Time Machine のローカルスナップショット
        /// など）を含む、Finder が表示するのと同じ値。
        var available: Int64
        var isInternal: Bool
        var isRemovable: Bool

        var used: Int64 { max(0, total - available) }

        /// 使用率（0.0〜1.0）。
        var usage: Double {
            guard total > 0 else { return 0 }
            return Double(used) / Double(total)
        }
    }

    private static let keys: Set<URLResourceKey> = [
        .volumeNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeIsInternalKey,
        .volumeIsRemovableKey,
        .volumeIsBrowsableKey,
    ]

    /// 起動ボリュームを先頭に、内蔵→外付けの順で返す。
    static func read() -> [Volume] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []

        let volumes = urls.compactMap { url -> Volume? in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.volumeIsBrowsable != false,
                  let total = values.volumeTotalCapacity, total > 0
            else { return nil }

            // volumeAvailableCapacityForImportantUsage は Int64? で返る。
            // 取得できない場合はボリュームごと除外する（0 と表示すると
            // 「空きなし」と誤読されるため）。
            guard let available = values.volumeAvailableCapacityForImportantUsage
            else { return nil }

            return Volume(
                name: values.volumeName ?? url.lastPathComponent,
                path: url.path,
                total: Int64(total),
                available: available,
                isInternal: values.volumeIsInternal ?? true,
                isRemovable: values.volumeIsRemovable ?? false
            )
        }

        return volumes.sorted { lhs, rhs in
            if lhs.path == "/" { return true }
            if rhs.path == "/" { return false }
            if lhs.isInternal != rhs.isInternal { return lhs.isInternal }
            return lhs.name < rhs.name
        }
    }
}
