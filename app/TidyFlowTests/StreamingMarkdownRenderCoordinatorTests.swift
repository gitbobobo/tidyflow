import XCTest
@testable import TidyFlow

/// 覆盖 AIChatStreamingRenderCoordinator 行为的单元测试。
///
/// 验证场景：
/// - 注册/注销 partId 与 tick 管理生命周期
/// - 流结束时最终态提交并写入 finalizedParts
/// - consumeFinalized 清除已消费条目
/// - 多个 partId 同时注册时 registeredCount 正确
@MainActor
final class StreamingMarkdownRenderCoordinatorTests: XCTestCase {

    // MARK: - 注册与 registeredCount

    func testRegisterIncreasesRegisteredCount() async {
        let coordinator = AIChatStreamingRenderCoordinator()
        XCTAssertEqual(coordinator.registeredCount, 0)

        coordinator.registerStreaming(partId: "p1")
        XCTAssertEqual(coordinator.registeredCount, 1)

        coordinator.registerStreaming(partId: "p2")
        XCTAssertEqual(coordinator.registeredCount, 2)
    }

    func testUnregisterDecreasesRegisteredCount() async {
        let coordinator = AIChatStreamingRenderCoordinator()
        coordinator.registerStreaming(partId: "p1")
        coordinator.registerStreaming(partId: "p2")

        coordinator.unregisterStreaming(partId: "p1")
        XCTAssertEqual(coordinator.registeredCount, 1)

        coordinator.unregisterStreaming(partId: "p2")
        XCTAssertEqual(coordinator.registeredCount, 0)
    }

    func testRegisterWithEmptyPartIdIsNoOp() async {
        let coordinator = AIChatStreamingRenderCoordinator()
        coordinator.registerStreaming(partId: "")
        XCTAssertEqual(coordinator.registeredCount, 0, "空 partId 不应注册")
    }

    // MARK: - 重复注册同一 partId

    func testRegisteringSamePartIdIsIdempotent() async {
        let coordinator = AIChatStreamingRenderCoordinator()
        coordinator.registerStreaming(partId: "p1")
        coordinator.registerStreaming(partId: "p1")
        // Set 语义：重复注册不增加计数
        XCTAssertEqual(coordinator.registeredCount, 1)
    }

    // MARK: - 最终态提交

    func testCommitFinalTextWritesToFinalizedParts() async {
        let coordinator = AIChatStreamingRenderCoordinator()
        coordinator.registerStreaming(partId: "p1")
        coordinator.commitFinalText(partId: "p1", text: "final content")

        XCTAssertEqual(coordinator.finalizedParts["p1"], "final content",
                        "commitFinalText 后 finalizedParts 应包含最终文本")
    }

    func testCommitFinalTextRemovesFromRegistered() async {
        let coordinator = AIChatStreamingRenderCoordinator()
        coordinator.registerStreaming(partId: "p1")
        coordinator.registerStreaming(partId: "p2")
        coordinator.commitFinalText(partId: "p1", text: "done")

        XCTAssertEqual(coordinator.registeredCount, 1, "commitFinalText 后 p1 应从注册集合移除")
    }

    func testCommitFinalTextWithEmptyPartIdIsNoOp() async {
        let coordinator = AIChatStreamingRenderCoordinator()
        coordinator.commitFinalText(partId: "", text: "text")
        XCTAssertTrue(coordinator.finalizedParts.isEmpty)
    }

    // MARK: - consumeFinalized

    func testConsumeFinalizedClearsEntry() async {
        let coordinator = AIChatStreamingRenderCoordinator()
        coordinator.commitFinalText(partId: "p1", text: "result")
        XCTAssertNotNil(coordinator.finalizedParts["p1"])

        coordinator.consumeFinalized(partId: "p1")
        XCTAssertNil(coordinator.finalizedParts["p1"], "consumeFinalized 后条目应被清除")
    }

    func testConsumeFinalizedForUnknownPartIdIsNoOp() async {
        let coordinator = AIChatStreamingRenderCoordinator()
        coordinator.consumeFinalized(partId: "non-existent")
        XCTAssertTrue(coordinator.finalizedParts.isEmpty, "消费不存在的 partId 不应崩溃")
    }

    // MARK: - tick 生命周期

    func testTickCountIncrementsAfterRegistration() async throws {
        let coordinator = AIChatStreamingRenderCoordinator()
        coordinator.registerStreaming(partId: "p1")

        let before = coordinator.tickCount
        // 等待至少一个 tick 间隔（40ms）
        try await Task.sleep(for: .milliseconds(120))
        let after = coordinator.tickCount

        XCTAssertGreaterThan(after, before, "注册后协调器 tick 应开始递增")
    }

    func testTickStopsAfterAllUnregistered() async throws {
        let coordinator = AIChatStreamingRenderCoordinator()
        coordinator.registerStreaming(partId: "p1")

        try await Task.sleep(for: .milliseconds(80))
        let tickBeforeUnregister = coordinator.tickCount

        coordinator.unregisterStreaming(partId: "p1")
        try await Task.sleep(for: .milliseconds(120))
        let tickAfterUnregister = coordinator.tickCount

        XCTAssertEqual(
            tickBeforeUnregister, tickAfterUnregister,
            "注销所有 part 后 tick 应停止"
        )
    }

    func testTickStopsAfterAllPartsFinalCommitted() async throws {
        let coordinator = AIChatStreamingRenderCoordinator()
        coordinator.registerStreaming(partId: "p1")
        coordinator.registerStreaming(partId: "p2")

        try await Task.sleep(for: .milliseconds(80))

        coordinator.commitFinalText(partId: "p1", text: "done1")
        coordinator.commitFinalText(partId: "p2", text: "done2")

        let tickAfterCommit = coordinator.tickCount
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(
            tickAfterCommit, coordinator.tickCount,
            "全部 part 提交最终态后 tick 应停止"
        )
    }

    // MARK: - 流式结束场景集成

    func testStreamEndSetsupFinalizedPartImmediately() async {
        let coordinator = AIChatStreamingRenderCoordinator()
        coordinator.registerStreaming(partId: "stream-part")
        coordinator.commitFinalText(partId: "stream-part", text: "Stream finished text")

        XCTAssertEqual(
            coordinator.finalizedParts["stream-part"],
            "Stream finished text",
            "流结束后最终文本应立即出现在 finalizedParts"
        )
        XCTAssertEqual(coordinator.registeredCount, 0,
                        "流结束后 part 应从注册集合移除")
    }
}
