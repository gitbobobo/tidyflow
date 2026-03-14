import Foundation
import Combine

/// macOS 终端展示辅助状态管理
///
/// 仅保留 macOS 专属的 AI 状态防抖和 Tab→SessionId 映射；
/// 壳层选择、请求相位、stale 标记与工作区 open time
/// 由共享终端壳层驱动（SharedTerminalShellState）和 TerminalSessionStore 负责。
class TerminalStore: ObservableObject {

    /// Tab → SessionId 映射（macOS 终端 tab UI 专用）
    @Published var terminalSessionByTabId: [UUID: String] = [:]

    /// 正在 spawn 中的 tab 集合（跳过 handleTabSwitch，等待 term_created 绑定）
    var pendingSpawnTabs: Set<UUID> = []

    /// 每个终端 tab 的 AI 执行状态（六态），用于标签栏状态指示器
    @Published var terminalAIStatusByTabId: [UUID: TerminalAIStatus] = [:]

    /// 过渡态（running/awaitingInput）的防抖工作项，避免高频状态变化造成标签栏闪烁
    private var statusDebounceWorkItemByTabId: [UUID: DispatchWorkItem] = [:]

    // MARK: - Tab → Session 查询

    /// 获取指定 tab 的终端 session ID
    func getTerminalSessionId(for tabId: UUID) -> String? {
        terminalSessionByTabId[tabId]
    }

    // MARK: - AI 执行状态

    /// 更新指定终端 tab 的 AI 状态。
    /// - 终态（success/failure/cancelled/idle）立即生效，并取消任何挂起的防抖任务。
    /// - 过渡态（running/awaitingInput）经 150ms 防抖后生效，避免高频刷新造成标签栏闪烁。
    func updateTerminalAIStatus(tabId: UUID, status: TerminalAIStatus) {
        switch status {
        case .success, .failure, .cancelled, .idle:
            // 终态立即生效
            statusDebounceWorkItemByTabId[tabId]?.cancel()
            statusDebounceWorkItemByTabId.removeValue(forKey: tabId)
            terminalAIStatusByTabId[tabId] = status
        case .running, .awaitingInput:
            // 过渡态防抖 150ms
            statusDebounceWorkItemByTabId[tabId]?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.terminalAIStatusByTabId[tabId] = status
            }
            statusDebounceWorkItemByTabId[tabId] = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
        }
    }

    /// 清除指定 tab 的 AI 状态（tab 关闭时调用）
    func clearTerminalAIStatus(for tabId: UUID) {
        statusDebounceWorkItemByTabId[tabId]?.cancel()
        statusDebounceWorkItemByTabId.removeValue(forKey: tabId)
        terminalAIStatusByTabId.removeValue(forKey: tabId)
    }
}
