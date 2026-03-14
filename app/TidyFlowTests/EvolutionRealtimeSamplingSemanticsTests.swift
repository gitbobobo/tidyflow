import XCTest
@testable import TidyFlow
import TidyFlowShared

/// Evolution 实时采样语义测试（WI-004）
///
/// 覆盖：
/// - 四档判定（paused/live/balanced/degraded）
/// - critical diagnosis 立即降级
/// - 连续 2 次健康后升档迟滞
/// - scene inactive 暂停
/// - runningAgents=0 暂停
/// - ws 断连暂停
final class EvolutionRealtimeSamplingSemanticsTests: XCTestCase {

    // MARK: - paused 档位

    func testPaused_sceneInactive() {
        let decision = computeDecision(
            runningAgentCount: 2,
            sceneActive: false,
            panelVisible: true,
            wsConnected: true
        )
        XCTAssertEqual(decision.tier, .paused)
        XCTAssertEqual(decision.reason, "scene_inactive")
        XCTAssertNil(decision.tier.intervalMs)
    }

    func testPaused_panelNotVisible() {
        let decision = computeDecision(
            runningAgentCount: 2,
            sceneActive: true,
            panelVisible: false,
            wsConnected: true
        )
        XCTAssertEqual(decision.tier, .paused)
        XCTAssertEqual(decision.reason, "panel_not_visible")
    }

    func testPaused_wsDisconnected() {
        let decision = computeDecision(
            runningAgentCount: 2,
            sceneActive: true,
            panelVisible: true,
            wsConnected: false
        )
        XCTAssertEqual(decision.tier, .paused)
        XCTAssertEqual(decision.reason, "ws_disconnected")
    }

    func testPaused_noRunningAgents() {
        let decision = computeDecision(
            runningAgentCount: 0,
            sceneActive: true,
            panelVisible: true,
            wsConnected: true
        )
        XCTAssertEqual(decision.tier, .paused)
        XCTAssertEqual(decision.reason, "no_running_agents")
    }

    // MARK: - live 档位

    func testLive_healthyConditions() {
        let decision = computeDecision(
            runningAgentCount: 1,
            sceneActive: true,
            panelVisible: true,
            wsConnected: true,
            diagnoses: []
        )
        XCTAssertEqual(decision.tier, .live)
        XCTAssertEqual(decision.tier.intervalMs, 1000)
        XCTAssertTrue(decision.tier.enableAnimation)
    }

    func testLive_intervalMs_is1000() {
        XCTAssertEqual(EvolutionRealtimeSamplingTier.live.intervalMs, 1000)
    }

    // MARK: - balanced 档位

    func testBalanced_manyRunningAgents() {
        let decision = computeDecision(
            runningAgentCount: 3,
            sceneActive: true,
            panelVisible: true,
            wsConnected: true,
            diagnoses: []
        )
        XCTAssertEqual(decision.tier, .balanced)
        XCTAssertEqual(decision.tier.intervalMs, 2000)
    }

    func testBalanced_warningDiagnosis() {
        let diagnoses = [makeDiagnosis(severity: .warning, reason: .workspaceSwitchLatencyHigh)]
        let decision = computeDecision(
            runningAgentCount: 1,
            sceneActive: true,
            panelVisible: true,
            wsConnected: true,
            diagnoses: diagnoses
        )
        XCTAssertEqual(decision.tier, .balanced)
    }

    func testBalanced_memoryDelta96To191MB() {
        // 100 MB delta -> balanced
        let report = makeClientReport(deltaBytes: 100 * 1024 * 1024)
        let snapshot = PerformanceObservabilitySnapshot(
            clientMetrics: [report], diagnoses: []
        )
        let metrics = EvolutionRealtimeSamplingSemantics.filterMetrics(
            snapshot: snapshot,
            project: "proj",
            workspace: "ws",
            clientInstanceId: report.clientInstanceId
        )
        let (tier, reason) = EvolutionRealtimeSamplingSemantics.targetTier(
            metrics: metrics,
            runningAgentCount: 1,
            sceneActive: true,
            panelVisible: true,
            wsConnected: true
        )
        XCTAssertEqual(tier, .balanced, "100MB delta should be balanced, reason=\(reason)")
    }

    // MARK: - degraded 档位

    func testDegraded_criticalDiagnosis_immediateDowngrade() {
        let diagnoses = [makeDiagnosis(severity: .critical, reason: .clientMemoryPressure)]
        let decision = computeDecision(
            runningAgentCount: 1,
            sceneActive: true,
            panelVisible: true,
            wsConnected: true,
            diagnoses: diagnoses
        )
        XCTAssertEqual(decision.tier, .degraded)
        XCTAssertEqual(decision.tier.intervalMs, 5000)
        XCTAssertFalse(decision.tier.enableAnimation, "degraded 档位应关闭动画")
    }

