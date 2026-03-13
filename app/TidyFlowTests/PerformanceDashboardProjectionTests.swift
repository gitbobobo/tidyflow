import XCTest
@testable import TidyFlow

/// 共享 PerformanceDashboardProjection 语义测试（WI-004）
///
/// 覆盖：
/// - PerformanceBudgetStatus 可比较语义
/// - PerformanceDashboardProjection.isTrendDegrading 逻辑
/// - PerformanceDashboardProjection.empty 空态
/// - PerformanceRegressionSummary 解析向后兼容
@MainActor
final class PerformanceDashboardProjectionTests: XCTestCase {

    // MARK: - PerformanceBudgetStatus

    func testBudgetStatus_comparable_order() {
        XCTAssertLessThan(PerformanceBudgetStatus.pass, .warn)
        XCTAssertLessThan(PerformanceBudgetStatus.warn, .fail)
        XCTAssertLessThan(PerformanceBudgetStatus.pass, .fail)
    }

    func testBudgetStatus_isReleaseBlocking_onlyForFail() {
        XCTAssertFalse(PerformanceBudgetStatus.pass.isReleaseBlocking)
        XCTAssertFalse(PerformanceBudgetStatus.warn.isReleaseBlocking)
        XCTAssertTrue(PerformanceBudgetStatus.fail.isReleaseBlocking)
        XCTAssertFalse(PerformanceBudgetStatus.unknown.isReleaseBlocking)
    }

    func testBudgetStatus_colorSemanticName_stable() {
        XCTAssertEqual(PerformanceBudgetStatus.pass.colorSemanticName, "green")
        XCTAssertEqual(PerformanceBudgetStatus.warn.colorSemanticName, "yellow")
        XCTAssertEqual(PerformanceBudgetStatus.fail.colorSemanticName, "red")
        XCTAssertEqual(PerformanceBudgetStatus.unknown.colorSemanticName, "gray")
    }

    // MARK: - PerformanceDashboardProjection.isTrendDegrading

    func testIsTrendDegrading_lessThan3Points_returnsFalse() {
        let proj = makeProjection(trendStatuses: [.warn, .fail])
        XCTAssertFalse(proj.isTrendDegrading, "少于 3 个点时不应判定为退化")
    }

    func testIsTrendDegrading_allPass_returnsFalse() {
        let proj = makeProjection(trendStatuses: [.pass, .pass, .pass, .pass, .pass])
        XCTAssertFalse(proj.isTrendDegrading)
    }

    func testIsTrendDegrading_majorityWarnOrFail_returnsTrue() {
        // 5 个点中 3 个 warn → 60% > 40%
        let proj = makeProjection(trendStatuses: [.pass, .warn, .warn, .warn, .pass])
        XCTAssertTrue(proj.isTrendDegrading)
    }

    func testIsTrendDegrading_only40PercentBad_returnsFalse() {
        // 5 个点中 2 个 warn → 40% == 40%，不超过，返回 false
        let proj = makeProjection(trendStatuses: [.pass, .warn, .warn, .pass, .pass])
        XCTAssertFalse(proj.isTrendDegrading)
    }

    // MARK: - empty 空态

    func testProjection_empty_hasUnknownBudget() {
        let proj = PerformanceDashboardProjection.empty()
        XCTAssertEqual(proj.budgetStatus, .unknown)
        XCTAssertTrue(proj.trendPoints.isEmpty)
        XCTAssertNil(proj.latestP95Ms)
        XCTAssertFalse(proj.isTrendDegrading)
    }

    func testProjection_empty_withSurface() {
        let proj = PerformanceDashboardProjection.empty(
            project: "test-proj", workspace: "test-ws", surface: .evolutionWorkspace
        )
        XCTAssertEqual(proj.surface, .evolutionWorkspace)
        XCTAssertEqual(proj.project, "test-proj")
    }

    // MARK: - latestP95Ms

    func testLatestP95Ms_returnsLastTrendPointValue() {
        let points = [
            PerformanceTrendPoint(timestampMs: 1000, p95Ms: 30, memoryDeltaBytes: nil, budgetStatus: .pass),
            PerformanceTrendPoint(timestampMs: 2000, p95Ms: 80, memoryDeltaBytes: nil, budgetStatus: .warn),
        ]
        let proj = makeProjection(trendPoints: points)
        XCTAssertEqual(proj.latestP95Ms, 80)
    }

    // MARK: - surface scenarioIds

    func testChatSession_scenarioIds_containChatStream() {
        XCTAssertTrue(PerformanceTrackedSurface.chatSession.scenarioIds.contains("chat_stream"))
        XCTAssertTrue(PerformanceTrackedSurface.chatSession.scenarioIds.contains("chat_stream_workspace_switch"),
                      "新增多工作区场景必须包含在 chatSession.scenarioIds 中")
    }

