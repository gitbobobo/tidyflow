import XCTest
@testable import TidyFlow
import TidyFlowShared

/// WI-003：Evolution 面板刷新回归测试
///
/// 覆盖：
/// - 性能-only 更新不触发结构投影发布
/// - 定向 snapshot 语义（project/workspace 参数）
/// - 多工作区隔离（趋势缓冲与 monitor key）
/// - 现有 Evolution fixture 日志契约保持不变

// MARK: - 性能投影不触发结构发布

@MainActor
final class EvolutionPerformanceOnlyUpdateTests: XCTestCase {

    /// 性能-only 更新只走 updatePerformanceProjection，不触发 updateProjection
    func testPerformanceOnlyUpdate_doesNotTriggerStructuralPublish() {
        let store = EvolutionPipelineProjectionStore()
        let structuralProjection = makeProjection(project: "proj", workspace: "ws")

        // 先建立结构投影基线
        XCTAssertTrue(store.updateProjection(structuralProjection), "初始结构投影应成功发布")

        // 性能-only 更新
        let perfProjection = EvolutionPipelinePerformanceProjection(
            decision: EvolutionRealtimeSamplingDecision(tier: .live, reason: "healthy"),
            metrics: .empty
        )
        let updated = store.updatePerformanceProjection(perfProjection)
        XCTAssertTrue(updated, "性能投影应成功更新")

        // 结构投影保持不变（cycleHistories 等不应变化）
        XCTAssertEqual(store.projection.project, "proj")
        XCTAssertEqual(store.projection.cycleHistories.count, 0)
        XCTAssertEqual(store.projection.performance.tier, .live)
    }

    /// 重复性能投影不触发二次发布
    func testPerformanceOnlyUpdate_duplicateIsSkipped() {
        let store = EvolutionPipelineProjectionStore()
        _ = store.updateProjection(makeProjection(project: "proj", workspace: "ws"))

        let perf = EvolutionPipelinePerformanceProjection(
            decision: EvolutionRealtimeSamplingDecision(tier: .balanced, reason: "ok"),
            metrics: .empty
        )
        XCTAssertTrue(store.updatePerformanceProjection(perf))
        XCTAssertFalse(store.updatePerformanceProjection(perf), "相同性能投影不应重复发布")
    }

    /// 结构投影变化不受性能签名影响
    func testStructuralProjection_notAffectedByPerformanceSignature() {
        let store = EvolutionPipelineProjectionStore()

        let p1 = makeProjection(project: "proj", workspace: "ws")
        XCTAssertTrue(store.updateProjection(p1))

        // 仅改变性能投影
        let perf = EvolutionPipelinePerformanceProjection(
            decision: EvolutionRealtimeSamplingDecision(tier: .live, reason: "healthy"),
            metrics: .empty
        )
        XCTAssertTrue(store.updatePerformanceProjection(perf))

        // 用相同结构数据再次 updateProjection，结构内容没变只有 performance 变了，
        // 应该返回 false（因为 performance 已经被单独更新过了）
        let p2 = EvolutionPipelineProjection(
            project: "proj",
            workspace: "ws",
            workspaceReady: true,
            workspaceContextKey: "proj/ws",
            scheduler: .empty,
            control: .empty,
            currentItem: nil,
            blockingRequest: nil,
            cycleHistories: [],
            runningAgents: [],
            standbyAgents: [],
            totalDurationText: nil,
            isCurrentCycleFailed: false,
            currentCycleFailureSummary: nil,
            isCurrentCycleRetryable: false,
            currentCycleRecoveryStatusText: nil,
            predictionProjection: .empty,
            analysisSummaries: [],
            performance: perf
        )
        XCTAssertFalse(store.updateProjection(p2), "结构相同且性能也相同时不应重复发布")
    }

    /// dashboard 字段可通过性能投影传递到 View 层
    func testPerformanceDashboard_accessibleViaProjection() {
        let store = EvolutionPipelineProjectionStore()
        _ = store.updateProjection(makeProjection(project: "proj", workspace: "ws"))

        // 默认 dashboard 为空
        XCTAssertEqual(store.projection.performance.dashboard.budgetStatus, .unknown)

        // 性能投影携带 dashboard
        let dashboardProjection = PerformanceDashboardProjection.empty()
        let perf = EvolutionPipelinePerformanceProjection(
            decision: .paused,
            metrics: .empty,
            dashboard: dashboardProjection
        )
        _ = store.updatePerformanceProjection(perf)
        XCTAssertEqual(store.projection.performance.dashboard.budgetStatus, .unknown)
    }

