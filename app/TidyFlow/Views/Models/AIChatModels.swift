import Foundation
#if os(macOS)
import AppKit
#endif

enum AIChatRole: String {
    case user
    case assistant
}

enum AIChatPartKind: String {
    case text
    case reasoning
    case tool
}

struct AIChatPart: Identifiable {
    let id: String
    let kind: AIChatPartKind
    var text: String?
    var toolName: String?
    var toolState: [String: Any]?
}

/// 一条消息对应一个 OpenCode message（message_id），内部包含多个 part
struct AIChatMessage: Identifiable {
    /// SwiftUI 稳定 id（本地生成）
    let id: String
    /// OpenCode messageID（服务端下发）；本地占位消息可为 nil
    var messageId: String?
    let role: AIChatRole
    var parts: [AIChatPart]
    var isStreaming: Bool
    let timestamp: Date

    init(
        id: String = UUID().uuidString,
        messageId: String? = nil,
        role: AIChatRole,
        parts: [AIChatPart] = [],
        isStreaming: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.messageId = messageId
        self.role = role
        self.parts = parts
        self.isStreaming = isStreaming
        self.timestamp = timestamp
    }
}

struct AISessionInfo: Identifiable {
    let projectName: String
    let workspaceName: String
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

// MARK: - 工作空间快照（切换时保留对话上下文）

struct AIChatSnapshot {
    var currentSessionId: String?
    var messages: [AIChatMessage]
    var isStreaming: Bool
    var sessions: [AISessionInfo]
    var messageIndexByMessageId: [String: Int]
    var partIndexByPartId: [String: (msgIdx: Int, partIdx: Int)]
}

// MARK: - 图片附件

struct ImageAttachment: Identifiable {
    let id: String
    let filename: String
    let data: Data
    #if os(macOS)
    let thumbnail: NSImage
    #endif
    let mime: String

    init(filename: String, data: Data, mime: String) {
        self.id = UUID().uuidString
        self.filename = filename
        self.data = data
        self.mime = mime
        #if os(macOS)
        self.thumbnail = NSImage(data: data) ?? NSImage()
        #endif
    }
}

// MARK: - Provider / 模型

struct AIProviderInfo: Identifiable {
    let id: String
    let name: String
    let models: [AIModelInfo]
}

struct AIModelInfo: Identifiable {
    let id: String
    let name: String
    let providerID: String
}

struct AIModelSelection: Equatable {
    let providerID: String
    let modelID: String
}

// MARK: - Agent

struct AIAgentInfo: Identifiable {
    var id: String { name }
    let name: String
    let description: String?
    let mode: String?
    let color: String?
    /// agent 默认 provider ID
    let defaultProviderID: String?
    /// agent 默认 model ID
    let defaultModelID: String?
}

// MARK: - 斜杠命令（从后端获取）

struct AISlashCommandInfo: Identifiable {
    var id: String { name }
    /// 命令名（不含 / 前缀）
    let name: String
    /// 命令描述
    let description: String
    /// 执行方式："client"（前端本地执行）| "agent"（发送给 AI 代理）
    let action: String
}
