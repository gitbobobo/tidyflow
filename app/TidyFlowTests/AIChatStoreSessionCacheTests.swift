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
        store.flushPendingStreamEvents()
        store.handleChatDone(sessionId: "s1")

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages[0].role, .assistant)
        XCTAssertEqual(store.messages[0].parts.count, 1)
        XCTAssertEqual(store.messages[0].parts[0].text, "hello")
        XCTAssertFalse(store.messages[0].isStreaming)
        XCTAssertFalse(store.isStreaming)
    }

    func testToolOutputDeltaReusesExistingOutputSectionByTitle() {
        let store = AIChatStore()

        store.applySessionCacheOps(
            [
                .messageUpdated(messageId: "m-tool", role: "assistant"),
                .partUpdated(
                    messageId: "m-tool",
                    part: makeToolPart(
                        id: "tp1",
                        status: "running",
                        sections: [
                            AIToolViewSection(
                                id: "terminal-output",
                                title: "output",
                                content: "hello",
                                style: .terminal,
                                language: "text",
                                copyable: true,
                                collapsedByDefault: false
                            ),
                        ]
                    )
                ),
                .partDelta(
                    messageId: "m-tool",
                    partId: "tp1",
                    partType: "tool",
                    field: "output",
                    delta: " world"
                ),
            ],
            isStreaming: false
        )

        let sections = store.messages[0].parts[0].toolView?.sections ?? []
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].id, "terminal-output")
        XCTAssertEqual(sections[0].content, "hello world")
    }

    func testToolProgressDeltaReusesExistingProgressSectionByTitle() {
        let store = AIChatStore()

        store.applySessionCacheOps(
            [
                .messageUpdated(messageId: "m-tool", role: "assistant"),
                .partUpdated(
                    messageId: "m-tool",
                    part: makeToolPart(
                        id: "tp1",
                        status: "running",
                        sections: [
                            AIToolViewSection(
                                id: "terminal-progress",
                                title: "progress",
                                content: "10%",
                                style: .text,
                                language: nil,
                                copyable: true,
                                collapsedByDefault: false
                            ),
                        ]
                    )
                ),
                .partDelta(
                    messageId: "m-tool",
                    partId: "tp1",
                    partType: "tool",
                    field: "progress",
                    delta: "50%"
                ),
            ],
            isStreaming: false
        )

        let sections = store.messages[0].parts[0].toolView?.sections ?? []
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].id, "terminal-progress")
        XCTAssertEqual(sections[0].content, "10%\n50%")
    }

    func testToolFullPartUpdateReplacesEarlierDeltaPlaceholder() {
        let store = AIChatStore()

        store.applySessionCacheOps(
            [
                .messageUpdated(messageId: "m-tool", role: "assistant"),
                .partDelta(
                    messageId: "m-tool",
                    partId: "tp1",
                    partType: "tool",
                    field: "output",
                    delta: "streaming"
                ),
                .partUpdated(
                    messageId: "m-tool",
                    part: makeToolPart(
                        id: "tp1",
                        status: "completed",
                        sections: [
                            AIToolViewSection(
                                id: "terminal-output",
                                title: "output",
                                content: "final output",
                                style: .terminal,
                                language: "text",
                                copyable: true,
                                collapsedByDefault: false
                            ),
                        ]
                    )
                ),
            ],
            isStreaming: false
        )

        let sections = store.messages[0].parts[0].toolView?.sections ?? []
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].id, "terminal-output")
        XCTAssertEqual(sections[0].content, "final output")
        XCTAssertEqual(store.messages[0].parts[0].toolView?.status, .completed)
    }

    func testSessionCacheRevisionRejectsRollback() {
        let store = AIChatStore()

        XCTAssertTrue(store.shouldApplySessionCacheRevision(fromRevision: 0, toRevision: 1, sessionId: "s1"))
        XCTAssertTrue(store.shouldApplySessionCacheRevision(fromRevision: 1, toRevision: 2, sessionId: "s1"))
        XCTAssertFalse(store.shouldApplySessionCacheRevision(fromRevision: 2, toRevision: 1, sessionId: "s1"))
        XCTAssertTrue(store.shouldApplySessionCacheRevision(fromRevision: 2, toRevision: 2, sessionId: "s1"))
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
        store.flushPendingStreamEvents()
        store.handleChatDone(sessionId: "s1")

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
        store.flushPendingStreamEvents()
        store.handleChatDone(sessionId: "s1")

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

    // MARK: - 会话作用域隔离与终态收敛回归

    /// 旧会话 delayed delta 在切换后被丢弃：切换 sessionId 后旧事件不写入新消息列表。
    func testOldSessionDelayedDeltaDroppedAfterSwitch() {
        let store = AIChatStore()
        store.setCurrentSessionId("session-old")

        // 入队流式事件（尚未 flush）
        store.applySessionCacheOps(
            [.messageUpdated(messageId: "m-old", role: "assistant"),
             .partUpdated(messageId: "m-old", part: makeTextPart(id: "p-old", text: nil)),
             .partDelta(messageId: "m-old", partId: "p-old", partType: "text", field: "text", delta: "hello")],
            isStreaming: true
        )

        // 切换到新会话（invalidateStreamScope 应丢弃旧事件）
        store.clearMessages()
        store.setCurrentSessionId("session-new")

        // flush 不应产生任何消息（旧事件已被丢弃）
        store.flushPendingStreamEvents()
        XCTAssertTrue(store.messages.isEmpty, "切换会话后旧流式事件应被丢弃")
    }

    /// terminal update 在无 ops 时立即冲刷最后 delta。
    func testTerminalUpdateFlushesLastDelta() {
        let store = AIChatStore()
        store.setCurrentSessionId("session-t")

        // 入队流式事件
        store.applySessionCacheOps(
            [.messageUpdated(messageId: "m-t", role: "assistant"),
             .partUpdated(messageId: "m-t", part: makeTextPart(id: "p-t", text: nil)),
             .partDelta(messageId: "m-t", partId: "p-t", partType: "text", field: "text", delta: "tail content")],
            isStreaming: true
        )

        // 终态提交应先冲刷再收敛
        store.commitTerminalState(sessionId: "session-t")

        // 验证尾部文本已正确落盘
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.first?.parts.first?.text, "tail content",
                       "终态提交应先冲刷待处理 delta")
        XCTAssertFalse(store.isStreaming, "终态后 isStreaming 应为 false")
    }

    /// 后台 snapshot 在 scope（generation）变化后被拒绝：applyPreparedSnapshot 的单次 tail 收敛。
    func testApplyPreparedSnapshotSingleTailPublish() {
        let store = AIChatStore()
        store.setCurrentSessionId("session-snap")
        let initialRevision = store.tailRevision

        let snapshot = AIChatPreparedSnapshot(
            messages: [AIChatMessage(messageId: "m-snap", role: .assistant,
                                      parts: [AIChatPart(id: "p-snap", kind: .text, text: "snapshot content", toolName: nil)],
                                      isStreaming: false)],
            pendingQuestionRequests: [],
            effectiveSelectionHint: nil,
            isStreaming: false,
            fromRevision: 0,
            toRevision: 1
        )
        store.applyPreparedSnapshot(snapshot)
        let afterFirstSnapshot = store.tailRevision

        XCTAssertGreaterThan(afterFirstSnapshot, initialRevision, "snapshot 应推进 tailRevision")

        // 再次应用相同 snapshot：tailRevision 不应再次推进（内容未变化）
        store.applyPreparedSnapshot(snapshot)
        XCTAssertEqual(store.tailRevision, afterFirstSnapshot,
                       "相同内容的 snapshot 不应重复推进 tailRevision")
    }

    /// 验证 generation 递增：setCurrentSessionId 触发 scope 失效。
    func testScopeGenerationIncrementsOnSessionSwitch() {
        let store = AIChatStore()
        let gen0 = store.testStreamScopeGeneration

        store.setCurrentSessionId("session-a")
        let gen1 = store.testStreamScopeGeneration
        XCTAssertGreaterThan(gen1, gen0, "setCurrentSessionId 应递增 generation")

        store.setCurrentSessionId("session-b")
        let gen2 = store.testStreamScopeGeneration
        XCTAssertGreaterThan(gen2, gen1, "再次切换应继续递增 generation")
    }

    /// 验证 clearAll 递增 generation。
    func testScopeGenerationIncrementsOnClearAll() {
        let store = AIChatStore()
        store.setCurrentSessionId("session-x")
        let genBefore = store.testStreamScopeGeneration

        store.clearAll()
        XCTAssertGreaterThan(store.testStreamScopeGeneration, genBefore,
                             "clearAll 应递增 generation")
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

    func testIdenticalSessionCacheSnapshotDoesNotRepublishTailSignals() {
        let store = AIChatStore()
        let snapshot = [
            AIProtocolMessageInfo(
                id: "m1",
                role: "assistant",
                createdAt: nil,
                agent: nil,
                modelProviderID: nil,
                modelID: nil,
                parts: [makeTextPart(id: "p1", text: "hello")]
            ),
        ]

        store.replaceMessagesFromSessionCache(snapshot, isStreaming: false)
        let revisionAfterFirstApply = store.tailRevision

        store.replaceMessagesFromSessionCache(snapshot, isStreaming: false)

        XCTAssertEqual(
            store.tailRevision,
            revisionAfterFirstApply,
            "相同会话快照重复应用时不应再次发布 tail signal"
        )
    }

    func testIdenticalStreamingSessionCacheSnapshotDoesNotRepublishTailSignals() {
        let store = AIChatStore()
        let snapshot = [
            AIProtocolMessageInfo(
                id: "m1",
                role: "assistant",
                createdAt: nil,
                agent: nil,
                modelProviderID: nil,
                modelID: nil,
                parts: [makeTextPart(id: "p1", text: "hello")]
            ),
        ]

        store.replaceMessagesFromSessionCache(snapshot, isStreaming: true)
        let revisionAfterFirstApply = store.tailRevision

        store.replaceMessagesFromSessionCache(snapshot, isStreaming: true)

        XCTAssertEqual(
            store.tailRevision,
            revisionAfterFirstApply,
            "相同流式会话快照重复应用时不应再次发布 tail signal"
        )
    }

    func testSummarizeTailChangeTreatsRemappedSessionCacheSnapshotAsNoMeaningfulChange() {
        let before = [
            AIChatMessage(
                id: "local-before",
                messageId: "m1",
                role: .assistant,
                parts: [AIChatPart(id: "p1", kind: .text, text: "hello")],
                isStreaming: false
            ),
        ]
        let after = [
            AIChatMessage(
                id: "local-after",
                messageId: "m1",
                role: .assistant,
                parts: [AIChatPart(id: "p1", kind: .text, text: "hello")],
                isStreaming: false
            ),
        ]

        XCTAssertEqual(
            AIChatStreamCoalescer.summarizeTailChange(before: before, after: after),
            .noMeaningfulChange,
            "相同 messageId 的 remap 快照不应因为本地 UUID 变化被视为尾部替换"
        )
    }

    func testSessionSwitchClearsPublicationBaselineForSameSnapshot() {
        let store = AIChatStore()
        let snapshot = [
            AIProtocolMessageInfo(
                id: "m1",
                role: "assistant",
                createdAt: nil,
                agent: nil,
                modelProviderID: nil,
                modelID: nil,
                parts: [makeTextPart(id: "p1", text: "hello")]
            ),
        ]

        store.setCurrentSessionId("session-a")
        store.replaceMessagesFromSessionCache(snapshot, isStreaming: false)
        let revisionAfterSessionA = store.tailRevision

        store.clearMessages()
        let revisionAfterClear = store.tailRevision
        XCTAssertGreaterThan(revisionAfterClear, revisionAfterSessionA)

        store.setCurrentSessionId("session-b")
        store.replaceMessagesFromSessionCache(snapshot, isStreaming: false)

        XCTAssertGreaterThan(
            store.tailRevision,
            revisionAfterClear,
            "切换会话并清空缓存后，同一快照在新会话中应重新发布"
        )
    }

    // MARK: - AI 聊天舞台生命周期与缓存隔离

    /// 验证舞台 enter → ready 迁移后，工具切换（switchTool）正确重置上下文。
    func testStageLifecycleEnterReadySwitchTool() {
        let lifecycle = AIChatStageLifecycle()

        let enterResult = lifecycle.apply(.enter(project: "proj-a", workspace: "ws-1", aiTool: .opencode))
        XCTAssertNotEqual(enterResult, .ignored)
        XCTAssertEqual(lifecycle.state.phase, .entering)
        XCTAssertEqual(lifecycle.state.project, "proj-a")
        XCTAssertEqual(lifecycle.state.aiTool, .opencode)

        lifecycle.apply(.ready)
        XCTAssertEqual(lifecycle.state.phase, .active)

        let switchResult = lifecycle.apply(.switchTool(newTool: .codex))
        XCTAssertNotEqual(switchResult, .ignored)
        XCTAssertEqual(lifecycle.state.phase, .entering)
        XCTAssertEqual(lifecycle.state.aiTool, .codex)
        XCTAssertNil(lifecycle.state.activeSessionId, "切换工具应清空 activeSessionId")
    }

    /// 验证舞台关闭后进入 idle，缓存不受影响。
    func testStageLifecycleCloseTransitionsToIdle() {
        let lifecycle = AIChatStageLifecycle()
        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .claude_code))
        lifecycle.apply(.ready)

        lifecycle.apply(.close)
        XCTAssertEqual(lifecycle.state.phase, .idle)
        XCTAssertEqual(lifecycle.state.project, "", "idle 状态应重置项目名")
    }

    /// 验证多工作区场景下，不同工作区的 enter 不会互相干扰。
    func testStageLifecycleMultiWorkspaceIsolation() {
        let lifecycle = AIChatStageLifecycle()

        lifecycle.apply(.enter(project: "proj-a", workspace: "ws-1", aiTool: .opencode))
        lifecycle.apply(.ready)
        XCTAssertTrue(lifecycle.acceptsStreamEvent(project: "proj-a", workspace: "ws-1", aiTool: .opencode))
        XCTAssertFalse(lifecycle.acceptsStreamEvent(project: "proj-a", workspace: "ws-2", aiTool: .opencode),
                       "不同工作区的流式事件应被拒绝")

        // 切换到另一个工作区
        lifecycle.apply(.close)
        lifecycle.apply(.enter(project: "proj-a", workspace: "ws-2", aiTool: .opencode))
        lifecycle.apply(.ready)
        XCTAssertFalse(lifecycle.acceptsStreamEvent(project: "proj-a", workspace: "ws-1", aiTool: .opencode),
                       "前一个工作区的流式事件应被拒绝")
        XCTAssertTrue(lifecycle.acceptsStreamEvent(project: "proj-a", workspace: "ws-2", aiTool: .opencode))
    }

    // MARK: - AI 聊天舞台生命周期与缓存隔离（流式中断边界）

    /// 验证流式中断后缓存状态与舞台状态一致。
    func testStreamInterruptionCacheConsistency() {
        let lifecycle = AIChatStageLifecycle()
        let store = AIChatStore()

        lifecycle.apply(.enter(project: "proj", workspace: "ws", aiTool: .opencode))
        lifecycle.apply(.ready)
        store.setCurrentSessionId("sess-1")
        store.applySessionCacheOps(
            [
                .messageUpdated(messageId: "m1", role: "assistant"),
                .partUpdated(messageId: "m1", part: makeTextPart(id: "p1", text: "streaming...")),
            ],
            isStreaming: true
        )
        store.flushPendingStreamEvents()
        XCTAssertTrue(store.isStreaming)

        // 流式中断
        lifecycle.apply(.streamInterrupted(sessionId: "sess-1"))
        XCTAssertEqual(lifecycle.state.phase, .resuming)
        // 缓存中的消息应保留（不清空），等待恢复
        XCTAssertEqual(store.messages.count, 1, "流式中断不应清空消息缓存")

        // 恢复完成后替换消息
        lifecycle.apply(.resumeCompleted)
        XCTAssertEqual(lifecycle.state.phase, .active)
        store.handleChatDone(sessionId: "sess-1")
        XCTAssertFalse(store.isStreaming, "恢复完成后流式标志应清除")
    }

    /// 验证工作区切换后 clearAll + 舞台 forceReset 联动正确。
    func testWorkspaceSwitchClearAllWithStageReset() {
        let lifecycle = AIChatStageLifecycle()
        let store = AIChatStore()

        // 在工作区 A 建立会话
        lifecycle.apply(.enter(project: "proj", workspace: "ws-a", aiTool: .codex))
        lifecycle.apply(.ready)
        store.setCurrentSessionId("sess-a")
        store.applySessionCacheOps(
            [.messageUpdated(messageId: "m1", role: "user")],
            isStreaming: false
        )

        // 模拟工作区切换
        lifecycle.apply(.forceReset)
        store.clearAll()

        // 验证清理完整
        XCTAssertEqual(lifecycle.state.phase, .idle)
        XCTAssertTrue(store.subscribedSessionIds.isEmpty)
        XCTAssertTrue(store.messages.isEmpty)

        // 进入工作区 B，不应残留工作区 A 的状态
        lifecycle.apply(.enter(project: "proj", workspace: "ws-b", aiTool: .codex))
        lifecycle.apply(.ready)
        store.setCurrentSessionId("sess-b")
        XCTAssertFalse(store.subscribedSessionIds.contains("sess-a"),
                       "工作区切换后旧会话 ID 不应在订阅集合中")
    }

    private func makeToolPart(
        id: String,
        status: String,
        sections: [AIToolViewSection] = []
    ) -> AIProtocolPartInfo {
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
                sections: sections,
                locations: [],
                question: nil,
                linkedSession: nil
            )
        )
    }
}

