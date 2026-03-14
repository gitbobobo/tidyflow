import Foundation
import TidyFlowShared

// MARK: - iOS 端领域消息处理适配器
// 各领域 adapter 继承共享骨架 WeakTargetMessageAdapter<MobileAppState>，
// 统一弱引用持有与主线程调度（DispatchQueue.main.async + MainActor.assumeIsolated），
// 仅保留领域差异与状态写入映射。
// AI 适配器从 MobileAppState.swift 迁入此处，与其它领域结构对齐。

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

final class MobileAppStateGitMessageHandlerAdapter: WeakTargetMessageAdapter<MobileAppState>, GitMessageHandler {
    func handleGitStatusResult(_ result: GitStatusResult) { dispatchToTarget { $0.handleGitStatusResult(result) } }
    func handleGitBranchesResult(_ result: GitBranchesResult) { dispatchToTarget { $0.handleGitBranchesResult(result) } }
    func handleGitCommitResult(_ result: GitCommitResult) { dispatchToTarget { $0.handleGitCommitResult(result) } }
    func handleGitOpResult(_ result: GitOpResult) { dispatchToTarget { $0.handleGitOpResult(result) } }
    func handleGitAIMergeResult(_ result: GitAIMergeResult) { dispatchToTarget { $0.handleGitAIMergeResult(result) } }
    func handleGitMergeToDefaultResult(_ result: GitMergeToDefaultResult) { dispatchToTarget { $0.handleGitMergeToDefaultResult(result) } }
    func handleGitStatusChanged(_ notification: GitStatusChangedNotification) { dispatchToTarget { $0.handleGitStatusChanged(notification) } }
    // v1.40: 冲突向导
    func handleGitConflictDetailResult(_ result: GitConflictDetailResult) { dispatchToTarget { $0.handleGitConflictDetailResult(result) } }
    func handleGitConflictActionResult(_ result: GitConflictActionResult) { dispatchToTarget { $0.handleGitConflictActionResult(result) } }
    /// iOS Diff 数据闭环：显式转发 handleGitDiffResult，由 MobileAppState 解析并回填 iOS Diff 缓存。
    func handleGitDiffResult(_ result: GitDiffResult) { dispatchToTarget { $0.handleGitDiffResult(result) } }
}

final class MobileAppStateProjectMessageHandlerAdapter: WeakTargetMessageAdapter<MobileAppState>, ProjectMessageHandler {
    func handleProjectsList(_ result: ProjectsListResult) { dispatchToTarget { $0.handleProjectsList(result) } }
    func handleWorkspacesList(_ result: WorkspacesListResult) { dispatchToTarget { $0.handleWorkspacesList(result) } }
    func handleProjectCommandStarted(_ project: String, _ workspace: String, _ commandId: String, _ taskId: String) {
        dispatchToTarget { $0.handleProjectCommandStarted(project: project, workspace: workspace, commandId: commandId, taskId: taskId) }
    }
    func handleProjectCommandCompleted(_ project: String, _ workspace: String, _ commandId: String, _ taskId: String, _ ok: Bool, _ message: String?) {
        dispatchToTarget { $0.handleProjectCommandCompleted(project: project, workspace: workspace, commandId: commandId, taskId: taskId, ok: ok, message: message) }
    }
    func handleProjectCommandOutput(_ taskId: String, _ line: String) {
        dispatchToTarget { $0.handleProjectCommandOutput(taskId: taskId, line: line) }
    }
    func handleTemplatesList(_ result: TemplatesListResult) { dispatchToTarget { $0.handleTemplatesList(result) } }
    func handleTemplateSaved(_ result: TemplateSavedResult) { dispatchToTarget { $0.handleTemplateSaved(result) } }
    func handleTemplateDeleted(_ result: TemplateDeletedResult) { dispatchToTarget { $0.handleTemplateDeleted(result) } }
    func handleTemplateImported(_ result: TemplateImportedResult) { dispatchToTarget { $0.handleTemplateImported(result) } }
}

