import Foundation

// MARK: - AI Chat Protocol Models (vNext)

struct AISessionStartedV2 {
    let projectName: String
    let workspaceName: String
    let sessionId: String
    let title: String
    let updatedAt: Int64

    static func from(json: [String: Any]) -> AISessionStartedV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let sessionId = json["session_id"] as? String,
              let title = json["title"] as? String else { return nil }
        let updatedAt = parseInt64(json["updated_at"])
        return AISessionStartedV2(
            projectName: projectName,
            workspaceName: workspaceName,
            sessionId: sessionId,
            title: title,
            updatedAt: updatedAt
        )
    }
}

struct AISessionListV2 {
    let projectName: String
    let workspaceName: String
    let sessions: [AIProtocolSessionInfo]

    static func from(json: [String: Any]) -> AISessionListV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String else { return nil }
        let items = (json["sessions"] as? [[String: Any]] ?? []).compactMap { AIProtocolSessionInfo.from(json: $0) }
        return AISessionListV2(projectName: projectName, workspaceName: workspaceName, sessions: items)
    }
}

struct AISessionMessagesV2 {
    let projectName: String
    let workspaceName: String
    let sessionId: String
    let messages: [AIProtocolMessageInfo]

    static func from(json: [String: Any]) -> AISessionMessagesV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let sessionId = json["session_id"] as? String else { return nil }
        let messages = (json["messages"] as? [[String: Any]] ?? []).compactMap { AIProtocolMessageInfo.from(json: $0) }
        return AISessionMessagesV2(projectName: projectName, workspaceName: workspaceName, sessionId: sessionId, messages: messages)
    }
}

struct AIProtocolSessionInfo {
    let projectName: String
    let workspaceName: String
    let id: String
    let title: String
    let updatedAt: Int64

    static func from(json: [String: Any]) -> AIProtocolSessionInfo? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let id = json["id"] as? String,
              let title = json["title"] as? String else { return nil }
        let updatedAt = parseInt64(json["updated_at"])
        return AIProtocolSessionInfo(projectName: projectName, workspaceName: workspaceName, id: id, title: title, updatedAt: updatedAt)
    }
}

struct AIProtocolPartInfo {
    let id: String
    let partType: String
    let text: String?
    let toolName: String?
    let toolCallId: String?
    let toolState: [String: Any]?
    let toolPartMetadata: [String: Any]?

    static func from(json: [String: Any]) -> AIProtocolPartInfo? {
        guard let id = json["id"] as? String,
              let partType = json["part_type"] as? String else { return nil }
        let text = json["text"] as? String
        let toolName = json["tool_name"] as? String
        let toolCallId = json["tool_call_id"] as? String
        let toolState = json["tool_state"] as? [String: Any]
        let toolPartMetadata = json["tool_part_metadata"] as? [String: Any]
        return AIProtocolPartInfo(
            id: id,
            partType: partType,
            text: text,
            toolName: toolName,
            toolCallId: toolCallId,
            toolState: toolState,
            toolPartMetadata: toolPartMetadata
        )
    }
}

struct AIProtocolMessageInfo {
    let id: String
    let role: String
    let createdAt: Int64?
    let parts: [AIProtocolPartInfo]

    static func from(json: [String: Any]) -> AIProtocolMessageInfo? {
        guard let id = json["id"] as? String,
              let role = json["role"] as? String else { return nil }
        let createdAtRaw = json["created_at"]
        let createdAt: Int64? = createdAtRaw == nil ? nil : parseInt64(createdAtRaw)
        let parts = (json["parts"] as? [[String: Any]] ?? []).compactMap { AIProtocolPartInfo.from(json: $0) }
        return AIProtocolMessageInfo(id: id, role: role, createdAt: createdAt, parts: parts)
    }
}

struct AIChatMessageUpdatedV2 {
    let projectName: String
    let workspaceName: String
    let sessionId: String
    let messageId: String
    let role: String

    static func from(json: [String: Any]) -> AIChatMessageUpdatedV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let sessionId = json["session_id"] as? String,
              let messageId = json["message_id"] as? String,
              let role = json["role"] as? String else { return nil }
        return AIChatMessageUpdatedV2(projectName: projectName, workspaceName: workspaceName, sessionId: sessionId, messageId: messageId, role: role)
    }
}

struct AIChatPartUpdatedV2 {
    let projectName: String
    let workspaceName: String
    let sessionId: String
    let messageId: String
    let part: AIProtocolPartInfo

    static func from(json: [String: Any]) -> AIChatPartUpdatedV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let sessionId = json["session_id"] as? String,
              let messageId = json["message_id"] as? String,
              let partDict = json["part"] as? [String: Any],
              let part = AIProtocolPartInfo.from(json: partDict) else { return nil }
        return AIChatPartUpdatedV2(projectName: projectName, workspaceName: workspaceName, sessionId: sessionId, messageId: messageId, part: part)
    }
}

struct AIChatPartDeltaV2 {
    let projectName: String
    let workspaceName: String
    let sessionId: String
    let messageId: String
    let partId: String
    let partType: String
    let field: String
    let delta: String

