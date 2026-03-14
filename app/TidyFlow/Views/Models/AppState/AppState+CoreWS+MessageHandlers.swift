import Foundation
import TidyFlowShared

private func reconcileDiscoveryPairingState(
    items: [NodeDiscoveryItemV2],
    peers: [NodePeerInfoV2]
) -> [NodeDiscoveryItemV2] {
    let pairedNodeIDs = Set(peers.map(\.peerNodeID))
    return items.map { item in
        NodeDiscoveryItemV2(
            nodeID: item.nodeID,
            nodeName: item.nodeName,
            host: item.host,
            port: item.port,
            protocolVersion: item.protocolVersion,
            lastSeenAtUnix: item.lastSeenAtUnix,
            paired: pairedNodeIDs.contains(item.nodeID)
        )
    }
}

// MARK: - macOS 领域消息处理适配器
// 各领域 adapter 继承共享骨架 WeakTargetMessageAdapter<AppState>，
// 统一弱引用持有与主线程调度，仅保留领域差异与状态写入映射。
// Settings 领域保持独立，不使用共享骨架。

final class AppStateGitMessageHandlerAdapter: WeakTargetMessageAdapter<AppState>, GitMessageHandler {
    func handleGitDiffResult(_ result: GitDiffResult) { dispatchToTarget { $0.gitCache.handleGitDiffResult(result) } }
    func handleGitStatusResult(_ result: GitStatusResult) { dispatchToTarget { $0.gitCache.handleGitStatusResult(result) } }
    func handleGitLogResult(_ result: GitLogResult) { dispatchToTarget { $0.gitCache.handleGitLogResult(result) } }
    func handleGitShowResult(_ result: GitShowResult) { dispatchToTarget { $0.gitCache.handleGitShowResult(result) } }
    func handleGitOpResult(_ result: GitOpResult) { dispatchToTarget { $0.gitCache.handleGitOpResult(result) } }
    func handleGitBranchesResult(_ result: GitBranchesResult) { dispatchToTarget { $0.gitCache.handleGitBranchesResult(result) } }
    func handleGitCommitResult(_ result: GitCommitResult) { dispatchToTarget { $0.gitCache.handleGitCommitResult(result) } }
    func handleGitRebaseResult(_ result: GitRebaseResult) { dispatchToTarget { $0.gitCache.handleGitRebaseResult(result) } }
    func handleGitOpStatusResult(_ result: GitOpStatusResult) { dispatchToTarget { $0.gitCache.handleGitOpStatusResult(result) } }
    func handleGitMergeToDefaultResult(_ result: GitMergeToDefaultResult) { dispatchToTarget { $0.gitCache.handleGitMergeToDefaultResult(result) } }
    func handleGitIntegrationStatusResult(_ result: GitIntegrationStatusResult) { dispatchToTarget { $0.gitCache.handleGitIntegrationStatusResult(result) } }
    func handleGitRebaseOntoDefaultResult(_ result: GitRebaseOntoDefaultResult) { dispatchToTarget { $0.gitCache.handleGitRebaseOntoDefaultResult(result) } }
    func handleGitResetIntegrationWorktreeResult(_ result: GitResetIntegrationWorktreeResult) { dispatchToTarget { $0.gitCache.handleGitResetIntegrationWorktreeResult(result) } }
    func handleGitStatusChanged(_ notification: GitStatusChangedNotification) {
        dispatchToTarget { $0.gitCache.applyGitInput(.gitStatusChanged, project: notification.project, workspace: notification.workspace) }
    }
    func handleGitAIMergeResult(_ result: GitAIMergeResult) { dispatchToTarget { $0.handleGitAIMergeResult(result) } }
    // v1.40: 冲突向导
    func handleGitConflictDetailResult(_ result: GitConflictDetailResult) { dispatchToTarget { $0.gitCache.handleGitConflictDetailResult(result) } }
    func handleGitConflictActionResult(_ result: GitConflictActionResult) { dispatchToTarget { $0.gitCache.handleGitConflictActionResult(result) } }
}

