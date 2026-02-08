import Foundation
import Combine
import SwiftUI

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

    // Git 状态索引缓存（资源管理器用，workspace key -> GitStatusIndex）
    var gitStatusIndexCache: [String: GitStatusIndex] = [:]

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

    func diffCacheKey(workspace: String, path: String, mode: String) -> String {
        return "\(workspace):\(path):\(mode)"
    }

    func gitStatusCacheKey(project: String, workspace: String) -> String {
        return "\(project):\(workspace)"
    }

    func gitLogCacheKey(project: String, workspace: String) -> String {
        return "\(project):\(workspace)"
    }
}
