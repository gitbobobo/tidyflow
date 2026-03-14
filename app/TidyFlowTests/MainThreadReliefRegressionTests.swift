import XCTest
@testable import TidyFlow

final class AIChatStoreTailSignalTests: XCTestCase {
    func testLatestAssistantPartMetaTracksLastAssistantPartAcrossTrailingUserMessages() {
        let store = AIChatStore()
        let assistantSource: [String: Any] = [
            "item_type": "plan",
            "vendor": "codex",
        ]

        store.replaceMessages([
            AIChatMessage(
                id: "local-user",
                messageId: "user-1",
                role: .user,
                parts: [
                    AIChatPart(id: "user-part", kind: .text, text: "请先给计划"),
                ]
            ),
            AIChatMessage(
                id: "local-assistant",
                messageId: "assistant-1",
                role: .assistant,
                parts: [
                    AIChatPart(
                        id: "assistant-plan",
                        kind: .text,
                        text: "这里是计划",
                        source: assistantSource
                    ),
                ]
            ),
            AIChatMessage(
                id: "local-user-2",
                messageId: "user-2",
                role: .user,
                parts: [
                    AIChatPart(id: "user-part-2", kind: .text, text: "收到"),
                ]
            ),
        ])

        XCTAssertEqual(store.latestAssistantPartMeta?.messageId, "assistant-1")
        XCTAssertEqual(store.latestAssistantPartMeta?.localMessageId, "local-assistant")
        XCTAssertEqual(store.latestAssistantPartMeta?.partId, "assistant-plan")
        XCTAssertEqual(store.latestAssistantPartMeta?.kind, .text)
        let syntheticPart = AIChatPart(
            id: store.latestAssistantPartMeta?.partId ?? "",
            kind: store.latestAssistantPartMeta?.kind ?? .text,
            text: nil,
            source: store.latestAssistantPartMeta?.source
        )
        XCTAssertTrue(
            AIPlanImplementationQuestion.isCodexPlanProposalPart(syntheticPart),
            "尾部轻量信号应保留计划卡探测所需的 source 信息"
        )
    }

    func testTailRevisionAdvancesOnStreamingMutationWithoutChangingMetaTarget() {
        let store = AIChatStore()
        store.applySessionCacheOps(
            [
                .messageUpdated(messageId: "assistant-1", role: "assistant"),
                .partUpdated(messageId: "assistant-1", part: makeTextPart(id: "part-1", text: "hel")),
            ],
            isStreaming: true
        )
        store.flushPendingStreamEvents()

        let revisionAfterInitialPart = store.tailRevision
        let metaAfterInitialPart = store.latestAssistantPartMeta

        store.applySessionCacheOps(
            [
                .partDelta(
                    messageId: "assistant-1",
                    partId: "part-1",
                    partType: "text",
                    field: "text",
                    delta: "lo"
                ),
            ],
            isStreaming: true
        )
        store.flushPendingStreamEvents()

        XCTAssertGreaterThan(store.tailRevision, revisionAfterInitialPart)
        XCTAssertEqual(store.latestAssistantPartMeta?.messageId, metaAfterInitialPart?.messageId)
        XCTAssertEqual(store.latestAssistantPartMeta?.partId, metaAfterInitialPart?.partId)
        XCTAssertEqual(store.messages.first?.parts.first?.text, "hello")
    }