final class AppStateProjectMessageHandlerAdapter: WeakTargetMessageAdapter<AppState>, ProjectMessageHandler {
    func handleProjectsList(_ result: ProjectsListResult) { dispatchToTarget { $0.handleProjectsList(result) } }
    func handleWorkspacesList(_ result: WorkspacesListResult) { dispatchToTarget { $0.handleWorkspacesList(result) } }
    func handleProjectImported(_ result: ProjectImportedResult) { dispatchToTarget { $0.handleProjectImported(result) } }
    func handleWorkspaceCreated(_ result: WorkspaceCreatedResult) { dispatchToTarget { $0.handleWorkspaceCreated(result) } }
    func handleProjectRemoved(_ result: ProjectRemovedResult) { dispatchToTarget { $0.handleProjectRemoved(result) } }
    func handleWorkspaceRemoved(_ result: WorkspaceRemovedResult) { dispatchToTarget { $0.handleWorkspaceRemoved(result) } }
    func handleProjectCommandsSaved(_ project: String, _ ok: Bool, _ message: String?) {
        if !ok {
            TFLog.app.warning("项目命令保存失败: \(message ?? "未知错误", privacy: .public)")
        }
    }
    func handleProjectCommandStarted(_ project: String, _ workspace: String, _ commandId: String, _ taskId: String) {
        dispatchToTarget { $0.handleProjectCommandStarted(project: project, workspace: workspace, commandId: commandId, taskId: taskId) }
    }
    func handleProjectCommandCompleted(_ project: String, _ workspace: String, _ commandId: String, _ taskId: String, _ ok: Bool, _ message: String?) {
        dispatchToTarget {
            $0.handleProjectCommandCompleted(
                project: project,
                workspace: workspace,
                commandId: commandId,
                taskId: taskId,
                ok: ok,
                message: message
            )
        }
    }
    func handleProjectCommandCancelled(_ project: String, _ workspace: String, _ commandId: String, _ taskId: String) {
        dispatchToTarget {
            $0.handleProjectCommandCancelled(
                project: project,
                workspace: workspace,
                commandId: commandId,
                taskId: taskId
            )
        }
    }
    func handleProjectCommandOutput(_ taskId: String, _ line: String) {
        dispatchToTarget { $0.handleProjectCommandOutput(taskId: taskId, line: line) }
    }
    // v1.40: 工作流模板管理
    func handleTemplatesList(_ result: TemplatesListResult) { dispatchToTarget { $0.handleTemplatesList(result) } }
    func handleTemplateSaved(_ result: TemplateSavedResult) { dispatchToTarget { $0.handleTemplateSaved(result) } }
    func handleTemplateDeleted(_ result: TemplateDeletedResult) { dispatchToTarget { $0.handleTemplateDeleted(result) } }
    func handleTemplateImported(_ result: TemplateImportedResult) { dispatchToTarget { $0.handleTemplateImported(result) } }
    func handleTemplateExported(_ result: TemplateExportedResult) { dispatchToTarget { $0.handleTemplateExported(result) } }
}

final class AppStateFileMessageHandlerAdapter: WeakTargetMessageAdapter<AppState>, FileMessageHandler {
    func handleFileReadResult(_ result: FileReadResult) { dispatchToTarget { $0.handleFileReadResult(result) } }
    func handleFileIndexResult(_ result: FileIndexResult) { dispatchToTarget { $0.handleFileIndexResult(result) } }
    func handleFileListResult(_ result: FileListResult) { dispatchToTarget { $0.handleFileListResult(result) } }
    func handleFileRenameResult(_ result: FileRenameResult) { dispatchToTarget { $0.handleFileRenameResult(result) } }
    func handleFileDeleteResult(_ result: FileDeleteResult) { dispatchToTarget { $0.handleFileDeleteResult(result) } }
    func handleFileCopyResult(_ result: FileCopyResult) { dispatchToTarget { $0.handleFileCopyResult(result) } }
    func handleFileMoveResult(_ result: FileMoveResult) { dispatchToTarget { $0.handleFileMoveResult(result) } }
    func handleFileWriteResult(_ result: FileWriteResult) { dispatchToTarget { $0.handleFileWriteResult(result) } }
    func handleFileChanged(_ notification: FileChangedNotification) {
        dispatchToTarget { appState in
            appState.invalidateFileCache(project: notification.project, workspace: notification.workspace)
            appState.notifyEditorFileChanged(notification: notification)
        }
    }
    func handleWatchSubscribed(_ result: WatchSubscribedResult) {
        dispatchToTarget { appState in
            let globalKey = appState.globalWorkspaceKey(projectName: result.project, workspaceName: result.workspace)
            appState.fileCache.onWatchSubscribed(globalKey: globalKey)
        }
    }
    func handleWatchUnsubscribed() {
        dispatchToTarget { appState in
            if let key = appState.currentGlobalWorkspaceKey {
                appState.fileCache.onWatchUnsubscribed(globalKey: key)
            }
        }
    }
}

