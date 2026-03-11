import Foundation
import TidyFlowShared

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
    private static let requestTimeout: TimeInterval = 15

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
        request.timeoutInterval = requestTimeout
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

protocol TypedWSRequest: Encodable {
    var action: String { get }
    var validationProject: String? { get }
    var validationWorkspace: String? { get }
}

extension TypedWSRequest {
    var validationProject: String? { nil }
    var validationWorkspace: String? { nil }
}

private struct ClientEnvelopeV6<Payload: Encodable>: Encodable {
    let requestID: String
    let domain: String
    let action: String
    let payload: Payload
    let clientTs: UInt64

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case domain
        case action
        case payload
        case clientTs = "client_ts"
    }
}

private struct EmptyTypedWSRequest: TypedWSRequest {
    private let requestAction: String

    var action: String { requestAction }

    init(action: String) {
        self.requestAction = action
    }

    private enum CodingKeys: CodingKey {}
}

private struct ProjectTypedWSRequest: TypedWSRequest {
    private let requestAction: String
    let project: String

    var action: String { requestAction }
    var validationProject: String? { project }

    init(action: String, project: String) {
        self.requestAction = action
        self.project = project
    }

    private enum CodingKeys: String, CodingKey {
        case project
    }
}

private struct ProjectWorkspaceTypedWSRequest: TypedWSRequest {
    private let requestAction: String
    let project: String
    let workspace: String

    var action: String { requestAction }
    var validationProject: String? { project }
    var validationWorkspace: String? { workspace }

    init(action: String, project: String, workspace: String) {
        self.requestAction = action
        self.project = project
        self.workspace = workspace
    }

    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
    }
}

private struct ProjectWorkspacePathTypedWSRequest: TypedWSRequest {
    private let requestAction: String
    let project: String
    let workspace: String
    let path: String

    var action: String { requestAction }
    var validationProject: String? { project }
    var validationWorkspace: String? { workspace }

    init(action: String, project: String, workspace: String, path: String) {
        self.requestAction = action
        self.project = project
        self.workspace = workspace
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
        case path
    }
}

private struct ProjectWorkspacePathContextTypedWSRequest: TypedWSRequest {
    private let requestAction: String
    let project: String
    let workspace: String
    let path: String
    let context: String

    var action: String { requestAction }
    var validationProject: String? { project }
    var validationWorkspace: String? { workspace }

    init(action: String, project: String, workspace: String, path: String, context: String) {
        self.requestAction = action
        self.project = project
        self.workspace = workspace
        self.path = path
        self.context = context
    }

    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
        case path
        case context
    }
}

private struct TermIDTypedWSRequest: TypedWSRequest {
    private let requestAction: String
    let termID: String

    var action: String { requestAction }

    init(action: String, termID: String) {
        self.requestAction = action
        self.termID = termID
    }

    private enum CodingKeys: String, CodingKey {
        case termID = "term_id"
    }
}

private struct FileIndexRequest: TypedWSRequest {
    let project: String
    let workspace: String
    let query: String?

    var action: String { "file_index" }
}

private struct FileListRequest: TypedWSRequest {
    let project: String
    let workspace: String
    let path: String

    var action: String { "file_list" }
}

private struct GitDiffRequest: TypedWSRequest {
    let project: String
    let workspace: String
    let path: String
    let mode: String

    var action: String { "git_diff" }
}

private struct GitLogRequest: TypedWSRequest {
    let project: String
    let workspace: String
    let limit: Int

    var action: String { "git_log" }
}

private struct GitShowRequest: TypedWSRequest {
    let project: String
    let workspace: String
    let sha: String

    var action: String { "git_show" }
}

private struct GitStageRequest: TypedWSRequest {
    let project: String
    let workspace: String
    let path: String?
    let scope: String

    var action: String { "git_stage" }
}

private struct GitUnstageRequest: TypedWSRequest {
    let project: String
    let workspace: String
    let path: String?
    let scope: String

    var action: String { "git_unstage" }
}

private struct GitDiscardRequest: TypedWSRequest {
    let project: String
    let workspace: String
    let path: String?
    let scope: String
    let includeUntracked: Bool?

    var action: String { "git_discard" }

    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
        case path
        case scope
        case includeUntracked = "include_untracked"
    }
}

private struct GitBranchRequest: TypedWSRequest {
    private let requestAction: String
    let project: String
    let workspace: String
    let branch: String

    var action: String { requestAction }

    init(action: String, project: String, workspace: String, branch: String) {
        self.requestAction = action
        self.project = project
        self.workspace = workspace
        self.branch = branch
    }

    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
        case branch
    }
}

private struct GitCommitRequest: TypedWSRequest {
    let project: String
    let workspace: String
    let message: String

    var action: String { "git_commit" }
}

private struct GitAIMergeRequest: TypedWSRequest {
    let project: String
    let workspace: String
    let aiAgent: String?
    let defaultBranch: String?

    var action: String { "git_ai_merge" }

    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
        case aiAgent = "ai_agent"
        case defaultBranch = "default_branch"
    }
}

private struct GitOntoBranchRequest: TypedWSRequest {
    private let requestAction: String
    let project: String
    let workspace: String
    let ontoBranch: String

    var action: String { requestAction }

