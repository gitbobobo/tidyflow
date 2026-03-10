import Foundation
import AppIntents

// MARK: - 基础 AI 工具类型（跨平台共享）

/// AI 工具标识，与协议 ai_tool 字段对应
public enum AIChatTool: String, CaseIterable, Identifiable {
    case opencode
    case codex
    case copilot
    case kimi
    case claude_code

    public var id: String { rawValue }
}

/// AI 会话来源
public enum AISessionOrigin: String, Equatable {
    case user
    case evolutionSystem = "evolution_system"

    public static func from(rawValue: String?) -> AISessionOrigin {
        guard let rawValue else { return .user }
        return AISessionOrigin(rawValue: rawValue) ?? .user
    }
}

/// AI 会话选择提示（模型/Provider 偏好）
public struct AISessionSelectionHint: Equatable {
    public let agent: String?
    public let modelProviderID: String?
    public let modelID: String?
    public let configOptions: [String: Any]?

    public var isEmpty: Bool {
        let agentEmpty = agent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let modelEmpty = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let configEmpty = configOptions?.isEmpty ?? true
        return agentEmpty && modelEmpty && configEmpty
    }

    public static func == (lhs: AISessionSelectionHint, rhs: AISessionSelectionHint) -> Bool {
        lhs.agent == rhs.agent &&
        lhs.modelProviderID == rhs.modelProviderID &&
        lhs.modelID == rhs.modelID
    }

    public init(agent: String?, modelProviderID: String?, modelID: String?, configOptions: [String: Any]?) {
        self.agent = agent
        self.modelProviderID = modelProviderID
        self.modelID = modelID
        self.configOptions = configOptions
    }
}

// MARK: - AI Chat Protocol Models (vNext)

public struct AISessionStartedV2 {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: AIChatTool
    public let sessionId: String
    public let title: String
    public let updatedAt: Int64
    public let origin: AISessionOrigin
    public let selectionHint: AISessionSelectionHint?

    public static func from(json: [String: Any]) -> AISessionStartedV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String,
              let title = json["title"] as? String else { return nil }
        let updatedAt = parseInt64(json["updated_at"])
        let origin = parseAISessionOrigin(json["session_origin"])
        let selectionHint = AISessionSelectionHint.from(json: json["selection_hint"] as? [String: Any])
        return AISessionStartedV2(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId,
            title: title,
            updatedAt: updatedAt,
            origin: origin,
            selectionHint: selectionHint
        )
    }

    public init(projectName: String, workspaceName: String, aiTool: AIChatTool, sessionId: String, title: String, updatedAt: Int64, origin: AISessionOrigin, selectionHint: AISessionSelectionHint?) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.sessionId = sessionId
        self.title = title
        self.updatedAt = updatedAt
        self.origin = origin
        self.selectionHint = selectionHint
    }
}

public struct AISessionListV2 {
    public let projectName: String
    public let workspaceName: String
    public let filterAIChatTool: AIChatTool?
    public let sessions: [AIProtocolSessionInfo]
    public let hasMore: Bool
    public let nextCursor: String?

    public static func from(json: [String: Any]) -> AISessionListV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String else { return nil }
        let filterAIChatTool = parseAIChatTool(json["filter_ai_tool"])
        let items = (json["sessions"] as? [[String: Any]] ?? []).compactMap { AIProtocolSessionInfo.from(json: $0) }
        let hasMore = parseBool(json["has_more"]) ?? false
        let nextCursor = parseOptionalString(json["next_cursor"])
        return AISessionListV2(
            projectName: projectName,
            workspaceName: workspaceName,
            filterAIChatTool: filterAIChatTool,
            sessions: items,
            hasMore: hasMore,
            nextCursor: nextCursor
        )
    }

    public init(projectName: String, workspaceName: String, filterAIChatTool: AIChatTool?, sessions: [AIProtocolSessionInfo], hasMore: Bool, nextCursor: String?) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.filterAIChatTool = filterAIChatTool
        self.sessions = sessions
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }
}

public struct AISessionMessagesV2 {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: AIChatTool
    public let sessionId: String
    public let beforeMessageId: String?
    public let messages: [AIProtocolMessageInfo]
    public let hasMore: Bool
    public let nextBeforeMessageId: String?
    public let selectionHint: AISessionSelectionHint?
    public let truncated: Bool

    public static func from(json: [String: Any]) -> AISessionMessagesV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String else { return nil }
        let beforeMessageId = parseOptionalString(json["before_message_id"])
        let messages = (json["messages"] as? [[String: Any]] ?? []).compactMap { AIProtocolMessageInfo.from(json: $0) }
        let hasMore = parseBool(json["has_more"]) ?? false
        let nextBeforeMessageId = parseOptionalString(json["next_before_message_id"])
        let selectionHint = AISessionSelectionHint.from(json: json["selection_hint"] as? [String: Any])
        let truncated = parseBool(json["truncated"]) ?? false
        return AISessionMessagesV2(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId,
            beforeMessageId: beforeMessageId,
            messages: messages,
            hasMore: hasMore,
            nextBeforeMessageId: nextBeforeMessageId,
            selectionHint: selectionHint,
            truncated: truncated
        )
    }

    public init(projectName: String, workspaceName: String, aiTool: AIChatTool, sessionId: String, beforeMessageId: String?, messages: [AIProtocolMessageInfo], hasMore: Bool, nextBeforeMessageId: String?, selectionHint: AISessionSelectionHint?, truncated: Bool) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.sessionId = sessionId
        self.beforeMessageId = beforeMessageId
        self.messages = messages
        self.hasMore = hasMore
        self.nextBeforeMessageId = nextBeforeMessageId
        self.selectionHint = selectionHint
        self.truncated = truncated
    }
}

/// AI 会话订阅确认（`ai_session_subscribe_ack`）
///
/// v7 新增 `projectName`/`workspaceName` 字段，客户端**必须**按
/// `{project}::{workspace}::{ai_tool}::{session_id}` 四元组路由到对应会话状态，
/// 不允许按 `sessionId` 单键或 `sessionKey` 字符串拼接作为唯一归属依据。
public struct AISessionSubscribeAck {
    public let projectName: String
    public let workspaceName: String
    public let sessionId: String
    public let sessionKey: String

    public static func from(json: [String: Any]) -> AISessionSubscribeAck? {
        guard let sessionId = json["session_id"] as? String,
              let sessionKey = json["session_key"] as? String else { return nil }
        // project_name / workspace_name 为 v7 新增字段，兼容旧 Core 时降级为空字符串
        let projectName = (json["project_name"] as? String) ?? ""
        let workspaceName = (json["workspace_name"] as? String) ?? ""
        return AISessionSubscribeAck(
            projectName: projectName,
            workspaceName: workspaceName,
            sessionId: sessionId,
            sessionKey: sessionKey
        )
    }

    public init(projectName: String, workspaceName: String, sessionId: String, sessionKey: String) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.sessionId = sessionId
        self.sessionKey = sessionKey
    }
}

public enum AIProtocolSessionCacheOp {
    case messageUpdated(messageId: String, role: String)
    case partUpdated(messageId: String, part: AIProtocolPartInfo)
    case partDelta(messageId: String, partId: String, partType: String, field: String, delta: String)

    public static func from(json: [String: Any]) -> AIProtocolSessionCacheOp? {
        if let payload = json["message_updated"] as? [String: Any] {
            guard let messageId = parseOptionalString(payload["message_id"]),
                  let role = parseOptionalString(payload["role"]) else { return nil }
            return .messageUpdated(messageId: messageId, role: role)
        }
        if let payload = json["part_updated"] as? [String: Any] {
            guard let messageId = parseOptionalString(payload["message_id"]),
                  let partDict = payload["part"] as? [String: Any],
                  let part = AIProtocolPartInfo.from(json: partDict) else { return nil }
            return .partUpdated(messageId: messageId, part: part)
        }
        if let payload = json["part_delta"] as? [String: Any] {
            guard let messageId = parseOptionalString(payload["message_id"]),
                  let partId = parseOptionalString(payload["part_id"]),
                  let partType = parseOptionalString(payload["part_type"]),
                  let field = parseOptionalString(payload["field"]),
                  let delta = payload["delta"] as? String else { return nil }
            return .partDelta(
                messageId: messageId,
                partId: partId,
                partType: partType,
                field: field,
                delta: delta
            )
        }

        let type = parseOptionalString(json["type"] ?? json["kind"])?.lowercased()
        if type == "message_updated" {
            guard let messageId = parseOptionalString(json["message_id"]),
                  let role = parseOptionalString(json["role"]) else { return nil }
            return .messageUpdated(messageId: messageId, role: role)
        }
        if type == "part_updated" {
            guard let messageId = parseOptionalString(json["message_id"]),
                  let partDict = json["part"] as? [String: Any],
                  let part = AIProtocolPartInfo.from(json: partDict) else { return nil }
            return .partUpdated(messageId: messageId, part: part)
        }
        if type == "part_delta" {
            guard let messageId = parseOptionalString(json["message_id"]),
                  let partId = parseOptionalString(json["part_id"]),
                  let partType = parseOptionalString(json["part_type"]),
                  let field = parseOptionalString(json["field"]),
                  let delta = json["delta"] as? String else { return nil }
            return .partDelta(
                messageId: messageId,
                partId: partId,
                partType: partType,
                field: field,
                delta: delta
            )
        }

        return nil
    }
}

public struct AISessionMessagesUpdateV2 {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: AIChatTool
    public let sessionId: String
    public let cacheRevision: UInt64
    public let isStreaming: Bool
    public let selectionHint: AISessionSelectionHint?
    public let messages: [AIProtocolMessageInfo]?
    public let ops: [AIProtocolSessionCacheOp]?

    public static func from(json: [String: Any]) -> AISessionMessagesUpdateV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String else { return nil }
        let cacheRevision = parseUInt64(json["cache_revision"])
        let isStreaming = parseBool(json["is_streaming"]) ?? false
        let selectionHint = AISessionSelectionHint.from(json: json["selection_hint"] as? [String: Any])

        let messages: [AIProtocolMessageInfo]? = {
            guard let array = json["messages"] as? [[String: Any]] else { return nil }
            return array.compactMap { AIProtocolMessageInfo.from(json: $0) }
        }()
        let ops: [AIProtocolSessionCacheOp]? = {
            guard let array = json["ops"] as? [[String: Any]] else { return nil }
            return array.compactMap { AIProtocolSessionCacheOp.from(json: $0) }
        }()

