import Foundation
import Combine

/// macOS 终端展示辅助状态管理
///
/// 仅保留 macOS 专属的 Tab→SessionId 映射；
/// 壳层选择、请求相位、stale 标记与工作区 open time
/// 由共享终端壳层驱动（SharedTerminalShellState）和 TerminalSessionStore 负责。
///
/// ── 职责边界 ──
/// 终端标签 AI 状态统一由 CoordinatorStateCache + TerminalSessionSemantics 提供，
/// 本类不再持有 tab 级 AI 状态字典或防抖逻辑。
class TerminalStore: ObservableObject {

    /// Tab → SessionId 映射（macOS 终端 tab UI 专用）
    @Published var terminalSessionByTabId: [UUID: String] = [:]

    /// 正在 spawn 中的 tab 集合（跳过 handleTabSwitch，等待 term_created 绑定）
    var pendingSpawnTabs: Set<UUID> = []

    // MARK: - Tab → Session 查询

    /// 获取指定 tab 的终端 session ID
    func getTerminalSessionId(for tabId: UUID) -> String? {
        terminalSessionByTabId[tabId]
    }
}