/// Settings 领域保持独立，不使用共享骨架（不纳入本轮共享抽象）。
final class AppStateSettingsMessageHandlerAdapter: SettingsMessageHandler {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handleClientSettingsResult(_ settings: ClientSettings) {
        guard let appState else { return }
        appState.clientSettings = settings
        appState.recordServerNodeProfile(
            nodeName: settings.nodeName,
            discoveryEnabled: settings.nodeDiscoveryEnabled
        )
        appState.applyEvolutionDefaultProfilesFromCore(settings.evolutionDefaultProfiles)
        if appState.clientSettings.keybindings.isEmpty {
            appState.clientSettings.keybindings = KeybindingConfig.defaultKeybindings()
        }
        appState.clientSettingsLoaded = true
        appState.applyEvolutionProfilesFromClientSettings(settings.evolutionAgentProfiles)
    }

    func handleClientSettingsSaved(_ ok: Bool, _ message: String?) {
        if !ok {
            TFLog.app.error("保存设置失败: \(message ?? "未知错误", privacy: .public)")
        }
    }
}

final class AppStateNodeMessageHandlerAdapter: WeakTargetMessageAdapter<AppState>, NodeMessageHandler {
    func handleNodeSelfUpdated(_ identity: NodeSelfInfoV2) {
        dispatchToTarget { appState in
            appState.nodeSelfInfo = identity
            appState.recordServerNodeProfile(
                nodeName: identity.nodeName,
                discoveryEnabled: identity.discoveryEnabled
            )
        }
    }

    func handleNodeDiscoveryUpdated(_ items: [NodeDiscoveryItemV2]) {
        dispatchToTarget { appState in
            appState.nodeDiscoveryItems = reconcileDiscoveryPairingState(
                items: items,
                peers: appState.nodeNetworkPeers
            )
        }
    }

    func handleNodeNetworkUpdated(_ snapshot: NodeNetworkSnapshotV2) {
        dispatchToTarget { appState in
            if appState.nodePairingInFlight == true {
                TFLog.app.info(
                    "配对期间收到节点网络更新: peers=\(snapshot.peers.count, privacy: .public), self=\(snapshot.identity.nodeID, privacy: .public)"
                )
            }
            appState.nodeSelfInfo = snapshot.identity
            appState.nodeNetworkPeers = snapshot.peers
            appState.nodeActiveLocks = snapshot.activeLocks
            appState.nodeDiscoveryItems = reconcileDiscoveryPairingState(
                items: appState.nodeDiscoveryItems,
                peers: snapshot.peers
            )
            appState.recordServerNodeProfile(
                nodeName: snapshot.identity.nodeName,
                discoveryEnabled: snapshot.identity.discoveryEnabled
            )
        }
    }

    func handleNodePairingResult(_ result: NodePairingResultV2) {
        dispatchToTarget { appState in
            if result.ok {
                TFLog.app.info(
                    "收到节点配对结果: ok=true, peer=\(result.peer?.peerNodeID ?? "nil", privacy: .public)"
                )
            } else {
                TFLog.app.warning(
                    "收到节点配对结果: ok=false, message=\(result.message ?? "未知错误", privacy: .public)"
                )
            }
            appState.nodeLastPairingResult = result
            appState.nodePairingInFlight = false
            if result.ok {
                appState.wsClient.requestNodeNetwork(cacheMode: .forceRefresh)
                appState.wsClient.requestNodeDiscovery(cacheMode: .forceRefresh)
            }
        }
    }