    init(action: String, project: String, workspace: String, ontoBranch: String) {
        self.requestAction = action
        self.project = project
        self.workspace = workspace
        self.ontoBranch = ontoBranch
    }

    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
        case ontoBranch = "onto_branch"
    }
}

private struct GitDefaultBranchRequest: TypedWSRequest {
    private let requestAction: String
    let project: String
    let workspace: String
    let defaultBranch: String

    var action: String { requestAction }

    init(action: String, project: String, workspace: String, defaultBranch: String) {
        self.requestAction = action
        self.project = project
        self.workspace = workspace
        self.defaultBranch = defaultBranch
    }

    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
        case defaultBranch = "default_branch"
    }
}

private struct ImportProjectRequest: TypedWSRequest {
    let name: String
    let path: String

    var action: String { "import_project" }
}

private struct ListWorkspacesRequest: TypedWSRequest {
    let project: String

    var action: String { "list_workspaces" }
}

private struct TermCreateRequest: TypedWSRequest {
    let project: String
    let workspace: String
    let cols: Int?
    let rows: Int?
    let name: String?
    let icon: String?

    var action: String { "term_create" }
}

private struct TermOutputAckRequest: TypedWSRequest {
    let termID: String
    let bytes: Int

    var action: String { "term_output_ack" }

    private enum CodingKeys: String, CodingKey {
        case termID = "term_id"
        case bytes
    }
}

private struct TerminalInputRequest: TypedWSRequest {
    let termID: String
    let data: [UInt8]

    var action: String { "input" }

    private enum CodingKeys: String, CodingKey {
        case termID = "term_id"
        case data
    }
}

private struct TerminalResizeRequest: TypedWSRequest {
    let termID: String
    let cols: Int
    let rows: Int

    var action: String { "resize" }

    private enum CodingKeys: String, CodingKey {
        case termID = "term_id"
        case cols
        case rows
    }
}

private struct CreateWorkspaceRequest: TypedWSRequest {
    let project: String
    let fromBranch: String?
    let templateID: String?

    var action: String { "create_workspace" }

    private enum CodingKeys: String, CodingKey {
        case project
        case fromBranch = "from_branch"
        case templateID = "template_id"
    }
}

private struct NameRequest: TypedWSRequest {
    private let requestAction: String
    let name: String

    var action: String { requestAction }

    init(action: String, name: String) {
        self.requestAction = action
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case name
    }
}

private struct FileRenameRequest: TypedWSRequest {
    let project: String
    let workspace: String
    let oldPath: String
    let newName: String

    var action: String { "file_rename" }

    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
        case oldPath = "old_path"
        case newName = "new_name"
    }
}

private struct FileCopyRequest: TypedWSRequest {
    let destProject: String
    let destWorkspace: String
    let sourceAbsolutePath: String
    let destDir: String

    var action: String { "file_copy" }

    private enum CodingKeys: String, CodingKey {
        case destProject = "dest_project"
        case destWorkspace = "dest_workspace"
        case sourceAbsolutePath = "source_absolute_path"
        case destDir = "dest_dir"
    }
}

private struct FileMoveRequest: TypedWSRequest {
    let project: String
    let workspace: String
    let oldPath: String
    let newDir: String

    var action: String { "file_move" }

    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
        case oldPath = "old_path"
        case newDir = "new_dir"
    }
}

private struct FileWriteRequest: TypedWSRequest {
    let project: String
    let workspace: String
    let path: String
    let content: [UInt8]

    var action: String { "file_write" }
}

private struct RunProjectCommandRequest: TypedWSRequest {
    let project: String
    let workspace: String
    let commandID: String

    var action: String { "run_project_command" }

    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
        case commandID = "command_id"
    }
}

private struct CancelProjectCommandRequest: TypedWSRequest {
    let project: String
    let workspace: String
    let commandID: String
    let taskID: String?

    var action: String { "cancel_project_command" }

    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
        case commandID = "command_id"
        case taskID = "task_id"
    }
}

private struct TemplateIDRequest: TypedWSRequest {
    private let requestAction: String
    let templateID: String

    var action: String { requestAction }

    init(action: String, templateID: String) {
        self.requestAction = action
        self.templateID = templateID
    }

    private enum CodingKeys: String, CodingKey {
        case templateID = "template_id"
    }
}

private struct CancelAITaskRequest: TypedWSRequest {
    let project: String
    let workspace: String
    let operationType: String

    var action: String { "cancel_ai_task" }

    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
        case operationType = "operation_type"
    }
}

private struct ClipboardImageUploadRequest: TypedWSRequest {
    let imageData: Data

    var action: String { "clipboard_image_upload" }

    private enum CodingKeys: String, CodingKey {
        case imageData = "image_data"
    }
}

private struct GetClientSettingsRequest: TypedWSRequest {
    var action: String { "get_client_settings" }
}

private struct SaveClientSettingsRequest: TypedWSRequest {
    var action: String { "save_client_settings" }
    let customCommands: [CustomCommandPayload]
    let workspaceShortcuts: [String: String]
    let mergeAIAgent: String?
    let fixedPort: Int
    let remoteAccessEnabled: Bool
    let evolutionDefaultProfiles: [EvolutionStageProfilePayload]
    let workspaceTodos: [String: [WorkspaceTodoPayload]]
    let keybindings: [KeybindingPayload]

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