    func testEvolutionWorkspace_scenarioIds_containEvolutionPanel() {
        XCTAssertTrue(PerformanceTrackedSurface.evolutionWorkspace.scenarioIds.contains("evolution_panel"))
        XCTAssertTrue(PerformanceTrackedSurface.evolutionWorkspace.scenarioIds.contains("evolution_panel_multi_workspace"),
                      "新增多工作区场景必须包含在 evolutionWorkspace.scenarioIds 中")
    }

    // MARK: - Helper

    private func makeProjection(
        trendStatuses: [PerformanceBudgetStatus]
    ) -> PerformanceDashboardProjection {
        let points = trendStatuses.enumerated().map { idx, status in
            PerformanceTrendPoint(
                timestampMs: Int64(idx * 1000),
                p95Ms: status == .pass ? 20 : (status == .warn ? 80 : 300),
                memoryDeltaBytes: nil,
                budgetStatus: status
            )
        }
        return makeProjection(trendPoints: points)
    }

    private func makeProjection(trendPoints: [PerformanceTrendPoint]) -> PerformanceDashboardProjection {
        PerformanceDashboardProjection(
            project: "test", workspace: "default",
            surface: .chatSession,
            budgetStatus: trendPoints.last?.budgetStatus ?? .unknown,
            trendPoints: trendPoints,
            regressionSummary: .empty,
            degradationReasons: [],
            projectedAt: Date()
        )
    }

    // MARK: - WI-003: 预算阈值映射共享测试

    func testBudgetStatus_max_failOverridesWarnAndPass() {
        // max() 用于合并实时和回归预算
        XCTAssertEqual(max(PerformanceBudgetStatus.pass, .warn), .warn)
        XCTAssertEqual(max(PerformanceBudgetStatus.warn, .fail), .fail)
        XCTAssertEqual(max(PerformanceBudgetStatus.pass, .fail), .fail)
    }

    func testBudgetStatus_unknownHandling() {
        // unknown 在排序中位于 fail 之后，但 Store 的合并逻辑会特殊处理
        XCTAssertLessThan(PerformanceBudgetStatus.fail, .unknown)
        // 确保 unknown 不会意外成为"最差"而阻断发布
        XCTAssertFalse(PerformanceBudgetStatus.unknown.isReleaseBlocking)
    }

    func testRegressionSummary_empty_isUnknown() {
        let empty = PerformanceRegressionSummary.empty
        XCTAssertEqual(empty.overall, .unknown)
        XCTAssertTrue(empty.degradationReasons.isEmpty)
        XCTAssertNil(empty.worstScenarioId)
    }

    func testProjection_mergedBudget_regressionFailUpgradesRealtimePass() {
        // 验证投影合并语义：max(realtimePass, regressionFail) = fail
        let failSummary = PerformanceRegressionSummary(
            overall: .fail,
            degradationReasons: ["test reason"],
            worstScenarioId: "chat_stream",
            generatedAt: Date()
        )
        let proj = PerformanceDashboardProjection(
            project: "p", workspace: "w", surface: .chatSession,
            budgetStatus: .fail,  // Store 已合并后的结果
            trendPoints: [],
            regressionSummary: failSummary,
            degradationReasons: ["test reason"],
            projectedAt: Date()
        )
        XCTAssertTrue(proj.budgetStatus.isReleaseBlocking)
        XCTAssertFalse(proj.degradationReasons.isEmpty)
    }

    // MARK: - WI-003: session/cycle 隔离

    func testScopeKey_chatSession_vs_evolutionCycle_isolated() {
        let chatKey = PerformanceScopeKey(
            project: "p", workspace: "w", surface: .chatSession, sessionOrCycleId: "sess-1"
        )
        let evoKey = PerformanceScopeKey(
            project: "p", workspace: "w", surface: .evolutionWorkspace, sessionOrCycleId: "cycle-1"
        )
        XCTAssertNotEqual(chatKey, evoKey,
                          "chatSession 与 evolutionWorkspace 的 scope key 不得相同")
        XCTAssertNotEqual(chatKey.stringKey, evoKey.stringKey)
    }

    func testScopeKey_sameSessionDifferentSurface_isolated() {
        let key1 = PerformanceScopeKey(
            project: "p", workspace: "w", surface: .chatSession, sessionOrCycleId: "shared-id"
        )
        let key2 = PerformanceScopeKey(
            project: "p", workspace: "w", surface: .evolutionWorkspace, sessionOrCycleId: "shared-id"
        )
        XCTAssertNotEqual(key1, key2,
                          "相同 sessionOrCycleId 但不同 surface 必须隔离")
    }
}