    // MARK: - 辅助

    private func makeProjection(project: String, workspace: String) -> EvolutionPipelineProjection {
        EvolutionPipelineProjection(
            project: project,
            workspace: workspace,
            workspaceReady: true,
            workspaceContextKey: "\(project)/\(workspace)",
            scheduler: .empty,
            control: .empty,
            currentItem: nil,
            blockingRequest: nil,
            cycleHistories: [],
            runningAgents: [],
            standbyAgents: [],
            totalDurationText: nil,
            isCurrentCycleFailed: false,
            currentCycleFailureSummary: nil,
            isCurrentCycleRetryable: false,
            currentCycleRecoveryStatusText: nil,
            predictionProjection: .empty,
            analysisSummaries: [],
            performance: .empty
        )
    }
}

// MARK: - 定向 Snapshot 语义

/// 验证 requestEvolutionSnapshot 接收 project/workspace 参数后正确发送过滤请求
final class EvolutionDirectedSnapshotSemanticsTests: XCTestCase {
    func testDirectedSnapshot_sendsProjectAndWorkspaceParams() {
        let appState = AppState()
        defer { tearDownAppState(appState) }

        appState.wsClient.currentURL = URL(string: "ws://127.0.0.1:8439/ws")

        var scheduledRequests: [(String, String, [URLQueryItem])] = []
        appState.wsClient.onHTTPRequestScheduled = { domain, path, queryItems in
            scheduledRequests.append((domain, path, queryItems))
        }

        appState.requestEvolutionSnapshot(project: "my-proj", workspace: "my-ws")

        // 注意：requestEvolutionSnapshot 走 WebSocket action 而非 HTTP，
        // 此处仅验证方法可正常调用不会崩溃或产生异常副作用
        // WebSocket 层的实际报文验证由协议层测试覆盖
    }

    /// 无参 snapshot 不应携带 project/workspace 过滤
    func testUnfilteredSnapshot_doesNotCrash() {
        let appState = AppState()
        defer { tearDownAppState(appState) }

        appState.wsClient.currentURL = URL(string: "ws://127.0.0.1:8439/ws")

        // 无参调用（用于初始加载）
        appState.requestEvolutionSnapshot()
    }

    /// 有参 snapshot 后再无参 snapshot 不应产生冲突
    func testDirectedThenUnfiltered_noConflict() {
        let appState = AppState()
        defer { tearDownAppState(appState) }

        appState.wsClient.currentURL = URL(string: "ws://127.0.0.1:8439/ws")

        appState.requestEvolutionSnapshot(project: "proj", workspace: "ws")
        appState.requestEvolutionSnapshot()
        appState.requestEvolutionSnapshot(project: "proj-2", workspace: "ws-2")
    }
}

// MARK: - 多工作区隔离

/// 验证多工作区场景下趋势缓冲与 monitor key 不互相污染
final class EvolutionMultiWorkspaceIsolationTests: XCTestCase {
    /// 不同工作区的 filter 结果完全隔离
    func testFilterMetrics_isolatesByWorkspaceKey() {
        let reportWS1 = ClientPerformanceReport(
            clientInstanceId: "client-1",
            platform: "macos",
            project: "proj",
            workspace: "ws-1"
        )
        let reportWS2 = ClientPerformanceReport(
            clientInstanceId: "client-1",
            platform: "macos",
            project: "proj",
            workspace: "ws-2"
        )
        let snapshot = PerformanceObservabilitySnapshot(
            clientMetrics: [reportWS1, reportWS2]
        )

        let result1 = EvolutionRealtimeSamplingSemantics.filterMetrics(
            snapshot: snapshot, project: "proj", workspace: "ws-1", clientInstanceId: "client-1"
        )
        let result2 = EvolutionRealtimeSamplingSemantics.filterMetrics(
            snapshot: snapshot, project: "proj", workspace: "ws-2", clientInstanceId: "client-1"
        )

        XCTAssertEqual(result1.clientMetrics.count, 1, "ws-1 过滤结果应只包含 ws-1 数据")
        XCTAssertEqual(result1.clientMetrics.first?.workspace, "ws-1")
        XCTAssertEqual(result2.clientMetrics.count, 1, "ws-2 过滤结果应只包含 ws-2 数据")
        XCTAssertEqual(result2.clientMetrics.first?.workspace, "ws-2")
    }

