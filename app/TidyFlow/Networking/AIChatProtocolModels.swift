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

struct AIProtocolSessionConfigOptionChoice {
    let value: Any
    let label: String
    let description: String?

    static func from(json: [String: Any]) -> AIProtocolSessionConfigOptionChoice? {
        guard let rawValue = normalizeProtocolJSONValue(json["value"]) else { return nil }
        let label = parseOptionalString(json["label"]) ?? "\(rawValue)"
        guard !label.isEmpty else { return nil }
        let description = parseOptionalString(json["description"])
        return AIProtocolSessionConfigOptionChoice(
            value: rawValue,
            label: label,
            description: description
        )
    }
}

struct AIProtocolSessionConfigOptionGroup {
    let label: String
    let options: [AIProtocolSessionConfigOptionChoice]

    static func from(json: [String: Any]) -> AIProtocolSessionConfigOptionGroup? {
        guard let label = parseOptionalString(json["label"]) else { return nil }
        let options = parseArrayOfDictionaries(json["options"])
            .compactMap { AIProtocolSessionConfigOptionChoice.from(json: $0) }
        return AIProtocolSessionConfigOptionGroup(label: label, options: options)
    }
}

struct AIProtocolSessionConfigOptionInfo {
    let optionID: String
    let category: String?
    let name: String
    let description: String?
    let currentValue: Any?
    let options: [AIProtocolSessionConfigOptionChoice]
    let optionGroups: [AIProtocolSessionConfigOptionGroup]
    let raw: [String: Any]?

    static func from(json: [String: Any]) -> AIProtocolSessionConfigOptionInfo? {
        guard let optionID = parseOptionalString(json["option_id"] ?? json["optionId"]),
              let name = parseOptionalString(json["name"]) else { return nil }
        let category = parseOptionalString(json["category"])
        let description = parseOptionalString(json["description"])
        let currentValue = normalizeProtocolJSONValue(json["current_value"] ?? json["currentValue"])
        let options = parseArrayOfDictionaries(json["options"])
            .compactMap { AIProtocolSessionConfigOptionChoice.from(json: $0) }
        let optionGroups = parseArrayOfDictionaries(json["option_groups"] ?? json["optionGroups"])
            .compactMap { AIProtocolSessionConfigOptionGroup.from(json: $0) }
        let raw = parseConfigOptionsMap(json["raw"])
        return AIProtocolSessionConfigOptionInfo(
            optionID: optionID,
            category: category,
            name: name,
            description: description,
            currentValue: currentValue,
            options: options,
            optionGroups: optionGroups,
            raw: raw
        )
    }
}

struct AISessionConfigOptionsResult {
    let projectName: String
    let workspaceName: String
    let aiTool: AIChatTool
    let sessionId: String?
    let options: [AIProtocolSessionConfigOptionInfo]

    static func from(json: [String: Any]) -> AISessionConfigOptionsResult? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]) else { return nil }
        let sessionId = parseOptionalString(json["session_id"])
        let options = parseArrayOfDictionaries(json["options"])
            .compactMap { AIProtocolSessionConfigOptionInfo.from(json: $0) }
        return AISessionConfigOptionsResult(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId,
            options: options
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
    let toolKind: String?
    let toolTitle: String?
    let toolRawInput: Any?
    let toolRawOutput: Any?
    let toolLocations: [AIProtocolToolCallLocationInfo]?
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
        let toolKind = parseOptionalString(json["tool_kind"])
        let toolTitle = parseOptionalString(json["tool_title"])
        let toolRawInput = json["tool_raw_input"]
        let toolRawOutput = json["tool_raw_output"]
        let toolLocations = (json["tool_locations"] as? [[String: Any]] ?? [])
            .compactMap { AIProtocolToolCallLocationInfo.from(json: $0) }
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
            toolKind: toolKind,
            toolTitle: toolTitle,
            toolRawInput: toolRawInput,
            toolRawOutput: toolRawOutput,
            toolLocations: toolLocations.isEmpty ? nil : toolLocations,
            toolState: toolState,
            toolPartMetadata: toolPartMetadata
        )
    }
}

struct AIProtocolToolCallLocationInfo {
    let uri: String?
    let path: String?
    let line: Int?
    let column: Int?
    let endLine: Int?
    let endColumn: Int?
    let label: String?

