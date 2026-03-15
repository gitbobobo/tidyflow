// GitWorkspaceStateDriver.swift
// TidyFlowShared
//
// 跨平台 Git 工作区状态驱动：定义共享的纯值类型、状态机和副作用描述。
// 共享层管理工作区级 Git 面板的读模型（status/branch）、操作中间态（stage/unstage/discard/commit/switch/create）
// 和刷新语义（statusChanged/op成功后自动拉取），不直接依赖 SwiftUI/AppKit/UIKit/WSClient，
// 平台层仅把 effect descriptor 翻译为具体网络请求。
// diff/log/show/conflict/integration 缓存不在本驱动管理范围内，由平台层各自维护。

import Foundation

// MARK: - GitWorkspaceContext

/// Git 工作区上下文，标识状态归属的 project:workspace。
public struct GitWorkspaceContext: Equatable, Hashable, Sendable {
    public let projectName: String
    public let workspaceName: String
    public let globalKey: String

    public init(projectName: String, workspaceName: String, globalKey: String) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.globalKey = globalKey
    }

    public init(projectName: String, workspaceName: String) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.globalKey = "\(projectName):\(workspaceName)"
    }
}

// MARK: - GitWorkspaceEffect

/// 共享副作用描述：平台层将其翻译为具体 WSClient 调用。
/// 不直接持有 WSClient 引用，保证共享层与网络层解耦。
public enum GitWorkspaceEffect: Equatable {
    case requestStatus(cacheMode: HTTPQueryCacheMode)
    case requestBranches(cacheMode: HTTPQueryCacheMode)
    case requestStage(path: String?, scope: String)
    case requestUnstage(path: String?, scope: String)
    case requestDiscard(path: String?, scope: String, includeUntracked: Bool)
    case requestCommit(message: String)
    case requestSwitchBranch(name: String)
    case requestCreateBranch(name: String)
    // v1.60: Sequencer 操作副作用
    case requestOpStatus(cacheMode: HTTPQueryCacheMode)
    case requestCherryPick(commitShas: [String])
    case requestRevert(commitShas: [String])
    case requestCherryPickContinue
    case requestCherryPickAbort
    case requestRevertContinue
    case requestRevertAbort
    case requestWorkspaceOpRollback
}

// MARK: - GitWorkspaceInput

/// Git 工作区输入事件。所有共享状态迁移必须通过此枚举触发。
public enum GitWorkspaceInput {
    // 用户意图
    case refreshStatus(cacheMode: HTTPQueryCacheMode)
    case refreshBranches(cacheMode: HTTPQueryCacheMode)
    case stage(path: String?, scope: String)
    case unstage(path: String?, scope: String)
    case discard(path: String?, scope: String, includeUntracked: Bool)
    case commit(message: String)
    case switchBranch(name: String)
    case createBranch(name: String)

    // 服务端结果
    case gitStatusResult(GitStatusResult)
    case gitBranchesResult(GitBranchesResult)
    case gitOpResult(GitOpResult)
    case gitCommitResult(GitCommitResult)
    case gitStatusChanged
    // v1.60: Sequencer 服务端结果
    case gitSequencerResult(GitSequencerResult)
    case gitWorkspaceOpRollbackResult(GitWorkspaceOpRollbackResult)
    case gitOpStatusResult(GitOpStatusResult)

    // 环境变化
    case connectionChanged(isConnected: Bool)
}

// MARK: - GitWorkspaceState

/// 单个工作区的 Git 共享状态。
/// 以 `(project, workspace)` 为作用域，平台层按 globalKey 存取。
public struct GitWorkspaceState: Equatable {

    /// Git 状态缓存（status 命令结果）
    public var statusCache: GitStatusCache
    /// Git 分支缓存（branches 命令结果）
    public var branchCache: GitBranchCache
    /// 正在执行中的 stage/unstage/discard 操作
    public var opsInFlight: Set<GitOpInFlight>
    /// 正在切换的目标分支名（nil = 无切换进行中）
    public var branchSwitchInFlight: String?
    /// 正在创建的新分支名（nil = 无创建进行中）
    public var branchCreateInFlight: String?
    /// 提交是否正在进行
    public var commitInFlight: Bool
    /// 当前工作区的提交消息（由 UI 层读写，driver 在 commit 成功后清空）
    public var commitMessage: String
    /// 最近一次提交结果提示
    public var commitResult: String?
    /// 是否已经至少收到过一次 Git 状态结果
    public var hasResolvedStatus: Bool
    /// Git 操作状态缓存（op-status 命令结果）
    public var opStatusCache: GitOpStatusCache
    /// 提交历史选择状态
    public var commitSelection: GitCommitSelectionState
    /// 最近一次 sequencer 操作结果（用于显示结果 banner）
    public var lastSequencerResult: GitSequencerResult?