        return AISessionMessagesUpdateV2(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId,
            cacheRevision: cacheRevision,
            isStreaming: isStreaming,
            selectionHint: selectionHint,
            messages: messages,
            ops: ops
        )
    }

    public init(projectName: String, workspaceName: String, aiTool: AIChatTool, sessionId: String, cacheRevision: UInt64, isStreaming: Bool, selectionHint: AISessionSelectionHint?, messages: [AIProtocolMessageInfo]?, ops: [AIProtocolSessionCacheOp]?) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.sessionId = sessionId
        self.cacheRevision = cacheRevision
        self.isStreaming = isStreaming
        self.selectionHint = selectionHint
        self.messages = messages
        self.ops = ops
    }
}

public struct AISessionStatusInfoV2 {
    /// "idle" | "running" | "awaiting_input" | "success" | "failure" | "cancelled"
    public let status: String
    public let errorMessage: String?
    public let contextRemainingPercent: Double?
    /// 当前正在执行的工具名称（可选，由后端推送）
    public let toolName: String?

    public static func from(json: [String: Any]) -> AISessionStatusInfoV2? {
        guard let status = json["status"] as? String else { return nil }
        let errorMessage = json["error_message"] as? String
        let contextRemainingPercent = parseDouble(json["context_remaining_percent"])
        let toolName = json["tool_name"] as? String
        return AISessionStatusInfoV2(
            status: status,
            errorMessage: errorMessage,
            contextRemainingPercent: contextRemainingPercent,
            toolName: toolName
        )
    }

    public init(status: String, errorMessage: String?, contextRemainingPercent: Double?, toolName: String?) {
        self.status = status
        self.errorMessage = errorMessage
        self.contextRemainingPercent = contextRemainingPercent
        self.toolName = toolName
    }
}

public struct AISessionStatusResultV2 {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: AIChatTool
    public let sessionId: String
    public let status: AISessionStatusInfoV2

    public static func from(json: [String: Any]) -> AISessionStatusResultV2? {
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

    public init(projectName: String, workspaceName: String, aiTool: AIChatTool, sessionId: String, status: AISessionStatusInfoV2) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.sessionId = sessionId
        self.status = status
    }
}

public struct AISessionStatusUpdateV2 {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: AIChatTool
    public let sessionId: String
    public let status: AISessionStatusInfoV2

    public static func from(json: [String: Any]) -> AISessionStatusUpdateV2? {
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

    public init(projectName: String, workspaceName: String, aiTool: AIChatTool, sessionId: String, status: AISessionStatusInfoV2) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.sessionId = sessionId
        self.status = status
    }
}

public struct AIProtocolSessionConfigOptionChoice {
    public let value: Any
    public let label: String
    public let description: String?

    public static func from(json: [String: Any]) -> AIProtocolSessionConfigOptionChoice? {
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

    public init(value: Any, label: String, description: String?) {
        self.value = value
        self.label = label
        self.description = description
    }
}

public struct AIProtocolSessionConfigOptionGroup {
    public let label: String
    public let options: [AIProtocolSessionConfigOptionChoice]

    public static func from(json: [String: Any]) -> AIProtocolSessionConfigOptionGroup? {
        guard let label = parseOptionalString(json["label"]) else { return nil }
        let options = parseArrayOfDictionaries(json["options"])
            .compactMap { AIProtocolSessionConfigOptionChoice.from(json: $0) }
        return AIProtocolSessionConfigOptionGroup(label: label, options: options)
    }

    public init(label: String, options: [AIProtocolSessionConfigOptionChoice]) {
        self.label = label
        self.options = options
    }
}

public struct AIProtocolSessionConfigOptionInfo {
    public let optionID: String
    public let category: String?
    public let name: String
    public let description: String?
    public let currentValue: Any?
    public let options: [AIProtocolSessionConfigOptionChoice]
    public let optionGroups: [AIProtocolSessionConfigOptionGroup]
    public let raw: [String: Any]?

    public static func from(json: [String: Any]) -> AIProtocolSessionConfigOptionInfo? {
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

    public init(optionID: String, category: String?, name: String, description: String?, currentValue: Any?, options: [AIProtocolSessionConfigOptionChoice], optionGroups: [AIProtocolSessionConfigOptionGroup], raw: [String: Any]?) {
        self.optionID = optionID
        self.category = category
        self.name = name
        self.description = description
        self.currentValue = currentValue
        self.options = options
        self.optionGroups = optionGroups
        self.raw = raw
    }
}

public struct AISessionConfigOptionsResult {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: AIChatTool
    public let sessionId: String?
    public let options: [AIProtocolSessionConfigOptionInfo]

    public static func from(json: [String: Any]) -> AISessionConfigOptionsResult? {
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

    public init(projectName: String, workspaceName: String, aiTool: AIChatTool, sessionId: String?, options: [AIProtocolSessionConfigOptionInfo]) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.sessionId = sessionId
        self.options = options
    }
}

public struct AIProtocolSessionInfo {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: AIChatTool
    public let id: String
    public let title: String
    public let updatedAt: Int64
    public let origin: AISessionOrigin

    public static func from(json: [String: Any]) -> AIProtocolSessionInfo? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let id = json["id"] as? String,
              let title = json["title"] as? String else { return nil }
        let updatedAt = parseInt64(json["updated_at"])
        let origin = parseAISessionOrigin(json["session_origin"])
        return AIProtocolSessionInfo(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            id: id,
            title: title,
            updatedAt: updatedAt,
            origin: origin
        )
    }

    public init(projectName: String, workspaceName: String, aiTool: AIChatTool, id: String, title: String, updatedAt: Int64, origin: AISessionOrigin) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.origin = origin
    }
}

public struct AIProtocolPartInfo {
    public let id: String
    public let partType: String
    public let text: String?
    public let mime: String?
    public let filename: String?
    public let url: String?
    public let synthetic: Bool?
    public let ignored: Bool?
    public let source: [String: Any]?
    public let toolName: String?
    public let toolCallId: String?
    public let toolKind: String?
    public let toolView: AIToolView?

    public static func from(json: [String: Any]) -> AIProtocolPartInfo? {
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
        let toolView = AIToolView.from(json: json["tool_view"] as? [String: Any])
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
            toolView: toolView
        )
    }

    public init(id: String, partType: String, text: String?, mime: String?, filename: String?, url: String?, synthetic: Bool?, ignored: Bool?, source: [String: Any]?, toolName: String?, toolCallId: String?, toolKind: String?, toolView: AIToolView?) {
        self.id = id
        self.partType = partType
        self.text = text
        self.mime = mime
        self.filename = filename
        self.url = url
        self.synthetic = synthetic
        self.ignored = ignored
        self.source = source
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.toolKind = toolKind
        self.toolView = toolView
    }
}

public enum AIToolViewSectionStyle: String {
    case text
    case code
    case diff
    case markdown
    case terminal
}

/// AI 工具调用状态（v7 协议）
public enum AIToolStatus: String, Equatable {
    case pending
    case running
    case completed
    case error
    case unknown
}

public struct AIToolViewSection: Identifiable, Equatable {
    public let id: String
    public let title: String
    public var content: String
    public let style: AIToolViewSectionStyle
    public let language: String?
    public let copyable: Bool
    public let collapsedByDefault: Bool

    public static func from(json: [String: Any]) -> AIToolViewSection? {
        guard let id = parseOptionalString(json["id"]),
              let title = parseOptionalString(json["title"]),
              let content = json["content"] as? String,
              let styleRaw = parseOptionalString(json["style"]),
              let style = AIToolViewSectionStyle(rawValue: styleRaw) else { return nil }
        return AIToolViewSection(
            id: id,
            title: title,
            content: content,
            style: style,
            language: parseOptionalString(json["language"]),
            copyable: parseBool(json["copyable"]) ?? true,
            collapsedByDefault: parseBool(json["collapsed_by_default"]) ?? false
        )
    }

    public init(id: String, title: String, content: String, style: AIToolViewSectionStyle, language: String?, copyable: Bool, collapsedByDefault: Bool) {
        self.id = id
        self.title = title
        self.content = content
        self.style = style
        self.language = language
        self.copyable = copyable
        self.collapsedByDefault = collapsedByDefault
    }
}

public struct AIToolViewLocation: Equatable {
    public let uri: String?
    public let path: String?
    public let line: Int?
    public let column: Int?
    public let endLine: Int?
    public let endColumn: Int?
    public let label: String?

    public static func from(json: [String: Any]) -> AIToolViewLocation? {
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
        return AIToolViewLocation(
            uri: uri,
            path: path,
            line: line == 0 ? nil : line,
            column: column == 0 ? nil : column,
            endLine: endLine == 0 ? nil : endLine,
            endColumn: endColumn == 0 ? nil : endColumn,
            label: label
        )
    }

    public init(uri: String?, path: String?, line: Int?, column: Int?, endLine: Int?, endColumn: Int?, label: String?) {
        self.uri = uri
        self.path = path
        self.line = line
        self.column = column
        self.endLine = endLine
        self.endColumn = endColumn
        self.label = label
    }
}

public struct AIToolViewQuestion: Equatable {
    public let requestID: String
    public let toolMessageID: String?
    public let promptItems: [AIQuestionInfo]
    public let interactive: Bool
    public let answers: [[String]]?

    public static func from(json: [String: Any]?) -> AIToolViewQuestion? {
        guard let json,
              let requestID = parseOptionalString(json["request_id"]) else { return nil }
        let promptItems = parseArrayOfDictionaries(json["prompt_items"])
            .compactMap { AIQuestionInfo.from(json: $0) }
        guard !promptItems.isEmpty else { return nil }
        let answers = (json["answers"] as? [Any])?.map { group -> [String] in
            if let values = group as? [String] {
                return values
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            if let values = group as? [Any] {
                return values.compactMap { AIQuestionRequestInfo.stringValue($0) }
            }
            return []
        }
        return AIToolViewQuestion(
            requestID: requestID,
            toolMessageID: parseOptionalString(json["tool_message_id"]),
            promptItems: promptItems,
            interactive: parseBool(json["interactive"]) ?? false,
            answers: answers
        )
    }

    public init(requestID: String, toolMessageID: String?, promptItems: [AIQuestionInfo], interactive: Bool, answers: [[String]]?) {
        self.requestID = requestID
        self.toolMessageID = toolMessageID
        self.promptItems = promptItems
        self.interactive = interactive
        self.answers = answers
    }
}

public struct AIToolLinkedSession: Equatable {
    public let sessionID: String
    public let agentName: String
    public let description: String

