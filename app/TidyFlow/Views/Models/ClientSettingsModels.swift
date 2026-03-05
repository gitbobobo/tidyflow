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

// MARK: - 工作空间待办

enum WorkspaceTodoStatus: String, Codable, CaseIterable {
    case pending
    case inProgress = "in_progress"
    case completed

    var sortRank: Int {
        switch self {
        case .pending: return 0
        case .inProgress: return 1
        case .completed: return 2
        }
    }

    var localizedTitle: String {
        switch self {
        case .pending: return "todo.status.pending".localized
        case .inProgress: return "todo.status.inProgress".localized
        case .completed: return "todo.status.completed".localized
        }
    }
}

struct WorkspaceTodoItem: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var note: String?
    var status: WorkspaceTodoStatus
    var order: Int64
    var createdAtMs: Int64
    var updatedAtMs: Int64

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

enum WorkspaceTodoStore {
    static func items(for workspaceKey: String, in storage: [String: [WorkspaceTodoItem]]) -> [WorkspaceTodoItem] {
        normalize(storage[workspaceKey] ?? [])
    }

    static func pendingCount(for workspaceKey: String, in storage: [String: [WorkspaceTodoItem]]) -> Int {
        items(for: workspaceKey, in: storage).filter { $0.status != .completed }.count
    }

    @discardableResult
    static func add(
        workspaceKey: String,
        title: String,
        note: String?,
        status: WorkspaceTodoStatus = .pending,
        storage: inout [String: [WorkspaceTodoItem]]
    ) -> WorkspaceTodoItem? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        var items = normalize(storage[workspaceKey] ?? [])
        let timestamp = nowMs()
        let nextOrder = (items.filter { $0.status == status }.map(\.order).max() ?? -1) + 1
        let newItem = WorkspaceTodoItem(
            id: UUID().uuidString,
            title: trimmedTitle,
            note: normalizedNote(note),
            status: status,
            order: nextOrder,
            createdAtMs: timestamp,
            updatedAtMs: timestamp
        )
        items.append(newItem)
        commit(items, workspaceKey: workspaceKey, storage: &storage)
        return newItem
    }

    @discardableResult
    static func update(
        workspaceKey: String,
        todoID: String,
        title: String,
        note: String?,
        storage: inout [String: [WorkspaceTodoItem]]
    ) -> Bool {
        var items = normalize(storage[workspaceKey] ?? [])
        guard let index = items.firstIndex(where: { $0.id == todoID }) else { return false }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return false }
        items[index].title = trimmedTitle
        items[index].note = normalizedNote(note)
        items[index].updatedAtMs = nowMs()
        commit(items, workspaceKey: workspaceKey, storage: &storage)
        return true
    }

    @discardableResult
    static func remove(
        workspaceKey: String,
        todoID: String,
        storage: inout [String: [WorkspaceTodoItem]]
    ) -> Bool {
        var items = normalize(storage[workspaceKey] ?? [])
        let oldCount = items.count
        items.removeAll { $0.id == todoID }
        guard items.count != oldCount else { return false }
        commit(items, workspaceKey: workspaceKey, storage: &storage)
        return true
    }

    @discardableResult
    static func setStatus(
        workspaceKey: String,
        todoID: String,
        status: WorkspaceTodoStatus,
        storage: inout [String: [WorkspaceTodoItem]]
    ) -> Bool {
        var items = normalize(storage[workspaceKey] ?? [])
        guard let index = items.firstIndex(where: { $0.id == todoID }) else { return false }
        guard items[index].status != status else { return true }
        items[index].status = status
        items[index].order = (items.filter { $0.status == status }.map(\.order).max() ?? -1) + 1
        items[index].updatedAtMs = nowMs()
        commit(items, workspaceKey: workspaceKey, storage: &storage)
        return true
    }

    static func move(
        workspaceKey: String,
        status: WorkspaceTodoStatus,
        fromOffsets: IndexSet,
        toOffset: Int,
        storage: inout [String: [WorkspaceTodoItem]]
    ) {
        var pending = statusItems(.pending, workspaceKey: workspaceKey, storage: storage)
        var inProgress = statusItems(.inProgress, workspaceKey: workspaceKey, storage: storage)
        var completed = statusItems(.completed, workspaceKey: workspaceKey, storage: storage)

        switch status {
        case .pending:
            pending = reindexed(moved(pending, fromOffsets: fromOffsets, toOffset: toOffset))
        case .inProgress:
            inProgress = reindexed(moved(inProgress, fromOffsets: fromOffsets, toOffset: toOffset))
        case .completed:
            completed = reindexed(moved(completed, fromOffsets: fromOffsets, toOffset: toOffset))
        }

        let merged = pending + inProgress + completed
        commit(merged, workspaceKey: workspaceKey, storage: &storage)
    }

    static func normalize(_ items: [WorkspaceTodoItem]) -> [WorkspaceTodoItem] {
        var pending = items.filter { $0.status == .pending }
        var inProgress = items.filter { $0.status == .inProgress }
        var completed = items.filter { $0.status == .completed }

        pending.sort { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            if lhs.updatedAtMs != rhs.updatedAtMs { return lhs.updatedAtMs < rhs.updatedAtMs }
            return lhs.createdAtMs < rhs.createdAtMs
        }
        inProgress.sort { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            if lhs.updatedAtMs != rhs.updatedAtMs { return lhs.updatedAtMs < rhs.updatedAtMs }
            return lhs.createdAtMs < rhs.createdAtMs
        }
        completed.sort { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            if lhs.updatedAtMs != rhs.updatedAtMs { return lhs.updatedAtMs < rhs.updatedAtMs }
            return lhs.createdAtMs < rhs.createdAtMs
        }

        for idx in pending.indices {
            pending[idx].order = Int64(idx)
        }
        for idx in inProgress.indices {
            inProgress[idx].order = Int64(idx)
        }
        for idx in completed.indices {
            completed[idx].order = Int64(idx)
        }

        return pending + inProgress + completed
    }

    private static func commit(
        _ items: [WorkspaceTodoItem],
        workspaceKey: String,
        storage: inout [String: [WorkspaceTodoItem]]
    ) {
        let normalized = normalize(items)
        if normalized.isEmpty {
            storage.removeValue(forKey: workspaceKey)
        } else {
            storage[workspaceKey] = normalized
        }
    }

    private static func statusItems(
        _ status: WorkspaceTodoStatus,
        workspaceKey: String,
        storage: [String: [WorkspaceTodoItem]]
    ) -> [WorkspaceTodoItem] {
        items(for: workspaceKey, in: storage).filter { $0.status == status }
    }

    private static func normalizedNote(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func moved<T>(_ source: [T], fromOffsets: IndexSet, toOffset: Int) -> [T] {
        var result = source
        let sortedOffsets = fromOffsets.sorted()
        let moving = sortedOffsets.compactMap { offset -> T? in
            guard result.indices.contains(offset) else { return nil }
            return result[offset]
        }
        for offset in sortedOffsets.reversed() where result.indices.contains(offset) {
            result.remove(at: offset)
        }
        let target = max(0, min(toOffset, result.count))
        result.insert(contentsOf: moving, at: target)
        return result
    }

    private static func reindexed(_ source: [WorkspaceTodoItem]) -> [WorkspaceTodoItem] {
        var result = source
        for idx in result.indices {
            result[idx].order = Int64(idx)
        }
        return result
    }
}

