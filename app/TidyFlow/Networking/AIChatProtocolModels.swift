import Foundation

// MARK: - AI Chat Protocol Models (vNext)

struct AISessionStartedV2 {
    let projectName: String
    let workspaceName: String
    let aiTool: AIChatTool
    let sessionId: String
    let title: String
    let updatedAt: Int64

    static func from(json: [String: Any]) -> AISessionStartedV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String,
              let title = json["title"] as? String else { return nil }
        let updatedAt = parseInt64(json["updated_at"])
        return AISessionStartedV2(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId,
            title: title,
            updatedAt: updatedAt
        )
    }
}

struct AISessionListV2 {
    let projectName: String
    let workspaceName: String
    let aiTool: AIChatTool
    let sessions: [AIProtocolSessionInfo]

    static func from(json: [String: Any]) -> AISessionListV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]) else { return nil }
        let items = (json["sessions"] as? [[String: Any]] ?? []).compactMap { AIProtocolSessionInfo.from(json: $0) }
        return AISessionListV2(projectName: projectName, workspaceName: workspaceName, aiTool: aiTool, sessions: items)
    }
}

struct AISessionMessagesV2 {
    let projectName: String
    let workspaceName: String
    let aiTool: AIChatTool
    let sessionId: String
    let messages: [AIProtocolMessageInfo]

    static func from(json: [String: Any]) -> AISessionMessagesV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String else { return nil }
        let messages = (json["messages"] as? [[String: Any]] ?? []).compactMap { AIProtocolMessageInfo.from(json: $0) }
        return AISessionMessagesV2(projectName: projectName, workspaceName: workspaceName, aiTool: aiTool, sessionId: sessionId, messages: messages)
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
    let mime: String?
    let filename: String?
    let url: String?
    let synthetic: Bool?
    let ignored: Bool?
    let source: [String: Any]?
    let toolName: String?
    let toolCallId: String?
    let toolState: [String: Any]?
    let toolPartMetadata: [String: Any]?

    static func from(json: [String: Any]) -> AIProtocolPartInfo? {
        guard let id = json["id"] as? String,
              let partType = json["part_type"] as? String else { return nil }
        let text = json["text"] as? String
        let mime = json["mime"] as? String
        let filename = json["filename"] as? String
        let url = json["url"] as? String
        let synthetic = json["synthetic"] as? Bool
        let ignored = json["ignored"] as? Bool
        let source = json["source"] as? [String: Any]
        let toolName = json["tool_name"] as? String
        let toolCallId = json["tool_call_id"] as? String
        let toolState = json["tool_state"] as? [String: Any]
        let toolPartMetadata = json["tool_part_metadata"] as? [String: Any]
        return AIProtocolPartInfo(
            id: id,
            partType: partType,
            text: text,
            mime: mime,
            filename: filename,
            url: url,
            synthetic: synthetic,
            ignored: ignored,
            source: source,
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
    let aiTool: AIChatTool
    let sessionId: String
    let messageId: String
    let role: String

    static func from(json: [String: Any]) -> AIChatMessageUpdatedV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String,
              let messageId = json["message_id"] as? String,
              let role = json["role"] as? String else { return nil }
        return AIChatMessageUpdatedV2(projectName: projectName, workspaceName: workspaceName, aiTool: aiTool, sessionId: sessionId, messageId: messageId, role: role)
    }
}

struct AIChatPartUpdatedV2 {
    let projectName: String
    let workspaceName: String
    let aiTool: AIChatTool
    let sessionId: String
    let messageId: String
    let part: AIProtocolPartInfo

    static func from(json: [String: Any]) -> AIChatPartUpdatedV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String,
              let messageId = json["message_id"] as? String,
              let partDict = json["part"] as? [String: Any],
              let part = AIProtocolPartInfo.from(json: partDict) else { return nil }
        return AIChatPartUpdatedV2(projectName: projectName, workspaceName: workspaceName, aiTool: aiTool, sessionId: sessionId, messageId: messageId, part: part)
    }
}

struct AIChatPartDeltaV2 {
    let projectName: String
    let workspaceName: String
    let aiTool: AIChatTool
    let sessionId: String
    let messageId: String
    let partId: String
    let partType: String
    let field: String
    let delta: String

    static func from(json: [String: Any]) -> AIChatPartDeltaV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String,
              let messageId = json["message_id"] as? String,
              let partId = json["part_id"] as? String,
              let partType = json["part_type"] as? String,
              let field = json["field"] as? String,
              let delta = json["delta"] as? String else { return nil }
        return AIChatPartDeltaV2(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
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
    let aiTool: AIChatTool
    let sessionId: String

    static func from(json: [String: Any]) -> AIChatDoneV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String else { return nil }
        return AIChatDoneV2(projectName: projectName, workspaceName: workspaceName, aiTool: aiTool, sessionId: sessionId)
    }
}

struct AIChatErrorV2 {
    let projectName: String
    let workspaceName: String
    let aiTool: AIChatTool
    let sessionId: String
    let error: String

