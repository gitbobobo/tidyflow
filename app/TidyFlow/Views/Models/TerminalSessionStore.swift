import Foundation
import Combine

// MARK: - 共享终端会话存储
//
// 统一管理按 project/workspace/termId 隔离的活跃终端会话数据，
// 包括展示信息、置顶状态、工作区首次 open time、attach/detach 请求时间和输出 ACK 计数。
// macOS（AppState+EditorTerminal）与 iOS（MobileAppState）的终端生命周期均通过此存储驱动，
// 保证多项目、多工作区并行下不会串用 termId 或错误复用展示信息。

final class TerminalSessionStore: ObservableObject {

    // MARK: - 展示信息（按 termId 索引）

    /// 终端展示信息缓存（key: termId）
    /// 包含图标、名称、源命令和置顶状态
    @Published private(set) var displayInfoById: [String: TerminalDisplayInfo] = [:]

    // MARK: - 置顶状态

    /// 置顶的 termId 集合（按用户操作更新）
    @Published private(set) var pinnedIds: Set<String> = []

    // MARK: - 工作区首次打开终端时间

    /// 工作区首次打开终端的时间（key: "project:workspace"）
    /// 用于工作区终端活跃排序（如快捷键自动路由）
    @Published var workspaceOpenTime: [String: Date] = [:]

    // MARK: - Attach/Detach 请求时间（perf 追踪）

    /// Attach 请求时间（key: termId）
    var attachRequestedAt: [String: Date] = [:]

    /// Detach 请求时间（key: termId）
    var detachRequestedAt: [String: Date] = [:]

    // MARK: - 输出 ACK 计数

    /// 每个终端未确认的输出字节数（key: termId）
    var unackedBytesByTermId: [String: Int] = [:]

    // MARK: - 展示信息管理

    /// 设置终端展示信息（由 term_created、term_attached、term_list 恢复路径调用）
    func setDisplayInfo(_ info: TerminalDisplayInfo) {
        var updated = info
        updated.isPinned = pinnedIds.contains(info.termId)
        displayInfoById[info.termId] = updated
    }

    /// 获取展示信息
    func displayInfo(for termId: String) -> TerminalDisplayInfo? {
        displayInfoById[termId]
    }

    /// 仅在没有缓存时从 TerminalDisplayInfo 恢复（重连场景兜底）
    func restoreDisplayInfoIfAbsent(_ info: TerminalDisplayInfo) {
        guard displayInfoById[info.termId] == nil else { return }
        setDisplayInfo(info)
    }

    // MARK: - 置顶管理

    /// 切换指定 termId 的置顶状态
    func togglePinned(termId: String) {
        if pinnedIds.contains(termId) {
            pinnedIds.remove(termId)
        } else {
            pinnedIds.insert(termId)
        }
        if var info = displayInfoById[termId] {
            info.isPinned = pinnedIds.contains(termId)
            displayInfoById[termId] = info
        }
    }

    /// 查询置顶状态
    func isPinned(termId: String) -> Bool {
        pinnedIds.contains(termId)
    }

    // MARK: - 工作区 Open Time

    /// 记录工作区首次打开终端时间（只在首次调用时写入）
    func recordWorkspaceOpenTimeIfNeeded(key: String) {
        if workspaceOpenTime[key] == nil {
            workspaceOpenTime[key] = Date()
        }
    }

    // MARK: - 生命周期：term_list 恢复

    /// term_list 恢复：清理过期展示信息与置顶状态，补全服务端信息
    func reconcileTermList(
        items: [TerminalSessionInfo],
        makeKey: (String, String) -> String
    ) {
        let liveIds = Set(items.map(\.termId))
        // 清理过期条目
        displayInfoById = displayInfoById.filter { liveIds.contains($0.key) }
        pinnedIds = pinnedIds.intersection(liveIds)

        // 从服务端恢复展示信息（重连场景：本地无缓存但 Core 有记录）
        for term in items {
            if displayInfoById[term.termId] == nil,
               let info = TerminalDisplayInfo.restoreFrom(session: term, isPinned: pinnedIds.contains(term.termId)) {
                displayInfoById[term.termId] = info
            }
        }

        // 更新工作区 open time
        workspaceOpenTime = TerminalSessionSemantics.updatedWorkspaceOpenTime(
            existing: workspaceOpenTime,
            activeTerminals: items,
            makeKey: makeKey
        )
    }

