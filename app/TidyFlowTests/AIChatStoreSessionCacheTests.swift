import XCTest
@testable import TidyFlow

final class AIChatStoreSessionCacheTests: XCTestCase {
    func testReplaceMessagesFromSessionCacheMarksLatestAssistantStreaming() {
        let store = AIChatStore()
        let messages = [
            AIProtocolMessageInfo(
                id: "m-user",
                role: "user",
                createdAt: nil,
                agent: nil,
                modelProviderID: nil,
                modelID: nil,
                parts: [makeTextPart(id: "p-user", text: "hi")]
            ),
            AIProtocolMessageInfo(
                id: "m-assistant",
                role: "assistant",
                createdAt: nil,
                agent: nil,
                modelProviderID: nil,
                modelID: nil,
                parts: [makeTextPart(id: "p-assistant", text: "hello")]
            ),
        ]

        store.replaceMessagesFromSessionCache(messages, isStreaming: true)

        XCTAssertEqual(store.messages.count, 2)
        XCTAssertFalse(store.messages[0].isStreaming)
        XCTAssertTrue(store.messages[1].isStreaming)
        XCTAssertTrue(store.isStreaming)
    }

    func testApplySessionCacheOpsBuildsTextFromDeltas() {
        let store = AIChatStore()
        let basePart = makeTextPart(id: "p1", text: nil)

        store.applySessionCacheOps(
            [
                .messageUpdated(messageId: "m1", role: "assistant"),
                .partUpdated(messageId: "m1", part: basePart),
                .partDelta(
                    messageId: "m1",
                    partId: "p1",
                    partType: "text",
                    field: "text",
                    delta: "hel"
                ),
                .partDelta(
                    messageId: "m1",
                    partId: "p1",
                    partType: "text",
                    field: "text",
                    delta: "lo"
                ),
            ],
            isStreaming: true
        )
        store.applySessionCacheOps([], isStreaming: false)

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages[0].role, .assistant)
        XCTAssertEqual(store.messages[0].parts.count, 1)
        XCTAssertEqual(store.messages[0].parts[0].text, "hello")
        XCTAssertFalse(store.messages[0].isStreaming)
        XCTAssertFalse(store.isStreaming)
    }

    func testSessionCacheRevisionRejectsRollback() {
        let store = AIChatStore()

        XCTAssertTrue(store.shouldApplySessionCacheRevision(1, sessionId: "s1"))
        XCTAssertTrue(store.shouldApplySessionCacheRevision(2, sessionId: "s1"))
        XCTAssertFalse(store.shouldApplySessionCacheRevision(1, sessionId: "s1"))
        XCTAssertTrue(store.shouldApplySessionCacheRevision(2, sessionId: "s1"))
    }

    func testRenderRevisionIncrementsOnPartUpdateAndDelta() {
        let store = AIChatStore()

        store.applySessionCacheOps(
            [
                .messageUpdated(messageId: "m1", role: "assistant"),
                .partUpdated(messageId: "m1", part: makeTextPart(id: "p1", text: "hel")),
            ],
            isStreaming: true
        )
        store.applySessionCacheOps([], isStreaming: false)

        XCTAssertEqual(store.messages.count, 1)
        let revisionAfterPartUpdate = store.messages[0].renderRevision
        XCTAssertGreaterThan(revisionAfterPartUpdate, 0)

        store.applySessionCacheOps(
            [
                .partDelta(
                    messageId: "m1",
                    partId: "p1",
                    partType: "text",
                    field: "text",
                    delta: "lo"
                ),
            ],
            isStreaming: true
        )
        store.applySessionCacheOps([], isStreaming: false)

        XCTAssertEqual(store.messages[0].parts.first?.text, "hello")
        XCTAssertGreaterThan(store.messages[0].renderRevision, revisionAfterPartUpdate)
    }

    func testStreamingStateConvergesWhenToolStopsRunning() {
        let store = AIChatStore()
        store.setCurrentSessionId("s1")

        let toolRunningMessage = AIProtocolMessageInfo(
            id: "m-tool",
            role: "assistant",
            createdAt: nil,
            agent: nil,
            modelProviderID: nil,
            modelID: nil,
            parts: [makeToolPart(id: "tp1", status: "running")]
        )
        store.replaceMessagesFromSessionCache([toolRunningMessage], isStreaming: false)
        XCTAssertTrue(store.isStreaming)

        store.applySessionCacheOps(
            [
                .partUpdated(messageId: "m-tool", part: makeToolPart(id: "tp1", status: "success")),
            ],
            isStreaming: false
        )
        XCTAssertFalse(store.isStreaming)
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

    // MARK: - 工具卡缓存与间距回归测试

    /// 验证会话快照中多个工具 part 都被正确保留，不丢失也不产生重复。
    func testReplaceMessagesFromSessionCachePreservesMultipleToolParts() {
        let store = AIChatStore()
        let messages = [
            AIProtocolMessageInfo(
                id: "m-assistant",
                role: "assistant",
                createdAt: nil,
                agent: nil,
                modelProviderID: nil,
                modelID: nil,
                parts: [
                    makeToolPart(id: "tp1", status: "success"),
                    makeToolPart(id: "tp2", status: "success"),
                    makeTextPart(id: "p1", text: "done"),
                ]
            ),
        ]

        store.replaceMessagesFromSessionCache(messages, isStreaming: false)

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages[0].parts.count, 3)
        let toolParts = store.messages[0].parts.filter { $0.kind == .tool }
        XCTAssertEqual(toolParts.count, 2, "两个工具卡都应保留在缓存中")
        // 工具 part 顺序应与原始顺序一致
        XCTAssertEqual(toolParts[0].id, "tp1")
        XCTAssertEqual(toolParts[1].id, "tp2")
    }

    /// 验证增量 ops 可以在同一消息中正确平铺多个工具 part，空文本 part 不影响工具卡顺序。
    func testApplySessionCacheOpsPreservesToolPartsWithEmptyTextPart() {
        let store = AIChatStore()

        store.applySessionCacheOps(
            [
                .messageUpdated(messageId: "m1", role: "assistant"),
                // 空文本 part（渲染层过滤，缓存层不应丢弃）
                .partUpdated(messageId: "m1", part: makeTextPart(id: "empty-p", text: "")),
                .partUpdated(messageId: "m1", part: makeToolPart(id: "tp1", status: "success")),
                .partUpdated(messageId: "m1", part: makeToolPart(id: "tp2", status: "success")),
            ],
            isStreaming: false
        )

        XCTAssertEqual(store.messages.count, 1)
        let allParts = store.messages[0].parts
        XCTAssertEqual(allParts.count, 3, "空文本 part 也应保留在缓存中，由渲染层决定是否显示")
        let toolParts = allParts.filter { $0.kind == .tool }
        XCTAssertEqual(toolParts.count, 2, "两个相邻工具卡均应存在于缓存中")
    }

    /// 验证相邻工具卡的 session cache 快照替换后，再次替换不会产生重复 part。
    func testReplaceMessagesFromSessionCacheIsIdempotentForToolParts() {
        let store = AIChatStore()
        let messages = [
            AIProtocolMessageInfo(
                id: "m1",
                role: "assistant",
                createdAt: nil,
                agent: nil,
                modelProviderID: nil,
                modelID: nil,
                parts: [
                    makeToolPart(id: "tp1", status: "success"),
                    makeToolPart(id: "tp2", status: "success"),
                ]
            ),
        ]

        store.replaceMessagesFromSessionCache(messages, isStreaming: false)
        store.replaceMessagesFromSessionCache(messages, isStreaming: false)

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages[0].parts.count, 2, "重复替换不应产生重复 part")
    }

    // MARK: - part_id 去重（WI-003）

    /// 当 Core 历史消息中同一 part_id 对应多次状态更新时（running → completed），
    /// replaceMessagesFromSessionCache 应只保留最后一次（最完整状态），不渲染多个卡片。
    func testReplaceMessagesFromSessionCacheDedupsByPartId() {
        let store = AIChatStore()
        // 模拟 Core 历史回放：同一 tool_call_id 先发 running，再发 completed
        let messages = [
            AIProtocolMessageInfo(
                id: "m-assistant",
                role: "assistant",
                createdAt: nil,
                agent: nil,
                modelProviderID: nil,
                modelID: nil,
                parts: [
                    makeToolPart(id: "tp-abc", status: "running"),
                    makeToolPart(id: "tp-abc", status: "completed"),  // 同 part_id，应覆盖上一条
                ]
            ),
        ]

        store.replaceMessagesFromSessionCache(messages, isStreaming: false)

        XCTAssertEqual(store.messages.count, 1)
        let parts = store.messages[0].parts
        XCTAssertEqual(parts.count, 1, "同一 part_id 应去重，只保留最后一次")
        XCTAssertEqual(parts[0].toolView?.status, .completed, "保留的 part 应是最终完整状态")
    }

    /// 不同 part_id 的工具调用不应相互覆盖，都应完整保留。
    func testReplaceMessagesFromSessionCacheKeepsDistinctPartIds() {
        let store = AIChatStore()
        let messages = [
            AIProtocolMessageInfo(
                id: "m1",
                role: "assistant",
                createdAt: nil,
                agent: nil,
                modelProviderID: nil,
                modelID: nil,
                parts: [
                    makeToolPart(id: "tp-1", status: "completed"),
                    makeToolPart(id: "tp-2", status: "completed"),
                    makeToolPart(id: "tp-3", status: "error"),
                ]
            ),
        ]

        store.replaceMessagesFromSessionCache(messages, isStreaming: false)

        XCTAssertEqual(store.messages[0].parts.count, 3, "不同 part_id 应全部保留")
    }

    /// 去重行为跨消息边界不干扰：同一 part_id 只在所属消息内去重，不影响其他消息。
    func testReplaceMessagesFromSessionCacheDedupsWithinMessageBoundary() {
        let store = AIChatStore()
        let messages = [
            AIProtocolMessageInfo(
                id: "m-first",
                role: "assistant",
                createdAt: nil,
                agent: nil,
                modelProviderID: nil,
                modelID: nil,
                parts: [makeToolPart(id: "tp-shared", status: "completed")]
            ),
            AIProtocolMessageInfo(
                id: "m-second",
                role: "assistant",
                createdAt: nil,
                agent: nil,
                modelProviderID: nil,
                modelID: nil,
                parts: [makeToolPart(id: "tp-shared", status: "error")]
            ),
        ]

        store.replaceMessagesFromSessionCache(messages, isStreaming: false)

        XCTAssertEqual(store.messages.count, 2)
        XCTAssertEqual(store.messages[0].parts.count, 1)
        XCTAssertEqual(store.messages[1].parts.count, 1)
        // 两条消息中同名 part_id 各自独立，不互相覆盖
        XCTAssertEqual(store.messages[0].parts[0].toolView?.status, .completed)
        XCTAssertEqual(store.messages[1].parts[0].toolView?.status, .error)
    }

    // MARK: - 分页历史加载

    func testUpdateHistoryPaginationSetsCursorAndHasMore() {
        let store = AIChatStore()
        store.updateHistoryPagination(hasMore: true, nextBeforeMessageId: "cursor-123")
        XCTAssertTrue(store.historyHasMore)
        XCTAssertEqual(store.historyNextBeforeMessageId, "cursor-123")
    }

    func testUpdateHistoryPaginationFalseResetsState() {
        let store = AIChatStore()
        store.updateHistoryPagination(hasMore: true, nextBeforeMessageId: "old-cursor")
        store.updateHistoryPagination(hasMore: false, nextBeforeMessageId: nil)
        XCTAssertFalse(store.historyHasMore)
        XCTAssertNil(store.historyNextBeforeMessageId)
    }

    func testPrependMessagesWithDeduplication() {
        let store = AIChatStore()
        let existing = AIProtocolMessageInfo(
            id: "m-existing", role: "user", createdAt: nil, agent: nil,
            modelProviderID: nil, modelID: nil, parts: [makeTextPart(id: "p1", text: "hi")]
        )
        store.replaceMessagesFromSessionCache([existing], isStreaming: false)

        let olderDup = AIProtocolMessageInfo(
            id: "m-existing", role: "user", createdAt: nil, agent: nil,
            modelProviderID: nil, modelID: nil, parts: [makeTextPart(id: "p1", text: "hi")]
        )
        let olderNew = AIProtocolMessageInfo(
            id: "m-older", role: "user", createdAt: nil, agent: nil,
            modelProviderID: nil, modelID: nil, parts: [makeTextPart(id: "p2", text: "older")]
        )
        // 转为 AIChatMessage 以使用 prependMessages
        let existingStore = AIChatStore()
        existingStore.replaceMessagesFromSessionCache([olderDup, olderNew], isStreaming: false)
        let olderMessages = existingStore.messages
        store.prependMessages(olderMessages)

        // olderDup 已存在，不应重复添加；olderNew 应出现在最前面
        XCTAssertEqual(store.messages.count, 2)
        XCTAssertEqual(store.messages.first?.messageId, "m-older")
        XCTAssertEqual(store.messages.last?.messageId, "m-existing")
    }

    func testRecentHistoryLoadingClearsAfterReplacingMessages() {
        let store = AIChatStore()
        store.setRecentHistoryLoading(true)

        store.replaceMessagesFromSessionCache(
            [
                AIProtocolMessageInfo(
                    id: "m1",
                    role: "assistant",
                    createdAt: nil,
                    agent: nil,
                    modelProviderID: nil,
                    modelID: nil,
                    parts: [makeTextPart(id: "p1", text: "hello")]
                ),
            ],
            isStreaming: false
        )

        XCTAssertFalse(store.recentHistoryIsLoading)
    }

    func testRecentHistoryLoadingClearsAfterPaginationUpdate() {
        let store = AIChatStore()
        store.setRecentHistoryLoading(true)

        store.updateHistoryPagination(hasMore: false, nextBeforeMessageId: nil)

        XCTAssertFalse(store.recentHistoryIsLoading)
    }

    func testRecentHistoryLoadingClearsAfterChatDone() {
        let store = AIChatStore()
        store.setRecentHistoryLoading(true)

        store.handleChatDone(sessionId: "s1")

        XCTAssertFalse(store.recentHistoryIsLoading)
    }

    private func makeToolPart(id: String, status: String) -> AIProtocolPartInfo {
        let toolStatus: AIToolStatus
        switch status {
        case "success", "completed":
            toolStatus = .completed
        case "failed", "error":
            toolStatus = .error
        case "running", "in_progress":
            toolStatus = .running
        case "pending", "waiting":
            toolStatus = .pending
        default:
            toolStatus = .unknown
        }
        return AIProtocolPartInfo(
            id: id,
            partType: "tool",
            text: nil,
            mime: nil,
            filename: nil,
            url: nil,
            synthetic: nil,
            ignored: nil,
            source: nil,
            toolName: "shell",
            toolCallId: "call-\(id)",
            toolKind: nil,
            toolView: AIToolView(
                status: toolStatus,
                displayTitle: "shell",
                statusText: status,
                summary: nil,
                headerCommandSummary: nil,
                durationMs: nil,
                sections: [],
                locations: [],
                question: nil,
                linkedSession: nil
            )
        )
    }
}
