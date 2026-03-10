import XCTest
@testable import TidyFlow
import TidyFlowShared

final class SharedProtocolModelsTests: XCTestCase {
    func testWorkspaceSidebarStatusInfoEmpty() {
        let info = WorkspaceSidebarStatusInfo.empty
        XCTAssertNil(info.taskIcon)
        XCTAssertFalse(info.chatActive)
        XCTAssertFalse(info.evolutionActive)
    }

    func testProjectInfoFromJson() {
        let json: [String: Any] = [
            "name": "my-project",
            "root": "/Users/test/project",
            "workspace_count": 2
        ]
        let info = ProjectInfo.from(json: json)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.name, "my-project")
        XCTAssertEqual(info?.workspaceCount, 2)
    }

    func testWorkspaceInfoFromJson() {
        let json: [String: Any] = [
            "name": "default",
            "root": "/Users/test/project",
            "branch": "main",
            "status": "idle"
        ]
        let info = WorkspaceInfo.from(json: json)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.branch, "main")
    }

    func testTerminalSessionInfoFromJson() {
        let json: [String: Any] = [
            "term_id": "term-001",
            "project": "my-project",
            "workspace": "default",
            "cwd": "/Users/test",
            "shell": "/bin/zsh",
            "status": "running"
        ]
        let info = TerminalSessionInfo.from(json: json)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.termId, "term-001")
        XCTAssertTrue(info?.isRunning ?? false)
    }

    // MARK: - 智能演化分析契约测试（WI-001 / WI-005）

    func testBottleneckEntryFromJson() {
        let json: [String: Any] = [
            "bottleneck_id": "bn:resource:proj:ws",
            "kind": "resource",
            "reason_code": "high_resource_pressure",
            "risk_score": 0.75,
            "evidence_summary": "资源压力级别 High",
            "context": [
                "project": "proj",
                "workspace": "ws"
            ],
            "related_ids": ["inc-1", "inc-2"],
            "detected_at": UInt64(1710000000000)
        ]
        let entry = BottleneckEntry.from(json: json)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.bottleneckId, "bn:resource:proj:ws")
        XCTAssertEqual(entry?.kind, .resource)
        XCTAssertEqual(entry?.reasonCode, "high_resource_pressure")
        XCTAssertEqual(entry!.riskScore, 0.75, accuracy: 0.001)
        XCTAssertEqual(entry?.relatedIds.count, 2)
    }

    func testOptimizationSuggestionFromJson() {
        let json: [String: Any] = [
            "suggestion_id": "sug:reduce:1",
            "scope": "system",
            "action": "reduce_concurrency",
            "summary": "建议降低并发至 2",
            "priority": 1,
            "expected_impact": "减少资源争用",
            "context": [:] as [String: Any]
        ]
        let suggestion = OptimizationSuggestion.from(json: json)
        XCTAssertNotNil(suggestion)
        XCTAssertEqual(suggestion?.scope, .system)
        XCTAssertEqual(suggestion?.action, "reduce_concurrency")
        XCTAssertEqual(suggestion?.priority, 1)
        XCTAssertEqual(suggestion?.expectedImpact, "减少资源争用")
    }

    func testEvolutionAnalysisSummaryFromJson() {
        let json: [String: Any] = [
            "project": "my-project",
            "workspace": "default",
            "cycle_id": "cycle-2026",
            "bottlenecks": [] as [[String: Any]],
            "overall_risk_score": 0.3,
            "health_score": 0.85,
            "pressure_level": "moderate",
            "predictive_anomaly_ids": ["pred-1"],
            "suggestions": [] as [[String: Any]],
            "analyzed_at": UInt64(1710000000000),
            "expires_at": UInt64(1710003600000)
        ]
        let summary = EvolutionAnalysisSummary.from(json: json)
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.project, "my-project")
        XCTAssertEqual(summary?.workspace, "default")
        XCTAssertEqual(summary?.cycleId, "cycle-2026")
        XCTAssertEqual(summary!.overallRiskScore, 0.3, accuracy: 0.001)
        XCTAssertEqual(summary!.healthScore, 0.85, accuracy: 0.001)
        XCTAssertEqual(summary?.pressureLevel, .moderate)
        XCTAssertEqual(summary?.predictiveAnomalyIds, ["pred-1"])
    }

    func testEvolutionAnalysisSummaryIsolation() {
        let summaryA = EvolutionAnalysisSummary.from(json: [
            "project": "projA",
            "workspace": "wsA",
            "cycle_id": "cycle-1",
            "overall_risk_score": 0.9,
            "health_score": 0.1,
            "pressure_level": "critical",
            "analyzed_at": UInt64(1000),
            "expires_at": UInt64(2000)
        ])
        let summaryB = EvolutionAnalysisSummary.from(json: [
            "project": "projB",
            "workspace": "wsB",
            "cycle_id": "cycle-1",
            "overall_risk_score": 0.1,
            "health_score": 0.95,
            "pressure_level": "low",
            "analyzed_at": UInt64(1000),
            "expires_at": UInt64(2000)
        ])
        XCTAssertNotNil(summaryA)
        XCTAssertNotNil(summaryB)
        // 确认两个分析摘要按 (project, workspace) 独立
        XCTAssertNotEqual(summaryA?.project, summaryB?.project)
        XCTAssertNotEqual(summaryA?.overallRiskScore, summaryB?.overallRiskScore)
    }
}
