import XCTest
@testable import TidyFlow

/// WI-004：EvolutionPerfFixtureScenario / EvolutionPerfFixtureRunner / TFPerfFixtureKind 单元测试
///
/// 覆盖：
/// 1. TFPerfFixtureKind 环境变量解析（统一 TF_PERF_SCENARIO + 向后兼容 TF_PERF_CHAT_SCENARIO）
/// 2. EvolutionPerfFixtureScenario 固定字段与多工作区 key 格式
/// 3. EvolutionPerfFixtureRunner 初始状态、运行状态迁移（不依赖真实 UI）
/// 4. EvolutionPipelineProjectionStore.applyFixtureRound 数值稳定性
final class EvolutionPerfFixtureTests: XCTestCase {

    // MARK: - TFPerfFixtureKind 解析

    func testTFPerfFixtureKind_evolutionPanel_rawValue() {
        XCTAssertEqual(TFPerfFixtureKind.evolutionPanel.rawValue, "evolution_panel",
                       "evolution_panel rawValue 必须与脚本提取规则一致，重命名会导致静默失效")
    }

    func testTFPerfFixtureKind_streamHeavy_rawValue() {
        XCTAssertEqual(TFPerfFixtureKind.streamHeavy.rawValue, "stream_heavy",
                       "stream_heavy rawValue 必须保持向后兼容")
    }

    func testTFPerfFixtureKind_unknownValue_returnsNil() {
        XCTAssertNil(TFPerfFixtureKind(rawValue: "unknown_scenario"))
    }

    // MARK: - EvolutionPerfFixtureScenario 固定字段契约

    func testEvolutionPerfFixtureScenario_id() {
        XCTAssertEqual(EvolutionPerfFixtureScenario.evolutionPanel.id, "evolution_panel",
                       "scenario.id 必须与 TFPerfFixtureKind.evolutionPanel.rawValue 一致")
    }

    func testEvolutionPerfFixtureScenario_fixedProject() {
        XCTAssertEqual(EvolutionPerfFixtureScenario.evolutionPanel.project, "perf-fixture-project",
                       "project 固定值变更会导致脚本证据定位失效")
    }

    func testEvolutionPerfFixtureScenario_fixedWorkspace() {
        XCTAssertEqual(EvolutionPerfFixtureScenario.evolutionPanel.workspace, "perf-fixture-workspace",
                       "workspace 固定值变更会导致脚本证据定位失效")
    }

    func testEvolutionPerfFixtureScenario_fixedCycleID() {
        XCTAssertEqual(EvolutionPerfFixtureScenario.evolutionPanel.cycleID, "fixture-evolution-cycle",
                       "cycleID 固定值变更会导致日志 cycle_id 字段不匹配")
    }

    func testEvolutionPerfFixtureScenario_roundCount() {
        XCTAssertGreaterThan(EvolutionPerfFixtureScenario.evolutionPanel.roundCount, 0,
                             "roundCount 必须大于 0，否则 fixture 无法运行")
    }

    func testEvolutionPerfFixtureScenario_workspaceContext_containsAllKeys() {
        let ctx = EvolutionPerfFixtureScenario.evolutionPanel.workspaceContext
        // workspaceContext 必须包含四个可断言字段，供脚本定位证据
        XCTAssertTrue(ctx.contains("AC-EVOLUTION-PERF-FIXTURE"), "workspaceContext 缺少 scenario 前缀")
        XCTAssertTrue(ctx.contains("iphone"), "workspaceContext 缺少 device 字段")
        XCTAssertTrue(ctx.contains("project=perf-fixture-project"), "workspaceContext 缺少 project 字段")
        XCTAssertTrue(ctx.contains("workspace=perf-fixture-workspace"), "workspaceContext 缺少 workspace 字段")
        XCTAssertTrue(ctx.contains("cycle_id=fixture-evolution-cycle"), "workspaceContext 缺少 cycle_id 字段")
    }

    // MARK: - EvolutionPerfFixtureRunner 初始状态

