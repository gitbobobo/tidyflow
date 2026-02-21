import Foundation

private struct GetClientSettingsRequest: Encodable {
    let type: String = "get_client_settings"
}

private struct SaveClientSettingsRequest: Encodable {
    let type: String = "save_client_settings"
    let customCommands: [CustomCommandPayload]
    let workspaceShortcuts: [String: String]
    let commitAIAgent: String?
    let mergeAIAgent: String?
    let fixedPort: Int
    let appLanguage: String
    let remoteAccessEnabled: Bool

    struct CustomCommandPayload: Encodable {
        let id: String
        let name: String
        let icon: String
        let command: String
    }

    enum CodingKeys: String, CodingKey {
        case type
        case customCommands = "custom_commands"
        case workspaceShortcuts = "workspace_shortcuts"
        case commitAIAgent = "commit_ai_agent"
        case mergeAIAgent = "merge_ai_agent"
        case fixedPort = "fixed_port"
        case appLanguage = "app_language"
        case remoteAccessEnabled = "remote_access_enabled"
    }
}

// MARK: - WSClient 发送消息扩展

extension WSClient {
    // BEGIN AUTO-GENERATED: protocol_action_rules
    private var protocolExactRules: [(domain: String, action: String)] {
        [
        ("system", "ping"),
        ("terminal", "spawn_terminal"),
        ("terminal", "kill_terminal"),
        ("terminal", "input"),
        ("terminal", "resize"),
        ("file", "clipboard_image_upload"),
        ("git", "cancel_ai_task"),
        ]
    }

    private var protocolPrefixRules: [(domain: String, prefix: String)] {
        [
        ("terminal", "term_"),
        ("file", "file_"),
        ("file", "watch_"),
        ("git", "git_"),
        ("project", "list_"),
        ("project", "select_"),
        ("project", "import_"),
        ("project", "create_"),
        ("project", "remove_"),
        ("project", "project_"),
        ("project", "workspace_"),
        ("project", "save_project_commands"),
        ("project", "run_project_command"),
        ("project", "cancel_project_command"),
        ("lsp", "lsp_"),
        ("log", "log_"),
        ("ai", "ai_"),
        ("evolution", "evo_"),
        ]
    }

    private var protocolContainsRules: [(domain: String, needle: String)] {
        [
        ("settings", "client_settings"),
        ]
    }
    // END AUTO-GENERATED: protocol_action_rules


    private func domainForAction(_ action: String) -> String {
        if let matched = protocolExactRules.first(where: { $0.action == action }) {
            return matched.domain
        }
        if let matched = protocolPrefixRules.first(where: { action.hasPrefix($0.prefix) }) {
            return matched.domain
        }
        if let matched = protocolContainsRules.first(where: { action.contains($0.needle) }) {
            return matched.domain
        }
        return "misc"
    }