    public static func from(json: [String: Any]?) -> AIToolLinkedSession? {
        guard let json,
              let sessionID = parseOptionalString(json["session_id"]),
              let agentName = parseOptionalString(json["agent_name"]),
              let description = parseOptionalString(json["description"]) else { return nil }
        return AIToolLinkedSession(sessionID: sessionID, agentName: agentName, description: description)
    }

    public init(sessionID: String, agentName: String, description: String) {
        self.sessionID = sessionID
        self.agentName = agentName
        self.description = description
    }
}

public struct AIToolView: Equatable {
    public let status: AIToolStatus
    public let displayTitle: String
    public let statusText: String
    public let summary: String?
    public let headerCommandSummary: String?
    public let durationMs: Double?
    public let sections: [AIToolViewSection]
    public let locations: [AIToolViewLocation]
    public let question: AIToolViewQuestion?
    public let linkedSession: AIToolLinkedSession?

    public static func from(json: [String: Any]?) -> AIToolView? {
        guard let json,
              let statusRaw = parseOptionalString(json["status"]),
              let displayTitle = parseOptionalString(json["display_title"]),
              let statusText = parseOptionalString(json["status_text"]) else { return nil }
        return AIToolView(
            status: AIToolStatus(rawValue: statusRaw) ?? .unknown,
            displayTitle: displayTitle,
            statusText: statusText,
            summary: parseOptionalString(json["summary"]),
            headerCommandSummary: parseOptionalString(json["header_command_summary"]),
            durationMs: parseDouble(json["duration_ms"]),
            sections: parseArrayOfDictionaries(json["sections"]).compactMap { AIToolViewSection.from(json: $0) },
            locations: parseArrayOfDictionaries(json["locations"]).compactMap { AIToolViewLocation.from(json: $0) },
            question: AIToolViewQuestion.from(json: json["question"] as? [String: Any]),
            linkedSession: AIToolLinkedSession.from(json: json["linked_session"] as? [String: Any])
        )
    }

    public init(status: AIToolStatus, displayTitle: String, statusText: String, summary: String?, headerCommandSummary: String?, durationMs: Double?, sections: [AIToolViewSection], locations: [AIToolViewLocation], question: AIToolViewQuestion?, linkedSession: AIToolLinkedSession?) {
        self.status = status
        self.displayTitle = displayTitle
        self.statusText = statusText
        self.summary = summary
        self.headerCommandSummary = headerCommandSummary
        self.durationMs = durationMs
        self.sections = sections
        self.locations = locations
        self.question = question
        self.linkedSession = linkedSession
    }
}

public struct AIProtocolMessageInfo {
    public let id: String
    public let role: String
    public let createdAt: Int64?
    public let agent: String?
    public let modelProviderID: String?
    public let modelID: String?
    public let parts: [AIProtocolPartInfo]

    public static func from(json: [String: Any]) -> AIProtocolMessageInfo? {
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

    public init(id: String, role: String, createdAt: Int64?, agent: String?, modelProviderID: String?, modelID: String?, parts: [AIProtocolPartInfo]) {
        self.id = id
        self.role = role
        self.createdAt = createdAt
        self.agent = agent
        self.modelProviderID = modelProviderID
        self.modelID = modelID
        self.parts = parts
    }
}

public struct AIChatDoneV2 {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: AIChatTool
    public let sessionId: String
    public let selectionHint: AISessionSelectionHint?
    public let stopReason: String?
    /// v1.42：路由决策元数据（旧版消息中可为 nil）
    public let routeDecision: AIRouteDecisionInfo?
    /// v1.42：预算状态（旧版消息中可为 nil）
    public let budgetStatus: AIBudgetStatus?

    public static func from(json: [String: Any]) -> AIChatDoneV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String else { return nil }
        let selectionHint = AISessionSelectionHint.from(json: json["selection_hint"] as? [String: Any])
        let stopReason = parseOptionalString(json["stop_reason"])
        let routeDecision = AIRouteDecisionInfo.from(json: json["route_decision"] as? [String: Any])
        let budgetStatus = AIBudgetStatus.from(json: json["budget_status"] as? [String: Any])
        return AIChatDoneV2(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId,
            selectionHint: selectionHint,
            stopReason: stopReason,
            routeDecision: routeDecision,
            budgetStatus: budgetStatus
        )
    }

    public init(projectName: String, workspaceName: String, aiTool: AIChatTool, sessionId: String, selectionHint: AISessionSelectionHint?, stopReason: String?, routeDecision: AIRouteDecisionInfo? = nil, budgetStatus: AIBudgetStatus? = nil) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.sessionId = sessionId
        self.selectionHint = selectionHint
        self.stopReason = stopReason
        self.routeDecision = routeDecision
        self.budgetStatus = budgetStatus
    }
}

public struct AIChatErrorV2 {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: AIChatTool
    public let sessionId: String
    public let error: String
    /// 结构化错误码（与 Core 共享，用于状态迁移决策）
    public let errorCode: CoreErrorCode
    /// v1.42：路由决策元数据（旧版消息中可为 nil）
    public let routeDecision: AIRouteDecisionInfo?

    public static func from(json: [String: Any]) -> AIChatErrorV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String,
              let error = json["error"] as? String else { return nil }
        let errorCode = CoreErrorCode.parse(json["error_code"] as? String ?? "ai_session_error")
        let routeDecision = AIRouteDecisionInfo.from(json: json["route_decision"] as? [String: Any])
        return AIChatErrorV2(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            sessionId: sessionId,
            error: error,
            errorCode: errorCode,
            routeDecision: routeDecision
        )
    }

    public init(projectName: String, workspaceName: String, aiTool: AIChatTool, sessionId: String, error: String, errorCode: CoreErrorCode, routeDecision: AIRouteDecisionInfo? = nil) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.sessionId = sessionId
        self.error = error
        self.errorCode = errorCode
        self.routeDecision = routeDecision
    }
}

/// 服务端收到 AIChatSend 后、启动 AI adapter 前立即发出，用于通知客户端进入 pending 态。
public struct AIChatPendingV2 {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: AIChatTool
    public let sessionId: String

    public static func from(json: [String: Any]) -> AIChatPendingV2? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]),
              let sessionId = json["session_id"] as? String else { return nil }
        return AIChatPendingV2(projectName: projectName, workspaceName: workspaceName, aiTool: aiTool, sessionId: sessionId)
    }

    public init(projectName: String, workspaceName: String, aiTool: AIChatTool, sessionId: String) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.sessionId = sessionId
    }
}

public struct AIQuestionOptionInfo: Equatable {
    public let optionID: String?
    public let label: String
    public let description: String

    public static func from(json: [String: Any]) -> AIQuestionOptionInfo? {
        guard let label = json["label"] as? String else { return nil }
        let optionID = parseOptionalString(json["option_id"]) ?? parseOptionalString(json["optionId"])
        let description = json["description"] as? String ?? ""
        return AIQuestionOptionInfo(optionID: optionID, label: label, description: description)
    }

    public init(optionID: String?, label: String, description: String) {
        self.optionID = optionID
        self.label = label
        self.description = description
    }
}

public struct AIQuestionInfo: Equatable {
    public let question: String
    public let header: String
    public let options: [AIQuestionOptionInfo]
    public let multiple: Bool
    public let custom: Bool

    public static func from(json: [String: Any]) -> AIQuestionInfo? {
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

    public init(question: String, header: String, options: [AIQuestionOptionInfo], multiple: Bool, custom: Bool) {
        self.question = question
        self.header = header
        self.options = options
        self.multiple = multiple
        self.custom = custom
    }
}

public struct AIQuestionRequestInfo {
    public let id: String
    public let sessionId: String
    public let questions: [AIQuestionInfo]
    public let toolMessageId: String?
    public let toolCallId: String?