    static func from(json: [String: Any]) -> AIChatErrorV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String,
              let error = json["error"] as? String else { return nil }
        return AIChatErrorV2(projectName: projectName, workspaceName: workspaceName, aiTool: aiTool, sessionId: sessionId, error: error)
    }
}

struct AIQuestionOptionInfo {
    let label: String
    let description: String

    static func from(json: [String: Any]) -> AIQuestionOptionInfo? {
        guard let label = json["label"] as? String else { return nil }
        let description = json["description"] as? String ?? ""
        return AIQuestionOptionInfo(label: label, description: description)
    }
}

struct AIQuestionInfo {
    let question: String
    let header: String
    let options: [AIQuestionOptionInfo]
    let multiple: Bool
    let custom: Bool

    static func from(json: [String: Any]) -> AIQuestionInfo? {
        guard let question = json["question"] as? String else { return nil }
        let header = json["header"] as? String ?? ""
        let options = (json["options"] as? [[String: Any]] ?? []).compactMap { AIQuestionOptionInfo.from(json: $0) }
        let multiple = json["multiple"] as? Bool ?? false
        let custom = json["custom"] as? Bool ?? true
        return AIQuestionInfo(
            question: question,
            header: header,
            options: options,
            multiple: multiple,
            custom: custom
        )
    }
}

struct AIQuestionRequestInfo {
    let id: String
    let sessionId: String
    let questions: [AIQuestionInfo]
    let toolMessageId: String?
    let toolCallId: String?

    static func from(json: [String: Any]) -> AIQuestionRequestInfo? {
        guard let id = json["id"] as? String,
              let sessionId = json["session_id"] as? String else { return nil }
        let questions = (json["questions"] as? [[String: Any]] ?? []).compactMap { AIQuestionInfo.from(json: $0) }
        let toolMessageId = json["tool_message_id"] as? String
        let toolCallId = json["tool_call_id"] as? String
        return AIQuestionRequestInfo(
            id: id,
            sessionId: sessionId,
            questions: questions,
            toolMessageId: toolMessageId,
            toolCallId: toolCallId
        )
    }
}

struct AIQuestionAskedV2 {
    let projectName: String
    let workspaceName: String
    let aiTool: AIChatTool
    let sessionId: String
    let request: AIQuestionRequestInfo

    static func from(json: [String: Any]) -> AIQuestionAskedV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String,
              let requestDict = json["request"] as? [String: Any],
              let request = AIQuestionRequestInfo.from(json: requestDict) else { return nil }
        return AIQuestionAskedV2(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId,
            request: request
        )
    }
}

struct AIQuestionClearedV2 {
    let projectName: String
    let workspaceName: String
    let aiTool: AIChatTool
    let sessionId: String
    let requestId: String

    static func from(json: [String: Any]) -> AIQuestionClearedV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String,
              let requestId = json["request_id"] as? String else { return nil }
        return AIQuestionClearedV2(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId,
            requestId: requestId
        )
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

private func parseAIChatTool(_ any: Any?) -> AIChatTool? {
    guard let raw = any as? String else { return nil }
    return AIChatTool(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
}

// MARK: - Provider / Agent 列表

struct AIProviderListResult {
    let projectName: String
    let workspaceName: String
    let aiTool: AIChatTool
    let providers: [AIProtocolProviderInfo]

    static func from(json: [String: Any]) -> AIProviderListResult? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]) else { return nil }
        let items = (json["providers"] as? [[String: Any]] ?? []).compactMap { AIProtocolProviderInfo.from(json: $0) }
        return AIProviderListResult(projectName: projectName, workspaceName: workspaceName, aiTool: aiTool, providers: items)
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
    let supportsImageInput: Bool

    static func from(json: [String: Any]) -> AIProtocolModelInfo? {
        guard let id = json["id"] as? String else { return nil }
        let name = json["name"] as? String ?? id
        let providerID = json["provider_id"] as? String ?? ""
        let supportsImageInput = json["supports_image_input"] as? Bool ?? false
        return AIProtocolModelInfo(
            id: id,
            name: name,
            providerID: providerID,
            supportsImageInput: supportsImageInput
        )
    }
}

struct AIAgentListResult {
    let projectName: String
    let workspaceName: String
    let aiTool: AIChatTool
    let agents: [AIProtocolAgentInfo]

    static func from(json: [String: Any]) -> AIAgentListResult? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]) else { return nil }
        let items = (json["agents"] as? [[String: Any]] ?? []).compactMap { AIProtocolAgentInfo.from(json: $0) }
        return AIAgentListResult(projectName: projectName, workspaceName: workspaceName, aiTool: aiTool, agents: items)
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
    let aiTool: AIChatTool
    let commands: [AIProtocolSlashCommand]

    static func from(json: [String: Any]) -> AISlashCommandsResult? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]) else { return nil }
        let items = (json["commands"] as? [[String: Any]] ?? []).compactMap { AIProtocolSlashCommand.from(json: $0) }
        return AISlashCommandsResult(projectName: projectName, workspaceName: workspaceName, aiTool: aiTool, commands: items)
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
