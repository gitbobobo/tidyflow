import Foundation
import SwiftUI
import UIKit

private struct PairExchangeHTTPBody: Encodable {
    let pairCode: String
    let deviceName: String

    enum CodingKeys: String, CodingKey {
        case pairCode = "pair_code"
        case deviceName = "device_name"
    }
}

private struct PairExchangeHTTPResponse: Decodable {
    let tokenId: String
    let wsToken: String
    let deviceName: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case tokenId = "token_id"
        case wsToken = "ws_token"
        case deviceName = "device_name"
        case expiresAt = "expires_at"
    }
}

private struct PairErrorHTTPResponse: Decodable {
    let error: String
    let message: String
}

enum MobileWorkspaceTaskType: String {
    case aiCommit
    case aiMerge
    case projectCommand
}

enum MobileWorkspaceTaskStatus: String {
    case pending
    case running
    case completed
    case failed
    case cancelled

    var isActive: Bool {
        self == .pending || self == .running
    }
}

enum ReconnectState: Equatable {
    case idle
    case reconnecting(attempt: Int, maxAttempts: Int)
    case failed
}

struct MobileWorkspaceTask: Identifiable, Equatable {
    let id: String
    let project: String
    let workspace: String
    let type: MobileWorkspaceTaskType
    var title: String
    var icon: String
    var status: MobileWorkspaceTaskStatus
    var message: String
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var commandId: String?
    var remoteTaskId: String?
    var lastOutputLine: String?
}

struct MobileWorkspaceGitSummary: Equatable {
    let additions: Int
    let deletions: Int
    let defaultBranch: String?
}

private struct MobileTerminalPresentation {
    let icon: String
    let name: String
    let sourceCommand: String?
}

@MainActor
protocol MobileTerminalOutputSink: AnyObject {
    func writeOutput(_ bytes: [UInt8])
    func focusTerminal()
    /// 切换 term_id 时必须重置本地终端视图，否则 SwiftUI 可能复用同一个 TerminalView，
    /// 导致新终端的 scrollback/输出追加到旧缓冲里，表现为“多终端数据混在一起”。
    func resetTerminal()
}

@MainActor
final class MobileAppState: ObservableObject {
    // 连接表单
    @Published var host: String = ""
    @Published var port: String = "47999"
    @Published var pairCode: String = ""
    @Published var deviceName: String = UIDevice.current.name
    /// 是否通过 HTTPS/WSS 连接（反向代理场景）
    @Published var useHTTPS: Bool = false

    // 连接状态
    @Published var connecting: Bool = false
    @Published var autoConnecting: Bool = false
    @Published var hasSavedConnection: Bool = false
    @Published var isConnected: Bool = false
    @Published var connectionMessage: String = ""
    @Published var errorMessage: String = ""
    @Published var reconnectState: ReconnectState = .idle

    // 数据
    @Published var projects: [ProjectInfo] = []
    @Published var workspaces: [WorkspaceInfo] = []
    @Published var workspacesByProject: [String: [WorkspaceInfo]] = [:]
    @Published var activeTerminals: [TerminalSessionInfo] = []
    @Published var customCommands: [CustomCommand] = []
    @Published var workspaceShortcuts: [String: String] = [:]
    @Published var workspaceTerminalOpenTime: [String: Date] = [:]
    @Published var workspaceGitSummary: [String: MobileWorkspaceGitSummary] = [:]
    @Published var workspaceTasksByKey: [String: [MobileWorkspaceTask]] = [:]
    @Published var commitAIAgent: String?
    @Published var mergeAIAgent: String?
    // AI Chat 状态（iOS 端完整对齐 macOS）
    @Published var aiActiveProject: String = ""
    @Published var aiActiveWorkspace: String = ""
    @Published var aiChatTool: AIChatTool = .opencode
    @Published var aiCurrentSessionId: String?
    @Published var aiChatMessages: [AIChatMessage] = []
    @Published var aiIsStreaming: Bool = false
    @Published var aiAbortPendingSessionId: String?
    @Published var aiSessions: [AISessionInfo] = [] {
        didSet {
            aiSessionsByTool[aiChatTool] = aiSessions
            refreshMergedAISessions()
        }
    }
    @Published var aiMergedSessions: [AISessionInfo] = []
    @Published var aiProviders: [AIProviderInfo] = []
    @Published var aiSelectedModel: AIModelSelection?
    @Published var aiAgents: [AIAgentInfo] = []
    @Published var aiSelectedAgent: String?
    @Published var aiSlashCommands: [AISlashCommandInfo] = []
    @Published var isAILoadingModels: Bool = false
    @Published var isAILoadingAgents: Bool = false
    @Published var aiFileIndexCache: [String: FileIndexCache] = [:]

    let aiChatStore = AIChatStore()

    // AI Chat：按工具分桶存储会话
    private var aiSessionsByTool: [AIChatTool: [AISessionInfo]] = [:]

    // 导航
    @Published var navigationPath = NavigationPath()

    // 终端
    @Published var currentTermId: String = ""
    @Published var terminalCols: Int = 80
    @Published var terminalRows: Int = 24
    /// 待创建终端的项目/工作空间（等终端视图 ready 后再真正创建）
    private var pendingTermProject: String = ""
    private var pendingTermWorkspace: String = ""
    /// 待附着的终端 ID（重连场景）
    private var pendingAttachTermId: String = ""
    /// 待执行的自定义命令（终端创建后自动发送）
    private var pendingCustomCommand: String = ""
    /// 待执行命令图标（用于终端列表展示）
    private var pendingCustomCommandIcon: String = ""
    /// 待执行命令名称（用于终端列表展示）
    private var pendingCustomCommandName: String = ""
    /// Ctrl 一次性修饰状态（用于虚拟键盘输入）
    private var ctrlArmedForNextInput: Bool = false
    /// 终端视图是否已经拿到有效 cols/rows
    private var isTerminalViewReady: Bool = false
    /// 终端输出流控 ACK：累计未确认字节数
    private var termOutputUnackedBytes: Int = 0
    /// ACK 阈值（50KB），与 macOS xterm.js 端一致
    private let termOutputAckThreshold = 50 * 1024

    /// 原生终端输出目标（SwiftTerm）
    private weak var terminalSink: MobileTerminalOutputSink?
    /// 终端未 ready 或尚未绑定 sink 时暂存输出，避免首屏丢数据
    private var pendingOutputChunks: [[UInt8]] = []
    private let pendingOutputChunkLimit = 128
    /// 记录最近一次已重置并开始渲染的 term_id，用于避免 SwiftUI 复用视图导致内容串台
    private var lastRenderedTermId: String = ""
    /// term_id -> 展示信息（图标/名称）
    private var terminalPresentationById: [String: MobileTerminalPresentation] = [:]
    /// AI 提交结果不带 project/workspace，按触发顺序匹配
    private var aiCommitPendingTaskIds: [String] = []
    /// AI 合并按 project 匹配
    private var aiMergePendingTaskIdByProject: [String: String] = [:]
    /// AI Chat：message_id -> message 下标
    private var aiMessageIndexByMessageId: [String: Int] = [:]
    /// AI Chat：part_id -> (message 下标, part 下标)
    private var aiPartIndexByPartId: [String: (msgIdx: Int, partIdx: Int)] = [:]
    /// AI Chat：按工作空间缓存快照，切换路由时恢复上下文
    private var aiChatSnapshotCache: [String: AIChatSnapshot] = [:]
    /// AI Chat：等待会话创建完成后的待发送请求（含上下文防串台）
    private var aiPendingSendRequest: (
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool,
        kind: PendingAIRequestKind
    )?
    /// 项目命令 started/completed 路由（project|workspace|commandId -> taskId 队列）
    private var projectCommandPendingTaskIdsByKey: [String: [String]] = [:]
    /// 项目命令 remote task_id -> 本地 taskId
    private var projectCommandTaskIdByRemoteTaskId: [String: String] = [:]
    /// 当前详情页选中的项目名（兼容旧接口）
    private var selectedProjectName: String = ""

    /// AI Chat 待发送请求类型
    private enum PendingAIRequestKind {
        case message(
            text: String,
            imageParts: [[String: Any]]?,
            model: [String: String]?,
            agent: String?,
            fileRefs: [String]?
        )
        case command(
            command: String,
            arguments: String,
            imageParts: [[String: Any]]?,
            model: [String: String]?,
            agent: String?,
            fileRefs: [String]?
        )
    }

    private let wsClient = WSClient()
    /// 重连任务（指数退避）
    private var reconnectTask: Task<Void, Never>?

    init() {
        setupWSCallbacks()
        // 恢复已保存的连接信息
        if let saved = ConnectionStorage.load() {
            host = saved.host
            port = "\(saved.port)"
            deviceName = saved.deviceName
            useHTTPS = saved.useHTTPS
            hasSavedConnection = true
        }
    }

    // MARK: - 前后台生命周期

    /// 进入后台时标记连接为 stale，确保回到前台时能正确触发探活/重连
    func handleEnterBackground() {
        guard !wsClient.isIntentionalDisconnect else { return }
        wsClient.markStaleIfConnected()
    }

    /// 回到前台：探活 → 重连 → 恢复键盘焦点
    func handleReturnToForeground() {
        // 恢复终端键盘焦点（无论连接状态，先让键盘弹出来）
        terminalSink?.focusTerminal()

        guard hasSavedConnection, !wsClient.isIntentionalDisconnect else { return }

        if wsClient.isStale || !isConnected {
            // 后台回来或已断开，直接重连
            reconnectWithBackoff()
            return
        }

        // 看起来还连着，ping 一下确认
        wsClient.sendPing(timeout: 2.0) { [weak self] alive in
            guard let self else { return }
            if alive {
                // 连接正常，重新附着终端输出（后台期间可能丢失订阅）
                self.reattachTerminalIfNeeded()
            } else {
                // ping 超时，连接已死
                self.reconnectWithBackoff()
            }
        }
    }

    /// 重连成功后或 ping 存活时，重新附着当前终端的输出订阅
    private func reattachTerminalIfNeeded() {
        guard !currentTermId.isEmpty else { return }
        wsClient.requestTermAttach(termId: currentTermId)
    }

    // MARK: - 连接

