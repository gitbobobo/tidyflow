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