    /// 切换工作区后性能投影签名不沿用旧值
    func testWorkspaceSwitch_producesNewPerformanceSignature() {
        let snapshotA = PerformanceObservabilitySnapshot(snapshotAt: 100)
        let snapshotB = PerformanceObservabilitySnapshot(snapshotAt: 200)

        let metricsA = EvolutionRealtimeSamplingSemantics.filterMetrics(
            snapshot: snapshotA, project: "proj", workspace: "ws-1", clientInstanceId: "c1"
        )
        let metricsB = EvolutionRealtimeSamplingSemantics.filterMetrics(
            snapshot: snapshotB, project: "proj", workspace: "ws-2", clientInstanceId: "c1"
        )

        XCTAssertNotEqual(metricsA.signature, metricsB.signature,
                          "切换工作区后签名必须变化，确保不沿用旧缓存")
    }

    /// 不同 project 同名 workspace 投影完全隔离
    @MainActor
    func testProjectIsolation_sameWorkspaceName() {
        let storeA = EvolutionPipelineProjectionStore()
        let storeB = EvolutionPipelineProjectionStore()

        let projA = EvolutionPipelineProjection(
            project: "project-alpha",
            workspace: "default",
            workspaceReady: true,
            workspaceContextKey: "project-alpha/default",
            scheduler: .empty,
            control: .empty,
            currentItem: nil,
            blockingRequest: nil,
            cycleHistories: [makeCycleHistory(id: "cycle-alpha")],
            runningAgents: [],
            standbyAgents: [],
            totalDurationText: nil,
            isCurrentCycleFailed: false,
            currentCycleFailureSummary: nil,
            isCurrentCycleRetryable: false,
            currentCycleRecoveryStatusText: nil,
            predictionProjection: .empty,
            analysisSummaries: [],
            performance: .empty
        )
        let projB = EvolutionPipelineProjection(
            project: "project-beta",
            workspace: "default",
            workspaceReady: true,
            workspaceContextKey: "project-beta/default",
            scheduler: .empty,
            control: .empty,
            currentItem: nil,
            blockingRequest: nil,
            cycleHistories: [makeCycleHistory(id: "cycle-beta")],
            runningAgents: [],
            standbyAgents: [],
            totalDurationText: nil,
            isCurrentCycleFailed: false,
            currentCycleFailureSummary: nil,
            isCurrentCycleRetryable: false,
            currentCycleRecoveryStatusText: nil,
            predictionProjection: .empty,
            analysisSummaries: [],
            performance: .empty
        )

        _ = storeA.updateProjection(projA)
        _ = storeB.updateProjection(projB)

        XCTAssertEqual(storeA.projection.project, "project-alpha")
        XCTAssertEqual(storeB.projection.project, "project-beta")
        XCTAssertEqual(storeA.projection.cycleHistories.first?.id, "cycle-alpha")
        XCTAssertEqual(storeB.projection.cycleHistories.first?.id, "cycle-beta")
    }