    struct EvolutionModelSelectionPayload: Encodable {
        let providerID: String
        let modelID: String

        enum CodingKeys: String, CodingKey {
            case providerID = "provider_id"
            case modelID = "model_id"
        }
    }

    struct EvolutionStageProfilePayload: Encodable {
        let stage: String
        let aiTool: String
        let mode: String?
        let model: EvolutionModelSelectionPayload?
        let configOptions: [String: AnyCodable]

        enum CodingKeys: String, CodingKey {
            case stage
            case aiTool = "ai_tool"
            case mode
            case model
            case configOptions = "config_options"
        }
    }

    struct KeybindingPayload: Encodable {
        let commandId: String
        let keyCombination: String
        let context: String

        enum CodingKeys: String, CodingKey {
            case commandId, keyCombination, context
        }
    }

    enum CodingKeys: String, CodingKey {
        case customCommands = "custom_commands"
        case workspaceShortcuts = "workspace_shortcuts"
        case mergeAIAgent = "merge_ai_agent"
        case fixedPort = "fixed_port"
        case remoteAccessEnabled = "remote_access_enabled"
        case evolutionDefaultProfiles = "evolution_default_profiles"
        case workspaceTodos = "workspace_todos"
        case keybindings
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
        ("project", "save_template"),
        ("project", "delete_template"),
        ("project", "export_template"),
        ("project", "import_template"),
        ("project", "templates"),
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
        ("project", "template_"),
        ("log", "log_"),
        ("ai", "ai_"),
        ("evidence", "evidence_"),
        ("evolution", "evo_"),
        ("git", "git_conflict_"),
        ("health", "health_"),
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

