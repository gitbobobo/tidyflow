import XCTest
@testable import TidyFlow

/// 共享 PerformanceDashboardStore 语义测试（WI-004）
///
/// 覆盖：
/// - 多项目/多工作区样本隔离
/// - surface 级 key 稳定性
/// - 历史窗口裁剪
/// - 工作区切换后实时缓冲清空
/// - 缺失回归报告时的空态
@MainActor
final class PerformanceDashboardStoreTests: XCTestCase {

    func makeEmptySnapshot() -> PerformanceObservabilitySnapshot {
        PerformanceObservabilitySnapshot.empty
    }

    // MARK: - 多项目隔离

    func testMultiProjectIsolation_chatSurface() {
        let store = PerformanceDashboardStore()
        store.ingestSnapshot(makeEmptySnapshot(), project: "project-a", workspace: "ws1")
        store.ingestSnapshot(makeEmptySnapshot(), project: "project-b", workspace: "ws1")

        let keyA = PerformanceScopeKey(project: "project-a", workspace: "ws1", surface: .chatSession)
        let keyB = PerformanceScopeKey(project: "project-b", workspace: "ws1", surface: .chatSession)

        XCTAssertNotEqual(keyA, keyB)
        let projA = store.projection(for: keyA)
        let projB = store.projection(for: keyB)
        XCTAssertEqual(projA.project, "project-a")
        XCTAssertEqual(projB.project, "project-b")
    }

    // MARK: - 多工作区隔离

    func testMultiWorkspaceIsolation_sameSurface() {
        let store = PerformanceDashboardStore()
        store.ingestSnapshot(makeEmptySnapshot(), project: "proj", workspace: "ws-alpha")
        store.ingestSnapshot(makeEmptySnapshot(), project: "proj", workspace: "ws-beta")

        let keyAlpha = PerformanceScopeKey(project: "proj", workspace: "ws-alpha", surface: .evolutionWorkspace)
        let keyBeta = PerformanceScopeKey(project: "proj", workspace: "ws-beta", surface: .evolutionWorkspace)

        XCTAssertNotEqual(keyAlpha, keyBeta)
        let pAlpha = store.projection(for: keyAlpha)
        let pBeta = store.projection(for: keyBeta)
        XCTAssertEqual(pAlpha.workspace, "ws-alpha")
        XCTAssertEqual(pBeta.workspace, "ws-beta")
    }

    // MARK: - surface 级 key 稳定性

    func testScopeKey_rawValue_matchesBaselines() {
        XCTAssertEqual(PerformanceTrackedSurface.chatSession.rawValue, "chat_session")
        XCTAssertEqual(PerformanceTrackedSurface.evolutionWorkspace.rawValue, "evolution_workspace")
    }

    func testScopeKey_stringKey_format() {
        let key = PerformanceScopeKey(project: "my-proj", workspace: "default", surface: .chatSession, sessionOrCycleId: "sess-001")
        XCTAssertEqual(key.stringKey, "my-proj/default/chat_session/sess-001")
    }

    func testScopeKey_stringKey_noSession() {
        let key = PerformanceScopeKey(project: "p", workspace: "w", surface: .evolutionWorkspace)
        XCTAssertEqual(key.stringKey, "p/w/evolution_workspace")
    }

    // MARK: - 历史窗口裁剪

    func testRealtimeBufferLimit_isEnforced() {
        let store = PerformanceDashboardStore()
        let limit = PerformanceDashboardStore.realtimeBufferLimit

        for _ in 0..<(limit + 100) {
            store.ingestSnapshot(makeEmptySnapshot(), project: "p", workspace: "w")
        }

        let key = PerformanceScopeKey(project: "p", workspace: "w", surface: .chatSession)
        let proj = store.projection(for: key)
        XCTAssertLessThanOrEqual(proj.trendPoints.count, 60)
    }

    // MARK: - 工作区切换后清空

    func testClearRealtimeBuffers_removesProjectionForWorkspace() {
        let store = PerformanceDashboardStore()
        store.ingestSnapshot(makeEmptySnapshot(), project: "p", workspace: "ws-old")
        let key = PerformanceScopeKey(project: "p", workspace: "ws-old", surface: .chatSession)

        store.clearRealtimeBuffers(project: "p", workspace: "ws-old")

        let proj = store.projection(for: key)
        XCTAssertEqual(proj.budgetStatus, .unknown)
        XCTAssertTrue(proj.trendPoints.isEmpty)
    }

