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

    // MARK: - @Published 属性

    /// 共享 Git 工作区状态（key: globalKey -> GitWorkspaceState）
    /// 通过 GitWorkspaceStateDriver 统一管理 status/branch/stage/commit 等状态迁移
    @Published var workspaceGitState: [String: GitWorkspaceState] = [:]

    // Phase C2-2a: Diff Cache (key: "workspace:path:mode" -> DiffCache)
    @Published var diffCache: [String: DiffCache] = [:]

    // Git Log Cache (workspace key -> GitLogCache)
    @Published var gitLogCache: [String: GitLogCache] = [:]

    // Git Show Cache (workspace key + sha -> GitShowCache)
    @Published var gitShowCache: [String: GitShowCache] = [:]

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

    // v1.50: Stash 缓存（key = "project:workspace"）
    @Published var stashListCache: [String: GitStashListCache] = [:]
    @Published var stashShowCache: [String: GitStashShowCache] = [:]
    /// 当前选中的 stash ID（按 "project:workspace" 隔离）
    @Published var selectedStashId: [String: String] = [:]
    /// Stash 操作进行中标志（按 "project:workspace" 隔离）
    @Published var stashOpInFlight: [String: Bool] = [:]
    /// 最近一次 stash 操作错误（按 "project:workspace" 隔离）
    @Published var stashLastError: [String: String] = [:]

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

    func stashCacheKey(project: String, workspace: String) -> String {
        return workspaceCacheKey(workspace: workspace, project: project)
    }

    func stashShowCacheKey(project: String, workspace: String, stashId: String) -> String {
        return "\(workspaceCacheKey(workspace: workspace, project: project)):stash:\(stashId)"
    }

    // MARK: - 资源管理：按工作区边界淘汰缓存

    /// 清除指定工作区的全部 Git 缓存数据。
    /// 在工作区被删除、项目下线或断线重连时调用，防止残留数据误导界面。
    /// - Parameter globalKey: "project:workspace" 格式的全局键
    func clearWorkspaceCache(globalKey: String) {
        workspaceGitState.removeValue(forKey: globalKey)
        gitLogCache.removeValue(forKey: globalKey)
        gitOpStatusCache.removeValue(forKey: globalKey)
        gitIntegrationStatusCache.removeValue(forKey: globalKey)
        rebaseInFlight.removeValue(forKey: globalKey)
        mergeInFlight.removeValue(forKey: globalKey)
        rebaseOntoDefaultInFlight.removeValue(forKey: globalKey)
        gitStatusIndexCache.removeValue(forKey: globalKey)
        stashListCache.removeValue(forKey: globalKey)
        selectedStashId.removeValue(forKey: globalKey)
        stashOpInFlight.removeValue(forKey: globalKey)
        stashLastError.removeValue(forKey: globalKey)
        // Stash show 缓存键格式为 "project:workspace:stash:<stash_id>"
        let stashPrefix = globalKey + ":stash:"
        stashShowCache.keys.filter { $0.hasPrefix(stashPrefix) }.forEach { stashShowCache.removeValue(forKey: $0) }
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

        evictSimpleCache(&workspaceGitState)
        evictSimpleCache(&gitLogCache)
        evictSimpleCache(&gitOpStatusCache)
        evictSimpleCache(&gitIntegrationStatusCache)
        evictSimpleCache(&rebaseInFlight)
        evictSimpleCache(&mergeInFlight)
        evictSimpleCache(&rebaseOntoDefaultInFlight)
        evictSimpleCache(&gitStatusIndexCache)
        evictPrefixCache(&diffCache)
        evictPrefixCache(&gitShowCache)
        evictSimpleCache(&stashListCache)
        evictSimpleCache(&selectedStashId)
        evictSimpleCache(&stashOpInFlight)
        evictSimpleCache(&stashLastError)
        evictPrefixCache(&stashShowCache)
    }

    // MARK: - 共享驱动辅助方法

    /// 将输入投递到共享 Git 工作区驱动，更新状态并返回待执行的副作用列表。
    @discardableResult
    func driveGitInput(
        _ input: GitWorkspaceInput,
        project: String,
        workspace: String
    ) -> [GitWorkspaceEffect] {
        let key = workspaceCacheKey(workspace: workspace, project: project)
        let context = GitWorkspaceContext(projectName: project, workspaceName: workspace, globalKey: key)
        let currentState = workspaceGitState[key] ?? .empty
        let (newState, effects) = GitWorkspaceStateDriver.reduce(state: currentState, input: input, context: context)
        if currentState != newState {
            workspaceGitState[key] = newState
        }
        return effects
    }

    /// 执行共享驱动产出的副作用列表（翻译为 WSClient 调用）
    func executeGitEffects(_ effects: [GitWorkspaceEffect], project: String, workspace: String) {
        for effect in effects {
            switch effect {
            case .requestStatus(let cacheMode):
                wsClient?.requestGitStatus(project: project, workspace: workspace, cacheMode: cacheMode)
            case .requestBranches(let cacheMode):
                wsClient?.requestGitBranches(project: project, workspace: workspace, cacheMode: cacheMode)
            case .requestStage(let path, let scope):
                wsClient?.requestGitStage(project: project, workspace: workspace, path: path, scope: scope)
            case .requestUnstage(let path, let scope):
                wsClient?.requestGitUnstage(project: project, workspace: workspace, path: path, scope: scope)
            case .requestDiscard(let path, let scope, let includeUntracked):
                wsClient?.requestGitDiscard(project: project, workspace: workspace, path: path, scope: scope, includeUntracked: includeUntracked)
            case .requestCommit(let message):
                wsClient?.requestGitCommit(project: project, workspace: workspace, message: message)
            case .requestSwitchBranch(let name):
                wsClient?.requestGitSwitchBranch(project: project, workspace: workspace, branch: name)
            case .requestCreateBranch(let name):
                wsClient?.requestGitCreateBranch(project: project, workspace: workspace, branch: name)
            }
        }
    }

    /// 便捷方法：投递输入到共享驱动并立即执行副作用
    func applyGitInput(
        _ input: GitWorkspaceInput,
        project: String,
        workspace: String
    ) {
        let effects = driveGitInput(input, project: project, workspace: workspace)
        executeGitEffects(effects, project: project, workspace: workspace)
    }
}