    func pairAndConnect() async {
        errorMessage = ""
        connectionMessage = ""
        connecting = true
        defer { connecting = false }

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = pairCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDeviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedHost.isEmpty else {
            errorMessage = "请填写电脑地址"
            return
        }
        guard let portValue = Int(port), portValue > 0, portValue <= 65535 else {
            errorMessage = "端口无效"
            return
        }
        guard trimmedCode.count == 6 else {
            errorMessage = "配对码必须是 6 位数字"
            return
        }

        do {
            let token = try await exchangePairCode(
                host: trimmedHost,
                port: portValue,
                pairCode: trimmedCode,
                deviceName: trimmedDeviceName.isEmpty ? "iOS Device" : trimmedDeviceName,
                secure: useHTTPS
            )

            wsClient.disconnect()
            wsClient.updateAuthToken(token.wsToken)
            wsClient.updateBaseURL(
                AppConfig.makeWsURL(host: trimmedHost, port: portValue, token: token.wsToken, secure: useHTTPS),
                reconnect: false
            )
            wsClient.connect()
            connectionMessage = "已配对，正在连接..."

            // 保存连接信息
            ConnectionStorage.save(SavedConnection(
                host: trimmedHost,
                port: portValue,
                wsToken: token.wsToken,
                deviceName: trimmedDeviceName.isEmpty ? "iOS Device" : trimmedDeviceName,
                savedAt: Date(),
                useHTTPS: useHTTPS
            ))
            hasSavedConnection = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        cancelReconnect()
        wsClient.disconnect()
        isConnected = false
        currentTermId = ""
        setCtrlArmed(false)
        connectionMessage = "已断开"
    }

    /// 使用保存的 token 自动重连
    func autoReconnect() async {
        guard let saved = ConnectionStorage.load() else { return }
        errorMessage = ""
        connectionMessage = "正在自动连接..."
        autoConnecting = true
        defer { autoConnecting = false }

        wsClient.disconnect()
        wsClient.updateAuthToken(saved.wsToken)
        wsClient.updateBaseURL(
            AppConfig.makeWsURL(host: saved.host, port: saved.port, token: saved.wsToken, secure: saved.useHTTPS),
            reconnect: false
        )
        wsClient.connect()

        // 等待连接结果，超时 5 秒
        let deadline = Date().addingTimeInterval(5)
        while !isConnected && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if !isConnected {
            connectionMessage = "自动连接超时，请手动配对"
        }
    }

    /// 使用指数退避重连（5次尝试：0.5s, 1s, 2s, 4s, 8s）
    func reconnectWithBackoff() {
        reconnectTask?.cancel()
        
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            
            let delays: [TimeInterval] = [0.5, 1, 2, 4, 8]
            let maxAttempts = delays.count
            
            for (index, delay) in delays.enumerated() {
                if Task.isCancelled { return }
                
                let attempt = index + 1
                await MainActor.run {
                    self.reconnectState = .reconnecting(attempt: attempt, maxAttempts: maxAttempts)
                }
                
                guard let saved = ConnectionStorage.load() else {
                    await MainActor.run {
                        self.reconnectState = .failed
                    }
                    return
                }
                
                await MainActor.run {
                    self.wsClient.disconnect()
                }
                
                // 等待旧连接完全清理（disconnect 会取消 webSocketTask，需要时间完全关闭）
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                
                await MainActor.run {
                    self.wsClient.updateAuthToken(saved.wsToken)
                    self.wsClient.updateBaseURL(
                        AppConfig.makeWsURL(host: saved.host, port: saved.port, token: saved.wsToken, secure: saved.useHTTPS),
                        reconnect: false
                    )
                    self.wsClient.connect()
                }
                
                // 等待连接结果，每轮最多等待 3 秒
                let pollDeadline = Date().addingTimeInterval(3)
                while !Task.isCancelled {
                    let connected = await MainActor.run { self.isConnected }
                    if connected {
                        await MainActor.run { self.reconnectState = .idle }
                        return
                    }
                    if Date() >= pollDeadline { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                
                if Task.isCancelled { return }
                
                // 如果还有下一次尝试，等待指数退避时间
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
            
            // 所有尝试都失败
            await MainActor.run {
                self.reconnectState = .failed
            }
        }
    }
    
    /// 重置状态并重新开始指数退避重连
    func retryReconnect() {
        reconnectState = .idle
        reconnectWithBackoff()
    }
    
    /// 取消正在进行的重连任务
    func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectState = .idle
    }

    /// 清除保存的连接信息
    func clearSavedConnection() {
        ConnectionStorage.clear()
        hasSavedConnection = false
    }

    // MARK: - 项目/工作空间

    /// 刷新项目树（项目、工作空间、终端、设置、任务历史）
    func refreshProjectTree() {
        wsClient.requestListProjects()
        wsClient.requestTermList()
        wsClient.requestGetClientSettings()
        wsClient.requestListTasks()
    }

    func selectProject(_ projectName: String) {
        selectedProjectName = projectName
        workspaces = []
        wsClient.requestListWorkspaces(project: projectName)
        wsClient.requestTermList()
    }

    /// 工作空间详情页刷新
    func refreshWorkspaceDetail(project: String, workspace: String) {
        wsClient.requestTermList()
        wsClient.requestGitStatus(project: project, workspace: workspace)
    }

    /// 懒加载项目工作空间
    func requestWorkspacesIfNeeded(project: String) {
        if workspacesByProject[project] == nil {
            wsClient.requestListWorkspaces(project: project)
        }
    }

    func workspacesForProject(_ project: String) -> [WorkspaceInfo] {
        workspacesByProject[project] ?? []
    }

    func projectCommands(for project: String) -> [ProjectCommand] {
        projects.first(where: { $0.name == project })?.commands ?? []
    }

    /// 自动分配的工作空间快捷键（按终端首次打开时间）
    var autoWorkspaceShortcuts: [String: String] {
        let sorted = workspaceTerminalOpenTime.sorted { $0.value < $1.value }.prefix(9)
        let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
        var result: [String: String] = [:]
        for (index, item) in sorted.enumerated() {
            result[keys[index]] = item.key
        }
        return result
    }

    func getWorkspaceShortcutKey(workspaceKey: String) -> String? {
        let globalKey: String
        if workspaceKey.contains(":") {
            globalKey = workspaceKey
        } else {
            let components = workspaceKey.split(separator: "/", maxSplits: 1)
            if components.count == 2 {
                var wsName = String(components[1])
                if wsName == "(default)" { wsName = "default" }
                globalKey = "\(components[0]):\(wsName)"
            } else {
                globalKey = workspaceKey
            }
        }
        for (shortcut, key) in autoWorkspaceShortcuts where key == globalKey {
            return shortcut
        }
        return nil
    }

    /// iOS 侧与 macOS 相同的项目排序策略
    var sortedProjectsForSidebar: [ProjectInfo] {
        projects.sorted { lhs, rhs in
            let lhsHasShortcut = projectMinShortcutKey(lhs) < Int.max
            let rhsHasShortcut = projectMinShortcutKey(rhs) < Int.max
            if lhsHasShortcut != rhsHasShortcut {
                return lhsHasShortcut
            }

            if lhsHasShortcut && rhsHasShortcut {
                let lhsTime = projectEarliestTerminalTime(lhs)
                let rhsTime = projectEarliestTerminalTime(rhs)
                if let l = lhsTime, let r = rhsTime, l != r {
                    return l < r
                }
            }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// 获取指定项目+工作空间的活跃终端
    func terminalsForWorkspace(project: String, workspace: String) -> [TerminalSessionInfo] {
        activeTerminals.filter { $0.project == project && $0.workspace == workspace && $0.isRunning }
    }

    func terminalPresentation(for termId: String) -> (icon: String, name: String)? {
        guard let presentation = terminalPresentationById[termId] else { return nil }
        return (presentation.icon, presentation.name)
    }

    func gitSummaryForWorkspace(project: String, workspace: String) -> MobileWorkspaceGitSummary {
        workspaceGitSummary[globalWorkspaceKey(project: project, workspace: workspace)] ??
        MobileWorkspaceGitSummary(additions: 0, deletions: 0, defaultBranch: nil)
    }

    func tasksForWorkspace(project: String, workspace: String) -> [MobileWorkspaceTask] {
        let key = globalWorkspaceKey(project: project, workspace: workspace)
        let tasks = workspaceTasksByKey[key] ?? []
        return tasks.sorted { lhs, rhs in
            if lhs.status.isActive != rhs.status.isActive {
                return lhs.status.isActive && !rhs.status.isActive
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    func runningTasksForWorkspace(project: String, workspace: String) -> [MobileWorkspaceTask] {
        tasksForWorkspace(project: project, workspace: workspace).filter { $0.status.isActive }
    }

    func canCancelTask(_ task: MobileWorkspaceTask) -> Bool {
        task.status.isActive
    }

    func cancelTask(_ task: MobileWorkspaceTask) {
        guard canCancelTask(task) else { return }

        switch task.type {
        case .projectCommand:
            if let commandId = task.commandId {
                wsClient.requestCancelProjectCommand(
                    project: task.project,
                    workspace: task.workspace,
                    commandId: commandId,
                    taskId: task.remoteTaskId
                )
            }
        case .aiCommit:
            wsClient.requestCancelAITask(
                project: task.project,
                workspace: task.workspace,
                operationType: "ai_commit"
            )
        case .aiMerge:
            wsClient.requestCancelAITask(
                project: task.project,
                workspace: task.workspace,
                operationType: "ai_merge"
            )
        }

        mutateTask(task.id) { item in
            item.status = .cancelled
            item.message = "已取消"
            item.completedAt = Date()
        }
    }

    /// 清除指定工作空间的已完成任务
    func clearCompletedTasks(project: String, workspace: String) {
        let key = globalWorkspaceKey(project: project, workspace: workspace)
        guard var tasks = workspaceTasksByKey[key] else { return }
        tasks.removeAll { !$0.status.isActive }
        workspaceTasksByKey[key] = tasks.isEmpty ? nil : tasks
    }

    func runAICommit(project: String, workspace: String) {
        let task = createTask(
            project: project,
            workspace: workspace,
            type: .aiCommit,
            title: "一键提交",
            icon: "sparkles",
            message: "执行中..."
        )
        aiCommitPendingTaskIds.append(task.id)
        wsClient.requestGitAICommit(project: project, workspace: workspace, aiAgent: commitAIAgent)
    }

    func runAIMerge(project: String, workspace: String) {
        let task = createTask(
            project: project,
            workspace: workspace,
            type: .aiMerge,
            title: "智能合并",
            icon: "cpu",
            message: "执行中..."
        )
        aiMergePendingTaskIdByProject[project] = task.id
        let summary = gitSummaryForWorkspace(project: project, workspace: workspace)
        wsClient.requestGitAIMerge(
            project: project,
            workspace: workspace,
            aiAgent: mergeAIAgent,
            defaultBranch: summary.defaultBranch ?? "main"
        )
    }

    func runProjectCommand(project: String, workspace: String, command: ProjectCommand) {
        if command.interactive {
            navigationPath.append(MobileRoute.terminal(
                project: project,
                workspace: workspace,
                command: command.command,
                commandIcon: command.icon,
                commandName: command.name
            ))
            return
        }

        let task = createTask(
            project: project,
            workspace: workspace,
            type: .projectCommand,
            title: command.name,
            icon: command.icon,
            message: "等待启动..."
        )
        mutateTask(task.id) { item in
            item.status = .pending
            item.startedAt = nil
            item.commandId = command.id
        }

        let routingKey = projectCommandRoutingKey(project: project, workspace: workspace, commandId: command.id)
        var queue = projectCommandPendingTaskIdsByKey[routingKey] ?? []
        queue.append(task.id)
        projectCommandPendingTaskIdsByKey[routingKey] = queue

        wsClient.requestRunProjectCommand(project: project, workspace: workspace, commandId: command.id)
    }

    // MARK: - AI 聊天

    /// 进入 AI 聊天页面：按 project/workspace 恢复上下文并刷新服务端会话数据
    func openAIChat(project: String, workspace: String) {
        let trimmedProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWorkspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProject.isEmpty, !trimmedWorkspace.isEmpty else { return }

        let contextChanged = aiActiveProject != trimmedProject || aiActiveWorkspace != trimmedWorkspace
        if contextChanged {
            saveCurrentAISnapshotIfNeeded()
            aiPendingSendRequest = nil
            aiAbortPendingSessionId = nil
        }

        aiActiveProject = trimmedProject
        aiActiveWorkspace = trimmedWorkspace

        if contextChanged {
            restoreAISnapshot(project: trimmedProject, workspace: trimmedWorkspace)
        } else if aiChatMessages.isEmpty {
            // 同一上下文视图重建时，优先从快照恢复，避免页面闪空
            restoreAISnapshot(project: trimmedProject, workspace: trimmedWorkspace)
        }

        aiProviders = []
        aiSelectedModel = nil
        aiAgents = []
        aiSelectedAgent = nil
        aiSlashCommands = []
        requestAIContextResources()
        reloadCurrentAISessionIfNeeded()
    }

    /// 离开 AI 聊天页面：仅保存快照，不主动清空上下文，便于返回时秒级恢复
    func closeAIChat() {
        saveCurrentAISnapshotIfNeeded()
        aiPendingSendRequest = nil
        aiAbortPendingSessionId = nil
    }

    /// 新建空会话（本地清空态）
    func createNewAISession() {
        aiPendingSendRequest = nil
        aiAbortPendingSessionId = nil
        aiCurrentSessionId = nil
        aiChatStore.setCurrentSessionId(nil)
        aiChatMessages = []
        aiIsStreaming = false
        aiMessageIndexByMessageId = [:]
        aiPartIndexByPartId = [:]
    }

    var canSwitchAIChatTool: Bool {
        aiCurrentSessionId == nil &&
        aiPendingSendRequest == nil &&
        aiAbortPendingSessionId == nil &&
        !aiIsStreaming
    }

    /// 切换 AI 工具（仅空白会话允许）
    func switchAIChatTool(_ newTool: AIChatTool) {
        guard newTool != aiChatTool else { return }
        guard canSwitchAIChatTool else { return }

        saveCurrentAISnapshotIfNeeded()
        aiPendingSendRequest = nil
        aiAbortPendingSessionId = nil
        aiChatTool = newTool

        if !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty {
            restoreAISnapshot(project: aiActiveProject, workspace: aiActiveWorkspace)
            aiProviders = []
            aiSelectedModel = nil
            aiAgents = []
            aiSelectedAgent = nil
            aiSlashCommands = []
            requestAIContextResources()
            reloadCurrentAISessionIfNeeded()
        }
    }

    /// 拉取会话列表 + provider/agent/斜杠命令
    func requestAIContextResources() {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return }
        // 会话列表按工具分别拉取，再在客户端做跨工具融合排序
        for tool in AIChatTool.allCases {
            wsClient.requestAISessionList(projectName: aiActiveProject, workspaceName: aiActiveWorkspace, aiTool: tool)
        }
        isAILoadingModels = true
        isAILoadingAgents = true
        wsClient.requestAIProviderList(projectName: aiActiveProject, workspaceName: aiActiveWorkspace, aiTool: aiChatTool)
        wsClient.requestAIAgentList(projectName: aiActiveProject, workspaceName: aiActiveWorkspace, aiTool: aiChatTool)
        wsClient.requestAISlashCommands(projectName: aiActiveProject, workspaceName: aiActiveWorkspace, aiTool: aiChatTool)
    }

    /// 加载指定会话消息
    func loadAISession(_ session: AISessionInfo) {
        guard session.projectName == aiActiveProject,
              session.workspaceName == aiActiveWorkspace else { return }

        let targetTool = session.aiTool

        if targetTool != aiChatTool {
            // 跨工具打开历史会话时，允许在“非流式/非待发/非停止中”条件下切换工具，
            // 不依赖 aiCurrentSessionId（否则会出现已选中但详情不加载）。
            guard aiPendingSendRequest == nil,
                  aiAbortPendingSessionId == nil,
                  !aiIsStreaming else { return }

            saveCurrentAISnapshotIfNeeded()
            aiPendingSendRequest = nil
            aiAbortPendingSessionId = nil
            aiChatTool = targetTool
            restoreAISnapshot(project: aiActiveProject, workspace: aiActiveWorkspace)
            aiProviders = []
            aiSelectedModel = nil
            aiAgents = []
            aiSelectedAgent = nil
            aiSlashCommands = []
            isAILoadingModels = true
            isAILoadingAgents = true
            wsClient.requestAIProviderList(projectName: aiActiveProject, workspaceName: aiActiveWorkspace, aiTool: targetTool)
            wsClient.requestAIAgentList(projectName: aiActiveProject, workspaceName: aiActiveWorkspace, aiTool: targetTool)
            wsClient.requestAISlashCommands(projectName: aiActiveProject, workspaceName: aiActiveWorkspace, aiTool: targetTool)
        }

        aiCurrentSessionId = session.id
        aiChatStore.setCurrentSessionId(session.id)
        aiChatMessages = []
        aiIsStreaming = false
        aiMessageIndexByMessageId = [:]
        aiPartIndexByPartId = [:]

        wsClient.requestAISessionMessages(
            projectName: session.projectName,
            workspaceName: session.workspaceName,
            aiTool: targetTool,
            sessionId: session.id,
            limit: 200
        )
    }

    /// 删除会话
    func deleteAISession(_ session: AISessionInfo) {
        let targetTool = session.aiTool
        wsClient.requestAISessionDelete(
            projectName: session.projectName,
            workspaceName: session.workspaceName,
            aiTool: targetTool,
            sessionId: session.id
        )
        if var sessions = aiSessionsByTool[targetTool] {
            sessions.removeAll { $0.id == session.id }
            setAISessions(sessions, for: targetTool)
        }
        if aiCurrentSessionId == session.id && aiChatTool == targetTool {
            aiCurrentSessionId = nil
            aiChatStore.setCurrentSessionId(nil)
            aiChatMessages = []
            aiIsStreaming = false
            aiMessageIndexByMessageId = [:]
            aiPartIndexByPartId = [:]
        }
    }

    /// 发送消息；返回 true 表示已受理（包括本地命令）
    @discardableResult
    func sendAIMessage(text: String, imageAttachments: [ImageAttachment]) -> Bool {
        // 上一次停止尚未收敛时，不允许发新消息，避免事件串扰。
        if aiAbortPendingSessionId != nil {
            return false
        }
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return false }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !imageAttachments.isEmpty else { return false }

        let slashCommand = parseSlashCommand(from: text)
        let slashAction: String? = {
            guard let slashCommand else { return nil }
            return aiSlashCommands.first(where: {
                $0.name.caseInsensitiveCompare(slashCommand.name) == .orderedSame
            })?.action
        }()

        if let slashCommand {
            let resolvedAction = slashAction ?? (
                slashCommand.name.caseInsensitiveCompare("new") == .orderedSame ? "client" : "agent"
            )
            if resolvedAction == "client" {
                switch slashCommand.name.lowercased() {
                case "new":
                    createNewAISession()
                default:
                    aiChatMessages.append(
                        AIChatMessage(
                            role: .assistant,
                            parts: [AIChatPart(
                                id: UUID().uuidString,
                                kind: .text,
                                text: "暂不支持本地命令：/\(slashCommand.name)",
                                toolName: nil,
                                toolState: nil
                            )],
                            isStreaming: false
                        )
                    )
                }
                return true
            }
        }

        let fileRefs = extractFileRefs(from: text)
        let fileRefsParam: [String]? = fileRefs.isEmpty ? nil : fileRefs
        let imageParts: [[String: Any]]? = imageAttachments.isEmpty ? nil : imageAttachments.map { img in
            [
                "filename": img.filename,
                "mime": img.mime,
                "data": img.data
            ]
        }
        let model: [String: String]? = aiSelectedModel.map {
            ["provider_id": $0.providerID, "model_id": $0.modelID]
        }
        let agentName = aiSelectedAgent
        let aiTool = aiChatTool

        // 先渲染用户消息与 assistant 占位，确保发送后即时反馈
        aiChatMessages.append(
            AIChatMessage(
                role: .user,
                parts: [AIChatPart(id: UUID().uuidString, kind: .text, text: text, toolName: nil, toolState: nil)],
                isStreaming: false
            )
        )
        aiChatMessages.append(AIChatMessage(role: .assistant, parts: [], isStreaming: true))
        aiIsStreaming = true

        if let sessionId = aiCurrentSessionId {
            if let slash = slashCommand {
                wsClient.requestAIChatCommand(
                    projectName: aiActiveProject,
                    workspaceName: aiActiveWorkspace,
                    aiTool: aiTool,
                    sessionId: sessionId,
                    command: slash.name,
                    arguments: slash.arguments,
                    fileRefs: fileRefsParam,
                    imageParts: imageParts,
                    model: model,
                    agent: agentName
                )
            } else {
                wsClient.requestAIChatSend(
                    projectName: aiActiveProject,
                    workspaceName: aiActiveWorkspace,
                    aiTool: aiTool,
                    sessionId: sessionId,
                    message: text,
                    fileRefs: fileRefsParam,
                    imageParts: imageParts,
                    model: model,
                    agent: agentName
                )
            }
        } else {
            if let slash = slashCommand {
                aiPendingSendRequest = (
                    aiActiveProject,
                    aiActiveWorkspace,
                    aiTool,
                    .command(
                        command: slash.name,
                        arguments: slash.arguments,
                        imageParts: imageParts,
                        model: model,
                        agent: agentName,
                        fileRefs: fileRefsParam
                    )
                )
            } else {
                aiPendingSendRequest = (
                    aiActiveProject,
                    aiActiveWorkspace,
                    aiTool,
                    .message(
                        text: text,
                        imageParts: imageParts,
                        model: model,
                        agent: agentName,
                        fileRefs: fileRefsParam
                    )
                )
            }
            wsClient.requestAIChatStart(
                projectName: aiActiveProject,
                workspaceName: aiActiveWorkspace,
                aiTool: aiTool,
                title: String(text.prefix(50))
            )
        }

        return true
    }

    /// 停止当前会话流式输出
    func stopAIStreaming() {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty,
              let sessionId = aiCurrentSessionId else { return }
        aiAbortPendingSessionId = sessionId
        wsClient.requestAIChatAbort(
            projectName: aiActiveProject,
            workspaceName: aiActiveWorkspace,
            aiTool: aiChatTool,
            sessionId: sessionId
        )
        aiIsStreaming = false

        // 立即收敛本地 loading，避免等待服务端 done 期间界面残留
        for idx in aiChatMessages.indices.reversed() {
            guard aiChatMessages[idx].role == .assistant,
                  aiChatMessages[idx].isStreaming else { continue }
            aiChatMessages[idx].isStreaming = false
            if aiChatMessages[idx].parts.isEmpty {
                aiChatMessages.remove(at: idx)
            }
        }
    }

    func replyAIQuestion(requestId: String, sessionId: String, answers: [[String]]) {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return }
        wsClient.requestAIQuestionReply(
            projectName: aiActiveProject,
            workspaceName: aiActiveWorkspace,
            aiTool: aiChatTool,
            sessionId: sessionId,
            requestId: requestId,
            answers: answers
        )
    }

    func rejectAIQuestion(requestId: String, sessionId: String) {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return }
        wsClient.requestAIQuestionReject(
            projectName: aiActiveProject,
            workspaceName: aiActiveWorkspace,
            aiTool: aiChatTool,
            sessionId: sessionId,
            requestId: requestId
        )
    }

    /// 当前上下文的文件索引（用于 @ 自动补全）
    func aiCurrentFileItems() -> [String] {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return [] }
        let key = aiContextKey(project: aiActiveProject, workspace: aiActiveWorkspace)
        return aiFileIndexCache[key]?.items ?? []
    }

    /// 按需拉取文件索引；首次输入 @ 时调用
    func fetchAIFileIndexIfNeeded(force: Bool = false) {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return }
        let key = aiContextKey(project: aiActiveProject, workspace: aiActiveWorkspace)
        if !force, let cache = aiFileIndexCache[key], !cache.items.isEmpty, !cache.isExpired {
            return
        }
        var cache = aiFileIndexCache[key] ?? FileIndexCache.empty()
        cache.isLoading = true
        cache.error = nil
        aiFileIndexCache[key] = cache
        wsClient.requestFileIndex(project: aiActiveProject, workspace: aiActiveWorkspace)
    }

    /// 按关键词远端查询文件索引（用于引用弹窗搜索）
    func searchAIFileReferences(query: String) {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return }
        let key = aiContextKey(project: aiActiveProject, workspace: aiActiveWorkspace)
        var cache = aiFileIndexCache[key] ?? FileIndexCache.empty()
        cache.isLoading = true
        cache.error = nil
        aiFileIndexCache[key] = cache

        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        wsClient.requestFileIndex(
            project: aiActiveProject,
            workspace: aiActiveWorkspace,
            query: normalized.isEmpty ? nil : normalized
        )
    }

