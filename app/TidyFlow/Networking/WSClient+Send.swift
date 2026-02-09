import Foundation

// MARK: - WSClient 发送消息扩展

extension WSClient {

    // MARK: - Send Messages

    /// 发送二进制 MessagePack 数据
    func sendBinary(_ data: Data) {
        guard isConnected else {
            TFLog.ws.warning("Cannot send - not connected")
            onError?("Not connected")
            return
        }

        webSocketTask?.send(.data(data)) { [weak self] error in
            if let error = error {
                TFLog.ws.error("Send failed: \(error.localizedDescription, privacy: .public)")
                self?.onError?("Send failed: \(error.localizedDescription)")
            }
        }
    }

    /// 发送消息，使用 MessagePack 编码
    func send(_ dict: [String: Any]) {
        do {
            let codable = AnyCodable.from(dict)
            let data = try msgpackEncoder.encode(codable)
            sendBinary(data)
        } catch {
            TFLog.ws.error("MessagePack encode failed: \(error.localizedDescription, privacy: .public)")
            onError?("Failed to encode message: \(error.localizedDescription)")
        }
    }

    func requestFileIndex(project: String, workspace: String) {
        send([
            "type": "file_index",
            "project": project,
            "workspace": workspace
        ])
    }

    /// 请求文件列表（目录浏览）
    func requestFileList(project: String, workspace: String, path: String = ".") {
        send([
            "type": "file_list",
            "project": project,
            "workspace": workspace,
            "path": path
        ])
    }

    // Phase C2-2a: Request git diff
    func requestGitDiff(project: String, workspace: String, path: String, mode: String) {
        send([
            "type": "git_diff",
            "project": project,
            "workspace": workspace,
            "path": path,
            "mode": mode
        ])
    }

    // Phase C3-1: Request git status
    func requestGitStatus(project: String, workspace: String) {
        send([
            "type": "git_status",
            "project": project,
            "workspace": workspace
        ])
    }

    // Git Log: Request commit history
    func requestGitLog(project: String, workspace: String, limit: Int = 50) {
        send([
            "type": "git_log",
            "project": project,
            "workspace": workspace,
            "limit": limit
        ])
    }

    // Git Show: Request single commit details
    func requestGitShow(project: String, workspace: String, sha: String) {
        send([
            "type": "git_show",
            "project": project,
            "workspace": workspace,
            "sha": sha
        ])
    }

    // Phase C3-2a: Request git stage
    func requestGitStage(project: String, workspace: String, path: String?, scope: String) {
        var msg: [String: Any] = [
            "type": "git_stage",
            "project": project,
            "workspace": workspace,
            "scope": scope
        ]
        if let path = path {
            msg["path"] = path
        }
        send(msg)
    }

    // Phase C3-2a: Request git unstage
    func requestGitUnstage(project: String, workspace: String, path: String?, scope: String) {
        var msg: [String: Any] = [
            "type": "git_unstage",
            "project": project,
            "workspace": workspace,
            "scope": scope
        ]
        if let path = path {
            msg["path"] = path
        }
        send(msg)
    }

    // Phase C3-2b: Request git discard
    func requestGitDiscard(project: String, workspace: String, path: String?, scope: String, includeUntracked: Bool = false) {
        var msg: [String: Any] = [
            "type": "git_discard",
            "project": project,
            "workspace": workspace,
            "scope": scope
        ]
        if let path = path {
            msg["path"] = path
        }
        if includeUntracked {
            msg["include_untracked"] = true
        }
        send(msg)
    }

    // Phase C3-3a: Request git branches
    func requestGitBranches(project: String, workspace: String) {
        send([
            "type": "git_branches",
            "project": project,
            "workspace": workspace
        ])
    }

    // Phase C3-3a: Request git switch branch
    func requestGitSwitchBranch(project: String, workspace: String, branch: String) {
        send([
            "type": "git_switch_branch",
            "project": project,
            "workspace": workspace,
            "branch": branch
        ])
    }

    // Phase C3-3b: Request git create branch
    func requestGitCreateBranch(project: String, workspace: String, branch: String) {
        send([
            "type": "git_create_branch",
            "project": project,
            "workspace": workspace,
            "branch": branch
        ])
    }

    // Phase C3-4a: Request git commit
    func requestGitCommit(project: String, workspace: String, message: String) {
        send([
            "type": "git_commit",
            "project": project,
            "workspace": workspace,
            "message": message
        ])
    }

