import Foundation
import Combine
import SwiftUI
import TidyFlowShared

/// 独立的 Git 缓存状态对象
/// 从 AppState 拆分出来，避免 Git 高频更新触发全局视图刷新
///
/// 方法实现拆分至：
/// - GitCacheState+DiffStatus.swift  — Diff / Status / Log / Show API
/// - GitCacheState+Operations.swift  — Stage/Unstage / Branch / Commit / Rebase / Merge / Integration API
class GitCacheState: ObservableObject {

    // MARK: - @Published 属性（原 AppState 中的 Git 相关属性）

    // Phase C2-2a: Diff Cache (key: "workspace:path:mode" -> DiffCache)
    @Published var diffCache: [String: DiffCache] = [:]

    // Phase C3-1: Git Status Cache (workspace key -> GitStatusCache)
    @Published var gitStatusCache: [String: GitStatusCache] = [:]

    // Git Log Cache (workspace key -> GitLogCache)
    @Published var gitLogCache: [String: GitLogCache] = [:]

    // Git Show Cache (workspace key + sha -> GitShowCache)
    @Published var gitShowCache: [String: GitShowCache] = [:]

    // Phase C3-2a: Git operation in-flight tracking (workspace key -> Set<GitOpInFlight>)
    @Published var gitOpsInFlight: [String: Set<GitOpInFlight>] = [:]

    // Phase C3-3a: Git Branch Cache (workspace key -> GitBranchCache)
    @Published var gitBranchCache: [String: GitBranchCache] = [:]
    // Phase C3-3a: Branch switch in-flight (workspace key -> target branch)
    @Published var branchSwitchInFlight: [String: String] = [:]
    // Phase C3-3b: Branch create in-flight (workspace key -> new branch name)
    @Published var branchCreateInFlight: [String: String] = [:]

    // Phase C3-4a: Commit message per workspace
    @Published var commitMessage: [String: String] = [:]
    // Phase C3-4a: Commit in-flight (workspace key -> true)
    @Published var commitInFlight: [String: Bool] = [:]

    // Phase UX-3a: Git operation status cache (workspace key -> GitOpStatusCache)
    @Published var gitOpStatusCache: [String: GitOpStatusCache] = [:]
    // Phase UX-3a: Rebase in-flight (workspace key -> true)
    @Published var rebaseInFlight: [String: Bool] = [:]

    // Phase UX-3b: Git integration status cache (workspace key -> GitIntegrationStatusCache)
    @Published var gitIntegrationStatusCache: [String: GitIntegrationStatusCache] = [:]
    // Phase UX-3b: Merge in-flight (workspace key -> true)
    @Published var mergeInFlight: [String: Bool] = [:]
    // Phase UX-4: Rebase onto default in-flight (workspace key -> true)
    @Published var rebaseOntoDefaultInFlight: [String: Bool] = [:]

    // v1.40: 冲突向导缓存（key = "project:workspace" 或 "project:integration"）
    @Published var conflictWizardCache: [String: ConflictWizardCache] = [:]

    // Git 状态索引缓存（资源管理器用，workspace key -> GitStatusIndex）
    var gitStatusIndexCache: [String: GitStatusIndex] = [:]

    // MARK: - 缓存可观测性指标（Core 权威输出，按 "project:workspace" 隔离）

    /// 从 Core system_snapshot 获取的 Git 缓存指标快照
    /// key: "project:workspace"；值由 Core 计算，客户端只消费
    private(set) var cacheMetricsIndex: [String: WorkspaceCacheMetricsModel] = [:]

    /// 更新 Git 缓存指标（由 AppState 在收到 system_snapshot 后调用）
    func updateCacheMetrics(_ metrics: SystemSnapshotCacheMetrics) {
        cacheMetricsIndex = metrics.index
    }

    /// 按 (project, workspace) 查询 Git 缓存指标（不存在则返回空指标）
    func gitCacheMetrics(project: String, workspace: String) -> GitCacheMetricsModel {
        let key = "\(project):\(workspace)"
        return cacheMetricsIndex[key]?.gitCache ?? .empty()
    }

    // MARK: - 由 AppState 注入的依赖

    weak var wsClient: WSClient?
    var getProjectName: (() -> String)?
    var getConnectionState: (() -> ConnectionState)?
    var getSelectedWorkspaceKey: (() -> String?)?

    // 跨域回调（handleGitOpResult 需要操作 tab）
    var onCloseAllDiffTabs: ((String) -> Void)?
    var onCloseDiffTab: ((String, String) -> Void)?
    var onRefreshActiveDiff: (() -> Void)?
    var getActiveDiffPath: (() -> String?)?
    var getActiveDiffMode: (() -> DiffMode)?

    // MARK: - 便捷属性（跨 extension 文件访问）

