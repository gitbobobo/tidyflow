import Foundation
import MessagePacker

// MARK: - 消息路由协议

/// 领域消息处理协议 — 替代 30+ 回调闭包
protocol GitMessageHandler: AnyObject {
    func handleGitDiffResult(_ result: GitDiffResult)
    func handleGitStatusResult(_ result: GitStatusResult)
    func handleGitLogResult(_ result: GitLogResult)
    func handleGitShowResult(_ result: GitShowResult)
    func handleGitOpResult(_ result: GitOpResult)
    func handleGitBranchesResult(_ result: GitBranchesResult)
    func handleGitCommitResult(_ result: GitCommitResult)
    func handleGitRebaseResult(_ result: GitRebaseResult)
    func handleGitOpStatusResult(_ result: GitOpStatusResult)
    func handleGitMergeToDefaultResult(_ result: GitMergeToDefaultResult)
    func handleGitIntegrationStatusResult(_ result: GitIntegrationStatusResult)
    func handleGitRebaseOntoDefaultResult(_ result: GitRebaseOntoDefaultResult)
    func handleGitResetIntegrationWorktreeResult(_ result: GitResetIntegrationWorktreeResult)
    func handleGitStatusChanged(_ notification: GitStatusChangedNotification)
    func handleGitAICommitResult(_ result: GitAICommitResult)
    func handleGitAIMergeResult(_ result: GitAIMergeResult)
}

/// 默认空实现，子类只需 override 关心的方法
extension GitMessageHandler {
    func handleGitDiffResult(_ result: GitDiffResult) {}
    func handleGitStatusResult(_ result: GitStatusResult) {}
    func handleGitLogResult(_ result: GitLogResult) {}
    func handleGitShowResult(_ result: GitShowResult) {}
    func handleGitOpResult(_ result: GitOpResult) {}
    func handleGitBranchesResult(_ result: GitBranchesResult) {}
    func handleGitCommitResult(_ result: GitCommitResult) {}
    func handleGitRebaseResult(_ result: GitRebaseResult) {}
    func handleGitOpStatusResult(_ result: GitOpStatusResult) {}
    func handleGitMergeToDefaultResult(_ result: GitMergeToDefaultResult) {}
    func handleGitIntegrationStatusResult(_ result: GitIntegrationStatusResult) {}
    func handleGitRebaseOntoDefaultResult(_ result: GitRebaseOntoDefaultResult) {}
    func handleGitResetIntegrationWorktreeResult(_ result: GitResetIntegrationWorktreeResult) {}
    func handleGitStatusChanged(_ notification: GitStatusChangedNotification) {}
    func handleGitAICommitResult(_ result: GitAICommitResult) {}
    func handleGitAIMergeResult(_ result: GitAIMergeResult) {}
}

protocol ProjectMessageHandler: AnyObject {
    func handleProjectsList(_ result: ProjectsListResult)
    func handleWorkspacesList(_ result: WorkspacesListResult)
    func handleProjectImported(_ result: ProjectImportedResult)
    func handleWorkspaceCreated(_ result: WorkspaceCreatedResult)
    func handleProjectRemoved(_ result: ProjectRemovedResult)
    func handleWorkspaceRemoved(_ result: WorkspaceRemovedResult)
    func handleProjectCommandsSaved(_ project: String, _ ok: Bool, _ message: String?)
    func handleProjectCommandStarted(_ project: String, _ workspace: String, _ commandId: String, _ taskId: String)
    func handleProjectCommandCompleted(_ project: String, _ workspace: String, _ commandId: String, _ taskId: String, _ ok: Bool, _ message: String?)
    func handleProjectCommandOutput(_ taskId: String, _ line: String)
}

