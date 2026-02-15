import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
}

/// 聊天消息类型：用于区分“正式回复”和“思考/工具过程”等展示风格
enum ChatMessageKind: String, Codable {
    case text
    case thinking
}

struct ChatMessage: Identifiable, Codable {
    let id: String
    let role: MessageRole
    let kind: ChatMessageKind
    let content: String
    /// 可选：思考过程（工具调用、推理片段等），用于折叠展示
    let thinking: String?
    /// 可选：工具调用追踪（独立于 thinking，避免被推理流覆盖）
    let toolTrace: String?
    let isStreaming: Bool
    let timestamp: Date

    init(
        id: String = UUID().uuidString,
        role: MessageRole,
        kind: ChatMessageKind = .text,
        content: String,
        thinking: String? = nil,
        toolTrace: String? = nil,
        isStreaming: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.kind = kind
        self.content = content
        self.thinking = thinking
        self.toolTrace = toolTrace
        self.isStreaming = isStreaming
        self.timestamp = timestamp
    }
}

struct SessionInfo: Identifiable, Codable {
    let id: String
    let title: String
    let updatedAt: Int64

    var displayTitle: String {
        return title.isEmpty ? "New Chat" : title
    }

    var formattedDate: String {
        let date = Date(timeIntervalSince1970: Double(updatedAt) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