final class MobileAppStateFileMessageHandlerAdapter: WeakTargetMessageAdapter<MobileAppState>, FileMessageHandler {
    func handleFileReadResult(_ result: FileReadResult) { dispatchToTarget { $0.handleFileReadResult(result) } }
    func handleFileIndexResult(_ result: FileIndexResult) { dispatchToTarget { $0.handleFileIndexResult(result) } }
    func handleFileListResult(_ result: FileListResult) { dispatchToTarget { $0.handleFileListResult(result) } }
    func handleFileRenameResult(_ result: FileRenameResult) { dispatchToTarget { $0.handleFileRenameResult(result) } }
    func handleFileDeleteResult(_ result: FileDeleteResult) { dispatchToTarget { $0.handleFileDeleteResult(result) } }
    func handleFileWriteResult(_ result: FileWriteResult) { dispatchToTarget { $0.handleFileWriteResult(result) } }
    func handleFileContentSearchResult(_ result: FileContentSearchResult) { dispatchToTarget { $0.handleFileContentSearchResult(result) } }
    func handleWatchSubscribed(_ result: WatchSubscribedResult) {
        dispatchToTarget { state in
            let key = state.globalWorkspaceKey(project: result.project, workspace: result.workspace)
            state.setFileWorkspacePhase(.watching, for: key)
        }
    }
    func handleWatchUnsubscribed() {
        dispatchToTarget { state in
            guard let identity = state.selectedWorkspaceIdentity else { return }
            let key = state.globalWorkspaceKey(
                project: identity.projectName,
                workspace: identity.workspaceName
            )
            state.setFileWorkspacePhase(.idle, for: key)
        }
    }
    func handleFileFormatCapabilitiesResult(_ result: FileFormatCapabilitiesResult) {
        dispatchToTarget { $0.handleFormatCapabilitiesResult(result) }
    }
    func handleFileFormatResult(_ result: FileFormatResult) {
        dispatchToTarget { $0.handleFormatResult(result) }
    }
    func handleFileFormatError(_ result: FileFormatErrorResult) {
        dispatchToTarget { $0.handleFormatError(result) }
    }
}

final class MobileAppStateTerminalMessageHandlerAdapter: WeakTargetMessageAdapter<MobileAppState>, TerminalMessageHandler {
    func handleTerminalOutput(_ termId: String?, _ bytes: [UInt8]) {
        dispatchToTarget { $0.handleTerminalOutput(termId: termId, bytes: bytes) }
    }
    func handleTerminalExit(_ termId: String?, _ code: Int) {
        dispatchToTarget { $0.handleTerminalExit(termId: termId, code: code) }
    }
    func handleTermCreated(_ result: TermCreatedResult) { dispatchToTarget { $0.handleTermCreated(result) } }
    func handleTermAttached(_ result: TermAttachedResult) { dispatchToTarget { $0.handleTermAttached(result) } }
    func handleTermList(_ result: TermListResult) { dispatchToTarget { $0.handleTermList(result) } }
    func handleTermClosed(_ termId: String) { dispatchToTarget { $0.handleTermClosed(termId) } }
}

final class MobileAppStateNodeMessageHandlerAdapter: WeakTargetMessageAdapter<MobileAppState>, NodeMessageHandler {
    func handleNodeSelfUpdated(_ identity: NodeSelfInfoV2) {
        dispatchToTarget { state in
            state.nodeSelfInfo = identity
        }
    }

    func handleNodeDiscoveryUpdated(_ items: [NodeDiscoveryItemV2]) {
        dispatchToTarget { state in
            state.nodeDiscoveryItems = reconcileDiscoveryPairingState(
                items: items,
                peers: state.nodeNetworkPeers
            )
        }
    }

    func handleNodeNetworkUpdated(_ snapshot: NodeNetworkSnapshotV2) {
        dispatchToTarget { state in
            state.nodeSelfInfo = snapshot.identity
            state.nodeNetworkPeers = snapshot.peers
            state.nodeActiveLocks = snapshot.activeLocks
            state.nodeDiscoveryItems = reconcileDiscoveryPairingState(
                items: state.nodeDiscoveryItems,
                peers: snapshot.peers
            )
        }
    }

    func handleNodePairingResult(_ result: NodePairingResultV2) {
        dispatchToTarget { state in
            state.nodePairingInFlight = false
            state.nodeLastPairingResult = result
            if result.ok {
                state.wsClient.requestNodeNetwork(cacheMode: .forceRefresh)
                state.wsClient.requestNodeDiscovery(cacheMode: .forceRefresh)
            }
        }
    }

