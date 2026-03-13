import XCTest
@testable import TidyFlow

/// 验证 AIChatShellProjectionInvalidationSignature 不再依赖 tailRevision 的回归用例。
///
/// 覆盖场景：
/// - tailRevision 增长但其他 shell 字段不变时，签名不变（不触发 projection 刷新）
/// - isStreaming、pendingQuestionVersion、abortPendingSessionId 等 shell 字段变化时，签名确实变化
/// - pendingQuestionCount 变化时签名变化（question/tool 状态更新应刷新 shell）
@MainActor
final class AIChatShellProjectionInvalidationTests: XCTestCase {

    // MARK: - tailRevision 变化不影响签名

    func testTailRevisionGrowthDoesNotChangSignature() {
        let base = makeInput(tailRevision: 10, isStreaming: false, pendingQuestionVersion: 0)
        let advanced = makeInput(tailRevision: 100, isStreaming: false, pendingQuestionVersion: 0)

        XCTAssertEqual(
            base.signature, advanced.signature,
            "tailRevision 增长不应改变 shell projection 签名（纯文本 token 增量不刷新 shell）"
        )
    }

    func testTailRevisionGrowthWithDifferentMessagesStillSameSignature() {
        // 即使 tailRevision 从 1 增长到 9999（流式输出全程），签名不变
        let before = makeInput(tailRevision: 1, isStreaming: true, pendingQuestionVersion: 0)
        let after = makeInput(tailRevision: 9999, isStreaming: true, pendingQuestionVersion: 0)

        XCTAssertEqual(
            before.signature, after.signature,
            "大量 tailRevision 递增不得触发签名变化"
        )
    }

    // MARK: - isStreaming 变化触发签名变化

    func testIsStreamingChangeTriggersSignatureChange() {
        let notStreaming = makeInput(tailRevision: 5, isStreaming: false, pendingQuestionVersion: 0)
        let streaming = makeInput(tailRevision: 5, isStreaming: true, pendingQuestionVersion: 0)

        XCTAssertNotEqual(
            notStreaming.signature, streaming.signature,
            "isStreaming 变化应触发签名变化（直接影响 composer 与 stop 按钮）"
        )
    }

    // MARK: - pendingQuestionVersion 变化触发签名变化

    func testPendingQuestionVersionChangeTriggersSignatureChange() {
        let before = makeInput(tailRevision: 5, isStreaming: false, pendingQuestionVersion: 0)
        let after = makeInput(tailRevision: 5, isStreaming: false, pendingQuestionVersion: 1)

        XCTAssertNotEqual(
            before.signature, after.signature,
            "pendingQuestionVersion 变化应触发签名变化（question/tool 卡片更新）"
        )
    }

    // MARK: - abortPendingSessionId 变化触发签名变化

    func testAbortPendingSessionIdChangeTriggersSignatureChange() {
        let before = makeInput(tailRevision: 5, isStreaming: false, pendingQuestionVersion: 0,
                               abortPendingSessionId: nil)
        let after = makeInput(tailRevision: 5, isStreaming: false, pendingQuestionVersion: 0,
                              abortPendingSessionId: "session-abort-1")

        XCTAssertNotEqual(
            before.signature, after.signature,
            "abortPendingSessionId 变化应触发签名变化（影响 streaming 状态展示）"
        )
    }

    // MARK: - scrollSessionToken 变化触发签名变化

    func testScrollSessionTokenChangeTriggersSignatureChange() {
        let before = makeInput(tailRevision: 5, isStreaming: false, pendingQuestionVersion: 0,
                               scrollSessionToken: 0)
        let after = makeInput(tailRevision: 5, isStreaming: false, pendingQuestionVersion: 0,
                              scrollSessionToken: 1)

        XCTAssertNotEqual(
            before.signature, after.signature,
            "scrollSessionToken 变化应触发签名变化"
        )
    }

    // MARK: - 签名稳定性：多字段同时不变时签名不变

    func testSignatureStableWhenAllShellFieldsUnchanged() {
        let a = makeInput(tailRevision: 1, isStreaming: false, pendingQuestionVersion: 0)
        let b = makeInput(tailRevision: 500, isStreaming: false, pendingQuestionVersion: 0)
        let c = makeInput(tailRevision: 9999, isStreaming: false, pendingQuestionVersion: 0)

        XCTAssertEqual(a.signature, b.signature)
        XCTAssertEqual(b.signature, c.signature)
    }

    // MARK: - 与 AIChatShellProjectionStore 集成

    func testProjectionStoreDoesNotRefreshOnTailRevisionOnlyChange() {
        let store = AIChatShellProjectionStore()
        let initial = makeInput(tailRevision: 0, isStreaming: false, pendingQuestionVersion: 0)
        store.refresh(initial)
        let projectionAfterInitial = store.projection

        // 仅 tailRevision 递增
        let updated = makeInput(tailRevision: 100, isStreaming: false, pendingQuestionVersion: 0)
        store.refresh(updated)

        XCTAssertEqual(
            store.projection, projectionAfterInitial,
            "仅 tailRevision 变化时 projection 不应更新（签名不变 → updateProjection 跳过）"
        )
    }

    func testProjectionStoreRefreshesOnIsStreamingChange() {
        let store = AIChatShellProjectionStore()
        let initial = makeInput(tailRevision: 5, isStreaming: false, pendingQuestionVersion: 0)
        store.refresh(initial)
        let projectionAfterInitial = store.projection

        let streaming = makeInput(tailRevision: 5, isStreaming: true, pendingQuestionVersion: 0)
        store.refresh(streaming)

        XCTAssertNotEqual(
            store.projection, projectionAfterInitial,
            "isStreaming 变化时 projection 应更新"
        )
    }

    // MARK: - Helper

    private func makeInput(
        tailRevision: UInt64,
        isStreaming: Bool,
        pendingQuestionVersion: UInt64,
        abortPendingSessionId: String? = nil,
        scrollSessionToken: Int = 0
    ) -> AIChatShellProjectionInput {
        AIChatShellProjectionInput(
            tool: .opencode,
            currentSessionId: "session-1",
            messages: [],
            recentHistoryIsLoading: false,
            historyHasMore: false,
            historyIsLoading: false,
            canSwitchTool: true,
            scrollSessionToken: scrollSessionToken,
            sessionStatus: nil,
            localIsStreaming: isStreaming,
            awaitingUserEcho: false,
            abortPendingSessionId: abortPendingSessionId,
            hasPendingFirstContent: false,
            pendingQuestions: [:],
            tailRevision: tailRevision,
            pendingQuestionVersion: pendingQuestionVersion
        )
    }
}