    func testDegraded_memoryGrowthUnbounded() {
        let diagnoses = [makeDiagnosis(severity: .warning, reason: .memoryGrowthUnbounded)]
        let decision = computeDecision(
            runningAgentCount: 1,
            sceneActive: true,
            panelVisible: true,
            wsConnected: true,
            diagnoses: diagnoses
        )
        XCTAssertEqual(decision.tier, .degraded)
    }

    func testDegraded_wsPipelineLatencyHigh() {
        let diagnoses = [makeDiagnosis(severity: .warning, reason: .wsPipelineLatencyHigh)]
        let decision = computeDecision(
            runningAgentCount: 1,
            sceneActive: true,
            panelVisible: true,
            wsConnected: true,
            diagnoses: diagnoses
        )
        XCTAssertEqual(decision.tier, .degraded)
    }

    func testDegraded_memoryDelta192MBOrMore() {
        let report = makeClientReport(deltaBytes: 200 * 1024 * 1024)
        let snapshot = PerformanceObservabilitySnapshot(
            clientMetrics: [report], diagnoses: []
        )
        let metrics = EvolutionRealtimeSamplingSemantics.filterMetrics(
            snapshot: snapshot,
            project: "proj",
            workspace: "ws",
            clientInstanceId: report.clientInstanceId
        )
        let (tier, _) = EvolutionRealtimeSamplingSemantics.targetTier(
            metrics: metrics,
            runningAgentCount: 1,
            sceneActive: true,
            panelVisible: true,
            wsConnected: true
        )
        XCTAssertEqual(tier, .degraded, "200MB delta 应触发 degraded")
    }

    // MARK: - 迟滞规则

    func testHysteresis_degradedDoesNotUpgradeUntil2HealthyCycles() {
        // 从 degraded 开始，目标是 live
        let degradedDecision = EvolutionRealtimeSamplingDecision(
            tier: .degraded, reason: "initial", consecutiveHealthyCount: 0
        )

        // 第一次健康：应保持 degraded（计数 = 1）
        let after1 = EvolutionRealtimeSamplingSemantics.applyHysteresis(
            targetTier: .live,
            targetReason: "healthy",
            currentDecision: degradedDecision
        )
        XCTAssertEqual(after1.tier, .degraded, "第一次健康不应升档")
        XCTAssertEqual(after1.consecutiveHealthyCount, 1)

        // 第二次健康：应升到 live
        let after2 = EvolutionRealtimeSamplingSemantics.applyHysteresis(
            targetTier: .live,
            targetReason: "healthy",
            currentDecision: after1
        )
        XCTAssertEqual(after2.tier, .live, "连续2次健康后应升档")
        XCTAssertEqual(after2.consecutiveHealthyCount, 0)
    }

    func testHysteresis_criticalCausesImmediateDowngrade() {
        // 从 live 状态
        let liveDecision = EvolutionRealtimeSamplingDecision(
            tier: .live, reason: "healthy", consecutiveHealthyCount: 0
        )

        let degraded = EvolutionRealtimeSamplingSemantics.applyHysteresis(
            targetTier: .degraded,
            targetReason: "critical_diagnosis:client_memory_pressure",
            currentDecision: liveDecision
        )
        XCTAssertEqual(degraded.tier, .degraded, "critical 诊断应立即降级")
        XCTAssertEqual(degraded.consecutiveHealthyCount, 0)
    }

    func testHysteresis_balancedToLiveRequires2Cycles() {
        let balanced = EvolutionRealtimeSamplingDecision(
            tier: .balanced, reason: "warning", consecutiveHealthyCount: 0
        )

        let after1 = EvolutionRealtimeSamplingSemantics.applyHysteresis(
            targetTier: .live, targetReason: "healthy", currentDecision: balanced
        )
        XCTAssertEqual(after1.tier, .balanced, "balanced -> live 第一次健康应保持")

        let after2 = EvolutionRealtimeSamplingSemantics.applyHysteresis(
            targetTier: .live, targetReason: "healthy", currentDecision: after1
        )
        XCTAssertEqual(after2.tier, .live, "连续2次健康应升到 live")
    }

    // MARK: - 档位属性

    func testTierIntervals() {
        XCTAssertNil(EvolutionRealtimeSamplingTier.paused.intervalMs)
        XCTAssertEqual(EvolutionRealtimeSamplingTier.live.intervalMs, 1000)
        XCTAssertEqual(EvolutionRealtimeSamplingTier.balanced.intervalMs, 2000)
        XCTAssertEqual(EvolutionRealtimeSamplingTier.degraded.intervalMs, 5000)
    }