    public static func from(json: [String: Any]) -> AIQuestionRequestInfo? {
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
    public func protocolAnswers(from displayAnswers: [[String]]) -> [[String]] {
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

    public static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    public init(id: String, sessionId: String, questions: [AIQuestionInfo], toolMessageId: String?, toolCallId: String?) {
        self.id = id
        self.sessionId = sessionId
        self.questions = questions
        self.toolMessageId = toolMessageId
        self.toolCallId = toolCallId
    }
}

public struct AIQuestionAskedV2 {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: AIChatTool
    public let sessionId: String
    public let request: AIQuestionRequestInfo

    public static func from(json: [String: Any]) -> AIQuestionAskedV2? {
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

    public init(projectName: String, workspaceName: String, aiTool: AIChatTool, sessionId: String, request: AIQuestionRequestInfo) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.sessionId = sessionId
        self.request = request
    }
}

public struct AIQuestionClearedV2 {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: AIChatTool
    public let sessionId: String
    public let requestId: String

    public static func from(json: [String: Any]) -> AIQuestionClearedV2? {
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

    public init(projectName: String, workspaceName: String, aiTool: AIChatTool, sessionId: String, requestId: String) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.sessionId = sessionId
        self.requestId = requestId
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

// MARK: - v1.42 路由决策与预算状态

/// AI 路由决策元数据（由 Core 权威计算，客户端只消费）
public struct AIRouteDecisionInfo {
    /// 最终选定的 provider ID
    public let providerId: String
    /// 最终选定的 model ID
    public let modelId: String
    /// 选定的 agent（若有）
    public let agent: String?
    /// 任务类型（"chat" | "code_generation" | "code_completion" 等）
    public let taskType: String
    /// 选择来源（"explicit" | "task_type_policy" | "selection_hint" | "default"）
    public let selectedBy: String
    /// 是否为降级路由
    public let isFallback: Bool
    /// 降级原因（isFallback=true 时有值）
    public let fallbackReason: String?

    public static func from(json: [String: Any]?) -> AIRouteDecisionInfo? {
        guard let json,
              let providerId = json["provider_id"] as? String,
              let modelId = json["model_id"] as? String,
              let taskType = json["task_type"] as? String,
              let selectedBy = json["selected_by"] as? String else { return nil }
        let isFallback = (json["is_fallback"] as? Bool) ?? false
        return AIRouteDecisionInfo(
            providerId: providerId,
            modelId: modelId,
            agent: parseOptionalString(json["agent"]),
            taskType: taskType,
            selectedBy: selectedBy,
            isFallback: isFallback,
            fallbackReason: parseOptionalString(json["fallback_reason"])
        )
    }

    public init(providerId: String, modelId: String, agent: String?, taskType: String, selectedBy: String, isFallback: Bool, fallbackReason: String?) {
        self.providerId = providerId
        self.modelId = modelId
        self.agent = agent
        self.taskType = taskType
        self.selectedBy = selectedBy
        self.isFallback = isFallback
        self.fallbackReason = fallbackReason
    }
}

/// AI 预算状态（由 Core 权威计算，客户端只消费）
public struct AIBudgetStatus {
    /// 是否已超阈值
    public let budgetExceeded: Bool
    /// 最近超阈值原因（budgetExceeded=true 时有值）
    public let lastExceededReason: String?
    /// 当前工作区总 token 数（估算，可选）
    public let totalTokens: UInt64?
    /// 当前工作区估算成本（归一化单位，可选）
    public let estimatedCost: Double?

    public static func from(json: [String: Any]?) -> AIBudgetStatus? {
        guard let json else { return nil }
        let budgetExceeded = (json["budget_exceeded"] as? Bool) ?? false
        let totalTokens = (json["total_tokens"] as? UInt64)
            ?? (json["total_tokens"] as? Int64).map { UInt64(max(0, $0)) }
        let estimatedCost = json["estimated_cost"] as? Double
        return AIBudgetStatus(
            budgetExceeded: budgetExceeded,
            lastExceededReason: parseOptionalString(json["last_exceeded_reason"]),
            totalTokens: totalTokens,
            estimatedCost: estimatedCost
        )
    }

    public init(budgetExceeded: Bool, lastExceededReason: String?, totalTokens: UInt64?, estimatedCost: Double?) {
        self.budgetExceeded = budgetExceeded
        self.lastExceededReason = lastExceededReason
        self.totalTokens = totalTokens
        self.estimatedCost = estimatedCost
    }
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

private func parseAISessionOrigin(_ any: Any?) -> AISessionOrigin {
    AISessionOrigin.from(rawValue: parseOptionalString(any))
}

// MARK: - Provider / Agent 列表

public struct AIProviderListResult {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: AIChatTool
    public let providers: [AIProtocolProviderInfo]

    public static func from(json: [String: Any]) -> AIProviderListResult? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]) else { return nil }
        let items = (json["providers"] as? [[String: Any]] ?? []).compactMap { AIProtocolProviderInfo.from(json: $0) }
        return AIProviderListResult(projectName: projectName, workspaceName: workspaceName, aiTool: aiTool, providers: items)
    }

    public init(projectName: String, workspaceName: String, aiTool: AIChatTool, providers: [AIProtocolProviderInfo]) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.providers = providers
    }
}

public struct AIProtocolProviderInfo {
    public let id: String
    public let name: String
    public let models: [AIProtocolModelInfo]

    public static func from(json: [String: Any]) -> AIProtocolProviderInfo? {
        guard let id = json["id"] as? String else { return nil }
        let name = json["name"] as? String ?? id
        let models = (json["models"] as? [[String: Any]] ?? []).compactMap { AIProtocolModelInfo.from(json: $0) }
        return AIProtocolProviderInfo(id: id, name: name, models: models)
    }

    public init(id: String, name: String, models: [AIProtocolModelInfo]) {
        self.id = id
        self.name = name
        self.models = models
    }
}

public struct AIProtocolModelInfo {
    public let id: String
    public let name: String
    public let providerID: String
    public let supportsImageInput: Bool

    public static func from(json: [String: Any]) -> AIProtocolModelInfo? {
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

    public init(id: String, name: String, providerID: String, supportsImageInput: Bool) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.supportsImageInput = supportsImageInput
    }
}

public struct AIAgentListResult {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: AIChatTool
    public let agents: [AIProtocolAgentInfo]

    public static func from(json: [String: Any]) -> AIAgentListResult? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = parseAIChatTool(json["ai_tool"]) else { return nil }
        let items = (json["agents"] as? [[String: Any]] ?? []).compactMap { AIProtocolAgentInfo.from(json: $0) }
        return AIAgentListResult(projectName: projectName, workspaceName: workspaceName, aiTool: aiTool, agents: items)
    }

    public init(projectName: String, workspaceName: String, aiTool: AIChatTool, agents: [AIProtocolAgentInfo]) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.agents = agents
    }
}

public struct AIProtocolAgentInfo {
    public let name: String
    public let description: String?
    public let mode: String?
    public let color: String?
    public let defaultProviderID: String?
    public let defaultModelID: String?

    public static func from(json: [String: Any]) -> AIProtocolAgentInfo? {
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

    public init(name: String, description: String?, mode: String?, color: String?, defaultProviderID: String?, defaultModelID: String?) {
        self.name = name
        self.description = description
        self.mode = mode
        self.color = color
        self.defaultProviderID = defaultProviderID
        self.defaultModelID = defaultModelID
    }
}

// MARK: - 斜杠命令列表

public struct AISlashCommandsResult {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: AIChatTool
    public let sessionID: String?
    public let commands: [AIProtocolSlashCommand]

    public static func from(json: [String: Any]) -> AISlashCommandsResult? {
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

    public init(projectName: String, workspaceName: String, aiTool: AIChatTool, sessionID: String?, commands: [AIProtocolSlashCommand]) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.sessionID = sessionID
        self.commands = commands
    }
}

public struct AISlashCommandsUpdateResult {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: AIChatTool
    public let sessionID: String
    public let commands: [AIProtocolSlashCommand]

    public static func from(json: [String: Any]) -> AISlashCommandsUpdateResult? {
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

    public init(projectName: String, workspaceName: String, aiTool: AIChatTool, sessionID: String, commands: [AIProtocolSlashCommand]) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.sessionID = sessionID
        self.commands = commands
    }
}

public struct AIProtocolSlashCommand {
    public let name: String
    public let description: String
    public let action: String
    public let inputHint: String?

    public static func from(json: [String: Any]) -> AIProtocolSlashCommand? {
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

    public init(name: String, description: String, action: String, inputHint: String?) {
        self.name = name
        self.description = description
        self.action = action
        self.inputHint = inputHint
    }
}

// MARK: - Evolution

public struct EvolutionBlockerOptionV2 {
    public let optionID: String
    public let label: String
    public let description: String

    public static func from(json: [String: Any]) -> EvolutionBlockerOptionV2? {
        guard let optionID = parseOptionalString(json["option_id"]) else { return nil }
        return EvolutionBlockerOptionV2(
            optionID: optionID,
            label: parseOptionalString(json["label"]) ?? optionID,
            description: parseOptionalString(json["description"]) ?? ""
        )
    }

    public init(optionID: String, label: String, description: String) {
        self.optionID = optionID
        self.label = label
        self.description = description
    }
}

public struct EvolutionBlockerItemV2 {
    public let blockerID: String
    public let status: String
    public let cycleID: String
    public let stage: String
    public let createdAt: String
    public let source: String
    public let title: String
    public let description: String
    public let questionType: String
    public let options: [EvolutionBlockerOptionV2]
    public let allowCustomInput: Bool

    public static func from(json: [String: Any]) -> EvolutionBlockerItemV2? {
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

    public init(blockerID: String, status: String, cycleID: String, stage: String, createdAt: String, source: String, title: String, description: String, questionType: String, options: [EvolutionBlockerOptionV2], allowCustomInput: Bool) {
        self.blockerID = blockerID
        self.status = status
        self.cycleID = cycleID
        self.stage = stage
        self.createdAt = createdAt
        self.source = source
        self.title = title
        self.description = description
        self.questionType = questionType
        self.options = options
        self.allowCustomInput = allowCustomInput
    }
}

public struct EvolutionBlockingRequiredV2 {
    public let project: String
    public let workspace: String
    public let trigger: String
    public let cycleID: String?
    public let stage: String?
    public let blockerFilePath: String
    public let unresolvedItems: [EvolutionBlockerItemV2]

    public static func from(json: [String: Any]) -> EvolutionBlockingRequiredV2? {
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

    public init(project: String, workspace: String, trigger: String, cycleID: String?, stage: String?, blockerFilePath: String, unresolvedItems: [EvolutionBlockerItemV2]) {
        self.project = project
        self.workspace = workspace
        self.trigger = trigger
        self.cycleID = cycleID
        self.stage = stage
        self.blockerFilePath = blockerFilePath
        self.unresolvedItems = unresolvedItems
    }
}

public struct EvolutionBlockersUpdatedV2 {
    public let project: String
    public let workspace: String
    public let unresolvedCount: Int
    public let unresolvedItems: [EvolutionBlockerItemV2]

    public static func from(json: [String: Any]) -> EvolutionBlockersUpdatedV2? {
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

    public init(project: String, workspace: String, unresolvedCount: Int, unresolvedItems: [EvolutionBlockerItemV2]) {
        self.project = project
        self.workspace = workspace
        self.unresolvedCount = unresolvedCount
        self.unresolvedItems = unresolvedItems
    }
}

public struct EvolutionBlockerResolutionInputV2 {
    public let blockerID: String
    public let selectedOptionIDs: [String]
    public let answerText: String?

    public func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "blocker_id": blockerID,
            "selected_option_ids": selectedOptionIDs
        ]
        if let answerText {
            json["answer_text"] = answerText
        }
        return json
    }

    public init(blockerID: String, selectedOptionIDs: [String], answerText: String?) {
        self.blockerID = blockerID
        self.selectedOptionIDs = selectedOptionIDs
        self.answerText = answerText
    }
}

public struct EvolutionModelSelectionV2 {
    public let providerID: String
    public let modelID: String

    public static func from(json: [String: Any]) -> EvolutionModelSelectionV2? {
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

    public static func from(rawModel: String, providerHint: String?) -> EvolutionModelSelectionV2? {
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

    public init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }
}

public struct EvolutionStageProfileInfoV2 {
    public let stage: String
    public let aiTool: AIChatTool
    public let mode: String?
    public let model: EvolutionModelSelectionV2?
    public let configOptions: [String: Any]