    func handleNodePeerStatus(peerNodeID: String, status: String, lastSeenAtUnix: UInt64?) {
        dispatchToTarget { state in
            state.nodeNetworkPeers = state.nodeNetworkPeers.map { peer in
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

final class MobileAppStateEvolutionMessageHandlerAdapter: WeakTargetMessageAdapter<MobileAppState>, EvolutionMessageHandler {
    func handleEvolutionPulse() { dispatchToTarget { $0.handleEvolutionPulse() } }
    func handleEvolutionWorkspaceStatusEvent(_ ev: EvolutionWorkspaceStatusEventV2) {
        dispatchToTarget { $0.handleEvolutionWorkspaceStatusEvent(ev) }
    }
    func handleEvolutionSnapshot(_ snapshot: EvolutionSnapshotV2) { dispatchToTarget { $0.handleEvolutionSnapshot(snapshot) } }
    func handleEvolutionCycleUpdated(_ ev: EvoCycleUpdatedV2) { dispatchToTarget { $0.handleEvolutionCycleUpdated(ev) } }
    func handleEvolutionAgentProfile(_ ev: EvolutionAgentProfileV2) { dispatchToTarget { $0.handleEvolutionAgentProfile(ev) } }
    func handleEvolutionBlockingRequired(_ ev: EvolutionBlockingRequiredV2) { dispatchToTarget { $0.handleEvolutionBlockingRequired(ev) } }
    func handleEvolutionBlockersUpdated(_ ev: EvolutionBlockersUpdatedV2) { dispatchToTarget { $0.handleEvolutionBlockersUpdated(ev) } }
    func handleEvolutionCycleHistory(project: String, workspace: String, cycles: [EvolutionCycleHistoryItemV2]) {
        dispatchToTarget { $0.handleEvolutionCycleHistory(project: project, workspace: workspace, cycles: cycles) }
    }
    func handleEvolutionAutoCommitResult(_ result: EvoAutoCommitResult) { dispatchToTarget { $0.handleEvolutionAutoCommitResult(result) } }
    func handleEvolutionError(_ error: CoreError) { dispatchToTarget { $0.handleEvolutionError(error) } }
}

final class MobileAppStateErrorMessageHandlerAdapter: WeakTargetMessageAdapter<MobileAppState>, ErrorMessageHandler {
    func handleClientError(_ message: String) { dispatchToTarget { $0.handleClientError(message) } }
    func handleCoreError(_ error: CoreError) { dispatchToTarget { $0.handleCoreError(error) } }
}

/// iOS 端 AI 消息处理适配器 — 从 MobileAppState.swift 迁入此处，
/// 与其它领域适配器结构对齐，共用 WeakTargetMessageAdapter 共享骨架。
final class MobileAppStateAIMessageHandlerAdapter: WeakTargetMessageAdapter<MobileAppState>, AIMessageHandler {
    func handleAITaskCancelled(_ result: AITaskCancelled) {
        dispatchToTarget { $0.handleAITaskCancelled(result) }
    }

    func handleAISessionStarted(_ ev: AISessionStartedV2) {
        dispatchToTarget { $0.handleAISessionStarted(ev) }
    }

    func handleAISessionList(_ ev: AISessionListV2) {
        dispatchToTarget { $0.handleAISessionList(ev) }
    }

    func handleAISessionMessages(_ ev: AISessionMessagesV2) {
        dispatchToTarget { $0.handleAISessionMessages(ev) }
    }

    func handleAISessionMessagesUpdate(_ ev: AISessionMessagesUpdateV2) {
        dispatchToTarget { $0.handleAISessionMessagesUpdate(ev) }
    }

    func handleAISessionStatusResult(_ ev: AISessionStatusResultV2) {
        dispatchToTarget { $0.handleAISessionStatusResult(ev) }
    }

    func handleAISessionStatusUpdate(_ ev: AISessionStatusUpdateV2) {
        dispatchToTarget { $0.handleAISessionStatusUpdate(ev) }
    }

    func handleAIChatDone(_ ev: AIChatDoneV2) {
        dispatchToTarget { $0.handleAIChatDone(ev) }
    }

    func handleAIChatError(_ ev: AIChatErrorV2) {
        dispatchToTarget { $0.handleAIChatError(ev) }
    }

    func handleAIProviderList(_ ev: AIProviderListResult) {
        dispatchToTarget { $0.handleAIProviderList(ev) }
    }

    func handleAIAgentList(_ ev: AIAgentListResult) {
        dispatchToTarget { $0.handleAIAgentList(ev) }
    }

    func handleAISlashCommands(_ ev: AISlashCommandsResult) {
        dispatchToTarget { $0.handleAISlashCommands(ev) }
    }

    func handleAISlashCommandsUpdate(_ ev: AISlashCommandsUpdateResult) {
        dispatchToTarget { $0.handleAISlashCommandsUpdate(ev) }
    }

    func handleAISessionConfigOptions(_ ev: AISessionConfigOptionsResult) {
        dispatchToTarget { $0.handleAISessionConfigOptions(ev) }
    }

    func handleAIQuestionAsked(_ ev: AIQuestionAskedV2) {
        dispatchToTarget { $0.handleAIQuestionAsked(ev) }
    }

    func handleAIQuestionCleared(_ ev: AIQuestionClearedV2) {
        dispatchToTarget { $0.handleAIQuestionCleared(ev) }
    }

    func handleAISessionRenameResult(_ ev: AISessionRenameResult) {
        dispatchToTarget { $0.handleAISessionRenameResult(ev) }
    }

    func handleAISessionSubscribeAck(_ ev: AISessionSubscribeAck) {
        dispatchToTarget { $0.handleAISessionSubscribeAck(ev) }
    }

    func handleAIContextSnapshotUpdated(_ json: [String: Any]) {
        dispatchToTarget { $0.handleAIContextSnapshotUpdated(json) }
    }
}