    private func validateOutgoingMessage(
        action: String,
        project: String? = nil,
        workspace: String? = nil
    ) -> String? {
        let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAction.isEmpty else {
            return "消息缺少 type"
        }
        guard evolutionActionsRequireProjectWorkspace.contains(trimmedAction) else {
            return nil
        }
        let trimmedProject = project?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedProject.isEmpty {
            return "消息 \(trimmedAction) 缺少 project"
        }
        let trimmedWorkspace = workspace?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedWorkspace.isEmpty {
            return "消息 \(trimmedAction) 缺少 workspace"
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
        return try makeMessagePackEncoder().encode(codable)
    }

    func encodeTypedEnvelope<Body: TypedWSRequest>(_ body: Body, requestId: String?) throws -> Data {
        let envelope = ClientEnvelopeV6(
            requestID: requestId ?? UUID().uuidString,
            domain: domainForAction(body.action),
            action: body.action,
            payload: body,
            clientTs: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        return try makeMessagePackEncoder().encode(envelope)
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
    func sendTyped<Body: TypedWSRequest>(_ body: Body, requestId: String? = nil) {
        if let validationError = validateOutgoingMessage(
            action: body.action,
            project: body.validationProject,
            workspace: body.validationWorkspace
        ) {
            TFLog.ws.error("Drop outbound typed message: \(validationError, privacy: .public)")
            emitClientError(validationError)
            return
        }
        do {
            let data = try encodeTypedEnvelope(body, requestId: requestId)
            sendBinary(data)
        } catch {
            TFLog.ws.error("MessagePack typed encode failed: \(error.localizedDescription, privacy: .public)")
            emitClientError("Failed to encode typed message: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func handleHTTPReadResult(
        domain: String,
        fallbackAction: String,
        json: [String: Any],
        context: HTTPReadRequestContext?
    ) {
        let action = (json["type"] as? String) ?? fallbackAction
        let handled: Bool
        switch domain {
        case "system":
            handled = handleSystemDomain(action, json: json)
        case "project":
            handled = handleProjectDomain(action, json: json)
        case "settings":
            handled = handleSettingsDomain(action, json: json)
        case "terminal":
            handled = handleTerminalDomain(action, json: json)
        case "file":
            handled = handleFileDomain(action, json: json)
        case "git":
            handled = handleGitDomain(action, json: json)
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
            let message = "Unexpected HTTP response action: \(action)"
            onHTTPReadFailure?(HTTPReadFailure(context: context, message: message))
            emitClientError(message)
        }
    }

    @MainActor
    private func handleHTTPReadError(_ error: Error, context: HTTPReadRequestContext?) {
        let message = error.localizedDescription
        onHTTPReadFailure?(HTTPReadFailure(context: context, message: message))
        emitClientError(message)
    }

    private func requestReadViaHTTP(
        domain: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        fallbackAction: String,
        context: HTTPReadRequestContext? = nil
    ) {
        guard let baseURL = CoreHTTPClient.baseURL(from: currentURL) else {
            let message = CoreHTTPClientError.invalidBaseURL.localizedDescription
            onHTTPReadFailure?(HTTPReadFailure(context: context, message: message))
            emitClientError(message)
            return
        }
        let token = wsAuthToken
        onHTTPRequestScheduled?(domain, path, queryItems)

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
                    json: json,
                    context: context
                )
            } catch {
                await self?.handleHTTPReadError(error, context: context)
            }
        }
    }

    func requestFileIndex(project: String, workspace: String, query: String? = nil) {
        let path = "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/files/index"
        let queryItems = query.map { [URLQueryItem(name: "query", value: $0)] } ?? []
        requestReadViaHTTP(
            domain: "file",
            path: path,
            queryItems: queryItems,
            fallbackAction: "file_index_result"
        )
    }

    /// 请求文件列表（目录浏览）
    func requestFileList(project: String, workspace: String, path: String = ".") {
        requestReadViaHTTP(
            domain: "file",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/files",
            queryItems: [URLQueryItem(name: "path", value: path)],
            fallbackAction: "file_list_result"
        )
    }

    /// 请求读取文件内容（文本/二进制）
    func requestFileRead(project: String, workspace: String, path: String) {
        requestReadViaHTTP(
            domain: "file",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/files/content",
            queryItems: [URLQueryItem(name: "path", value: path)],
            fallbackAction: "file_read_result",
            context: .fileRead(project: project, workspace: workspace, path: path)
        )
    }

    // Phase C2-2a: Request git diff
    func requestGitDiff(project: String, workspace: String, path: String, mode: String) {
        requestReadViaHTTP(
            domain: "git",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/git/diff",
            queryItems: [
                URLQueryItem(name: "path", value: path),
                URLQueryItem(name: "mode", value: mode)
            ],
            fallbackAction: "git_diff_result"
        )
    }

    // Phase C3-1: Request git status
    func requestGitStatus(project: String, workspace: String) {
        requestReadViaHTTP(
            domain: "git",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/git/status",
            fallbackAction: "git_status_result"
        )
    }

    // Git Log: Request commit history
    func requestGitLog(project: String, workspace: String, limit: Int = 50) {
        requestReadViaHTTP(
            domain: "git",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/git/log",
            queryItems: [URLQueryItem(name: "limit", value: "\(limit)")],
            fallbackAction: "git_log_result"
        )
    }

    // Git Show: Request single commit details
    func requestGitShow(project: String, workspace: String, sha: String) {
        requestReadViaHTTP(
            domain: "git",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/git/commits/\(encodePathComponent(sha))",
            fallbackAction: "git_show_result"
        )
    }

    // Phase C3-2a: Request git stage
    func requestGitStage(project: String, workspace: String, path: String?, scope: String) {
        sendTyped(GitStageRequest(project: project, workspace: workspace, path: path, scope: scope))
    }

    // Phase C3-2a: Request git unstage
    func requestGitUnstage(project: String, workspace: String, path: String?, scope: String) {
        sendTyped(GitUnstageRequest(project: project, workspace: workspace, path: path, scope: scope))
    }

    // Phase C3-2b: Request git discard
    func requestGitDiscard(project: String, workspace: String, path: String?, scope: String, includeUntracked: Bool = false) {
        sendTyped(
            GitDiscardRequest(
                project: project,
                workspace: workspace,
                path: path,
                scope: scope,
                includeUntracked: includeUntracked ? true : nil
            )
        )
    }

    // Phase C3-3a: Request git branches
    func requestGitBranches(project: String, workspace: String) {
        requestReadViaHTTP(
            domain: "git",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/git/branches",
            fallbackAction: "git_branches_result"
        )
    }

    // Phase C3-3a: Request git switch branch
    func requestGitSwitchBranch(project: String, workspace: String, branch: String) {
        sendTyped(GitBranchRequest(action: "git_switch_branch", project: project, workspace: workspace, branch: branch))
    }

    // Phase C3-3b: Request git create branch
    func requestGitCreateBranch(project: String, workspace: String, branch: String) {
        sendTyped(GitBranchRequest(action: "git_create_branch", project: project, workspace: workspace, branch: branch))
    }

    // Phase C3-4a: Request git commit
    func requestGitCommit(project: String, workspace: String, message: String) {
        sendTyped(GitCommitRequest(project: project, workspace: workspace, message: message))
    }

    /// Evolution AutoCommit 独立执行
    func requestEvoAutoCommit(project: String, workspace: String) {
        sendTyped(ProjectWorkspaceTypedWSRequest(action: "evo_auto_commit", project: project, workspace: workspace))
    }

    /// AI 智能合并到默认分支（v1.33）
    func requestGitAIMerge(project: String, workspace: String, aiAgent: String? = nil, defaultBranch: String? = nil) {
        sendTyped(GitAIMergeRequest(project: project, workspace: workspace, aiAgent: aiAgent, defaultBranch: defaultBranch))
    }

    // Phase UX-3a: Request git fetch
    func requestGitFetch(project: String, workspace: String) {
        sendTyped(ProjectWorkspaceTypedWSRequest(action: "git_fetch", project: project, workspace: workspace))
    }

    // Phase UX-3a: Request git rebase
    func requestGitRebase(project: String, workspace: String, ontoBranch: String) {
        sendTyped(GitOntoBranchRequest(action: "git_rebase", project: project, workspace: workspace, ontoBranch: ontoBranch))
    }

    // Phase UX-3a: Request git rebase continue
    func requestGitRebaseContinue(project: String, workspace: String) {
        sendTyped(ProjectWorkspaceTypedWSRequest(action: "git_rebase_continue", project: project, workspace: workspace))
    }

    // Phase UX-3a: Request git rebase abort
    func requestGitRebaseAbort(project: String, workspace: String) {
        sendTyped(ProjectWorkspaceTypedWSRequest(action: "git_rebase_abort", project: project, workspace: workspace))
    }

    // Phase UX-3a: Request git operation status
    func requestGitOpStatus(project: String, workspace: String) {
        requestReadViaHTTP(
            domain: "git",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/git/op-status",
            fallbackAction: "git_op_status_result"
        )
    }

    // Phase UX-3b: Request git merge to default
    func requestGitMergeToDefault(project: String, workspace: String, defaultBranch: String) {
        sendTyped(GitDefaultBranchRequest(action: "git_merge_to_default", project: project, workspace: workspace, defaultBranch: defaultBranch))
    }

    // Phase UX-3b: Request git merge continue
    func requestGitMergeContinue(project: String) {
        sendTyped(ProjectTypedWSRequest(action: "git_merge_continue", project: project))
    }

    // Phase UX-3b: Request git merge abort
    func requestGitMergeAbort(project: String) {
        sendTyped(ProjectTypedWSRequest(action: "git_merge_abort", project: project))
    }

    // Phase UX-3b: Request git integration status
    func requestGitIntegrationStatus(project: String) {
        requestReadViaHTTP(
            domain: "git",
            path: "/api/v1/projects/\(encodePathComponent(project))/git/integration-status",
            fallbackAction: "git_integration_status_result"
        )
    }

    // Phase UX-4: Request git rebase onto default
    func requestGitRebaseOntoDefault(project: String, workspace: String, defaultBranch: String) {
        sendTyped(GitDefaultBranchRequest(action: "git_rebase_onto_default", project: project, workspace: workspace, defaultBranch: defaultBranch))
    }

    // Phase UX-4: Request git rebase onto default continue
    func requestGitRebaseOntoDefaultContinue(project: String) {
        sendTyped(ProjectTypedWSRequest(action: "git_rebase_onto_default_continue", project: project))
    }

    // Phase UX-4: Request git rebase onto default abort
    func requestGitRebaseOntoDefaultAbort(project: String) {
        sendTyped(ProjectTypedWSRequest(action: "git_rebase_onto_default_abort", project: project))
    }

    // Phase UX-5: Request git reset integration worktree
    func requestGitResetIntegrationWorktree(project: String) {
        sendTyped(ProjectTypedWSRequest(action: "git_reset_integration_worktree", project: project))
    }

    // Phase UX-6: Request git check branch up to date
    func requestGitCheckBranchUpToDate(project: String, workspace: String) {
        requestReadViaHTTP(
            domain: "git",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/git/up-to-date",
            fallbackAction: "git_integration_status_result"
        )
    }

    // v1.40: 冲突向导请求方法

    /// 读取单文件四路对比内容
    func requestGitConflictDetail(project: String, workspace: String, path: String, context: String) {
        requestReadViaHTTP(
            domain: "git",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/git/conflicts/detail",
            queryItems: [
                URLQueryItem(name: "path", value: path),
                URLQueryItem(name: "context", value: context)
            ],
            fallbackAction: "git_conflict_detail_result"
        )
    }

    /// 接受我方版本（ours）解决冲突
    func requestGitConflictAcceptOurs(project: String, workspace: String, path: String, context: String) {
        sendTyped(ProjectWorkspacePathContextTypedWSRequest(action: "git_conflict_accept_ours", project: project, workspace: workspace, path: path, context: context))
    }

    /// 接受对方版本（theirs）解决冲突
    func requestGitConflictAcceptTheirs(project: String, workspace: String, path: String, context: String) {
        sendTyped(ProjectWorkspacePathContextTypedWSRequest(action: "git_conflict_accept_theirs", project: project, workspace: workspace, path: path, context: context))
    }

    /// 保留双方内容（both）解决冲突
    func requestGitConflictAcceptBoth(project: String, workspace: String, path: String, context: String) {
        sendTyped(ProjectWorkspacePathContextTypedWSRequest(action: "git_conflict_accept_both", project: project, workspace: workspace, path: path, context: context))
    }

    /// 手动标记文件已解决
    func requestGitConflictMarkResolved(project: String, workspace: String, path: String, context: String) {
        sendTyped(ProjectWorkspacePathContextTypedWSRequest(action: "git_conflict_mark_resolved", project: project, workspace: workspace, path: path, context: context))
    }

    // UX-2: Request import project
    func requestImportProject(name: String, path: String) {
        sendTyped(ImportProjectRequest(name: name, path: path))
    }

    // UX-2: Request list projects
    func requestListProjects() {
        requestReadViaHTTP(
            domain: "project",
            path: "/api/v1/projects",
            fallbackAction: "projects"
        )
    }

    // Request list workspaces
    func requestListWorkspaces(project: String) {
        requestReadViaHTTP(
            domain: "project",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces",
            fallbackAction: "workspaces"
        )
    }

    // MARK: - 终端会话（供 iOS / 远程客户端复用）

    /// 创建终端（基于项目与工作空间），可附带初始尺寸和展示信息
    func requestTermCreate(project: String, workspace: String, cols: Int? = nil, rows: Int? = nil, name: String? = nil, icon: String? = nil) {
        sendTyped(
            TermCreateRequest(
                project: project,
                workspace: workspace,
                cols: cols,
                rows: rows,
                name: name,
                icon: icon
            )
        )
    }

    /// 获取终端会话列表
    func requestTermList() {
        requestReadViaHTTP(
            domain: "terminal",
            path: "/api/v1/terminals",
            fallbackAction: "term_list"
        )
    }

    /// 关闭终端
    func requestTermClose(termId: String) {
        sendTyped(TermIDTypedWSRequest(action: "term_close", termID: termId))
    }

    /// 附着已存在终端（重连场景）
    func requestTermAttach(termId: String) {
        sendTyped(TermIDTypedWSRequest(action: "term_attach", termID: termId))
    }

    /// 取消当前 WS 连接对该终端的输出订阅（不关闭 PTY）
    func requestTermDetach(termId: String) {
        sendTyped(TermIDTypedWSRequest(action: "term_detach", termID: termId))
    }

    /// 终端输出流控 ACK：通知 Core 已消费指定字节数，释放背压
    func sendTermOutputAck(termId: String, bytes: Int) {
        sendTyped(TermOutputAckRequest(termID: termId, bytes: bytes))
    }

    /// 发送终端输入（二进制字节）
    func sendTerminalInput(_ bytes: [UInt8], termId: String) {
        sendTyped(TerminalInputRequest(termID: termId, data: bytes))
    }

    /// 发送终端输入（UTF-8 文本）
    func sendTerminalInput(_ text: String, termId: String) {
        sendTerminalInput(Array(text.utf8), termId: termId)
    }

    /// 发送终端 resize
    func requestTermResize(termId: String, cols: Int, rows: Int) {
        sendTyped(TerminalResizeRequest(termID: termId, cols: cols, rows: rows))
    }

    // UX-2: Request create workspace（名称由 Core 用 petname 生成）
    func requestCreateWorkspace(project: String, fromBranch: String? = nil, templateId: String? = nil) {
        sendTyped(CreateWorkspaceRequest(project: project, fromBranch: fromBranch, templateID: templateId))
    }

    // Remove project
    func requestRemoveProject(name: String) {
        sendTyped(NameRequest(action: "remove_project", name: name))
    }

    // Remove workspace
    func requestRemoveWorkspace(project: String, workspace: String) {
        sendTyped(ProjectWorkspaceTypedWSRequest(action: "remove_workspace", project: project, workspace: workspace))
    }

    // MARK: - 客户端设置

    /// 请求获取客户端设置
    func requestGetClientSettings() {
        requestReadViaHTTP(
            domain: "settings",
            path: "/api/v1/client-settings",
            fallbackAction: "client_settings_result"
        )
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
            evolutionDefaultProfiles: settings.evolutionDefaultProfiles.map { profile in
                SaveClientSettingsRequest.EvolutionStageProfilePayload(
                    stage: profile.stage,
                    aiTool: profile.aiTool.rawValue,
                    mode: profile.mode,
                    model: profile.model.map { model in
                        SaveClientSettingsRequest.EvolutionModelSelectionPayload(
                            providerID: model.providerID,
                            modelID: model.modelID
                        )
                    },
                    configOptions: profile.configOptions.mapValues { AnyCodable.from($0) }
                )
            },
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
            },
            keybindings: settings.keybindings.map { kb in
                SaveClientSettingsRequest.KeybindingPayload(
                    commandId: kb.commandId,
                    keyCombination: kb.keyCombination,
                    context: kb.context
                )
            }
        )
        sendTyped(payload)
    }