extension ProjectMessageHandler {
    func handleProjectsList(_ result: ProjectsListResult) {}
    func handleWorkspacesList(_ result: WorkspacesListResult) {}
    func handleProjectImported(_ result: ProjectImportedResult) {}
    func handleWorkspaceCreated(_ result: WorkspaceCreatedResult) {}
    func handleProjectRemoved(_ result: ProjectRemovedResult) {}
    func handleWorkspaceRemoved(_ result: WorkspaceRemovedResult) {}
    func handleProjectCommandsSaved(_ project: String, _ ok: Bool, _ message: String?) {}
    func handleProjectCommandStarted(_ project: String, _ workspace: String, _ commandId: String, _ taskId: String) {}
    func handleProjectCommandCompleted(_ project: String, _ workspace: String, _ commandId: String, _ taskId: String, _ ok: Bool, _ message: String?) {}
    func handleProjectCommandOutput(_ taskId: String, _ line: String) {}
}

protocol FileMessageHandler: AnyObject {
    func handleFileReadResult(_ result: FileReadResult)
    func handleFileIndexResult(_ result: FileIndexResult)
    func handleFileListResult(_ result: FileListResult)
    func handleFileRenameResult(_ result: FileRenameResult)
    func handleFileDeleteResult(_ result: FileDeleteResult)
    func handleFileCopyResult(_ result: FileCopyResult)
    func handleFileMoveResult(_ result: FileMoveResult)
    func handleFileWriteResult(_ result: FileWriteResult)
    func handleFileChanged(_ notification: FileChangedNotification)
    func handleWatchSubscribed(_ result: WatchSubscribedResult)
    func handleWatchUnsubscribed()
}

extension FileMessageHandler {
    func handleFileReadResult(_ result: FileReadResult) {}
    func handleFileIndexResult(_ result: FileIndexResult) {}
    func handleFileListResult(_ result: FileListResult) {}
    func handleFileRenameResult(_ result: FileRenameResult) {}
    func handleFileDeleteResult(_ result: FileDeleteResult) {}
    func handleFileCopyResult(_ result: FileCopyResult) {}
    func handleFileMoveResult(_ result: FileMoveResult) {}
    func handleFileWriteResult(_ result: FileWriteResult) {}
    func handleFileChanged(_ notification: FileChangedNotification) {}
    func handleWatchSubscribed(_ result: WatchSubscribedResult) {}
    func handleWatchUnsubscribed() {}
}

protocol SettingsMessageHandler: AnyObject {
    func handleClientSettingsResult(_ settings: ClientSettings)
    func handleClientSettingsSaved(_ ok: Bool, _ message: String?)
}

extension SettingsMessageHandler {
    func handleClientSettingsResult(_ settings: ClientSettings) {}
    func handleClientSettingsSaved(_ ok: Bool, _ message: String?) {}
}

protocol TerminalMessageHandler: AnyObject {
    func handleTerminalOutput(_ termId: String?, _ bytes: [UInt8])
    func handleTerminalExit(_ termId: String?, _ code: Int)
    func handleTermCreated(_ result: TermCreatedResult)
    func handleTermAttached(_ result: TermAttachedResult)
    func handleTermList(_ result: TermListResult)
    func handleTermClosed(_ termId: String)
    func handleRemoteTermChanged()
}

extension TerminalMessageHandler {
    func handleTerminalOutput(_ termId: String?, _ bytes: [UInt8]) {}
    func handleTerminalExit(_ termId: String?, _ code: Int) {}
    func handleTermCreated(_ result: TermCreatedResult) {}
    func handleTermAttached(_ result: TermAttachedResult) {}
    func handleTermList(_ result: TermListResult) {}
    func handleTermClosed(_ termId: String) {}
    func handleRemoteTermChanged() {}
}

