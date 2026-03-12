import Foundation
import TidyFlowShared

// MARK: - WSClient 领域处理（Core）

extension WSClient {
    func handleSystemDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "hello", "pong":
            return true
        case "system_snapshot":
            // 统一可观测性快照解析（v1.42）：一次性解析所有观测字段，双端共享
            let cacheMetrics = SystemSnapshotCacheMetrics.from(json: json["cache_metrics"])
            let perfMetrics = PerfMetricsSnapshot.from(json: json["perf_metrics"] as? [String: Any])
            let logContext = LogContextSummary.from(json: json["log_context"] as? [String: Any])
            let observability = ObservabilitySnapshot(
                cacheMetrics: cacheMetrics,
                perfMetrics: perfMetrics,
                logContext: logContext
            )
            onSystemSnapshot?(cacheMetrics)
            onObservabilitySnapshot?(observability)
            // WI-001: 全链路性能可观测快照
            if let perfObsJson = json["performance_observability"] as? [String: Any],
               let perfObsData = try? JSONSerialization.data(withJSONObject: perfObsJson),
               let perfObs = try? JSONDecoder().decode(PerformanceObservabilitySnapshot.self, from: perfObsData) {
                onPerformanceObservability?(perfObs)
            }
            // 工作区恢复状态与 Evolution 摘要：从 workspace_items 提取，按 (project, workspace) 隔离
            if let workspaceItems = json["workspace_items"] as? [[String: Any]] {
                let evolutionSummaries = workspaceItems.compactMap {
                    SystemSnapshotEvolutionWorkspaceSummary.from(workspaceItem: $0)
                }
                onEvolutionWorkspaceSummaries?(evolutionSummaries)
                let recoverySummaries = workspaceItems.compactMap { item -> WorkspaceRecoverySummary? in
                    guard let project = item["project"] as? String,
                          let workspace = item["workspace"] as? String
                    else { return nil }
                    return WorkspaceRecoverySummary.from(json: item, project: project, workspace: workspace)
                }
                if !recoverySummaries.isEmpty {
                    onWorkspaceRecoverySummaries?(recoverySummaries)
                }
                // v1.46: 从 workspace_items 提取 coordinator_ai 种子，按工作区分发
                for item in workspaceItems {
                    guard let project = item["project"] as? String,
                          let workspace = item["workspace"] as? String,
                          let aiJson = item["coordinator_ai"] as? [String: Any] else { continue }
                    let ai = AiDomainState.from(json: aiJson)
                    let version = aiJson["display_updated_at"] as? UInt64 ?? 0
                    let generatedAt = item["coordinator_ai_generated_at"] as? String ?? ""
                    let payload = CoordinatorWorkspaceSnapshotPayload(
                        project: project,
                        workspace: workspace,
                        ai: ai,
                        version: version,
                        generatedAt: generatedAt
                    )
                    onCoordinatorSnapshot?(payload)
                }
            }
            return true
        default:
            return false
        }
    }

    func handleTerminalDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "output_batch":
            let items = (json["items"] as? [[String: Any]] ?? [])
                .compactMap(TerminalOutputBatchItem.from(json:))
            for item in items {
                if let handler = terminalMessageHandler {
                    handler.handleTerminalOutput(item.termId, item.data)
                } else {
                    onTerminalOutput?(item.termId, item.data)
                }
            }
            return true
        case "exit":
            let termId = json["term_id"] as? String
            let code = json["code"] as? Int ?? -1
            if let handler = terminalMessageHandler {
                handler.handleTerminalExit(termId, code)
            } else {
                onTerminalExit?(termId, code)
            }
            return true
        case "term_created":
            if let result = TermCreatedResult.from(json: json) {
                if let handler = terminalMessageHandler {
                    handler.handleTermCreated(result)
                } else {
                    onTermCreated?(result)
                }
            }
            return true
        case "term_attached":
            if let result = TermAttachedResult.from(json: json) {
                if let handler = terminalMessageHandler {
                    handler.handleTermAttached(result)
                } else {
                    onTermAttached?(result)
                }
            }
            return true
        case "term_list":
            if let result = TermListResult.from(json: json) {
                let remoteSubs = result.items.flatMap(\.remoteSubscribers)
                TFLog.ws.info("Received term_list: \(result.items.count) terminals, \(remoteSubs.count) remote subscribers")
                if let handler = terminalMessageHandler {
                    handler.handleTermList(result)
                } else {
                    onTermList?(result)
                }
            } else {
                TFLog.ws.warning("Failed to parse term_list response")
            }
            return true
        case "term_closed":
            if let termId = json["term_id"] as? String {
                if let handler = terminalMessageHandler {
                    handler.handleTermClosed(termId)
                } else {
                    onTermClosed?(termId)
                }
            }
            return true
        case "remote_term_changed":
            TFLog.ws.info("Received remote_term_changed notification")
            if let handler = terminalMessageHandler {
                handler.handleRemoteTermChanged()
            } else {
                onRemoteTermChanged?()
            }
            return true
        default:
            return false
        }
    }

    func handleGitDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "git_diff_result":
            if let result = GitDiffResult.from(json: json) {
                if let handler = gitMessageHandler {
                    handler.handleGitDiffResult(result)
                } else {
                    onGitDiffResult?(result)
                }
            }
            return true
        case "git_status_result":
            if let result = GitStatusResult.from(json: json) {
                if let handler = gitMessageHandler {
                    handler.handleGitStatusResult(result)
                } else {
                    onGitStatusResult?(result)
                }
            }
            return true
        case "git_log_result":
            if let result = GitLogResult.from(json: json) {
                if let handler = gitMessageHandler {
                    handler.handleGitLogResult(result)
                } else {
                    onGitLogResult?(result)
                }
            }
            return true
        case "git_show_result":
            if let result = GitShowResult.from(json: json) {
                if let handler = gitMessageHandler {
                    handler.handleGitShowResult(result)
                } else {
                    onGitShowResult?(result)
                }
            }
            return true
        case "git_op_result":
            if let result = GitOpResult.from(json: json) {
                if result.ok {
                    invalidateHTTPQueries(.gitWorkspace(project: result.project, workspace: result.workspace))
                }
                if let handler = gitMessageHandler {
                    handler.handleGitOpResult(result)
                } else {
                    onGitOpResult?(result)
                }
            }
            return true
        case "git_branches_result":
            if let result = GitBranchesResult.from(json: json) {
                if let handler = gitMessageHandler {
                    handler.handleGitBranchesResult(result)
                } else {
                    onGitBranchesResult?(result)
                }
            }
            return true
        case "git_commit_result":
            if let result = GitCommitResult.from(json: json) {
                if result.ok {
                    invalidateHTTPQueries(.gitWorkspace(project: result.project, workspace: result.workspace))
                }
                if let handler = gitMessageHandler {
                    handler.handleGitCommitResult(result)
                } else {
                    onGitCommitResult?(result)
                }
            }
            return true
        case "git_ai_merge_result":
            if let result = GitAIMergeResult.from(json: json) {
                if result.success {
                    invalidateHTTPQueries(.gitWorkspace(project: result.project, workspace: result.workspace))
                }
                if let handler = gitMessageHandler {
                    handler.handleGitAIMergeResult(result)
                } else {
                    onGitAIMergeResult?(result)
                }
            }
            return true
        case "git_rebase_result":
            if let result = GitRebaseResult.from(json: json) {
                invalidateHTTPQueries(.gitWorkspace(project: result.project, workspace: result.workspace))
                if let handler = gitMessageHandler {
                    handler.handleGitRebaseResult(result)
                } else {
                    onGitRebaseResult?(result)
                }
            }
            return true
        case "git_op_status_result":
            if let result = GitOpStatusResult.from(json: json) {
                if let handler = gitMessageHandler {
                    handler.handleGitOpStatusResult(result)
                } else {
                    onGitOpStatusResult?(result)
                }
            }
            return true
        case "git_merge_to_default_result":
            if let result = GitMergeToDefaultResult.from(json: json) {
                invalidateHTTPQueries(.gitProject(project: result.project))
                if let handler = gitMessageHandler {
                    handler.handleGitMergeToDefaultResult(result)
                } else {
                    onGitMergeToDefaultResult?(result)
                }
            }
            return true
        case "git_integration_status_result":
            if let result = GitIntegrationStatusResult.from(json: json) {
                if let handler = gitMessageHandler {
                    handler.handleGitIntegrationStatusResult(result)
                } else {
                    onGitIntegrationStatusResult?(result)
                }
            }
            return true
        case "git_rebase_onto_default_result":
            if let result = GitRebaseOntoDefaultResult.from(json: json) {
                invalidateHTTPQueries(.gitProject(project: result.project))
                if let handler = gitMessageHandler {
                    handler.handleGitRebaseOntoDefaultResult(result)
                } else {
                    onGitRebaseOntoDefaultResult?(result)
                }
            }
            return true
        case "git_reset_integration_worktree_result":
            if let result = GitResetIntegrationWorktreeResult.from(json: json) {
                if result.ok {
                    invalidateHTTPQueries(.gitProject(project: result.project))
                }
                if let handler = gitMessageHandler {
                    handler.handleGitResetIntegrationWorktreeResult(result)
                } else {
                    onGitResetIntegrationWorktreeResult?(result)
                }
            }
            return true
        case "git_status_changed":
            if let notification = GitStatusChangedNotification.from(json: json) {
                invalidateHTTPQueries(.gitWorkspace(project: notification.project, workspace: notification.workspace))
                if let handler = gitMessageHandler {
                    handler.handleGitStatusChanged(notification)
                } else {
                    onGitStatusChanged?(notification)
                }
            }
            return true
        // v1.40: 冲突向导响应
        case "git_conflict_detail_result":
            if let result = GitConflictDetailResult.from(json: json) {
                gitMessageHandler?.handleGitConflictDetailResult(result)
            }
            return true
        case "git_conflict_action_result":
            if let result = GitConflictActionResult.from(json: json) {
                if result.ok {
                    invalidateHTTPQueries(.gitWorkspace(project: result.project, workspace: result.workspace))
                }
                gitMessageHandler?.handleGitConflictActionResult(result)
            }
            return true
        default:
            return false
        }
    }

    func handleFileDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "watch_subscribed":
            if let result = WatchSubscribedResult.from(json: json) {
                if let handler = fileMessageHandler {
                    handler.handleWatchSubscribed(result)
                } else {
                    onWatchSubscribed?(result)
                }
            }
            return true
        case "watch_unsubscribed":
            if let handler = fileMessageHandler {
                handler.handleWatchUnsubscribed()
            } else {
                onWatchUnsubscribed?()
            }
            return true
        case "file_rename_result":
            if let result = FileRenameResult.from(json: json) {
                if result.success {
                    invalidateHTTPQueries(.fileWorkspace(project: result.project, workspace: result.workspace))
                    invalidateHTTPQueries(.fileRead(project: result.project, workspace: result.workspace, path: result.oldPath))
                    invalidateHTTPQueries(.fileRead(project: result.project, workspace: result.workspace, path: result.newPath))
                }
                if let handler = fileMessageHandler {
                    handler.handleFileRenameResult(result)
                } else {
                    onFileRenameResult?(result)
                }
            }
            return true
        case "file_delete_result":
            if let result = FileDeleteResult.from(json: json) {
                if result.success {
                    invalidateHTTPQueries(.fileWorkspace(project: result.project, workspace: result.workspace))
                    invalidateHTTPQueries(.fileRead(project: result.project, workspace: result.workspace, path: result.path))
                }
                if let handler = fileMessageHandler {
                    handler.handleFileDeleteResult(result)
                } else {
                    onFileDeleteResult?(result)
                }
            }
            return true
        case "file_copy_result":
            if let result = FileCopyResult.from(json: json) {
                if let handler = fileMessageHandler {
                    handler.handleFileCopyResult(result)
                } else {
                    onFileCopyResult?(result)
                }
            }
            return true
        case "file_move_result":
            if let result = FileMoveResult.from(json: json) {
                if result.success {
                    invalidateHTTPQueries(.fileWorkspace(project: result.project, workspace: result.workspace))
                    invalidateHTTPQueries(.fileRead(project: result.project, workspace: result.workspace, path: result.oldPath))
                    invalidateHTTPQueries(.fileRead(project: result.project, workspace: result.workspace, path: result.newPath))
                }
                if let handler = fileMessageHandler {
                    handler.handleFileMoveResult(result)
                } else {
                    onFileMoveResult?(result)
                }
            }
            return true
        case "file_write_result":
            if let result = FileWriteResult.from(json: json) {
                if result.success {
                    invalidateHTTPQueries(.fileWorkspace(project: result.project, workspace: result.workspace))
                    invalidateHTTPQueries(.fileRead(project: result.project, workspace: result.workspace, path: result.path))
                }
                if let handler = fileMessageHandler {
                    handler.handleFileWriteResult(result)
                } else {
                    onFileWriteResult?(result)
                }
            }
            return true
        case "file_read_result":
            if let result = FileReadResult.from(json: json) {
                if let handler = fileMessageHandler {
                    handler.handleFileReadResult(result)
                } else {
                    onFileReadResult?(result)
                }
            }
            return true
        case "file_changed":
            if let notification = FileChangedNotification.from(json: json) {
                invalidateHTTPQueries(.fileWorkspace(project: notification.project, workspace: notification.workspace))
                notification.paths.forEach {
                    invalidateHTTPQueries(.fileRead(project: notification.project, workspace: notification.workspace, path: $0))
                }
                if let handler = fileMessageHandler {
                    handler.handleFileChanged(notification)
                } else {
                    onFileChanged?(notification)
                }
            }
            return true
        case "file_index_result":
            if let result = FileIndexResult.from(json: json) {
                if let handler = fileMessageHandler {
                    handler.handleFileIndexResult(result)
                } else {
                    onFileIndexResult?(result)
                }
            }
            return true
        case "file_list_result":
            if let result = FileListResult.from(json: json) {
                if let handler = fileMessageHandler {
                    handler.handleFileListResult(result)
                } else {
                    onFileListResult?(result)
                }
            }
            return true
        default:
            return false
        }
    }

    // MARK: - 健康域处理（v1.41）

    func handleHealthDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "health_snapshot":
            if let snapshotJson = json["snapshot"] as? [String: Any],
               let snapshot = SystemHealthSnapshot.from(json: snapshotJson) {
                onHealthSnapshot?(snapshot)
            }
            return true
        case "health_repair_result":
            if let auditJson = json["audit"] as? [String: Any],
               let audit = RepairAuditEntry.from(json: auditJson) {
                onHealthRepairResult?(audit)
            }
            return true
        default:
            return false
        }
    }

    // MARK: - Coordinator 域处理（v1.46）

    func handleCoordinatorDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "coordinator_snapshot":
            if let payload = CoordinatorWorkspaceSnapshotPayload.from(json: json) {
                onCoordinatorSnapshot?(payload)
            }
            return true
        default:
            return false
        }
    }

}