    // MARK: - v1.22: 文件监控

    /// 订阅工作空间文件监控
    func requestWatchSubscribe(project: String, workspace: String) {
        sendTyped(ProjectWorkspaceTypedWSRequest(action: "watch_subscribe", project: project, workspace: workspace))
    }

    /// 取消文件监控订阅
    func requestWatchUnsubscribe() {
        sendTyped(EmptyTypedWSRequest(action: "watch_unsubscribe"))
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
        sendTyped(FileRenameRequest(project: project, workspace: workspace, oldPath: oldPath, newName: newName))
    }

    /// 请求删除文件或目录（移到回收站）
    func requestFileDelete(project: String, workspace: String, path: String) {
        sendTyped(ProjectWorkspacePathTypedWSRequest(action: "file_delete", project: project, workspace: workspace, path: path))
    }

    // MARK: - v1.24: 文件复制

    /// 请求复制文件或目录（使用绝对路径）
    func requestFileCopy(destProject: String, destWorkspace: String, sourceAbsolutePath: String, destDir: String) {
        sendTyped(
            FileCopyRequest(
                destProject: destProject,
                destWorkspace: destWorkspace,
                sourceAbsolutePath: sourceAbsolutePath,
                destDir: destDir
            )
        )
    }

    // MARK: - v1.25: 文件移动

