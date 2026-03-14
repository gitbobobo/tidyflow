import Foundation

private enum CoreHTTPClientError: LocalizedError {
    case invalidBaseURL
    case invalidRequestURL
    case invalidResponse
    case invalidPayload
    case httpStatus(code: Int, message: String)

    public var errorDescription: String? {
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

    public static func baseURL(from wsURL: URL?) -> URL? {
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

    public static func fetchData(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem],
        token: String?,
        clientID: String?,
        deviceName: String?
    ) async throws -> Data {
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
        if let clientID, !clientID.isEmpty {
            request.setValue(clientID, forHTTPHeaderField: "X-TidyFlow-Client-ID")
        }
        if let deviceName, !deviceName.isEmpty {
            request.setValue(deviceName, forHTTPHeaderField: "X-TidyFlow-Device-Name")
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

        _ = try decodeHTTPResponseObject(from: data)
        return data
    }
}

private func decodeHTTPResponseObject(from data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CoreHTTPClientError.invalidPayload
    }
    return object
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
    public let requestID: String
    public let domain: String
    public let action: String
    public let payload: Payload
    public let clientTs: UInt64

    public enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case domain
        case action
        case payload
        case clientTs = "client_ts"
    }
}

private struct EmptyTypedWSRequest: TypedWSRequest {
    private let requestAction: String

    public var action: String { requestAction }

    public init(action: String) {
        self.requestAction = action
    }

    private enum CodingKeys: CodingKey {}
}

private struct ProjectTypedWSRequest: TypedWSRequest {
    private let requestAction: String
    public let project: String

    public var action: String { requestAction }
    public var validationProject: String? { project }

    public init(action: String, project: String) {
        self.requestAction = action
        self.project = project
    }

    private enum CodingKeys: String, CodingKey {
        case project
    }
}

private struct ProjectWorkspaceTypedWSRequest: TypedWSRequest {
    private let requestAction: String
    public let project: String
    public let workspace: String

    public var action: String { requestAction }
    public var validationProject: String? { project }
    public var validationWorkspace: String? { workspace }

    public init(action: String, project: String, workspace: String) {
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
    public let project: String
    public let workspace: String
    public let path: String

    public var action: String { requestAction }
    public var validationProject: String? { project }
    public var validationWorkspace: String? { workspace }

    public init(action: String, project: String, workspace: String, path: String) {
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
    public let project: String
    public let workspace: String
    public let path: String
    public let context: String

    public var action: String { requestAction }
    public var validationProject: String? { project }
    public var validationWorkspace: String? { workspace }

    public init(action: String, project: String, workspace: String, path: String, context: String) {
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
    public let termID: String

    public var action: String { requestAction }

    public init(action: String, termID: String) {
        self.requestAction = action
        self.termID = termID
    }

    private enum CodingKeys: String, CodingKey {
        case termID = "term_id"
    }
}

private struct FileIndexRequest: TypedWSRequest {
    public let project: String
    public let workspace: String
    public let query: String?

    public var action: String { "file_index" }
}

private struct FileListRequest: TypedWSRequest {
    public let project: String
    public let workspace: String
    public let path: String

    public var action: String { "file_list" }
}

private struct GitDiffRequest: TypedWSRequest {
    public let project: String
    public let workspace: String
    public let path: String
    public let mode: String

    public var action: String { "git_diff" }
}

private struct GitLogRequest: TypedWSRequest {
    public let project: String
    public let workspace: String
    public let limit: Int

    public var action: String { "git_log" }
}

private struct GitShowRequest: TypedWSRequest {
    public let project: String
    public let workspace: String
    public let sha: String

    public var action: String { "git_show" }
}

private struct GitStageRequest: TypedWSRequest {
    public let project: String
    public let workspace: String
    public let path: String?
    public let scope: String

    public var action: String { "git_stage" }
}

private struct GitUnstageRequest: TypedWSRequest {
    public let project: String
    public let workspace: String
    public let path: String?
    public let scope: String

    public var action: String { "git_unstage" }
}

private struct GitDiscardRequest: TypedWSRequest {
    public let project: String
    public let workspace: String
    public let path: String?
    public let scope: String
    public let includeUntracked: Bool?

    public var action: String { "git_discard" }

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
    public let project: String
    public let workspace: String
    public let branch: String

    public var action: String { requestAction }

    public init(action: String, project: String, workspace: String, branch: String) {
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
    public let project: String
    public let workspace: String
    public let message: String

    public var action: String { "git_commit" }
}

private struct GitAIMergeRequest: TypedWSRequest {
    public let project: String
    public let workspace: String
    public let aiAgent: String?
    public let defaultBranch: String?

    public var action: String { "git_ai_merge" }

    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
        case aiAgent = "ai_agent"
        case defaultBranch = "default_branch"
    }
}

private struct GitOntoBranchRequest: TypedWSRequest {
    private let requestAction: String
    public let project: String
    public let workspace: String
    public let ontoBranch: String

    public var action: String { requestAction }

    public init(action: String, project: String, workspace: String, ontoBranch: String) {
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
    public let project: String
    public let workspace: String
    public let defaultBranch: String

    public var action: String { requestAction }

    public init(action: String, project: String, workspace: String, defaultBranch: String) {
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
    public let name: String
    public let path: String

    public var action: String { "import_project" }
}

private struct ListWorkspacesRequest: TypedWSRequest {
    public let project: String

    public var action: String { "list_workspaces" }
}

private struct TermCreateRequest: TypedWSRequest {
    public let project: String
    public let workspace: String
    public let cols: Int?
    public let rows: Int?
    public let name: String?
    public let icon: String?

    public var action: String { "term_create" }
}

private struct TermOutputAckRequest: TypedWSRequest {
    public let termID: String
    public let bytes: Int

    public var action: String { "term_output_ack" }

    private enum CodingKeys: String, CodingKey {
        case termID = "term_id"
        case bytes
    }
}

private struct TerminalInputRequest: TypedWSRequest {
    public let termID: String
    public let data: [UInt8]

    public var action: String { "input" }

    private enum CodingKeys: String, CodingKey {
        case termID = "term_id"
        case data
    }
}

private struct TerminalResizeRequest: TypedWSRequest {
    public let termID: String
    public let cols: Int
    public let rows: Int

    public var action: String { "resize" }

    private enum CodingKeys: String, CodingKey {
        case termID = "term_id"
        case cols
        case rows
    }
}

private struct CreateWorkspaceRequest: TypedWSRequest {
    public let project: String
    public let fromBranch: String?
    public let templateID: String?

    public var action: String { "create_workspace" }

    private enum CodingKeys: String, CodingKey {
        case project
        case fromBranch = "from_branch"
        case templateID = "template_id"
    }
}

private struct NameRequest: TypedWSRequest {
    private let requestAction: String
    public let name: String

    public var action: String { requestAction }

    public init(action: String, name: String) {
        self.requestAction = action
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case name
    }
}

private struct FileRenameRequest: TypedWSRequest {
    public let project: String
    public let workspace: String
    public let oldPath: String
    public let newName: String

    public var action: String { "file_rename" }

    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
        case oldPath = "old_path"
        case newName = "new_name"
    }
}

private struct FileCopyRequest: TypedWSRequest {
    public let destProject: String
    public let destWorkspace: String
    public let sourceAbsolutePath: String
    public let destDir: String

    public var action: String { "file_copy" }

    private enum CodingKeys: String, CodingKey {
        case destProject = "dest_project"
        case destWorkspace = "dest_workspace"
        case sourceAbsolutePath = "source_absolute_path"
        case destDir = "dest_dir"
    }
}

private struct FileMoveRequest: TypedWSRequest {
    public let project: String
    public let workspace: String
    public let oldPath: String
    public let newDir: String

    public var action: String { "file_move" }

    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
        case oldPath = "old_path"
        case newDir = "new_dir"
    }
}

private struct FileWriteRequest: TypedWSRequest {
    public let project: String
    public let workspace: String
    public let path: String
    public let content: [UInt8]

    public var action: String { "file_write" }
}

private struct RunProjectCommandRequest: TypedWSRequest {
    public let project: String
    public let workspace: String
    public let commandID: String

    public var action: String { "run_project_command" }

    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
        case commandID = "command_id"
    }
}

private struct CancelProjectCommandRequest: TypedWSRequest {
    public let project: String
    public let workspace: String
    public let commandID: String
    public let taskID: String?

    public var action: String { "cancel_project_command" }

    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
        case commandID = "command_id"
        case taskID = "task_id"
    }
}

private struct TemplateIDRequest: TypedWSRequest {
    private let requestAction: String
    public let templateID: String

