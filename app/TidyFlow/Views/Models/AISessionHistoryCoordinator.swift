import Foundation

// MARK: - AI 会话历史加载协调器
//
// 跨平台共享的 AI 会话历史加载协调器。
// 统一主聊天、evolution replay、sub-agent viewer、重连补拉和"加载更早消息"
// 的 subscription-first、首屏最近页请求和分页游标推进，
// 以 project/workspace/aiTool/sessionId 四元组为硬边界，
// 防止多项目/多工作区并行时旧会话内容串写。

struct AISessionHistoryCoordinator {

    // MARK: - 会话上下文（强隔离边界）

    /// 唯一标识一个 AI 会话的四元组。
    /// 历史加载必须携带完整上下文，不得仅用 sessionId 做宽松匹配。
    struct Context: Equatable {
        let project: String
        let workspace: String
        let aiTool: AIChatTool
        let sessionId: String
    }

    // MARK: - 订阅优先 + 首屏加载

    /// Subscription-first 模式：先注册订阅，再请求最近 N 条历史消息。
    /// 适用于主聊天首次绑定、evolution replay 载入、sub-agent viewer 打开
    /// 以及重连后补拉等所有需要"重新建立会话订阅"的场景。
    static func subscribeAndLoadRecent(
        context: Context,
        wsClient: WSClient,
        store: AIChatStore,
        pageSize: Int = AISessionSemantics.defaultMessagesPageSize
    ) {
        store.addSubscription(context.sessionId)
        store.setRecentHistoryLoading(true)
        wsClient.requestAISessionSubscribe(
            project: context.project,
            workspace: context.workspace,
            aiTool: context.aiTool.rawValue,
            sessionId: context.sessionId
        )
        wsClient.requestAISessionMessages(
            projectName: context.project,
            workspaceName: context.workspace,
            aiTool: context.aiTool,
            sessionId: context.sessionId,
            limit: pageSize
        )
    }

    // MARK: - 历史分页加载

    /// 向前翻页加载更早的历史消息，使用 store 中的 nextBeforeMessageId 游标推进。
    /// 若 hasMore 为 false 或游标为空则静默返回；调用前无需额外 guard。
    static func loadOlderPage(
        context: Context,
        wsClient: WSClient,
        store: AIChatStore,
        pageSize: Int = AISessionSemantics.defaultMessagesPageSize
    ) {
        guard store.historyHasMore else { return }
        guard let beforeMessageId = store.historyNextBeforeMessageId,
              !beforeMessageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store.updateHistoryPagination(hasMore: false, nextBeforeMessageId: nil)
            return
        }
        store.setHistoryLoading(true)
        wsClient.requestAISessionMessages(
            projectName: context.project,
            workspaceName: context.workspace,
            aiTool: context.aiTool,
            sessionId: context.sessionId,
            limit: pageSize,
            beforeMessageId: beforeMessageId
        )
    }
}