    func handleNodePeerStatus(peerNodeID: String, status: String, lastSeenAtUnix: UInt64?) {
        dispatchToTarget { appState in
            appState.nodeNetworkPeers = appState.nodeNetworkPeers.map { peer in
                guard peer.peerNodeID == peerNodeID else { return peer }
                return NodePeerInfoV2(
                    peerNodeID: peer.peerNodeID,
                    peerName: peer.peerName,
                    addresses: peer.addresses,
                    port: peer.port,
                    trustSource: peer.trustSource,
                    introducedBy: peer.introducedBy,
                    lastSeenAtUnix: lastSeenAtUnix ?? peer.lastSeenAtUnix,
                    status: status,
                    authToken: peer.authToken
                )
            }
        }
    }
}

final class AppStateTerminalMessageHandlerAdapter: WeakTargetMessageAdapter<AppState>, TerminalMessageHandler {
    func handleTerminalOutput(_ termId: String?, _ bytes: [UInt8]) {
        dispatchToTarget { $0.handleTerminalOutput(termId: termId, bytes: bytes) }
    }

    func handleTerminalExit(_ termId: String?, _ code: Int) {
        dispatchToTarget { $0.handleTerminalExit(termId: termId, code: code) }
    }

    func handleTermCreated(_ result: TermCreatedResult) {
        dispatchToTarget { $0.handleTermCreated(result) }
    }

    func handleTermAttached(_ result: TermAttachedResult) {
        dispatchToTarget { $0.handleTermAttached(result) }
    }

    func handleTermList(_ result: TermListResult) {
        dispatchToTarget { $0.updateRemoteTerminals(from: result.items) }
    }

    func handleTermClosed(_ termId: String) {
        dispatchToTarget { $0.handleTermClosed(termId) }
    }

    func handleRemoteTermChanged() {
        dispatchToTarget { $0.refreshRemoteTerminals() }
    }
}

final class AppStateAIMessageHandlerAdapter: WeakTargetMessageAdapter<AppState>, AIMessageHandler {
    func handleAITaskCancelled(_ result: AITaskCancelled) { dispatchToTarget { $0.handleAITaskCancelled(result) } }
    func handleAISessionStarted(_ ev: AISessionStartedV2) { dispatchToTarget { $0.handleAISessionStarted(ev) } }
    func handleAISessionList(_ ev: AISessionListV2) { dispatchToTarget { $0.handleAISessionList(ev) } }
    func handleAISessionMessages(_ ev: AISessionMessagesV2) { dispatchToTarget { $0.handleAISessionMessages(ev) } }
    func handleAISessionMessagesUpdate(_ ev: AISessionMessagesUpdateV2) { dispatchToTarget { $0.handleAISessionMessagesUpdate(ev) } }
    func handleAISessionStatusResult(_ ev: AISessionStatusResultV2) { dispatchToTarget { $0.handleAISessionStatusResult(ev) } }
    func handleAISessionStatusUpdate(_ ev: AISessionStatusUpdateV2) { dispatchToTarget { $0.handleAISessionStatusUpdate(ev) } }
    func handleAIChatDone(_ ev: AIChatDoneV2) { dispatchToTarget { $0.handleAIChatDone(ev) } }
    func handleAIChatPending(_ ev: AIChatPendingV2) { dispatchToTarget { $0.handleAIChatPending(ev) } }
    func handleAIChatError(_ ev: AIChatErrorV2) { dispatchToTarget { $0.handleAIChatError(ev) } }
    func handleAIQuestionAsked(_ ev: AIQuestionAskedV2) { dispatchToTarget { $0.handleAIQuestionAsked(ev) } }
    func handleAIQuestionCleared(_ ev: AIQuestionClearedV2) { dispatchToTarget { $0.handleAIQuestionCleared(ev) } }
    func handleAIProviderList(_ ev: AIProviderListResult) { dispatchToTarget { $0.handleAIProviderList(ev) } }
    func handleAIAgentList(_ ev: AIAgentListResult) { dispatchToTarget { $0.handleAIAgentList(ev) } }
    func handleAISlashCommands(_ ev: AISlashCommandsResult) { dispatchToTarget { $0.handleAISlashCommands(ev) } }
    func handleAISlashCommandsUpdate(_ ev: AISlashCommandsUpdateResult) { dispatchToTarget { $0.handleAISlashCommandsUpdate(ev) } }
    func handleAISessionConfigOptions(_ ev: AISessionConfigOptionsResult) { dispatchToTarget { $0.handleAISessionConfigOptions(ev) } }
    func handleAISessionSubscribeAck(_ ev: AISessionSubscribeAck) { dispatchToTarget { $0.handleAISessionSubscribeAck(ev) } }
    func handleAISessionRenameResult(_ ev: AISessionRenameResult) { dispatchToTarget { $0.handleAISessionRenameResult(ev) } }
    func handleAICodeReviewResult(_ ev: AICodeReviewResult) { dispatchToTarget { $0.handleAICodeReviewResult(ev) } }
    func handleAICodeCompletionChunk(_ ev: AICodeCompletionChunk) { dispatchToTarget { $0.handleAICodeCompletionChunk(ev) } }
    func handleAICodeCompletionDone(_ ev: AICodeCompletionDone) { dispatchToTarget { $0.handleAICodeCompletionDone(ev) } }
}

