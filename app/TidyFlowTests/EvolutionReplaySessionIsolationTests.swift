import XCTest
@testable import TidyFlow

// AC-002：新旧会话串流隔离测试
// 验证 clearAll() 完整清空订阅集合，以及旧会话流事件在新会话激活后被正确拦截。

final class EvolutionReplaySessionIsolationTests: XCTestCase {

    // MARK: - clearAll 清除 subscribedSessionIds

    /// clearAll() 之后 subscribedSessionIds 必须为空，
    /// 确保旧会话流事件不再通过 subscribedSessionIds.contains() 检查。
    func testClearAllRemovesAllSubscribedSessionIds() {
        let store = AIChatStore()

        // 模拟先订阅若干会话
        store.addSubscription("old-session-1")
        store.addSubscription("old-session-2")
        store.setCurrentSessionId("old-session-1")

        XCTAssertFalse(store.subscribedSessionIds.isEmpty, "清空前应有订阅")

        store.clearAll()

        XCTAssertTrue(store.subscribedSessionIds.isEmpty, "clearAll() 后 subscribedSessionIds 必须清空")
        XCTAssertNil(store.currentSessionId, "clearAll() 后 currentSessionId 必须为 nil")
        XCTAssertTrue(store.messages.isEmpty, "clearAll() 后消息列表必须清空")
    }

    /// clearAll() 后，旧会话的 sessionId 不再在 subscribedSessionIds 中，
    /// 模拟处理器的 guard 语句会正确拦截旧会话流事件。
    func testOldSessionEventsRejectedAfterClearAll() {
        let store = AIChatStore()
        let oldSessionId = "old-session-x"

        store.setCurrentSessionId(oldSessionId)
        XCTAssertTrue(store.subscribedSessionIds.contains(oldSessionId))

        // 用户切换到新会话，触发 clearAll
        store.clearAll()

        // 模拟旧会话流事件到达——处理器检查 subscribedSessionIds.contains(sessionId)
        XCTAssertFalse(
            store.subscribedSessionIds.contains(oldSessionId),
            "clearAll 后旧会话 ID 不应在订阅集合中，事件应被拦截"
        )
    }

    // MARK: - setCurrentSessionId 维护订阅集合

    /// 切换到新会话 ID 时，旧 ID 应从 subscribedSessionIds 移除，新 ID 加入。
    func testSetCurrentSessionIdUpdatesSubscriptionSet() {
        let store = AIChatStore()

        store.setCurrentSessionId("session-A")
        XCTAssertTrue(store.subscribedSessionIds.contains("session-A"))
        XCTAssertFalse(store.subscribedSessionIds.contains("session-B"))

        store.setCurrentSessionId("session-B")
        XCTAssertFalse(store.subscribedSessionIds.contains("session-A"), "切换后旧 session-A 应移出订阅")
        XCTAssertTrue(store.subscribedSessionIds.contains("session-B"), "新 session-B 应加入订阅")
    }

    /// 设置 nil 作为 currentSessionId 时，旧 ID 应移出订阅集合。
    func testSetCurrentSessionIdToNilRemovesOldSubscription() {
        let store = AIChatStore()

        store.setCurrentSessionId("session-C")
        XCTAssertTrue(store.subscribedSessionIds.contains("session-C"))

        store.setCurrentSessionId(nil)
        XCTAssertFalse(store.subscribedSessionIds.contains("session-C"), "设置 nil 后旧 ID 应移出订阅")
    }

    // MARK: - addSubscription / removeSubscription 手动管理

    func testManualAddRemoveSubscription() {
        let store = AIChatStore()

        store.addSubscription("s1")
        store.addSubscription("s2")
        XCTAssertTrue(store.subscribedSessionIds.contains("s1"))
        XCTAssertTrue(store.subscribedSessionIds.contains("s2"))

        store.removeSubscription("s1")
        XCTAssertFalse(store.subscribedSessionIds.contains("s1"), "removeSubscription 后 s1 应不再订阅")
        XCTAssertTrue(store.subscribedSessionIds.contains("s2"), "未移除的 s2 应保留")
    }

    // MARK: - 流事件仅作用于当前订阅 session