/// 客户端设置
struct ClientSettings: Codable {
    var customCommands: [CustomCommand]
    /// 工作空间快捷键映射：key 为 "0"-"9"，value 为 "projectName/workspaceName"
    var workspaceShortcuts: [String: String]
    /// 用于合并操作的 AI Agent
    var mergeAIAgent: String?
    /// 固定端口，0 表示动态分配
    var fixedPort: Int
    /// 是否开启远程访问（开启后 Core 会监听 0.0.0.0）
    var remoteAccessEnabled: Bool
    /// Evolution 代理配置（key: "project/workspace"）
    var evolutionAgentProfiles: [String: [EvolutionStageProfileInfoV2]]
    /// 工作空间待办（key: "project:workspace"）
    var workspaceTodos: [String: [WorkspaceTodoItem]]

    enum CodingKeys: String, CodingKey {
        case customCommands
        case workspaceShortcuts
        case mergeAIAgent = "merge_ai_agent"
        case fixedPort = "fixed_port"
        case remoteAccessEnabled = "remote_access_enabled"
        case evolutionAgentProfiles = "evolution_agent_profiles"
        case workspaceTodos = "workspace_todos"
    }

    init(
        customCommands: [CustomCommand] = [],
        workspaceShortcuts: [String: String] = [:],
        mergeAIAgent: String? = nil,
        fixedPort: Int = 0,
        remoteAccessEnabled: Bool = false,
        evolutionAgentProfiles: [String: [EvolutionStageProfileInfoV2]] = [:],
        workspaceTodos: [String: [WorkspaceTodoItem]] = [:]
    ) {
        self.customCommands = customCommands
        self.workspaceShortcuts = workspaceShortcuts
        self.mergeAIAgent = mergeAIAgent
        self.fixedPort = fixedPort
        self.remoteAccessEnabled = remoteAccessEnabled
        self.evolutionAgentProfiles = evolutionAgentProfiles
        self.workspaceTodos = workspaceTodos
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customCommands = try container.decodeIfPresent([CustomCommand].self, forKey: .customCommands) ?? []
        workspaceShortcuts = try container.decodeIfPresent([String: String].self, forKey: .workspaceShortcuts) ?? [:]
        mergeAIAgent = try container.decodeIfPresent(String.self, forKey: .mergeAIAgent)
        fixedPort = try container.decodeIfPresent(Int.self, forKey: .fixedPort) ?? 0
        remoteAccessEnabled = try container.decodeIfPresent(Bool.self, forKey: .remoteAccessEnabled) ?? false
        evolutionAgentProfiles = [:]
        workspaceTodos = try container.decodeIfPresent([String: [WorkspaceTodoItem]].self, forKey: .workspaceTodos) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(customCommands, forKey: .customCommands)
        try container.encode(workspaceShortcuts, forKey: .workspaceShortcuts)
        try container.encodeIfPresent(mergeAIAgent, forKey: .mergeAIAgent)
        try container.encode(fixedPort, forKey: .fixedPort)
        try container.encode(remoteAccessEnabled, forKey: .remoteAccessEnabled)
        try container.encode(workspaceTodos, forKey: .workspaceTodos)
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
    case copilot = "copilot"
    
    var assetName: String {
        switch self {
        case .cursor: return "cursor-icon"
        case .vscode: return "vscode-icon"
        case .trae: return "trae-icon"
        case .claude: return "claude-icon"
        case .codex: return "codex-icon"
        case .gemini: return "gemini-icon"
        case .opencode: return "opencode-icon"
        case .copilot: return "copilot-icon"
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
        case .copilot: return "Copilot CLI"
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
        case .copilot: return "copilot"
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
        case .copilot: return "copilot --allow-all"
        default: return nil
        }
    }
}
