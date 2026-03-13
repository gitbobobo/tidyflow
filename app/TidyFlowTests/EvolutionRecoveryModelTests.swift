import XCTest
@testable import TidyFlow
import TidyFlowShared

/// WI-004：Evolution 自愈恢复模型 Swift 测试
/// 验证恢复对象解析、按钮可用性、投影映射与历史列表消费。
final class EvolutionRecoveryModelTests: XCTestCase {

    // MARK: - EvolutionRecoveryDTO 解析

    func testRecoveryDTOParsesValidJSON() {
        let json: [String: Any] = [
            "phase": "recovering",
            "strategy": "wait_rate_limit",
            "diagnosis_code": "rate_limit",
            "diagnosis_summary": "429 Too Many Requests",
            "resume_at": "2099-12-31T23:59:59Z",
            "retry_count": 1,
            "retry_limit": 3,
            "degraded_until": NSNull(),
            "updated_at": "2026-03-13T20:00:00Z"
        ]

        let dto = EvolutionRecoveryDTO.from(json: json)
        XCTAssertNotNil(dto)
        XCTAssertEqual(dto?.phase, "recovering")
        XCTAssertEqual(dto?.strategy, "wait_rate_limit")
        XCTAssertEqual(dto?.diagnosisCode, "rate_limit")
        XCTAssertEqual(dto?.diagnosisSummary, "429 Too Many Requests")
        XCTAssertEqual(dto?.resumeAt, "2099-12-31T23:59:59Z")
        XCTAssertEqual(dto?.retryCount, 1)
        XCTAssertEqual(dto?.retryLimit, 3)
        XCTAssertNil(dto?.degradedUntil)
        XCTAssertEqual(dto?.updatedAt, "2026-03-13T20:00:00Z")
    }

    func testRecoveryDTOReturnsNilForMissingRequiredFields() {
        // phase 缺失 → 应返回 nil
        let json: [String: Any] = [
            "strategy": "none",
            "diagnosis_code": "unknown_system",
            "updated_at": "2026-01-01T00:00:00Z"
        ]
        XCTAssertNil(EvolutionRecoveryDTO.from(json: json))
    }

    func testRecoveryDTOReturnsNilForNilInput() {
        XCTAssertNil(EvolutionRecoveryDTO.from(json: nil))
    }

    func testRecoveryDTOActiveCooldownPhases() {
        let recovering = EvolutionRecoveryDTO(
            phase: "recovering", strategy: "wait_rate_limit",
            diagnosisCode: "rate_limit", diagnosisSummary: nil,
            resumeAt: nil, retryCount: 0, retryLimit: 3,
            degradedUntil: nil, updatedAt: "2026-01-01T00:00:00Z"
        )
        XCTAssertTrue(recovering.isActiveCooldown)

        let degraded = EvolutionRecoveryDTO(
            phase: "degraded", strategy: "defer_workspace",
            diagnosisCode: "gate_blocked", diagnosisSummary: nil,
            resumeAt: nil, retryCount: 0, retryLimit: 3,
            degradedUntil: nil, updatedAt: "2026-01-01T00:00:00Z"
        )
        XCTAssertTrue(degraded.isActiveCooldown)

        let failed = EvolutionRecoveryDTO(
            phase: "failed", strategy: "none",
            diagnosisCode: "unknown_system", diagnosisSummary: nil,
            resumeAt: nil, retryCount: 0, retryLimit: 3,
            degradedUntil: nil, updatedAt: "2026-01-01T00:00:00Z"
        )
        XCTAssertFalse(failed.isActiveCooldown)
    }

    // MARK: - EvolutionWorkspaceItemV2 recovery 字段

