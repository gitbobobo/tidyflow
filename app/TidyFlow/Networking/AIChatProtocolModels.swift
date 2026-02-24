import Foundation

// MARK: - AI Chat Protocol Models (vNext)

struct AISessionStartedV2 {
    let projectName: String
    let workspaceName: String
    let aiTool: AIChatTool
    let sessionId: String
    let title: String
    let updatedAt: Int64
    let selectionHint: AISessionSelectionHint?

    static func from(json: [String: Any]) -> AISessionStartedV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String,
              let title = json["title"] as? String else { return nil }
        let updatedAt = parseInt64(json["updated_at"])
        let selectionHint = AISessionSelectionHint.from(json: json["selection_hint"] as? [String: Any])
        return AISessionStartedV2(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId,
            title: title,
            updatedAt: updatedAt,
            selectionHint: selectionHint
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
    let selectionHint: AISessionSelectionHint?

    static func from(json: [String: Any]) -> AISessionMessagesV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String else { return nil }
        let messages = (json["messages"] as? [[String: Any]] ?? []).compactMap { AIProtocolMessageInfo.from(json: $0) }
        let selectionHint = AISessionSelectionHint.from(json: json["selection_hint"] as? [String: Any])
        return AISessionMessagesV2(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId,
            messages: messages,
            selectionHint: selectionHint
        )
    }
}

struct AISessionStatusInfoV2 {
    /// "idle" | "busy" | "error"
    let status: String
    let errorMessage: String?
    let contextRemainingPercent: Double?

    static func from(json: [String: Any]) -> AISessionStatusInfoV2? {
        guard let status = json["status"] as? String else { return nil }
        let errorMessage = json["error_message"] as? String
        let contextRemainingPercent = parseDouble(json["context_remaining_percent"])
        return AISessionStatusInfoV2(
            status: status,
            errorMessage: errorMessage,
            contextRemainingPercent: contextRemainingPercent
        )
    }
}

struct AISessionStatusResultV2 {
    let projectName: String
    let workspaceName: String
    let aiTool: AIChatTool
    let sessionId: String
    let status: AISessionStatusInfoV2

    static func from(json: [String: Any]) -> AISessionStatusResultV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String,
              let statusDict = json["status"] as? [String: Any],
              let status = AISessionStatusInfoV2.from(json: statusDict) else { return nil }
        return AISessionStatusResultV2(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId,
            status: status
        )
    }
}

struct AISessionStatusUpdateV2 {
    let projectName: String
    let workspaceName: String
    let aiTool: AIChatTool
    let sessionId: String
    let status: AISessionStatusInfoV2

    static func from(json: [String: Any]) -> AISessionStatusUpdateV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String,
              let statusDict = json["status"] as? [String: Any],
              let status = AISessionStatusInfoV2.from(json: statusDict) else { return nil }
        return AISessionStatusUpdateV2(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId,
            status: status
        )
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
    let agent: String?
    let modelProviderID: String?
    let modelID: String?
    let parts: [AIProtocolPartInfo]

    static func from(json: [String: Any]) -> AIProtocolMessageInfo? {
        guard let id = json["id"] as? String,
              let role = json["role"] as? String else { return nil }
        let createdAtRaw = json["created_at"]
        let createdAt: Int64? = createdAtRaw == nil ? nil : parseInt64(createdAtRaw)
        let agent = parseOptionalString(json["agent"])
        let modelProviderID = parseOptionalString(json["model_provider_id"])
        let modelID = parseOptionalString(json["model_id"])
        let parts = (json["parts"] as? [[String: Any]] ?? []).compactMap { AIProtocolPartInfo.from(json: $0) }
        return AIProtocolMessageInfo(
            id: id,
            role: role,
            createdAt: createdAt,
            agent: agent,
            modelProviderID: modelProviderID,
            modelID: modelID,
            parts: parts
        )
    }
}

struct AIChatMessageUpdatedV2 {
    let projectName: String
    let workspaceName: String
    let aiTool: AIChatTool
    let sessionId: String
    let messageId: String
    let role: String
    let selectionHint: AISessionSelectionHint?

