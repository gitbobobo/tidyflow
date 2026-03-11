import Foundation
import Combine
import TidyFlowShared

/// 独立的文件缓存状态对象
/// 从 AppState 拆分出来，避免文件高频更新（文件监控事件、目录展开/折叠）触发全局视图刷新
/// 仅 ExplorerView、CommandPaletteView 等文件相关视图需要观察此对象
class FileCacheState: ObservableObject {

    // MARK: - 文件工作区相位（统一状态机）

    /// 按 (project, workspace) 隔离的文件工作区相位。
    /// key: "project:workspace" 格式的全局键。
    /// 相位由 Core 权威管理，客户端通过 WS 事件更新，不自行推导。
    @Published private(set) var workspacePhases: [String: FileWorkspacePhase] = [:]

    /// 查询指定工作区的当前文件相位。不存在时返回 `.idle`。
    func phase(for globalKey: String) -> FileWorkspacePhase {
        workspacePhases[globalKey] ?? .idle
    }

    /// 更新指定工作区的文件相位。
    func setPhase(_ phase: FileWorkspacePhase, for globalKey: String) {
        guard workspacePhases[globalKey] != phase else { return }
        workspacePhases[globalKey] = phase
    }

    /// watcher 订阅成功时调用。
    func onWatchSubscribed(globalKey: String) {
        setPhase(.watching, for: globalKey)
    }

    /// watcher 退订时调用。
    func onWatchUnsubscribed(globalKey: String) {
        setPhase(.idle, for: globalKey)
    }

    /// 连接断开时重置所有相位为 idle。
    func resetAllPhasesOnDisconnect() {
        for key in workspacePhases.keys {
            workspacePhases[key] = .idle
        }
    }

    // MARK: - @Published 属性（原 AppState 中的文件缓存相关属性）

    /// 文件索引缓存（workspace key -> FileIndexCache），用于 Quick Open 搜索
    @Published var fileIndexCache: [String: FileIndexCache] = [:]

    /// 文件列表缓存 (key: "project:workspace:path" -> FileListCache)
    @Published var fileListCache: [String: FileListCache] = [:]

    /// 目录展开状态 (key: "project:workspace:path" -> isExpanded)
    @Published var directoryExpandState: [String: Bool] = [:]

    // MARK: - 缓存可观测性指标（Core 权威输出，按 "project:workspace" 隔离）

    /// 从 Core system_snapshot 获取的文件缓存指标快照
    /// key: "project:workspace"；值由 Core 计算，客户端只消费
    private(set) var cacheMetricsIndex: [String: WorkspaceCacheMetricsModel] = [:]

    /// 更新指定工作区的缓存指标（由 AppState 在收到 system_snapshot 后调用）
    /// - Parameters:
    ///   - metrics: Core 权威输出的 system_snapshot cache_metrics
    func updateCacheMetrics(_ metrics: SystemSnapshotCacheMetrics) {
        cacheMetricsIndex = metrics.index
    }

    /// 按 (project, workspace) 查询文件缓存指标（不存在则返回空指标）
    func fileCacheMetrics(project: String, workspace: String) -> FileCacheMetricsModel {
        let key = "\(project):\(workspace)"
        return cacheMetricsIndex[key]?.fileCache ?? .empty()
    }

    /// 按 (project, workspace) 查询该工作区是否超出预算（Core 权威判定）
    func isBudgetExceeded(project: String, workspace: String) -> Bool {
        let key = "\(project):\(workspace)"
        return cacheMetricsIndex[key]?.budgetExceeded ?? false
    }

    // MARK: - 资源管理：按工作区边界淘汰缓存

    /// 清除指定工作区的全部文件缓存（文件索引、文件列表、目录展开状态）。
    /// 在工作区被删除、项目下线或断线重连时调用。
    /// - Parameter globalKey: "project:workspace" 格式的全局键
    func clearWorkspaceCache(globalKey: String) {
        fileIndexCache.removeValue(forKey: globalKey)
        let prefix = globalKey + ":"
        fileListCache.keys
            .filter { $0.hasPrefix(prefix) }
            .forEach { fileListCache.removeValue(forKey: $0) }
        directoryExpandState.keys
            .filter { $0.hasPrefix(prefix) }
            .forEach { directoryExpandState.removeValue(forKey: $0) }
    }

    /// 淘汰非活跃工作区的文件缓存，保留当前活跃工作区数据不受影响。
    /// 多项目并行时降低非活跃工作区的常驻内存占用。
    /// - Parameter activeGlobalKey: 当前活跃工作区的全局键（"project:workspace"）
    func evictNonActiveWorkspaceCache(activeGlobalKey: String) {
        let activePrefix = activeGlobalKey + ":"

        fileIndexCache.keys
            .filter { $0 != activeGlobalKey }
            .forEach { fileIndexCache.removeValue(forKey: $0) }

        fileListCache.keys
            .filter { !$0.hasPrefix(activePrefix) }
            .forEach { fileListCache.removeValue(forKey: $0) }

        // 保留活跃工作区的目录展开状态；非活跃工作区的展开状态也可释放，
        // 切换回该工作区时会自然重建（根目录默认关闭）。
        directoryExpandState.keys
            .filter { !$0.hasPrefix(activePrefix) }
            .forEach { directoryExpandState.removeValue(forKey: $0) }
    }
}