    /// 请求移动文件或目录到新目录
    func requestFileMove(project: String, workspace: String, oldPath: String, newDir: String) {
        sendTyped(FileMoveRequest(project: project, workspace: workspace, oldPath: oldPath, newDir: newDir))
    }

    // MARK: - 文件写入（新建文件）

    /// 请求写入文件（用于新建空文件）
    func requestFileWrite(project: String, workspace: String, path: String, content: Data) {
        sendTyped(FileWriteRequest(project: project, workspace: workspace, path: path, content: [UInt8](content)))
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
        sendTyped(RunProjectCommandRequest(project: project, workspace: workspace, commandID: commandId))
    }

    /// 取消正在运行的项目命令
    func requestCancelProjectCommand(
        project: String,
        workspace: String,
        commandId: String,
        taskId: String? = nil
    ) {
        sendTyped(
            CancelProjectCommandRequest(
                project: project,
                workspace: workspace,
                commandID: commandId,
                taskID: taskId?.isEmpty == false ? taskId : nil
            )
        )
    }

    // MARK: - v1.40: 工作流模板管理

    /// 获取所有工作流模板列表
    func requestListTemplates() {
        requestReadViaHTTP(
            domain: "project",
            path: "/api/v1/templates",
            fallbackAction: "templates"
        )
    }

