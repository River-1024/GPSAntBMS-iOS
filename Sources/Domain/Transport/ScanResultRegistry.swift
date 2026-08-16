import Foundation

/// 扫描结果注册表：按 peripheral UUID 去重，并产出确定性 RSSI 排序的展示顺序。
///
/// 规则（与 Android 端「扫描结果按 RSSI 排序」对齐，补充确定性 tie-break）：
/// - 同一 peripheral UUID 只保留一个条目；重复发现时更新 RSSI，名称优先保留首个非空值；
/// - 展示顺序：RSSI 降序；RSSI 相同时有名称者在前（nil 名称排最后）；名称仍相同按 UUID 字符串升序。
struct ScanResultRegistry: Equatable {
    /// 单个扫描结果条目（与服务层 `BleDevice` 同构，保持纯逻辑可测）。
    struct Entry: Equatable {
        let id: UUID
        let name: String?
        let rssi: Int

        init(id: UUID, name: String?, rssi: Int) {
            self.id = id
            self.name = name
            self.rssi = rssi
        }
    }

    private(set) var entries: [Entry] = []

    /// 插入或更新一个扫描结果（按 `id` 去重）。
    mutating func upsert(id: UUID, name: String?, rssi: Int) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            let existing = entries[index]
            let mergedName = existing.name ?? name
            entries[index] = Entry(id: id, name: mergedName, rssi: rssi)
        } else {
            entries.append(Entry(id: id, name: name, rssi: rssi))
        }
    }

    /// 确定性展示顺序：RSSI 降序；RSSI 相同时有名称者在前（nil 名称排最后）；
    /// 名称相同（含均为 nil）按 UUID 字符串升序。
    func sortedForDisplay() -> [Entry] {
        entries.sorted { lhs, rhs in
            if lhs.rssi != rhs.rssi { return lhs.rssi > rhs.rssi }
            switch (lhs.name, rhs.name) {
            case (nil, nil):
                break
            case (nil, _):
                return false // lhs 无名称，不排在前
            case (_, nil):
                return true // rhs 无名称，lhs 在前
            case let (lhsName?, rhsName?) where lhsName != rhsName:
                return lhsName < rhsName
            default:
                break
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// 清空全部条目（扫描重启时调用）。
    mutating func removeAll() {
        entries.removeAll()
    }
}
