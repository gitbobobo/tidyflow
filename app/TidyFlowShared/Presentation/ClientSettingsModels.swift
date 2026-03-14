import Foundation

// MARK: - 终端启动请求

/// 通用终端启动参数。
/// 用于“打开一个预填命令的新终端”，不承担设置持久化职责。
public struct TerminalLaunchRequest: Equatable, Sendable {
    public var title: String?
    public var icon: String?
    public var command: String?

    public init(title: String? = nil, icon: String? = nil, command: String? = nil) {
        self.title = title
        self.icon = icon
        self.command = command
    }
}

// MARK: - 快捷键配置

/// 用户自定义快捷键配置
public struct KeybindingConfig: Identifiable, Codable, Equatable {
    public var commandId: String
    public var keyCombination: String
    public var context: String

    public var id: String { commandId }

    public init(commandId: String, keyCombination: String, context: String) {
        self.commandId = commandId
        self.keyCombination = keyCombination
        self.context = context
    }

    enum CodingKeys: String, CodingKey {
        case commandId, keyCombination, context
    }
}

public extension KeybindingConfig {
    static func defaultKeybindings() -> [KeybindingConfig] {
        return [
            KeybindingConfig(commandId: "global.palette", keyCombination: "cmd+shift+p", context: "global"),
            KeybindingConfig(commandId: "global.quickOpen", keyCombination: "cmd+p", context: "global"),
            KeybindingConfig(commandId: "global.reconnect", keyCombination: "cmd+r", context: "global"),
            KeybindingConfig(commandId: "workspace.closeOtherTabs", keyCombination: "cmd+option+t", context: "workspace"),
            KeybindingConfig(commandId: "workspace.save", keyCombination: "cmd+s", context: "workspace"),
            KeybindingConfig(commandId: "workspace.find", keyCombination: "cmd+f", context: "workspace"),
        ]
    }

    /// 命令 ID 的人类可读名称
    static func displayName(for commandId: String) -> String {
        let names: [String: String] = [
            "global.palette": "命令面板",
            "global.quickOpen": "快速打开",
            "global.reconnect": "重新连接",
            "workspace.newTerminal": "新建终端",
            "workspace.closeTab": "关闭标签",
            "workspace.closeOtherTabs": "关闭其他标签",
            "workspace.save": "保存",
            "workspace.find": "查找",
        ]
        return names[commandId] ?? commandId
    }
}

// MARK: - Evolution 阶段语义（纯逻辑部分）

/// 统一维护自主进化运行时阶段的归一化、排序规则。
/// 平台展示语义（Color、.localized 文案）保留在各 app target。
public enum EvolutionStageSemantics {
    public static func runtimeStageKey(_ stage: String) -> String {
        let normalized = normalize(stage)
        if normalized.hasPrefix("implement.general.") { return "implement.general" }
        if normalized.hasPrefix("implement.visual.") { return "implement.visual" }
        if normalized.hasPrefix("verify.") { return "verify" }
        if normalized.hasPrefix("reimplement.") { return "reimplement" }
        if normalized == "implement_general" || normalized == "implement" { return "implement.general" }
        if normalized == "implement_visual" { return "implement.visual" }
        if normalized == "implement_advanced" { return "reimplement" }
        return normalized
    }

    public static func profileStageKey(for stage: String) -> String {
        let normalized = normalize(stage)
        if normalized.hasPrefix("implement.general.") { return "implement_general" }
        if normalized.hasPrefix("implement.visual.") { return "implement_visual" }
        if normalized.hasPrefix("verify.") { return "verify" }
        if normalized.hasPrefix("reimplement.") { return "implement_advanced" }
        if normalized == "implement.general" { return "implement_general" }
        if normalized == "implement.visual" { return "implement_visual" }
        if normalized == "implement" { return "implement_general" }
        if normalized == "reimplement" { return "implement_advanced" }
        return normalized
    }

    public static func stageSortOrder(_ stage: String) -> (Int, Int, Int, String) {
        let normalized = normalize(stage)
        if normalized == "direction" { return (0, 0, 0, "") }
        if normalized == "plan" { return (1, 0, 0, "") }
        if normalized == "auto_commit" { return (5, 0, 0, "") }
        if normalized.hasPrefix("implement.") {
            let parts = normalized.split(separator: ".")
            if parts.count == 3, let index = Int(parts[2]) {
                let kindRank = parts[1] == "general" ? 0 : 1
                return (2, index, kindRank, "")
            }
        }
        if normalized.hasPrefix("reimplement.") {
            let parts = normalized.split(separator: ".")
            if parts.count == 2, let index = Int(parts[1]) {
                return (3, index, 0, "")
            }
        }
        if normalized.hasPrefix("verify.") {
            let parts = normalized.split(separator: ".")
            if parts.count == 2, let index = Int(parts[1]) {
                return (4, index, 0, "")
            }
        }
        switch normalized {
        case "implement_general", "implement":
            return (2, 1, 0, "")
        case "implement_visual":
            return (2, 1, 1, "")
        case "implement_advanced":
            return (3, 1, 0, "")
        case "sync":
            return (6, 0, 0, "")
        case "integration":
            return (7, 0, 0, "")
        default:
            return (8, 0, 0, normalized)
        }
    }

