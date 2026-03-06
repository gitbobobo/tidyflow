import Foundation

private enum CoreHTTPClientError: LocalizedError {
    case invalidBaseURL
    case invalidRequestURL
    case invalidResponse
    case invalidPayload
    case httpStatus(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "HTTP base URL 不可用"
        case .invalidRequestURL:
            return "HTTP 请求 URL 非法"
        case .invalidResponse:
            return "HTTP 响应无效"
        case .invalidPayload:
            return "HTTP 响应格式非法"
        case let .httpStatus(code, message):
            return "HTTP \(code): \(message)"
        }
    }
}

private struct CoreHTTPClient {
    static func baseURL(from wsURL: URL?) -> URL? {
        guard let wsURL,
              var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if components.scheme == "wss" {
            components.scheme = "https"
        } else {
            components.scheme = "http"
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func fetchJSON(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem],
        token: String?
    ) async throws -> [String: Any] {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CoreHTTPClientError.invalidRequestURL
        }
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw CoreHTTPClientError.invalidRequestURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoreHTTPClientError.invalidResponse
        }

        if !(200..<300).contains(httpResponse.statusCode) {
            let message: String = {
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return "请求失败"
                }
                let code = (object["code"] as? String) ?? "error"
                let detail = (object["message"] as? String) ?? "请求失败"
                return "\(code): \(detail)"
            }()
            throw CoreHTTPClientError.httpStatus(code: httpResponse.statusCode, message: message)
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoreHTTPClientError.invalidPayload
        }
        return object
    }
}

private func encodePathComponent(_ raw: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
}

private struct GetClientSettingsRequest: Encodable {
    let type: String = "get_client_settings"
}

private struct SaveClientSettingsRequest: Encodable {
    let type: String = "save_client_settings"
    let customCommands: [CustomCommandPayload]
    let workspaceShortcuts: [String: String]
    let mergeAIAgent: String?
    let fixedPort: Int
    let remoteAccessEnabled: Bool
    let workspaceTodos: [String: [WorkspaceTodoPayload]]

    struct CustomCommandPayload: Encodable {
        let id: String
        let name: String
        let icon: String
        let command: String
    }

    struct WorkspaceTodoPayload: Encodable {
        let id: String
        let title: String
        let note: String?
        let status: String
        let order: Int64
        let createdAtMs: Int64
        let updatedAtMs: Int64

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case note
            case status
            case order
            case createdAtMs = "created_at_ms"
            case updatedAtMs = "updated_at_ms"
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case customCommands = "custom_commands"
        case workspaceShortcuts = "workspace_shortcuts"
        case mergeAIAgent = "merge_ai_agent"
        case fixedPort = "fixed_port"
        case remoteAccessEnabled = "remote_access_enabled"
        case workspaceTodos = "workspace_todos"
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
        ("log", "log_"),
        ("ai", "ai_"),
        ("evidence", "evidence_"),
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

    /// Evolution 动作里要求必须携带 `project/workspace` 的集合。
    /// `evo_get_snapshot` 的 project/workspace 可选，`evo_stop_all` 不需要，因此不在此集合中。
    private var evolutionActionsRequireProjectWorkspace: Set<String> {
        [
            "evo_start_workspace",
            "evo_stop_workspace",
            "evo_resume_workspace",
            "evo_open_stage_chat",
            "evo_update_agent_profile",
            "evo_get_agent_profile",
            "evo_list_cycle_history",
            "evo_resolve_blockers",
            "evo_auto_commit"
        ]
    }

