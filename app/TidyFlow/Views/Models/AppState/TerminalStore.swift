import Foundation
import Combine

/// 终端领域状态管理
/// 从 AppState 提取，减少终端状态变化对全局视图的影响
class TerminalStore: ObservableObject {
    /// 全局终端连接状态（用于状态栏显示）
    @Published var terminalState: TerminalState = .idle

    /// Tab → SessionId 映射（终端会话追踪）
    @Published var terminalSessionByTabId: [UUID: String] = [:]

    /// 断连后标记的过时终端 tab 集合
    @Published var staleTerminalTabs: Set<UUID> = []

    /// 工作空间首次打开终端的时间（用于自动快捷键排序，不持久化）
    /// key: globalWorkspaceKey (如 "projectName:workspaceName")
    @Published var workspaceTerminalOpenTime: [String: Date] = [:]

    /// 正在 spawn 中的 tab 集合（跳过 handleTabSwitch）
    var pendingSpawnTabs: Set<UUID> = []

    // MARK: - 回调

    /// 终端关闭回调
    var onTerminalKill: ((String, String) -> Void)?
    /// 终端创建回调：(tabId, project, workspace)
    var onTerminalSpawn: ((String, String, String) -> Void)?
    /// 终端附着回调：(tabId, sessionId)
    var onTerminalAttach: ((String, String) -> Void)?

    // MARK: - 查询方法

    /// 获取指定 tab 的终端 session ID
    func getTerminalSessionId(for tabId: UUID) -> String? {
        terminalSessionByTabId[tabId]
    }

    /// 检查终端 tab 是否需要重新 spawn
    func terminalNeedsRespawn(_ tabId: UUID) -> Bool {
        staleTerminalTabs.contains(tabId) || terminalSessionByTabId[tabId] == nil
    }

    /// 请求终端（更新状态为 connecting）
    func requestTerminal() {
        terminalState = .connecting
    }

    /// 终端连接成功后清除错误状态
    func handleTerminalConnected() {
        if case .error = terminalState {
            terminalState = .idle
        }
    }

    /// 终端错误
    func handleTerminalError(message: String) {
        terminalState = .error(message: message)
        TFLog.app.error("Terminal error: \(message, privacy: .public)")
    }

    /// 断连时标记所有终端会话为 stale
    func markAllTerminalSessionsStale() {
        for tabId in terminalSessionByTabId.keys {
            staleTerminalTabs.insert(tabId)
        }
        terminalSessionByTabId.removeAll()
        terminalState = .idle
    }

    /// 终端关闭事件处理（清除 session 映射）
    func handleTerminalClosed(tabId: UUID) {
        terminalSessionByTabId.removeValue(forKey: tabId)
    }

    /// 终端 ready 事件处理（建立 session 映射）
    func handleTerminalReady(tabId: UUID, sessionId: String, globalKey: String) {
        // 记录首次打开时间
        if workspaceTerminalOpenTime[globalKey] == nil {
            workspaceTerminalOpenTime[globalKey] = Date()
        }
        // 更新 session 映射
        terminalSessionByTabId[tabId] = sessionId
        staleTerminalTabs.remove(tabId)
        pendingSpawnTabs.remove(tabId)
        // 更新全局状态
        terminalState = .ready(sessionId: sessionId)
    }
}
