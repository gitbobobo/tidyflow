import Foundation

// MARK: - WSClient 领域处理（Core）

extension WSClient {
    func handleSystemDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "hello", "pong":
            return true
        default:
            return false
        }
    }

    func handleTerminalDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "output":
            let termId = json["term_id"] as? String
            let bytes = WSBinary.decodeBytes(json["data"])
            onTerminalOutput?(termId, bytes)
            return true
        case "exit":
            let termId = json["term_id"] as? String
            let code = json["code"] as? Int ?? -1
            onTerminalExit?(termId, code)
            return true
        case "term_created":
            if let result = TermCreatedResult.from(json: json) {
                onTermCreated?(result)
            }
            return true
        case "term_attached":
            if let result = TermAttachedResult.from(json: json) {
                onTermAttached?(result)
            }
            return true
        case "term_list":
            if let result = TermListResult.from(json: json) {
                let remoteSubs = result.items.flatMap(\.remoteSubscribers)
                TFLog.ws.info("Received term_list: \(result.items.count) terminals, \(remoteSubs.count) remote subscribers")
                onTermList?(result)
            } else {
                TFLog.ws.warning("Failed to parse term_list response")
            }
            return true
        case "term_closed":
            if let termId = json["term_id"] as? String {
                onTermClosed?(termId)
            }
            return true
        case "remote_term_changed":
            TFLog.ws.info("Received remote_term_changed notification")
            onRemoteTermChanged?()
            return true
        default:
            return false
        }
    }

    func handleGitDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "git_diff_result":
            if let result = GitDiffResult.from(json: json) {
                onGitDiffResult?(result)
            }
            return true
        case "git_status_result":
            if let result = GitStatusResult.from(json: json) {
                onGitStatusResult?(result)
            }
            return true
        case "git_log_result":
            if let result = GitLogResult.from(json: json) {
                onGitLogResult?(result)
            }
            return true
        case "git_show_result":
            if let result = GitShowResult.from(json: json) {
                onGitShowResult?(result)
            }
            return true
        case "git_op_result":
            if let result = GitOpResult.from(json: json) {
                onGitOpResult?(result)
            }
            return true
        case "git_branches_result":
            if let result = GitBranchesResult.from(json: json) {
                onGitBranchesResult?(result)
            }
            return true
        case "git_commit_result":
            if let result = GitCommitResult.from(json: json) {
                onGitCommitResult?(result)
            }
            return true
        case "git_ai_commit_result":
            if let result = GitAICommitResult.from(json: json) {
                onGitAICommitResult?(result)
            }
            return true
        case "git_ai_merge_result":
            if let result = GitAIMergeResult.from(json: json) {
                onGitAIMergeResult?(result)
            }
            return true
        case "git_rebase_result":
            if let result = GitRebaseResult.from(json: json) {
                onGitRebaseResult?(result)
            }
            return true
        case "git_op_status_result":
            if let result = GitOpStatusResult.from(json: json) {
                onGitOpStatusResult?(result)
            }
            return true
        case "git_merge_to_default_result":
            if let result = GitMergeToDefaultResult.from(json: json) {
                onGitMergeToDefaultResult?(result)
            }
            return true
        case "git_integration_status_result":
            if let result = GitIntegrationStatusResult.from(json: json) {
                onGitIntegrationStatusResult?(result)
            }
            return true
        case "git_rebase_onto_default_result":
            if let result = GitRebaseOntoDefaultResult.from(json: json) {
                onGitRebaseOntoDefaultResult?(result)
            }
            return true
        case "git_reset_integration_worktree_result":
            if let result = GitResetIntegrationWorktreeResult.from(json: json) {
                onGitResetIntegrationWorktreeResult?(result)
            }
            return true
        case "git_status_changed":
            if let notification = GitStatusChangedNotification.from(json: json) {
                onGitStatusChanged?(notification)
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
                onWatchSubscribed?(result)
            }
            return true
        case "watch_unsubscribed":
            onWatchUnsubscribed?()
            return true
        case "file_rename_result":
            if let result = FileRenameResult.from(json: json) {
                onFileRenameResult?(result)
            }
            return true
        case "file_delete_result":
            if let result = FileDeleteResult.from(json: json) {
                onFileDeleteResult?(result)
            }
            return true
        case "file_copy_result":
            if let result = FileCopyResult.from(json: json) {
                onFileCopyResult?(result)
            }
            return true
        case "file_move_result":
            if let result = FileMoveResult.from(json: json) {
                onFileMoveResult?(result)
            }
            return true
        case "file_write_result":
            if let result = FileWriteResult.from(json: json) {
                onFileWriteResult?(result)
            }
            return true
        case "file_changed":
            if let notification = FileChangedNotification.from(json: json) {
                onFileChanged?(notification)
            }
            return true
        case "file_index_result":
            if let result = FileIndexResult.from(json: json) {
                onFileIndexResult?(result)
            }
            return true
        case "file_list_result":
            if let result = FileListResult.from(json: json) {
                onFileListResult?(result)
            }
            return true
        default:
            return false
        }
    }

    func handleLspDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "lsp_diagnostics":
            if let result = LspDiagnosticsResult.from(json: json) {
                onLspDiagnostics?(result)
            }
            return true
        case "lsp_status":
            if let result = LspStatusResult.from(json: json) {
                onLspStatus?(result)
            }
            return true
        default:
            return false
        }
    }
}