    /// 出站消息基础校验，防止把明显非法的 payload 发送到服务端。
    private func validateOutgoingMessage(_ dict: [String: Any]) -> String? {
        guard let action = dict["type"] as? String, !action.isEmpty else {
            return "消息缺少 type"
        }
        if action.hasPrefix("evo_"),
           dict["project_name"] != nil || dict["workspace_name"] != nil {
            return "消息 \(action) 使用了过期字段 project_name/workspace_name，请改为 project/workspace"
        }
        guard evolutionActionsRequireProjectWorkspace.contains(action) else {
            return nil
        }
        let project = (dict["project"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if project.isEmpty {
            return "消息 \(action) 缺少 project"
        }
        let workspace = (dict["workspace"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if workspace.isEmpty {
            return "消息 \(action) 缺少 workspace"
        }
        return nil
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
        if let validationError = validateOutgoingMessage(dict) {
            TFLog.ws.error("Drop outbound message: \(validationError, privacy: .public)")
            emitClientError(validationError)
            return
        }
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

    @MainActor
    private func handleHTTPReadResult(
        domain: String,
        fallbackAction: String,
        json: [String: Any]
    ) {
        let action = (json["type"] as? String) ?? fallbackAction
        let handled: Bool
        switch domain {
        case "ai":
            handled = handleAiDomain(action, json: json)
        case "evolution":
            handled = handleEvolutionDomain(action, json: json)
        case "evidence":
            handled = handleEvidenceDomain(action, json: json)
        default:
            handled = false
        }
        if !handled {
            emitClientError("Unexpected HTTP response action: \(action)")
        }
    }

    @MainActor
    private func handleHTTPReadError(_ error: Error) {
        emitClientError(error.localizedDescription)
    }

    private func requestReadViaHTTP(
        domain: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        fallbackAction: String
    ) {
        guard let baseURL = CoreHTTPClient.baseURL(from: currentURL) else {
            emitClientError(CoreHTTPClientError.invalidBaseURL.localizedDescription)
            return
        }
        let token = wsAuthToken

        Task { [weak self] in
            do {
                let json = try await CoreHTTPClient.fetchJSON(
                    baseURL: baseURL,
                    path: path,
                    queryItems: queryItems,
                    token: token
                )
                await self?.handleHTTPReadResult(
                    domain: domain,
                    fallbackAction: fallbackAction,
                    json: json
                )
            } catch {
                await self?.handleHTTPReadError(error)
            }
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

    /// 请求读取文件内容（文本/二进制）
    func requestFileRead(project: String, workspace: String, path: String) {
        send([
            "type": "file_read",
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

    /// Evolution AutoCommit 独立执行
    func requestEvoAutoCommit(project: String, workspace: String) {
        send([
            "type": "evo_auto_commit",
            "project": project,
            "workspace": workspace
        ])
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
            mergeAIAgent: settings.mergeAIAgent,
            fixedPort: settings.fixedPort,
            remoteAccessEnabled: settings.remoteAccessEnabled,
            workspaceTodos: settings.workspaceTodos.mapValues { items in
                items.map { item in
                    SaveClientSettingsRequest.WorkspaceTodoPayload(
                        id: item.id,
                        title: item.title,
                        note: item.note,
                        status: item.status.rawValue,
                        order: item.order,
                        createdAtMs: item.createdAtMs,
                        updatedAtMs: item.updatedAtMs
                    )
                }
            }
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

    // MARK: - v1.xx: AI 会话订阅

    /// 订阅 AI 会话消息
    func requestAISessionSubscribe(project: String, workspace: String, aiTool: String, sessionId: String) {
        send([
            "type": "ai_session_subscribe",
            "project_name": project,
            "workspace_name": workspace,
            "ai_tool": aiTool,
            "session_id": sessionId,
        ])
    }

    /// 取消 AI 会话订阅
    func requestAISessionUnsubscribe(project: String, workspace: String, aiTool: String, sessionId: String) {
        send([
            "type": "ai_session_unsubscribe",
            "project_name": project,
            "workspace_name": workspace,
            "ai_tool": aiTool,
            "session_id": sessionId,
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
        audioParts: [[String: Any]]? = nil,
        model: [String: String]? = nil,
        agent: String? = nil,
        configOverrides: [String: Any]? = nil
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
        if let audioParts, !audioParts.isEmpty {
            msg["audio_parts"] = audioParts
        }
        if let model {
            msg["model"] = model
        }
        if let agent {
            msg["agent"] = agent
        }
        if let configOverrides, !configOverrides.isEmpty {
            msg["config_overrides"] = configOverrides
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
        audioParts: [[String: Any]]? = nil,
        model: [String: String]? = nil,
        agent: String? = nil,
        configOverrides: [String: Any]? = nil
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
        if let audioParts, !audioParts.isEmpty {
            msg["audio_parts"] = audioParts
        }
        if let model {
            msg["model"] = model
        }
        if let agent {
            msg["agent"] = agent
        }
        if let configOverrides, !configOverrides.isEmpty {
            msg["config_overrides"] = configOverrides
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
    func requestAISessionList(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        limit: Int? = 50
    ) {
        let path = "/api/v1/projects/\(encodePathComponent(projectName))/workspaces/\(encodePathComponent(workspaceName))/ai/\(encodePathComponent(aiTool.rawValue))/sessions"
        var queryItems: [URLQueryItem] = []
        if let limit, limit > 0 {
            queryItems.append(URLQueryItem(name: "limit", value: "\(limit)"))
        }
        requestReadViaHTTP(
            domain: "ai",
            path: path,
            queryItems: queryItems,
            fallbackAction: "ai_session_list"
        )
    }

    /// 获取 AI 会话历史消息
    func requestAISessionMessages(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String,
        limit: Int? = nil,
        beforeMessageId: String? = nil
    ) {
        let path = "/api/v1/projects/\(encodePathComponent(projectName))/workspaces/\(encodePathComponent(workspaceName))/ai/\(encodePathComponent(aiTool.rawValue))/sessions/\(encodePathComponent(sessionId))/messages"
        var queryItems: [URLQueryItem] = []
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: "\(limit)"))
        }
        if let beforeMessageId,
           !beforeMessageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "before_message_id", value: beforeMessageId))
        }
        requestReadViaHTTP(
            domain: "ai",
            path: path,
            queryItems: queryItems,
            fallbackAction: "ai_session_messages"
        )
    }

    /// 查询 AI 会话状态（idle/busy/error）
    func requestAISessionStatus(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String
    ) {
        let path = "/api/v1/projects/\(encodePathComponent(projectName))/workspaces/\(encodePathComponent(workspaceName))/ai/\(encodePathComponent(aiTool.rawValue))/sessions/\(encodePathComponent(sessionId))/status"
        requestReadViaHTTP(
            domain: "ai",
            path: path,
            fallbackAction: "ai_session_status_result"
        )
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

    func requestAISessionRename(project: String, workspace: String, aiTool: String, sessionId: String, newTitle: String) {
        send([
            "type": "ai_session_rename",
            "project_name": project,
            "workspace_name": workspace,
            "ai_tool": aiTool,
            "session_id": sessionId,
            "new_title": newTitle
        ])
    }

    func requestAISessionSearch(project: String, workspace: String, aiTool: String, query: String, limit: Int? = nil) {
        var msg: [String: Any] = [
            "type": "ai_session_search",
            "project_name": project,
            "workspace_name": workspace,
            "ai_tool": aiTool,
            "query": query
        ]
        if let limit = limit {
            msg["limit"] = limit
        }
        send(msg)
    }

    func requestAICodeReview(project: String, workspace: String, aiTool: String, diffText: String, filePaths: [String] = [], sessionId: String? = nil) {
        var msg: [String: Any] = [
            "type": "ai_code_review",
            "project_name": project,
            "workspace_name": workspace,
            "ai_tool": aiTool,
            "diff_text": diffText,
            "file_paths": filePaths
        ]
        if let sessionId = sessionId {
            msg["session_id"] = sessionId
        }
        send(msg)
    }

    /// 获取 AI Provider/模型列表
    func requestAIProviderList(projectName: String, workspaceName: String, aiTool: AIChatTool) {
        let path = "/api/v1/projects/\(encodePathComponent(projectName))/workspaces/\(encodePathComponent(workspaceName))/ai/\(encodePathComponent(aiTool.rawValue))/providers"
        requestReadViaHTTP(
            domain: "ai",
            path: path,
            fallbackAction: "ai_provider_list"
        )
    }

    /// 获取 AI Agent 列表
    func requestAIAgentList(projectName: String, workspaceName: String, aiTool: AIChatTool) {
        let path = "/api/v1/projects/\(encodePathComponent(projectName))/workspaces/\(encodePathComponent(workspaceName))/ai/\(encodePathComponent(aiTool.rawValue))/agents"
        requestReadViaHTTP(
            domain: "ai",
            path: path,
            fallbackAction: "ai_agent_list"
        )
    }

    /// 获取 AI 斜杠命令列表
    func requestAISlashCommands(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String? = nil
    ) {
        let path = "/api/v1/projects/\(encodePathComponent(projectName))/workspaces/\(encodePathComponent(workspaceName))/ai/\(encodePathComponent(aiTool.rawValue))/slash-commands"
        var queryItems: [URLQueryItem] = []
        if let sessionId, !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "session_id", value: sessionId))
        }
        requestReadViaHTTP(
            domain: "ai",
            path: path,
            queryItems: queryItems,
            fallbackAction: "ai_slash_commands"
        )
    }

    /// 获取会话配置选项（ACP session-config-options）
    func requestAISessionConfigOptions(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String? = nil
    ) {
        let path = "/api/v1/projects/\(encodePathComponent(projectName))/workspaces/\(encodePathComponent(workspaceName))/ai/\(encodePathComponent(aiTool.rawValue))/session-config-options"
        var queryItems: [URLQueryItem] = []
        if let sessionId, !sessionId.isEmpty {
            queryItems.append(URLQueryItem(name: "session_id", value: sessionId))
        }
        requestReadViaHTTP(
            domain: "ai",
            path: path,
            queryItems: queryItems,
            fallbackAction: "ai_session_config_options"
        )
    }

    /// 设置会话配置选项（ACP session/set_config_option）
    func requestAISessionSetConfigOption(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String,
        optionID: String,
        value: Any
    ) {
        send([
            "type": "ai_session_set_config_option",
            "project_name": projectName,
            "workspace_name": workspaceName,
            "ai_tool": aiTool.rawValue,
            "session_id": sessionId,
            "option_id": optionID,
            "value": value
        ])
    }

    // MARK: - Evolution

    /// 手动启动工作空间的自主进化流程（可配置总循环轮次）
    func requestEvoStartWorkspace(
        project: String,
        workspace: String,
        priority: Int = 0,
        loopRoundLimit: Int? = nil,
        stageProfiles: [EvolutionStageProfileInfoV2] = []
    ) {
        let normalizedProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWorkspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProject.isEmpty, !normalizedWorkspace.isEmpty else {
            TFLog.ws.error(
                "requestEvoStartWorkspace aborted: empty project/workspace, project='\(project, privacy: .public)', workspace='\(workspace, privacy: .public)'"
            )
            emitClientError("无法启动循环：项目或工作空间为空")
            return
        }
        var msg: [String: Any] = [
            "type": "evo_start_workspace",
            "project": normalizedProject,
            "workspace": normalizedWorkspace,
            "priority": priority
        ]
        if let loopRoundLimit {
            msg["loop_round_limit"] = loopRoundLimit
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

    func requestEvoResolveBlockers(
        project: String,
        workspace: String,
        resolutions: [EvolutionBlockerResolutionInputV2]
    ) {
        send([
            "type": "evo_resolve_blockers",
            "project": project,
            "workspace": workspace,
            "resolutions": resolutions.map { $0.toJSON() }
        ])
    }

    func requestEvoSnapshot(project: String? = nil, workspace: String? = nil) {
        var queryItems: [URLQueryItem] = []
        if let project, !project.isEmpty {
            queryItems.append(URLQueryItem(name: "project", value: project))
        }
        if let workspace, !workspace.isEmpty {
            queryItems.append(URLQueryItem(name: "workspace", value: workspace))
        }
        requestReadViaHTTP(
            domain: "evolution",
            path: "/api/v1/evolution/snapshot",
            queryItems: queryItems,
            fallbackAction: "evo_snapshot"
        )
    }

    func requestEvoOpenStageChat(project: String, workspace: String, cycleID: String, stage: String) {
        let path = "/api/v1/evolution/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/stage-chat"
        requestReadViaHTTP(
            domain: "evolution",
            path: path,
            queryItems: [
                URLQueryItem(name: "cycle_id", value: cycleID),
                URLQueryItem(name: "stage", value: stage)
            ],
            fallbackAction: "evo_stage_chat_opened"
        )
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
        let path = "/api/v1/evolution/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/agent-profile"
        requestReadViaHTTP(
            domain: "evolution",
            path: path,
            fallbackAction: "evo_agent_profile"
        )
    }

    func requestEvoListCycleHistory(project: String, workspace: String) {
        let path = "/api/v1/evolution/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/cycle-history"
        requestReadViaHTTP(
            domain: "evolution",
            path: path,
            fallbackAction: "evo_cycle_history"
        )
    }

    func requestEvidenceSnapshot(project: String, workspace: String) {
        let path = "/api/v1/evidence/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/snapshot"
        requestReadViaHTTP(
            domain: "evidence",
            path: path,
            fallbackAction: "evidence_snapshot"
        )
    }

    func requestEvidenceRebuildPrompt(project: String, workspace: String) {
        let path = "/api/v1/evidence/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/rebuild-prompt"
        requestReadViaHTTP(
            domain: "evidence",
            path: path,
            fallbackAction: "evidence_rebuild_prompt"
        )
    }

    func requestEvidenceReadItem(
        project: String,
        workspace: String,
        itemID: String,
        offset: UInt64 = 0,
        limit: UInt32? = 262_144
    ) {
        let path = "/api/v1/evidence/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/items/\(encodePathComponent(itemID))/chunk"
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "offset", value: "\(offset)")
        ]
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: "\(limit)"))
        }
        requestReadViaHTTP(
            domain: "evidence",
            path: path,
            queryItems: queryItems,
            fallbackAction: "evidence_item_chunk"
        )
    }
}