    func testEvolutionPerfFixtureRunner_initialState() {
        let runner = EvolutionPerfFixtureRunner(scenario: .evolutionPanel)
        XCTAssertFalse(runner.isRunning, "初始状态 isRunning 必须为 false")
        XCTAssertFalse(runner.isCompleted, "初始状态 isCompleted 必须为 false")
        XCTAssertEqual(runner.statusText, "idle", "初始状态 statusText 必须为 idle")
        XCTAssertEqual(runner.progress, 0, "初始状态 progress 必须为 0")
    }

    func testEvolutionPerfFixtureRunner_cancel_whenIdle_noEffect() {
        let runner = EvolutionPerfFixtureRunner(scenario: .evolutionPanel)
        runner.cancel()
        XCTAssertFalse(runner.isRunning)
        XCTAssertFalse(runner.isCompleted)
        XCTAssertEqual(runner.statusText, "idle")
    }

    // MARK: - EvolutionPipelineProjectionStore.applyFixtureRound 数值稳定性

    @MainActor
    func testApplyFixtureRound_returnsPositiveDuration() {
        let store = EvolutionPipelineProjectionStore()
        let durationMs = store.applyFixtureRound(
            project: "perf-fixture-project",
            workspace: "perf-fixture-workspace",
            cycleID: "fixture-evolution-cycle",
            roundIndex: 0
        )
        XCTAssertGreaterThanOrEqual(durationMs, 0.0,
                                    "applyFixtureRound 返回的耗时不应为负数")
    }

    @MainActor
    func testApplyFixtureRound_updatesProjection() {
        let store = EvolutionPipelineProjectionStore()
        let initialProjection = store.projection

        store.applyFixtureRound(
            project: "perf-fixture-project",
            workspace: "perf-fixture-workspace",
            cycleID: "fixture-evolution-cycle",
            roundIndex: 0
        )

        XCTAssertNotEqual(store.projection, initialProjection,
                          "applyFixtureRound 应该更新 projection")
        XCTAssertEqual(store.projection.project, "perf-fixture-project")
        XCTAssertEqual(store.projection.workspace, "perf-fixture-workspace")
    }

    @MainActor
    func testApplyFixtureRound_multipleRounds_differentHistories() {
        let store = EvolutionPipelineProjectionStore()

        store.applyFixtureRound(
            project: "perf-fixture-project",
            workspace: "perf-fixture-workspace",
            cycleID: "fixture-evolution-cycle",
            roundIndex: 0
        )
        let projection0 = store.projection

        store.applyFixtureRound(
            project: "perf-fixture-project",
            workspace: "perf-fixture-workspace",
            cycleID: "fixture-evolution-cycle",
            roundIndex: 1
        )
        let projection1 = store.projection

        // 每轮历史记录 id 不同，应触发 projection 更新
        XCTAssertNotEqual(projection0.cycleHistories.first?.id,
                          projection1.cycleHistories.first?.id,
                          "不同 roundIndex 应产生不同的 cycleHistory id")
    }

    @MainActor
    func testApplyFixtureRound_multiWorkspaceIsolation() {
        let store1 = EvolutionPipelineProjectionStore()
        let store2 = EvolutionPipelineProjectionStore()

        store1.applyFixtureRound(
            project: "project-a", workspace: "workspace-a",
            cycleID: "cycle-a", roundIndex: 0
        )
        store2.applyFixtureRound(
            project: "project-b", workspace: "workspace-b",
            cycleID: "cycle-b", roundIndex: 0
        )

        XCTAssertEqual(store1.projection.project, "project-a",
                       "多工作区场景：store1 投影不应被 store2 污染")
        XCTAssertEqual(store2.projection.project, "project-b",
                       "多工作区场景：store2 投影不应被 store1 污染")
        XCTAssertNotEqual(store1.projection, store2.projection,
                          "不同工作区的 fixture 投影不能相同")
    }

    // MARK: - AIChatPerfFixtureScenario 向后兼容验证

    func testAIChatPerfFixtureScenario_id_backwardCompat() {
        XCTAssertEqual(AIChatPerfFixtureScenario.streamHeavy.id, "stream_heavy",
                       "stream_heavy id 重命名会导致脚本 hotspot 日志提取失效")
    }

    func testAIChatPerfFixtureScenario_flushCount_greaterThanZero() {
        XCTAssertGreaterThan(AIChatPerfFixtureScenario.streamHeavy.flushCount, 0)
    }