    func testWorkspaceItemParsesRecoveryField() {
        let json: [String: Any] = [
            "project": "tidyflow",
            "workspace": "default",
            "cycle_id": "cycle-test",
            "status": "running",
            "current_stage": "implement.general.1",
            "global_loop_round": 1,
            "loop_round_limit": 10,
            "verify_iteration": 0,
            "verify_iteration_limit": 5,
            "agents": [],
            "executions": [],
            "recovery": [
                "phase": "recovering",
                "strategy": "retry_stage",
                "diagnosis_code": "transient_session",
                "diagnosis_summary": "stream error",
                "retry_count": 2,
                "retry_limit": 3,
                "updated_at": "2026-03-13T20:00:00Z"
            ] as [String: Any]
        ]

        let item = EvolutionWorkspaceItemV2.from(json: json)
        XCTAssertNotNil(item)
        XCTAssertNotNil(item?.recovery)
        XCTAssertEqual(item?.recovery?.phase, "recovering")
        XCTAssertEqual(item?.recovery?.strategy, "retry_stage")
        XCTAssertEqual(item?.recovery?.diagnosisCode, "transient_session")
    }

    func testWorkspaceItemWithoutRecoveryFieldIsNil() {
        let json: [String: Any] = [
            "project": "tidyflow",
            "workspace": "default",
            "cycle_id": "cycle-test",
            "status": "running",
            "current_stage": "plan",
            "global_loop_round": 1,
            "loop_round_limit": 10,
            "verify_iteration": 0,
            "verify_iteration_limit": 5,
            "agents": [],
            "executions": []
        ]

        let item = EvolutionWorkspaceItemV2.from(json: json)
        XCTAssertNotNil(item)
        XCTAssertNil(item?.recovery)
    }

    // MARK: - EvolutionCycleHistoryItemV2 recovery 字段

    func testCycleHistoryItemParsesRecoveryField() {
        let json: [String: Any] = [
            "cycle_id": "cycle-hist-1",
            "title": "历史循环",
            "status": "failed_system",
            "global_loop_round": 2,
            "created_at": "2026-03-13T18:00:00Z",
            "updated_at": "2026-03-13T19:30:00Z",
            "stages": [],
            "recovery": [
                "phase": "failed",
                "strategy": "none",
                "diagnosis_code": "artifact_contract_violation",
                "diagnosis_summary": "schema mismatch",
                "retry_count": 0,
                "retry_limit": 0,
                "updated_at": "2026-03-13T19:30:00Z"
            ] as [String: Any]
        ]

        let item = EvolutionCycleHistoryItemV2.from(json: json)
        XCTAssertNotNil(item)
        XCTAssertNotNil(item?.recovery)
        XCTAssertEqual(item?.recovery?.phase, "failed")
        XCTAssertEqual(item?.recovery?.diagnosisCode, "artifact_contract_violation")
    }

    func testCycleHistoryItemWithoutRecoveryIsNil() {
        let json: [String: Any] = [
            "cycle_id": "cycle-hist-2",
            "status": "completed",
            "global_loop_round": 1,
            "created_at": "2026-03-13T18:00:00Z",
            "updated_at": "2026-03-13T19:00:00Z",
            "stages": []
        ]

        let item = EvolutionCycleHistoryItemV2.from(json: json)
        XCTAssertNotNil(item)
        XCTAssertNil(item?.recovery)
    }

    // MARK: - EvoCycleUpdatedV2 recovery 字段

    func testEvoCycleUpdatedParsesRecoveryField() {
        let json: [String: Any] = [
            "project": "tidyflow",
            "workspace": "default",
            "cycle_id": "cycle-upd-1",
            "status": "running",
            "current_stage": "verify.general.1",
            "global_loop_round": 1,
            "loop_round_limit": 5,
            "verify_iteration": 2,
            "verify_iteration_limit": 5,
            "agents": [],
            "executions": [],
            "retryable": false,
            "recovery": [
                "phase": "degraded",
                "strategy": "defer_workspace",
                "diagnosis_code": "gate_blocked",
                "diagnosis_summary": "verify retry exhausted",
                "retry_count": 3,
                "retry_limit": 3,
                "degraded_until": "2099-01-01T00:00:00Z",
                "updated_at": "2026-03-13T20:00:00Z"
            ] as [String: Any]
        ]

        let ev = EvoCycleUpdatedV2.from(json: json)
        XCTAssertNotNil(ev)
        XCTAssertNotNil(ev?.recovery)
        XCTAssertEqual(ev?.recovery?.phase, "degraded")
        XCTAssertEqual(ev?.recovery?.strategy, "defer_workspace")
        XCTAssertEqual(ev?.recovery?.degradedUntil, "2099-01-01T00:00:00Z")
    }