    public init(
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

    public static func from(json: [String: Any]) -> EvolutionStageProfileInfoV2? {
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

    public func toJSON() -> [String: Any] {
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

public struct EvolutionAgentInfoV2: Equatable {
    public let stage: String
    public let agent: String
    public let status: String
    public let toolCallCount: Int
    /// 代理开始运行的 RFC3339 时间戳
    public let startedAt: String?
    /// 代理运行耗时（毫秒），仅在完成后填充
    public let durationMs: UInt64?

    public static func from(json: [String: Any]) -> EvolutionAgentInfoV2? {
        guard let stage = json["stage"] as? String,
              let agent = json["agent"] as? String,
              let status = json["status"] as? String else { return nil }
        let toolCallCount = Int(parseInt64(json["tool_call_count"]))
        let startedAt = parseOptionalString(json["started_at"])
        let durationMs: UInt64? = (json["duration_ms"] as? NSNumber).map { $0.uint64Value }
        return EvolutionAgentInfoV2(
            stage: stage,
            agent: agent,
            status: status,
            toolCallCount: toolCallCount,
            startedAt: startedAt,
            durationMs: durationMs
        )
    }

    public init(stage: String, agent: String, status: String, toolCallCount: Int, startedAt: String?, durationMs: UInt64?) {
        self.stage = stage
        self.agent = agent
        self.status = status
        self.toolCallCount = toolCallCount
        self.startedAt = startedAt
        self.durationMs = durationMs
    }
}

public struct EvolutionSessionExecutionEntryV2: Equatable {
    public let stage: String
    public let agent: String
    public let aiTool: String
    public let sessionID: String
    public let status: String
    public let startedAt: String
    public let completedAt: String?
    public let durationMs: UInt64?
    public let toolCallCount: Int

    public static func from(json: [String: Any]) -> EvolutionSessionExecutionEntryV2? {
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

    public init(stage: String, agent: String, aiTool: String, sessionID: String, status: String, startedAt: String, completedAt: String?, durationMs: UInt64?, toolCallCount: Int) {
        self.stage = stage
        self.agent = agent
        self.aiTool = aiTool
        self.sessionID = sessionID
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMs = durationMs
        self.toolCallCount = toolCallCount
    }
}

public extension EvolutionSessionExecutionEntryV2 {
    var hasResolvedSessionReference: Bool {
        !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !aiTool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private enum EvolutionExecutionLookupSemantics {
    static func exactStageKey(for stage: String) -> String {
        normalize(stage)
    }

    static func profileStageKey(for stage: String) -> String {
        let normalized = normalize(stage)
        if normalized.hasPrefix("implement.general.") { return "implement_general" }
        if normalized.hasPrefix("implement.visual.") { return "implement_visual" }
        if normalized.hasPrefix("verify.") { return "verify" }
        if normalized.hasPrefix("reimplement.") {
            let parts = normalized.split(separator: ".")
            if parts.count == 2, let index = Int(parts[1]) {
                return index <= 2 ? "implement_general" : "implement_advanced"
            }
            return "implement_general"
        }
        if normalized == "implement.general" { return "implement_general" }
        if normalized == "implement.visual" { return "implement_visual" }
        if normalized == "implement" { return "implement_general" }
        if normalized == "reimplement" { return "implement_general" }
        return normalized
    }

    private static func normalize(_ stage: String) -> String {
        stage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: ".")
    }
}

public struct EvolutionSchedulerInfoV2: Equatable {
    public let activationState: String
    public let maxParallelWorkspaces: Int
    public let runningCount: Int
    public let queuedCount: Int

    public static let empty = EvolutionSchedulerInfoV2(
        activationState: "idle",
        maxParallelWorkspaces: 0,
        runningCount: 0,
        queuedCount: 0
    )

    public static func from(json: [String: Any]) -> EvolutionSchedulerInfoV2? {
        guard let activationState = json["activation_state"] as? String else { return nil }
        return EvolutionSchedulerInfoV2(
            activationState: activationState,
            maxParallelWorkspaces: Int(parseInt64(json["max_parallel_workspaces"])),
            runningCount: Int(parseInt64(json["running_count"])),
            queuedCount: Int(parseInt64(json["queued_count"]))
        )
    }

    public init(activationState: String, maxParallelWorkspaces: Int, runningCount: Int, queuedCount: Int) {
        self.activationState = activationState
        self.maxParallelWorkspaces = maxParallelWorkspaces
        self.runningCount = runningCount
        self.queuedCount = queuedCount
    }
}

public struct EvolutionWorkspaceItemV2: Equatable {
    public let project: String
    public let workspace: String
    public let cycleID: String
    public let title: String?
    public let status: String
    public let currentStage: String
    public let globalLoopRound: Int
    public let loopRoundLimit: Int
    public let verifyIteration: Int
    public let verifyIterationLimit: Int
    public let agents: [EvolutionAgentInfoV2]
    public let executions: [EvolutionSessionExecutionEntryV2]
    public let terminalReasonCode: String?
    public let terminalErrorMessage: String?
    public let rateLimitErrorMessage: String?

    public var workspaceKey: String {
        "\(project):\(workspace)"
    }

    public var activeAgents: [String] {
        agents
            .filter { $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "running" }
            .map(\.agent)
    }

    public var statusStageRoundSignature: Int {
        var hasher = Hasher()
        hasher.combine(project)
        hasher.combine(workspace)
        hasher.combine(cycleID)
        hasher.combine(status)
        hasher.combine(currentStage)
        hasher.combine(globalLoopRound)
        hasher.combine(loopRoundLimit)
        hasher.combine(verifyIteration)
        hasher.combine(verifyIterationLimit)
        hasher.combine(terminalReasonCode ?? "")
        hasher.combine(terminalErrorMessage ?? "")
        hasher.combine(rateLimitErrorMessage ?? "")
        return hasher.finalize()
    }

    public var timelineSignature: Int {
        var hasher = Hasher()
        hasher.combine(project)
        hasher.combine(workspace)
        hasher.combine(cycleID)
        hasher.combine(globalLoopRound)
        hasher.combine(executions.count)
        for execution in executions {
            hasher.combine(execution.stage)
            hasher.combine(execution.sessionID)
            hasher.combine(execution.status)
            hasher.combine(execution.startedAt)
            hasher.combine(execution.completedAt ?? "")
            hasher.combine(execution.durationMs ?? 0)
            hasher.combine(execution.toolCallCount)
        }
        for agent in agents {
            hasher.combine(agent.stage)
            hasher.combine(agent.agent)
            hasher.combine(agent.status)
            hasher.combine(agent.startedAt ?? "")
            hasher.combine(agent.durationMs ?? 0)
            hasher.combine(agent.toolCallCount)
        }
        return hasher.finalize()
    }

    public var projectionSignature: Int {
        var hasher = Hasher()
        hasher.combine(statusStageRoundSignature)
        hasher.combine(timelineSignature)
        hasher.combine(agents.count)
        hasher.combine(executions.count)
        return hasher.finalize()
    }

    public func latestResolvedExecution(forExactStage stage: String) -> EvolutionSessionExecutionEntryV2? {
        let targetStageKey = EvolutionExecutionLookupSemantics.exactStageKey(for: stage)
        return executions.reversed().first { execution in
            execution.hasResolvedSessionReference &&
                EvolutionExecutionLookupSemantics.exactStageKey(for: execution.stage) == targetStageKey
        }
    }

    public func latestResolvedExecution(forStage stage: String) -> EvolutionSessionExecutionEntryV2? {
        let targetStageKey = EvolutionExecutionLookupSemantics.profileStageKey(for: stage)
        return executions.reversed().first { execution in
            execution.hasResolvedSessionReference &&
                EvolutionExecutionLookupSemantics.profileStageKey(for: execution.stage) == targetStageKey
        }
    }

    public static func from(json: [String: Any]) -> EvolutionWorkspaceItemV2? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let cycleID = json["cycle_id"] as? String,
              let status = json["status"] as? String,
              let currentStage = json["current_stage"] as? String else { return nil }

        let agents = (json["agents"] as? [[String: Any]] ?? []).compactMap { EvolutionAgentInfoV2.from(json: $0) }
        let executions = (json["executions"] as? [[String: Any]] ?? [])
            .compactMap { EvolutionSessionExecutionEntryV2.from(json: $0) }
        return EvolutionWorkspaceItemV2(
            project: project,
            workspace: workspace,
            cycleID: cycleID,
            title: parseOptionalString(json["title"]),
            status: status,
            currentStage: currentStage,
            globalLoopRound: Int(parseInt64(json["global_loop_round"])),
            loopRoundLimit: Int(parseInt64(json["loop_round_limit"])),
            verifyIteration: Int(parseInt64(json["verify_iteration"])),
            verifyIterationLimit: Int(parseInt64(json["verify_iteration_limit"])),
            agents: agents,
            executions: executions,
            terminalReasonCode: json["terminal_reason_code"] as? String,
            terminalErrorMessage: json["terminal_error_message"] as? String,
            rateLimitErrorMessage: json["rate_limit_error_message"] as? String
        )
    }

    public init(project: String, workspace: String, cycleID: String, title: String?, status: String, currentStage: String, globalLoopRound: Int, loopRoundLimit: Int, verifyIteration: Int, verifyIterationLimit: Int, agents: [EvolutionAgentInfoV2], executions: [EvolutionSessionExecutionEntryV2], terminalReasonCode: String?, terminalErrorMessage: String?, rateLimitErrorMessage: String?) {
        self.project = project
        self.workspace = workspace
        self.cycleID = cycleID
        self.title = title
        self.status = status
        self.currentStage = currentStage
        self.globalLoopRound = globalLoopRound
        self.loopRoundLimit = loopRoundLimit
        self.verifyIteration = verifyIteration
        self.verifyIterationLimit = verifyIterationLimit
        self.agents = agents
        self.executions = executions
        self.terminalReasonCode = terminalReasonCode
        self.terminalErrorMessage = terminalErrorMessage
        self.rateLimitErrorMessage = rateLimitErrorMessage
    }
}

public struct EvolutionSnapshotV2: Equatable {
    public let scheduler: EvolutionSchedulerInfoV2
    public let workspaceItems: [EvolutionWorkspaceItemV2]

    public static func from(json: [String: Any]) -> EvolutionSnapshotV2? {
        guard let schedulerDict = json["scheduler"] as? [String: Any],
              let scheduler = EvolutionSchedulerInfoV2.from(json: schedulerDict) else { return nil }
        let items = (json["workspace_items"] as? [[String: Any]] ?? [])
            .compactMap { EvolutionWorkspaceItemV2.from(json: $0) }
        return EvolutionSnapshotV2(scheduler: scheduler, workspaceItems: items)
    }

    public init(scheduler: EvolutionSchedulerInfoV2, workspaceItems: [EvolutionWorkspaceItemV2]) {
        self.scheduler = scheduler
        self.workspaceItems = workspaceItems
    }
}

/// evo_cycle_updated 事件的直接解析模型，用于在不触发全量快照刷新的情况下更新单个工作空间状态
public struct EvoCycleUpdatedV2 {
    public let project: String
    public let workspace: String
    public let cycleID: String
    public let title: String?
    public let status: String
    public let currentStage: String
    public let globalLoopRound: Int
    public let loopRoundLimit: Int
    public let verifyIteration: Int
    public let verifyIterationLimit: Int
    public let agents: [EvolutionAgentInfoV2]
    public let executions: [EvolutionSessionExecutionEntryV2]
    public let terminalReasonCode: String?
    public let terminalErrorMessage: String?
    public let rateLimitErrorMessage: String?

    public static func from(json: [String: Any]) -> EvoCycleUpdatedV2? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let cycleID = json["cycle_id"] as? String,
              let status = json["status"] as? String,
              let currentStage = json["current_stage"] as? String else { return nil }
        let agents = (json["agents"] as? [[String: Any]] ?? []).compactMap { EvolutionAgentInfoV2.from(json: $0) }
        let executions = (json["executions"] as? [[String: Any]] ?? [])
            .compactMap { EvolutionSessionExecutionEntryV2.from(json: $0) }
        return EvoCycleUpdatedV2(
            project: project,
            workspace: workspace,
            cycleID: cycleID,
            title: parseOptionalString(json["title"]),
            status: status,
            currentStage: currentStage,
            globalLoopRound: Int(parseInt64(json["global_loop_round"])),
            loopRoundLimit: Int(parseInt64(json["loop_round_limit"])),
            verifyIteration: Int(parseInt64(json["verify_iteration"])),
            verifyIterationLimit: Int(parseInt64(json["verify_iteration_limit"])),
            agents: agents,
            executions: executions,
            terminalReasonCode: json["terminal_reason_code"] as? String,
            terminalErrorMessage: json["terminal_error_message"] as? String,
            rateLimitErrorMessage: json["rate_limit_error_message"] as? String
        )
    }

    public init(project: String, workspace: String, cycleID: String, title: String?, status: String, currentStage: String, globalLoopRound: Int, loopRoundLimit: Int, verifyIteration: Int, verifyIterationLimit: Int, agents: [EvolutionAgentInfoV2], executions: [EvolutionSessionExecutionEntryV2], terminalReasonCode: String?, terminalErrorMessage: String?, rateLimitErrorMessage: String?) {
        self.project = project
        self.workspace = workspace
        self.cycleID = cycleID
        self.title = title
        self.status = status
        self.currentStage = currentStage
        self.globalLoopRound = globalLoopRound
        self.loopRoundLimit = loopRoundLimit
        self.verifyIteration = verifyIteration
        self.verifyIterationLimit = verifyIterationLimit
        self.agents = agents
        self.executions = executions
        self.terminalReasonCode = terminalReasonCode
        self.terminalErrorMessage = terminalErrorMessage
        self.rateLimitErrorMessage = rateLimitErrorMessage
    }
}

public enum EvolutionWorkspaceStatusEventKindV2: String {
    case started = "started"
    case stopped = "stopped"
    case resumed = "resumed"
    case stageChanged = "stage_changed"
}

public struct EvolutionWorkspaceStatusEventV2 {
    public let kind: EvolutionWorkspaceStatusEventKindV2
    public let project: String
    public let workspace: String
    public let cycleID: String
    public let status: String?
    public let currentStage: String?
    public let verifyIteration: Int?
    public let reason: String?
    public let source: String?

    public static func from(action: String, json: [String: Any]) -> EvolutionWorkspaceStatusEventV2? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String,
              let cycleID = json["cycle_id"] as? String else {
            return nil
        }

        let kind: EvolutionWorkspaceStatusEventKindV2
        switch action {
        case "evo_workspace_started":
            kind = .started
        case "evo_workspace_stopped":
            kind = .stopped
        case "evo_workspace_resumed":
            kind = .resumed
        case "evo_stage_changed":
            kind = .stageChanged
        default:
            return nil
        }

        let currentStage: String? = {
            if kind == .stageChanged {
                return parseOptionalString(json["to_stage"])
            }
            return parseOptionalString(json["current_stage"])
        }()

        return EvolutionWorkspaceStatusEventV2(
            kind: kind,
            project: project,
            workspace: workspace,
            cycleID: cycleID,
            status: parseOptionalString(json["status"]),
            currentStage: currentStage,
            verifyIteration: json["verify_iteration"].map { Int(parseInt64($0)) },
            reason: parseOptionalString(json["reason"]),
            source: parseOptionalString(json["source"])
        )
    }

    public init(
        kind: EvolutionWorkspaceStatusEventKindV2,
        project: String,
        workspace: String,
        cycleID: String,
        status: String?,
        currentStage: String?,
        verifyIteration: Int?,
        reason: String?,
        source: String?
    ) {
        self.kind = kind
        self.project = project
        self.workspace = workspace
        self.cycleID = cycleID
        self.status = status
        self.currentStage = currentStage
        self.verifyIteration = verifyIteration
        self.reason = reason
        self.source = source
    }
}

public struct EvolutionAgentProfileV2 {
    public let project: String
    public let workspace: String
    public let stageProfiles: [EvolutionStageProfileInfoV2]

    public static func from(json: [String: Any]) -> EvolutionAgentProfileV2? {
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

    public init(project: String, workspace: String, stageProfiles: [EvolutionStageProfileInfoV2]) {
        self.project = project
        self.workspace = workspace
        self.stageProfiles = stageProfiles
    }
}

// MARK: - 进化循环历史数据模型

public struct EvolutionCycleStageHistoryEntryV2 {
    public let stage: String
    public let agent: String
    public let aiTool: String
    public let status: String
    public let durationMs: UInt64?

    public static func from(json: [String: Any]) -> EvolutionCycleStageHistoryEntryV2? {
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

    public init(stage: String, agent: String, aiTool: String, status: String, durationMs: UInt64?) {
        self.stage = stage
        self.agent = agent
        self.aiTool = aiTool
        self.status = status
        self.durationMs = durationMs
    }
}

public struct EvolutionCycleHistoryItemV2 {
    public let cycleID: String
    public let title: String?
    public let status: String
    public let globalLoopRound: Int
    public let createdAt: String
    public let updatedAt: String
    public let terminalReasonCode: String?
    public let terminalErrorMessage: String?
    public let executions: [EvolutionSessionExecutionEntryV2]
    public let stages: [EvolutionCycleStageHistoryEntryV2]

    public static func from(json: [String: Any]) -> EvolutionCycleHistoryItemV2? {
        guard let cycleID = parseOptionalString(json["cycle_id"]) else { return nil }
        let title = parseOptionalString(json["title"])
        let status = parseOptionalString(json["status"]) ?? "unknown"
        let globalLoopRound = Int(parseInt64(json["global_loop_round"]))
        let createdAt = parseOptionalString(json["created_at"]) ?? ""
        let updatedAt = parseOptionalString(json["updated_at"]) ?? ""
        let terminalReasonCode = parseOptionalString(json["terminal_reason_code"])
        let terminalErrorMessage = parseOptionalString(json["terminal_error_message"])
        let executions = (json["executions"] as? [[String: Any]] ?? [])
            .compactMap { EvolutionSessionExecutionEntryV2.from(json: $0) }
        let stages = (json["stages"] as? [[String: Any]] ?? [])
            .compactMap { EvolutionCycleStageHistoryEntryV2.from(json: $0) }
        return EvolutionCycleHistoryItemV2(
            cycleID: cycleID,
            title: title,
            status: status,
            globalLoopRound: globalLoopRound,
            createdAt: createdAt,
            updatedAt: updatedAt,
            terminalReasonCode: terminalReasonCode,
            terminalErrorMessage: terminalErrorMessage,
            executions: executions,
            stages: stages
        )
    }

    public init(cycleID: String, title: String?, status: String, globalLoopRound: Int, createdAt: String, updatedAt: String, terminalReasonCode: String?, terminalErrorMessage: String?, executions: [EvolutionSessionExecutionEntryV2], stages: [EvolutionCycleStageHistoryEntryV2]) {
        self.cycleID = cycleID
        self.title = title
        self.status = status
        self.globalLoopRound = globalLoopRound
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.terminalReasonCode = terminalReasonCode
        self.terminalErrorMessage = terminalErrorMessage
        self.executions = executions
        self.stages = stages
    }
}

public struct EvidenceSubsystemInfoV2 {
    public let id: String
    public let kind: String
    public let path: String

    public static func from(json: [String: Any]) -> EvidenceSubsystemInfoV2? {
        guard let id = parseOptionalString(json["id"]),
              let kind = parseOptionalString(json["kind"]),
              let path = parseOptionalString(json["path"]) else {
            return nil
        }
        return EvidenceSubsystemInfoV2(id: id, kind: kind, path: path)
    }

    public init(id: String, kind: String, path: String) {
        self.id = id
        self.kind = kind
        self.path = path
    }
}

public struct EvidenceIssueInfoV2 {
    public let code: String
    public let level: String
    public let message: String

    public static func from(json: [String: Any]) -> EvidenceIssueInfoV2? {
        guard let code = parseOptionalString(json["code"]),
              let level = parseOptionalString(json["level"]),
              let message = parseOptionalString(json["message"]) else {
            return nil
        }
        return EvidenceIssueInfoV2(code: code, level: level, message: message)
    }

    public init(code: String, level: String, message: String) {
        self.code = code
        self.level = level
        self.message = message
    }
}

public struct EvidenceItemInfoV2 {
    public let itemID: String
    public let deviceType: String
    public let evidenceType: String
    public let order: Int
    public let path: String
    public let title: String
    public let description: String
    public let scenario: String?
    public let subsystem: String?
    public let createdAt: String?
    public let sizeBytes: UInt64
    public let exists: Bool
    public let mimeType: String

    public static func from(json: [String: Any]) -> EvidenceItemInfoV2? {
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

    public init(itemID: String, deviceType: String, evidenceType: String, order: Int, path: String, title: String, description: String, scenario: String?, subsystem: String?, createdAt: String?, sizeBytes: UInt64, exists: Bool, mimeType: String) {
        self.itemID = itemID
        self.deviceType = deviceType
        self.evidenceType = evidenceType
        self.order = order
        self.path = path
        self.title = title
        self.description = description
        self.scenario = scenario
        self.subsystem = subsystem
        self.createdAt = createdAt
        self.sizeBytes = sizeBytes
        self.exists = exists
        self.mimeType = mimeType
    }
}

public struct EvidenceSnapshotV2 {
    public let project: String
    public let workspace: String
    public let evidenceRoot: String
    public let indexFile: String
    public let indexExists: Bool
    public let detectedSubsystems: [EvidenceSubsystemInfoV2]
    public let detectedDeviceTypes: [String]
    public let items: [EvidenceItemInfoV2]
    public let issues: [EvidenceIssueInfoV2]
    public let updatedAt: String

    public static func from(json: [String: Any]) -> EvidenceSnapshotV2? {
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

    public init(project: String, workspace: String, evidenceRoot: String, indexFile: String, indexExists: Bool, detectedSubsystems: [EvidenceSubsystemInfoV2], detectedDeviceTypes: [String], items: [EvidenceItemInfoV2], issues: [EvidenceIssueInfoV2], updatedAt: String) {
        self.project = project
        self.workspace = workspace
        self.evidenceRoot = evidenceRoot
        self.indexFile = indexFile
        self.indexExists = indexExists
        self.detectedSubsystems = detectedSubsystems
        self.detectedDeviceTypes = detectedDeviceTypes
        self.items = items
        self.issues = issues
        self.updatedAt = updatedAt
    }
}

public struct EvidenceRebuildPromptV2 {
    public let project: String
    public let workspace: String
    public let prompt: String
    public let evidenceRoot: String
    public let indexFile: String
    public let detectedSubsystems: [EvidenceSubsystemInfoV2]
    public let detectedDeviceTypes: [String]
    public let generatedAt: String

    public static func from(json: [String: Any]) -> EvidenceRebuildPromptV2? {
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

    public init(project: String, workspace: String, prompt: String, evidenceRoot: String, indexFile: String, detectedSubsystems: [EvidenceSubsystemInfoV2], detectedDeviceTypes: [String], generatedAt: String) {
        self.project = project
        self.workspace = workspace
        self.prompt = prompt
        self.evidenceRoot = evidenceRoot
        self.indexFile = indexFile
        self.detectedSubsystems = detectedSubsystems
        self.detectedDeviceTypes = detectedDeviceTypes
        self.generatedAt = generatedAt
    }
}

public struct EvidenceItemChunkV2 {
    public let project: String
    public let workspace: String
    public let itemID: String
    public let offset: UInt64
    public let nextOffset: UInt64
    public let eof: Bool
    public let totalSizeBytes: UInt64
    public let mimeType: String
    public let content: [UInt8]

    public static func from(json: [String: Any]) -> EvidenceItemChunkV2? {
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

    public init(project: String, workspace: String, itemID: String, offset: UInt64, nextOffset: UInt64, eof: Bool, totalSizeBytes: UInt64, mimeType: String, content: [UInt8]) {
        self.project = project
        self.workspace = workspace
        self.itemID = itemID
        self.offset = offset
        self.nextOffset = nextOffset
        self.eof = eof
        self.totalSizeBytes = totalSizeBytes
        self.mimeType = mimeType
        self.content = content
    }
}

// toChatMessages() 扩展依赖平台视图模型层（AIChatMessage 等），
// 已移至 app/TidyFlow/Views/Models/ 中的平台侧扩展。

// MARK: - AI 会话重命名响应
public struct AISessionRenameResult {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: String
    public let sessionId: String
    public let title: String
    public let updatedAt: Int64

    public static func from(json: [String: Any]) -> AISessionRenameResult? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = json["ai_tool"] as? String,
              let sessionId = json["session_id"] as? String,
              let title = json["title"] as? String else { return nil }
        let updatedAt = (json["updated_at"] as? Int64) ?? (json["updated_at"] as? Int).map { Int64($0) } ?? 0
        return AISessionRenameResult(projectName: projectName, workspaceName: workspaceName,
                                     aiTool: aiTool, sessionId: sessionId,
                                     title: title, updatedAt: updatedAt)
    }

    public init(projectName: String, workspaceName: String, aiTool: String, sessionId: String, title: String, updatedAt: Int64) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.sessionId = sessionId
        self.title = title
        self.updatedAt = updatedAt
    }
}

// MARK: - AI 会话搜索响应
public struct AISessionSearchResult {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: String
    public let query: String
    public let sessions: [AIProtocolSessionInfo]

    public static func from(json: [String: Any]) -> AISessionSearchResult? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = json["ai_tool"] as? String,
              let query = json["query"] as? String,
              let aiChatTool = AIChatTool(rawValue: aiTool) else { return nil }
        let rawSessions = json["sessions"] as? [[String: Any]] ?? []
        let sessions = rawSessions.compactMap { item -> AIProtocolSessionInfo? in
            guard let id = item["id"] as? String,
                  let title = item["title"] as? String else { return nil }
            let updatedAt = parseInt64(item["updated_at"])
            let origin = parseAISessionOrigin(item["session_origin"])
            return AIProtocolSessionInfo(projectName: projectName, workspaceName: workspaceName,
                                         aiTool: aiChatTool, id: id, title: title, updatedAt: updatedAt, origin: origin)
        }
        return AISessionSearchResult(projectName: projectName, workspaceName: workspaceName,
                                     aiTool: aiTool, query: query, sessions: sessions)
    }

    public init(projectName: String, workspaceName: String, aiTool: String, query: String, sessions: [AIProtocolSessionInfo]) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.query = query
        self.sessions = sessions
    }
}

// MARK: - AI 代码审查响应
public struct AICodeReviewResult: Equatable {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: String
    public let sessionId: String
    public let reviewText: String?
    public let error: String?

    public static func from(json: [String: Any]) -> AICodeReviewResult? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = json["ai_tool"] as? String,
              let sessionId = json["session_id"] as? String else { return nil }
        return AICodeReviewResult(projectName: projectName, workspaceName: workspaceName,
                                  aiTool: aiTool, sessionId: sessionId,
                                  reviewText: json["review_text"] as? String,
                                  error: json["error"] as? String)
    }

    public init(projectName: String, workspaceName: String, aiTool: String, sessionId: String, reviewText: String?, error: String?) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.sessionId = sessionId
        self.reviewText = reviewText
        self.error = error
    }
}

// MARK: - AI 代码补全协议模型

/// 编程语言枚举（与 Rust Core 对齐）
public enum AICodeCompletionLanguage: String {
    case swift
    case rust
    case javascript
    case typescript
    case python
    case go
    case other

    /// 从文件扩展名推断语言
    public static func from(fileExtension ext: String) -> AICodeCompletionLanguage {
        switch ext.lowercased() {
        case "swift": return .swift
        case "rs": return .rust
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "py", "pyw": return .python
        case "go": return .go
        default: return .other
        }
    }

    /// 从文件路径推断语言
    public static func from(filePath: String) -> AICodeCompletionLanguage {
        let ext = (filePath as NSString).pathExtension
        return from(fileExtension: ext)
    }
}

/// 补全流式分片（服务端推送）
public struct AICodeCompletionChunk {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: String
    public let requestId: String
    public let delta: String
    public let isFinal: Bool

    public static func from(json: [String: Any]) -> AICodeCompletionChunk? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = json["ai_tool"] as? String,
              let chunk = json["chunk"] as? [String: Any],
              let requestId = chunk["request_id"] as? String,
              let delta = chunk["delta"] as? String else { return nil }
        let isFinal = chunk["is_final"] as? Bool ?? false
        return AICodeCompletionChunk(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            requestId: requestId,
            delta: delta,
            isFinal: isFinal
        )
    }

    public init(projectName: String, workspaceName: String, aiTool: String, requestId: String, delta: String, isFinal: Bool) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.requestId = requestId
        self.delta = delta
        self.isFinal = isFinal
    }
}

/// 补全完成事件（流结束）
public struct AICodeCompletionDone {
    public let projectName: String
    public let workspaceName: String
    public let aiTool: String
    public let requestId: String
    public let completionText: String
    public let stopReason: String
    public let error: String?

