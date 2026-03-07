import XCTest
@testable import TidyFlow

// AC-003：代理级 Handoff 历史解析测试
// 验证 EvolutionHandoffInfoV2、EvolutionCycleStageHistoryEntryV2 与
// EvolutionCycleHistoryItemV2 的协议解析，确保 stages 级别能携带各阶段自身的
// handoff 元数据，而不仅是循环汇总级别。

final class EvolutionHistoryAgentHandoffTests: XCTestCase {

    // MARK: - EvolutionHandoffInfoV2 解析

    func testHandoffInfoParsesAllSections() {
        let json: [String: Any] = [
            "completed": ["已完成任务A", "已完成任务B"],
            "risks": ["风险一"],
            "next": ["下一步一", "下一步二", "下一步三"],
        ]
        let handoff = EvolutionHandoffInfoV2.from(json: json)
        XCTAssertNotNil(handoff)
        XCTAssertEqual(handoff?.completed, ["已完成任务A", "已完成任务B"])
        XCTAssertEqual(handoff?.risks, ["风险一"])
        XCTAssertEqual(handoff?.next.count, 3)
    }

    func testHandoffInfoReturnsNilWhenAllSectionsEmpty() {
        let empty1 = EvolutionHandoffInfoV2.from(json: [:])
        XCTAssertNil(empty1, "全空 handoff 应返回 nil")

        let empty2 = EvolutionHandoffInfoV2.from(json: [
            "completed": [],
            "risks": [],
            "next": [],
        ])
        XCTAssertNil(empty2, "三个空数组应视为空 handoff 并返回 nil")
    }

    func testHandoffInfoFiltersEmptyStrings() {
        let json: [String: Any] = [
            "completed": ["有效条目", "  ", ""],
            "risks": [],
            "next": ["  有效  "],
        ]
        let handoff = EvolutionHandoffInfoV2.from(json: json)
        XCTAssertNotNil(handoff)
        XCTAssertEqual(handoff?.completed, ["有效条目"], "空白字符串应被过滤")
        XCTAssertEqual(handoff?.next, ["有效"], "应对条目做 trim 处理")
    }

    func testHandoffInfoIsEquatable() {
        let a = EvolutionHandoffInfoV2(completed: ["a"], risks: [], next: [])
        let b = EvolutionHandoffInfoV2(completed: ["a"], risks: [], next: [])
        let c = EvolutionHandoffInfoV2(completed: ["b"], risks: [], next: [])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - EvolutionCycleStageHistoryEntryV2 解析（含 handoff 字段）

    /// AC-003 核心：stage history entry 能携带该阶段自己的 handoff 信息
    func testStageHistoryEntryParsesHandoff() {
        let json: [String: Any] = [
            "stage": "implement_general",
            "agent": "ImplementGeneralAgent",
            "ai_tool": "copilot",
            "status": "done",
            "duration_ms": 3_889_786,
            "handoff": [
                "completed": ["WI-001 完成", "WI-002 完成"],
                "risks": ["WI-005 不广播 EvoCycleUpdated"],
                "next": ["进入 implement_advanced"],
            ],
        ]
        let entry = EvolutionCycleStageHistoryEntryV2.from(json: json)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.stage, "implement_general")
        XCTAssertEqual(entry?.agent, "ImplementGeneralAgent")
        XCTAssertNotNil(entry?.handoff, "阶段 handoff 字段应被正确解析")
        XCTAssertEqual(entry?.handoff?.completed.count, 2)
        XCTAssertEqual(entry?.handoff?.risks.count, 1)
        XCTAssertEqual(entry?.handoff?.next.count, 1)
    }

    /// 没有 handoff 字段时，返回 nil 而不是崩溃
    func testStageHistoryEntryWithoutHandoffIsNil() {
        let json: [String: Any] = [
            "stage": "plan",
            "agent": "PlanAgent",
            "ai_tool": "codex",
            "status": "done",
            "duration_ms": 390_000,
        ]
        let entry = EvolutionCycleStageHistoryEntryV2.from(json: json)
        XCTAssertNotNil(entry, "缺少 handoff 字段时 entry 仍应成功解析")
        XCTAssertNil(entry?.handoff, "缺少 handoff 时字段应为 nil")
    }

    /// stage 字段缺失时整条记录应返回 nil
    func testStageHistoryEntryRequiresStageField() {
        let json: [String: Any] = [
            "agent": "PlanAgent",
            "status": "done",
        ]
        XCTAssertNil(EvolutionCycleStageHistoryEntryV2.from(json: json))
    }

    // MARK: - EvolutionCycleHistoryItemV2 解析（含 stages 数组）