    // MARK: - PipelineCycleHistory 恢复投影

    func testPipelineCycleHistoryRecoveryStatusText() {
        let recovering = PipelineCycleHistory(
            id: "h1", round: 1, stages: [], startDate: Date(), stageEntries: [],
            recovery: EvolutionRecoveryDTO(
                phase: "recovering", strategy: "wait_rate_limit",
                diagnosisCode: "rate_limit", diagnosisSummary: nil,
                resumeAt: nil, retryCount: 0, retryLimit: 3,
                degradedUntil: nil, updatedAt: "2026-01-01T00:00:00Z"
            )
        )
        XCTAssertEqual(recovering.recoveryStatusText, "恢复中")

        let degraded = PipelineCycleHistory(
            id: "h2", round: 1, stages: [], startDate: Date(), stageEntries: [],
            recovery: EvolutionRecoveryDTO(
                phase: "degraded", strategy: "defer_workspace",
                diagnosisCode: "gate_blocked", diagnosisSummary: nil,
                resumeAt: nil, retryCount: 0, retryLimit: 3,
                degradedUntil: nil, updatedAt: "2026-01-01T00:00:00Z"
            )
        )
        XCTAssertEqual(degraded.recoveryStatusText, "降级中")

        let failed = PipelineCycleHistory(
            id: "h3", round: 1, stages: [], startDate: Date(), stageEntries: [],
            recovery: EvolutionRecoveryDTO(
                phase: "failed", strategy: "none",
                diagnosisCode: "unknown_system", diagnosisSummary: nil,
                resumeAt: nil, retryCount: 0, retryLimit: 3,
                degradedUntil: nil, updatedAt: "2026-01-01T00:00:00Z"
            )
        )
        XCTAssertEqual(failed.recoveryStatusText, "恢复失败")

        let noRecovery = PipelineCycleHistory(
            id: "h4", round: 1, stages: [], startDate: Date(), stageEntries: []
        )
        XCTAssertNil(noRecovery.recoveryStatusText)
    }

    func testPipelineCycleHistoryRetryBlockedByRecovery() {
        let blocked = PipelineCycleHistory(
            id: "h1", round: 1, stages: [], startDate: Date(), stageEntries: [],
            retryable: true,
            recovery: EvolutionRecoveryDTO(
                phase: "recovering", strategy: "retry_stage",
                diagnosisCode: "transient_session", diagnosisSummary: nil,
                resumeAt: nil, retryCount: 1, retryLimit: 3,
                degradedUntil: nil, updatedAt: "2026-01-01T00:00:00Z"
            )
        )
        XCTAssertTrue(blocked.isRetryBlockedByRecovery)

        let notBlocked = PipelineCycleHistory(
            id: "h2", round: 1, stages: [], startDate: Date(), stageEntries: [],
            retryable: true,
            recovery: EvolutionRecoveryDTO(
                phase: "failed", strategy: "none",
                diagnosisCode: "unknown_system", diagnosisSummary: nil,
                resumeAt: nil, retryCount: 0, retryLimit: 0,
                degradedUntil: nil, updatedAt: "2026-01-01T00:00:00Z"
            )
        )
        XCTAssertFalse(notBlocked.isRetryBlockedByRecovery)
    }

    // MARK: - 向后兼容：旧协议无 recovery 字段

    func testBackwardCompatibilityWithoutRecoveryField() {
        // 模拟旧 Core（v1.47 及更早）输出的 JSON，不包含 recovery 字段
        let workspaceJson: [String: Any] = [
            "project": "legacy-project",
            "workspace": "default",
            "cycle_id": "cycle-legacy",
            "status": "completed",
            "current_stage": "auto_commit",
            "global_loop_round": 3,
            "loop_round_limit": 5,
            "verify_iteration": 0,
            "verify_iteration_limit": 5,
            "agents": [],
            "executions": [],
            "retryable": false
        ]

        let item = EvolutionWorkspaceItemV2.from(json: workspaceJson)
        XCTAssertNotNil(item)
        XCTAssertNil(item?.recovery)
        XCTAssertEqual(item?.retryable, false)
    }
}