    public static func from(json: [String: Any]) -> AICodeCompletionDone? {
        guard let projectName = json["project_name"] as? String,
              let workspaceName = json["workspace_name"] as? String,
              let aiTool = json["ai_tool"] as? String,
              let result = json["result"] as? [String: Any],
              let requestId = result["request_id"] as? String,
              let completionText = result["completion_text"] as? String,
              let stopReason = result["stop_reason"] as? String else { return nil }
        return AICodeCompletionDone(
            projectName: projectName,
            workspaceName: workspaceName,
            aiTool: aiTool,
            requestId: requestId,
            completionText: completionText,
            stopReason: stopReason,
            error: result["error"] as? String
        )
    }

    public init(projectName: String, workspaceName: String, aiTool: String, requestId: String, completionText: String, stopReason: String, error: String?) {
        self.projectName = projectName
        self.workspaceName = workspaceName
        self.aiTool = aiTool
        self.requestId = requestId
        self.completionText = completionText
        self.stopReason = stopReason
        self.error = error
    }
}

// MARK: - 平铺 AI 会话消息（Flattened AI Session Cache）

/// 平铺消息语义类型，对应 Rust 侧 FlattenedAiMessageKind
public enum AIFlattenedMessageKind: String {
    case user
    case assistant
    case toolCall = "tool_call"
    case toolResult = "tool_result"
    case system
    case unknown

