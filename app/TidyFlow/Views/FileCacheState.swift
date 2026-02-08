import Foundation
import Combine

/// 独立的文件缓存状态对象
/// 从 AppState 拆分出来，避免文件高频更新（文件监控事件、目录展开/折叠）触发全局视图刷新
/// 仅 ExplorerView、CommandPaletteView 等文件相关视图需要观察此对象
class FileCacheState: ObservableObject {

    // MARK: - @Published 属性（原 AppState 中的文件缓存相关属性）

    /// 文件索引缓存（workspace key -> FileIndexCache），用于 Quick Open 搜索
    @Published var fileIndexCache: [String: FileIndexCache] = [:]

    /// 文件列表缓存 (key: "project:workspace:path" -> FileListCache)
    @Published var fileListCache: [String: FileListCache] = [:]

    /// 目录展开状态 (key: "project:workspace:path" -> isExpanded)
    @Published var directoryExpandState: [String: Bool] = [:]
}