    static func from(json: [String: Any]) -> AIChatPartDeltaV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let sessionId = json["session_id"] as? String,
              let messageId = json["message_id"] as? String,
              let partId = json["part_id"] as? String,
              let partType = json["part_type"] as? String,
              let field = json["field"] as? String,
              let delta = json["delta"] as? String else { return nil }
        return AIChatPartDeltaV2(
            projectName: projectName,
            workspaceName: workspaceName,
            sessionId: sessionId,
            messageId: messageId,
            partId: partId,
            partType: partType,
            field: field,
            delta: delta
        )
    }
}

struct AIChatDoneV2 {
    let projectName: String
    let workspaceName: String
    let sessionId: String

    static func from(json: [String: Any]) -> AIChatDoneV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let sessionId = json["session_id"] as? String else { return nil }
        return AIChatDoneV2(projectName: projectName, workspaceName: workspaceName, sessionId: sessionId)
    }
}

struct AIChatErrorV2 {
    let projectName: String
    let workspaceName: String
    let sessionId: String
    let error: String

    static func from(json: [String: Any]) -> AIChatErrorV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let sessionId = json["session_id"] as? String,
              let error = json["error"] as? String else { return nil }
        return AIChatErrorV2(projectName: projectName, workspaceName: workspaceName, sessionId: sessionId, error: error)
    }
}

// MARK: - Helpers

private func parseInt64(_ any: Any?) -> Int64 {
    switch any {
    case let v as Int64:
        return v
    case let v as Int:
        return Int64(v)
    case let v as UInt:
        return Int64(v)
    case let v as Double:
        return Int64(v)
    case let v as String:
        return Int64(v) ?? 0
    default:
        return 0
    }
}

// MARK: - Provider / Agent 列表

struct AIProviderListResult {
    let projectName: String
    let workspaceName: String
    let providers: [AIProtocolProviderInfo]

    static func from(json: [String: Any]) -> AIProviderListResult? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String else { return nil }
        let items = (json["providers"] as? [[String: Any]] ?? []).compactMap { AIProtocolProviderInfo.from(json: $0) }
        return AIProviderListResult(projectName: projectName, workspaceName: workspaceName, providers: items)
    }
}

struct AIProtocolProviderInfo {
    let id: String
    let name: String
    let models: [AIProtocolModelInfo]

    static func from(json: [String: Any]) -> AIProtocolProviderInfo? {
        guard let id = json["id"] as? String else { return nil }
        let name = json["name"] as? String ?? id
        let models = (json["models"] as? [[String: Any]] ?? []).compactMap { AIProtocolModelInfo.from(json: $0) }
        return AIProtocolProviderInfo(id: id, name: name, models: models)
    }
}

struct AIProtocolModelInfo {
    let id: String
    let name: String
    let providerID: String

    static func from(json: [String: Any]) -> AIProtocolModelInfo? {
        guard let id = json["id"] as? String else { return nil }
        let name = json["name"] as? String ?? id
        let providerID = json["provider_id"] as? String ?? ""
        return AIProtocolModelInfo(id: id, name: name, providerID: providerID)
    }
}

struct AIAgentListResult {
    let projectName: String
    let workspaceName: String
    let agents: [AIProtocolAgentInfo]

    static func from(json: [String: Any]) -> AIAgentListResult? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String else { return nil }
        let items = (json["agents"] as? [[String: Any]] ?? []).compactMap { AIProtocolAgentInfo.from(json: $0) }
        return AIAgentListResult(projectName: projectName, workspaceName: workspaceName, agents: items)
    }
}

struct AIProtocolAgentInfo {
    let name: String
    let description: String?
    let mode: String?
    let color: String?
    let defaultProviderID: String?
    let defaultModelID: String?

    static func from(json: [String: Any]) -> AIProtocolAgentInfo? {
        guard let name = json["name"] as? String else { return nil }
        return AIProtocolAgentInfo(
            name: name,
            description: json["description"] as? String,
            mode: json["mode"] as? String,
            color: json["color"] as? String,
            defaultProviderID: json["default_provider_id"] as? String,
            defaultModelID: json["default_model_id"] as? String
        )
    }
}

// MARK: - 斜杠命令列表

struct AISlashCommandsResult {
    let projectName: String
    let workspaceName: String
    let commands: [AIProtocolSlashCommand]

    static func from(json: [String: Any]) -> AISlashCommandsResult? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String else { return nil }
        let items = (json["commands"] as? [[String: Any]] ?? []).compactMap { AIProtocolSlashCommand.from(json: $0) }
        return AISlashCommandsResult(projectName: projectName, workspaceName: workspaceName, commands: items)
    }
}

struct AIProtocolSlashCommand {
    let name: String
    let description: String
    let action: String

    static func from(json: [String: Any]) -> AIProtocolSlashCommand? {
        guard let name = json["name"] as? String else { return nil }
        let description = json["description"] as? String ?? ""
        let action = json["action"] as? String ?? "client"
        return AIProtocolSlashCommand(name: name, description: description, action: action)
    }
}
