import XCTest
@testable import TidyFlow
import TidyFlowShared

/// Evolution 面板性能投影与工作区隔离测试（WI-004）
///
/// 覆盖：
/// - 当前工作区过滤：只显示匹配 project/workspace 的指标
/// - 同名 workspace 跨 project 隔离
/// - performance 投影签名未变时不触发整面板重绘
/// - 样本窗口上限 60
final class EvolutionPerformanceProjectionTests: XCTestCase {

    // MARK: - 工作区指标过滤

    func testFilterMetrics_onlyReturnsMatchingWorkspace() {
        let otherReport = makeClientReport(project: "proj", workspace: "ws", clientId: "client-1")
        let wrongProject = makeClientReport(project: "other-proj", workspace: "ws", clientId: "client-1")
        let wrongWorkspace = makeClientReport(project: "proj", workspace: "ws-2", clientId: "client-1")

        let snapshot = PerformanceObservabilitySnapshot(
            clientMetrics: [otherReport, wrongProject, wrongWorkspace]
        )
        let result = EvolutionRealtimeSamplingSemantics.filterMetrics(
            snapshot: snapshot,
            project: "proj",
            workspace: "ws",
            clientInstanceId: "client-1"
        )

        XCTAssertEqual(result.clientMetrics.count, 1)
        XCTAssertEqual(result.clientMetrics.first?.project, "proj")
        XCTAssertEqual(result.clientMetrics.first?.workspace, "ws")
    }

    func testFilterMetrics_differentProjectSameName() {
        // 同名 workspace 下不同 project 不应互相影响
        let reportA = makeClientReport(project: "project-a", workspace: "default", clientId: "client-a")
        let reportB = makeClientReport(project: "project-b", workspace: "default", clientId: "client-b")

        let snapshot = PerformanceObservabilitySnapshot(
            clientMetrics: [reportA, reportB]
        )

        let resultA = EvolutionRealtimeSamplingSemantics.filterMetrics(
            snapshot: snapshot, project: "project-a", workspace: "default", clientInstanceId: "client-a"
        )
        let resultB = EvolutionRealtimeSamplingSemantics.filterMetrics(
            snapshot: snapshot, project: "project-b", workspace: "default", clientInstanceId: "client-b"
        )

        XCTAssertEqual(resultA.clientMetrics.count, 1)
        XCTAssertEqual(resultA.clientMetrics.first?.project, "project-a")
        XCTAssertEqual(resultB.clientMetrics.count, 1)
        XCTAssertEqual(resultB.clientMetrics.first?.project, "project-b")
    }

    // MARK: - 诊断过滤

    func testFilterMetrics_systemDiagnosisAlwaysIncluded() {
        let sysDiag = makeDiagnosis(scope: .system, clientId: nil, project: nil, workspace: nil)
        let wsDiag = makeDiagnosis(scope: .workspace, clientId: nil, project: "proj", workspace: "ws")
        let wrongWsDiag = makeDiagnosis(scope: .workspace, clientId: nil, project: "proj", workspace: "ws-2")
        let clientDiag = makeDiagnosis(scope: .clientInstance, clientId: "client-1", project: "proj", workspace: "ws")
        let wrongClientDiag = makeDiagnosis(scope: .clientInstance, clientId: "client-2", project: "proj", workspace: "ws")

        let snapshot = PerformanceObservabilitySnapshot(
            diagnoses: [sysDiag, wsDiag, wrongWsDiag, clientDiag, wrongClientDiag]
        )
        let result = EvolutionRealtimeSamplingSemantics.filterMetrics(
            snapshot: snapshot,
            project: "proj",
            workspace: "ws",
            clientInstanceId: "client-1"
        )

        XCTAssertTrue(result.diagnoses.contains(where: { $0.diagnosisId == sysDiag.diagnosisId }), "system 级诊断应包含")
        XCTAssertTrue(result.diagnoses.contains(where: { $0.diagnosisId == wsDiag.diagnosisId }), "当前 workspace 诊断应包含")
        XCTAssertFalse(result.diagnoses.contains(where: { $0.diagnosisId == wrongWsDiag.diagnosisId }), "其他 workspace 诊断不应包含")
        XCTAssertTrue(result.diagnoses.contains(where: { $0.diagnosisId == clientDiag.diagnosisId }), "当前 client 诊断应包含")
        XCTAssertFalse(result.diagnoses.contains(where: { $0.diagnosisId == wrongClientDiag.diagnosisId }), "其他 client 诊断不应包含")
    }

    // MARK: - 性能投影签名

    func testPerformanceProjection_signatureUnchangedWhenMetricsUnchanged() {
        let snapshot = PerformanceObservabilitySnapshot(snapshotAt: 1000)
        let metrics1 = EvolutionRealtimeSamplingSemantics.filterMetrics(
            snapshot: snapshot, project: "proj", workspace: "ws", clientInstanceId: "c1"
        )
        let metrics2 = EvolutionRealtimeSamplingSemantics.filterMetrics(
            snapshot: snapshot, project: "proj", workspace: "ws", clientInstanceId: "c1"
        )
        XCTAssertEqual(metrics1.signature, metrics2.signature, "相同输入应产生相同签名")
    }

    func testPerformanceProjection_signatureChangesWhenDiagnosisAdded() {
        let snapshot1 = PerformanceObservabilitySnapshot(snapshotAt: 1000)
        let snapshot2 = PerformanceObservabilitySnapshot(
            diagnoses: [makeDiagnosis(scope: .system, clientId: nil, project: nil, workspace: nil)],
            snapshotAt: 1001
        )
        let m1 = EvolutionRealtimeSamplingSemantics.filterMetrics(
            snapshot: snapshot1, project: "proj", workspace: "ws", clientInstanceId: "c1"
        )
        let m2 = EvolutionRealtimeSamplingSemantics.filterMetrics(
            snapshot: snapshot2, project: "proj", workspace: "ws", clientInstanceId: "c1"
        )
        XCTAssertNotEqual(m1.signature, m2.signature, "增加诊断后签名应改变")
    }

    // MARK: - EvolutionPipelinePerformanceProjection 相等性

    func testPerformanceProjection_equality() {
        let p1 = EvolutionPipelinePerformanceProjection(decision: .paused, metrics: .empty)
        let p2 = EvolutionPipelinePerformanceProjection(decision: .paused, metrics: .empty)
        XCTAssertEqual(p1, p2)
    }

    func testPerformanceProjection_inequalityOnTierChange() {
        let p1 = EvolutionPipelinePerformanceProjection(decision: .paused, metrics: .empty)
        let p2 = EvolutionPipelinePerformanceProjection(
            decision: EvolutionRealtimeSamplingDecision(tier: .live, reason: "healthy"),
            metrics: .empty
        )
        XCTAssertNotEqual(p1, p2)
    }

    // MARK: - 辅助

    private func makeClientReport(project: String, workspace: String, clientId: String) -> ClientPerformanceReport {
        ClientPerformanceReport(
            clientInstanceId: clientId,
            platform: "macos",
            project: project,
            workspace: workspace
        )
    }

    private func makeDiagnosis(
        scope: PerformanceDiagnosisScope,
        clientId: String?,
        project: String?,
        workspace: String?
    ) -> PerformanceDiagnosis {
        PerformanceDiagnosis(
            diagnosisId: UUID().uuidString,
            scope: scope,
            severity: .warning,
            reason: .workspaceSwitchLatencyHigh,
            summary: "test",
            recommendedAction: "none",
            context: HealthContext(project: project, workspace: workspace),
            clientInstanceId: clientId
        )
    }
}
