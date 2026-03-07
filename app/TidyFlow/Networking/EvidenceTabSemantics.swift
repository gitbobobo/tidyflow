import Foundation

// MARK: - 证据页 Tab 共享语义
// EvidenceTabType 是 macOS 与 iOS 共用的证据页 Tab 枚举。
// 分类规则、displayName、iconName、emptyStateText 在此集中定义，
// 两端不再各自维护独立的 switch/filter 逻辑。

/// 证据页 Tab 类型：截图 / 日志
enum EvidenceTabType: String, CaseIterable, Identifiable {
    case screenshot = "screenshot"
    case log = "log"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .screenshot: return "截图"
        case .log: return "日志"
        }
    }

    var iconName: String {
        switch self {
        case .screenshot: return "photo"
        case .log: return "doc.text"
        }
    }

    /// 空态提示文案
    var emptyStateText: String {
        switch self {
        case .screenshot: return "暂无截图数据"
        case .log: return "暂无日志数据"
        }
    }

    /// 判断一个证据条目是否属于本标签页类型（共享语义，macOS 与 iOS 统一使用）
    func matchesItem(_ item: EvidenceItemInfoV2) -> Bool {
        switch self {
        case .screenshot:
            return item.evidenceType == "screenshot" || item.mimeType.hasPrefix("image/")
        case .log:
            return item.evidenceType == "log" || (!item.mimeType.hasPrefix("image/") && item.evidenceType != "screenshot")
        }
    }

    /// 从快照中筛选出属于本标签页的条目，并按 order 排序（纯函数，多项目/多工作区安全）
    func filteredItems(from snapshot: EvidenceSnapshotV2) -> [EvidenceItemInfoV2] {
        snapshot.items.filter { matchesItem($0) }.sorted { $0.order < $1.order }
    }

    /// 返回快照中属于本标签页的条目数量
    func itemCount(in snapshot: EvidenceSnapshotV2) -> Int {
        snapshot.items.filter { matchesItem($0) }.count
    }
}