// MARK: - 工具 diff section 更新非回归测试

/// 验证流式工具 diff section 更新后，消息 diff 内容正确替换而不是追加。
final class AIChatToolDiffSectionUpdateTests: XCTestCase {
    /// 工具 part 通过 partUpdated op 更新时 sections 内容应完整替换（非追加）。
    func testPartUpdatedOpReplacesDiffSections() {
        let store = AIChatStore()

        // 初始：流式 partDelta 建立 diff 占位，先 flush 以建立中间状态
        store.applySessionCacheOps(
            [
                .messageUpdated(messageId: "m-edit", role: "assistant"),
                .partDelta(
                    messageId: "m-edit",
                    partId: "tp-diff",
                    partType: "tool",
                    field: "output",
                    delta: "streaming..."
                ),
            ],
            isStreaming: true
        )
        // 先 flush 流式事件，建立 streaming placeholder，再应用 partUpdated
        store.flushPendingStreamEvents()

        // 最终 partUpdated 应替换 sections，不追加
        store.applySessionCacheOps(
            [
                .partUpdated(
                    messageId: "m-edit",
                    part: makeToolPartWithSections(
                        id: "tp-diff",
                        sections: [
                            AIToolViewSection(
                                id: "edit-diff",
                                title: "diff",
                                content: "- old\n+ new",
                                style: .diff,
                                language: "diff",
                                copyable: false,
                                collapsedByDefault: false
                            )
                        ]
                    )
                )
            ],
            isStreaming: false
        )

        store.handleChatDone(sessionId: "s1")

        let sections = store.messages.first?.parts.first?.toolView?.sections ?? []
        XCTAssertEqual(sections.count, 1, "partUpdated 应替换 sections 而非追加")
        XCTAssertEqual(sections.first?.style, .diff, "section 应为 diff 类型")
        XCTAssertEqual(sections.first?.content, "- old\n+ new")
    }