    /// 保存（新增或更新）工作流模板
    func requestSaveTemplate(_ template: TemplateInfo) {
        send([
            "type": "save_template",
            "template": template.toDict()
        ])
    }

    /// 删除工作流模板
    func requestDeleteTemplate(templateId: String) {
        sendTyped(TemplateIDRequest(action: "delete_template", templateID: templateId))
    }

    /// 导出工作流模板（服务端返回完整模板数据）
    func requestExportTemplate(templateId: String) {
        requestReadViaHTTP(
            domain: "project",
            path: "/api/v1/templates/\(encodePathComponent(templateId))/export",
            fallbackAction: "template_exported"
        )
    }

    /// 导入工作流模板
    func requestImportTemplate(_ template: TemplateInfo) {
        send([
            "type": "import_template",
            "template": template.toDict()
        ])
    }

    // MARK: - v1.37: 取消 AI 任务

    /// 取消正在运行的 AI 任务
    func requestCancelAITask(project: String, workspace: String, operationType: String) {
        sendTyped(CancelAITaskRequest(project: project, workspace: workspace, operationType: operationType))
    }

    // MARK: - v1.39: 剪贴板图片上传

    /// 上传剪贴板图片到服务端（转 JPG 写入 macOS 系统剪贴板）
    func sendClipboardImageUpload(imageData: [UInt8]) {
        sendTyped(ClipboardImageUploadRequest(imageData: Data(imageData)))
    }

    // MARK: - 日志上报

    /// 发送日志到 Rust Core 统一写入文件（含结构化错误码与上下文）
    func sendLogEntry(
        level: String,
        category: String? = nil,
        msg: String,
        detail: String? = nil,
        errorCode: CoreErrorCode? = nil,
        project: String? = nil,
        workspace: String? = nil,
        sessionId: String? = nil,
        cycleId: String? = nil
    ) {
        var dict: [String: Any] = [
            "type": "log_entry",
            "level": level,
            "source": "swift",
            "msg": msg
        ]
        if let category { dict["category"] = category }
        if let detail { dict["detail"] = detail }
        if let errorCode { dict["error_code"] = errorCode.rawValue }
        if let project { dict["project"] = project }
        if let workspace { dict["workspace"] = workspace }
        if let sessionId { dict["session_id"] = sessionId }
        if let cycleId { dict["cycle_id"] = cycleId }
        send(dict)
    }

    // MARK: - 任务历史

