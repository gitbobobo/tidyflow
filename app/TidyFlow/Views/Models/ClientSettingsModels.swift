import Foundation

// MARK: - 自定义终端命令

/// 自定义终端命令配置
struct CustomCommand: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var icon: String  // SF Symbol 名称或 "custom:filename" 格式的自定义图标
    var command: String
    
    /// 创建新命令时生成唯一 ID
    init(id: String = UUID().uuidString, name: String = "", icon: String = "terminal", command: String = "") {
        self.id = id
        self.name = name
        self.icon = icon
        self.command = command
    }
}

/// 客户端设置
struct ClientSettings: Codable {
    var customCommands: [CustomCommand]
    /// 工作空间快捷键映射：key 为 "0"-"9"，value 为 "projectName/workspaceName"
    var workspaceShortcuts: [String: String]
    /// 用于提交操作的 AI Agent
    var commitAIAgent: String?
    /// 用于合并操作的 AI Agent
    var mergeAIAgent: String?

    enum CodingKeys: String, CodingKey {
        case customCommands
        case workspaceShortcuts
        case commitAIAgent = "commit_ai_agent"
        case mergeAIAgent = "merge_ai_agent"
        // 旧字段，仅用于解码迁移
        case selectedAIAgent = "selected_ai_agent"
    }

    init(customCommands: [CustomCommand] = [], workspaceShortcuts: [String: String] = [:], commitAIAgent: String? = nil, mergeAIAgent: String? = nil) {
        self.customCommands = customCommands
        self.workspaceShortcuts = workspaceShortcuts
        self.commitAIAgent = commitAIAgent
        self.mergeAIAgent = mergeAIAgent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customCommands = try container.decodeIfPresent([CustomCommand].self, forKey: .customCommands) ?? []
        workspaceShortcuts = try container.decodeIfPresent([String: String].self, forKey: .workspaceShortcuts) ?? [:]
        commitAIAgent = try container.decodeIfPresent(String.self, forKey: .commitAIAgent)
        mergeAIAgent = try container.decodeIfPresent(String.self, forKey: .mergeAIAgent)
        // 兼容旧字段迁移
        let oldAgent = try container.decodeIfPresent(String.self, forKey: .selectedAIAgent)
        if let old = oldAgent {
            if commitAIAgent == nil { commitAIAgent = old }
            if mergeAIAgent == nil { mergeAIAgent = old }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(customCommands, forKey: .customCommands)
        try container.encode(workspaceShortcuts, forKey: .workspaceShortcuts)
        try container.encodeIfPresent(commitAIAgent, forKey: .commitAIAgent)
        try container.encodeIfPresent(mergeAIAgent, forKey: .mergeAIAgent)
        // 不编码旧字段 selectedAIAgent
    }
}

/// 品牌图标枚举（用于自定义命令图标选择）
enum BrandIcon: String, CaseIterable {
    case cursor = "cursor"
    case vscode = "vscode"
    case trae = "trae"
    case claude = "claude"
    case codex = "codex"
    case gemini = "gemini"
    case opencode = "opencode"
    
    var assetName: String {
        switch self {
        case .cursor: return "cursor-icon"
        case .vscode: return "vscode-icon"
        case .trae: return "trae-icon"
        case .claude: return "claude-icon"
        case .codex: return "codex-icon"
        case .gemini: return "gemini-icon"
        case .opencode: return "opencode-icon"
        }
    }
    
    var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .vscode: return "VS Code"
        case .trae: return "Trae"
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .gemini: return "Gemini CLI"
        case .opencode: return "OpenCode"
        }
    }

    /// 是否有 AI Agent 功能（VS Code 和 Trae 没有）
    var hasAIAgent: Bool {
        switch self {
        case .vscode, .trae: return false
        default: return true
        }
    }

    /// 建议的正常模式命令
    var suggestedCommand: String? {
        switch self {
        case .cursor: return "cursor-agent"
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        case .opencode: return "opencode"
        case .vscode, .trae: return nil
        }
    }

    /// 建议的 Yolo 模式命令（自动执行，跳过确认）
    var yoloCommand: String? {
        switch self {
        case .claude: return "claude --dangerously-skip-permissions"
        case .codex: return "codex --full-auto"
        case .gemini: return "gemini --approval-mode yolo --no-sandbox"
        case .cursor: return "cursor-agent --sandbox disabled -f"
        default: return nil
        }
    }
}