    static func from(json: [String: Any]) -> AIProtocolToolCallLocationInfo? {
        let uri = parseOptionalString(json["uri"])
        let path = parseOptionalString(json["path"])
        let line = Int(parseInt64(json["line"]))
        let column = Int(parseInt64(json["column"]))
        let endLine = Int(parseInt64(json["end_line"] ?? json["endLine"]))
        let endColumn = Int(parseInt64(json["end_column"] ?? json["endColumn"]))
        let label = parseOptionalString(json["label"])
        if uri == nil && path == nil && line == 0 && column == 0 && endLine == 0 && endColumn == 0 && label == nil {
            return nil
        }
        return AIProtocolToolCallLocationInfo(
            uri: uri,
            path: path,
            line: line == 0 ? nil : line,
            column: column == 0 ? nil : column,
            endLine: endLine == 0 ? nil : endLine,
            endColumn: endColumn == 0 ? nil : endColumn,
            label: label
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
    let stopReason: String?

    static func from(json: [String: Any]) -> AIChatDoneV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String else { return nil }
        let selectionHint = AISessionSelectionHint.from(json: json["selection_hint"] as? [String: Any])
        let stopReason = parseOptionalString(json["stop_reason"])
        return AIChatDoneV2(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId,
            selectionHint: selectionHint,
            stopReason: stopReason
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
    let optionID: String?
    let label: String
    let description: String

    static func from(json: [String: Any]) -> AIQuestionOptionInfo? {
        guard let label = json["label"] as? String else { return nil }
        let optionID = parseOptionalString(json["option_id"]) ?? parseOptionalString(json["optionId"])
        let description = json["description"] as? String ?? ""
        return AIQuestionOptionInfo(optionID: optionID, label: label, description: description)
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

    /// 将 UI 展示答案映射为协议答案：优先 optionID，自定义答案保持原值。
    func protocolAnswers(from displayAnswers: [[String]]) -> [[String]] {
        displayAnswers.enumerated().map { index, group in
            guard index < questions.count else { return group }
            let options = questions[index].options
            guard !options.isEmpty else { return group }

            return group.map { answer in
                let token = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { return answer }

                if let direct = options.first(where: { option in
                    guard let optionID = option.optionID else { return false }
                    return optionID == token || optionID.caseInsensitiveCompare(token) == .orderedSame
                })?.optionID {
                    return direct
                }

                if let matchedByLabel = options.first(where: {
                    $0.label.caseInsensitiveCompare(token) == .orderedSame
                })?.optionID {
                    return matchedByLabel
                }

                return answer
            }
        }
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

private func parseBool(_ any: Any?) -> Bool? {
    switch any {
    case let value as Bool:
        return value
    case let value as NSNumber:
        return value.boolValue
    case let value as String:
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "true" || normalized == "1" { return true }
        if normalized == "false" || normalized == "0" { return false }
        return nil
    default:
        return nil
    }
}

private func parseUInt64(_ any: Any?) -> UInt64 {
    let value = parseInt64(any)
    if value < 0 { return 0 }
    return UInt64(value)
}

private func parseStringArray(_ any: Any?) -> [String] {
    if let values = any as? [String] {
        return values
    }
    guard let items = any as? [Any] else { return [] }
    return items.compactMap { parseOptionalString($0) }
}

private func parseByteArray(_ any: Any?) -> [UInt8] {
    if let bytes = any as? [UInt8] {
        return bytes
    }
    if let data = any as? Data {
        return [UInt8](data)
    }
    if let items = any as? [Any] {
        return items.compactMap { item in
            if let value = item as? UInt8 { return value }
            if let value = item as? NSNumber { return UInt8(truncating: value) }
            if let value = item as? Int {
                if value < 0 { return 0 }
                if value > Int(UInt8.max) { return UInt8.max }
                return UInt8(value)
            }
            if let value = item as? Int64 {
                if value < 0 { return 0 }
                if value > Int64(UInt8.max) { return UInt8.max }
                return UInt8(value)
            }
            return nil
        }
    }
    return []
}

private extension AISessionSelectionHint {
    static func from(json: [String: Any]?) -> AISessionSelectionHint? {
        guard let json else { return nil }
        let agent = parseOptionalString(json["agent"])?.lowercased()
        let modelProviderID = parseOptionalString(json["model_provider_id"])
        let modelID = parseOptionalString(json["model_id"])
        let configOptions = parseConfigOptionsMap(
            json["config_options"]
                ?? json["configOptions"]
                ?? json["session_config_options"]
                ?? json["sessionConfigOptions"]
        )
        let hint = AISessionSelectionHint(
            agent: agent,
            modelProviderID: modelProviderID,
            modelID: modelID,
            configOptions: configOptions
        )
        return hint.isEmpty ? nil : hint
    }
}

private func parseConfigOptionsMap(_ any: Any?) -> [String: Any]? {
    guard let dict = parseDictionary(any) else { return nil }
    var normalized: [String: Any] = [:]
    normalized.reserveCapacity(dict.count)
    for (key, value) in dict {
        if let normalizedValue = normalizeProtocolJSONValue(value) {
            normalized[key] = normalizedValue
        }
    }
    return normalized.isEmpty ? nil : normalized
}

private func normalizeProtocolJSONValue(_ any: Any?) -> Any? {
    guard let any else { return nil }
    if any is NSNull {
        return NSNull()
    }
    if let dict = parseDictionary(any) {
        var mapped: [String: Any] = [:]
        mapped.reserveCapacity(dict.count)
        for (key, value) in dict {
            mapped[key] = normalizeProtocolJSONValue(value) ?? NSNull()
        }
        return mapped
    }
    if let array = any as? [Any] {
        return array.map { normalizeProtocolJSONValue($0) ?? NSNull() }
    }
    return any
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
    let normalizedRaw = raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let normalized = normalizedRaw.replacingOccurrences(of: "_", with: "-")
    let mapped = switch normalized {
    case "open-code":
        "opencode"
    case "codex-app-server", "codex-app":
        "codex"
    case "copilot-acp", "github-copilot":
        "copilot"
    case "kimi-code":
        "kimi"
    case "claude-code", "claudecode":
        "claude_code"
    default:
        normalizedRaw
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
    let sessionID: String?
    let commands: [AIProtocolSlashCommand]

    static func from(json: [String: Any]) -> AISlashCommandsResult? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]) else { return nil }
        let items = (json["commands"] as? [[String: Any]] ?? []).compactMap { AIProtocolSlashCommand.from(json: $0) }
        return AISlashCommandsResult(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionID: parseOptionalString(json["session_id"]),
            commands: items
        )
    }
}

struct AISlashCommandsUpdateResult {
    let projectName: String
    let workspaceName: String
    let aiTool: AIChatTool
    let sessionID: String
    let commands: [AIProtocolSlashCommand]

    static func from(json: [String: Any]) -> AISlashCommandsUpdateResult? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionID = parseOptionalString(json["session_id"]) else { return nil }
        let items = (json["commands"] as? [[String: Any]] ?? []).compactMap { AIProtocolSlashCommand.from(json: $0) }
        return AISlashCommandsUpdateResult(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionID: sessionID,
            commands: items
        )
    }
}

struct AIProtocolSlashCommand {
    let name: String
    let description: String
    let action: String
    let inputHint: String?

    static func from(json: [String: Any]) -> AIProtocolSlashCommand? {
        guard let name = json["name"] as? String else { return nil }
        let description = json["description"] as? String ?? ""
        let action = json["action"] as? String ?? "client"
        let nestedHint = parseOptionalString(parseDictionary(json["input"])?["hint"])
        let inputHint = nestedHint
            ?? parseOptionalString(json["input_hint"] ?? json["inputHint"] ?? json["hint"])
        return AIProtocolSlashCommand(
            name: name,
            description: description,
            action: action,
            inputHint: inputHint
        )
    }
}

// MARK: - Evolution

struct EvolutionBlockerOptionV2 {
    let optionID: String
    let label: String
    let description: String

    static func from(json: [String: Any]) -> EvolutionBlockerOptionV2? {
        guard let optionID = parseOptionalString(json["option_id"]) else { return nil }
        return EvolutionBlockerOptionV2(
            optionID: optionID,
            label: parseOptionalString(json["label"]) ?? optionID,
            description: parseOptionalString(json["description"]) ?? ""
        )
    }
}

struct EvolutionBlockerItemV2 {
    let blockerID: String
    let status: String
    let cycleID: String
    let stage: String
    let createdAt: String
    let source: String
    let title: String
    let description: String
    let questionType: String
    let options: [EvolutionBlockerOptionV2]
    let allowCustomInput: Bool

    static func from(json: [String: Any]) -> EvolutionBlockerItemV2? {
        guard let blockerID = parseOptionalString(json["blocker_id"]),
              let status = parseOptionalString(json["status"]),
              let cycleID = parseOptionalString(json["cycle_id"]),
              let stage = parseOptionalString(json["stage"]) else { return nil }
        let optionItems = (json["options"] as? [[String: Any]] ?? []).compactMap {
            EvolutionBlockerOptionV2.from(json: $0)
        }
        return EvolutionBlockerItemV2(
            blockerID: blockerID,
            status: status,
            cycleID: cycleID,
            stage: stage,
            createdAt: parseOptionalString(json["created_at"]) ?? "",
            source: parseOptionalString(json["source"]) ?? "unknown",
            title: parseOptionalString(json["title"]) ?? "需要人工处理",
            description: parseOptionalString(json["description"]) ?? "",
            questionType: parseOptionalString(json["question_type"]) ?? "text",
            options: optionItems,
            allowCustomInput: json["allow_custom_input"] as? Bool ?? true
        )
    }
}

struct EvolutionBlockingRequiredV2 {
    let project: String
    let workspace: String
    let trigger: String
    let cycleID: String?
    let stage: String?
    let blockerFilePath: String
    let unresolvedItems: [EvolutionBlockerItemV2]

    static func from(json: [String: Any]) -> EvolutionBlockingRequiredV2? {
        guard let project = parseOptionalString(json["project"]),
              let workspace = parseOptionalString(json["workspace"]),
              let trigger = parseOptionalString(json["trigger"]),
              let blockerFilePath = parseOptionalString(json["blocker_file_path"]) else {
            return nil
        }
        let unresolvedItems = (json["unresolved_items"] as? [[String: Any]] ?? [])
            .compactMap { EvolutionBlockerItemV2.from(json: $0) }
        return EvolutionBlockingRequiredV2(
            project: project,
            workspace: workspace,
            trigger: trigger,
            cycleID: parseOptionalString(json["cycle_id"]),
            stage: parseOptionalString(json["stage"]),
            blockerFilePath: blockerFilePath,
            unresolvedItems: unresolvedItems
        )
    }
}

struct EvolutionBlockersUpdatedV2 {
    let project: String
    let workspace: String
    let unresolvedCount: Int
    let unresolvedItems: [EvolutionBlockerItemV2]

    static func from(json: [String: Any]) -> EvolutionBlockersUpdatedV2? {
        guard let project = parseOptionalString(json["project"]),
              let workspace = parseOptionalString(json["workspace"]) else {
            return nil
        }
        let unresolvedItems = (json["unresolved_items"] as? [[String: Any]] ?? [])
            .compactMap { EvolutionBlockerItemV2.from(json: $0) }
        return EvolutionBlockersUpdatedV2(
            project: project,
            workspace: workspace,
            unresolvedCount: Int(parseInt64(json["unresolved_count"])),
            unresolvedItems: unresolvedItems
        )
    }
}

struct EvolutionBlockerResolutionInputV2 {
    let blockerID: String
    let selectedOptionIDs: [String]
    let answerText: String?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "blocker_id": blockerID,
            "selected_option_ids": selectedOptionIDs
        ]
        if let answerText {
            json["answer_text"] = answerText
        }
        return json
    }
}

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
    let configOptions: [String: Any]