    public static let empty = GitWorkspaceState(
        statusCache: .empty(),
        branchCache: .empty(),
        opsInFlight: [],
        branchSwitchInFlight: nil,
        branchCreateInFlight: nil,
        commitInFlight: false,
        commitMessage: "",
        commitResult: nil,
        hasResolvedStatus: false,
        opStatusCache: .empty(),
        commitSelection: .empty,
        lastSequencerResult: nil
    )

    public init(
        statusCache: GitStatusCache,
        branchCache: GitBranchCache,
        opsInFlight: Set<GitOpInFlight>,
        branchSwitchInFlight: String?,
        branchCreateInFlight: String?,
        commitInFlight: Bool,
        commitMessage: String,
        commitResult: String?,
        hasResolvedStatus: Bool,
        opStatusCache: GitOpStatusCache = .empty(),
        commitSelection: GitCommitSelectionState = .empty,
        lastSequencerResult: GitSequencerResult? = nil
    ) {
        self.statusCache = statusCache
        self.branchCache = branchCache
        self.opsInFlight = opsInFlight
        self.branchSwitchInFlight = branchSwitchInFlight
        self.branchCreateInFlight = branchCreateInFlight
        self.commitInFlight = commitInFlight
        self.commitMessage = commitMessage
        self.commitResult = commitResult
        self.hasResolvedStatus = hasResolvedStatus
        self.opStatusCache = opStatusCache
        self.commitSelection = commitSelection
        self.lastSequencerResult = lastSequencerResult
    }

    // MARK: - 共享派生属性

    /// 从 statusCache 产出的统一语义快照
    public var semanticSnapshot: GitPanelSemanticSnapshot {
        statusCache.semanticSnapshot
    }

    /// 是否有 stage all 操作正在进行
    public var isStageAllInFlight: Bool {
        opsInFlight.contains { $0.op == "stage" && $0.path == nil }
    }

    /// 提交是否正在进行
    public var isCommitInFlight: Bool {
        commitInFlight
    }

    /// 分支切换是否正在进行
    public var isBranchSwitchInFlight: Bool {
        branchSwitchInFlight != nil
    }

    /// 分支创建是否正在进行
    public var isBranchCreateInFlight: Bool {
        branchCreateInFlight != nil
    }

    /// 是否可以提交（有暂存变更且不在提交中）
    public var canCommit: Bool {
        semanticSnapshot.hasStagedChanges && !commitInFlight
    }

    /// 是否可以切换分支（没有分支切换/创建正在进行）
    public var canSwitchBranch: Bool {
        !isBranchSwitchInFlight && !isBranchCreateInFlight
    }

    /// 是否可以创建分支（没有分支切换/创建正在进行）
    public var canCreateBranch: Bool {
        !isBranchSwitchInFlight && !isBranchCreateInFlight
    }
}

// MARK: - GitWorkspaceStateDriver

/// 跨平台 Git 工作区状态驱动器：纯函数入口，不持有平台可变状态。
/// 每次输入产出 (新状态, 副作用列表)，平台层负责翻译副作用为 WSClient 调用。
public enum GitWorkspaceStateDriver {

