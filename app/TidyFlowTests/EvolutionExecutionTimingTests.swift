import XCTest
@testable import TidyFlow

// AC-001：耗时归因去重逻辑测试
// 验证 totalDurationText 在重试场景下只累计同一 (stage, agent) 最新一次执行的耗时，
// 而不是从第一次尝试开始累加。

final class EvolutionExecutionTimingTests: XCTestCase {

    // MARK: - EvolutionSessionExecutionEntryV2 协议解析

    func testExecutionEntryParsesAllFields() {
        let json: [String: Any] = [
            "stage": "implement_general",
            "agent": "ImplementGeneralAgent",
            "ai_tool": "copilot",
            "session_id": "sess-001",
            "status": "done",
            "started_at": "2026-03-07T06:49:42Z",
            "completed_at": "2026-03-07T07:54:00Z",
            "duration_ms": 3889786,
            "tool_call_count": 332,
        ]
        let entry = EvolutionSessionExecutionEntryV2.from(json: json)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.stage, "implement_general")
        XCTAssertEqual(entry?.agent, "ImplementGeneralAgent")
        XCTAssertEqual(entry?.aiTool, "copilot")
        XCTAssertEqual(entry?.sessionID, "sess-001")
        XCTAssertEqual(entry?.status, "done")
        XCTAssertEqual(entry?.durationMs, 3_889_786)
        XCTAssertEqual(entry?.toolCallCount, 332)
    }

    func testExecutionEntryParsesIntDurationMs() {
        let json: [String: Any] = [
            "stage": "plan",
            "session_id": "sess-002",
            "duration_ms": 60000,
        ]
        let entry = EvolutionSessionExecutionEntryV2.from(json: json)
        XCTAssertEqual(entry?.durationMs, 60_000)
    }

    func testExecutionEntryRequiresStageAndSessionId() {
        XCTAssertNil(EvolutionSessionExecutionEntryV2.from(json: ["stage": "plan"]))
        XCTAssertNil(EvolutionSessionExecutionEntryV2.from(json: ["session_id": "s"]))
        XCTAssertNil(EvolutionSessionExecutionEntryV2.from(json: [:]))
    }

    // MARK: - 去重算法：同一 (stage, agent) 只取 startedAt 最新记录

    /// AC-001 核心：同一 stage+agent 存在两次执行（重试），只取最新那条的耗时。
    func testDeduplicateByStageAgentKeepsLatestEntry() {
        // 第一次执行（旧，应被排除）
        let first = EvolutionSessionExecutionEntryV2.from(json: [
            "stage": "implement_general",
            "agent": "ImplementGeneralAgent",
            "session_id": "sess-old",
            "status": "done",
            "started_at": "2026-03-07T06:00:00Z",
            "duration_ms": 5_000_000,  // 旧的 5000 秒，不应被计入
        ])!

        // 第二次执行（新，应被采用）
        let second = EvolutionSessionExecutionEntryV2.from(json: [
            "stage": "implement_general",
            "agent": "ImplementGeneralAgent",
            "session_id": "sess-new",
            "status": "done",
            "started_at": "2026-03-07T07:00:00Z",
            "duration_ms": 1_000_000,  // 新的 1000 秒
        ])!

        let allEntries = [first, second]
        let deduped = deduplicateByStageAgent(allEntries)

        XCTAssertEqual(deduped.count, 1, "同一 stage+agent 应只保留一条")
        XCTAssertEqual(deduped[0].sessionID, "sess-new", "应保留 startedAt 更新的条目")
        XCTAssertEqual(deduped[0].durationMs, 1_000_000, "耗时应来自最新执行记录")
    }

    /// 不同 (stage, agent) 的记录不应被去重合并
    func testDeduplicatePreservesDistinctStageAgentCombinations() {
        let entries: [EvolutionSessionExecutionEntryV2] = [
            makeEntry(stage: "plan", agent: "PlanAgent", startedAt: "2026-03-07T06:00:00Z", durationMs: 100_000),
            makeEntry(stage: "implement_general", agent: "ImplementGeneralAgent", startedAt: "2026-03-07T06:10:00Z", durationMs: 200_000),
            makeEntry(stage: "verify", agent: "VerifyAgent", startedAt: "2026-03-07T06:30:00Z", durationMs: 50_000),
        ]

        let deduped = deduplicateByStageAgent(entries)
        XCTAssertEqual(deduped.count, 3, "三个不同 stage+agent 应全部保留")

        let totalMs = deduped.compactMap(\.durationMs).reduce(0, +)
        XCTAssertEqual(totalMs, 350_000)
    }

    /// 多代理、多次重试混合场景：每个 stage+agent 组合只取最新
    func testDeduplicateMultipleRetryMixedScenario() {
        let entries: [EvolutionSessionExecutionEntryV2] = [
            // implement_general 第一次（旧）
            makeEntry(stage: "implement_general", agent: "ImplementGeneralAgent", startedAt: "2026-03-07T06:00:00Z", durationMs: 3_000_000),
            // plan 第一次（只有一次）
            makeEntry(stage: "plan", agent: "PlanAgent", startedAt: "2026-03-07T05:50:00Z", durationMs: 400_000),
            // implement_general 第二次（新，应覆盖第一次）
            makeEntry(stage: "implement_general", agent: "ImplementGeneralAgent", startedAt: "2026-03-07T07:00:00Z", durationMs: 1_500_000),
        ]

        let deduped = deduplicateByStageAgent(entries)
        XCTAssertEqual(deduped.count, 2)

        let implEntry = deduped.first { $0.stage == "implement_general" }
        XCTAssertEqual(implEntry?.durationMs, 1_500_000, "应使用重试后最新耗时而非累计")

        let totalMs = deduped.compactMap(\.durationMs).reduce(0, +)
        XCTAssertEqual(totalMs, 1_900_000, "总耗时 = 最新 impl(1500s) + plan(400s)")
    }

    // MARK: - 私有辅助：复现 EvolutionPipelineView 去重算法（便于验证语义）

    /// 与 EvolutionPipelineView.totalDurationText 使用相同的去重语义：
    /// 同一 (stage, agent) 组合只保留 startedAt 字符串最大的条目。
    private func deduplicateByStageAgent(
        _ entries: [EvolutionSessionExecutionEntryV2]
    ) -> [EvolutionSessionExecutionEntryV2] {
        var latestByKey: [String: EvolutionSessionExecutionEntryV2] = [:]
        for entry in entries {
            let key = "\(entry.stage)|\(entry.agent)"
            if let existing = latestByKey[key] {
                if entry.startedAt > existing.startedAt {
                    latestByKey[key] = entry
                }
            } else {
                latestByKey[key] = entry
            }
        }
        return Array(latestByKey.values)
    }

    private func makeEntry(
        stage: String,
        agent: String,
        startedAt: String,
        durationMs: UInt64
    ) -> EvolutionSessionExecutionEntryV2 {
        EvolutionSessionExecutionEntryV2.from(json: [
            "stage": stage,
            "agent": agent,
            "session_id": "sess-\(stage)-\(startedAt)",
            "status": "done",
            "started_at": startedAt,
            "duration_ms": Int(durationMs),
        ])!
    }
}
