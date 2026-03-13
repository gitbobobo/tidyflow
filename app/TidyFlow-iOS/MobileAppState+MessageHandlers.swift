import Foundation
import TidyFlowShared

// MARK: - iOS 端领域消息处理适配器
// 与 macOS AppState+CoreWS+MessageHandlers.swift 对称，
// 将 WSClient handler 协议方法转发到 MobileAppState 实例方法。
// WSClient 在解码队列回调协议方法，此处统一切回主线程，避免 UI 状态跨线程写入。

final class MobileAppStateGitMessageHandlerAdapter: GitMessageHandler {
    weak var appState: MobileAppState?

    init(appState: MobileAppState) {
        self.appState = appState
    }

    private func dispatchToMain(_ action: @escaping @MainActor (MobileAppState) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let appState = self?.appState else { return }
            MainActor.assumeIsolated { action(appState) }
        }
    }

    func handleGitStatusResult(_ result: GitStatusResult) { dispatchToMain { $0.handleGitStatusResult(result) } }
    func handleGitBranchesResult(_ result: GitBranchesResult) { dispatchToMain { $0.handleGitBranchesResult(result) } }
    func handleGitCommitResult(_ result: GitCommitResult) { dispatchToMain { $0.handleGitCommitResult(result) } }
    func handleGitAIMergeResult(_ result: GitAIMergeResult) { dispatchToMain { $0.handleGitAIMergeResult(result) } }
    func handleGitMergeToDefaultResult(_ result: GitMergeToDefaultResult) { dispatchToMain { $0.handleGitMergeToDefaultResult(result) } }
    func handleGitStatusChanged(_ notification: GitStatusChangedNotification) { dispatchToMain { $0.handleGitStatusChanged(notification) } }
    // v1.40: 冲突向导
    func handleGitConflictDetailResult(_ result: GitConflictDetailResult) { dispatchToMain { $0.handleGitConflictDetailResult(result) } }
    func handleGitConflictActionResult(_ result: GitConflictActionResult) { dispatchToMain { $0.handleGitConflictActionResult(result) } }
    /// iOS Diff 数据闭环：显式转发 handleGitDiffResult，由 MobileAppState 解析并回填 iOS Diff 缓存。
    func handleGitDiffResult(_ result: GitDiffResult) { dispatchToMain { $0.handleGitDiffResult(result) } }
}

final class MobileAppStateProjectMessageHandlerAdapter: ProjectMessageHandler {
    weak var appState: MobileAppState?

    init(appState: MobileAppState) {
        self.appState = appState
    }

    private func dispatchToMain(_ action: @escaping @MainActor (MobileAppState) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let appState = self?.appState else { return }
            MainActor.assumeIsolated { action(appState) }
        }
    }

    func handleProjectsList(_ result: ProjectsListResult) { dispatchToMain { $0.handleProjectsList(result) } }
    func handleWorkspacesList(_ result: WorkspacesListResult) { dispatchToMain { $0.handleWorkspacesList(result) } }
    func handleProjectCommandStarted(_ project: String, _ workspace: String, _ commandId: String, _ taskId: String) {
        dispatchToMain { $0.handleProjectCommandStarted(project: project, workspace: workspace, commandId: commandId, taskId: taskId) }
    }
    func handleProjectCommandCompleted(_ project: String, _ workspace: String, _ commandId: String, _ taskId: String, _ ok: Bool, _ message: String?) {
        dispatchToMain { $0.handleProjectCommandCompleted(project: project, workspace: workspace, commandId: commandId, taskId: taskId, ok: ok, message: message) }
    }
    func handleProjectCommandOutput(_ taskId: String, _ line: String) {
        dispatchToMain { $0.handleProjectCommandOutput(taskId: taskId, line: line) }
    }
    func handleTemplatesList(_ result: TemplatesListResult) { dispatchToMain { $0.handleTemplatesList(result) } }
    func handleTemplateSaved(_ result: TemplateSavedResult) { dispatchToMain { $0.handleTemplateSaved(result) } }
    func handleTemplateDeleted(_ result: TemplateDeletedResult) { dispatchToMain { $0.handleTemplateDeleted(result) } }
    func handleTemplateImported(_ result: TemplateImportedResult) { dispatchToMain { $0.handleTemplateImported(result) } }
}

final class MobileAppStateFileMessageHandlerAdapter: FileMessageHandler {
    weak var appState: MobileAppState?

    init(appState: MobileAppState) {
        self.appState = appState
    }

    private func dispatchToMain(_ action: @escaping @MainActor (MobileAppState) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let appState = self?.appState else { return }
            MainActor.assumeIsolated { action(appState) }
        }
    }

    func handleFileReadResult(_ result: FileReadResult) { dispatchToMain { $0.handleFileReadResult(result) } }
    func handleFileIndexResult(_ result: FileIndexResult) { dispatchToMain { $0.handleFileIndexResult(result) } }
    func handleFileListResult(_ result: FileListResult) { dispatchToMain { $0.handleFileListResult(result) } }
    func handleFileRenameResult(_ result: FileRenameResult) { dispatchToMain { $0.handleFileRenameResult(result) } }
    func handleFileDeleteResult(_ result: FileDeleteResult) { dispatchToMain { $0.handleFileDeleteResult(result) } }
    func handleFileWriteResult(_ result: FileWriteResult) { dispatchToMain { $0.handleFileWriteResult(result) } }
    func handleWatchSubscribed(_ result: WatchSubscribedResult) {
        dispatchToMain { state in
            let key = state.globalWorkspaceKey(project: result.project, workspace: result.workspace)
            state.setFileWorkspacePhase(.watching, for: key)
        }
    }
    func handleWatchUnsubscribed() {
        dispatchToMain { state in
            guard let identity = state.selectedWorkspaceIdentity else { return }
            let key = state.globalWorkspaceKey(
                project: identity.projectName,
                workspace: identity.workspaceName
            )
            state.setFileWorkspacePhase(.idle, for: key)
        }
    }
}