protocol AIMessageHandler: AnyObject {
    func handleAITaskCancelled(_ result: AITaskCancelled)
    func handleAISessionStarted(_ ev: AISessionStartedV2)
    func handleAISessionList(_ ev: AISessionListV2)
    func handleAISessionMessages(_ ev: AISessionMessagesV2)
    func handleAISessionStatusResult(_ ev: AISessionStatusResultV2)
    func handleAISessionStatusUpdate(_ ev: AISessionStatusUpdateV2)
    func handleAIChatMessageUpdated(_ ev: AIChatMessageUpdatedV2)
    func handleAIChatPartUpdated(_ ev: AIChatPartUpdatedV2)
    func handleAIChatPartDelta(_ ev: AIChatPartDeltaV2)
    func handleAIChatDone(_ ev: AIChatDoneV2)
    func handleAIChatPending(_ ev: AIChatPendingV2)
    func handleAIChatError(_ ev: AIChatErrorV2)
    func handleAIQuestionAsked(_ ev: AIQuestionAskedV2)
    func handleAIQuestionCleared(_ ev: AIQuestionClearedV2)
    func handleAIProviderList(_ ev: AIProviderListResult)
    func handleAIAgentList(_ ev: AIAgentListResult)
    func handleAISlashCommands(_ ev: AISlashCommandsResult)
    func handleAISlashCommandsUpdate(_ ev: AISlashCommandsUpdateResult)
    func handleAISessionConfigOptions(_ ev: AISessionConfigOptionsResult)
    func handleAISessionSubscribeAck()
}

extension AIMessageHandler {
    func handleAITaskCancelled(_ result: AITaskCancelled) {}
    func handleAISessionStarted(_ ev: AISessionStartedV2) {}
    func handleAISessionList(_ ev: AISessionListV2) {}
    func handleAISessionMessages(_ ev: AISessionMessagesV2) {}
    func handleAISessionStatusResult(_ ev: AISessionStatusResultV2) {}
    func handleAISessionStatusUpdate(_ ev: AISessionStatusUpdateV2) {}
    func handleAIChatMessageUpdated(_ ev: AIChatMessageUpdatedV2) {}
    func handleAIChatPartUpdated(_ ev: AIChatPartUpdatedV2) {}
    func handleAIChatPartDelta(_ ev: AIChatPartDeltaV2) {}
    func handleAIChatDone(_ ev: AIChatDoneV2) {}
    func handleAIChatPending(_ ev: AIChatPendingV2) {}
    func handleAIChatError(_ ev: AIChatErrorV2) {}
    func handleAIQuestionAsked(_ ev: AIQuestionAskedV2) {}
    func handleAIQuestionCleared(_ ev: AIQuestionClearedV2) {}
    func handleAIProviderList(_ ev: AIProviderListResult) {}
    func handleAIAgentList(_ ev: AIAgentListResult) {}
    func handleAISlashCommands(_ ev: AISlashCommandsResult) {}
    func handleAISlashCommandsUpdate(_ ev: AISlashCommandsUpdateResult) {}
    func handleAISessionConfigOptions(_ ev: AISessionConfigOptionsResult) {}
    func handleAISessionSubscribeAck() {}
}

protocol EvolutionMessageHandler: AnyObject {
    func handleEvolutionPulse()
    func handleEvolutionSnapshot(_ snapshot: EvolutionSnapshotV2)
    func handleEvolutionStageChatOpened(_ ev: EvolutionStageChatOpenedV2)
    func handleEvolutionAgentProfile(_ ev: EvolutionAgentProfileV2)
    func handleEvolutionBlockingRequired(_ ev: EvolutionBlockingRequiredV2)
    func handleEvolutionBlockersUpdated(_ ev: EvolutionBlockersUpdatedV2)
    func handleEvolutionCycleHistory(project: String, workspace: String, cycles: [EvolutionCycleHistoryItemV2])
    func handleEvolutionError(_ message: String, project: String?, workspace: String?)
}

extension EvolutionMessageHandler {
    func handleEvolutionPulse() {}
    func handleEvolutionSnapshot(_ snapshot: EvolutionSnapshotV2) {}
    func handleEvolutionStageChatOpened(_ ev: EvolutionStageChatOpenedV2) {}
    func handleEvolutionAgentProfile(_ ev: EvolutionAgentProfileV2) {}
    func handleEvolutionBlockingRequired(_ ev: EvolutionBlockingRequiredV2) {}
    func handleEvolutionBlockersUpdated(_ ev: EvolutionBlockersUpdatedV2) {}
    func handleEvolutionCycleHistory(project: String, workspace: String, cycles: [EvolutionCycleHistoryItemV2]) {}
    func handleEvolutionError(_ message: String, project: String?, workspace: String?) {}
}