    private func reloadCurrentAISessionIfNeeded() {
        guard let sessionId = aiCurrentSessionId,
              !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return }
        // 兜底：避免"工具与 session_id 不匹配"时把请求发到错误后端（如 opencode + codex 线程 ID）。
        let currentToolSessions = aiSessionsByTool[aiChatTool] ?? []
        let existsInCurrentTool = currentToolSessions.contains { $0.id == sessionId }
        guard existsInCurrentTool else {
            aiCurrentSessionId = nil
            aiChatStore.setCurrentSessionId(nil)
            aiChatMessages = []
            aiIsStreaming = false
            aiMessageIndexByMessageId = [:]
            aiPartIndexByPartId = [:]
            return
        }
        wsClient.requestAISessionMessages(
            projectName: aiActiveProject,
            workspaceName: aiActiveWorkspace,
            aiTool: aiChatTool,
            sessionId: sessionId,
            limit: 200
        )
    }

    private func reloadAISessionDataAfterReconnect() {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return }

        // 重连后补拉各工具会话列表
        for tool in AIChatTool.allCases {
            wsClient.requestAISessionList(
                projectName: aiActiveProject,
                workspaceName: aiActiveWorkspace,
                aiTool: tool
            )
        }

        // 若有选中会话，重新拉取详情以恢复流式状态
        for tool in AIChatTool.allCases {
            let sessions = aiSessionsByTool[tool] ?? []
            guard let sessionId = (tool == aiChatTool ? aiCurrentSessionId : nil),
                  !sessionId.isEmpty,
                  sessions.contains(where: { $0.id == sessionId }) else { continue }
            wsClient.requestAISessionMessages(
                projectName: aiActiveProject,
                workspaceName: aiActiveWorkspace,
                aiTool: tool,
                sessionId: sessionId,
                limit: 200
            )
        }
    }

    private func aiContextKey(project: String, workspace: String) -> String {
        "\(project):\(workspace):\(aiChatTool.rawValue)"
    }

    private func saveCurrentAISnapshotIfNeeded() {
        guard !aiActiveProject.isEmpty, !aiActiveWorkspace.isEmpty else { return }
        let key = aiContextKey(project: aiActiveProject, workspace: aiActiveWorkspace)
        aiChatSnapshotCache[key] = AIChatSnapshot(
            currentSessionId: aiCurrentSessionId,
            messages: aiChatMessages,
            isStreaming: aiIsStreaming,
            sessions: aiSessions,
            messageIndexByMessageId: aiMessageIndexByMessageId,
            partIndexByPartId: aiPartIndexByPartId,
            pendingToolQuestions: [:],
            questionRequestToCallId: [:]
        )
    }

    private func restoreAISnapshot(project: String, workspace: String) {
        let key = aiContextKey(project: project, workspace: workspace)
        if let snapshot = aiChatSnapshotCache[key] {
            aiCurrentSessionId = snapshot.currentSessionId
            aiChatStore.setCurrentSessionId(snapshot.currentSessionId)
            aiChatMessages = snapshot.messages
            aiIsStreaming = false
            aiSessions = snapshot.sessions
            aiMessageIndexByMessageId = snapshot.messageIndexByMessageId
            aiPartIndexByPartId = snapshot.partIndexByPartId
            return
        }
        aiCurrentSessionId = nil
        aiChatStore.setCurrentSessionId(nil)
        aiChatMessages = []
        aiIsStreaming = false
        aiSessions = []
        aiMessageIndexByMessageId = [:]
        aiPartIndexByPartId = [:]
    }

    private func parseSlashCommand(from text: String) -> (name: String, arguments: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "/" || first == "／" else { return nil }
        let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        if let separator = body.firstIndex(where: { $0.isWhitespace }) {
            let name = String(body[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let arguments = String(body[separator...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (name, arguments)
        }
        return (body, "")
    }

    private func sendPendingAIRequest(
        _ kind: PendingAIRequestKind,
        sessionId: String,
        projectName: String,
        workspaceName: String,
        aiTool: AIChatTool
    ) {
        switch kind {
        case let .message(text, imageParts, model, agent, fileRefs):
            wsClient.requestAIChatSend(
                projectName: projectName,
                workspaceName: workspaceName,
                aiTool: aiTool,
                sessionId: sessionId,
                message: text,
                fileRefs: fileRefs,
                imageParts: imageParts,
                model: model,
                agent: agent
            )
        case let .command(command, arguments, imageParts, model, agent, fileRefs):
            wsClient.requestAIChatCommand(
                projectName: projectName,
                workspaceName: workspaceName,
                aiTool: aiTool,
                sessionId: sessionId,
                command: command,
                arguments: arguments,
                fileRefs: fileRefs,
                imageParts: imageParts,
                model: model,
                agent: agent
            )
        }
    }

    private func applyAgentDefaultModel(_ agent: AIAgentInfo?) {
        guard let agent,
              let providerID = agent.defaultProviderID,
              let modelID = agent.defaultModelID,
              !providerID.isEmpty, !modelID.isEmpty else { return }
        aiSelectedModel = AIModelSelection(providerID: providerID, modelID: modelID)
    }

    func setAISessions(_ sessions: [AISessionInfo], for tool: AIChatTool) {
        aiSessionsByTool[tool] = sessions
        if aiChatTool == tool {
            aiSessions = sessions
        } else {
            refreshMergedAISessions()
        }
    }

    private func refreshMergedAISessions() {
        aiMergedSessions = AIChatTool.allCases
            .flatMap { aiSessionsByTool[$0] ?? [] }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - 终端视图绑定

    /// 绑定 SwiftTerm 输出目标
    func attachTerminalSink(_ sink: MobileTerminalOutputSink) {
        terminalSink = sink
        // 先确保视图处于“当前 term_id 的干净状态”，再 flush 缓冲/scrollback。
        if currentTermId.isEmpty || lastRenderedTermId != currentTermId {
            sink.resetTerminal()
            lastRenderedTermId = currentTermId
        }
        flushPendingOutput()
    }

    /// 解绑 SwiftTerm 输出目标
    func detachTerminalSink(_ sink: MobileTerminalOutputSink? = nil) {
        if let sink, let current = terminalSink, current !== sink {
            return
        }
        terminalSink = nil
        isTerminalViewReady = false
        pendingOutputChunks.removeAll()
        lastRenderedTermId = ""
    }

    /// SwiftTerm 视图尺寸变化（首次拿到有效尺寸也会走这里）
    func terminalViewDidResize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }

        let becameReady = !isTerminalViewReady
        isTerminalViewReady = true
        terminalCols = cols
        terminalRows = rows

        if !currentTermId.isEmpty {
            wsClient.requestTermResize(termId: currentTermId, cols: cols, rows: rows)
        }

        if becameReady {
            fireTermCreate()
            flushPendingOutput()
        }
    }


    // MARK: - 终端

    /// 记录待创建的终端信息，实际创建延迟到终端视图 ready 后
    func createTerminalForWorkspace(project: String, workspace: String) {
        pendingTermProject = project
        pendingTermWorkspace = workspace
        pendingAttachTermId = ""
        pendingCustomCommand = ""
        pendingCustomCommandIcon = ""
        pendingCustomCommandName = ""
        if isTerminalViewReady {
            fireTermCreate()
        }
    }

    /// 创建终端并在就绪后自动执行命令
    func createTerminalWithCommand(
        project: String,
        workspace: String,
        command: String,
        icon: String? = nil,
        name: String? = nil
    ) {
        pendingCustomCommand = command
        pendingCustomCommandIcon = icon ?? ""
        pendingCustomCommandName = name ?? ""
        pendingTermProject = project
        pendingTermWorkspace = workspace
        pendingAttachTermId = ""
        if isTerminalViewReady {
            fireTermCreate()
        }
    }

    /// 关闭（终止）指定终端
    func closeTerminal(termId: String) {
        wsClient.requestTermClose(termId: termId)
    }

    /// 附着已有终端（重连场景）
    func attachTerminal(project: String, workspace: String, termId: String) {
        pendingTermProject = project
        pendingTermWorkspace = workspace
        pendingAttachTermId = termId
        pendingCustomCommand = ""
        pendingCustomCommandIcon = ""
        pendingCustomCommandName = ""
        if isTerminalViewReady {
            fireTermCreate()
        }
    }

    private func fireTermCreate() {
        guard isTerminalViewReady else { return }
        guard !pendingTermProject.isEmpty else { return }

        let project = pendingTermProject
        let workspace = pendingTermWorkspace
        let attachId = pendingAttachTermId
        pendingTermProject = ""
        pendingTermWorkspace = ""
        pendingAttachTermId = ""

        if !attachId.isEmpty {
            // 附着已有终端
            pendingCustomCommand = ""
            pendingCustomCommandIcon = ""
            pendingCustomCommandName = ""
            wsClient.requestTermAttach(termId: attachId)
        } else {
            // 创建新终端，携带展示信息供 Core 持久化
            let name: String? = pendingCustomCommandName.isEmpty ? nil : pendingCustomCommandName
            let icon: String? = pendingCustomCommandIcon.isEmpty ? nil : pendingCustomCommandIcon
            wsClient.requestTermCreate(
                project: project,
                workspace: workspace,
                cols: terminalCols,
                rows: terminalRows,
                name: name,
                icon: icon
            )
        }
    }

    private func switchToTerminal(termId: String) {
        let newId = termId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newId.isEmpty else { return }
        guard newId != currentTermId else { return }

        // 防止 SwiftUI 复用同一个 TerminalView 时，把新终端输出追加到旧缓冲。
        pendingOutputChunks.removeAll()
        termOutputUnackedBytes = 0
        currentTermId = newId
        lastRenderedTermId = ""
        if let sink = terminalSink {
            sink.resetTerminal()
            lastRenderedTermId = newId
        }
    }

    /// 发送特殊键序列到终端
    func sendSpecialKey(_ sequence: String) {
        guard !currentTermId.isEmpty else { return }
        wsClient.sendTerminalInput(sequence, termId: currentTermId)
    }

    /// 发送键盘输入到终端（字符串）
    func sendTerminalInput(_ data: String) {
        guard !currentTermId.isEmpty else { return }
        let transformed = consumeCtrlIfNeeded(for: data)
        wsClient.sendTerminalInput(transformed, termId: currentTermId)
    }

    /// 粘贴按钮：文本直接发送，图片上传到服务端转 JPG 写入 macOS 剪贴板
    func handlePaste() {
        let pb = UIPasteboard.general
        // 1. 文本优先
        if let text = pb.string, !text.isEmpty {
            sendSpecialKey(text)
            return
        }
        // 2. 图片：上传到服务端转 JPG 并写入 macOS 剪贴板
        if let image = pb.image, let pngData = image.pngData() {
            wsClient.sendClipboardImageUpload(imageData: [UInt8](pngData))
            return
        }
        // 3. 其他类型跳过
    }

    /// 发送键盘输入到终端（原始字节）
    func sendTerminalInputBytes(_ data: [UInt8]) {
        guard !currentTermId.isEmpty else { return }
        let transformed = consumeCtrlIfNeeded(for: data)
        wsClient.sendTerminalInput(transformed, termId: currentTermId)
    }

    /// 设置 Ctrl 锁定状态（由输入工具栏回调）
    func setCtrlArmed(_ armed: Bool) {
        ctrlArmedForNextInput = armed
        NotificationCenter.default.post(
            name: .mobileTerminalCtrlStateDidChange,
            object: nil,
            userInfo: ["armed": armed]
        )
    }

    /// 离开终端视图时清理
    func detachTerminal() {
        // 离开页面时仅取消输出订阅，避免后台持续转发导致卡顿/抖动/不必要的资源占用。
        // 注意：不要触发 term_close（那会直接 kill 远端 PTY）。
        if !currentTermId.isEmpty {
            wsClient.requestTermDetach(termId: currentTermId)
        }
        currentTermId = ""
        pendingTermProject = ""
        pendingTermWorkspace = ""
        pendingAttachTermId = ""
        pendingCustomCommand = ""
        pendingCustomCommandIcon = ""
        pendingCustomCommandName = ""
        isTerminalViewReady = false
        termOutputUnackedBytes = 0
        pendingOutputChunks.removeAll()
        terminalSink = nil
        lastRenderedTermId = ""
        setCtrlArmed(false)
    }

    // MARK: - WS 回调

    private func setupWSCallbacks() {
        wsClient.onConnectionStateChanged = { [weak self] connected in
            guard let self else { return }
            self.isConnected = connected
            if connected {
                self.reconnectState = .idle
                self.connectionMessage = "连接成功"
                self.errorMessage = ""
                self.refreshProjectTree()
                // 重连成功后重新附着终端输出订阅（后台期间订阅可能已丢失）
                self.reattachTerminalIfNeeded()
                // 重连后恢复 AI 会话数据（流式输出可能中断，需重新拉取）
                self.reloadAISessionDataAfterReconnect()
                // 恢复键盘焦点
                self.terminalSink?.focusTerminal()
            } else {
                self.connectionMessage = "连接断开"
                if !self.wsClient.isIntentionalDisconnect {
                    self.reconnectWithBackoff()
                }
            }
        }

        wsClient.onProjectsList = { [weak self] result in
            guard let self else { return }
            self.projects = result.items
            let names = Set(result.items.map(\.name))
            self.workspacesByProject = self.workspacesByProject.filter { names.contains($0.key) }
            for project in result.items {
                self.wsClient.requestListWorkspaces(project: project.name)
            }
        }

        wsClient.onWorkspacesList = { [weak self] result in
            guard let self else { return }
            self.workspacesByProject[result.project] = result.items
            if self.selectedProjectName == result.project || self.workspaces.isEmpty {
                self.workspaces = result.items
            }
        }

        wsClient.onGitStatusResult = { [weak self] result in
            guard let self else { return }
            let additions = result.items.reduce(0) { $0 + ( $1.additions ?? 0 ) }
            let deletions = result.items.reduce(0) { $0 + ( $1.deletions ?? 0 ) }
            let key = self.globalWorkspaceKey(project: result.project, workspace: result.workspace)
            self.workspaceGitSummary[key] = MobileWorkspaceGitSummary(
                additions: additions,
                deletions: deletions,
                defaultBranch: result.defaultBranch
            )
        }

        wsClient.onTermList = { [weak self] result in
            guard let self else { return }
            self.activeTerminals = result.items
            let liveIds = Set(result.items.map(\.termId))
            self.terminalPresentationById = self.terminalPresentationById.filter { liveIds.contains($0.key) }

            // 从服务端恢复展示信息（重连场景：本地无缓存但 Core 有记录）
            for term in result.items {
                if self.terminalPresentationById[term.termId] == nil,
                   let name = term.name, !name.isEmpty {
                    self.terminalPresentationById[term.termId] = MobileTerminalPresentation(
                        icon: term.icon ?? "terminal",
                        name: name,
                        sourceCommand: nil
                    )
                }
            }

            var activeWorkspaceKeys: Set<String> = []
            for term in result.items where term.isRunning {
                let key = self.globalWorkspaceKey(project: term.project, workspace: term.workspace)
                activeWorkspaceKeys.insert(key)
                if self.workspaceTerminalOpenTime[key] == nil {
                    self.workspaceTerminalOpenTime[key] = Date()
                }
            }
            self.workspaceTerminalOpenTime = self.workspaceTerminalOpenTime.filter { activeWorkspaceKeys.contains($0.key) }
        }

        wsClient.onTermCreated = { [weak self] result in
            guard let self else { return }
            self.switchToTerminal(termId: result.termId)
            let key = self.globalWorkspaceKey(project: result.project, workspace: result.workspace)
            if self.workspaceTerminalOpenTime[key] == nil {
                self.workspaceTerminalOpenTime[key] = Date()
            }

            let commandIcon = self.pendingCustomCommandIcon
            let commandName = self.pendingCustomCommandName
            if !commandIcon.isEmpty || !commandName.isEmpty {
                self.terminalPresentationById[result.termId] = MobileTerminalPresentation(
                    icon: commandIcon.isEmpty ? "terminal" : commandIcon,
                    name: commandName.isEmpty ? "终端" : commandName,
                    sourceCommand: self.pendingCustomCommand
                )
            }

            // 确保 PTY 尺寸与终端视图一致（兜底 resize）
            self.wsClient.requestTermResize(
                termId: result.termId,
                cols: self.terminalCols,
                rows: self.terminalRows
            )
            self.terminalSink?.focusTerminal()
            // 刷新终端列表
            self.wsClient.requestTermList()
            // 自定义命令：延迟发送，等 shell 初始化完成
            let cmd = self.pendingCustomCommand
            if !cmd.isEmpty {
                let termId = result.termId
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.wsClient.sendTerminalInput(cmd + "\n", termId: termId)
                }
            }
            self.pendingCustomCommand = ""
            self.pendingCustomCommandIcon = ""
            self.pendingCustomCommandName = ""
        }

        wsClient.onTermAttached = { [weak self] result in
            guard let self else { return }
            self.switchToTerminal(termId: result.termId)
            // 从服务端恢复展示信息
            if self.terminalPresentationById[result.termId] == nil,
               let name = result.name, !name.isEmpty {
                self.terminalPresentationById[result.termId] = MobileTerminalPresentation(
                    icon: result.icon ?? "terminal",
                    name: name,
                    sourceCommand: nil
                )
            }
            // 写入 scrollback 到 SwiftTerm
            if !result.scrollback.isEmpty {
                self.emitTerminalOutput(result.scrollback)
                // scrollback 回放后立即发送 ACK，避免大量 scrollback 数据触发背压
                if !result.termId.isEmpty {
                    self.wsClient.sendTermOutputAck(termId: result.termId, bytes: result.scrollback.count)
                    self.termOutputUnackedBytes = 0
                }
            }
            self.wsClient.requestTermResize(
                termId: result.termId,
                cols: self.terminalCols,
                rows: self.terminalRows
            )
            self.terminalSink?.focusTerminal()
        }

        wsClient.onTerminalOutput = { [weak self] termId, bytes in
            guard let self else { return }
            if let termId, self.currentTermId.isEmpty {
                self.switchToTerminal(termId: termId)
            }
            // 只接受当前查看终端的输出，其他终端的数据丢弃（scrollback 在服务端保留）
            guard let termId, termId == self.currentTermId else { return }
            self.emitTerminalOutput(bytes)
        }

        wsClient.onTerminalExit = { [weak self] _, _ in
            // 终端退出，可选择通知用户
            _ = self
        }

        wsClient.onTermClosed = { [weak self] termId in
            guard let self else { return }
            self.terminalPresentationById.removeValue(forKey: termId)
            if self.currentTermId == termId {
                self.currentTermId = ""
            }
            // 刷新终端列表
            self.wsClient.requestTermList()
        }

        wsClient.onGitAICommitResult = { [weak self] result in
            guard let self else { return }
            // 按 project:workspace 匹配本地任务
            let key = self.globalWorkspaceKey(project: result.project, workspace: result.workspace)
            let localTaskId = self.aiCommitPendingTaskIds.first.flatMap { taskId -> String? in
                // 验证 taskId 归属的 workspace key 匹配
                if let tasks = self.workspaceTasksByKey[key],
                   tasks.contains(where: { $0.id == taskId && $0.status.isActive }) {
                    return taskId
                }
                return nil
            } ?? self.aiCommitPendingTaskIds.first // 兜底：按顺序匹配

            if let taskId = localTaskId {
                self.aiCommitPendingTaskIds.removeAll { $0 == taskId }
                self.mutateTask(taskId) { task in
                    task.status = result.success ? .completed : .failed
                    task.message = result.message
                    task.completedAt = Date()
                }
            } else {
                // 远程任务：非本地发起，创建条目并直接标记完成
                let task = self.createTask(
                    project: result.project,
                    workspace: result.workspace,
                    type: .aiCommit,
                    title: "一键提交",
                    icon: "sparkles",
                    message: result.message
                )
                self.mutateTask(task.id) { t in
                    t.status = result.success ? .completed : .failed
                    t.completedAt = Date()
                }
            }
        }

        wsClient.onGitAIMergeResult = { [weak self] result in
            guard let self else { return }
            let resolvedTaskId =
                self.aiMergePendingTaskIdByProject.removeValue(forKey: result.project)
                ?? self.findLatestActiveTaskId(project: result.project, type: .aiMerge)
            if let taskId = resolvedTaskId {
                self.mutateTask(taskId) { task in
                    task.status = result.success ? .completed : .failed
                    task.message = result.message
                    task.completedAt = Date()
                }
            } else {
                // 远程任务：非本地发起，创建条目并直接标记完成
                let task = self.createTask(
                    project: result.project,
                    workspace: result.workspace,
                    type: .aiMerge,
                    title: "智能合并",
                    icon: "cpu",
                    message: result.message
                )
                self.mutateTask(task.id) { t in
                    t.status = result.success ? .completed : .failed
                    t.completedAt = Date()
                }
            }
        }

        wsClient.onGitMergeToDefaultResult = { [weak self] result in
            guard let self else { return }
            let resolvedTaskId =
                self.aiMergePendingTaskIdByProject.removeValue(forKey: result.project)
                ?? self.findLatestActiveTaskId(project: result.project, type: .aiMerge)
            guard let taskId = resolvedTaskId else { return }
            self.mutateTask(taskId) { task in
                let success = result.ok && result.state == .completed
                task.status = success ? .completed : .failed
                task.message = result.message ?? (success ? "完成" : "失败")
                task.completedAt = Date()
            }
        }

        wsClient.onProjectCommandStarted = { [weak self] project, workspace, commandId, taskId in
            guard let self else { return }
            let routeKey = self.projectCommandRoutingKey(project: project, workspace: workspace, commandId: commandId)
            let localTaskId: String?
            if let mapped = self.projectCommandTaskIdByRemoteTaskId[taskId] {
                localTaskId = mapped
            } else if var queue = self.projectCommandPendingTaskIdsByKey[routeKey], !queue.isEmpty {
                let first = queue.removeFirst()
                self.projectCommandPendingTaskIdsByKey[routeKey] = queue.isEmpty ? nil : queue
                self.projectCommandTaskIdByRemoteTaskId[taskId] = first
                localTaskId = first
            } else {
                localTaskId = nil
            }
            if let resolvedId = localTaskId {
                self.mutateTask(resolvedId) { task in
                    task.status = .running
                    task.startedAt = task.startedAt ?? Date()
                    task.message = "运行中..."
                    task.remoteTaskId = taskId
                }
            } else {
                // 远程任务：非本地发起，创建远程任务条目
                let commandName = self.resolveCommandName(project: project, commandId: commandId)
                let commandIcon = self.resolveCommandIcon(project: project, commandId: commandId)
                let task = self.createTask(
                    project: project,
                    workspace: workspace,
                    type: .projectCommand,
                    title: commandName,
                    icon: commandIcon,
                    message: "运行中..."
                )
                self.mutateTask(task.id) { t in
                    t.commandId = commandId
                    t.remoteTaskId = taskId
                }
                self.projectCommandTaskIdByRemoteTaskId[taskId] = task.id
            }
        }

        wsClient.onProjectCommandOutput = { [weak self] taskId, line in
            guard let self else { return }
            guard let localTaskId = self.projectCommandTaskIdByRemoteTaskId[taskId] else { return }
            self.mutateTask(localTaskId) { task in
                task.lastOutputLine = line
            }
        }

        wsClient.onProjectCommandCompleted = { [weak self] project, workspace, commandId, taskId, ok, message in
            guard let self else { return }
            let routeKey = self.projectCommandRoutingKey(project: project, workspace: workspace, commandId: commandId)
            let localTaskId = self.projectCommandTaskIdByRemoteTaskId.removeValue(forKey: taskId)
                ?? self.projectCommandPendingTaskIdsByKey[routeKey]?.first
            if let localTaskId,
               var queue = self.projectCommandPendingTaskIdsByKey[routeKey],
               queue.first == localTaskId {
                queue.removeFirst()
                self.projectCommandPendingTaskIdsByKey[routeKey] = queue.isEmpty ? nil : queue
            }
            guard let resolvedId = localTaskId else { return }
            self.mutateTask(resolvedId) { task in
                task.status = ok ? .completed : .failed
                task.message = message ?? (ok ? "完成" : "失败")
                task.completedAt = Date()
            }
        }

        wsClient.onError = { [weak self] message in
            guard let self else { return }
            self.errorMessage = message
            if !self.aiActiveProject.isEmpty, !self.aiActiveWorkspace.isEmpty {
                let key = self.aiContextKey(project: self.aiActiveProject, workspace: self.aiActiveWorkspace)
                if var cache = self.aiFileIndexCache[key], cache.isLoading {
                    cache.isLoading = false
                    cache.error = message
                    self.aiFileIndexCache[key] = cache
                }
            }
        }

        wsClient.onClipboardImageSet = { [weak self] ok, message in
            guard let self else { return }
            if ok {
                // 图片已写入 macOS 剪贴板，发送 Ctrl+V 让 TUI 应用读取
                self.sendSpecialKey("\u{16}")
            } else {
                self.errorMessage = message ?? "剪贴板图片写入失败"
            }
        }

        wsClient.onAITaskCancelled = { [weak self] result in
            guard let self else { return }
            // 按 project + workspace + operation_type 查找活跃任务并标记取消
            let key = self.globalWorkspaceKey(project: result.project, workspace: result.workspace)
            let taskType: MobileWorkspaceTaskType = result.operationType == "ai_merge" ? .aiMerge : .aiCommit
            if let tasks = self.workspaceTasksByKey[key],
               let task = tasks.first(where: { $0.type == taskType && $0.status.isActive }) {
                self.mutateTask(task.id) { t in
                    t.status = .cancelled
                    t.message = "已取消"
                    t.completedAt = Date()
                }
            }
        }

        wsClient.onClientSettingsResult = { [weak self] settings in
            guard let self else { return }
            self.customCommands = settings.customCommands
            self.workspaceShortcuts = settings.workspaceShortcuts
            self.commitAIAgent = settings.commitAIAgent
            self.mergeAIAgent = settings.mergeAIAgent
        }

        wsClient.onTasksSnapshot = { [weak self] entries in
            guard let self else { return }
            self.restoreTasksFromSnapshot(entries)
        }

        // AI Chat: 文件索引（@ 自动补全）
        wsClient.onFileIndexResult = { [weak self] result in
            guard let self else { return }
            let key = self.aiContextKey(project: result.project, workspace: result.workspace)
            self.aiFileIndexCache[key] = FileIndexCache(
                items: result.items,
                truncated: result.truncated,
                updatedAt: Date(),
                isLoading: false,
                error: nil
            )
        }

        // AI Chat（结构化 message/part 流）
        wsClient.onAISessionStarted = { [weak self] ev in
            guard let self else { return }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool else { return }

            self.aiCurrentSessionId = ev.sessionId
            self.aiChatStore.setCurrentSessionId(ev.sessionId)
            let updatedAt = ev.updatedAt == 0 ? Int64(Date().timeIntervalSince1970 * 1000) : ev.updatedAt
            let session = AISessionInfo(
                projectName: ev.projectName,
                workspaceName: ev.workspaceName,
                aiTool: ev.aiTool,
                id: ev.sessionId,
                title: ev.title,
                updatedAt: updatedAt
            )
            self.aiSessions.removeAll { $0.id == session.id }
            self.aiSessions.insert(session, at: 0)

            if let pending = self.aiPendingSendRequest {
                guard pending.projectName == ev.projectName,
                      pending.workspaceName == ev.workspaceName,
                      pending.aiTool == ev.aiTool else {
                    self.aiPendingSendRequest = nil
                    return
                }
                self.aiPendingSendRequest = nil
                self.sendPendingAIRequest(
                    pending.kind,
                    sessionId: ev.sessionId,
                    projectName: ev.projectName,
                    workspaceName: ev.workspaceName,
                    aiTool: ev.aiTool
                )
            }
        }

        wsClient.onAISessionList = { [weak self] ev in
            guard let self else { return }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName else { return }
            let sessions = ev.sessions.map {
                AISessionInfo(
                    projectName: $0.projectName,
                    workspaceName: $0.workspaceName,
                    aiTool: ev.aiTool,
                    id: $0.id,
                    title: $0.title,
                    updatedAt: $0.updatedAt
                )
            }
            self.setAISessions(sessions.sorted { $0.updatedAt > $1.updatedAt }, for: ev.aiTool)
        }

        wsClient.onAISessionMessages = { [weak self] ev in
            guard let self else { return }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool else { return }
            guard self.aiCurrentSessionId == ev.sessionId else { return }

            self.aiChatMessages = ev.messages.compactMap { m in
                let role: AIChatRole = (m.role == "assistant") ? .assistant : .user
                let parts: [AIChatPart] = m.parts.compactMap { p in
                    let kind = AIChatPartKind(rawValue: p.partType) ?? .text
                    return AIChatPart(
                        id: p.id,
                        kind: kind,
                        text: p.text,
                        toolName: p.toolName,
                        toolState: p.toolState,
                        toolCallId: p.toolCallId,
                        toolPartMetadata: p.toolPartMetadata
                    )
                }
                return AIChatMessage(messageId: m.id, role: role, parts: parts, isStreaming: false)
            }
            self.rebuildAIIndexes()
            self.aiIsStreaming = false
        }

        wsClient.onAIChatMessageUpdated = { [weak self] ev in
            guard let self else { return }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool else { return }
            guard self.aiCurrentSessionId == ev.sessionId else { return }
            if self.aiAbortPendingSessionId == ev.sessionId { return }

            if ev.role == "user" {
                // user echo 到达，绑定占位消息的真实 messageId
                self.aiBindUserPlaceholder(messageId: ev.messageId)
            } else {
                let msgIdx = self.aiEnsureAssistantMessage(messageId: ev.messageId)
                self.aiMarkOnlyStreamingAssistant(at: msgIdx)
                self.recomputeAIIsStreaming()
            }
        }

        wsClient.onAIChatPartUpdated = { [weak self] ev in
            guard let self else { return }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool else { return }
            guard self.aiCurrentSessionId == ev.sessionId else { return }
            if self.aiAbortPendingSessionId == ev.sessionId { return }

            // 若 messageId 已绑定到 user 占位消息，跳过 assistant 流式处理
            if let idx = self.aiMessageIndexByMessageId[ev.messageId],
               idx < self.aiChatMessages.count,
               self.aiChatMessages[idx].role == .user {
                return
            }

            let msgIdx = self.aiEnsureAssistantMessage(messageId: ev.messageId)
            self.aiUpsertPart(msgIdx: msgIdx, part: ev.part)
            self.aiMarkOnlyStreamingAssistant(at: msgIdx)
            self.recomputeAIIsStreaming()
        }

        wsClient.onAIChatPartDelta = { [weak self] ev in
            guard let self else { return }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool else { return }
            guard self.aiCurrentSessionId == ev.sessionId else { return }
            if self.aiAbortPendingSessionId == ev.sessionId { return }

            // 若 messageId 已绑定到 user 占位消息，跳过 assistant 流式处理
            if let idx = self.aiMessageIndexByMessageId[ev.messageId],
               idx < self.aiChatMessages.count,
               self.aiChatMessages[idx].role == .user {
                return
            }

            let msgIdx = self.aiEnsureAssistantMessage(messageId: ev.messageId)
            self.aiAppendDelta(
                msgIdx: msgIdx,
                partId: ev.partId,
                partType: ev.partType,
                field: ev.field,
                delta: ev.delta
            )
            self.aiMarkOnlyStreamingAssistant(at: msgIdx)
            self.recomputeAIIsStreaming()
        }

        wsClient.onAIChatDone = { [weak self] ev in
            guard let self else { return }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool else { return }
            guard self.aiCurrentSessionId == ev.sessionId else { return }
            if self.aiAbortPendingSessionId == ev.sessionId {
                self.aiAbortPendingSessionId = nil
            }
            self.aiIsStreaming = false
            self.aiClearAssistantStreaming()
            if let idx = self.aiChatMessages.lastIndex(where: {
                $0.role == .assistant && $0.messageId == nil && $0.parts.isEmpty
            }) {
                self.aiChatMessages.remove(at: idx)
            }
            self.recomputeAIIsStreaming()
        }

        wsClient.onAIChatError = { [weak self] ev in
            guard let self else { return }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool else { return }
            guard self.aiCurrentSessionId == ev.sessionId else { return }
            if self.aiAbortPendingSessionId == ev.sessionId {
                self.aiAbortPendingSessionId = nil
            }
            self.aiIsStreaming = false
            self.aiClearAssistantStreaming()
            if let idx = self.aiChatMessages.lastIndex(where: {
                $0.role == .assistant && $0.messageId == nil && $0.parts.isEmpty
            }) {
                self.aiChatMessages.remove(at: idx)
            }
            self.aiChatMessages.append(
                AIChatMessage(
                    role: .assistant,
                    parts: [AIChatPart(
                        id: UUID().uuidString,
                        kind: .text,
                        text: "错误：\(ev.error)",
                        toolName: nil,
                        toolState: nil
                    )],
                    isStreaming: false
                )
            )
            self.rebuildAIIndexes()
            self.recomputeAIIsStreaming()
        }

        wsClient.onAIProviderList = { [weak self] ev in
            guard let self else { return }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool else { return }
            self.aiProviders = ev.providers.map { p in
                AIProviderInfo(
                    id: p.id,
                    name: p.name,
                    models: p.models.map { m in
                        AIModelInfo(
                            id: m.id,
                            name: m.name,
                            providerID: m.providerID.isEmpty ? p.id : m.providerID,
                            supportsImageInput: m.supportsImageInput
                        )
                    }
                )
            }
            self.isAILoadingModels = false
        }

        wsClient.onAIAgentList = { [weak self] ev in
            guard let self else { return }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool else { return }
            self.aiAgents = ev.agents.map { a in
                AIAgentInfo(
                    name: a.name,
                    description: a.description,
                    mode: a.mode,
                    color: a.color,
                    defaultProviderID: a.defaultProviderID,
                    defaultModelID: a.defaultModelID
                )
            }
            self.isAILoadingAgents = false
            if self.aiSelectedAgent == nil {
                let first = self.aiAgents.first(where: { $0.mode == "primary" || $0.mode == "all" }) ?? self.aiAgents.first
                self.aiSelectedAgent = first?.name
                self.applyAgentDefaultModel(first)
            }
        }

        wsClient.onAISlashCommands = { [weak self] ev in
            guard let self else { return }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool else { return }
            self.aiSlashCommands = ev.commands.map {
                AISlashCommandInfo(name: $0.name, description: $0.description, action: $0.action)
            }
        }

        wsClient.onAIQuestionAsked = { [weak self] ev in
            guard let self else { return }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool,
                  self.aiChatStore.currentSessionId == ev.sessionId else { return }
            self.aiChatStore.upsertQuestionRequest(ev.request)
        }

        wsClient.onAIQuestionCleared = { [weak self] ev in
            guard let self else { return }
            guard self.aiActiveProject == ev.projectName,
                  self.aiActiveWorkspace == ev.workspaceName,
                  self.aiChatTool == ev.aiTool,
                  self.aiChatStore.currentSessionId == ev.sessionId else { return }
            self.aiChatStore.completeQuestionRequestLocally(requestId: ev.requestId)
        }
    }

    // MARK: - AI Chat 索引与流式状态

    /// 以“是否存在正在流式的 assistant 消息”为准计算 loading 状态
    private func recomputeAIIsStreaming() {
        aiIsStreaming = aiChatMessages.contains { msg in
            msg.role == .assistant && msg.isStreaming
        }
    }

    private func rebuildAIIndexes() {
        aiMessageIndexByMessageId = [:]
        aiPartIndexByPartId = [:]
        for (msgIdx, msg) in aiChatMessages.enumerated() {
            if let mid = msg.messageId {
                aiMessageIndexByMessageId[mid] = msgIdx
            }
            for (partIdx, part) in msg.parts.enumerated() {
                aiPartIndexByPartId[part.id] = (msgIdx, partIdx)
            }
        }
    }

    /// 确保 assistant 消息存在；优先复用本地占位消息，避免流式时产生重复气泡
    @discardableResult
    private func aiEnsureAssistantMessage(messageId: String) -> Int {
        if let idx = aiMessageIndexByMessageId[messageId],
           idx < aiChatMessages.count,
           aiChatMessages[idx].messageId == messageId {
            return idx
        }
        aiMessageIndexByMessageId.removeValue(forKey: messageId)

        if let idx = aiChatMessages.lastIndex(where: {
            $0.role == .assistant && $0.messageId == nil && $0.isStreaming && $0.parts.isEmpty
        }) {
            aiChatMessages[idx].messageId = messageId
            aiMessageIndexByMessageId[messageId] = idx
            return idx
        }

        let newMessage = AIChatMessage(messageId: messageId, role: .assistant, parts: [], isStreaming: true)
        aiChatMessages.append(newMessage)
        let idx = aiChatMessages.count - 1
        aiMessageIndexByMessageId[messageId] = idx
        return idx
    }

    /// user echo 到达时，绑定占位用户消息的真实 messageId
    private func aiBindUserPlaceholder(messageId: String) {
        // 已在索引中则跳过
        if let idx = aiMessageIndexByMessageId[messageId],
           idx < aiChatMessages.count,
           aiChatMessages[idx].messageId == messageId {
            return
        }
        // 查找最后一个无 messageId 的 user 占位消息
        if let idx = aiChatMessages.lastIndex(where: { $0.role == .user && $0.messageId == nil }) {
            aiChatMessages[idx].messageId = messageId
            aiMessageIndexByMessageId[messageId] = idx
        }
    }

    private func aiUpsertPart(msgIdx: Int, part: AIProtocolPartInfo) {
        guard msgIdx >= 0, msgIdx < aiChatMessages.count else { return }
        let kind = AIChatPartKind(rawValue: part.partType) ?? .text

        if let existing = aiPartIndexByPartId[part.id],
           existing.msgIdx == msgIdx,
           existing.partIdx >= 0,
           existing.partIdx < aiChatMessages[msgIdx].parts.count {
            aiChatMessages[msgIdx].parts[existing.partIdx].text = part.text
            aiChatMessages[msgIdx].parts[existing.partIdx].toolName = part.toolName
            aiChatMessages[msgIdx].parts[existing.partIdx].toolState = part.toolState
            aiChatMessages[msgIdx].parts[existing.partIdx].toolCallId = part.toolCallId
            aiChatMessages[msgIdx].parts[existing.partIdx].toolPartMetadata = part.toolPartMetadata
            return
        }

        aiPartIndexByPartId.removeValue(forKey: part.id)
        let newPart = AIChatPart(
            id: part.id,
            kind: kind,
            text: part.text,
            toolName: part.toolName,
            toolState: part.toolState,
            toolCallId: part.toolCallId,
            toolPartMetadata: part.toolPartMetadata
        )
        aiChatMessages[msgIdx].parts.append(newPart)
        let newPartIdx = aiChatMessages[msgIdx].parts.count - 1
        aiPartIndexByPartId[part.id] = (msgIdx, newPartIdx)
    }

    private func aiAppendDelta(
        msgIdx: Int,
        partId: String,
        partType: String,
        field: String,
        delta: String
    ) {
        // 当前仅消费 text 增量，避免未知字段污染 UI
        guard field == "text" else { return }
        guard msgIdx >= 0, msgIdx < aiChatMessages.count else { return }

        if let existing = aiPartIndexByPartId[partId],
           existing.msgIdx == msgIdx,
           existing.partIdx >= 0,
           existing.partIdx < aiChatMessages[msgIdx].parts.count {
            let current = aiChatMessages[msgIdx].parts[existing.partIdx].text ?? ""
            aiChatMessages[msgIdx].parts[existing.partIdx].text = current + delta
            return
        }

        let kind = AIChatPartKind(rawValue: partType) ?? .text
        let newPart = AIChatPart(id: partId, kind: kind, text: delta, toolName: nil, toolState: nil)
        aiChatMessages[msgIdx].parts.append(newPart)
        let newPartIdx = aiChatMessages[msgIdx].parts.count - 1
        aiPartIndexByPartId[partId] = (msgIdx, newPartIdx)
    }

    /// 同一时刻只允许一个 assistant 气泡处于流式态
    private func aiMarkOnlyStreamingAssistant(at msgIdx: Int) {
        for idx in aiChatMessages.indices {
            guard aiChatMessages[idx].role == .assistant else { continue }
            aiChatMessages[idx].isStreaming = idx == msgIdx
        }
    }

    private func aiClearAssistantStreaming() {
        for idx in aiChatMessages.indices {
            guard aiChatMessages[idx].role == .assistant else { continue }
            aiChatMessages[idx].isStreaming = false
        }
    }

    // MARK: - 排序/任务内部工具

    /// 从服务端任务快照恢复本地任务状态（重连场景）
    private func restoreTasksFromSnapshot(_ entries: [TaskSnapshotEntry]) {
        // 收集当前本地已有的 remoteTaskId，避免重复创建
        let existingRemoteIds: Set<String> = Set(
            workspaceTasksByKey.values.flatMap { $0 }.compactMap { $0.remoteTaskId }
        )

        for entry in entries {
            // 跳过已存在的任务
            if existingRemoteIds.contains(entry.taskId) { continue }

            let taskType: MobileWorkspaceTaskType
            switch entry.taskType {
            case "ai_commit": taskType = .aiCommit
            case "ai_merge": taskType = .aiMerge
            default: taskType = .projectCommand
            }

            let status: MobileWorkspaceTaskStatus
            switch entry.status {
            case "running": status = .running
            case "completed": status = .completed
            case "failed": status = .failed
            case "cancelled": status = .cancelled
            default: status = .running
            }

            let startedDate = Date(timeIntervalSince1970: TimeInterval(entry.startedAt) / 1000.0)
            let completedDate = entry.completedAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }

            let task = MobileWorkspaceTask(
                id: UUID().uuidString,
                project: entry.project,
                workspace: entry.workspace,
                type: taskType,
                title: entry.title,
                icon: taskType == .projectCommand ? "terminal" : "sparkles",
                status: status,
                message: entry.message ?? "",
                createdAt: startedDate,
                startedAt: startedDate,
                completedAt: completedDate,
                commandId: entry.commandId,
                remoteTaskId: entry.taskId,
                lastOutputLine: nil
            )

            let key = globalWorkspaceKey(project: entry.project, workspace: entry.workspace)
            var tasks = workspaceTasksByKey[key] ?? []
            tasks.append(task)
            workspaceTasksByKey[key] = tasks

            // 维护 remoteTaskId 映射（running 状态的项目命令需要接收后续输出）
            if taskType == .projectCommand && status == .running {
                projectCommandTaskIdByRemoteTaskId[entry.taskId] = task.id
            }
        }
    }

    private func globalWorkspaceKey(project: String, workspace: String) -> String {
        "\(project):\(workspace)"
    }

    private func projectEarliestTerminalTime(_ project: ProjectInfo) -> Date? {
        var earliest: Date?
        for workspace in workspacesForProject(project.name) {
            let key = globalWorkspaceKey(project: project.name, workspace: workspace.name)
            if let time = workspaceTerminalOpenTime[key] {
                if earliest == nil || time < earliest! {
                    earliest = time
                }
            }
        }
        return earliest
    }

    private func projectMinShortcutKey(_ project: ProjectInfo) -> Int {
        var minKey = Int.max
        for workspace in workspacesForProject(project.name) {
            let wsKey = workspace.name == "default"
                ? "\(project.name)/(default)"
                : "\(project.name)/\(workspace.name)"
            if let shortcut = getWorkspaceShortcutKey(workspaceKey: wsKey),
               let num = Int(shortcut) {
                let sortValue = num == 0 ? 10 : num
                minKey = min(minKey, sortValue)
            }
        }
        return minKey
    }

    @discardableResult
    private func createTask(
        project: String,
        workspace: String,
        type: MobileWorkspaceTaskType,
        title: String,
        icon: String,
        message: String
    ) -> MobileWorkspaceTask {
        let task = MobileWorkspaceTask(
            id: UUID().uuidString,
            project: project,
            workspace: workspace,
            type: type,
            title: title,
            icon: icon,
            status: .running,
            message: message,
            createdAt: Date(),
            startedAt: Date(),
            completedAt: nil,
            commandId: nil,
            remoteTaskId: nil,
            lastOutputLine: nil
        )
        let key = globalWorkspaceKey(project: project, workspace: workspace)
        var tasks = workspaceTasksByKey[key] ?? []
        tasks.append(task)
        workspaceTasksByKey[key] = tasks
        return task
    }

    private func mutateTask(_ taskId: String, mutate: (inout MobileWorkspaceTask) -> Void) {
        for (key, var tasks) in workspaceTasksByKey {
            if let index = tasks.firstIndex(where: { $0.id == taskId }) {
                mutate(&tasks[index])
                workspaceTasksByKey[key] = tasks
                return
            }
        }
    }

    private func findLatestActiveTaskId(project: String, type: MobileWorkspaceTaskType) -> String? {
        workspaceTasksByKey.values
            .flatMap { $0 }
            .filter { $0.project == project && $0.type == type && $0.status.isActive }
            .sorted { $0.createdAt > $1.createdAt }
            .first?
            .id
    }

    private func projectCommandRoutingKey(project: String, workspace: String, commandId: String) -> String {
        "\(project)|\(workspace)|\(commandId)"
    }

    /// 从项目配置中查找命令名称
    private func resolveCommandName(project: String, commandId: String) -> String {
        projects.first(where: { $0.name == project })?
            .commands.first(where: { $0.id == commandId })?
            .name ?? commandId
    }

    /// 从项目配置中查找命令图标
    private func resolveCommandIcon(project: String, commandId: String) -> String {
        projects.first(where: { $0.name == project })?
            .commands.first(where: { $0.id == commandId })?
            .icon ?? "terminal"
    }

    // MARK: - 输出缓冲

    private func emitTerminalOutput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }

        // 流控 ACK：累计字节数，超过阈值时通知 Core 释放背压
        termOutputUnackedBytes += bytes.count
        if termOutputUnackedBytes >= termOutputAckThreshold, !currentTermId.isEmpty {
            wsClient.sendTermOutputAck(termId: currentTermId, bytes: termOutputUnackedBytes)
            termOutputUnackedBytes = 0
        }

        if let sink = terminalSink {
            sink.writeOutput(bytes)
            return
        }

        // 终端视图尚未就绪：缓冲到本地，等 ready 后 flush
        pendingOutputChunks.append(bytes)
        if pendingOutputChunks.count > pendingOutputChunkLimit {
            pendingOutputChunks.removeFirst(pendingOutputChunks.count - pendingOutputChunkLimit)
        }
    }

    private func flushPendingOutput() {
        guard let sink = terminalSink else { return }
        guard !pendingOutputChunks.isEmpty else { return }

        let chunks = pendingOutputChunks
        pendingOutputChunks.removeAll()
        for chunk in chunks {
            sink.writeOutput(chunk)
        }
    }

    // MARK: - HTTP 配对

    private func exchangePairCode(
        host: String,
        port: Int,
        pairCode: String,
        deviceName: String,
        secure: Bool = false
    ) async throws -> PairExchangeHTTPResponse {
        let scheme = secure ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(host):\(port)/pair/exchange") else {
            throw NSError(domain: "TidyFlowiOS", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "配对服务地址无效"
            ])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try JSONEncoder().encode(
            PairExchangeHTTPBody(pairCode: pairCode, deviceName: deviceName)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "TidyFlowiOS", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "服务端响应异常"
            ])
        }

        if (200..<300).contains(httpResponse.statusCode) {
            return try JSONDecoder().decode(PairExchangeHTTPResponse.self, from: data)
        }

        if let serverError = try? JSONDecoder().decode(PairErrorHTTPResponse.self, from: data) {
            throw NSError(domain: "TidyFlowiOS", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "\(serverError.error): \(serverError.message)"
            ])
        }

        throw NSError(domain: "TidyFlowiOS", code: httpResponse.statusCode, userInfo: [
            NSLocalizedDescriptionKey: "配对失败 (HTTP \(httpResponse.statusCode))"
        ])
    }

    private func consumeCtrlIfNeeded(for data: String) -> String {
        guard ctrlArmedForNextInput else { return data }
        disarmCtrlIfNeeded()

        if let mapped = mapCtrlSequence(from: data) {
            return mapped
        }
        return data
    }

    private func consumeCtrlIfNeeded(for data: [UInt8]) -> [UInt8] {
        guard ctrlArmedForNextInput else { return data }
        disarmCtrlIfNeeded()

        guard let text = String(bytes: data, encoding: .utf8) else {
            return data
        }
        guard let mapped = mapCtrlSequence(from: text) else {
            return data
        }
        return Array(mapped.utf8)
    }

    private func disarmCtrlIfNeeded() {
        ctrlArmedForNextInput = false
        NotificationCenter.default.post(
            name: .mobileTerminalCtrlStateDidChange,
            object: nil,
            userInfo: ["armed": false]
        )
    }

    private func mapCtrlSequence(from data: String) -> String? {
        guard data.unicodeScalars.count == 1, let scalar = data.unicodeScalars.first else {
            return nil
        }

        let value = scalar.value

        // Ctrl + A-Z / a-z
        if (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) {
            guard let ctrlScalar = UnicodeScalar(value & 0x1F) else { return nil }
            return String(ctrlScalar)
        }

        // 常见 Ctrl + 符号/数字映射
        switch value {
        case 0x20, 0x32, 0x40: // Space, 2, @
            return "\u{00}"
        case 0x33, 0x5B: // 3, [
            return "\u{1b}"
        case 0x34, 0x5C: // 4, \\
            return "\u{1c}"
        case 0x35, 0x5D: // 5, ]
            return "\u{1d}"
        case 0x36, 0x5E: // 6, ^
            return "\u{1e}"
        case 0x37, 0x2F, 0x3F, 0x5F: // 7, /, ?, _
            return "\u{1f}"
        default:
            return nil
        }
    }
}