    public static func isRepeatableStage(_ stage: String) -> Bool {
        let normalized = normalize(stage)
        return normalized == "verify" || normalized.hasPrefix("verify.") || normalized.hasPrefix("reimplement.")
    }

    public static func iconName(for stage: String) -> String {
        let normalized = normalize(stage)
        if normalized.hasPrefix("implement.general.") { return "hammer" }
        if normalized.hasPrefix("implement.visual.") { return "paintbrush" }
        if normalized.hasPrefix("verify.") { return "checkmark.seal" }
        if normalized.hasPrefix("reimplement.") { return "wrench.and.screwdriver" }
        switch normalized {
        case "direction":
            return "arrow.triangle.branch"
        case "plan":
            return "map"
        case "implement_general", "implement":
            return "hammer"
        case "implement_visual":
            return "paintbrush"
        case "implement_advanced":
            return "wand.and.stars"
        case "code":
            return "chevron.left.forwardslash.chevron.right"
        case "verify":
            return "checkmark.seal"
        case "auto_commit":
            return "sparkles"
        case "sync":
            return "arrow.trianglehead.2.clockwise"
        case "integration":
            return "arrow.triangle.merge"
        default:
            return "person.crop.square"
        }
    }

    static func normalize(_ stage: String) -> String {
        stage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - 工作空间待办

public enum WorkspaceTodoStatus: String, Codable, CaseIterable {
    case pending
    case inProgress = "in_progress"
    case completed

    public var sortRank: Int {
        switch self {
        case .pending: return 0
        case .inProgress: return 1
        case .completed: return 2
        }
    }
}

public struct WorkspaceTodoItem: Identifiable, Codable, Equatable {
    public var id: String
    public var title: String
    public var note: String?
    public var status: WorkspaceTodoStatus
    public var order: Int64
    public var createdAtMs: Int64
    public var updatedAtMs: Int64

    public init(id: String, title: String, note: String?, status: WorkspaceTodoStatus, order: Int64, createdAtMs: Int64, updatedAtMs: Int64) {
        self.id = id
        self.title = title
        self.note = note
        self.status = status
        self.order = order
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
    }

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

public enum WorkspaceTodoStore {
    public static func items(for workspaceKey: String, in storage: [String: [WorkspaceTodoItem]]) -> [WorkspaceTodoItem] {
        normalize(storage[workspaceKey] ?? [])
    }

    public static func pendingCount(for workspaceKey: String, in storage: [String: [WorkspaceTodoItem]]) -> Int {
        items(for: workspaceKey, in: storage).filter { $0.status != .completed }.count
    }

    @discardableResult
    public static func add(
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
    public static func update(
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
    public static func remove(
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
    public static func setStatus(
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

    public static func move(
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

    public static func normalize(_ items: [WorkspaceTodoItem]) -> [WorkspaceTodoItem] {
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
public struct ClientSettings: Codable {
    /// 工作空间快捷键映射：key 为 "0"-"9"，value 为 "projectName/workspaceName"
    public var workspaceShortcuts: [String: String]
    /// 用于合并操作的 AI Agent
    public var mergeAIAgent: String?
    /// 固定端口，0 表示动态分配
    public var fixedPort: Int
    /// 是否开启远程访问（开启后 Core 会监听 0.0.0.0）
    public var remoteAccessEnabled: Bool
    /// 节点名称；为空时不启用局域网发现广播
    public var nodeName: String?
    /// 是否开启节点发现广播
    public var nodeDiscoveryEnabled: Bool
    /// Evolution 全局默认配置
    public var evolutionDefaultProfiles: [EvolutionStageProfileInfoV2]
    /// Evolution 代理配置（key: "project/workspace"）
    public var evolutionAgentProfiles: [String: [EvolutionStageProfileInfoV2]]
    /// 工作空间待办（key: "project:workspace"）
    public var workspaceTodos: [String: [WorkspaceTodoItem]]
    /// 用户自定义快捷键配置
    public var keybindings: [KeybindingConfig]

    enum CodingKeys: String, CodingKey {
        case workspaceShortcuts
        case mergeAIAgent = "merge_ai_agent"
        case fixedPort = "fixed_port"
        case remoteAccessEnabled = "remote_access_enabled"
        case nodeName = "node_name"
        case nodeDiscoveryEnabled = "node_discovery_enabled"
        case evolutionDefaultProfiles = "evolution_default_profiles"
        case evolutionAgentProfiles = "evolution_agent_profiles"
        case workspaceTodos = "workspace_todos"
        case keybindings
    }

    public init(
        workspaceShortcuts: [String: String] = [:],
        mergeAIAgent: String? = nil,
        fixedPort: Int = 0,
        remoteAccessEnabled: Bool = false,
        nodeName: String? = nil,
        nodeDiscoveryEnabled: Bool = false,
        evolutionDefaultProfiles: [EvolutionStageProfileInfoV2] = [],
        evolutionAgentProfiles: [String: [EvolutionStageProfileInfoV2]] = [:],
        workspaceTodos: [String: [WorkspaceTodoItem]] = [:],
        keybindings: [KeybindingConfig] = []
    ) {
        self.workspaceShortcuts = workspaceShortcuts
        self.mergeAIAgent = mergeAIAgent
        self.fixedPort = fixedPort
        self.remoteAccessEnabled = remoteAccessEnabled
        self.nodeName = nodeName
        self.nodeDiscoveryEnabled = nodeDiscoveryEnabled
        self.evolutionDefaultProfiles = evolutionDefaultProfiles
        self.evolutionAgentProfiles = evolutionAgentProfiles
        self.workspaceTodos = workspaceTodos
        self.keybindings = keybindings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceShortcuts = try container.decodeIfPresent([String: String].self, forKey: .workspaceShortcuts) ?? [:]
        mergeAIAgent = try container.decodeIfPresent(String.self, forKey: .mergeAIAgent)
        fixedPort = try container.decodeIfPresent(Int.self, forKey: .fixedPort) ?? 0
        remoteAccessEnabled = try container.decodeIfPresent(Bool.self, forKey: .remoteAccessEnabled) ?? false
        nodeName = try container.decodeIfPresent(String.self, forKey: .nodeName)
        nodeDiscoveryEnabled = try container.decodeIfPresent(Bool.self, forKey: .nodeDiscoveryEnabled) ?? false
        evolutionDefaultProfiles = []
        evolutionAgentProfiles = [:]
        workspaceTodos = try container.decodeIfPresent([String: [WorkspaceTodoItem]].self, forKey: .workspaceTodos) ?? [:]
        keybindings = try container.decodeIfPresent([KeybindingConfig].self, forKey: .keybindings) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workspaceShortcuts, forKey: .workspaceShortcuts)
        try container.encodeIfPresent(mergeAIAgent, forKey: .mergeAIAgent)
        try container.encode(fixedPort, forKey: .fixedPort)
        try container.encode(remoteAccessEnabled, forKey: .remoteAccessEnabled)
        try container.encodeIfPresent(nodeName, forKey: .nodeName)
        try container.encode(nodeDiscoveryEnabled, forKey: .nodeDiscoveryEnabled)
        try container.encode(workspaceTodos, forKey: .workspaceTodos)
        try container.encode(keybindings, forKey: .keybindings)
    }
}

// MARK: - VS Code 快捷键导入

public struct VSCodeKeybindingEntry: Codable {
    public var key: String
    public var command: String
    public var when: String?

    public init(key: String, command: String, when: String? = nil) {
        self.key = key
        self.command = command
        self.when = when
    }
}

public struct VSCodeKeybindingsImporter {
    public static let commandMapping: [String: String] = [
        "workbench.action.showCommands": "global.palette",
        "workbench.action.quickOpen": "global.quickOpen",
        "workbench.action.terminal.new": "workspace.newTerminal",
        "workbench.action.closeActiveEditor": "workspace.closeTab",
        "workbench.action.files.save": "workspace.save",
        "actions.find": "workspace.find",
        "workbench.action.closeOtherEditors": "workspace.closeOtherTabs",
    ]

    public static func importFrom(jsonData: Data) -> (mapped: [KeybindingConfig], unmapped: [String]) {
        guard let entries = try? JSONDecoder().decode([VSCodeKeybindingEntry].self, from: jsonData) else {
            return ([], [])
        }
        var mapped: [KeybindingConfig] = []
        var unmapped: [String] = []
        for entry in entries {
            if let tidyCommand = commandMapping[entry.command] {
                let keyCombination = convertVSCodeKey(entry.key)
                mapped.append(KeybindingConfig(
                    commandId: tidyCommand,
                    keyCombination: keyCombination,
                    context: contextFor(entry.when)
                ))
            } else {
                unmapped.append(entry.command)
            }
        }
        return (mapped, unmapped)
    }

    private static func convertVSCodeKey(_ key: String) -> String {
        return key
            .replacingOccurrences(of: "meta+", with: "cmd+")
            .replacingOccurrences(of: "ctrl+", with: "cmd+")
    }

    private static func contextFor(_ when: String?) -> String {
        guard let when = when else { return "global" }
        if when.contains("terminal") { return "terminal" }
        if when.contains("editorFocus") { return "editor" }
        return "workspace"
    }
}