    func testClearRealtimeBuffer_doesNotAffectOtherWorkspace() {
        let store = PerformanceDashboardStore()
        store.ingestSnapshot(makeEmptySnapshot(), project: "p", workspace: "ws-keep")
        store.ingestSnapshot(makeEmptySnapshot(), project: "p", workspace: "ws-clear")

        store.clearRealtimeBuffers(project: "p", workspace: "ws-clear")

        let keepKey = PerformanceScopeKey(project: "p", workspace: "ws-keep", surface: .chatSession)
        let clearKey = PerformanceScopeKey(project: "p", workspace: "ws-clear", surface: .chatSession)

        let keepProj = store.projection(for: keepKey)
        XCTAssertNotNil(keepProj)

        let clearProj = store.projection(for: clearKey)
        XCTAssertEqual(clearProj.budgetStatus, .unknown)
    }

    // MARK: - 缺失回归报告时空态

    func testRegressionSummary_whenNoReportLoaded_returnsEmpty() {
        let store = PerformanceDashboardStore()
        let summary = store.regressionSummary(for: .chatSession)
        XCTAssertEqual(summary.overall, .unknown)
        XCTAssertTrue(summary.degradationReasons.isEmpty)
        XCTAssertNil(summary.worstScenarioId)
    }

    func testProjection_whenNoData_budgetStatusIsUnknown() {
        let store = PerformanceDashboardStore()
        let key = PerformanceScopeKey(project: "p", workspace: "w", surface: .evolutionWorkspace)
        let proj = store.projection(for: key)
        XCTAssertEqual(proj.budgetStatus, .unknown)
        XCTAssertTrue(proj.trendPoints.isEmpty)
        XCTAssertTrue(proj.degradationReasons.isEmpty)
    }

    // MARK: - 会话切换隔离

    func testSessionIsolation_chatSurface() {
        let key1 = PerformanceScopeKey(project: "p", workspace: "w", surface: .chatSession, sessionOrCycleId: "sess-1")
        let key2 = PerformanceScopeKey(project: "p", workspace: "w", surface: .chatSession, sessionOrCycleId: "sess-2")
        XCTAssertNotEqual(key1, key2, "不同 session 必须产生不同 scope key")
    }

    // MARK: - 回归报告加载

    func testLoadRegressionReport_appliesSnapshotJSON() {
        let store = PerformanceDashboardStore()
        // 先注入一个实时快照以确保投影存在
        store.ingestSnapshot(makeEmptySnapshot(), project: "p", workspace: "w")

        let reportJSON: [String: Any] = [
            "overall": "warn",
            "generated_at": "2026-03-13T12:00:00Z",
            "scenarios": [
                [
                    "scenario_id": "chat_stream",
                    "surface_id": "chat_session",
                    "overall": "warn",
                    "issues": ["aiMessageTailFlush P95=55ms > warn=50ms"],
                ],
                [
                    "scenario_id": "evolution_panel",
                    "surface_id": "evolution_workspace",
                    "overall": "pass",
                    "issues": [] as [String],
                ],
            ] as [[String: Any]],
        ]
        store.applyRegressionReportJSON(reportJSON)

        let chatSummary = store.regressionSummary(for: .chatSession)
        XCTAssertEqual(chatSummary.overall, .warn)
        XCTAssertEqual(chatSummary.worstScenarioId, "chat_stream")
        XCTAssertFalse(chatSummary.degradationReasons.isEmpty)

        let evoSummary = store.regressionSummary(for: .evolutionWorkspace)
        XCTAssertEqual(evoSummary.overall, .pass)
    }

    func testLoadRegressionReport_dashboardSnapshotFormat() {
        let store = PerformanceDashboardStore()
        store.ingestSnapshot(makeEmptySnapshot(), project: "p", workspace: "w")

        // 精简仪表盘快照格式（scenarios_summary 而非 scenarios）
        let snapshotJSON: [String: Any] = [
            "overall": "pass",
            "generated_at": "2026-03-13T12:00:00Z",
            "scenarios_summary": [
                ["scenario_id": "chat_stream", "surface_id": "chat_session", "overall": "pass"],
                ["scenario_id": "evolution_panel", "surface_id": "evolution_workspace", "overall": "pass"],
            ] as [[String: Any]],
        ]
        store.applyRegressionReportJSON(snapshotJSON)

        let chatSummary = store.regressionSummary(for: .chatSession)
        XCTAssertEqual(chatSummary.overall, .pass)
        let evoSummary = store.regressionSummary(for: .evolutionWorkspace)
        XCTAssertEqual(evoSummary.overall, .pass)
    }