    public var action: String { requestAction }

    public init(action: String, templateID: String) {
        self.requestAction = action
        self.templateID = templateID
    }

    private enum CodingKeys: String, CodingKey {
        case templateID = "template_id"
    }
}

private struct CancelAITaskRequest: TypedWSRequest {
    public let project: String
    public let workspace: String
    public let operationType: String

    public var action: String { "cancel_ai_task" }

    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
        case operationType = "operation_type"
    }
}

private struct ClipboardImageUploadRequest: TypedWSRequest {
    public let imageData: Data

    public var action: String { "clipboard_image_upload" }

    private enum CodingKeys: String, CodingKey {
        case imageData = "image_data"
    }
}

private struct GetClientSettingsRequest: TypedWSRequest {
    public var action: String { "get_client_settings" }
}

private struct SaveClientSettingsRequest: TypedWSRequest {
    public var action: String { "save_client_settings" }
    public let customCommands: [CustomCommandPayload]
    public let workspaceShortcuts: [String: String]
    public let mergeAIAgent: String?
    public let fixedPort: Int
    public let remoteAccessEnabled: Bool
    public let nodeName: String?
    public let nodeDiscoveryEnabled: Bool
    public let evolutionDefaultProfiles: [EvolutionStageProfilePayload]
    public let workspaceTodos: [String: [WorkspaceTodoPayload]]
    public let keybindings: [KeybindingPayload]

    public struct CustomCommandPayload: Encodable {
        let id: String
        let name: String
        let icon: String
        let command: String
    }

    public struct WorkspaceTodoPayload: Encodable {
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

    public struct EvolutionModelSelectionPayload: Encodable {
        let providerID: String
        let modelID: String

        enum CodingKeys: String, CodingKey {
            case providerID = "provider_id"
            case modelID = "model_id"
        }
    }

    public struct EvolutionStageProfilePayload: Encodable {
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

    public struct KeybindingPayload: Encodable {
        let commandId: String
        let keyCombination: String
        let context: String

        enum CodingKeys: String, CodingKey {
            case commandId, keyCombination, context
        }
    }

    public enum CodingKeys: String, CodingKey {
        case customCommands = "custom_commands"
        case workspaceShortcuts = "workspace_shortcuts"
        case mergeAIAgent = "merge_ai_agent"
        case fixedPort = "fixed_port"
        case remoteAccessEnabled = "remote_access_enabled"
        case nodeName = "node_name"
        case nodeDiscoveryEnabled = "node_discovery_enabled"
        case evolutionDefaultProfiles = "evolution_default_profiles"
        case workspaceTodos = "workspace_todos"
        case keybindings
    }
}

private struct NodeUpdateProfileRequest: TypedWSRequest {
    public let nodeName: String?
    public let discoveryEnabled: Bool

    public var action: String { "node_update_profile" }

    private enum CodingKeys: String, CodingKey {
        case nodeName = "node_name"
        case discoveryEnabled = "discovery_enabled"
    }
}

private struct NodePairPeerRequest: TypedWSRequest {
    public let host: String
    public let port: Int
    public let pairKey: String

    public var action: String { "node_pair_peer" }

    private enum CodingKeys: String, CodingKey {
        case host
        case port
        case pairKey = "pair_key"
    }
}

private struct NodeUnpairPeerRequest: TypedWSRequest {
    public let peerNodeID: String

    public var action: String { "node_unpair_peer" }

    private enum CodingKeys: String, CodingKey {
        case peerNodeID = "peer_node_id"
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
        ("node", "node_refresh_network"),
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
        ("node", "node_"),
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
    public func sendBinary(_ data: Data) {
        guard isConnected else {
            CoreWSLog.ws.warning("Cannot send - not connected")
            emitClientError("Not connected")
            return
        }

        webSocketTask?.send(.data(data)) { [weak self] error in
            if let error = error {
                CoreWSLog.ws.error("Send failed: \(error.localizedDescription, privacy: .public)")
                self?.emitClientError("Send failed: \(error.localizedDescription)")
            }
        }
    }