    static func from(json: [String: Any]) -> AIChatMessageUpdatedV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String,
              let messageId = json["message_id"] as? String,
              let role = json["role"] as? String else { return nil }
        let selectionHint = AISessionSelectionHint.from(json: json["selection_hint"] as? [String: Any])
        return AIChatMessageUpdatedV2(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId,
            messageId: messageId,
            role: role,
            selectionHint: selectionHint
        )
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
    let selectionHint: AISessionSelectionHint?

    static func from(json: [String: Any]) -> AIChatDoneV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String else { return nil }
        let selectionHint = AISessionSelectionHint.from(json: json["selection_hint"] as? [String: Any])
        return AIChatDoneV2(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId,
            selectionHint: selectionHint
        )
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

private func parseOptionalString(_ any: Any?) -> String? {
    switch any {
    case let v as String:
        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    case let v as NSNumber:
        let text = v.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    default:
        return nil
    }
}

private func parseDictionary(_ any: Any?) -> [String: Any]? {
    if let dict = any as? [String: Any] {
        return dict
    }
    if let dict = any as? [AnyHashable: Any] {
        var converted: [String: Any] = [:]
        converted.reserveCapacity(dict.count)
        for (key, value) in dict {
            guard let text = key as? String else { continue }
            converted[text] = value
        }
        return converted
    }
    return nil
}

private func parseArrayOfDictionaries(_ any: Any?) -> [[String: Any]] {
    if let dicts = any as? [[String: Any]] {
        return dicts
    }
    guard let items = any as? [Any] else { return [] }
    return items.compactMap { parseDictionary($0) }
}

private extension AISessionSelectionHint {
    static func from(json: [String: Any]?) -> AISessionSelectionHint? {
        guard let json else { return nil }
        let agent = parseOptionalString(json["agent"])?.lowercased()
        let modelProviderID = parseOptionalString(json["model_provider_id"])
        let modelID = parseOptionalString(json["model_id"])
        let hint = AISessionSelectionHint(
            agent: agent,
            modelProviderID: modelProviderID,
            modelID: modelID
        )
        return hint.isEmpty ? nil : hint
    }
}

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

private func parseDouble(_ any: Any?) -> Double? {
    switch any {
    case let v as Double:
        return v
    case let v as Float:
        return Double(v)
    case let v as Int:
        return Double(v)
    case let v as Int64:
        return Double(v)
    case let v as NSNumber:
        return v.doubleValue
    case let v as String:
        return Double(v.trimmingCharacters(in: .whitespacesAndNewlines))
    default:
        return nil
    }
}

private func parseAIChatTool(_ any: Any?) -> AIChatTool? {
    guard let raw = any as? String else { return nil }
    let normalized = raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "_", with: "-")
    let mapped = switch normalized {
    case "open-code":
        "opencode"
    case "codex-app-server", "codex-app":
        "codex"
    case "copilot-acp", "github-copilot":
        "copilot"
    default:
        normalized
    }
    return AIChatTool(rawValue: mapped)
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

// MARK: - Evolution

struct EvolutionModelSelectionV2 {
    let providerID: String
    let modelID: String

    static func from(json: [String: Any]) -> EvolutionModelSelectionV2? {
        let providerID = parseOptionalString(json["provider_id"])
            ?? parseOptionalString(json["providerId"])
            ?? parseOptionalString(json["providerID"])
            ?? parseOptionalString(json["model_provider_id"])
            ?? parseOptionalString(json["modelProviderID"])
            ?? parseOptionalString(json["modelProviderId"])
        let modelID = parseOptionalString(json["model_id"])
            ?? parseOptionalString(json["modelId"])
            ?? parseOptionalString(json["modelID"])
        guard let providerID, let modelID else { return nil }
        return EvolutionModelSelectionV2(providerID: providerID, modelID: modelID)
    }

