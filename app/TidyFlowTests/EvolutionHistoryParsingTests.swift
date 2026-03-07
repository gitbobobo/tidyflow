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
                    "stage": "verify",
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
        XCTAssertEqual(item?.stages.last?.stage, "verify")
    }

    func testWorkspaceItemIgnoresLegacyHandoffPayload() {
        let json: [String: Any] = [
            "project": "tidyflow",
            "workspace": "default",
            "cycle_id": "cycle-1",
            "title": "当前循环标题",
            "status": "running",
            "current_stage": "verify",
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
    }
}
