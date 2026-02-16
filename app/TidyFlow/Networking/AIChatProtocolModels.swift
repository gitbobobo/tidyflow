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
    let toolState: [String: Any]?

    static func from(json: [String: Any]) -> AIProtocolPartInfo? {
        guard let id = json["id"] as? String,
              let partType = json["part_type"] as? String else { return nil }
        let text = json["text"] as? String
        let toolName = json["tool_name"] as? String
        let toolState = json["tool_state"] as? [String: Any]
        return AIProtocolPartInfo(id: id, partType: partType, text: text, toolName: toolName, toolState: toolState)
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
