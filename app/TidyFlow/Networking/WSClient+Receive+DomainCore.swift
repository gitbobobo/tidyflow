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
            if let handler = terminalMessageHandler {
                handler.handleTerminalOutput(termId, bytes)
            } else {
                onTerminalOutput?(termId, bytes)
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
                if let handler = gitMessageHandler {
                    handler.handleGitCommitResult(result)
                } else {
                    onGitCommitResult?(result)
                }
            }
            return true
        case "git_ai_commit_result":
            if let result = GitAICommitResult.from(json: json) {
                if let handler = gitMessageHandler {
                    handler.handleGitAICommitResult(result)
                } else {
                    onGitAICommitResult?(result)
                }
            }
            return true
        case "git_ai_merge_result":
            if let result = GitAIMergeResult.from(json: json) {
                if let handler = gitMessageHandler {
                    handler.handleGitAIMergeResult(result)
                } else {
                    onGitAIMergeResult?(result)
                }
            }
            return true
        case "git_rebase_result":
            if let result = GitRebaseResult.from(json: json) {
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
                if let handler = gitMessageHandler {
                    handler.handleGitRebaseOntoDefaultResult(result)
                } else {
                    onGitRebaseOntoDefaultResult?(result)
                }
            }
            return true
        case "git_reset_integration_worktree_result":
            if let result = GitResetIntegrationWorktreeResult.from(json: json) {
                if let handler = gitMessageHandler {
                    handler.handleGitResetIntegrationWorktreeResult(result)
                } else {
                    onGitResetIntegrationWorktreeResult?(result)
                }
            }
            return true
        case "git_status_changed":
            if let notification = GitStatusChangedNotification.from(json: json) {
                if let handler = gitMessageHandler {
                    handler.handleGitStatusChanged(notification)
                } else {
                    onGitStatusChanged?(notification)
                }
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
                if let handler = fileMessageHandler {
                    handler.handleFileRenameResult(result)
                } else {
                    onFileRenameResult?(result)
                }
            }
            return true
        case "file_delete_result":
            if let result = FileDeleteResult.from(json: json) {
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
                if let handler = fileMessageHandler {
                    handler.handleFileMoveResult(result)
                } else {
                    onFileMoveResult?(result)
                }
            }
            return true
        case "file_write_result":
            if let result = FileWriteResult.from(json: json) {
                if let handler = fileMessageHandler {
                    handler.handleFileWriteResult(result)
                } else {
                    onFileWriteResult?(result)
                }
            }
            return true
        case "file_changed":
            if let notification = FileChangedNotification.from(json: json) {
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

    func handleLspDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "lsp_diagnostics":
            if let result = LspDiagnosticsResult.from(json: json) {
                if let handler = lspMessageHandler {
                    handler.handleLspDiagnostics(result)
                } else {
                    onLspDiagnostics?(result)
                }
            }
            return true
        case "lsp_status":
            if let result = LspStatusResult.from(json: json) {
                if let handler = lspMessageHandler {
                    handler.handleLspStatus(result)
                } else {
                    onLspStatus?(result)
                }
            }
            return true
        default:
            return false
        }
    }
}