    init(
        stage: String,
        aiTool: AIChatTool,
        mode: String?,
        model: EvolutionModelSelectionV2?,
        configOptions: [String: Any] = [:]
    ) {
        self.stage = stage
        self.aiTool = aiTool
        self.mode = mode
        self.model = model
        self.configOptions = configOptions
    }

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
        let configOptions = parseConfigOptionsMap(json["config_options"] ?? json["configOptions"]) ?? [:]
        return EvolutionStageProfileInfoV2(
            stage: stage,
            aiTool: aiTool,
            mode: mode,
            model: model,
            configOptions: configOptions
        )
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
        if !configOptions.isEmpty {
            json["config_options"] = configOptions
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
    /// 代理开始运行的 RFC3339 时间戳
    let startedAt: String?
    /// 代理运行耗时（毫秒），仅在完成后填充
    let durationMs: UInt64?

    static func from(json: [String: Any]) -> EvolutionAgentInfoV2? {
        guard let stage = json["stage"] as? String,
              let agent = json["agent"] as? String,
              let status = json["status"] as? String else { return nil }
        let toolCallCount = Int(parseInt64(json["tool_call_count"]))
        let latestMessage = parseOptionalString(json["latest_message"])
        let startedAt = parseOptionalString(json["started_at"])
        let durationMs: UInt64? = (json["duration_ms"] as? NSNumber).map { $0.uint64Value }
        return EvolutionAgentInfoV2(
            stage: stage,
            agent: agent,
            status: status,
            toolCallCount: toolCallCount,
            latestMessage: latestMessage,
            startedAt: startedAt,
            durationMs: durationMs
        )
    }
}

struct EvolutionSessionExecutionEntryV2 {
    let stage: String
    let agent: String
    let aiTool: String
    let sessionID: String
    let status: String
    let startedAt: String
    let completedAt: String?
    let durationMs: UInt64?
    let toolCallCount: Int