    /// AI 智能提交
    func requestGitAICommit(project: String, workspace: String, aiAgent: String? = nil) {
        var dict: [String: Any] = [
            "type": "git_ai_commit",
            "project": project,
            "workspace": workspace
        ]
        if let agent = aiAgent {
            dict["ai_agent"] = agent
        }
        send(dict)
    }

    // Phase UX-3a: Request git fetch
    func requestGitFetch(project: String, workspace: String) {
        send([
            "type": "git_fetch",
            "project": project,
            "workspace": workspace
        ])
    }

    // Phase UX-3a: Request git rebase
    func requestGitRebase(project: String, workspace: String, ontoBranch: String) {
        send([
            "type": "git_rebase",
            "project": project,
            "workspace": workspace,
            "onto_branch": ontoBranch
        ])
    }

    // Phase UX-3a: Request git rebase continue
    func requestGitRebaseContinue(project: String, workspace: String) {
        send([
            "type": "git_rebase_continue",
            "project": project,
            "workspace": workspace
        ])
    }

    // Phase UX-3a: Request git rebase abort
    func requestGitRebaseAbort(project: String, workspace: String) {
        send([
            "type": "git_rebase_abort",
            "project": project,
            "workspace": workspace
        ])
    }

    // Phase UX-3a: Request git operation status
    func requestGitOpStatus(project: String, workspace: String) {
        send([
            "type": "git_op_status",
            "project": project,
            "workspace": workspace
        ])
    }

    // Phase UX-3b: Request git merge to default
    func requestGitMergeToDefault(project: String, workspace: String, defaultBranch: String) {
        send([
            "type": "git_merge_to_default",
            "project": project,
            "workspace": workspace,
            "default_branch": defaultBranch
        ])
    }

    // Phase UX-3b: Request git merge continue
    func requestGitMergeContinue(project: String) {
        send([
            "type": "git_merge_continue",
            "project": project
        ])
    }

    // Phase UX-3b: Request git merge abort
    func requestGitMergeAbort(project: String) {
        send([
            "type": "git_merge_abort",
            "project": project
        ])
    }

    // Phase UX-3b: Request git integration status
    func requestGitIntegrationStatus(project: String) {
        send([
            "type": "git_integration_status",
            "project": project
        ])
    }

    // Phase UX-4: Request git rebase onto default
    func requestGitRebaseOntoDefault(project: String, workspace: String, defaultBranch: String) {
        send([
            "type": "git_rebase_onto_default",
            "project": project,
            "workspace": workspace,
            "default_branch": defaultBranch
        ])
    }

    // Phase UX-4: Request git rebase onto default continue
    func requestGitRebaseOntoDefaultContinue(project: String) {
        send([
            "type": "git_rebase_onto_default_continue",
            "project": project
        ])
    }

    // Phase UX-4: Request git rebase onto default abort
    func requestGitRebaseOntoDefaultAbort(project: String) {
        send([
            "type": "git_rebase_onto_default_abort",
            "project": project
        ])
    }

    // Phase UX-5: Request git reset integration worktree
    func requestGitResetIntegrationWorktree(project: String) {
        send([
            "type": "git_reset_integration_worktree",
            "project": project
        ])
    }

    // Phase UX-6: Request git check branch up to date
    func requestGitCheckBranchUpToDate(project: String, workspace: String) {
        send([
            "type": "git_check_branch_up_to_date",
            "project": project,
            "workspace": workspace
        ])
    }

    // UX-2: Request import project
    func requestImportProject(name: String, path: String) {
        send([
            "type": "import_project",
            "name": name,
            "path": path
        ])
    }

    // UX-2: Request list projects
    func requestListProjects() {
        send([
            "type": "list_projects"
        ])
    }

    // Request list workspaces
    func requestListWorkspaces(project: String) {
        send([
            "type": "list_workspaces",
            "project": project
        ])
    }

    // UX-2: Request create workspace（名称由 Core 用 petname 生成）
    func requestCreateWorkspace(project: String, fromBranch: String? = nil) {
        var msg: [String: Any] = [
            "type": "create_workspace",
            "project": project
        ]
        if let branch = fromBranch {
            msg["from_branch"] = branch
        }
        send(msg)
    }

    // Remove project
    func requestRemoveProject(name: String) {
        send([
            "type": "remove_project",
            "name": name
        ])
    }

    // Remove workspace
    func requestRemoveWorkspace(project: String, workspace: String) {
        send([
            "type": "remove_workspace",
            "project": project,
            "workspace": workspace
        ])
    }