    static func from(rawModel: String, providerHint: String?) -> EvolutionModelSelectionV2? {
        let normalizedModel = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else { return nil }
        if let slash = normalizedModel.firstIndex(of: "/") {
            let provider = normalizedModel[..<slash].trimmingCharacters(in: .whitespacesAndNewlines)
            let model = normalizedModel[normalizedModel.index(after: slash)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !provider.isEmpty, !model.isEmpty else { return nil }
            return EvolutionModelSelectionV2(providerID: provider, modelID: model)
        }
        guard let providerHint = providerHint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerHint.isEmpty else { return nil }
        return EvolutionModelSelectionV2(providerID: providerHint, modelID: normalizedModel)
    }
}

struct EvolutionStageProfileInfoV2 {
    let stage: String
    let aiTool: AIChatTool
    let mode: String?
    let model: EvolutionModelSelectionV2?

    static func from(json: [String: Any]) -> EvolutionStageProfileInfoV2? {
        guard let stage = parseOptionalString(json["stage"])
            ?? parseOptionalString(json["stage_name"])
            ?? parseOptionalString(json["stageName"]) else { return nil }
        let aiTool = parseAIChatTool(json["ai_tool"] ?? json["aiTool"]) ?? .codex
        let mode = parseOptionalString(json["mode"])
        let providerHint = parseOptionalString(json["provider_id"])
            ?? parseOptionalString(json["providerId"])
            ?? parseOptionalString(json["providerID"])
            ?? parseOptionalString(json["model_provider_id"])
            ?? parseOptionalString(json["modelProviderId"])
            ?? parseOptionalString(json["modelProviderID"])
        let model = parseDictionary(json["model"]).flatMap { EvolutionModelSelectionV2.from(json: $0) }
            ?? EvolutionModelSelectionV2.from(json: json)
            ?? parseOptionalString(json["model"]).flatMap { EvolutionModelSelectionV2.from(rawModel: $0, providerHint: providerHint) }
        return EvolutionStageProfileInfoV2(stage: stage, aiTool: aiTool, mode: mode, model: model)
    }

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "stage": stage,
            "ai_tool": aiTool.rawValue
        ]
        if let mode { json["mode"] = mode }
        if let model {
            json["model"] = [
                "provider_id": model.providerID,
                "model_id": model.modelID
            ]
        }
        return json
    }
}

struct EvolutionAgentInfoV2 {
    let stage: String
    let agent: String
    let status: String
    let toolCallCount: Int
    let latestMessage: String?

    static func from(json: [String: Any]) -> EvolutionAgentInfoV2? {
        guard let stage = json["stage"] as? String,
              let agent = json["agent"] as? String,
              let status = json["status"] as? String else { return nil }
        let toolCallCount = Int(parseInt64(json["tool_call_count"]))
        let latestMessage = parseOptionalString(json["latest_message"])
        return EvolutionAgentInfoV2(
            stage: stage,
            agent: agent,
            status: status,
            toolCallCount: toolCallCount,
            latestMessage: latestMessage
        )
    }
}

struct EvolutionSchedulerInfoV2 {
    let activationState: String
    let maxParallelWorkspaces: Int
    let runningCount: Int
    let queuedCount: Int

    static let empty = EvolutionSchedulerInfoV2(
        activationState: "idle",
        maxParallelWorkspaces: 0,
        runningCount: 0,
        queuedCount: 0
    )

    static func from(json: [String: Any]) -> EvolutionSchedulerInfoV2? {
        guard let activationState = json["activation_state"] as? String else { return nil }
        return EvolutionSchedulerInfoV2(
            activationState: activationState,
            maxParallelWorkspaces: Int(parseInt64(json["max_parallel_workspaces"])),
            runningCount: Int(parseInt64(json["running_count"])),
            queuedCount: Int(parseInt64(json["queued_count"]))
        )
    }
}

struct EvolutionWorkspaceItemV2 {
    let project: String
    let workspace: String
    let cycleID: String
    let status: String
    let currentStage: String
    let globalLoopRound: Int
    let autoLoopEnabled: Bool
    let verifyIteration: Int
    let verifyIterationLimit: Int
    let agents: [EvolutionAgentInfoV2]
    let activeAgents: [String]

    var workspaceKey: String {
        "\(project):\(workspace)"
    }

    static func from(json: [String: Any]) -> EvolutionWorkspaceItemV2? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let cycleID = json["cycle_id"] as? String,
              let status = json["status"] as? String,
              let currentStage = json["current_stage"] as? String else { return nil }