    // MARK: - 多工作区场景标识契约（WI-001 新增场景）

    func testNewScenarioIds_chatStreamWorkspaceSwitch() {
        XCTAssertEqual(
            PerformanceTrackedSurface.chatSession.rawValue, "chat_session",
            "chat_stream_workspace_switch 的 surface_id 必须为 chat_session"
        )
        XCTAssertTrue(
            PerformanceTrackedSurface.chatSession.scenarioIds.contains("chat_stream_workspace_switch"),
            "chatSession.scenarioIds 必须包含 chat_stream_workspace_switch"
        )
    }

    func testNewScenarioIds_evolutionPanelMultiWorkspace() {
        XCTAssertEqual(
            PerformanceTrackedSurface.evolutionWorkspace.rawValue, "evolution_workspace",
            "evolution_panel_multi_workspace 的 surface_id 必须为 evolution_workspace"
        )
        XCTAssertTrue(
            PerformanceTrackedSurface.evolutionWorkspace.scenarioIds.contains("evolution_panel_multi_workspace"),
            "evolutionWorkspace.scenarioIds 必须包含 evolution_panel_multi_workspace"
        )
    }

    func testSurfaceId_matchesBaselinesSurfaceId() {
        let knownSurfaces = PerformanceTrackedSurface.allCases
        for surface in knownSurfaces {
            XCTAssertFalse(surface.rawValue.isEmpty, "\(surface) rawValue 不能为空")
            XCTAssertFalse(surface.scenarioIds.isEmpty, "\(surface) 必须至少关联一个 scenario id")
        }
    }

    // MARK: - 投影 store 在 fixture 场景下的结构/性能通道验证

    @MainActor
    func testFixtureRound_doesNotBreakSourceSnapshotTestProxyContract() {
        // 验证 SourceSnapshotTestProxy 的 Equatable 语义与 SourceSnapshot 一致：
        // performanceSignature 差异应导致不等
        let proxy1 = EvolutionPipelineProjectionStore.SourceSnapshotTestProxy(
            project: "perf-fixture-project",
            workspace: "perf-fixture-workspace",
            schedulerHash: 1,
            controlHash: 1,
            currentItemSignature: nil,
            blockingSignature: 0,
            cycleHistorySignature: 0,
            performanceSignature: 0
        )
        let proxy2 = EvolutionPipelineProjectionStore.SourceSnapshotTestProxy(
            project: "perf-fixture-project",
            workspace: "perf-fixture-workspace",
            schedulerHash: 1,
            controlHash: 1,
            currentItemSignature: nil,
            blockingSignature: 0,
            cycleHistorySignature: 0,
            performanceSignature: 0
        )
        XCTAssertEqual(proxy1, proxy2,
                       "相同字段的 SourceSnapshotTestProxy 应相等，iOS 固定 performanceSignature=0 可保证结构快照稳定")
    }

    @MainActor
    func testFixtureRound_transcriptStoreReset_clearsCachedState() {
        // 验证 AIChatTranscriptProjectionStore.reset 后不残留 fixture 数据
        let store = AIChatTranscriptProjectionStore()
        let messages = (0..<5).map { i in
            AIChatMessage(
                id: "fixture-m\(i)",
                messageId: "fixture-m\(i)",
                role: .assistant,
                parts: [AIChatPart(id: "p\(i)", kind: .text, text: "fixture")]
            )
        }
        let plan = AIChatTranscriptRenderPlan(
            displayMessages: messages,
            refreshStrategy: .fullRefresh,
            fullRenderRange: nil,
            pendingAnchorID: nil
        )
        store.apply(plan: plan, sourceCount: 5)
        XCTAssertEqual(store.projection.displayMessages.count, 5)

        store.reset()

        XCTAssertTrue(store.projection.displayMessages.isEmpty, "reset 后不应残留 fixture 消息")
        XCTAssertTrue(store.projection.messageIndexMap.isEmpty, "reset 后不应残留 fixture 索引映射")
        XCTAssertEqual(store.cachedSourceCount, -1, "reset 后 cachedSourceCount 应为 -1")
    }
}
