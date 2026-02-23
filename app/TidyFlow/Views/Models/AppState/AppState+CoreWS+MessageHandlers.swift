import Foundation

final class AppStateGitMessageHandlerAdapter: GitMessageHandler {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handleGitDiffResult(_ result: GitDiffResult) { appState?.gitCache.handleGitDiffResult(result) }
    func handleGitStatusResult(_ result: GitStatusResult) { appState?.gitCache.handleGitStatusResult(result) }
    func handleGitLogResult(_ result: GitLogResult) { appState?.gitCache.handleGitLogResult(result) }
    func handleGitShowResult(_ result: GitShowResult) { appState?.gitCache.handleGitShowResult(result) }
    func handleGitOpResult(_ result: GitOpResult) { appState?.gitCache.handleGitOpResult(result) }
    func handleGitBranchesResult(_ result: GitBranchesResult) { appState?.gitCache.handleGitBranchesResult(result) }
    func handleGitCommitResult(_ result: GitCommitResult) { appState?.gitCache.handleGitCommitResult(result) }
    func handleGitRebaseResult(_ result: GitRebaseResult) { appState?.gitCache.handleGitRebaseResult(result) }
    func handleGitOpStatusResult(_ result: GitOpStatusResult) { appState?.gitCache.handleGitOpStatusResult(result) }
    func handleGitMergeToDefaultResult(_ result: GitMergeToDefaultResult) { appState?.gitCache.handleGitMergeToDefaultResult(result) }
    func handleGitIntegrationStatusResult(_ result: GitIntegrationStatusResult) { appState?.gitCache.handleGitIntegrationStatusResult(result) }
    func handleGitRebaseOntoDefaultResult(_ result: GitRebaseOntoDefaultResult) { appState?.gitCache.handleGitRebaseOntoDefaultResult(result) }
    func handleGitResetIntegrationWorktreeResult(_ result: GitResetIntegrationWorktreeResult) { appState?.gitCache.handleGitResetIntegrationWorktreeResult(result) }
    func handleGitStatusChanged(_ notification: GitStatusChangedNotification) {
        appState?.gitCache.fetchGitStatus(workspaceKey: notification.workspace)
        appState?.gitCache.fetchGitBranches(workspaceKey: notification.workspace)
    }
    func handleGitAICommitResult(_ result: GitAICommitResult) { appState?.handleGitAICommitResult(result) }
    func handleGitAIMergeResult(_ result: GitAIMergeResult) { appState?.handleGitAIMergeResult(result) }
}

final class AppStateProjectMessageHandlerAdapter: ProjectMessageHandler {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handleProjectsList(_ result: ProjectsListResult) { appState?.handleProjectsList(result) }
    func handleWorkspacesList(_ result: WorkspacesListResult) { appState?.handleWorkspacesList(result) }
    func handleProjectImported(_ result: ProjectImportedResult) { appState?.handleProjectImported(result) }
    func handleWorkspaceCreated(_ result: WorkspaceCreatedResult) { appState?.handleWorkspaceCreated(result) }
    func handleProjectRemoved(_ result: ProjectRemovedResult) {
        if !result.ok {
            TFLog.app.error("移除项目失败: \(result.message ?? "未知错误", privacy: .public)")
        }
    }
    func handleWorkspaceRemoved(_ result: WorkspaceRemovedResult) { appState?.handleWorkspaceRemoved(result) }
    func handleProjectCommandsSaved(_ project: String, _ ok: Bool, _ message: String?) {
        if !ok {
            TFLog.app.warning("项目命令保存失败: \(message ?? "未知错误", privacy: .public)")
        }
    }
    func handleProjectCommandStarted(_ project: String, _ workspace: String, _ commandId: String, _ taskId: String) {
        appState?.handleProjectCommandStarted(project: project, workspace: workspace, commandId: commandId, taskId: taskId)
    }
    func handleProjectCommandCompleted(_ project: String, _ workspace: String, _ commandId: String, _ taskId: String, _ ok: Bool, _ message: String?) {
        appState?.handleProjectCommandCompleted(
            project: project,
            workspace: workspace,
            commandId: commandId,
            taskId: taskId,
            ok: ok,
            message: message
        )
    }
    func handleProjectCommandOutput(_ taskId: String, _ line: String) {
        appState?.handleProjectCommandOutput(taskId: taskId, line: line)
    }
}