    private func encodeEnvelope(dict: [String: Any], requestId: String?) throws -> Data {
        guard let action = dict["type"] as? String, !action.isEmpty else {
            throw NSError(domain: "WSClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Message missing type"])
        }
        var payload = dict
        payload.removeValue(forKey: "type")
        let envelope: [String: Any] = [
            "request_id": requestId ?? UUID().uuidString,
            "domain": domainForAction(action),
            "action": action,
            "payload": payload,
            "client_ts": Int(Date().timeIntervalSince1970 * 1000)
        ]
        let codable = AnyCodable.from(envelope)
        return try msgpackEncoder.encode(codable)
    }

    // MARK: - Send Messages

    /// 发送二进制 MessagePack 数据
    func sendBinary(_ data: Data) {
        guard isConnected else {
            TFLog.ws.warning("Cannot send - not connected")
            emitClientError("Not connected")
            return
        }

        webSocketTask?.send(.data(data)) { [weak self] error in
            if let error = error {
                TFLog.ws.error("Send failed: \(error.localizedDescription, privacy: .public)")
                self?.emitClientError("Send failed: \(error.localizedDescription)")
            }
        }
    }

    /// 发送消息，使用 MessagePack 编码
    func send(_ dict: [String: Any], requestId: String? = nil) {
        do {
            let data = try encodeEnvelope(dict: dict, requestId: requestId)
            sendBinary(data)
        } catch {
            TFLog.ws.error("MessagePack encode failed: \(error.localizedDescription, privacy: .public)")
            emitClientError("Failed to encode message: \(error.localizedDescription)")
        }
    }

    /// 使用类型化请求体发送消息（包含统一请求包络）。
    func sendTyped<Body: Encodable>(_ body: Body, requestId: String? = nil) {
        do {
            let jsonData = try JSONEncoder().encode(body)
            let jsonObject = try JSONSerialization.jsonObject(with: jsonData)
            guard let dict = jsonObject as? [String: Any] else {
                throw NSError(domain: "WSClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "Typed body is not object"])
            }
            send(dict, requestId: requestId)
        } catch {
            TFLog.ws.error("MessagePack typed encode failed: \(error.localizedDescription, privacy: .public)")
            emitClientError("Failed to encode typed message: \(error.localizedDescription)")
        }
    }

    func requestFileIndex(project: String, workspace: String, query: String? = nil) {
        var msg: [String: Any] = [
            "type": "file_index",
            "project": project,
            "workspace": workspace
        ]
        if let query {
            msg["query"] = query
        }
        send(msg)
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

    /// AI 智能合并到默认分支（v1.33）
    func requestGitAIMerge(project: String, workspace: String, aiAgent: String? = nil, defaultBranch: String? = nil) {
        var dict: [String: Any] = [
            "type": "git_ai_merge",
            "project": project,
            "workspace": workspace
        ]
        if let agent = aiAgent {
            dict["ai_agent"] = agent
        }
        if let branch = defaultBranch {
            dict["default_branch"] = branch
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

    // MARK: - 终端会话（供 iOS / 远程客户端复用）

    /// 创建终端（基于项目与工作空间），可附带初始尺寸和展示信息
    func requestTermCreate(project: String, workspace: String, cols: Int? = nil, rows: Int? = nil, name: String? = nil, icon: String? = nil) {
        var msg: [String: Any] = [
            "type": "term_create",
            "project": project,
            "workspace": workspace
        ]
        if let cols { msg["cols"] = cols }
        if let rows { msg["rows"] = rows }
        if let name { msg["name"] = name }
        if let icon { msg["icon"] = icon }
        send(msg)
    }

    /// 获取终端会话列表
    func requestTermList() {
        send([
            "type": "term_list"
        ])
    }

    /// 关闭终端
    func requestTermClose(termId: String) {
        send([
            "type": "term_close",
            "term_id": termId
        ])
    }

    /// 附着已存在终端（重连场景）
    func requestTermAttach(termId: String) {
        send([
            "type": "term_attach",
            "term_id": termId
        ])
    }

    /// 取消当前 WS 连接对该终端的输出订阅（不关闭 PTY）
    func requestTermDetach(termId: String) {
        send([
            "type": "term_detach",
            "term_id": termId
        ])
    }

    /// 终端输出流控 ACK：通知 Core 已消费指定字节数，释放背压
    func sendTermOutputAck(termId: String, bytes: Int) {
        send([
            "type": "term_output_ack",
            "term_id": termId,
            "bytes": bytes
        ])
    }

    /// 发送终端输入（二进制字节）
    func sendTerminalInput(_ bytes: [UInt8], termId: String) {
        send([
            "type": "input",
            "term_id": termId,
            "data": bytes
        ])
    }

    /// 发送终端输入（UTF-8 文本）
    func sendTerminalInput(_ text: String, termId: String) {
        sendTerminalInput(Array(text.utf8), termId: termId)
    }

    /// 发送终端 resize
    func requestTermResize(termId: String, cols: Int, rows: Int) {
        send([
            "type": "resize",
            "term_id": termId,
            "cols": cols,
            "rows": rows
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
        sendTyped(GetClientSettingsRequest(), requestId: UUID().uuidString)
    }

    /// 保存客户端设置
    func requestSaveClientSettings(settings: ClientSettings) {
        let payload = SaveClientSettingsRequest(
            customCommands: settings.customCommands.map { cmd in
                SaveClientSettingsRequest.CustomCommandPayload(
                    id: cmd.id,
                    name: cmd.name,
                    icon: cmd.icon,
                    command: cmd.command
                )
            },
            workspaceShortcuts: settings.workspaceShortcuts,
            commitAIAgent: settings.commitAIAgent,
            mergeAIAgent: settings.mergeAIAgent,
            fixedPort: settings.fixedPort,
            appLanguage: settings.appLanguage,
            remoteAccessEnabled: settings.remoteAccessEnabled
        )
        sendTyped(payload, requestId: UUID().uuidString)
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
    func requestCancelProjectCommand(
        project: String,
        workspace: String,
        commandId: String,
        taskId: String? = nil
    ) {
        var payload: [String: Any] = [
            "type": "cancel_project_command",
            "project": project,
            "workspace": workspace,
            "command_id": commandId
        ]
        if let taskId, !taskId.isEmpty {
            payload["task_id"] = taskId
        }
        send(payload)
    }

    // MARK: - v1.31: LSP diagnostics

    /// 启动工作区 LSP 诊断
    func requestLspStartWorkspace(project: String, workspace: String) {
        send([
            "type": "lsp_start_workspace",
            "project": project,
            "workspace": workspace
        ])
    }

    /// 停止工作区 LSP 诊断
    func requestLspStopWorkspace(project: String, workspace: String) {
        send([
            "type": "lsp_stop_workspace",
            "project": project,
            "workspace": workspace
        ])
    }

    /// 拉取一次当前工作区 LSP 诊断快照
    func requestLspGetDiagnostics(project: String, workspace: String) {
        send([
            "type": "lsp_get_diagnostics",
            "project": project,
            "workspace": workspace
        ])
    }

    // MARK: - v1.37: 取消 AI 任务

    /// 取消正在运行的 AI 任务
    func requestCancelAITask(project: String, workspace: String, operationType: String) {
        send([
            "type": "cancel_ai_task",
            "project": project,
            "workspace": workspace,
            "operation_type": operationType
        ])
    }

    // MARK: - v1.39: 剪贴板图片上传

    /// 上传剪贴板图片到服务端（转 JPG 写入 macOS 系统剪贴板）
    func sendClipboardImageUpload(imageData: [UInt8]) {
        send([
            "type": "clipboard_image_upload",
            "image_data": Data(imageData)
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

    // MARK: - 任务历史

    /// 请求任务快照（用于移动端重连后恢复后台任务状态）
    func requestListTasks() {
        send([
            "type": "list_tasks"
        ])
    }

    // MARK: - AI Chat（结构化 message/part 流）

    /// 开始新的 AI 聊天会话
    func requestAIChatStart(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        title: String? = nil
    ) {
        var msg: [String: Any] = [
            "type": "ai_chat_start",
            "project_name": projectName,
            "workspace_name": workspaceName,
            "ai_tool": aiTool.rawValue
        ]
        if let title { msg["title"] = title }
        send(msg)
    }

    /// 发送 AI 聊天消息
    func requestAIChatSend(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String,
        message: String,
        fileRefs: [String]? = nil,
        imageParts: [[String: Any]]? = nil,
        model: [String: String]? = nil,
        agent: String? = nil
    ) {
        var msg: [String: Any] = [
            "type": "ai_chat_send",
            "project_name": projectName,
            "workspace_name": workspaceName,
            "ai_tool": aiTool.rawValue,
            "session_id": sessionId,
            "message": message
        ]
        if let fileRefs, !fileRefs.isEmpty {
            msg["file_refs"] = fileRefs
        }
        if let imageParts, !imageParts.isEmpty {
            msg["image_parts"] = imageParts
        }
        if let model {
            msg["model"] = model
        }
        if let agent {
            msg["agent"] = agent
        }
        send(msg)
    }

    /// 发送 AI 斜杠命令（OpenCode session.command）
    func requestAIChatCommand(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String,
        command: String,
        arguments: String,
        fileRefs: [String]? = nil,
        imageParts: [[String: Any]]? = nil,
        model: [String: String]? = nil,
        agent: String? = nil
    ) {
        var msg: [String: Any] = [
            "type": "ai_chat_command",
            "project_name": projectName,
            "workspace_name": workspaceName,
            "ai_tool": aiTool.rawValue,
            "session_id": sessionId,
            "command": command,
            "arguments": arguments
        ]
        if let fileRefs, !fileRefs.isEmpty {
            msg["file_refs"] = fileRefs
        }
        if let imageParts, !imageParts.isEmpty {
            msg["image_parts"] = imageParts
        }
        if let model {
            msg["model"] = model
        }
        if let agent {
            msg["agent"] = agent
        }
        send(msg)
    }

    /// 终止正在进行的 AI 聊天
    func requestAIChatAbort(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String
    ) {
        send([
            "type": "ai_chat_abort",
            "project_name": projectName,
            "workspace_name": workspaceName,
            "ai_tool": aiTool.rawValue,
            "session_id": sessionId
        ])
    }

    /// 回复 AI question 请求
    func requestAIQuestionReply(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String,
        requestId: String,
        answers: [[String]]
    ) {
        send([
            "type": "ai_question_reply",
            "project_name": projectName,
            "workspace_name": workspaceName,
            "ai_tool": aiTool.rawValue,
            "session_id": sessionId,
            "request_id": requestId,
            "answers": answers
        ])
    }

    /// 拒绝 AI question 请求
    func requestAIQuestionReject(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String,
        requestId: String
    ) {
        send([
            "type": "ai_question_reject",
            "project_name": projectName,
            "workspace_name": workspaceName,
            "ai_tool": aiTool.rawValue,
            "session_id": sessionId,
            "request_id": requestId
        ])
    }

    /// 获取 AI 会话列表
    func requestAISessionList(projectName: String, workspaceName: String, aiTool: AIChatTool) {
        send([
            "type": "ai_session_list",
            "project_name": projectName,
            "workspace_name": workspaceName,
            "ai_tool": aiTool.rawValue
        ])
    }

    /// 获取 AI 会话历史消息
    func requestAISessionMessages(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String,
        limit: Int? = nil
    ) {
        var msg: [String: Any] = [
            "type": "ai_session_messages",
            "project_name": projectName,
            "workspace_name": workspaceName,
            "ai_tool": aiTool.rawValue,
            "session_id": sessionId
        ]
        if let limit { msg["limit"] = limit }
        send(msg)
    }

    /// 查询 AI 会话状态（idle/busy/error）
    func requestAISessionStatus(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String
    ) {
        send([
            "type": "ai_session_status",
            "project_name": projectName,
            "workspace_name": workspaceName,
            "ai_tool": aiTool.rawValue,
            "session_id": sessionId
        ])
    }

    /// 删除 AI 会话
    func requestAISessionDelete(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String
    ) {
        send([
            "type": "ai_session_delete",
            "project_name": projectName,
            "workspace_name": workspaceName,
            "ai_tool": aiTool.rawValue,
            "session_id": sessionId
        ])
    }

    /// 获取 AI Provider/模型列表
    func requestAIProviderList(projectName: String, workspaceName: String, aiTool: AIChatTool) {
        send([
            "type": "ai_provider_list",
            "project_name": projectName,
            "workspace_name": workspaceName,
            "ai_tool": aiTool.rawValue
        ])
    }

    /// 获取 AI Agent 列表
    func requestAIAgentList(projectName: String, workspaceName: String, aiTool: AIChatTool) {
        send([
            "type": "ai_agent_list",
            "project_name": projectName,
            "workspace_name": workspaceName,
            "ai_tool": aiTool.rawValue
        ])
    }

    /// 获取 AI 斜杠命令列表
    func requestAISlashCommands(projectName: String, workspaceName: String, aiTool: AIChatTool) {
        send([
            "type": "ai_slash_commands",
            "project_name": projectName,
            "workspace_name": workspaceName,
            "ai_tool": aiTool.rawValue
        ])
    }

    // MARK: - Evolution

    /// 手动启动工作空间的自主进化流程（可配置是否自动续轮）
    func requestEvoStartWorkspace(
        project: String,
        workspace: String,
        priority: Int = 0,
        maxVerifyIterations: Int? = nil,
        autoLoopEnabled: Bool? = nil,
        stageProfiles: [EvolutionStageProfileInfoV2] = []
    ) {
        var msg: [String: Any] = [
            "type": "evo_start_workspace",
            "project": project,
            "workspace": workspace,
            "priority": priority
        ]
        if let maxVerifyIterations {
            msg["max_verify_iterations"] = maxVerifyIterations
        }
        if let autoLoopEnabled {
            msg["auto_loop_enabled"] = autoLoopEnabled
        }
        if !stageProfiles.isEmpty {
            msg["stage_profiles"] = stageProfiles.map { $0.toJSON() }
        }
        send(msg)
    }

    func requestEvoStopWorkspace(project: String, workspace: String, reason: String? = nil) {
        var msg: [String: Any] = [
            "type": "evo_stop_workspace",
            "project": project,
            "workspace": workspace
        ]
        if let reason, !reason.isEmpty {
            msg["reason"] = reason
        }
        send(msg)
    }

    func requestEvoStopAll(reason: String? = nil) {
        var msg: [String: Any] = ["type": "evo_stop_all"]
        if let reason, !reason.isEmpty {
            msg["reason"] = reason
        }
        send(msg)
    }

    func requestEvoResumeWorkspace(project: String, workspace: String) {
        send([
            "type": "evo_resume_workspace",
            "project": project,
            "workspace": workspace
        ])
    }

    func requestEvoSnapshot(project: String? = nil, workspace: String? = nil) {
        var msg: [String: Any] = ["type": "evo_get_snapshot"]
        if let project, !project.isEmpty { msg["project"] = project }
        if let workspace, !workspace.isEmpty { msg["workspace"] = workspace }
        send(msg)
    }

    func requestEvoOpenStageChat(project: String, workspace: String, cycleID: String, stage: String) {
        send([
            "type": "evo_open_stage_chat",
            "project": project,
            "workspace": workspace,
            "cycle_id": cycleID,
            "stage": stage
        ])
    }

    func requestEvoUpdateAgentProfile(project: String, workspace: String, stageProfiles: [EvolutionStageProfileInfoV2]) {
        send([
            "type": "evo_update_agent_profile",
            "project": project,
            "workspace": workspace,
            "stage_profiles": stageProfiles.map { $0.toJSON() }
        ])
    }

    func requestEvoGetAgentProfile(project: String, workspace: String) {
        send([
            "type": "evo_get_agent_profile",
            "project": project,
            "workspace": workspace
        ])
    }
}