    // MARK: - 客户端设置

    /// 请求获取客户端设置
    func requestGetClientSettings() {
        send([
            "type": "get_client_settings"
        ])
    }

    /// 保存客户端设置
    func requestSaveClientSettings(settings: ClientSettings) {
        let commandsData = settings.customCommands.map { cmd -> [String: Any] in
            return [
                "id": cmd.id,
                "name": cmd.name,
                "icon": cmd.icon,
                "command": cmd.command
            ]
        }
        var payload: [String: Any] = [
            "type": "save_client_settings",
            "custom_commands": commandsData,
            "workspace_shortcuts": settings.workspaceShortcuts
        ]
        if let agent = settings.commitAIAgent {
            payload["commit_ai_agent"] = agent
        }
        if let agent = settings.mergeAIAgent {
            payload["merge_ai_agent"] = agent
        }
        send(payload)
    }

    // MARK: - v1.22: 文件监控

    /// 订阅工作空间文件监控
    func requestWatchSubscribe(project: String, workspace: String) {
        send([
            "type": "watch_subscribe",
            "project": project,
            "workspace": workspace
        ])
    }

    /// 取消文件监控订阅
    func requestWatchUnsubscribe() {
        send([
            "type": "watch_unsubscribe"
        ])
    }

    // MARK: - v1.23: 文件重命名/删除

    /// 请求重命名文件或目录
    func requestFileRename(project: String, workspace: String, oldPath: String, newName: String) {
        send([
            "type": "file_rename",
            "project": project,
            "workspace": workspace,
            "old_path": oldPath,
            "new_name": newName
        ])
    }

    /// 请求删除文件或目录（移到回收站）
    func requestFileDelete(project: String, workspace: String, path: String) {
        send([
            "type": "file_delete",
            "project": project,
            "workspace": workspace,
            "path": path
        ])
    }

    // MARK: - v1.24: 文件复制

    /// 请求复制文件或目录（使用绝对路径）
    func requestFileCopy(destProject: String, destWorkspace: String, sourceAbsolutePath: String, destDir: String) {
        send([
            "type": "file_copy",
            "dest_project": destProject,
            "dest_workspace": destWorkspace,
            "source_absolute_path": sourceAbsolutePath,
            "dest_dir": destDir
        ])
    }

    // MARK: - v1.25: 文件移动

    /// 请求移动文件或目录到新目录
    func requestFileMove(project: String, workspace: String, oldPath: String, newDir: String) {
        send([
            "type": "file_move",
            "project": project,
            "workspace": workspace,
            "old_path": oldPath,
            "new_dir": newDir
        ])
    }

    // MARK: - 文件写入（新建文件）

    /// 请求写入文件（用于新建空文件）
    func requestFileWrite(project: String, workspace: String, path: String, content: Data) {
        send([
            "type": "file_write",
            "project": project,
            "workspace": workspace,
            "path": path,
            "content": [UInt8](content)
        ])
    }

    // MARK: - v1.29: 项目命令

    /// 保存项目命令配置
    func requestSaveProjectCommands(project: String, commands: [ProjectCommand]) {
        let commandsData = commands.map { cmd -> [String: Any] in
            return [
                "id": cmd.id,
                "name": cmd.name,
                "icon": cmd.icon,
                "command": cmd.command,
                "blocking": cmd.blocking,
                "interactive": cmd.interactive
            ]
        }
        send([
            "type": "save_project_commands",
            "project": project,
            "commands": commandsData
        ])
    }

    /// 执行项目命令
    func requestRunProjectCommand(project: String, workspace: String, commandId: String) {
        send([
            "type": "run_project_command",
            "project": project,
            "workspace": workspace,
            "command_id": commandId
        ])
    }

    /// 取消正在运行的项目命令
    func requestCancelProjectCommand(project: String, workspace: String, commandId: String) {
        send([
            "type": "cancel_project_command",
            "project": project,
            "workspace": workspace,
            "command_id": commandId
        ])
    }

    // MARK: - 日志上报

    /// 发送日志到 Rust Core 统一写入文件
    func sendLogEntry(level: String, category: String? = nil, msg: String, detail: String? = nil) {
        var dict: [String: Any] = [
            "type": "log_entry",
            "level": level,
            "source": "swift",
            "msg": msg
        ]
        if let category = category {
            dict["category"] = category
        }
        if let detail = detail {
            dict["detail"] = detail
        }
        send(dict)
    }
}
