import XCTest
@testable import TidyFlow

final class EvolutionHistoryParsingTests: XCTestCase {
    func testStageHistoryEntryParsesWithoutHandoffField() {
        let json: [String: Any] = [
            "stage": "implement_general",
            "agent": "ImplementGeneralAgent",
            "ai_tool": "copilot",
            "status": "done",
            "duration_ms": 3_889_786,
            "handoff": [
                "completed": ["legacy"]
            ]
        ]

        let entry = EvolutionCycleStageHistoryEntryV2.from(json: json)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.stage, "implement_general")
        XCTAssertEqual(entry?.agent, "ImplementGeneralAgent")
        XCTAssertEqual(entry?.durationMs, 3_889_786)
    }

    func testCycleHistoryItemIgnoresLegacyHandoffPayload() {
        let json: [String: Any] = [
            "cycle_id": "2026-03-07T06-41-44-767Z",
            "status": "completed",
            "global_loop_round": 1,
            "created_at": "2026-03-07T06:41:44Z",
            "updated_at": "2026-03-07T08:00:00Z",
            "handoff": [
                "completed": ["legacy summary"]
            ],
            "stages": [
                [
                    "stage": "plan",
                    "agent": "PlanAgent",
                    "ai_tool": "codex",
                    "status": "done",
                    "duration_ms": 390_000,
                    "handoff": [
                        "completed": ["legacy stage summary"]
                    ]
                ],
                [
                    "stage": "verify.1",
                    "agent": "VerifyAgent",
                    "ai_tool": "copilot",
                    "status": "done",
                    "duration_ms": 120_000
                ]
            ]
        ]

        let item = EvolutionCycleHistoryItemV2.from(json: json)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.cycleID, "2026-03-07T06-41-44-767Z")
        XCTAssertEqual(item?.stages.count, 2)
        XCTAssertEqual(item?.stages.first?.stage, "plan")
        XCTAssertEqual(item?.stages.last?.stage, "verify.1")
    }

    func testWorkspaceItemIgnoresLegacyHandoffPayload() {
        let json: [String: Any] = [
            "project": "tidyflow",
            "workspace": "default",
            "cycle_id": "cycle-1",
            "title": "当前循环标题",
            "status": "running",
            "current_stage": "verify.1",
            "global_loop_round": 1,
            "loop_round_limit": 3,
            "verify_iteration": 0,
            "verify_iteration_limit": 5,
            "agents": [],
            "executions": [],
            "handoff": [
                "completed": ["legacy"]
            ]
        ]

        let item = EvolutionWorkspaceItemV2.from(json: json)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.cycleID, "cycle-1")
        XCTAssertEqual(item?.title, "当前循环标题")
        XCTAssertEqual(item?.currentStage, "verify.1")
    }
}

final class EvolutionStageSemanticsTests: XCTestCase {
    func testReimplementRuntimeStageMapsToAdvancedProfileStage() {
        XCTAssertEqual(
            EvolutionStageSemantics.profileStageKey(for: "reimplement.1"),
            "implement_advanced"
        )
        XCTAssertEqual(
            EvolutionStageSemantics.profileStageKey(for: "reimplement.2"),
            "implement_advanced"
        )
    }

    func testVerifyRuntimeStageMapsToVerifyProfileStage() {
        XCTAssertEqual(EvolutionStageSemantics.runtimeStageKey("verify.2"), "verify")
        XCTAssertEqual(EvolutionStageSemantics.profileStageKey(for: "verify.2"), "verify")
    }

    func testVerifyRuntimeStageDisplayNameUsesInstanceIndex() {
        XCTAssertEqual(EvolutionStageSemantics.displayName(for: "verify.2"), "Verify #2")
    }

    func testVerifyRuntimeStageSortsAfterReimplementAndBeforeAutoCommit() {
        let reimplementOrder = EvolutionStageSemantics.stageSortOrder("reimplement.1")
        let verifyOrder = EvolutionStageSemantics.stageSortOrder("verify.2")
        let autoCommitOrder = EvolutionStageSemantics.stageSortOrder("auto_commit")

        XCTAssertTrue(reimplementOrder < verifyOrder)
        XCTAssertTrue(verifyOrder < autoCommitOrder)
    }

    func testVerifyRuntimeStageIsRepeatable() {
        XCTAssertTrue(EvolutionStageSemantics.isRepeatableStage("verify.2"))
    }
}