    /// 旧会话流的 partDelta 事件不应被追加到已切换新会话的消息列表。
    func testOldSessionStreamEventsDoNotPollutateNewSession() {
        let store = AIChatStore()
        let oldSessionId = "old-replay-sess"
        let newSessionId = "new-live-sess"

        // 1. 先建立旧会话并填充消息
        store.setCurrentSessionId(oldSessionId)
        store.applySessionCacheOps(
            [.messageUpdated(messageId: "m-old", role: "assistant"),
             .partUpdated(messageId: "m-old", part: makeTextPart(id: "p-old", text: "旧内容"))],
            isStreaming: false
        )
        XCTAssertEqual(store.messages.count, 1)

        // 2. 切换到新会话，清空旧状态
        store.clearAll()
        store.setCurrentSessionId(newSessionId)
        XCTAssertTrue(store.messages.isEmpty, "切换新会话后消息列表应为空")

        // 3. 旧会话有延迟事件到达：先检查 subscribedSessionIds 再决定是否处理
        let oldEventShouldBeAccepted = store.subscribedSessionIds.contains(oldSessionId)
        XCTAssertFalse(oldEventShouldBeAccepted, "旧会话 ID 不在订阅集合中，事件应被丢弃")

        // 4. 新会话的事件正常处理
        let newEventShouldBeAccepted = store.subscribedSessionIds.contains(newSessionId)
        XCTAssertTrue(newEventShouldBeAccepted, "新会话 ID 在订阅集合中，事件应被接受")
    }

    // MARK: - 私有辅助

    // MARK: - AISessionHistoryCoordinator.Context 隔离

    func testCoordinatorContextEqualityWithSameValues() {
        let ctx1 = AISessionHistoryCoordinator.Context(
            project: "project-a",
            workspace: "default",
            aiTool: .claude_code,
            sessionId: "session-123"
        )
        let ctx2 = AISessionHistoryCoordinator.Context(
            project: "project-a",
            workspace: "default",
            aiTool: .claude_code,
            sessionId: "session-123"
        )
        XCTAssertEqual(ctx1, ctx2, "相同四元组的 Context 应相等")
    }

    func testCoordinatorContextInequalityOnDifferentSession() {
        let ctx1 = AISessionHistoryCoordinator.Context(
            project: "project-a",
            workspace: "default",
            aiTool: .claude_code,
            sessionId: "session-123"
        )
        let ctx2 = AISessionHistoryCoordinator.Context(
            project: "project-a",
            workspace: "default",
            aiTool: .claude_code,
            sessionId: "session-456"
        )
        XCTAssertNotEqual(ctx1, ctx2, "不同 sessionId 的 Context 应不相等，防止跨会话事件混用")
    }

    func testCoordinatorContextInequalityOnDifferentProject() {
        let ctx1 = AISessionHistoryCoordinator.Context(
            project: "project-a",
            workspace: "default",
            aiTool: .claude_code,
            sessionId: "session-1"
        )
        let ctx2 = AISessionHistoryCoordinator.Context(
            project: "project-b",
            workspace: "default",
            aiTool: .claude_code,
            sessionId: "session-1"
        )
        XCTAssertNotEqual(ctx1, ctx2, "不同 project 的 Context 应不相等，防止跨项目历史合并")
    }

    func testCoordinatorContextInequalityOnDifferentAITool() {
        let ctx1 = AISessionHistoryCoordinator.Context(
            project: "p",
            workspace: "default",
            aiTool: .claude_code,
            sessionId: "s1"
        )
        let ctx2 = AISessionHistoryCoordinator.Context(
            project: "p",
            workspace: "default",
            aiTool: .codex,
            sessionId: "s1"
        )
        XCTAssertNotEqual(ctx1, ctx2, "不同 aiTool 的 Context 应不相等")
    }

    // MARK: - WI-005: 门禁生命周期与隔离护栏