    /// 发送消息，使用 MessagePack 编码
    public func send(_ dict: [String: Any], requestId: String? = nil) {
        if let validationError = validateOutgoingMessage(dict) {
            CoreWSLog.ws.error("Drop outbound message: \(validationError, privacy: .public)")
            emitClientError(validationError)
            return
        }
        do {
            let data = try encodeEnvelope(dict: dict, requestId: requestId)
            sendBinary(data)
        } catch {
            CoreWSLog.ws.error("MessagePack encode failed: \(error.localizedDescription, privacy: .public)")
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
            CoreWSLog.ws.error("Drop outbound typed message: \(validationError, privacy: .public)")
            emitClientError(validationError)
            return
        }
        do {
            let data = try encodeTypedEnvelope(body, requestId: requestId)
            sendBinary(data)
        } catch {
            CoreWSLog.ws.error("MessagePack typed encode failed: \(error.localizedDescription, privacy: .public)")
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
        case "node":
            handled = handleNodeDomain(action, json: json)
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

    private func executeHTTPRead(
        key: HTTPQueryKey,
        policy: HTTPQueryPolicy,
        domain: String,
        path: String,
        queryItems: [URLQueryItem],
        fallbackAction: String,
        context: HTTPReadRequestContext?,
        baseURL: URL,
        token: String?,
        cacheMode: HTTPQueryCacheMode
    ) async {
        do {
            let data = try await httpQueryClient.fetch(
                key: key,
                policy: policy,
                force: cacheMode == .forceRefresh
            ) { [self] in
                onHTTPRequestScheduled?(domain, path, queryItems)
                if let httpReadFetcherOverride {
                    return try await httpReadFetcherOverride(
                        baseURL,
                        path,
                        queryItems,
                        token,
                        self.authClientID,
                        self.authDeviceName
                    )
                }
                return try await CoreHTTPClient.fetchData(
                    baseURL: baseURL,
                    path: path,
                    queryItems: queryItems,
                    token: token,
                    clientID: self.authClientID,
                    deviceName: self.authDeviceName
                )
            }
            let json = try decodeHTTPResponseObject(from: data)
            await handleHTTPReadResult(
                domain: domain,
                fallbackAction: fallbackAction,
                json: json,
                context: context
            )
        } catch {
            await handleHTTPReadError(error, context: context)
        }
    }

    private func requestReadViaHTTP(
        domain: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        fallbackAction: String,
        context: HTTPReadRequestContext? = nil,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        guard let baseURL = CoreHTTPClient.baseURL(from: currentURL) else {
            let message = CoreHTTPClientError.invalidBaseURL.localizedDescription
            onHTTPReadFailure?(HTTPReadFailure(context: context, message: message))
            emitClientError(message)
            return
        }
        let key = HTTPQueryKey(
            baseURL: baseURL,
            path: path,
            queryItems: queryItems,
            fallbackAction: fallbackAction
        )
        let policy = HTTPQueryClient.policy(forFallbackAction: fallbackAction)
        let token = wsAuthToken

        Task { [weak self] in
            guard let self else { return }
            if cacheMode == .default,
               let cached = await self.httpQueryClient.cachedValue(
                    for: key,
                    policy: policy,
                    mode: cacheMode
               ) {
                switch cached {
                case let .fresh(data):
                    do {
                        let json = try decodeHTTPResponseObject(from: data)
                        await self.handleHTTPReadResult(
                            domain: domain,
                            fallbackAction: fallbackAction,
                            json: json,
                            context: context
                        )
                    } catch {
                        await self.httpQueryClient.invalidate(key: key)
                        await self.handleHTTPReadError(error, context: context)
                    }
                    return
                case let .stale(data):
                    do {
                        let json = try decodeHTTPResponseObject(from: data)
                        await self.handleHTTPReadResult(
                            domain: domain,
                            fallbackAction: fallbackAction,
                            json: json,
                            context: context
                        )
                    } catch {
                        await self.httpQueryClient.invalidate(key: key)
                    }

                    await self.executeHTTPRead(
                        key: key,
                        policy: policy,
                        domain: domain,
                        path: path,
                        queryItems: queryItems,
                        fallbackAction: fallbackAction,
                        context: context,
                        baseURL: baseURL,
                        token: token,
                        cacheMode: .forceRefresh
                    )
                    return
                }
            }

            await self.executeHTTPRead(
                key: key,
                policy: policy,
                domain: domain,
                path: path,
                queryItems: queryItems,
                fallbackAction: fallbackAction,
                context: context,
                baseURL: baseURL,
                token: token,
                cacheMode: cacheMode
            )
        }
    }

    public enum HTTPQueryInvalidationScope {
        case fileWorkspace(project: String, workspace: String)
        case fileRead(project: String, workspace: String, path: String)
        case gitWorkspace(project: String, workspace: String)
        case gitProject(project: String)
        case aiWorkspace(project: String, workspace: String, aiTool: String? = nil)
        case evolutionWorkspace(project: String, workspace: String)
        case evidenceWorkspace(project: String, workspace: String)
    }

    public func invalidateHTTPQueries(_ scope: HTTPQueryInvalidationScope) {
        Task { [weak self] in
            guard let self else { return }
            await self.httpQueryClient.invalidate { key in
                switch scope {
                case let .fileWorkspace(project, workspace):
                    let prefix = "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/"
                    return key.path.hasPrefix(prefix) && (
                        key.fallbackAction == "file_index_result" ||
                        key.fallbackAction == "file_list_result"
                    )
                case let .fileRead(project, workspace, path):
                    let targetPath = "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/files/content"
                    return key.path == targetPath &&
                        key.fallbackAction == "file_read_result" &&
                        key.queryItems.contains { $0.name == "path" && $0.value == path }
                case let .gitWorkspace(project, workspace):
                    let prefix = "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/git/"
                    return key.path.hasPrefix(prefix)
                case let .gitProject(project):
                    let workspacePrefix = "/api/v1/projects/\(encodePathComponent(project))/workspaces/"
                    let integrationPrefix = "/api/v1/projects/\(encodePathComponent(project))/git/"
                    return (key.path.hasPrefix(workspacePrefix) && key.path.contains("/git/")) ||
                        key.path.hasPrefix(integrationPrefix)
                case let .aiWorkspace(project, workspace, aiTool):
                    let prefix = "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/ai/"
                    guard key.path.hasPrefix(prefix) else { return false }
                    guard let aiTool else { return true }
                    let encodedAITool = encodePathComponent(aiTool)
                    if key.path.contains("/ai/\(encodedAITool)/") {
                        return true
                    }
                    if key.fallbackAction == "ai_session_list" {
                        let listFilter = key.queryItems.first { $0.name == "ai_tool" }?.value
                        return listFilter == nil || listFilter == aiTool
                    }
                    return false
                case let .evolutionWorkspace(project, workspace):
                    let snapshotPath = "/api/v1/evolution/snapshot"
                    let workspacePrefix = "/api/v1/evolution/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/"
                    if key.path == snapshotPath {
                        let projectMatch = key.queryItems.contains {
                            $0.name == "project" && $0.value == project
                        }
                        let workspaceMatch = key.queryItems.contains {
                            $0.name == "workspace" && $0.value == workspace
                        }
                        return projectMatch && workspaceMatch
                    }
                    return key.path.hasPrefix(workspacePrefix)
                case let .evidenceWorkspace(project, workspace):
                    let prefix = "/api/v1/evidence/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/"
                    return key.path.hasPrefix(prefix)
                }
            }
        }
    }

    public func requestFileIndex(
        project: String,
        workspace: String,
        query: String? = nil,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        let path = "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/files/index"
        let queryItems = query.map { [URLQueryItem(name: "query", value: $0)] } ?? []
        requestReadViaHTTP(
            domain: "file",
            path: path,
            queryItems: queryItems,
            fallbackAction: "file_index_result",
            cacheMode: cacheMode
        )
    }

    /// 请求文件列表（目录浏览）
    public func requestFileList(
        project: String,
        workspace: String,
        path: String = ".",
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        requestReadViaHTTP(
            domain: "file",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/files",
            queryItems: [URLQueryItem(name: "path", value: path)],
            fallbackAction: "file_list_result",
            cacheMode: cacheMode
        )
    }

    /// 请求读取文件内容（文本/二进制）
    public func requestFileRead(
        project: String,
        workspace: String,
        path: String,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        requestReadViaHTTP(
            domain: "file",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/files/content",
            queryItems: [URLQueryItem(name: "path", value: path)],
            fallbackAction: "file_read_result",
            context: .fileRead(project: project, workspace: workspace, path: path),
            cacheMode: cacheMode
        )
    }

    // Phase C2-2a: Request git diff
    public func requestGitDiff(
        project: String,
        workspace: String,
        path: String,
        mode: String,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        requestReadViaHTTP(
            domain: "git",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/git/diff",
            queryItems: [
                URLQueryItem(name: "path", value: path),
                URLQueryItem(name: "mode", value: mode)
            ],
            fallbackAction: "git_diff_result",
            cacheMode: cacheMode
        )
    }

    // Phase C3-1: Request git status
    public func requestGitStatus(
        project: String,
        workspace: String,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        requestReadViaHTTP(
            domain: "git",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/git/status",
            fallbackAction: "git_status_result",
            cacheMode: cacheMode
        )
    }

    // Git Log: Request commit history
    public func requestGitLog(
        project: String,
        workspace: String,
        limit: Int = 50,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        requestReadViaHTTP(
            domain: "git",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/git/log",
            queryItems: [URLQueryItem(name: "limit", value: "\(limit)")],
            fallbackAction: "git_log_result",
            cacheMode: cacheMode
        )
    }

    // Git Show: Request single commit details
    public func requestGitShow(
        project: String,
        workspace: String,
        sha: String,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        requestReadViaHTTP(
            domain: "git",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/git/commits/\(encodePathComponent(sha))",
            fallbackAction: "git_show_result",
            cacheMode: cacheMode
        )
    }

    // Phase C3-2a: Request git stage
    public func requestGitStage(project: String, workspace: String, path: String?, scope: String) {
        sendTyped(GitStageRequest(project: project, workspace: workspace, path: path, scope: scope))
    }

    // Phase C3-2a: Request git unstage
    public func requestGitUnstage(project: String, workspace: String, path: String?, scope: String) {
        sendTyped(GitUnstageRequest(project: project, workspace: workspace, path: path, scope: scope))
    }

    // Phase C3-2b: Request git discard
    public func requestGitDiscard(project: String, workspace: String, path: String?, scope: String, includeUntracked: Bool = false) {
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
    public func requestGitBranches(
        project: String,
        workspace: String,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        requestReadViaHTTP(
            domain: "git",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/git/branches",
            fallbackAction: "git_branches_result",
            cacheMode: cacheMode
        )
    }

    // Phase C3-3a: Request git switch branch
    public func requestGitSwitchBranch(project: String, workspace: String, branch: String) {
        sendTyped(GitBranchRequest(action: "git_switch_branch", project: project, workspace: workspace, branch: branch))
    }

    // Phase C3-3b: Request git create branch
    public func requestGitCreateBranch(project: String, workspace: String, branch: String) {
        sendTyped(GitBranchRequest(action: "git_create_branch", project: project, workspace: workspace, branch: branch))
    }

    // Phase C3-4a: Request git commit
    public func requestGitCommit(project: String, workspace: String, message: String) {
        sendTyped(GitCommitRequest(project: project, workspace: workspace, message: message))
    }

    /// Evolution AutoCommit 独立执行
    public func requestEvoAutoCommit(project: String, workspace: String) {
        sendTyped(ProjectWorkspaceTypedWSRequest(action: "evo_auto_commit", project: project, workspace: workspace))
    }

    /// AI 智能合并到默认分支（v1.33）
    public func requestGitAIMerge(project: String, workspace: String, aiAgent: String? = nil, defaultBranch: String? = nil) {
        sendTyped(GitAIMergeRequest(project: project, workspace: workspace, aiAgent: aiAgent, defaultBranch: defaultBranch))
    }

    // Phase UX-3a: Request git fetch
    public func requestGitFetch(project: String, workspace: String) {
        sendTyped(ProjectWorkspaceTypedWSRequest(action: "git_fetch", project: project, workspace: workspace))
    }

    // Phase UX-3a: Request git rebase
    public func requestGitRebase(project: String, workspace: String, ontoBranch: String) {
        sendTyped(GitOntoBranchRequest(action: "git_rebase", project: project, workspace: workspace, ontoBranch: ontoBranch))
    }

    // Phase UX-3a: Request git rebase continue
    public func requestGitRebaseContinue(project: String, workspace: String) {
        sendTyped(ProjectWorkspaceTypedWSRequest(action: "git_rebase_continue", project: project, workspace: workspace))
    }

    // Phase UX-3a: Request git rebase abort
    public func requestGitRebaseAbort(project: String, workspace: String) {
        sendTyped(ProjectWorkspaceTypedWSRequest(action: "git_rebase_abort", project: project, workspace: workspace))
    }

    // Phase UX-3a: Request git operation status
    public func requestGitOpStatus(
        project: String,
        workspace: String,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        requestReadViaHTTP(
            domain: "git",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/git/op-status",
            fallbackAction: "git_op_status_result",
            cacheMode: cacheMode
        )
    }

    // Phase UX-3b: Request git merge to default
    public func requestGitMergeToDefault(project: String, workspace: String, defaultBranch: String) {
        sendTyped(GitDefaultBranchRequest(action: "git_merge_to_default", project: project, workspace: workspace, defaultBranch: defaultBranch))
    }

    // Phase UX-3b: Request git merge continue
    public func requestGitMergeContinue(project: String) {
        sendTyped(ProjectTypedWSRequest(action: "git_merge_continue", project: project))
    }

    // Phase UX-3b: Request git merge abort
    public func requestGitMergeAbort(project: String) {
        sendTyped(ProjectTypedWSRequest(action: "git_merge_abort", project: project))
    }

    // Phase UX-3b: Request git integration status
    public func requestGitIntegrationStatus(project: String, cacheMode: HTTPQueryCacheMode = .default) {
        requestReadViaHTTP(
            domain: "git",
            path: "/api/v1/projects/\(encodePathComponent(project))/git/integration-status",
            fallbackAction: "git_integration_status_result",
            cacheMode: cacheMode
        )
    }

    // Phase UX-4: Request git rebase onto default
    public func requestGitRebaseOntoDefault(project: String, workspace: String, defaultBranch: String) {
        sendTyped(GitDefaultBranchRequest(action: "git_rebase_onto_default", project: project, workspace: workspace, defaultBranch: defaultBranch))
    }

    // Phase UX-4: Request git rebase onto default continue
    public func requestGitRebaseOntoDefaultContinue(project: String) {
        sendTyped(ProjectTypedWSRequest(action: "git_rebase_onto_default_continue", project: project))
    }

    // Phase UX-4: Request git rebase onto default abort
    public func requestGitRebaseOntoDefaultAbort(project: String) {
        sendTyped(ProjectTypedWSRequest(action: "git_rebase_onto_default_abort", project: project))
    }

    // Phase UX-5: Request git reset integration worktree
    public func requestGitResetIntegrationWorktree(project: String) {
        sendTyped(ProjectTypedWSRequest(action: "git_reset_integration_worktree", project: project))
    }

    // Phase UX-6: Request git check branch up to date
    public func requestGitCheckBranchUpToDate(
        project: String,
        workspace: String,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        requestReadViaHTTP(
            domain: "git",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/git/up-to-date",
            fallbackAction: "git_integration_status_result",
            cacheMode: cacheMode
        )
    }

    // v1.40: 冲突向导请求方法

    /// 读取单文件四路对比内容
    public func requestGitConflictDetail(
        project: String,
        workspace: String,
        path: String,
        context: String,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        requestReadViaHTTP(
            domain: "git",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/git/conflicts/detail",
            queryItems: [
                URLQueryItem(name: "path", value: path),
                URLQueryItem(name: "context", value: context)
            ],
            fallbackAction: "git_conflict_detail_result",
            cacheMode: cacheMode
        )
    }

    /// 接受我方版本（ours）解决冲突
    public func requestGitConflictAcceptOurs(project: String, workspace: String, path: String, context: String) {
        sendTyped(ProjectWorkspacePathContextTypedWSRequest(action: "git_conflict_accept_ours", project: project, workspace: workspace, path: path, context: context))
    }

    /// 接受对方版本（theirs）解决冲突
    public func requestGitConflictAcceptTheirs(project: String, workspace: String, path: String, context: String) {
        sendTyped(ProjectWorkspacePathContextTypedWSRequest(action: "git_conflict_accept_theirs", project: project, workspace: workspace, path: path, context: context))
    }

    /// 保留双方内容（both）解决冲突
    public func requestGitConflictAcceptBoth(project: String, workspace: String, path: String, context: String) {
        sendTyped(ProjectWorkspacePathContextTypedWSRequest(action: "git_conflict_accept_both", project: project, workspace: workspace, path: path, context: context))
    }

    /// 手动标记文件已解决
    public func requestGitConflictMarkResolved(project: String, workspace: String, path: String, context: String) {
        sendTyped(ProjectWorkspacePathContextTypedWSRequest(action: "git_conflict_mark_resolved", project: project, workspace: workspace, path: path, context: context))
    }

    // UX-2: Request import project
    public func requestImportProject(name: String, path: String) {
        sendTyped(ImportProjectRequest(name: name, path: path))
    }

    // UX-2: Request list projects
    public func requestListProjects(cacheMode: HTTPQueryCacheMode = .default) {
        requestReadViaHTTP(
            domain: "project",
            path: "/api/v1/projects",
            fallbackAction: "projects",
            cacheMode: cacheMode
        )
    }

    // Request list workspaces
    public func requestListWorkspaces(project: String, cacheMode: HTTPQueryCacheMode = .default) {
        requestReadViaHTTP(
            domain: "project",
            path: "/api/v1/projects/\(encodePathComponent(project))/workspaces",
            fallbackAction: "workspaces",
            cacheMode: cacheMode
        )
    }

    // MARK: - 终端会话（供 iOS / 远程客户端复用）

    /// 创建终端（基于项目与工作空间），可附带初始尺寸和展示信息
    public func requestTermCreate(project: String, workspace: String, cols: Int? = nil, rows: Int? = nil, name: String? = nil, icon: String? = nil) {
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
    public func requestTermList(cacheMode: HTTPQueryCacheMode = .default) {
        requestReadViaHTTP(
            domain: "terminal",
            path: "/api/v1/terminals",
            fallbackAction: "term_list",
            cacheMode: cacheMode
        )
    }

    /// 关闭终端
    public func requestTermClose(termId: String) {
        sendTyped(TermIDTypedWSRequest(action: "term_close", termID: termId))
    }

    /// 附着已存在终端（重连场景）
    public func requestTermAttach(termId: String) {
        sendTyped(TermIDTypedWSRequest(action: "term_attach", termID: termId))
    }

    /// 取消当前 WS 连接对该终端的输出订阅（不关闭 PTY）
    public func requestTermDetach(termId: String) {
        sendTyped(TermIDTypedWSRequest(action: "term_detach", termID: termId))
    }

    /// 终端输出流控 ACK：通知 Core 已消费指定字节数，释放背压
    public func sendTermOutputAck(termId: String, bytes: Int) {
        sendTyped(TermOutputAckRequest(termID: termId, bytes: bytes))
    }

    /// 发送终端输入（二进制字节）
    public func sendTerminalInput(_ bytes: [UInt8], termId: String) {
        sendTyped(TerminalInputRequest(termID: termId, data: bytes))
    }

    /// 发送终端输入（UTF-8 文本）
    public func sendTerminalInput(_ text: String, termId: String) {
        sendTerminalInput(Array(text.utf8), termId: termId)
    }

    /// 发送终端 resize
    public func requestTermResize(termId: String, cols: Int, rows: Int) {
        sendTyped(TerminalResizeRequest(termID: termId, cols: cols, rows: rows))
    }

    // UX-2: Request create workspace（名称由 Core 用 petname 生成）
    public func requestCreateWorkspace(project: String, fromBranch: String? = nil, templateId: String? = nil) {
        sendTyped(CreateWorkspaceRequest(project: project, fromBranch: fromBranch, templateID: templateId))
    }

    // Remove project
    public func requestRemoveProject(name: String) {
        sendTyped(NameRequest(action: "remove_project", name: name))
    }

    // Remove workspace
    public func requestRemoveWorkspace(project: String, workspace: String) {
        sendTyped(ProjectWorkspaceTypedWSRequest(action: "remove_workspace", project: project, workspace: workspace))
    }

    // MARK: - 客户端设置

    /// 请求获取客户端设置
    public func requestGetClientSettings(cacheMode: HTTPQueryCacheMode = .default) {
        requestReadViaHTTP(
            domain: "settings",
            path: "/api/v1/client-settings",
            fallbackAction: "client_settings_result",
            cacheMode: cacheMode
        )
    }

    /// 保存客户端设置
    public func requestSaveClientSettings(settings: ClientSettings) {
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
            nodeName: settings.nodeName,
            nodeDiscoveryEnabled: settings.nodeDiscoveryEnabled,
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

    // MARK: - Node Network

    public func requestNodeSelf(cacheMode: HTTPQueryCacheMode = .default) {
        requestReadViaHTTP(
            domain: "node",
            path: "/api/v1/node/self",
            fallbackAction: "node_self_updated",
            cacheMode: cacheMode
        )
    }

    public func requestNodeDiscovery(cacheMode: HTTPQueryCacheMode = .default) {
        requestReadViaHTTP(
            domain: "node",
            path: "/api/v1/node/discovery",
            fallbackAction: "node_discovery_updated",
            cacheMode: cacheMode
        )
    }

    public func requestNodeNetwork(cacheMode: HTTPQueryCacheMode = .default) {
        requestReadViaHTTP(
            domain: "node",
            path: "/api/v1/node/network",
            fallbackAction: "node_network_updated",
            cacheMode: cacheMode
        )
    }

    public func requestNodeUpdateProfile(nodeName: String?, discoveryEnabled: Bool) {
        sendTyped(
            NodeUpdateProfileRequest(
                nodeName: nodeName,
                discoveryEnabled: discoveryEnabled
            )
        )
    }

    public func requestNodePairPeer(host: String, port: Int, pairKey: String) {
        sendTyped(NodePairPeerRequest(host: host, port: port, pairKey: pairKey))
    }

    public func requestNodeUnpairPeer(peerNodeID: String) {
        sendTyped(NodeUnpairPeerRequest(peerNodeID: peerNodeID))
    }

    public func requestNodeRefreshNetwork() {
        sendTyped(EmptyTypedWSRequest(action: "node_refresh_network"))
    }

    // MARK: - v1.22: 文件监控

    /// 订阅工作空间文件监控
    public func requestWatchSubscribe(project: String, workspace: String) {
        sendTyped(ProjectWorkspaceTypedWSRequest(action: "watch_subscribe", project: project, workspace: workspace))
    }

    /// 取消文件监控订阅
    public func requestWatchUnsubscribe() {
        sendTyped(EmptyTypedWSRequest(action: "watch_unsubscribe"))
    }

    // MARK: - v1.xx: AI 会话订阅

    /// 订阅 AI 会话消息
    public func requestAISessionSubscribe(project: String, workspace: String, aiTool: String, sessionId: String) {
        send([
            "type": "ai_session_subscribe",
            "project_name": project,
            "workspace_name": workspace,
            "ai_tool": aiTool,
            "session_id": sessionId,
        ])
    }

    /// 取消 AI 会话订阅
    public func requestAISessionUnsubscribe(project: String, workspace: String, aiTool: String, sessionId: String) {
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
    public func requestFileRename(project: String, workspace: String, oldPath: String, newName: String) {
        sendTyped(FileRenameRequest(project: project, workspace: workspace, oldPath: oldPath, newName: newName))
    }

    /// 请求删除文件或目录（移到回收站）
    public func requestFileDelete(project: String, workspace: String, path: String) {
        sendTyped(ProjectWorkspacePathTypedWSRequest(action: "file_delete", project: project, workspace: workspace, path: path))
    }

    // MARK: - v1.24: 文件复制

    /// 请求复制文件或目录（使用绝对路径）
    public func requestFileCopy(destProject: String, destWorkspace: String, sourceAbsolutePath: String, destDir: String) {
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
    public func requestFileMove(project: String, workspace: String, oldPath: String, newDir: String) {
        sendTyped(FileMoveRequest(project: project, workspace: workspace, oldPath: oldPath, newDir: newDir))
    }

    // MARK: - 文件写入（新建文件）

    /// 请求写入文件（用于新建空文件）
    public func requestFileWrite(project: String, workspace: String, path: String, content: Data) {
        sendTyped(FileWriteRequest(project: project, workspace: workspace, path: path, content: [UInt8](content)))
    }

    // MARK: - v1.29: 项目命令

    /// 保存项目命令配置
    public func requestSaveProjectCommands(project: String, commands: [ProjectCommand]) {
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
    public func requestRunProjectCommand(project: String, workspace: String, commandId: String) {
        sendTyped(RunProjectCommandRequest(project: project, workspace: workspace, commandID: commandId))
    }

    /// 取消正在运行的项目命令
    public func requestCancelProjectCommand(
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
    public func requestListTemplates(cacheMode: HTTPQueryCacheMode = .default) {
        requestReadViaHTTP(
            domain: "project",
            path: "/api/v1/templates",
            fallbackAction: "templates",
            cacheMode: cacheMode
        )
    }

    /// 保存（新增或更新）工作流模板
    public func requestSaveTemplate(_ template: TemplateInfo) {
        send([
            "type": "save_template",
            "template": template.toDict()
        ])
    }

    /// 删除工作流模板
    public func requestDeleteTemplate(templateId: String) {
        sendTyped(TemplateIDRequest(action: "delete_template", templateID: templateId))
    }

    /// 导出工作流模板（服务端返回完整模板数据）
    public func requestExportTemplate(templateId: String, cacheMode: HTTPQueryCacheMode = .default) {
        requestReadViaHTTP(
            domain: "project",
            path: "/api/v1/templates/\(encodePathComponent(templateId))/export",
            fallbackAction: "template_exported",
            cacheMode: cacheMode
        )
    }

    /// 导入工作流模板
    public func requestImportTemplate(_ template: TemplateInfo) {
        send([
            "type": "import_template",
            "template": template.toDict()
        ])
    }

    // MARK: - v1.37: 取消 AI 任务

    /// 取消正在运行的 AI 任务
    public func requestCancelAITask(project: String, workspace: String, operationType: String) {
        sendTyped(CancelAITaskRequest(project: project, workspace: workspace, operationType: operationType))
    }

    // MARK: - v1.39: 剪贴板图片上传

    /// 上传剪贴板图片到服务端（转 JPG 写入 macOS 系统剪贴板）
    public func sendClipboardImageUpload(imageData: [UInt8]) {
        sendTyped(ClipboardImageUploadRequest(imageData: Data(imageData)))
    }

    // MARK: - 任务历史

    /// 请求任务快照（用于移动端重连后恢复后台任务状态）
    public func requestListTasks(cacheMode: HTTPQueryCacheMode = .default) {
        requestReadViaHTTP(
            domain: "project",
            path: "/api/v1/tasks",
            fallbackAction: "tasks_snapshot",
            cacheMode: cacheMode
        )
    }

    // MARK: - AI Chat（结构化 message/part 流）

    /// 开始新的 AI 聊天会话
    public func requestAIChatStart(
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
    public func requestAIChatSend(
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
        invalidateHTTPQueries(.aiWorkspace(
            project: projectName,
            workspace: workspaceName,
            aiTool: aiTool.rawValue
        ))
    }

    /// 发送 AI 斜杠命令（OpenCode session.command）
    public func requestAIChatCommand(
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
    public func requestAIChatAbort(
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
    public func requestAIQuestionReply(
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
        invalidateHTTPQueries(.aiWorkspace(
            project: projectName,
            workspace: workspaceName,
            aiTool: aiTool.rawValue
        ))
    }

    /// 拒绝 AI question 请求
    public func requestAIQuestionReject(
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
        invalidateHTTPQueries(.aiWorkspace(
            project: projectName,
            workspace: workspaceName,
            aiTool: aiTool.rawValue
        ))
    }

    /// 获取 AI 会话列表
    public func requestAISessionList(
        projectName: String,
        workspaceName: String,
        filter: AIChatTool? = nil,
        cursor: String? = nil,
        limit: Int? = 50,
        cacheMode: HTTPQueryCacheMode = .default
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
            fallbackAction: "ai_session_list",
            cacheMode: cacheMode
        )
    }

    /// 获取 AI 会话历史消息
    public func requestAISessionMessages(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String,
        limit: Int? = nil,
        beforeMessageId: String? = nil,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        let normalizedBefore = beforeMessageId?.trimmingCharacters(in: .whitespacesAndNewlines)
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
            fallbackAction: "ai_session_messages",
            cacheMode: cacheMode
        )
    }

    /// 查询 AI 会话状态（idle/busy/error）
    public func requestAISessionStatus(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        let path = "/api/v1/projects/\(encodePathComponent(projectName))/workspaces/\(encodePathComponent(workspaceName))/ai/\(encodePathComponent(aiTool.rawValue))/sessions/\(encodePathComponent(sessionId))/status"
        requestReadViaHTTP(
            domain: "ai",
            path: path,
            fallbackAction: "ai_session_status_result",
            cacheMode: cacheMode
        )
    }

    /// 删除 AI 会话
    public func requestAISessionDelete(
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
        invalidateHTTPQueries(.aiWorkspace(
            project: projectName,
            workspace: workspaceName,
            aiTool: aiTool.rawValue
        ))
    }

    public func requestAISessionRename(project: String, workspace: String, aiTool: String, sessionId: String, newTitle: String) {
        send([
            "type": "ai_session_rename",
            "project_name": project,
            "workspace_name": workspace,
            "ai_tool": aiTool,
            "session_id": sessionId,
            "new_title": newTitle
        ])
        invalidateHTTPQueries(.aiWorkspace(project: project, workspace: workspace, aiTool: aiTool))
    }

    public func requestAISessionSearch(project: String, workspace: String, aiTool: String, query: String, limit: Int? = nil) {
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

    public func requestAICodeReview(project: String, workspace: String, aiTool: String, diffText: String, filePaths: [String] = [], sessionId: String? = nil) {
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
    public func requestAIProviderList(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        let path = "/api/v1/projects/\(encodePathComponent(projectName))/workspaces/\(encodePathComponent(workspaceName))/ai/\(encodePathComponent(aiTool.rawValue))/providers"
        requestReadViaHTTP(
            domain: "ai",
            path: path,
            fallbackAction: "ai_provider_list",
            context: .aiProviderList(project: projectName, workspace: workspaceName, aiTool: aiTool),
            cacheMode: cacheMode
        )
    }

    /// 获取 AI Agent 列表
    public func requestAIAgentList(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        let path = "/api/v1/projects/\(encodePathComponent(projectName))/workspaces/\(encodePathComponent(workspaceName))/ai/\(encodePathComponent(aiTool.rawValue))/agents"
        requestReadViaHTTP(
            domain: "ai",
            path: path,
            fallbackAction: "ai_agent_list",
            context: .aiAgentList(project: projectName, workspace: workspaceName, aiTool: aiTool),
            cacheMode: cacheMode
        )
    }

    /// 获取 AI 斜杠命令列表
    public func requestAISlashCommands(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String? = nil,
        cacheMode: HTTPQueryCacheMode = .default
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
            fallbackAction: "ai_slash_commands",
            cacheMode: cacheMode
        )
    }

    /// 获取会话配置选项（ACP session-config-options）
    public func requestAISessionConfigOptions(
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        sessionId: String? = nil,
        cacheMode: HTTPQueryCacheMode = .default
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
            fallbackAction: "ai_session_config_options",
            cacheMode: cacheMode
        )
    }

    /// 设置会话配置选项（ACP session/set_config_option）
    public func requestAISessionSetConfigOption(
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
        invalidateHTTPQueries(.aiWorkspace(
            project: projectName,
            workspace: workspaceName,
            aiTool: aiTool.rawValue
        ))
    }

    // MARK: - Evolution

    /// 手动启动工作空间的自主进化流程（可配置总循环轮次）
    public func requestEvoStartWorkspace(
        project: String,
        workspace: String,
        priority: Int = 0,
        loopRoundLimit: Int? = nil,
        stageProfiles: [EvolutionStageProfileInfoV2] = []
    ) {
        let normalizedProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWorkspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProject.isEmpty, !normalizedWorkspace.isEmpty else {
            CoreWSLog.ws.error(
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
        invalidateHTTPQueries(.evolutionWorkspace(project: normalizedProject, workspace: normalizedWorkspace))
    }

    public func requestEvoStopWorkspace(project: String, workspace: String, reason: String? = nil) {
        var msg: [String: Any] = [
            "type": "evo_stop_workspace",
            "project": project,
            "workspace": workspace
        ]
        if let reason, !reason.isEmpty {
            msg["reason"] = reason
        }
        send(msg)
        invalidateHTTPQueries(.evolutionWorkspace(project: project, workspace: workspace))
    }

    public func requestEvoStopAll(reason: String? = nil) {
        var msg: [String: Any] = ["type": "evo_stop_all"]
        if let reason, !reason.isEmpty {
            msg["reason"] = reason
        }
        send(msg)
    }

    public func requestEvoResumeWorkspace(project: String, workspace: String) {
        send([
            "type": "evo_resume_workspace",
            "project": project,
            "workspace": workspace
        ])
        invalidateHTTPQueries(.evolutionWorkspace(project: project, workspace: workspace))
    }

    public func requestEvoAdjustLoopRound(project: String, workspace: String, loopRoundLimit: Int) {
        send([
            "type": "evo_adjust_loop_round",
            "project": project,
            "workspace": workspace,
            "loop_round_limit": max(1, loopRoundLimit)
        ])
    }

    public func requestEvoResolveBlockers(
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
        invalidateHTTPQueries(.evolutionWorkspace(project: project, workspace: workspace))
    }

    public func requestEvoSnapshot(
        project: String? = nil,
        workspace: String? = nil,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
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
            fallbackAction: "evo_snapshot",
            cacheMode: cacheMode
        )
    }

    public func requestEvoUpdateAgentProfile(project: String, workspace: String, stageProfiles: [EvolutionStageProfileInfoV2]) {
        send([
            "type": "evo_update_agent_profile",
            "project": project,
            "workspace": workspace,
            "stage_profiles": stageProfiles.map { $0.toJSON() }
        ])
        invalidateHTTPQueries(.evolutionWorkspace(project: project, workspace: workspace))
    }

    public func requestEvoGetAgentProfile(
        project: String,
        workspace: String,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        let path = "/api/v1/evolution/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/agent-profile"
        requestReadViaHTTP(
            domain: "evolution",
            path: path,
            fallbackAction: "evo_agent_profile",
            cacheMode: cacheMode
        )
    }

    public func requestEvoListCycleHistory(
        project: String,
        workspace: String,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        let path = "/api/v1/evolution/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/cycle-history"
        requestReadViaHTTP(
            domain: "evolution",
            path: path,
            fallbackAction: "evo_cycle_history",
            cacheMode: cacheMode
        )
    }

    public func requestEvidenceSnapshot(
        project: String,
        workspace: String,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        let path = "/api/v1/evidence/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/snapshot"
        requestReadViaHTTP(
            domain: "evidence",
            path: path,
            fallbackAction: "evidence_snapshot",
            cacheMode: cacheMode
        )
    }

    public func requestEvidenceRebuildPrompt(
        project: String,
        workspace: String,
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        let path = "/api/v1/evidence/projects/\(encodePathComponent(project))/workspaces/\(encodePathComponent(workspace))/rebuild-prompt"
        requestReadViaHTTP(
            domain: "evidence",
            path: path,
            fallbackAction: "evidence_rebuild_prompt",
            cacheMode: cacheMode
        )
    }

    public func requestEvidenceReadItem(
        project: String,
        workspace: String,
        itemID: String,
        offset: UInt64 = 0,
        limit: UInt32? = 262_144,
        cacheMode: HTTPQueryCacheMode = .default
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
            fallbackAction: "evidence_item_chunk",
            cacheMode: cacheMode
        )
    }

    // MARK: - AI 代码补全

    /// 发送 AI 代码补全请求（流式）
    public func requestAICodeCompletion(
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
    public func requestAICodeCompletionAbort(
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
    public func requestSystemSnapshot(cacheMode: HTTPQueryCacheMode = .default) {
        requestReadViaHTTP(
            domain: "system",
            path: "/api/v1/system/snapshot",
            fallbackAction: "system_snapshot",
            cacheMode: cacheMode
        )
    }

    // MARK: - v1.41: 系统健康诊断与自修复

    /// 上报客户端健康状态（含本地检测 incidents）
    public func reportHealthStatus(
        clientSessionId: String,
        connectivity: ClientConnectivity,
        incidents: [HealthIncident] = [],
        context: HealthContext = .system,
        clientPerformanceReport: ClientPerformanceReport? = nil
    ) {
        let incidentsJson = incidents.compactMap { incident -> [String: Any]? in
            guard let data = try? JSONEncoder().encode(incident),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return dict
        }
        var payload: [String: Any] = [
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
        ]
        // WI-001: 附加客户端性能上报
        if let report = clientPerformanceReport,
           let data = try? JSONEncoder().encode(report),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload["client_performance_report"] = dict
        }
        send(payload)
    }

    /// 请求执行修复动作（含上下文，确保 project/workspace 边界）
    public func requestHealthRepair(
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