        let agents = (json["agents"] as? [[String: Any]] ?? []).compactMap { EvolutionAgentInfoV2.from(json: $0) }
        let activeAgents = json["active_agents"] as? [String] ?? []
        return EvolutionWorkspaceItemV2(
            project: project,
            workspace: workspace,
            cycleID: cycleID,
            status: status,
            currentStage: currentStage,
            globalLoopRound: Int(parseInt64(json["global_loop_round"])),
            autoLoopEnabled: json["auto_loop_enabled"] as? Bool ?? true,
            verifyIteration: Int(parseInt64(json["verify_iteration"])),
            verifyIterationLimit: Int(parseInt64(json["verify_iteration_limit"])),
            agents: agents,
            activeAgents: activeAgents
        )
    }
}

struct EvolutionSnapshotV2 {
    let scheduler: EvolutionSchedulerInfoV2
    let workspaceItems: [EvolutionWorkspaceItemV2]

    static func from(json: [String: Any]) -> EvolutionSnapshotV2? {
        guard let schedulerDict = json["scheduler"] as? [String: Any],
              let scheduler = EvolutionSchedulerInfoV2.from(json: schedulerDict) else { return nil }
        let items = (json["workspace_items"] as? [[String: Any]] ?? [])
            .compactMap { EvolutionWorkspaceItemV2.from(json: $0) }
        return EvolutionSnapshotV2(scheduler: scheduler, workspaceItems: items)
    }
}

struct EvolutionStageChatOpenedV2 {
    let project: String
    let workspace: String
    let cycleID: String
    let stage: String
    let aiToolRaw: String
    let sessionID: String

    var aiTool: AIChatTool? {
        AIChatTool(rawValue: aiToolRaw.lowercased())
    }

    static func from(json: [String: Any]) -> EvolutionStageChatOpenedV2? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let cycleID = json["cycle_id"] as? String,
              let stage = json["stage"] as? String,
              let aiToolRaw = json["ai_tool"] as? String,
              let sessionID = json["session_id"] as? String else { return nil }
        return EvolutionStageChatOpenedV2(
            project: project,
            workspace: workspace,
            cycleID: cycleID,
            stage: stage,
            aiToolRaw: aiToolRaw,
            sessionID: sessionID
        )
    }
}

struct EvolutionAgentProfileV2 {
    let project: String
    let workspace: String
    let stageProfiles: [EvolutionStageProfileInfoV2]

    static func from(json: [String: Any]) -> EvolutionAgentProfileV2? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String else { return nil }
        let stageProfileSource = json["stage_profiles"] ?? json["stageProfiles"]
        let stageProfileDicts: [[String: Any]] = {
            let fromArray = parseArrayOfDictionaries(stageProfileSource)
            if !fromArray.isEmpty { return fromArray }
            guard let byStage = parseDictionary(stageProfileSource) else { return [] }
            return byStage.compactMap { (key, value) in
                guard var item = parseDictionary(value) else { return nil }
                if parseOptionalString(item["stage"]) == nil {
                    item["stage"] = key
                }
                return item
            }
        }()
        let stageProfiles = stageProfileDicts
            .compactMap { EvolutionStageProfileInfoV2.from(json: $0) }
        return EvolutionAgentProfileV2(project: project, workspace: workspace, stageProfiles: stageProfiles)
    }
}

extension AISessionMessagesV2 {
    func toChatMessages() -> [AIChatMessage] {
        messages.compactMap { message in
            let role: AIChatRole = (message.role == "assistant") ? .assistant : .user
            let parts: [AIChatPart] = message.parts.compactMap { part in
                let kind = AIChatPartKind(rawValue: part.partType) ?? .text
                return AIChatPart(
                    id: part.id,
                    kind: kind,
                    text: part.text,
                    mime: part.mime,
                    filename: part.filename,
                    url: part.url,
                    synthetic: part.synthetic,
                    ignored: part.ignored,
                    source: part.source,
                    toolName: part.toolName,
                    toolState: part.toolState,
                    toolCallId: part.toolCallId,
                    toolPartMetadata: part.toolPartMetadata
                )
            }
            return AIChatMessage(messageId: message.id, role: role, parts: parts, isStreaming: false)
        }
    }
}