final class AppStateFileMessageHandlerAdapter: FileMessageHandler {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handleFileReadResult(_ result: FileReadResult) { appState?.handleFileReadResult(result) }
    func handleFileIndexResult(_ result: FileIndexResult) { appState?.handleFileIndexResult(result) }
    func handleFileListResult(_ result: FileListResult) { appState?.handleFileListResult(result) }
    func handleFileRenameResult(_ result: FileRenameResult) { appState?.handleFileRenameResult(result) }
    func handleFileDeleteResult(_ result: FileDeleteResult) { appState?.handleFileDeleteResult(result) }
    func handleFileCopyResult(_ result: FileCopyResult) { appState?.handleFileCopyResult(result) }
    func handleFileMoveResult(_ result: FileMoveResult) { appState?.handleFileMoveResult(result) }
    func handleFileWriteResult(_ result: FileWriteResult) { appState?.handleFileWriteResult(result) }
    func handleFileChanged(_ notification: FileChangedNotification) {
        appState?.invalidateFileCache(project: notification.project, workspace: notification.workspace)
        appState?.notifyEditorFileChanged(notification: notification)
    }
}

final class AppStateSettingsMessageHandlerAdapter: SettingsMessageHandler {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handleClientSettingsResult(_ settings: ClientSettings) {
        guard let appState else { return }
        appState.clientSettings = settings
        appState.clientSettingsLoaded = true
        appState.applyEvolutionProfilesFromClientSettings(settings.evolutionAgentProfiles)
        LocalizationManager.shared.appLanguage = settings.appLanguage
    }

    func handleClientSettingsSaved(_ ok: Bool, _ message: String?) {
        if !ok {
            TFLog.app.error("保存设置失败: \(message ?? "未知错误", privacy: .public)")
        }
    }
}

final class AppStateTerminalMessageHandlerAdapter: TerminalMessageHandler {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handleTermList(_ result: TermListResult) {
        appState?.updateRemoteTerminals(from: result.items)
    }

    func handleRemoteTermChanged() {
        appState?.refreshRemoteTerminals()
    }
}

final class AppStateLspMessageHandlerAdapter: LspMessageHandler {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handleLspDiagnostics(_ result: LspDiagnosticsResult) {
        appState?.handleLspDiagnostics(result)
    }

    func handleLspStatus(_ result: LspStatusResult) {
        appState?.handleLspStatus(result)
    }
}

final class AppStateAIMessageHandlerAdapter: AIMessageHandler {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handleAISessionStarted(_ ev: AISessionStartedV2) { appState?.handleAISessionStarted(ev) }
    func handleAISessionList(_ ev: AISessionListV2) { appState?.handleAISessionList(ev) }
    func handleAISessionMessages(_ ev: AISessionMessagesV2) { appState?.handleAISessionMessages(ev) }
    func handleAISessionStatusResult(_ ev: AISessionStatusResultV2) { appState?.handleAISessionStatusResult(ev) }
    func handleAISessionStatusUpdate(_ ev: AISessionStatusUpdateV2) { appState?.handleAISessionStatusUpdate(ev) }
    func handleAIChatMessageUpdated(_ ev: AIChatMessageUpdatedV2) { appState?.handleAIChatMessageUpdated(ev) }
    func handleAIChatPartUpdated(_ ev: AIChatPartUpdatedV2) { appState?.handleAIChatPartUpdated(ev) }
    func handleAIChatPartDelta(_ ev: AIChatPartDeltaV2) { appState?.handleAIChatPartDelta(ev) }
    func handleAIChatDone(_ ev: AIChatDoneV2) { appState?.handleAIChatDone(ev) }
    func handleAIChatError(_ ev: AIChatErrorV2) { appState?.handleAIChatError(ev) }
    func handleAIQuestionAsked(_ ev: AIQuestionAskedV2) { appState?.handleAIQuestionAsked(ev) }
    func handleAIQuestionCleared(_ ev: AIQuestionClearedV2) { appState?.handleAIQuestionCleared(ev) }
    func handleAIProviderList(_ ev: AIProviderListResult) { appState?.handleAIProviderList(ev) }
    func handleAIAgentList(_ ev: AIAgentListResult) { appState?.handleAIAgentList(ev) }
    func handleAISlashCommands(_ ev: AISlashCommandsResult) { appState?.handleAISlashCommands(ev) }
    func handleAISessionSubscribeAck() { appState?.handleAISessionSubscribeAck() }
}

final class AppStateEvolutionMessageHandlerAdapter: EvolutionMessageHandler {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handleEvolutionPulse() { appState?.handleEvolutionPulse() }
    func handleEvolutionSnapshot(_ snapshot: EvolutionSnapshotV2) { appState?.handleEvolutionSnapshot(snapshot) }
    func handleEvolutionStageChatOpened(_ ev: EvolutionStageChatOpenedV2) { appState?.handleEvolutionStageChatOpened(ev) }
    func handleEvolutionAgentProfile(_ ev: EvolutionAgentProfileV2) { appState?.handleEvolutionAgentProfile(ev) }
    func handleEvolutionError(_ message: String) { appState?.handleEvolutionError(message) }
}

final class AppStateErrorMessageHandlerAdapter: ErrorMessageHandler {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handleClientError(_ message: String) {
        appState?.handleClientErrorMessage(message)
    }
}