    func testTierAnimationFlags() {
        XCTAssertTrue(EvolutionRealtimeSamplingTier.live.enableAnimation)
        XCTAssertTrue(EvolutionRealtimeSamplingTier.balanced.enableAnimation)
        XCTAssertFalse(EvolutionRealtimeSamplingTier.degraded.enableAnimation)
        XCTAssertFalse(EvolutionRealtimeSamplingTier.paused.enableAnimation)
    }

    // MARK: - WI-003: Evolution 采样决策与预算状态关系

    func testSamplingDecision_panelVisibilityChange_doesNotCauseBudgetFlutter() {
        // 从 live 开始
        let liveDecision = EvolutionRealtimeSamplingDecision(
            tier: .live, reason: "healthy", consecutiveHealthyCount: 0
        )

        // 面板隐藏 → paused
        let hiddenDecision = computeDecision(
            runningAgentCount: 1,
            sceneActive: true,
            panelVisible: false,
            wsConnected: true,
            currentDecision: liveDecision
        )
        XCTAssertEqual(hiddenDecision.tier, .paused)

        // 面板重新可见 → 应恢复但经过迟滞（balanced 而非直接 live）
        let resumedDecision = computeDecision(
            runningAgentCount: 1,
            sceneActive: true,
            panelVisible: true,
            wsConnected: true,
            currentDecision: hiddenDecision
        )
        // 从 paused 恢复时，live 目标通过迟滞先到 balanced
        XCTAssertTrue(resumedDecision.tier == .balanced || resumedDecision.tier == .live,
                       "从 paused 恢复应到 balanced 或 live，不应抖动到 degraded")
    }

    func testSamplingDecision_runningAgentCountChange_predictable() {
        // 1 个 agent: live
        let live1 = computeDecision(
            runningAgentCount: 1,
            sceneActive: true,
            panelVisible: true,
            wsConnected: true
        )
        XCTAssertEqual(live1.tier, .live)

        // 3 个 agent: balanced
        let balanced3 = computeDecision(
            runningAgentCount: 3,
            sceneActive: true,
            panelVisible: true,
            wsConnected: true
        )
        XCTAssertEqual(balanced3.tier, .balanced)

        // 0 个 agent: paused
        let paused0 = computeDecision(
            runningAgentCount: 0,
            sceneActive: true,
            panelVisible: true,
            wsConnected: true
        )
        XCTAssertEqual(paused0.tier, .paused)
    }

    func testSamplingDecision_wsConnectionChange_noUnexpectedBudgetState() {
        // WS 连接断开 → paused
        let disconnected = computeDecision(
            runningAgentCount: 2,
            sceneActive: true,
            panelVisible: true,
            wsConnected: false
        )
        XCTAssertEqual(disconnected.tier, .paused, "WS 断连应 paused")

        // WS 重连 → 恢复（不应直接到 degraded）
        let reconnected = computeDecision(
            runningAgentCount: 2,
            sceneActive: true,
            panelVisible: true,
            wsConnected: true,
            currentDecision: disconnected
        )
        XCTAssertNotEqual(reconnected.tier, .degraded,
                          "WS 重连后无诊断时不应出现 degraded")
    }

    // MARK: - 辅助

    private func computeDecision(
        runningAgentCount: Int,
        sceneActive: Bool,
        panelVisible: Bool,
        wsConnected: Bool,
        diagnoses: [PerformanceDiagnosis] = [],
        // 默认从 live 开始，以便测试降级是否立即生效（降级无迟滞）
        currentDecision: EvolutionRealtimeSamplingDecision = EvolutionRealtimeSamplingDecision(tier: .live, reason: "test_init")
    ) -> EvolutionRealtimeSamplingDecision {
        let snapshot = PerformanceObservabilitySnapshot(diagnoses: diagnoses)
        let metrics = EvolutionRealtimeSamplingSemantics.filterMetrics(
            snapshot: snapshot,
            project: "proj",
            workspace: "ws",
            clientInstanceId: "test-client"
        )
        return EvolutionRealtimeSamplingSemantics.computeDecision(
            metrics: metrics,
            runningAgentCount: runningAgentCount,
            sceneActive: sceneActive,
            panelVisible: panelVisible,
            wsConnected: wsConnected,
            currentDecision: currentDecision
        )
    }

    private func makeDiagnosis(
        severity: PerformanceDiagnosisSeverity,
        reason: PerformanceDiagnosisReason
    ) -> PerformanceDiagnosis {
        PerformanceDiagnosis(
            diagnosisId: UUID().uuidString,
            scope: .system,
            severity: severity,
            reason: reason,
            summary: "test",
            recommendedAction: "none"
        )
    }