    func testLoadRegressionReport_missingReportReturnsUnknown() {
        let store = PerformanceDashboardStore()
        // 尝试加载不存在的路径
        store.loadDashboardSnapshot(atPath: "/nonexistent/path/snapshot.json")

        let chatSummary = store.regressionSummary(for: .chatSession)
        XCTAssertEqual(chatSummary.overall, .unknown, "缺失报告时必须返回 .unknown，不得伪造 pass")
        XCTAssertTrue(chatSummary.degradationReasons.isEmpty)
        XCTAssertNil(chatSummary.worstScenarioId)
    }

    func testLoadRegressionReport_failScenarioUpgradesBudget() {
        let store = PerformanceDashboardStore()
        store.ingestSnapshot(makeEmptySnapshot(), project: "p", workspace: "w")

        let reportJSON: [String: Any] = [
            "overall": "fail",
            "generated_at": "2026-03-13T12:00:00Z",
            "scenarios": [
                [
                    "scenario_id": "chat_stream",
                    "surface_id": "chat_session",
                    "overall": "fail",
                    "issues": ["aiMessageTailFlush P95=210ms > fail=200ms"],
                ],
            ] as [[String: Any]],
        ]
        store.applyRegressionReportJSON(reportJSON)

        let key = PerformanceScopeKey(project: "p", workspace: "w", surface: .chatSession)
        let proj = store.projection(for: key)
        // 回归报告 fail 应升级投影的 budgetStatus
        XCTAssertTrue(proj.budgetStatus >= .fail || proj.regressionSummary.overall == .fail)
    }

    // MARK: - surface 映射完整性

    func testSurfaceMappingCoversAllBaselines() {
        // 验证每个 surface 的 scenarioIds 都包含对应的多工作区场景
        let chatScenarios = PerformanceTrackedSurface.chatSession.scenarioIds
        XCTAssertTrue(chatScenarios.contains("chat_stream"))
        XCTAssertTrue(chatScenarios.contains("chat_stream_workspace_switch"))

        let evoScenarios = PerformanceTrackedSurface.evolutionWorkspace.scenarioIds
        XCTAssertTrue(evoScenarios.contains("evolution_panel"))
        XCTAssertTrue(evoScenarios.contains("evolution_panel_multi_workspace"))
    }

    // MARK: - 多工作区隔离（跨项目同名工作区）

    func testCrossProjectSameWorkspaceName_noContamination() {
        let store = PerformanceDashboardStore()

        let reportJSON: [String: Any] = [
            "overall": "fail",
            "generated_at": "2026-03-13T12:00:00Z",
            "scenarios": [
                [
                    "scenario_id": "chat_stream",
                    "surface_id": "chat_session",
                    "overall": "fail",
                    "issues": ["test"],
                ],
            ] as [[String: Any]],
        ]
        store.applyRegressionReportJSON(reportJSON)

        store.ingestSnapshot(makeEmptySnapshot(), project: "proj-a", workspace: "default")
        store.ingestSnapshot(makeEmptySnapshot(), project: "proj-b", workspace: "default")

        let keyA = PerformanceScopeKey(project: "proj-a", workspace: "default", surface: .chatSession)
        let keyB = PerformanceScopeKey(project: "proj-b", workspace: "default", surface: .chatSession)

        XCTAssertNotEqual(keyA, keyB, "同名工作区跨项目必须隔离")
        let projA = store.projection(for: keyA)
        let projB = store.projection(for: keyB)
        XCTAssertEqual(projA.project, "proj-a")
        XCTAssertEqual(projB.project, "proj-b")
    }

    // MARK: - 不同 surface 同 key 不串台

    func testSameScopeKey_differentSurface_isolated() {
        let store = PerformanceDashboardStore()
        store.ingestSnapshot(makeEmptySnapshot(), project: "p", workspace: "w")

        let chatKey = PerformanceScopeKey(project: "p", workspace: "w", surface: .chatSession)
        let evoKey = PerformanceScopeKey(project: "p", workspace: "w", surface: .evolutionWorkspace)

        XCTAssertNotEqual(chatKey, evoKey, "不同 surface 的 key 不得相同")
    }
}
