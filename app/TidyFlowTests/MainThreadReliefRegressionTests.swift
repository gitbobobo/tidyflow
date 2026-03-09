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
            appState.wsClient.disconnect()
            appState.coreProcessManager.stop()
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