protocol EvidenceMessageHandler: AnyObject {
    func handleEvidenceSnapshot(_ snapshot: EvidenceSnapshotV2)
    func handleEvidenceRebuildPrompt(_ prompt: EvidenceRebuildPromptV2)
    func handleEvidenceItemChunk(_ chunk: EvidenceItemChunkV2)
}

extension EvidenceMessageHandler {
    func handleEvidenceSnapshot(_ snapshot: EvidenceSnapshotV2) {}
    func handleEvidenceRebuildPrompt(_ prompt: EvidenceRebuildPromptV2) {}
    func handleEvidenceItemChunk(_ chunk: EvidenceItemChunkV2) {}
}

protocol ErrorMessageHandler: AnyObject {
    func handleClientError(_ message: String)
}

extension ErrorMessageHandler {
    func handleClientError(_ message: String) {}
}

// MARK: - 类型安全的请求构建器

/// Git 领域请求
enum GitRequest {
    /// 构建 git_status 请求
    static func status(project: String, workspace: String) -> [String: Any] {
        ["type": "git_status", "project": project, "workspace": workspace]
    }

    /// 构建 git_diff 请求
    static func diff(project: String, workspace: String, path: String, mode: String) -> [String: Any] {
        ["type": "git_diff", "project": project, "workspace": workspace, "path": path, "mode": mode]
    }

    /// 构建 git_stage 请求
    static func stage(project: String, workspace: String, path: String?, scope: String) -> [String: Any] {
        var msg: [String: Any] = ["type": "git_stage", "project": project, "workspace": workspace, "scope": scope]
        if let path = path { msg["path"] = path }
        return msg
    }

    /// 构建 git_unstage 请求
    static func unstage(project: String, workspace: String, path: String?, scope: String) -> [String: Any] {
        var msg: [String: Any] = ["type": "git_unstage", "project": project, "workspace": workspace, "scope": scope]
        if let path = path { msg["path"] = path }
        return msg
    }

    /// 构建 git_discard 请求
    static func discard(project: String, workspace: String, path: String?, scope: String, includeUntracked: Bool = false) -> [String: Any] {
        var msg: [String: Any] = ["type": "git_discard", "project": project, "workspace": workspace, "scope": scope]
        if let path = path { msg["path"] = path }
        if includeUntracked { msg["include_untracked"] = true }
        return msg
    }

    /// 构建 git_commit 请求
    static func commit(project: String, workspace: String, message: String) -> [String: Any] {
        ["type": "git_commit", "project": project, "workspace": workspace, "message": message]
    }

    /// 构建 git_branches 请求
    static func branches(project: String, workspace: String) -> [String: Any] {
        ["type": "git_branches", "project": project, "workspace": workspace]
    }

    /// 构建 git_switch_branch 请求
    static func switchBranch(project: String, workspace: String, branch: String) -> [String: Any] {
        ["type": "git_switch_branch", "project": project, "workspace": workspace, "branch": branch]
    }

    /// 构建 git_create_branch 请求
    static func createBranch(project: String, workspace: String, branch: String) -> [String: Any] {
        ["type": "git_create_branch", "project": project, "workspace": workspace, "branch": branch]
    }
}

/// 项目领域请求
enum ProjectRequest {
    static func listProjects() -> [String: Any] {
        ["type": "list_projects"]
    }

    static func listWorkspaces(project: String) -> [String: Any] {
        ["type": "list_workspaces", "project": project]
    }

    static func importProject(name: String, path: String) -> [String: Any] {
        ["type": "import_project", "name": name, "path": path]
    }
}