    func testTailSignalsClearWhenMessagesAreCleared() {
        let store = AIChatStore()
        store.replaceMessages([
            AIChatMessage(
                id: "assistant-local",
                messageId: "assistant-1",
                role: .assistant,
                parts: [AIChatPart(id: "assistant-part", kind: .text, text: "hello")]
            ),
        ])
        let revisionBeforeClear = store.tailRevision

        store.clearMessages()

        XCTAssertGreaterThan(store.tailRevision, revisionBeforeClear)
        XCTAssertNil(store.latestAssistantPartMeta)
        XCTAssertTrue(store.messages.isEmpty)
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

final class WSSetupIdempotenceTests: XCTestCase {
    func testSetupWSClientSkipsDuplicateConnectForSameTargetWhileConnecting() {
        let appState = AppState()
        defer {
            tearDownAppState(appState)
        }

        let port = 65534
        let authToken = appState.coreProcessManager.wsAuthToken
        let targetIdentity = "\(authToken ?? "")@\(port)"
        let targetURL = AppConfig.makeWsURL(port: port, token: authToken)

        appState.configuredWSConnectionTarget = targetIdentity
        appState.initializedWSConnectionIdentity = "already-initialized"
        appState.wsClient.updateAuthToken(authToken)
        appState.wsClient.currentURL = targetURL
        appState.wsClient.isConnecting = true
        appState.wsClient.webSocketTaskIdentity = "task-1"

        appState.setupWSClient(port: port)

        XCTAssertEqual(appState.configuredWSConnectionTarget, targetIdentity)
        XCTAssertEqual(appState.initializedWSConnectionIdentity, "already-initialized")
        XCTAssertEqual(appState.wsClient.currentURL, targetURL)
        XCTAssertEqual(appState.wsClient.webSocketTaskIdentity, "task-1")
    }
}

// MARK: - MainThreadReliefRegressionTests

/// 验证高频 delta flush 场景下事件聚合与会话隔离的回归用例。
///
/// 覆盖：
/// - 300 个连续 delta 事件被聚合为有界事件集，不产生 O(N) UI 刷新
/// - 会话切换后聚合器不跨 session 合并状态
final class MainThreadReliefRegressionTests: XCTestCase {

    // MARK: - 高频 delta 聚合界限

    func testHighFrequencyDeltaEventsCoalesceIntoBoundedResultSet() {
        // 300 个连续同 partId/field delta 应聚合为 1 个 delta
        let events: [AIChatStreamEvent] = (0..<300).map { i in
            AIChatStreamEvent.partDelta(
                messageId: "msg-1",
                partId: "part-1",
                partType: "text",
                field: "text",
                delta: "token\(i) "
            )
        }
        let result = AIChatStreamCoalescer.coalesce(events)
        // 聚合后应为单个 delta（同 partId/field 完全合并）
        XCTAssertEqual(result.count, 1, "300 个连续同字段 delta 应聚合为 1 个事件")
        if case let .partDelta(_, _, _, _, delta) = result[0] {
            XCTAssertTrue(delta.contains("token0 "), "聚合结果应包含首个 token")
            XCTAssertTrue(delta.contains("token299 "), "聚合结果应包含末个 token")
        } else {
            XCTFail("聚合结果类型不正确")
        }
    }

    func testInterleavedDifferentFieldsDontCoalesce() {
        // 不同 field 的 delta 不应合并
        let events: [AIChatStreamEvent] = [
            .partDelta(messageId: "msg-1", partId: "part-1", partType: "text", field: "text", delta: "aaa"),
            .partDelta(messageId: "msg-1", partId: "part-1", partType: "text", field: "reasoning", delta: "bbb"),
            .partDelta(messageId: "msg-1", partId: "part-1", partType: "text", field: "text", delta: "ccc"),
        ]
        let result = AIChatStreamCoalescer.coalesce(events)
        XCTAssertEqual(result.count, 3, "不同 field 的 delta 不应合并")
    }

    func testPartUpdatedBreaksCoalescingBoundary() {
        // partUpdated 会打断前后 delta 的合并
        let events: [AIChatStreamEvent] = [
            .partDelta(messageId: "msg-1", partId: "part-1", partType: "text", field: "text", delta: "a"),
            .partDelta(messageId: "msg-1", partId: "part-1", partType: "text", field: "text", delta: "b"),
            .partUpdated(messageId: "msg-1", part: AIProtocolPartInfo(
                id: "part-1", partType: "text", text: nil, mime: nil, filename: nil,
                url: nil, synthetic: nil, ignored: nil, source: nil,
                toolName: nil, toolCallId: nil, toolKind: nil, toolView: nil
            )),
            .partDelta(messageId: "msg-1", partId: "part-1", partType: "text", field: "text", delta: "c"),
        ]
        let result = AIChatStreamCoalescer.coalesce(events)
        XCTAssertEqual(result.count, 3, "partUpdated 前后的 delta 不应合并")
        if case let .partDelta(_, _, _, _, delta) = result[0] {
            XCTAssertEqual(delta, "ab", "partUpdated 前的 delta 应合并")
        }
    }

    // MARK: - 会话切换聚合隔离

    func testCoalescerDoesNotMergeEventsAcrossSessionSwitch() {
        // session A 的 delta 与 session B 的 delta 在同一批次时，
        // 不同 messageId 表示不同消息，不应被合并
        let sessionAEvents: [AIChatStreamEvent] = (0..<50).map { _ in
            AIChatStreamEvent.partDelta(
                messageId: "session-A-msg",
                partId: "part-1",
                partType: "text",
                field: "text",
                delta: "A"
            )
        }
        let sessionBEvents: [AIChatStreamEvent] = (0..<50).map { _ in
            AIChatStreamEvent.partDelta(
                messageId: "session-B-msg",
                partId: "part-1",
                partType: "text",
                field: "text",
                delta: "B"
            )
        }
        // 混合两个会话的事件（模拟错误场景）
        let mixed = sessionAEvents + sessionBEvents
        let result = AIChatStreamCoalescer.coalesce(mixed)
        // 不同 messageId 不应合并：应有 2 个 delta（A 批、B 批各一个）
        XCTAssertEqual(result.count, 2, "不同 session 消息的 delta 不应合并")
        if case let .partDelta(msgId, _, _, _, _) = result[0] {
            XCTAssertEqual(msgId, "session-A-msg", "第一批应为 session A")
        }
        if case let .partDelta(msgId, _, _, _, _) = result[1] {
            XCTAssertEqual(msgId, "session-B-msg", "第二批应为 session B")
        }
    }

    func testTailChangeSummaryDetectsNewMessage() {
        let before: [AIChatMessage] = [
            makeMsg(id: "msg-1", text: "Hello"),
        ]
        let after: [AIChatMessage] = [
            makeMsg(id: "msg-1", text: "Hello"),
            makeMsg(id: "msg-2", text: "World"),
        ]
        let summary = AIChatStreamCoalescer.summarizeTailChange(before: before, after: after)
        XCTAssertEqual(summary, .appendedNewMessage)
    }

    func testTailChangeSummaryDetectsTextGrowth() {
        let before: [AIChatMessage] = [makeMsg(id: "msg-1", text: "Hello")]
        let after: [AIChatMessage] = [makeMsg(id: "msg-1", text: "Hello world")]
        let summary = AIChatStreamCoalescer.summarizeTailChange(before: before, after: after)
        XCTAssertEqual(summary, .grewTailText)
    }

    func testTailChangeSummaryDetectsNoChange() {
        let messages: [AIChatMessage] = [makeMsg(id: "msg-1", text: "Hello")]
        let summary = AIChatStreamCoalescer.summarizeTailChange(before: messages, after: messages)
        XCTAssertEqual(summary, .noMeaningfulChange)
    }

    func testHighFrequencyDeltaFlushPublishesBoundedTailRevisions() {
        let store = AIChatStore()
        store.applySessionCacheOps(
            [
                .messageUpdated(messageId: "assistant-1", role: "assistant"),
                .partUpdated(messageId: "assistant-1", part: makeTextPart(id: "part-1", text: "")),
            ],
            isStreaming: true
        )
        store.flushPendingStreamEvents()
        let baseline = store.tailRevision

        let deltaOps: [AIProtocolSessionCacheOp] = (0..<300).map { index in
            .partDelta(
                messageId: "assistant-1",
                partId: "part-1",
                partType: "text",
                field: "text",
                delta: "token\(index)"
            )
        }
        store.applySessionCacheOps(deltaOps, isStreaming: true)
        store.flushPendingStreamEvents()

        XCTAssertLessThanOrEqual(
            store.tailRevision - baseline,
            1,
            "300 次 delta 在一次 flush 中应只产生有界的 tail 发布"
        )
        XCTAssertTrue(store.messages.first?.parts.first?.text?.contains("token299") == true)
    }

    // MARK: - Helper

    private func makeMsg(id: String, text: String) -> AIChatMessage {
        AIChatMessage(
            id: id,
            messageId: id,
            role: .assistant,
            parts: [AIChatPart(id: "\(id)-part", kind: .text, text: text)]
        )
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

// MARK: - 转录投影 store 在高频 delta 场景下的增量语义

/// 验证 AIChatTranscriptProjectionStore 在高频 delta flush 后正确复用 indexMap，
/// 避免 O(N) 重建。
final class TranscriptStoreHighFrequencyDeltaTests: XCTestCase {

    private func makeMsg(id: String, text: String, streaming: Bool = false) -> AIChatMessage {
        AIChatMessage(
            id: id,
            messageId: id,
            role: .assistant,
            parts: [AIChatPart(id: "\(id)-part", kind: .text, text: text)],
            isStreaming: streaming
        )
    }

    func testTailSyncAfter300DeltasReusesIndexMap() {
        let store = AIChatTranscriptProjectionStore()
        let messageCount = 100
        let messages = (0..<messageCount).map {
            makeMsg(id: "m\($0)", text: "initial-\($0)", streaming: $0 == messageCount - 1)
        }

        // 初始 fullRefresh
        let initialPlan = AIChatTranscriptRenderPlan(
            displayMessages: messages,
            refreshStrategy: .fullRefresh,
            fullRenderRange: nil,
            pendingAnchorID: nil
        )
        store.apply(plan: initialPlan, sourceCount: messageCount)

        let initialMap = store.projection.messageIndexMap
        XCTAssertEqual(initialMap.count, messageCount)

        // 模拟 300 次 delta flush 后的 tailSync：消息数不变，只有尾消息文本更新
        var updatedMessages = messages
        updatedMessages[messageCount - 1] = makeMsg(
            id: "m\(messageCount - 1)",
            text: "after-300-deltas",
            streaming: true
        )
        let tailPlan = AIChatTranscriptRenderPlan(
            displayMessages: updatedMessages,
            refreshStrategy: .tailSync,
            fullRenderRange: nil,
            pendingAnchorID: nil
        )
        store.apply(plan: tailPlan, sourceCount: messageCount)

        // tailSync 应复用 indexMap，不重建
        XCTAssertEqual(store.projection.messageIndexMap, initialMap,
                       "高频 delta 后的 tailSync 应复用 indexMap，避免 O(N) 重建")
        XCTAssertEqual(store.projection.displayMessages.last?.parts.first?.text, "after-300-deltas")
    }

    func testMultipleConsecutiveTailSyncsNeverRebuildIndexMap() {
        let store = AIChatTranscriptProjectionStore()
        let messages = (0..<50).map { makeMsg(id: "m\($0)", text: "v0", streaming: $0 == 49) }

        let initialPlan = AIChatTranscriptRenderPlan(
            displayMessages: messages,
            refreshStrategy: .fullRefresh,
            fullRenderRange: nil,
            pendingAnchorID: nil
        )
        store.apply(plan: initialPlan, sourceCount: 50)
        let baseMap = store.projection.messageIndexMap

        // 连续 10 次 tailSync
        for round in 1...10 {
            var msgs = messages
            msgs[49] = makeMsg(id: "m49", text: "v\(round)", streaming: true)
            let plan = AIChatTranscriptRenderPlan(
                displayMessages: msgs,
                refreshStrategy: .tailSync,
                fullRenderRange: nil,
                pendingAnchorID: nil
            )
            store.apply(plan: plan, sourceCount: 50)
            XCTAssertEqual(store.projection.messageIndexMap, baseMap,
                           "第 \(round) 次 tailSync 不应重建 indexMap")
        }
    }
}