    /// 循环历史条目能同时携带 cycle-level handoff 和 stages 数组中各阶段的 handoff
    func testCycleHistoryItemParsesStagesWithHandoffs() {
        let json: [String: Any] = [
            "cycle_id": "2026-03-07T06-41-44-767Z",
            "status": "completed",
            "global_loop_round": 1,
            "created_at": "2026-03-07T06:41:44Z",
            "updated_at": "2026-03-07T08:00:00Z",
            "handoff": [
                "completed": ["循环总结"],
                "risks": [],
                "next": [],
            ],
            "stages": [
                [
                    "stage": "plan",
                    "agent": "PlanAgent",
                    "ai_tool": "codex",
                    "status": "done",
                    "duration_ms": 390_000,
                    "handoff": [
                        "completed": ["完成计划"],
                        "risks": [],
                        "next": ["进入实现"],
                    ],
                ],
                [
                    "stage": "implement_general",
                    "agent": "ImplementGeneralAgent",
                    "ai_tool": "copilot",
                    "status": "done",
                    "duration_ms": 3_889_786,
                    // 无 handoff
                ],
                [
                    "stage": "verify",
                    "agent": "VerifyAgent",
                    "ai_tool": "copilot",
                    "status": "done",
                    "duration_ms": 120_000,
                    "handoff": [
                        "completed": ["验证通过"],
                        "risks": ["测试覆盖不足"],
                        "next": [],
                    ],
                ],
            ],
        ]

        let item = EvolutionCycleHistoryItemV2.from(json: json)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.cycleID, "2026-03-07T06-41-44-767Z")
        XCTAssertEqual(item?.stages.count, 3, "应解析出 3 个阶段")

        // cycle-level handoff
        XCTAssertNotNil(item?.handoff)
        XCTAssertEqual(item?.handoff?.completed, ["循环总结"])

        // stages 级别 handoff
        let planStage = item?.stages.first { $0.stage == "plan" }
        XCTAssertNotNil(planStage?.handoff, "plan 阶段 handoff 应存在")
        XCTAssertEqual(planStage?.handoff?.completed, ["完成计划"])

        let implStage = item?.stages.first { $0.stage == "implement_general" }
        XCTAssertNil(implStage?.handoff, "implement_general 无 handoff，应为 nil")

        let verifyStage = item?.stages.first { $0.stage == "verify" }
        XCTAssertNotNil(verifyStage?.handoff)
        XCTAssertEqual(verifyStage?.handoff?.risks, ["测试覆盖不足"])
    }

    func testCycleHistoryItemRequiresCycleId() {
        XCTAssertNil(EvolutionCycleHistoryItemV2.from(json: [:]))
        XCTAssertNil(EvolutionCycleHistoryItemV2.from(json: ["status": "completed"]))
    }

    /// 空 stages 数组不影响解析
    func testCycleHistoryItemWithEmptyStages() {
        let json: [String: Any] = [
            "cycle_id": "cycle-empty",
            "status": "completed",
            "created_at": "",
            "updated_at": "",
            "stages": [],
        ]
        let item = EvolutionCycleHistoryItemV2.from(json: json)
        XCTAssertNotNil(item)
        XCTAssertTrue(item!.stages.isEmpty)
        XCTAssertNil(item?.handoff)
    }

    // MARK: - 多阶段选择语义：按阶段名筛选 handoff

    /// 客户端可通过 stages 数组按 stage 名称找到对应代理的 handoff，
    /// 若某阶段缺失 handoff，结果为 nil 而不是回退到其他阶段内容。
    func testStageHandoffLookupByNameIsExactAndIsolated() {
        let stages: [EvolutionCycleStageHistoryEntryV2] = [
            makeStageEntry(stage: "plan", hasHandoff: true),
            makeStageEntry(stage: "implement_general", hasHandoff: false),
            makeStageEntry(stage: "verify", hasHandoff: true),
        ]

        // 精确查找存在 handoff 的阶段
        let planHandoff = stages.first { $0.stage == "plan" }?.handoff
        XCTAssertNotNil(planHandoff)

        // 精确查找缺失 handoff 的阶段，不应回退到其他阶段
        let implHandoff = stages.first { $0.stage == "implement_general" }?.handoff
        XCTAssertNil(implHandoff, "缺少 handoff 的阶段查找结果应为 nil，不应误读其他阶段内容")

        // 不存在的阶段返回 nil
        let unknownHandoff = stages.first { $0.stage == "direction" }?.handoff
        XCTAssertNil(unknownHandoff)
    }

    // MARK: - 私有辅助

    private func makeStageEntry(stage: String, hasHandoff: Bool) -> EvolutionCycleStageHistoryEntryV2 {
        var json: [String: Any] = [
            "stage": stage,
            "agent": "\(stage.capitalized)Agent",
            "ai_tool": "copilot",
            "status": "done",
            "duration_ms": 100_000,
        ]
        if hasHandoff {
            json["handoff"] = [
                "completed": ["\(stage) 完成"],
                "risks": [],
                "next": [],
            ]
        }
        return EvolutionCycleStageHistoryEntryV2.from(json: json)!
    }
}