    public static func from(raw: String?) -> AIFlattenedMessageKind {
        guard let raw else { return .unknown }
        return AIFlattenedMessageKind(rawValue: raw) ?? .unknown
    }
}

/// 平铺 AI 消息结构，单层不嵌套，对应 Rust 侧 FlattenedAiMessage
public struct AIFlattenedMessage {
    /// 消息/part 唯一 ID
    public let id: String
    /// 所属会话 ID（稳定索引键）
    public let sessionId: String
    /// 消息语义类型
    public let kind: AIFlattenedMessageKind
    /// 文本内容（user/assistant/system 时有效）
    public let content: String?
    /// 工具名称（tool_call/tool_result 时有效）
    public let toolName: String?
    /// 工具调用 ID（tool_call/tool_result 关联键）
    public let toolCallId: String?
    /// 创建时间戳（毫秒）
    public let createdAt: Int64

    public static func from(json: [String: Any]) -> AIFlattenedMessage? {
        guard let id = json["id"] as? String,
              let sessionId = json["session_id"] as? String else { return nil }
        return AIFlattenedMessage(
            id: id,
            sessionId: sessionId,
            kind: AIFlattenedMessageKind.from(raw: json["kind"] as? String),
            content: json["content"] as? String,
            toolName: json["tool_name"] as? String,
            toolCallId: json["tool_call_id"] as? String,
            createdAt: parseInt64(json["created_at"])
        )
    }