    private func makeClientReport(deltaBytes: Int64) -> ClientPerformanceReport {
        ClientPerformanceReport(
            clientInstanceId: "test-client",
            platform: "macos",
            project: "proj",
            workspace: "ws",
            memory: MemoryUsageSnapshot(
                currentBytes: UInt64(abs(deltaBytes)),
                peakBytes: UInt64(abs(deltaBytes)),
                deltaFromBaselineBytes: deltaBytes,
                sampleCount: 1
            ),
            workspaceSwitch: .empty,
            fileTreeRequest: .empty,
            fileTreeExpand: .empty,
            aiSessionListRequest: .empty,
            aiMessageTailFlush: .empty,
            evidencePageAppend: .empty,
            reportedAt: 0
        )
    }
}

// MARK: - EvolutionTimelineLocalState / EvolutionRealtimeLocalState 测试

/// 验证 Evolution 面板局部状态容器的隔离性和重置语义。
#if os(macOS)
final class EvolutionLocalStateContainerTests: XCTestCase {

    func testTimelineLocalState_resetClearsAllFields() {
        let state = EvolutionTimelineLocalState()
        state.lastRecordedRound = 5
        state.timelineSnapshotSignature = 42
        state.completedTimeline = [PipelineTimelineEntry(
            id: "entry-0", stage: "plan", agent: "agent-1",
            toolCallCount: 3, completedAt: "2025-01-01T00:00:00Z"
        )]

        state.reset()

        XCTAssertEqual(state.lastRecordedRound, 0, "reset 后 lastRecordedRound 应为 0")
        XCTAssertEqual(state.timelineSnapshotSignature, 0, "reset 后 timelineSnapshotSignature 应为 0")
        XCTAssertTrue(state.completedTimeline.isEmpty, "reset 后 completedTimeline 应为空")
    }

    func testRealtimeLocalState_resetClearsAllFields() {
        let state = EvolutionRealtimeLocalState()
        state.realtimeIndicatorsActive = true
        state.activeRealtimeConsumerID = "consumer-1"
        state.lastRealtimeMetricsSignature = "sig-123"
        state.activeMonitorKey = "proj/ws"

        state.reset()

        XCTAssertFalse(state.realtimeIndicatorsActive, "reset 后 realtimeIndicatorsActive 应为 false")
        XCTAssertNil(state.activeRealtimeConsumerID, "reset 后 activeRealtimeConsumerID 应为 nil")
        XCTAssertEqual(state.lastRealtimeMetricsSignature, "", "reset 后 lastRealtimeMetricsSignature 应为空")
        XCTAssertEqual(state.activeMonitorKey, "", "reset 后 activeMonitorKey 应为空")
        XCTAssertTrue(state.realtimeTrendBuffer.isEmpty, "reset 后 realtimeTrendBuffer 应为空")
    }

    func testRealtimeLocalState_trendBufferCapsAt60() {
        let state = EvolutionRealtimeLocalState()
        for i in 1...70 {
            state.appendSample(EvolutionRealtimeMetricsProjection(
                workspaceMetrics: [], clientMetrics: [], diagnoses: [],
                snapshotAt: UInt64(i)
            ))
        }
        XCTAssertEqual(state.realtimeTrendBuffer.count, EvolutionRealtimeLocalState.trendBufferLimit,
                       "趋势缓冲应限制在 \(EvolutionRealtimeLocalState.trendBufferLimit) 个样本")
        XCTAssertEqual(state.realtimeTrendBuffer.first?.snapshotAt, 11,
                       "前 10 个样本应被淘汰，缓冲从第 11 个开始")
    }

    func testRealtimeLocalState_clearTrendBuffer_returnsCount() {
        let state = EvolutionRealtimeLocalState()
        for i in 1...5 {
            state.appendSample(EvolutionRealtimeMetricsProjection(
                workspaceMetrics: [], clientMetrics: [], diagnoses: [],
                snapshotAt: UInt64(i)
            ))
        }
        let cleared = state.clearTrendBuffer()
        XCTAssertEqual(cleared, 5)
        XCTAssertTrue(state.realtimeTrendBuffer.isEmpty)
    }

    func testMultipleWorkspaceContexts_stateIsIndependent() {
        // 验证两个独立的 state 容器实例不共享全局状态
        let stateA = EvolutionTimelineLocalState()
        let stateB = EvolutionTimelineLocalState()

        stateA.lastRecordedRound = 3
        stateB.lastRecordedRound = 7

        XCTAssertEqual(stateA.lastRecordedRound, 3)
        XCTAssertEqual(stateB.lastRecordedRound, 7)
        XCTAssertNotEqual(stateA.lastRecordedRound, stateB.lastRecordedRound,
                          "不同工作区的 state 容器不应共享全局状态")
    }
}
#endif