    var selectedProjectName: String {
        getProjectName?() ?? "default"
    }

    var connectionState: ConnectionState {
        getConnectionState?() ?? .disconnected
    }

    var selectedWorkspaceKey: String? {
        getSelectedWorkspaceKey?()
    }

    // MARK: - Cache Key 辅助方法（跨 extension 文件访问）

    func workspaceCacheKey(workspace: String, project: String? = nil) -> String {
        let projectName = project ?? selectedProjectName
        return WorkspaceKeySemantics.globalKey(project: projectName, workspace: workspace)
    }

    func diffCacheKey(project: String, workspace: String, path: String, mode: String) -> String {
        return "\(workspaceCacheKey(workspace: workspace, project: project)):\(path):\(mode)"
    }

    func diffCacheKey(workspace: String, path: String, mode: String) -> String {
        return diffCacheKey(project: selectedProjectName, workspace: workspace, path: path, mode: mode)
    }

    func gitStatusCacheKey(project: String, workspace: String) -> String {
        return workspaceCacheKey(workspace: workspace, project: project)
    }

    func gitLogCacheKey(project: String, workspace: String) -> String {
        return workspaceCacheKey(workspace: workspace, project: project)
    }

    func gitShowCacheKey(project: String, workspace: String, sha: String) -> String {
        return "\(workspaceCacheKey(workspace: workspace, project: project)):\(sha)"
    }

    // MARK: - 资源管理：按工作区边界淘汰缓存

    /// 清除指定工作区的全部 Git 缓存数据。
    /// 在工作区被删除、项目下线或断线重连时调用，防止残留数据误导界面。
    /// - Parameter globalKey: "project:workspace" 格式的全局键
    func clearWorkspaceCache(globalKey: String) {
        gitStatusCache.removeValue(forKey: globalKey)
        gitLogCache.removeValue(forKey: globalKey)
        gitBranchCache.removeValue(forKey: globalKey)
        gitOpsInFlight.removeValue(forKey: globalKey)
        gitOpStatusCache.removeValue(forKey: globalKey)
        gitIntegrationStatusCache.removeValue(forKey: globalKey)
        commitMessage.removeValue(forKey: globalKey)
        commitInFlight.removeValue(forKey: globalKey)
        rebaseInFlight.removeValue(forKey: globalKey)
        mergeInFlight.removeValue(forKey: globalKey)
        rebaseOntoDefaultInFlight.removeValue(forKey: globalKey)
        branchSwitchInFlight.removeValue(forKey: globalKey)
        branchCreateInFlight.removeValue(forKey: globalKey)
        gitStatusIndexCache.removeValue(forKey: globalKey)
        // Diff 缓存键格式为 "project:workspace:path:mode"，按前缀过滤
        let prefix = globalKey + ":"
        diffCache.keys.filter { $0.hasPrefix(prefix) }.forEach { diffCache.removeValue(forKey: $0) }
        gitShowCache.keys.filter { $0.hasPrefix(prefix) }.forEach { gitShowCache.removeValue(forKey: $0) }
    }

    /// 淘汰非活跃工作区的 Git 缓存，保留当前活跃工作区数据不受影响。
    /// 多项目并行时降低非活跃工作区的常驻内存占用。
    /// - Parameter activeGlobalKey: 当前活跃工作区的全局键（"project:workspace"）
    func evictNonActiveWorkspaceCache(activeGlobalKey: String) {
        let activePrefix = activeGlobalKey + ":"

        func evictSimpleCache<V>(_ cache: inout [String: V]) {
            cache.keys.filter { $0 != activeGlobalKey }.forEach { cache.removeValue(forKey: $0) }
        }
        func evictPrefixCache<V>(_ cache: inout [String: V]) {
            cache.keys.filter { !$0.hasPrefix(activePrefix) && $0 != activeGlobalKey }
                .forEach { cache.removeValue(forKey: $0) }
        }

        evictSimpleCache(&gitStatusCache)
        evictSimpleCache(&gitLogCache)
        evictSimpleCache(&gitBranchCache)
        evictSimpleCache(&gitOpsInFlight)
        evictSimpleCache(&gitOpStatusCache)
        evictSimpleCache(&gitIntegrationStatusCache)
        evictSimpleCache(&commitMessage)
        evictSimpleCache(&commitInFlight)
        evictSimpleCache(&rebaseInFlight)
        evictSimpleCache(&mergeInFlight)
        evictSimpleCache(&rebaseOntoDefaultInFlight)
        evictSimpleCache(&branchSwitchInFlight)
        evictSimpleCache(&branchCreateInFlight)
        evictSimpleCache(&gitStatusIndexCache)
        evictPrefixCache(&diffCache)
        evictPrefixCache(&gitShowCache)
    }
}
