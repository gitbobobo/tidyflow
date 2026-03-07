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
            toolTitle: nil,
            toolRawInput: nil,
            toolRawOutput: nil,
            toolLocations: nil,
            toolState: nil,
            toolPartMetadata: nil
        )
    }
}