    static func from(json: [String: Any]) -> EvolutionSessionExecutionEntryV2? {
        guard let stage = parseOptionalString(json["stage"]),
              let sessionID = parseOptionalString(json["session_id"] ?? json["sessionId"]) else { return nil }
        let agent = parseOptionalString(json["agent"]) ?? ""
        let aiTool = parseOptionalString(json["ai_tool"] ?? json["aiTool"]) ?? ""
        let status = parseOptionalString(json["status"]) ?? "unknown"
        let startedAt = parseOptionalString(json["started_at"] ?? json["startedAt"]) ?? ""
        let completedAt = parseOptionalString(json["completed_at"] ?? json["completedAt"])
        let durationMs: UInt64? = {
            if let v = json["duration_ms"] as? UInt64 { return v }
            if let v = json["duration_ms"] as? Int { return UInt64(v) }
            if let v = json["duration_ms"] as? Double { return UInt64(v) }
            if let v = json["durationMs"] as? UInt64 { return v }
            if let v = json["durationMs"] as? Int { return UInt64(v) }
            if let v = json["durationMs"] as? Double { return UInt64(v) }
            return nil
        }()
        let toolCallCount = Int(parseInt64(json["tool_call_count"] ?? json["toolCallCount"]))

        return EvolutionSessionExecutionEntryV2(
            stage: stage,
            agent: agent,
            aiTool: aiTool,
            sessionID: sessionID,
            status: status,
            startedAt: startedAt,
            completedAt: completedAt,
            durationMs: durationMs,
            toolCallCount: toolCallCount
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
    let loopRoundLimit: Int
    let verifyIteration: Int
    let verifyIterationLimit: Int
    let agents: [EvolutionAgentInfoV2]
    let executions: [EvolutionSessionExecutionEntryV2]
    let activeAgents: [String]
    let terminalReasonCode: String?
    let rateLimitErrorMessage: String?

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
        let executions = (json["executions"] as? [[String: Any]] ?? [])
            .compactMap { EvolutionSessionExecutionEntryV2.from(json: $0) }
        let activeAgents = json["active_agents"] as? [String] ?? []
        return EvolutionWorkspaceItemV2(
            project: project,
            workspace: workspace,
            cycleID: cycleID,
            status: status,
            currentStage: currentStage,
            globalLoopRound: Int(parseInt64(json["global_loop_round"])),
            loopRoundLimit: Int(parseInt64(json["loop_round_limit"])),
            verifyIteration: Int(parseInt64(json["verify_iteration"])),
            verifyIterationLimit: Int(parseInt64(json["verify_iteration_limit"])),
            agents: agents,
            executions: executions,
            activeAgents: activeAgents,
            terminalReasonCode: json["terminal_reason_code"] as? String,
            rateLimitErrorMessage: json["rate_limit_error_message"] as? String
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
        parseAIChatTool(aiToolRaw)
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

// MARK: - 进化循环历史数据模型

struct EvolutionCycleStageHistoryEntryV2 {
    let stage: String
    let agent: String
    let aiTool: String
    let status: String
    let durationMs: UInt64?

    static func from(json: [String: Any]) -> EvolutionCycleStageHistoryEntryV2? {
        guard let stage = parseOptionalString(json["stage"]) else { return nil }
        let agent = parseOptionalString(json["agent"]) ?? ""
        let aiTool = parseOptionalString(json["ai_tool"]) ?? ""
        let status = parseOptionalString(json["status"]) ?? "unknown"
        let durationMs: UInt64? = {
            if let v = json["duration_ms"] as? UInt64 { return v }
            if let v = json["duration_ms"] as? Int { return UInt64(v) }
            if let v = json["duration_ms"] as? Double { return UInt64(v) }
            return nil
        }()
        return EvolutionCycleStageHistoryEntryV2(
            stage: stage,
            agent: agent,
            aiTool: aiTool,
            status: status,
            durationMs: durationMs
        )
    }
}

struct EvolutionCycleHistoryItemV2 {
    let cycleID: String
    let status: String
    let globalLoopRound: Int
    let createdAt: String
    let updatedAt: String
    let terminalReasonCode: String?
    let executions: [EvolutionSessionExecutionEntryV2]
    let stages: [EvolutionCycleStageHistoryEntryV2]

    static func from(json: [String: Any]) -> EvolutionCycleHistoryItemV2? {
        guard let cycleID = parseOptionalString(json["cycle_id"]) else { return nil }
        let status = parseOptionalString(json["status"]) ?? "unknown"
        let globalLoopRound = Int(parseInt64(json["global_loop_round"]))
        let createdAt = parseOptionalString(json["created_at"]) ?? ""
        let updatedAt = parseOptionalString(json["updated_at"]) ?? ""
        let terminalReasonCode = parseOptionalString(json["terminal_reason_code"])
        let executions = (json["executions"] as? [[String: Any]] ?? [])
            .compactMap { EvolutionSessionExecutionEntryV2.from(json: $0) }
        let stages = (json["stages"] as? [[String: Any]] ?? [])
            .compactMap { EvolutionCycleStageHistoryEntryV2.from(json: $0) }
        return EvolutionCycleHistoryItemV2(
            cycleID: cycleID,
            status: status,
            globalLoopRound: globalLoopRound,
            createdAt: createdAt,
            updatedAt: updatedAt,
            terminalReasonCode: terminalReasonCode,
            executions: executions,
            stages: stages
        )
    }
}

struct EvidenceSubsystemInfoV2 {
    let id: String
    let kind: String
    let path: String

    static func from(json: [String: Any]) -> EvidenceSubsystemInfoV2? {
        guard let id = parseOptionalString(json["id"]),
              let kind = parseOptionalString(json["kind"]),
              let path = parseOptionalString(json["path"]) else {
            return nil
        }
        return EvidenceSubsystemInfoV2(id: id, kind: kind, path: path)
    }
}

struct EvidenceIssueInfoV2 {
    let code: String
    let level: String
    let message: String

    static func from(json: [String: Any]) -> EvidenceIssueInfoV2? {
        guard let code = parseOptionalString(json["code"]),
              let level = parseOptionalString(json["level"]),
              let message = parseOptionalString(json["message"]) else {
            return nil
        }
        return EvidenceIssueInfoV2(code: code, level: level, message: message)
    }
}

struct EvidenceItemInfoV2 {
    let itemID: String
    let deviceType: String
    let evidenceType: String
    let order: Int
    let path: String
    let title: String
    let description: String
    let scenario: String?
    let subsystem: String?
    let createdAt: String?
    let sizeBytes: UInt64
    let exists: Bool
    let mimeType: String

    static func from(json: [String: Any]) -> EvidenceItemInfoV2? {
        guard let itemID = parseOptionalString(json["item_id"]),
              let deviceType = parseOptionalString(json["device_type"]),
              let evidenceType = parseOptionalString(json["type"]),
              let path = parseOptionalString(json["path"]),
              let title = parseOptionalString(json["title"]),
              let description = parseOptionalString(json["description"]) else {
            return nil
        }
        return EvidenceItemInfoV2(
            itemID: itemID,
            deviceType: deviceType,
            evidenceType: evidenceType,
            order: Int(parseInt64(json["order"])),
            path: path,
            title: title,
            description: description,
            scenario: parseOptionalString(json["scenario"]),
            subsystem: parseOptionalString(json["subsystem"]),
            createdAt: parseOptionalString(json["created_at"]),
            sizeBytes: parseUInt64(json["size_bytes"]),
            exists: parseBool(json["exists"]) ?? false,
            mimeType: parseOptionalString(json["mime_type"]) ?? "application/octet-stream"
        )
    }
}

struct EvidenceSnapshotV2 {
    let project: String
    let workspace: String
    let evidenceRoot: String
    let indexFile: String
    let indexExists: Bool
    let detectedSubsystems: [EvidenceSubsystemInfoV2]
    let detectedDeviceTypes: [String]
    let items: [EvidenceItemInfoV2]
    let issues: [EvidenceIssueInfoV2]
    let updatedAt: String

    static func from(json: [String: Any]) -> EvidenceSnapshotV2? {
        guard let project = parseOptionalString(json["project"]),
              let workspace = parseOptionalString(json["workspace"]),
              let evidenceRoot = parseOptionalString(json["evidence_root"]),
              let indexFile = parseOptionalString(json["index_file"]),
              let updatedAt = parseOptionalString(json["updated_at"]) else {
            return nil
        }
        let detectedSubsystems = (json["detected_subsystems"] as? [[String: Any]] ?? [])
            .compactMap { EvidenceSubsystemInfoV2.from(json: $0) }
        let detectedDeviceTypes = parseStringArray(json["detected_device_types"])
        let items = (json["items"] as? [[String: Any]] ?? [])
            .compactMap { EvidenceItemInfoV2.from(json: $0) }
        let issues = (json["issues"] as? [[String: Any]] ?? [])
            .compactMap { EvidenceIssueInfoV2.from(json: $0) }
        return EvidenceSnapshotV2(
            project: project,
            workspace: workspace,
            evidenceRoot: evidenceRoot,
            indexFile: indexFile,
            indexExists: parseBool(json["index_exists"]) ?? false,
            detectedSubsystems: detectedSubsystems,
            detectedDeviceTypes: detectedDeviceTypes,
            items: items,
            issues: issues,
            updatedAt: updatedAt
        )
    }
}

struct EvidenceRebuildPromptV2 {
    let project: String
    let workspace: String
    let prompt: String
    let evidenceRoot: String
    let indexFile: String
    let detectedSubsystems: [EvidenceSubsystemInfoV2]
    let detectedDeviceTypes: [String]
    let generatedAt: String

    static func from(json: [String: Any]) -> EvidenceRebuildPromptV2? {
        guard let project = parseOptionalString(json["project"]),
              let workspace = parseOptionalString(json["workspace"]),
              let prompt = json["prompt"] as? String,
              let evidenceRoot = parseOptionalString(json["evidence_root"]),
              let indexFile = parseOptionalString(json["index_file"]),
              let generatedAt = parseOptionalString(json["generated_at"]) else {
            return nil
        }
        let detectedSubsystems = (json["detected_subsystems"] as? [[String: Any]] ?? [])
            .compactMap { EvidenceSubsystemInfoV2.from(json: $0) }
        let detectedDeviceTypes = parseStringArray(json["detected_device_types"])
        return EvidenceRebuildPromptV2(
            project: project,
            workspace: workspace,
            prompt: prompt,
            evidenceRoot: evidenceRoot,
            indexFile: indexFile,
            detectedSubsystems: detectedSubsystems,
            detectedDeviceTypes: detectedDeviceTypes,
            generatedAt: generatedAt
        )
    }
}

struct EvidenceItemChunkV2 {
    let project: String
    let workspace: String
    let itemID: String
    let offset: UInt64
    let nextOffset: UInt64
    let eof: Bool
    let totalSizeBytes: UInt64
    let mimeType: String
    let content: [UInt8]

    static func from(json: [String: Any]) -> EvidenceItemChunkV2? {
        guard let project = parseOptionalString(json["project"]),
              let workspace = parseOptionalString(json["workspace"]),
              let itemID = parseOptionalString(json["item_id"]),
              let mimeType = parseOptionalString(json["mime_type"]) else {
            return nil
        }
        return EvidenceItemChunkV2(
            project: project,
            workspace: workspace,
            itemID: itemID,
            offset: parseUInt64(json["offset"]),
            nextOffset: parseUInt64(json["next_offset"]),
            eof: parseBool(json["eof"]) ?? false,
            totalSizeBytes: parseUInt64(json["total_size_bytes"]),
            mimeType: mimeType,
            content: parseByteArray(json["content"])
        )
    }
}

extension AISessionMessagesV2 {
    func toChatMessages() -> [AIChatMessage] {
        messages.compactMap { message in
            let role: AIChatRole = (message.role == "assistant") ? .assistant : .user
            let parts: [AIChatPart] = message.parts.map { AIChatPartNormalization.makeChatPart(from: $0) }
            return AIChatMessage(messageId: message.id, role: role, parts: parts, isStreaming: false)
        }
    }
}