    // MARK: - 生命周期：term_created

    /// term_created 处理：设置展示信息（来自自定义命令或服务端回显）
    func handleTermCreated(
        result: TermCreatedResult,
        pendingCommandIcon: String?,
        pendingCommandName: String?,
        pendingCommand: String?,
        makeKey: (String, String) -> String
    ) {
        let key = makeKey(result.project, result.workspace)
        recordWorkspaceOpenTimeIfNeeded(key: key)

        let icon = pendingCommandIcon ?? result.icon ?? "terminal"
        let name = pendingCommandName ?? result.name ?? "终端"
        let info = TerminalDisplayInfo(
            termId: result.termId,
            project: result.project,
            workspace: result.workspace,
            icon: icon.isEmpty ? "terminal" : icon,
            name: name.isEmpty ? "终端" : name,
            sourceCommand: pendingCommand,
            isPinned: pinnedIds.contains(result.termId)
        )
        displayInfoById[result.termId] = info
    }

    // MARK: - 生命周期：term_attached

    /// term_attached 处理：记录 RTT，恢复展示信息
    func handleTermAttached(result: TermAttachedResult) -> TimeInterval? {
        var rtt: TimeInterval? = nil
        if let requestedAt = attachRequestedAt.removeValue(forKey: result.termId) {
            rtt = Date().timeIntervalSince(requestedAt)
        }
        // 仅在没有缓存时从服务端恢复展示信息
        if let info = TerminalDisplayInfo.restoreFrom(attached: result, isPinned: pinnedIds.contains(result.termId)) {
            restoreDisplayInfoIfAbsent(info)
        }
        return rtt
    }

    // MARK: - 生命周期：term_closed

    /// term_closed 处理：清理所有与该 termId 相关的存储条目
    func handleTermClosed(termId: String) {
        displayInfoById.removeValue(forKey: termId)
        pinnedIds.remove(termId)
        unackedBytesByTermId.removeValue(forKey: termId)
        attachRequestedAt.removeValue(forKey: termId)
        detachRequestedAt.removeValue(forKey: termId)
    }

    // MARK: - 生命周期：断线 stale 标记

    /// 断线时清理 attach/detach/ACK 追踪状态（展示信息与置顶状态保留用于重连恢复）
    func handleDisconnect() {
        attachRequestedAt.removeAll()
        detachRequestedAt.removeAll()
        unackedBytesByTermId.removeAll()
    }

    // MARK: - ACK 追踪

    /// 重置指定终端的 ACK 计数（attach 时调用）
    func resetUnackedBytes(for termId: String) {
        unackedBytesByTermId[termId] = 0
    }

    /// 累加未确认字节数
    func addUnackedBytes(_ count: Int, for termId: String) {
        unackedBytesByTermId[termId] = (unackedBytesByTermId[termId] ?? 0) + count
    }

    /// 清零未确认字节数（ACK 发送后）
    func clearUnackedBytes(for termId: String) {
        unackedBytesByTermId[termId] = 0
    }

    /// 查询未确认字节数
    func unackedBytes(for termId: String) -> Int {
        unackedBytesByTermId[termId] ?? 0
    }

    // MARK: - Attach 请求时间

    /// 记录 attach 请求时间（用于 RTT 追踪）
    func recordAttachRequest(termId: String) {
        attachRequestedAt[termId] = Date()
    }

    /// 记录 detach 请求时间（用于 RTT 追踪）
    func recordDetachRequest(termId: String) {
        detachRequestedAt[termId] = Date()
    }
}