final class AppStateEvolutionMessageHandlerAdapter: WeakTargetMessageAdapter<AppState>, EvolutionMessageHandler {
    func handleEvolutionPulse() { dispatchToTarget { $0.handleEvolutionPulse() } }
    func handleEvolutionWorkspaceStatusEvent(_ ev: EvolutionWorkspaceStatusEventV2) { dispatchToTarget { $0.handleEvolutionWorkspaceStatusEvent(ev) } }
    func handleEvolutionSnapshot(_ snapshot: EvolutionSnapshotV2) { dispatchToTarget { $0.handleEvolutionSnapshot(snapshot) } }
    func handleEvolutionCycleUpdated(_ ev: EvoCycleUpdatedV2) { dispatchToTarget { $0.handleEvolutionCycleUpdated(ev) } }
    func handleEvolutionAgentProfile(_ ev: EvolutionAgentProfileV2) { dispatchToTarget { $0.handleEvolutionAgentProfile(ev) } }
    func handleEvolutionBlockingRequired(_ ev: EvolutionBlockingRequiredV2) { dispatchToTarget { $0.handleEvolutionBlockingRequired(ev) } }
    func handleEvolutionBlockersUpdated(_ ev: EvolutionBlockersUpdatedV2) { dispatchToTarget { $0.handleEvolutionBlockersUpdated(ev) } }
    func handleEvolutionCycleHistory(project: String, workspace: String, cycles: [EvolutionCycleHistoryItemV2]) {
        dispatchToTarget { $0.handleEvolutionCycleHistory(project: project, workspace: workspace, cycles: cycles) }
    }
    func handleEvolutionAutoCommitResult(_ result: EvoAutoCommitResult) { dispatchToTarget { $0.handleEvoAutoCommitResult(result) } }
    func handleEvolutionError(_ error: CoreError) {
        // macOS 桌面端映射：解构 CoreError 为独立参数
        dispatchToTarget { $0.handleEvolutionError(error.message, project: error.project, workspace: error.workspace) }
    }
}

final class AppStateErrorMessageHandlerAdapter: WeakTargetMessageAdapter<AppState>, ErrorMessageHandler {
    func handleClientError(_ message: String) {
        dispatchToTarget { $0.handleClientErrorMessage(message) }
    }

    func handleCoreError(_ error: CoreError) {
        dispatchToTarget { $0.handleCoreError(error) }
    }
}