    /// 验证 clearAll + setCurrentSessionId 不会让旧 cycle 的会话事件泄漏到新 cycle
    func testNewCycleDoesNotInheritOldCycleSubscriptions() {
        let store = AIChatStore()

        // 旧 cycle 的会话
        store.setCurrentSessionId("cycle-old-session")
        store.addSubscription("cycle-old-aux")
        XCTAssertEqual(store.subscribedSessionIds.count, 2)

        // 模拟新 cycle 开始：clearAll 重置状态
        store.clearAll()
        store.setCurrentSessionId("cycle-new-session")

        XCTAssertFalse(store.subscribedSessionIds.contains("cycle-old-session"),
                       "新 cycle 不应继承旧 cycle 的会话订阅")
        XCTAssertFalse(store.subscribedSessionIds.contains("cycle-old-aux"),
                       "新 cycle 不应继承旧 cycle 的辅助订阅")
        XCTAssertTrue(store.subscribedSessionIds.contains("cycle-new-session"),
                      "新 cycle 的当前会话应在订阅集合中")
        XCTAssertEqual(store.subscribedSessionIds.count, 1,
                       "新 cycle 应只有一个订阅会话")
    }

    /// 验证多次 clearAll 调用的幂等性
    func testMultipleClearAllCallsAreIdempotent() {
        let store = AIChatStore()
        store.setCurrentSessionId("session-x")
        store.applySessionCacheOps(
            [.messageUpdated(messageId: "m1", role: "user")],
            isStreaming: false
        )

        store.clearAll()
        store.clearAll()
        store.clearAll()

        XCTAssertTrue(store.subscribedSessionIds.isEmpty, "多次 clearAll 后订阅集合应为空")
        XCTAssertNil(store.currentSessionId, "多次 clearAll 后 currentSessionId 应为 nil")
        XCTAssertTrue(store.messages.isEmpty, "多次 clearAll 后消息列表应为空")
    }

    /// 验证跨项目的 Context 不会发生 hash 碰撞
    func testCoordinatorContextHashIsolationAcrossProjects() {
        let ctx1 = AISessionHistoryCoordinator.Context(
            project: "projectA",
            workspace: "default",
            aiTool: .claude_code,
            sessionId: "same-session"
        )
        let ctx2 = AISessionHistoryCoordinator.Context(
            project: "projectB",
            workspace: "default",
            aiTool: .claude_code,
            sessionId: "same-session"
        )
        // 使用 Set 测试 hash 隔离
        let set: Set<AISessionHistoryCoordinator.Context> = [ctx1, ctx2]
        XCTAssertEqual(set.count, 2, "不同项目的 Context 在 Set 中不应碰撞")
    }

    // MARK: - AI 聊天舞台生命周期与多工作区隔离

    /// 验证舞台 acceptsStreamEvent 在 idle 阶段拒绝所有事件。
    func testStageRejectsEventsInIdlePhase() {
        let lifecycle = AIChatStageLifecycle()
        XCTAssertEqual(lifecycle.state.phase, .idle)
        XCTAssertFalse(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws", aiTool: .opencode),
                       "idle 阶段应拒绝所有流式事件")
    }