    public init(id: String, sessionId: String, kind: AIFlattenedMessageKind, content: String?, toolName: String?, toolCallId: String?, createdAt: Int64) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.content = content
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.createdAt = createdAt
    }
}

/// AI 会话平铺消息缓存，按 session_id 索引，revision 单调递增，对应 Rust 侧 AiSessionFlatCache
public struct AISessionFlatCache {
    /// 会话 ID（稳定索引键）
    public let sessionId: String
    /// 缓存修订号，每次追加消息时单调递增
    public let revision: UInt64
    /// 平铺后的消息列表
    public let messages: [AIFlattenedMessage]

    public static func from(json: [String: Any]) -> AISessionFlatCache? {
        guard let sessionId = json["session_id"] as? String else { return nil }
        let revision = (json["revision"] as? UInt64) ?? UInt64(json["revision"] as? Int ?? 0)
        let messages = (json["messages"] as? [[String: Any]] ?? [])
            .compactMap { AIFlattenedMessage.from(json: $0) }
        return AISessionFlatCache(
            sessionId: sessionId,
            revision: revision,
            messages: messages
        )
    }

    public init(sessionId: String, revision: UInt64, messages: [AIFlattenedMessage]) {
        self.sessionId = sessionId
        self.revision = revision
        self.messages = messages
    }
}

// MARK: - 多项目上下文协议模型

public struct AIProjectMentionMeta {
    public let projectName: String
    public let resolved: Bool

    public static func from(json: [String: Any]) -> AIProjectMentionMeta? {
        guard let projectName = json["project_name"] as? String else { return nil }
        let resolved = (json["resolved"] as? Bool) ?? false
        return AIProjectMentionMeta(projectName: projectName, resolved: resolved)
    }

    public init(projectName: String, resolved: Bool) {
        self.projectName = projectName
        self.resolved = resolved
    }
}

public struct AIProjectContextSummary {
    public let projectName: String
    public let contextText: String

    public static func from(json: [String: Any]) -> AIProjectContextSummary? {
        guard let projectName = json["project_name"] as? String,
              let contextText = json["context_text"] as? String else { return nil }
        return AIProjectContextSummary(projectName: projectName, contextText: contextText)
    }

    public init(projectName: String, contextText: String) {
        self.projectName = projectName
        self.contextText = contextText
    }
}

// MARK: - 工作区缓存可观测性协议模型（v1.40+）

/// 文件索引缓存指标快照，由 Core system_snapshot 权威输出
public struct FileCacheMetricsModel {
    public let hitCount: UInt64
    public let missCount: UInt64
    public let rebuildCount: UInt64
    public let incrementalUpdateCount: UInt64
    public let evictionCount: UInt64
    public let itemCount: UInt64
    public let lastEvictionReason: String?

    public static func from(json: [String: Any]) -> FileCacheMetricsModel {
        FileCacheMetricsModel(
            hitCount: (json["hit_count"] as? UInt64) ?? UInt64(json["hit_count"] as? Int ?? 0),
            missCount: (json["miss_count"] as? UInt64) ?? UInt64(json["miss_count"] as? Int ?? 0),
            rebuildCount: (json["rebuild_count"] as? UInt64) ?? UInt64(json["rebuild_count"] as? Int ?? 0),
            incrementalUpdateCount: (json["incremental_update_count"] as? UInt64) ?? UInt64(json["incremental_update_count"] as? Int ?? 0),
            evictionCount: (json["eviction_count"] as? UInt64) ?? UInt64(json["eviction_count"] as? Int ?? 0),
            itemCount: (json["item_count"] as? UInt64) ?? UInt64(json["item_count"] as? Int ?? 0),
            lastEvictionReason: json["last_eviction_reason"] as? String
        )
    }

    public static func empty() -> FileCacheMetricsModel {
        FileCacheMetricsModel(
            hitCount: 0, missCount: 0, rebuildCount: 0,
            incrementalUpdateCount: 0, evictionCount: 0, itemCount: 0,
            lastEvictionReason: nil
        )
    }

    public init(
        hitCount: UInt64, missCount: UInt64, rebuildCount: UInt64,
        incrementalUpdateCount: UInt64, evictionCount: UInt64, itemCount: UInt64,
        lastEvictionReason: String?
    ) {
        self.hitCount = hitCount
        self.missCount = missCount
        self.rebuildCount = rebuildCount
        self.incrementalUpdateCount = incrementalUpdateCount
        self.evictionCount = evictionCount
        self.itemCount = itemCount
        self.lastEvictionReason = lastEvictionReason
    }
}

/// Git 状态缓存指标快照，由 Core system_snapshot 权威输出
public struct GitCacheMetricsModel {
    public let hitCount: UInt64
    public let missCount: UInt64
    public let rebuildCount: UInt64
    public let evictionCount: UInt64
    public let itemCount: UInt64
    public let lastEvictionReason: String?

    public static func from(json: [String: Any]) -> GitCacheMetricsModel {
        GitCacheMetricsModel(
            hitCount: (json["hit_count"] as? UInt64) ?? UInt64(json["hit_count"] as? Int ?? 0),
            missCount: (json["miss_count"] as? UInt64) ?? UInt64(json["miss_count"] as? Int ?? 0),
            rebuildCount: (json["rebuild_count"] as? UInt64) ?? UInt64(json["rebuild_count"] as? Int ?? 0),
            evictionCount: (json["eviction_count"] as? UInt64) ?? UInt64(json["eviction_count"] as? Int ?? 0),
            itemCount: (json["item_count"] as? UInt64) ?? UInt64(json["item_count"] as? Int ?? 0),
            lastEvictionReason: json["last_eviction_reason"] as? String
        )
    }

    public static func empty() -> GitCacheMetricsModel {
        GitCacheMetricsModel(
            hitCount: 0, missCount: 0, rebuildCount: 0,
            evictionCount: 0, itemCount: 0,
            lastEvictionReason: nil
        )
    }

    public init(
        hitCount: UInt64, missCount: UInt64, rebuildCount: UInt64,
        evictionCount: UInt64, itemCount: UInt64,
        lastEvictionReason: String?
    ) {
        self.hitCount = hitCount
        self.missCount = missCount
        self.rebuildCount = rebuildCount
        self.evictionCount = evictionCount
        self.itemCount = itemCount
        self.lastEvictionReason = lastEvictionReason
    }
}

/// 工作区级缓存可观测性快照，以 `(project, workspace)` 为唯一键
///
/// 所有字段由 Core 权威计算，客户端只消费。`budgetExceeded` 和 `lastEvictionReason`
/// 不得由客户端本地重新计算。
public struct WorkspaceCacheMetricsModel {
    /// 全局键："project:workspace"
    public let globalKey: String
    public let project: String
    public let workspace: String
    public let fileCache: FileCacheMetricsModel
    public let gitCache: GitCacheMetricsModel
    /// Core 计算的预算超限标志
    public let budgetExceeded: Bool
    /// 最近淘汰原因（文件或 Git 缓存中最新发生的）
    public let lastEvictionReason: String?

    public static func from(json: [String: Any]) -> WorkspaceCacheMetricsModel? {
        guard let project = json["project"] as? String,
              let workspace = json["workspace"] as? String else {
            return nil
        }
        let fileJson = json["file_cache"] as? [String: Any] ?? [:]
        let gitJson = json["git_cache"] as? [String: Any] ?? [:]
        return WorkspaceCacheMetricsModel(
            project: project,
            workspace: workspace,
            fileCache: FileCacheMetricsModel.from(json: fileJson),
            gitCache: GitCacheMetricsModel.from(json: gitJson),
            budgetExceeded: (json["budget_exceeded"] as? Bool) ?? false,
            lastEvictionReason: json["last_eviction_reason"] as? String
        )
    }

    public init(
        project: String, workspace: String,
        fileCache: FileCacheMetricsModel, gitCache: GitCacheMetricsModel,
        budgetExceeded: Bool, lastEvictionReason: String?
    ) {
        self.project = project
        self.workspace = workspace
        self.globalKey = "\(project):\(workspace)"
        self.fileCache = fileCache
        self.gitCache = gitCache
        self.budgetExceeded = budgetExceeded
        self.lastEvictionReason = lastEvictionReason
    }
}

/// system_snapshot HTTP 响应中的 cache_metrics 数组解析助手
public struct SystemSnapshotCacheMetrics {
    /// 以 "project:workspace" 为键的指标字典
    public let index: [String: WorkspaceCacheMetricsModel]

    public static func from(json: Any?) -> SystemSnapshotCacheMetrics {
        guard let arr = json as? [[String: Any]] else {
            return SystemSnapshotCacheMetrics(index: [:])
        }
        var idx: [String: WorkspaceCacheMetricsModel] = [:]
        for item in arr {
            if let model = WorkspaceCacheMetricsModel.from(json: item) {
                idx[model.globalKey] = model
            }
        }
        return SystemSnapshotCacheMetrics(index: idx)
    }

    /// 按 (project, workspace) 查询缓存指标，不存在则返回空指标
    public func metrics(project: String, workspace: String) -> WorkspaceCacheMetricsModel {
        let key = "\(project):\(workspace)"
        return index[key] ?? WorkspaceCacheMetricsModel(
            project: project, workspace: workspace,
            fileCache: .empty(), gitCache: .empty(),
            budgetExceeded: false, lastEvictionReason: nil
        )
    }

    public init(index: [String: WorkspaceCacheMetricsModel]) {
        self.index = index
    }
}