    /// 请求任务快照（用于移动端重连后恢复后台任务状态）
    func requestListTasks() {
        requestReadViaHTTP(
            domain: "project",
            path: "/api/v1/tasks",
            fallbackAction: "tasks_snapshot"
        )
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
        configOverrides: [String: Any]? = nil,
        projectMentions: [String]? = nil
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
        if let projectMentions, !projectMentions.isEmpty {
            msg["project_mentions"] = projectMentions
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
        filter: AIChatTool? = nil,
        cursor: String? = nil,
        limit: Int? = 50
    ) {
        let path = "/api/v1/projects/\(encodePathComponent(projectName))/workspaces/\(encodePathComponent(workspaceName))/ai/sessions"
        var queryItems: [URLQueryItem] = []
        if let limit, limit > 0 {
            queryItems.append(URLQueryItem(name: "limit", value: "\(limit)"))
        }
        if let filter {
            queryItems.append(URLQueryItem(name: "ai_tool", value: filter.rawValue))
        }
        if let cursor,
           !cursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
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
        let normalizedBefore = beforeMessageId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedBefore == nil || normalizedBefore?.isEmpty == true {
            let dedupKey = aiRecentSessionMessagesKey(
                projectName: projectName,
                workspaceName: workspaceName,
                aiTool: aiTool,
                sessionId: sessionId
            )
            let now = Date()
            if let startedAt = aiRecentSessionMessagesInFlightAt[dedupKey],
               now.timeIntervalSince(startedAt) < 5 {
                aiRecentSessionMessagesDedupDropTotal += 1
                TFLog.perf.info("perf ai_session_list_dedup_drop_total=\(self.aiRecentSessionMessagesDedupDropTotal, privacy: .public) scope=messages")
                return
            }
            if let lastSuccessAt = aiRecentSessionMessagesLastSuccessAt[dedupKey],
               now.timeIntervalSince(lastSuccessAt) < 1 {
                aiRecentSessionMessagesDedupDropTotal += 1
                TFLog.perf.info("perf ai_session_list_dedup_drop_total=\(self.aiRecentSessionMessagesDedupDropTotal, privacy: .public) scope=messages")
                return
            }
            aiRecentSessionMessagesInFlightAt[dedupKey] = now
        }

        let path = "/api/v1/projects/\(encodePathComponent(projectName))/workspaces/\(encodePathComponent(workspaceName))/ai/\(encodePathComponent(aiTool.rawValue))/sessions/\(encodePathComponent(sessionId))/messages"
        var queryItems: [URLQueryItem] = []
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: "\(limit)"))
        }
        if let normalizedBefore,
           !normalizedBefore.isEmpty {
            queryItems.append(URLQueryItem(name: "before_message_id", value: normalizedBefore))
        }
        requestReadViaHTTP(
            domain: "ai",
            path: path,
            queryItems: queryItems,
            fallbackAction: "ai_session_messages"
        )
    }

    func aiRecentSessionMessagesKey(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String
    ) -> String {
        "\(projectName)::\(workspaceName)::\(aiTool.rawValue)::\(sessionId)"
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
            fallbackAction: "ai_provider_list",
            context: .aiProviderList(project: projectName, workspace: workspaceName, aiTool: aiTool)
        )
    }

    /// 获取 AI Agent 列表
    func requestAIAgentList(projectName: String, workspaceName: String, aiTool: AIChatTool) {
        let path = "/api/v1/projects/\(encodePathComponent(projectName))/workspaces/\(encodePathComponent(workspaceName))/ai/\(encodePathComponent(aiTool.rawValue))/agents"
        requestReadViaHTTP(
            domain: "ai",
            path: path,
            fallbackAction: "ai_agent_list",
            context: .aiAgentList(project: projectName, workspace: workspaceName, aiTool: aiTool)
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

    func requestEvoAdjustLoopRound(project: String, workspace: String, loopRoundLimit: Int) {
        send([
            "type": "evo_adjust_loop_round",
            "project": project,
            "workspace": workspace,
            "loop_round_limit": max(1, loopRoundLimit)
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

    // MARK: - AI 代码补全

    /// 发送 AI 代码补全请求（流式）
    func requestAICodeCompletion(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        requestId: String,
        language: String,
        prefix: String,
        suffix: String? = nil,
        filePath: String? = nil,
        cursorLine: Int? = nil,
        cursorColumn: Int? = nil,
        triggerKind: String = "auto"
    ) {
        var request: [String: Any] = [
            "request_id": requestId,
            "language": language,
            "prefix": prefix,
            "trigger_kind": triggerKind
        ]
        if let suffix { request["suffix"] = suffix }
        if let filePath { request["file_path"] = filePath }
        if let cursorLine { request["cursor_line"] = cursorLine }
        if let cursorColumn { request["cursor_column"] = cursorColumn }

        send([
            "type": "ai_code_completion",
            "project_name": projectName,
            "workspace_name": workspaceName,
            "ai_tool": aiTool.rawValue,
            "request": request
        ])
    }

    /// 取消正在进行的 AI 代码补全请求
    func requestAICodeCompletionAbort(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        requestId: String
    ) {
        send([
            "type": "ai_code_completion_abort",
            "project_name": projectName,
            "workspace_name": workspaceName,
            "ai_tool": aiTool.rawValue,
            "request_id": requestId
        ])
    }

    /// 请求工作区缓存可观测性快照（HTTP /api/v1/system/snapshot）
    /// 响应中的 `cache_metrics` 字段包含所有工作区的缓存指标，由 Core 权威计算。
    func requestSystemSnapshot() {
        requestReadViaHTTP(
            domain: "system",
            path: "/api/v1/system/snapshot",
            fallbackAction: "system_snapshot"
        )
    }

    // MARK: - v1.41: 系统健康诊断与自修复

    /// 上报客户端健康状态（含本地检测 incidents）
    func reportHealthStatus(
        clientSessionId: String,
        connectivity: ClientConnectivity,
        incidents: [HealthIncident] = [],
        context: HealthContext = .system
    ) {
        let incidentsJson = incidents.compactMap { incident -> [String: Any]? in
            guard let data = try? JSONEncoder().encode(incident),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return dict
        }
        send([
            "type": "health_report",
            "client_session_id": clientSessionId,
            "connectivity": connectivity.rawValue,
            "incidents": incidentsJson,
            "context": [
                "project": context.project as Any,
                "workspace": context.workspace as Any,
                "session_id": context.sessionId as Any,
                "cycle_id": context.cycleId as Any
            ],
            "reported_at": UInt64(Date().timeIntervalSince1970 * 1000)
        ])
    }

    /// 请求执行修复动作（含上下文，确保 project/workspace 边界）
    func requestHealthRepair(
        action: RepairActionKind,
        context: HealthContext,
        incidentId: String? = nil
    ) {
        let requestId = UUID().uuidString
        var requestDict: [String: Any] = [
            "request_id": requestId,
            "action": action.rawValue,
            "context": [
                "project": context.project as Any,
                "workspace": context.workspace as Any,
                "session_id": context.sessionId as Any,
                "cycle_id": context.cycleId as Any
            ]
        ]
        if let incidentId {
            requestDict["incident_id"] = incidentId
        }
        send([
            "type": "health_repair",
            "request": requestDict
        ])
    }
}