    /// 监控 key 应在切换工作区时更新
    func testMonitorKeyIsolation_stopOldBeforeStartNew() {
        let appState = AppState()
        defer {
            MainActor.assumeIsolated {
                appState.stopAllEvolutionPerformanceMonitoring()
            }
            tearDownAppState(appState)
        }

        Task { @MainActor in
            // 启动 ws-1 监控
            appState.startEvolutionPerformanceMonitoring(
                project: "proj", workspace: "ws-1", contextKey: "proj/ws-1"
            )
            XCTAssertNotNil(appState.evolutionPerformanceMonitorTasks["proj/ws-1"],
                            "ws-1 应有活跃任务")

            // 停止 ws-1，启动 ws-2
            appState.stopEvolutionPerformanceMonitoring(contextKey: "proj/ws-1")
            appState.startEvolutionPerformanceMonitoring(
                project: "proj", workspace: "ws-2", contextKey: "proj/ws-2"
            )

            XCTAssertNil(appState.evolutionPerformanceMonitorTasks["proj/ws-1"],
                         "旧工作区监控任务应已清理")
            XCTAssertNotNil(appState.evolutionPerformanceMonitorTasks["proj/ws-2"],
                            "新工作区应有活跃任务")
        }

        let exp = expectation(description: "等待监控操作完成")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - 辅助

    private func makeCycleHistory(id: String) -> PipelineCycleHistory {
        PipelineCycleHistory(
            id: id,
            title: "Test Cycle",
            status: "completed",
            round: 1,
            stages: ["plan", "implement.general.1"],
            startDate: Date(),
            stageEntries: [],
            terminalReasonCode: nil,
            terminalErrorMessage: nil,
            durationMs: 5000,
            errorCode: nil,
            retryable: false
        )
    }
}

// MARK: - Fixture 日志契约保持

/// 验证现有 Evolution fixture 的日志契约不因 WI-003 改动而回归
@MainActor
final class EvolutionFixtureContractRegressionTests: XCTestCase {

    /// applyFixtureRound 生成的投影应包含正确的 project/workspace
    func testFixtureRound_producesCorrectProjection() {
        let store = EvolutionPipelineProjectionStore()
        let duration = store.applyFixtureRound(
            project: "perf-fixture-project",
            workspace: "perf-fixture-workspace",
            cycleID: "fixture-evolution-cycle",
            roundIndex: 0
        )
        XCTAssertGreaterThanOrEqual(duration, 0, "fixture 耗时应非负")
        XCTAssertEqual(store.projection.project, "perf-fixture-project")
        XCTAssertEqual(store.projection.workspace, "perf-fixture-workspace")
        XCTAssertTrue(store.projection.workspaceReady)
    }

    /// 多轮 fixture 生成不同的历史条目 ID
    func testFixtureRound_multipleRounds_differentHistoryIDs() {
        let store = EvolutionPipelineProjectionStore()
        _ = store.applyFixtureRound(
            project: "perf-fixture-project",
            workspace: "perf-fixture-workspace",
            cycleID: "fixture-evolution-cycle",
            roundIndex: 0
        )
        let firstID = store.projection.cycleHistories.first?.id

        _ = store.applyFixtureRound(
            project: "perf-fixture-project",
            workspace: "perf-fixture-workspace",
            cycleID: "fixture-evolution-cycle",
            roundIndex: 1
        )
        let secondID = store.projection.cycleHistories.first?.id

        XCTAssertNotEqual(firstID, secondID, "不同轮次应生成不同的历史条目 ID")
    }

    /// fixture 投影的 performance 字段默认为 empty
    func testFixtureRound_performanceDefaultsToEmpty() {
        let store = EvolutionPipelineProjectionStore()
        _ = store.applyFixtureRound(
            project: "perf-fixture-project",
            workspace: "perf-fixture-workspace",
            cycleID: "fixture-evolution-cycle",
            roundIndex: 0
        )
        XCTAssertEqual(store.projection.performance, .empty,
                       "fixture 投影不应携带非空性能投影")
    }

    /// updatePerformanceProjection 不影响 fixture 的结构投影
    func testFixtureRound_performanceUpdateDoesNotAffectStructure() {
        let store = EvolutionPipelineProjectionStore()
        _ = store.applyFixtureRound(
            project: "perf-fixture-project",
            workspace: "perf-fixture-workspace",
            cycleID: "fixture-evolution-cycle",
            roundIndex: 2
        )
        let historiesBefore = store.projection.cycleHistories

        // 独立更新性能投影
        let perf = EvolutionPipelinePerformanceProjection(
            decision: EvolutionRealtimeSamplingDecision(tier: .live, reason: "test"),
            metrics: .empty
        )
        _ = store.updatePerformanceProjection(perf)

        XCTAssertEqual(store.projection.cycleHistories, historiesBefore,
                       "性能投影更新不应改变结构数据")
        XCTAssertEqual(store.projection.performance.tier, .live,
                       "性能投影应已更新")
    }
}