    /// 计算输入驱动的状态迁移和副作用。
    /// - Parameters:
    ///   - state: 当前工作区 Git 状态
    ///   - input: 输入事件
    ///   - context: 工作区上下文
    /// - Returns: (新状态, 副作用列表)
    public static func reduce(
        state: GitWorkspaceState,
        input: GitWorkspaceInput,
        context: GitWorkspaceContext
    ) -> (GitWorkspaceState, [GitWorkspaceEffect]) {
        var next = state
        var effects: [GitWorkspaceEffect] = []

        switch input {

        // MARK: - 用户意图

        case .refreshStatus(let cacheMode):
            if next.statusCache.isLoading != true {
                next.statusCache.isLoading = true
                next.statusCache.error = nil
            }
            effects.append(.requestStatus(cacheMode: cacheMode))

        case .refreshBranches(let cacheMode):
            if next.branchCache.isLoading != true {
                next.branchCache.isLoading = true
                next.branchCache.error = nil
            }
            effects.append(.requestBranches(cacheMode: cacheMode))

        case .stage(let path, let scope):
            let opKey = GitOpInFlight(op: "stage", path: path, scope: scope)
            next.opsInFlight.insert(opKey)
            effects.append(.requestStage(path: path, scope: scope))

        case .unstage(let path, let scope):
            let opKey = GitOpInFlight(op: "unstage", path: path, scope: scope)
            next.opsInFlight.insert(opKey)
            effects.append(.requestUnstage(path: path, scope: scope))

        case .discard(let path, let scope, let includeUntracked):
            let opKey = GitOpInFlight(op: "discard", path: path, scope: scope)
            next.opsInFlight.insert(opKey)
            effects.append(.requestDiscard(path: path, scope: scope, includeUntracked: includeUntracked))

        case .commit(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { break }
            next.commitInFlight = true
            next.commitResult = nil
            effects.append(.requestCommit(message: trimmed))

        case .switchBranch(let name):
            guard next.canSwitchBranch else { break }
            next.branchSwitchInFlight = name
            effects.append(.requestSwitchBranch(name: name))

        case .createBranch(let name):
            guard next.canCreateBranch else { break }
            next.branchCreateInFlight = name
            effects.append(.requestCreateBranch(name: name))

        // MARK: - 服务端结果

        case .gitStatusResult(let result):
            next.statusCache = GitStatusCache(
                items: result.items,
                isLoading: false,
                error: result.error,
                isGitRepo: result.isGitRepo,
                updatedAt: Date(),
                hasStagedChanges: result.hasStagedChanges,
                stagedCount: result.stagedCount,
                currentBranch: result.currentBranch,
                defaultBranch: result.defaultBranch,
                aheadBy: result.aheadBy,
                behindBy: result.behindBy,
                comparedBranch: result.comparedBranch
            )
            next.hasResolvedStatus = true

        case .gitBranchesResult(let result):
            next.branchCache = GitBranchCache(
                current: result.current,
                branches: result.branches,
                isLoading: false,
                error: nil,
                updatedAt: Date()
            )

        case .gitOpResult(let result):
            // 清除对应的 in-flight 记录
            let opKey = GitOpInFlight(op: result.op, path: result.path, scope: result.scope)
            next.opsInFlight.remove(opKey)

            if result.op == "switch_branch" {
                next.branchSwitchInFlight = nil
                if result.ok {
                    effects.append(.requestStatus(cacheMode: .default))
                    effects.append(.requestBranches(cacheMode: .default))
                }
                break
            }

            if result.op == "create_branch" {
                next.branchCreateInFlight = nil
                if result.ok {
                    effects.append(.requestStatus(cacheMode: .default))
                    effects.append(.requestBranches(cacheMode: .default))
                }
                break
            }

            // stage / unstage / discard
            if result.ok {
                effects.append(.requestStatus(cacheMode: .default))
            }

        case .gitCommitResult(let result):
            next.commitInFlight = false
            if result.ok {
                next.commitMessage = ""
                next.commitResult = result.message ?? "提交成功"
                effects.append(.requestStatus(cacheMode: .default))
            } else {
                next.commitResult = result.message ?? "提交失败"
            }

        case .gitStatusChanged:
            effects.append(.requestStatus(cacheMode: .default))
            effects.append(.requestBranches(cacheMode: .default))

        // MARK: - v1.60: Sequencer 服务端结果

        case .gitSequencerResult(let result):
            next.lastSequencerResult = result
            // 操作完成后清空选择模式
            next.commitSelection.exitSelectionMode()
            // 刷新 status、op-status
            effects.append(.requestStatus(cacheMode: .default))
            effects.append(.requestOpStatus(cacheMode: .default))

        case .gitWorkspaceOpRollbackResult:
            next.lastSequencerResult = nil
            effects.append(.requestStatus(cacheMode: .default))
            effects.append(.requestOpStatus(cacheMode: .default))

        case .gitOpStatusResult(let result):
            next.opStatusCache = GitOpStatusCache(
                state: result.state,
                conflicts: result.conflicts,
                conflictFiles: result.conflictFiles,
                isLoading: false,
                updatedAt: Date(),
                operationKind: result.operationKind,
                pendingCommits: result.pendingCommits,
                currentCommit: result.currentCommit,
                rollbackReceipt: result.rollbackReceipt
            )

        // MARK: - 环境变化

        case .connectionChanged(let isConnected):
            if !isConnected {
                // 断连时清除所有 in-flight，保留最后已解析快照
                next.opsInFlight.removeAll()
                next.branchSwitchInFlight = nil
                next.branchCreateInFlight = nil
                next.commitInFlight = false
            }
        }

        return (next, effects)
    }
}
