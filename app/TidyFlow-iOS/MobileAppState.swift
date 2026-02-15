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
    /// 用户是否处于"向上滚动查看 scrollback"的状态；此时暂停把新输出直接喂给渲染，避免被 TUI 刷新抢回底部造成抖动
    private var isScrollbackLocked: Bool = false
    /// 滚动锁定期间因缓冲溢出退化为 detach 模式
    private var isDetachedDueToOverflow: Bool = false
    /// 滚动锁定期间本地缓冲的字节数
    private var scrollLockBufferedBytes: Int = 0
    /// 滚动锁定本地缓冲上限（512KB），超过后退化为 detach 模式
    private let scrollLockBufferLimit = 512 * 1024

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
    /// 项目命令 started/completed 路由（project|workspace|commandId -> taskId 队列）
    private var projectCommandPendingTaskIdsByKey: [String: [String]] = [:]
    /// 项目命令 remote task_id -> 本地 taskId
    private var projectCommandTaskIdByRemoteTaskId: [String: String] = [:]
    /// 当前详情页选中的项目名（兼容旧接口）
    private var selectedProjectName: String = ""

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

    /// 刷新项目树（项目、工作空间、终端、设置）
    func refreshProjectTree() {
        wsClient.requestListProjects()
        wsClient.requestTermList()
        wsClient.requestGetClientSettings()
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

    /// SwiftTerm / UIScrollView 滚动状态更新：
    /// - 用户离开底部时：锁定 scrollback，继续接收输出但缓冲在本地（不再 detach）
    /// - 用户回到底部且不再交互时：解锁并 flush 本地缓冲（无需 resetTerminal + attach）
    /// - 缓冲溢出时退化为 detach 模式（安全阀）
    func terminalViewDidUpdateScrollState(isAtBottom: Bool, isUserInteracting: Bool) {
        // 用户离开底部：立即锁定（避免 TUI 刷新抢回底部）
        if !isAtBottom {
            if !isScrollbackLocked {
                isScrollbackLocked = true
                scrollLockBufferedBytes = 0
                isDetachedDueToOverflow = false
                pendingOutputChunks.removeAll()
            }
            return
        }

        // 回到底部但仍在拖拽/减速：不要立刻解锁，否则 flush+持续输出会和手势竞争造成抖动
        if isUserInteracting {
            return
        }

        // 回到底部且空闲：解锁并补齐积压输出
        if isScrollbackLocked {
            isScrollbackLocked = false

            if isDetachedDueToOverflow {
                // 溢出退化模式：走原有 resetTerminal + term_attach 路径
                isDetachedDueToOverflow = false
                scrollLockBufferedBytes = 0
                pendingOutputChunks.removeAll()
                terminalSink?.resetTerminal()
                if !currentTermId.isEmpty {
                    wsClient.requestTermAttach(termId: currentTermId)
                }
            } else {
                // 正常模式：直接 flush 本地缓冲到 SwiftTerm，无闪屏
                scrollLockBufferedBytes = 0
                flushPendingOutput()
            }
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
        isScrollbackLocked = false
        isDetachedDueToOverflow = false
        scrollLockBufferedBytes = 0
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
        isScrollbackLocked = false
        isDetachedDueToOverflow = false
        scrollLockBufferedBytes = 0
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
            self?.errorMessage = message
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
    }

    // MARK: - 排序/任务内部工具

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

        if let sink = terminalSink, !isScrollbackLocked {
            sink.writeOutput(bytes)
            return
        }

        // 滚动锁定期间：缓冲到本地
        pendingOutputChunks.append(bytes)
        scrollLockBufferedBytes += bytes.count
        if pendingOutputChunks.count > pendingOutputChunkLimit {
            pendingOutputChunks.removeFirst(pendingOutputChunks.count - pendingOutputChunkLimit)
        }

        // 安全阀：本地缓冲超过上限时退化为 detach 模式
        if scrollLockBufferedBytes > scrollLockBufferLimit, !isDetachedDueToOverflow {
            isDetachedDueToOverflow = true
            pendingOutputChunks.removeAll()
            scrollLockBufferedBytes = 0
            if !currentTermId.isEmpty {
                wsClient.requestTermDetach(termId: currentTermId)
            }
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