    /// 验证舞台 acceptsStreamEvent 在 entering 阶段拒绝事件。
    func testStageRejectsEventsInEnteringPhase() {
        let lifecycle = AIChatStageLifecycle()
        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .opencode))
        XCTAssertEqual(lifecycle.state.phase, .entering)
        XCTAssertFalse(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws", aiTool: .opencode),
                       "entering 阶段应拒绝流式事件（尚未就绪）")
    }

    /// 验证舞台 acceptsStreamEvent 在 active 阶段只接受匹配上下文的事件。
    func testStageAcceptsMatchingEventsInActivePhase() {
        let lifecycle = AIChatStageLifecycle()
        lifecycle.apply(.enter(project: "proj-a", workspace: "ws-1", aiTool: .claude_code))
        lifecycle.apply(.ready)
        XCTAssertEqual(lifecycle.state.phase, .active)

        XCTAssertTrue(lifecycle.acceptsStreamEvent(project: "proj-a", workspace: "ws-1", aiTool: .claude_code))
        XCTAssertFalse(lifecycle.acceptsStreamEvent(project: "proj-b", workspace: "ws-1", aiTool: .claude_code),
                       "不同项目的事件应被拒绝")
        XCTAssertFalse(lifecycle.acceptsStreamEvent(project: "proj-a", workspace: "ws-2", aiTool: .claude_code),
                       "不同工作区的事件应被拒绝")
        XCTAssertFalse(lifecycle.acceptsStreamEvent(project: "proj-a", workspace: "ws-1", aiTool: .codex),
                       "不同工具的事件应被拒绝")
    }

    /// 验证舞台 resume/resumeCompleted 迁移路径正确。
    func testStageResumeLifecycle() {
        let lifecycle = AIChatStageLifecycle()
        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .opencode))
        lifecycle.apply(.ready)

        let resumeResult = lifecycle.apply(.resume(sessionId: "session-123"))
        XCTAssertNotEqual(resumeResult, .ignored)
        XCTAssertEqual(lifecycle.state.phase, .resuming)
        XCTAssertEqual(lifecycle.state.activeSessionId, "session-123")
        // resuming 阶段仍接受匹配上下文的事件
        XCTAssertTrue(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws", aiTool: .opencode))

        lifecycle.apply(.resumeCompleted)
        XCTAssertEqual(lifecycle.state.phase, .active)
    }

    /// 验证 forceReset 从任意阶段迁移到 idle。
    func testStageForceResetFromAnyPhase() {
        let lifecycle = AIChatStageLifecycle()

        // 从 entering
        lifecycle.apply(.enter(project: "p", workspace: "w", aiTool: .codex))
        lifecycle.apply(.forceReset)
        XCTAssertEqual(lifecycle.state.phase, .idle)

        // 从 active
        lifecycle.apply(.enter(project: "p", workspace: "w", aiTool: .codex))
        lifecycle.apply(.ready)
        lifecycle.apply(.forceReset)
        XCTAssertEqual(lifecycle.state.phase, .idle)

        // 从 resuming
        lifecycle.apply(.enter(project: "p", workspace: "w", aiTool: .codex))
        lifecycle.apply(.ready)
        lifecycle.apply(.resume(sessionId: "s"))
        lifecycle.apply(.forceReset)
        XCTAssertEqual(lifecycle.state.phase, .idle)
    }

    /// 验证舞台上下文键的多工作区隔离。
    func testStageContextKeyIsolation() {
        let lifecycle = AIChatStageLifecycle()
        lifecycle.apply(.enter(project: "proj-a", workspace: "ws-1", aiTool: .opencode))
        let key1 = lifecycle.state.contextKey

        lifecycle.apply(.close)
        lifecycle.apply(.enter(project: "proj-a", workspace: "ws-2", aiTool: .opencode))
        let key2 = lifecycle.state.contextKey

        lifecycle.apply(.close)
        lifecycle.apply(.enter(project: "proj-b", workspace: "ws-1", aiTool: .opencode))
        let key3 = lifecycle.state.contextKey

        XCTAssertNotEqual(key1, key2, "不同工作区的上下文键应不同")
        XCTAssertNotEqual(key1, key3, "不同项目的上下文键应不同")
        XCTAssertNotEqual(key2, key3, "不同项目+工作区组合的上下文键应不同")
    }

    // MARK: - AI 聊天舞台生命周期边界回归（多工作区 + 流式中断）

    /// 回归：多工作区切换 → forceReset → enter 新工作区后，旧工作区事件被拒绝。
    func testMultiWorkspaceSwitchIsolation() {
        let lifecycle = AIChatStageLifecycle()
        let store = AIChatStore()

        // 工作区 A 活跃
        lifecycle.apply(.enter(project: "proj", workspace: "ws-a", aiTool: .opencode))
        lifecycle.apply(.ready)
        store.setCurrentSessionId("session-a")
        XCTAssertTrue(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws-a", aiTool: .opencode))

        // 模拟平台层工作区切换：forceReset + clearAll
        lifecycle.apply(.forceReset)
        store.clearAll()

        // 工作区 B 活跃
        lifecycle.apply(.enter(project: "proj", workspace: "ws-b", aiTool: .opencode))
        lifecycle.apply(.ready)
        store.setCurrentSessionId("session-b")

        // 旧工作区 A 的事件应被拒绝（舞台 + 缓存双层验证）
        XCTAssertFalse(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws-a", aiTool: .opencode),
                       "旧工作区的事件应被舞台拒绝")
        XCTAssertFalse(store.subscribedSessionIds.contains("session-a"),
                       "旧工作区的会话 ID 不应在订阅集合中")
        // 新工作区 B 的事件应被接受
        XCTAssertTrue(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws-b", aiTool: .opencode))
        XCTAssertTrue(store.subscribedSessionIds.contains("session-b"))
    }

    /// 回归：流式中断后恢复 → 确认事件仍被正确路由。
    func testStreamInterruptionRecoveryWithSessionIsolation() {
        let lifecycle = AIChatStageLifecycle()
        let store = AIChatStore()

        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .claude_code))
        lifecycle.apply(.ready)
        store.setCurrentSessionId("sess-1")

        // 流式中断
        lifecycle.apply(.streamInterrupted(sessionId: "sess-1"))
        XCTAssertEqual(lifecycle.state.phase, .resuming)
        // resuming 阶段仍接受匹配上下文的事件
        XCTAssertTrue(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws", aiTool: .claude_code))
        XCTAssertTrue(store.subscribedSessionIds.contains("sess-1"),
                      "流式中断不应清空订阅集合")

        // 恢复完成
        lifecycle.apply(.resumeCompleted)
        XCTAssertEqual(lifecycle.state.phase, .active)

        // 切换到新会话后旧会话事件被拒绝
        store.clearAll()
        store.setCurrentSessionId("sess-2")
        XCTAssertFalse(store.subscribedSessionIds.contains("sess-1"),
                       "切换会话后旧 session ID 应被移出订阅")
    }

    /// 回归：forceReset 从 resuming 阶段恢复到 idle，不残留任何上下文。
    func testForceResetFromResumingClearsContext() {
        let lifecycle = AIChatStageLifecycle()

        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .codex))
        lifecycle.apply(.ready)
        lifecycle.apply(.streamInterrupted(sessionId: "sess-x"))
        XCTAssertEqual(lifecycle.state.phase, .resuming)

        lifecycle.apply(.forceReset)
        XCTAssertEqual(lifecycle.state.phase, .idle)
        XCTAssertEqual(lifecycle.state.project, "", "forceReset 后 project 应为空")
        XCTAssertEqual(lifecycle.state.workspace, "", "forceReset 后 workspace 应为空")
        XCTAssertNil(lifecycle.state.activeSessionId, "forceReset 后 activeSessionId 应为 nil")
        XCTAssertFalse(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws", aiTool: .codex),
                       "forceReset 后不应接受任何事件")
    }

    /// 回归：工具切换后旧工具的事件与订阅应被清理隔离。
    func testToolSwitchIsolation() {
        let lifecycle = AIChatStageLifecycle()
        let store = AIChatStore()

        // codex 工具活跃
        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .codex))
        lifecycle.apply(.ready)
        store.setCurrentSessionId("codex-session")
        XCTAssertTrue(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws", aiTool: .codex))

        // 切换到 claude_code（模拟 switchAIChatTool 的 clearAll + switchTool + ready）
        store.clearAll()
        lifecycle.apply(.switchTool(newTool: .claude_code))
        lifecycle.apply(.ready)
        store.setCurrentSessionId("claude-session")

        // 旧工具的事件应被拒绝
        XCTAssertFalse(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws", aiTool: .codex),
                       "旧工具的事件应被舞台拒绝")
        XCTAssertFalse(store.subscribedSessionIds.contains("codex-session"),
                       "旧工具的会话 ID 不应在订阅集合中")
        // 新工具的事件应被接受
        XCTAssertTrue(lifecycle.acceptsStreamEvent(project: "proj", workspace: "ws", aiTool: .claude_code))
        XCTAssertTrue(store.subscribedSessionIds.contains("claude-session"))
    }

    private func makeTextPart(id: String, text: String?) -> AIProtocolPartInfo {
        AIProtocolPartInfo(
            id: id,
            partType: "text",
            text: text,
            mime: nil,
            filename: nil,
            url: nil,
            synthetic: nil,
            ignored: nil,
            source: nil,
            toolName: nil,
            toolCallId: nil,
            toolKind: nil,
            toolView: nil
        )
    }
}