    /// toolKind=diff 工具在完成时 diff section 内容正确，不重复。
    func testDiffToolKindCompletionHasCorrectSections() {
        let store = AIChatStore()

        store.applySessionCacheOps(
            [
                .messageUpdated(messageId: "m-tool", role: "assistant"),
                .partUpdated(
                    messageId: "m-tool",
                    part: AIProtocolPartInfo(
                        id: "tp-1", partType: "tool", text: nil, mime: nil, filename: nil,
                        url: nil, synthetic: nil, ignored: nil, source: nil,
                        toolName: "edit", toolCallId: "call-1",
                        toolKind: "diff",
                        toolView: AIToolView(
                            status: .completed, displayTitle: "edit", statusText: "completed",
                            summary: nil, headerCommandSummary: nil, durationMs: nil,
                            sections: [
                                AIToolViewSection(
                                    id: "edit-diff", title: "diff",
                                    content: "final diff",
                                    style: .diff, language: "diff",
                                    copyable: false, collapsedByDefault: false
                                )
                            ],
                            locations: [], question: nil, linkedSession: nil
                        )
                    )
                )
            ],
            isStreaming: false
        )

        store.flushPendingStreamEvents()
        store.handleChatDone(sessionId: "s1")

        XCTAssertEqual(store.messages.first?.parts.first?.toolView?.sections.count, 1)
        XCTAssertEqual(store.messages.first?.parts.first?.toolKind, "diff")
        XCTAssertEqual(store.messages.first?.parts.first?.toolView?.status, .completed)
    }

    private func makeToolPartWithSections(id: String, sections: [AIToolViewSection]) -> AIProtocolPartInfo {
        AIProtocolPartInfo(
            id: id, partType: "tool", text: nil, mime: nil, filename: nil,
            url: nil, synthetic: nil, ignored: nil, source: nil,
            toolName: "shell", toolCallId: "call-\(id)", toolKind: "diff",
            toolView: AIToolView(
                status: .running, displayTitle: "shell", statusText: "running",
                summary: nil, headerCommandSummary: nil, durationMs: nil,
                sections: sections, locations: [], question: nil, linkedSession: nil
            )
        )
    }
}