final class MobileAppStateTerminalMessageHandlerAdapter: TerminalMessageHandler {
    weak var appState: MobileAppState?

    init(appState: MobileAppState) {
        self.appState = appState
    }

    private func dispatchToMain(_ action: @escaping @MainActor (MobileAppState) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let appState = self?.appState else { return }
            MainActor.assumeIsolated { action(appState) }
        }
    }

    func handleTerminalOutput(_ termId: String?, _ bytes: [UInt8]) {
        dispatchToMain { $0.handleTerminalOutput(termId: termId, bytes: bytes) }
    }
    func handleTerminalExit(_ termId: String?, _ code: Int) {
        dispatchToMain { $0.handleTerminalExit(termId: termId, code: code) }
    }
    func handleTermCreated(_ result: TermCreatedResult) { dispatchToMain { $0.handleTermCreated(result) } }
    func handleTermAttached(_ result: TermAttachedResult) { dispatchToMain { $0.handleTermAttached(result) } }
    func handleTermList(_ result: TermListResult) { dispatchToMain { $0.handleTermList(result) } }
    func handleTermClosed(_ termId: String) { dispatchToMain { $0.handleTermClosed(termId) } }
}

final class MobileAppStateEvolutionMessageHandlerAdapter: EvolutionMessageHandler {
    weak var appState: MobileAppState?

    init(appState: MobileAppState) {
        self.appState = appState
    }

    private func dispatchToMain(_ action: @escaping @MainActor (MobileAppState) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let appState = self?.appState else { return }
            MainActor.assumeIsolated { action(appState) }
        }
    }

    func handleEvolutionPulse() { dispatchToMain { $0.handleEvolutionPulse() } }
    func handleEvolutionWorkspaceStatusEvent(_ ev: EvolutionWorkspaceStatusEventV2) {
        dispatchToMain { $0.handleEvolutionWorkspaceStatusEvent(ev) }
    }
    func handleEvolutionSnapshot(_ snapshot: EvolutionSnapshotV2) { dispatchToMain { $0.handleEvolutionSnapshot(snapshot) } }
    func handleEvolutionCycleUpdated(_ ev: EvoCycleUpdatedV2) { dispatchToMain { $0.handleEvolutionCycleUpdated(ev) } }
    func handleEvolutionAgentProfile(_ ev: EvolutionAgentProfileV2) { dispatchToMain { $0.handleEvolutionAgentProfile(ev) } }
    func handleEvolutionBlockingRequired(_ ev: EvolutionBlockingRequiredV2) { dispatchToMain { $0.handleEvolutionBlockingRequired(ev) } }
    func handleEvolutionBlockersUpdated(_ ev: EvolutionBlockersUpdatedV2) { dispatchToMain { $0.handleEvolutionBlockersUpdated(ev) } }
    func handleEvolutionCycleHistory(project: String, workspace: String, cycles: [EvolutionCycleHistoryItemV2]) {
        dispatchToMain { $0.handleEvolutionCycleHistory(project: project, workspace: workspace, cycles: cycles) }
    }
    func handleEvolutionAutoCommitResult(_ result: EvoAutoCommitResult) { dispatchToMain { $0.handleEvolutionAutoCommitResult(result) } }
    func handleEvolutionError(_ error: CoreError) { dispatchToMain { $0.handleEvolutionError(error) } }
}

final class MobileAppStateEvidenceMessageHandlerAdapter: EvidenceMessageHandler {
    weak var appState: MobileAppState?

    init(appState: MobileAppState) {
        self.appState = appState
    }

    private func dispatchToMain(_ action: @escaping @MainActor (MobileAppState) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let appState = self?.appState else { return }
            MainActor.assumeIsolated { action(appState) }
        }
    }

    func handleEvidenceSnapshot(_ snapshot: EvidenceSnapshotV2) { dispatchToMain { $0.handleEvidenceSnapshot(snapshot) } }
    func handleEvidenceRebuildPrompt(_ prompt: EvidenceRebuildPromptV2) { dispatchToMain { $0.handleEvidenceRebuildPrompt(prompt) } }
    func handleEvidenceItemChunk(_ chunk: EvidenceItemChunkV2) { dispatchToMain { $0.handleEvidenceItemChunk(chunk) } }
}

final class MobileAppStateErrorMessageHandlerAdapter: ErrorMessageHandler {
    weak var appState: MobileAppState?

    init(appState: MobileAppState) {
        self.appState = appState
    }

    private func dispatchToMain(_ action: @escaping @MainActor (MobileAppState) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let appState = self?.appState else { return }
            MainActor.assumeIsolated { action(appState) }
        }
    }

    func handleClientError(_ message: String) { dispatchToMain { $0.handleClientError(message) } }
    func handleCoreError(_ error: CoreError) { dispatchToMain { $0.handleCoreError(error) } }
}
