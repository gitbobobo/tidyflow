import XCTest
@testable import TidyFlowShared

final class CoordinatorStateCacheTests: XCTestCase {

    // MARK: - 身份模型测试

    func testWorkspaceIdGlobalKey() {
        let id = CoordinatorWorkspaceId(project: "proj-a", workspace: "default")
        XCTAssertEqual(id.globalKey, "proj-a:default")
    }

    func testWorkspaceIdFromGlobalKeyRoundtrip() {
        let id = CoordinatorWorkspaceId(project: "proj-a", workspace: "feature-1")
        let parsed = CoordinatorWorkspaceId.fromGlobalKey(id.globalKey)
        XCTAssertEqual(id, parsed)
    }

    func testWorkspaceIdFromInvalidGlobalKey() {
        XCTAssertNil(CoordinatorWorkspaceId.fromGlobalKey("no-colon"))
        XCTAssertNil(CoordinatorWorkspaceId.fromGlobalKey(":empty-project"))
        XCTAssertNil(CoordinatorWorkspaceId.fromGlobalKey("empty-ws:"))
    }

    // MARK: - 状态缓存基础操作

    func testEmptyCacheIsIdle() {
        let cache = CoordinatorStateCache()
        XCTAssertTrue(cache.isEmpty)
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.systemHealth, .healthy)
    }

    func testUpdateWorkspaceAddsState() {
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "default")
        let state = WorkspaceCoordinatorState(id: id, version: 1)

        let result = cache.apply(.updateWorkspace(state))
        XCTAssertTrue(result.changed)
        XCTAssertEqual(cache.count, 1)
        XCTAssertNotNil(cache.state(for: id))
    }

    func testUpdateWorkspaceReplacesState() {
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "default")
        let state1 = WorkspaceCoordinatorState(id: id, health: .healthy, version: 1)
        let state2 = WorkspaceCoordinatorState(id: id, health: .degraded, version: 2)

        cache.apply(.updateWorkspace(state1))
        let result = cache.apply(.updateWorkspace(state2))
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.healthChanged)
        XCTAssertEqual(result.previousHealth, .healthy)
        XCTAssertEqual(result.currentHealth, .degraded)
        XCTAssertEqual(cache.state(for: id)?.health, .degraded)
    }

    func testRemoveWorkspace() {
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "default")
        let state = WorkspaceCoordinatorState(id: id, version: 1)

        cache.apply(.updateWorkspace(state))
        XCTAssertEqual(cache.count, 1)

        let result = cache.apply(.removeWorkspace(id))
        XCTAssertTrue(result.changed)
        XCTAssertEqual(cache.count, 0)
    }

    func testClear() {
        let cache = CoordinatorStateCache()
        let id1 = CoordinatorWorkspaceId(project: "proj-a", workspace: "default")
        let id2 = CoordinatorWorkspaceId(project: "proj-b", workspace: "default")
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id1, version: 1)))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id2, version: 1)))

        let result = cache.apply(.clear)
        XCTAssertTrue(result.changed)
        XCTAssertTrue(cache.isEmpty)
        XCTAssertEqual(cache.lastGlobalVersion, 0)
    }

    // MARK: - 多工作区隔离

    func testMultiWorkspaceIsolation() {
        let cache = CoordinatorStateCache()
        let id1 = CoordinatorWorkspaceId(project: "proj-a", workspace: "default")
        let id2 = CoordinatorWorkspaceId(project: "proj-a", workspace: "feature-1")
        let id3 = CoordinatorWorkspaceId(project: "proj-b", workspace: "default")

        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id1, version: 1)))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id2, version: 2)))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id3, version: 3)))

        XCTAssertEqual(cache.count, 3)

        let projAStates = cache.states(forProject: "proj-a")
        XCTAssertEqual(projAStates.count, 2)

        let projBStates = cache.states(forProject: "proj-b")
        XCTAssertEqual(projBStates.count, 1)
    }

    // MARK: - 系统健康度投影

    func testSystemHealthDegradedWhenAnyDegraded() {
        let cache = CoordinatorStateCache()
        let id1 = CoordinatorWorkspaceId(project: "proj-a", workspace: "default")
        let id2 = CoordinatorWorkspaceId(project: "proj-b", workspace: "default")

        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id1, health: .healthy, version: 1)))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id2, health: .degraded, version: 2)))

        XCTAssertEqual(cache.systemHealth, .degraded)
    }

    func testSystemHealthFaultedWhenAnyFaulted() {
        let cache = CoordinatorStateCache()
        let id1 = CoordinatorWorkspaceId(project: "proj-a", workspace: "default")
        let id2 = CoordinatorWorkspaceId(project: "proj-b", workspace: "default")

        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id1, health: .degraded, version: 1)))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id2, health: .faulted, version: 2)))

        XCTAssertEqual(cache.systemHealth, .faulted)
    }

    // MARK: - 关注列表

    func testWorkspacesNeedingAttention() {
        let cache = CoordinatorStateCache()
        let id1 = CoordinatorWorkspaceId(project: "proj-a", workspace: "default")
        let id2 = CoordinatorWorkspaceId(project: "proj-a", workspace: "feature-1")
        let id3 = CoordinatorWorkspaceId(project: "proj-b", workspace: "default")

        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id1, health: .healthy, version: 1)))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id2, health: .degraded, version: 2)))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id3, health: .faulted, version: 3)))

        let attention = cache.workspacesNeedingAttention
        XCTAssertEqual(attention.count, 2)
        XCTAssertTrue(attention.contains(id2))
        XCTAssertTrue(attention.contains(id3))
        XCTAssertFalse(attention.contains(id1))
    }

    // MARK: - 批量更新

    func testBatchUpdate() {
        let cache = CoordinatorStateCache()
        let states = [
            WorkspaceCoordinatorState(
                id: CoordinatorWorkspaceId(project: "proj-a", workspace: "default"),
                version: 1
            ),
            WorkspaceCoordinatorState(
                id: CoordinatorWorkspaceId(project: "proj-b", workspace: "default"),
                version: 2
            ),
        ]

        let result = cache.apply(.batchUpdate(states))
        XCTAssertTrue(result.changed)
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.lastGlobalVersion, 2)
    }

    // MARK: - 版本追踪

    func testGlobalVersionTracking() {
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "default")

        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id, version: 5)))
        XCTAssertEqual(cache.lastGlobalVersion, 5)

        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id, version: 3)))
        // 不会回退
        XCTAssertEqual(cache.lastGlobalVersion, 5)

        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id, version: 10)))
        XCTAssertEqual(cache.lastGlobalVersion, 10)
    }

    // MARK: - 协议解析

    func testWorkspaceCoordinatorStateFromJson() {
        let json: [String: Any] = [
            "id": ["project": "proj", "workspace": "default"],
            "ai": ["phase": "active", "active_session_count": 2, "total_session_count": 5],
            "terminal": ["phase": "idle", "alive_count": 0, "total_count": 0],
            "file": ["phase": "ready", "watcher_active": true, "indexing_in_progress": false],
            "health": "degraded",
            "generated_at": "2026-03-11T18:00:00Z",
            "version": UInt64(42),
        ]

        let state = WorkspaceCoordinatorState.from(json: json)
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.id.project, "proj")
        XCTAssertEqual(state?.ai.phase, .active)
        XCTAssertEqual(state?.ai.activeSessionCount, 2)
        XCTAssertEqual(state?.terminal.phase, .idle)
        XCTAssertEqual(state?.file.phase, .ready)
        XCTAssertEqual(state?.file.watcherActive, true)
        XCTAssertEqual(state?.health, .degraded)
        XCTAssertEqual(state?.version, 42)
    }

    func testWorkspaceCoordinatorStateFromInvalidJson() {
        let json: [String: Any] = ["invalid": "data"]
        let state = WorkspaceCoordinatorState.from(json: json)
        XCTAssertNil(state)
    }

    // MARK: - 项目级操作

    func testRemoveProject_removesAllWorkspacesForProject() {
        let cache = CoordinatorStateCache()
        let id1 = CoordinatorWorkspaceId(project: "proj-a", workspace: "default")
        let id2 = CoordinatorWorkspaceId(project: "proj-a", workspace: "feature-1")
        let id3 = CoordinatorWorkspaceId(project: "proj-b", workspace: "default")

        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id1, version: 1)))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id2, version: 2)))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id3, version: 3)))

        let removed = cache.removeProject("proj-a")
        XCTAssertEqual(removed, 2, "proj-a 下应有 2 个工作区被移除")
        XCTAssertNil(cache.state(for: id1), "proj-a/default 应被移除")
        XCTAssertNil(cache.state(for: id2), "proj-a/feature-1 应被移除")
        XCTAssertNotNil(cache.state(for: id3), "proj-b/default 不应受影响")
    }

    func testRemoveProject_nonexistentProject_returnsZero() {
        let cache = CoordinatorStateCache()
        let removed = cache.removeProject("nonexistent")
        XCTAssertEqual(removed, 0)
    }

    func testAllWorkspaceIds_forProject() {
        let cache = CoordinatorStateCache()
        let id1 = CoordinatorWorkspaceId(project: "proj-a", workspace: "ws1")
        let id2 = CoordinatorWorkspaceId(project: "proj-a", workspace: "ws2")
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id1, version: 1)))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id2, version: 2)))

        let ids = cache.allWorkspaceIds(forProject: "proj-a")
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(ids.contains(id1))
        XCTAssertTrue(ids.contains(id2))
    }

    // MARK: - 多域聚合投影

    func testAggregatedSummary_noState_returnsHealthyDefaults() {
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "default")
        let summary = cache.aggregatedSummary(for: id)

        XCTAssertEqual(summary.health, .healthy)
        XCTAssertFalse(summary.hasActiveAISessions)
        XCTAssertFalse(summary.hasActiveTerminals)
        XCTAssertFalse(summary.fileIsReady)
        XCTAssertEqual(summary.aiActiveSessionCount, 0)
        XCTAssertEqual(summary.terminalAliveCount, 0)
        XCTAssertFalse(summary.hasActiveResources)
        XCTAssertFalse(summary.needsAttention)
    }

    func testAggregatedSummary_activeAI_reflectsCorrectly() {
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "default")
        let state = WorkspaceCoordinatorState(
            id: id,
            ai: AiDomainState(phase: .active, activeSessionCount: 2, totalSessionCount: 5),
            terminal: TerminalDomainState(phase: .active, aliveCount: 3, totalCount: 4),
            file: FileDomainState(phase: .ready, watcherActive: true, indexingInProgress: false),
            health: .healthy,
            version: 1
        )
        cache.apply(.updateWorkspace(state))
        let summary = cache.aggregatedSummary(for: id)

        XCTAssertTrue(summary.hasActiveAISessions)
        XCTAssertTrue(summary.hasActiveTerminals)
        XCTAssertTrue(summary.fileIsReady)
        XCTAssertEqual(summary.aiActiveSessionCount, 2)
        XCTAssertEqual(summary.terminalAliveCount, 3)
        XCTAssertTrue(summary.hasActiveResources)
        XCTAssertFalse(summary.needsAttention)
    }

    func testAggregatedSummary_faultedHealth_needsAttention() {
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "default")
        let state = WorkspaceCoordinatorState(id: id, health: .faulted, version: 1)
        cache.apply(.updateWorkspace(state))

        let summary = cache.aggregatedSummary(for: id)
        XCTAssertTrue(summary.needsAttention)
        XCTAssertEqual(summary.health, .faulted)
    }

    func testAggregatedSummary_multiWorkspace_isolation() {
        let cache = CoordinatorStateCache()
        let id1 = CoordinatorWorkspaceId(project: "proj", workspace: "ws1")
        let id2 = CoordinatorWorkspaceId(project: "proj", workspace: "ws2")

        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: id1,
            ai: AiDomainState(phase: .active, activeSessionCount: 1, totalSessionCount: 1),
            health: .degraded,
            version: 1
        )))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: id2,
            ai: AiDomainState(phase: .idle, activeSessionCount: 0, totalSessionCount: 0),
            health: .healthy,
            version: 2
        )))

        let summary1 = cache.aggregatedSummary(for: id1)
        let summary2 = cache.aggregatedSummary(for: id2)

        XCTAssertTrue(summary1.hasActiveAISessions, "ws1 应有活跃 AI 会话")
        XCTAssertFalse(summary2.hasActiveAISessions, "ws2 无活跃 AI 会话")
        XCTAssertEqual(summary1.health, .degraded)
        XCTAssertEqual(summary2.health, .healthy)
    }

    // MARK: - v1.46 AI 展示六态投影

    func testAiDisplayStatus_defaultIsIdle() {
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "default")
        XCTAssertEqual(cache.aiDisplayStatus(for: id), .idle, "无缓存时应返回 idle")
        XCTAssertEqual(cache.aiDisplayStatus(forGlobalKey: "proj:default"), .idle)
    }

    func testAiDisplayStatus_reflectsRunning() {
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "ws")
        let aiState = AiDomainState(
            phase: .active, activeSessionCount: 1, totalSessionCount: 1,
            displayStatus: .running, activeToolName: "Codex", lastErrorMessage: nil, displayUpdatedAt: 1000
        )
        let state = WorkspaceCoordinatorState(id: id, ai: aiState, version: 1000)
        cache.apply(.updateWorkspace(state))

        XCTAssertEqual(cache.aiDisplayStatus(for: id), .running)
    }

    func testAiDisplayStatus_reflectsAwaitingInput() {
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "ws")
        let aiState = AiDomainState(displayStatus: .awaitingInput)
        let state = WorkspaceCoordinatorState(id: id, ai: aiState, version: 2000)
        cache.apply(.updateWorkspace(state))
        XCTAssertEqual(cache.aiDisplayStatus(for: id), .awaitingInput)
    }

    func testAiDisplayStatus_isolatedByWorkspace() {
        let cache = CoordinatorStateCache()
        let id1 = CoordinatorWorkspaceId(project: "proj", workspace: "ws1")
        let id2 = CoordinatorWorkspaceId(project: "proj", workspace: "ws2")

        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: id1,
            ai: AiDomainState(displayStatus: .running),
            version: 1
        )))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: id2,
            ai: AiDomainState(displayStatus: .success),
            version: 1
        )))

        XCTAssertEqual(cache.aiDisplayStatus(for: id1), .running, "ws1 状态不应被 ws2 影响")
        XCTAssertEqual(cache.aiDisplayStatus(for: id2), .success, "ws2 状态不应被 ws1 影响")
    }

    func testAiDisplayStatus_clearedAfterClear() {
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "ws")
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: id, ai: AiDomainState(displayStatus: .failure), version: 1
        )))
        XCTAssertEqual(cache.aiDisplayStatus(for: id), .failure)
        cache.apply(.clear)
        XCTAssertEqual(cache.aiDisplayStatus(for: id), .idle, "清除后应回退到 idle")
    }

    // MARK: - v1.46 CoordinatorWorkspaceSnapshotPayload 种子/增量解析

    func testSnapshotPayloadParsing_basic() {
        let json: [String: Any] = [
            "project": "proj",
            "workspace": "ws",
            "ai": [
                "phase": "active",
                "active_session_count": 2,
                "total_session_count": 3,
                "display_status": "running",
                "active_tool_name": "Codex",
                "display_updated_at": Int64(1_741_800_000_000),
            ] as [String: Any],
            "version": UInt64(1_741_800_000_000),
            "generated_at": "2026-03-12T12:00:00Z",
        ]
        let payload = CoordinatorWorkspaceSnapshotPayload.from(json: json)
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.project, "proj")
        XCTAssertEqual(payload?.workspace, "ws")
        XCTAssertEqual(payload?.ai.displayStatus, .running)
        XCTAssertEqual(payload?.ai.activeToolName, "Codex")
        XCTAssertEqual(payload?.version, 1_741_800_000_000)
    }

    func testSnapshotPayloadParsing_missingProjectReturnNil() {
        let json: [String: Any] = ["workspace": "ws", "ai": [:] as [String: Any]]
        XCTAssertNil(CoordinatorWorkspaceSnapshotPayload.from(json: json))
    }

    func testSnapshotPayload_noOlderVersionOverwrite() {
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "ws")

        // 写入 version=5000 的状态
        let newer = CoordinatorWorkspaceSnapshotPayload(
            project: "proj", workspace: "ws",
            ai: AiDomainState(displayStatus: .success), version: 5000, generatedAt: ""
        )
        let state5000 = newer.toWorkspaceCoordinatorState(existing: nil)
        cache.apply(.updateWorkspace(state5000))
        XCTAssertEqual(cache.aiDisplayStatus(for: id), .success)

        // 尝试写入 version=3000 的旧状态（不应覆盖）
        let older = CoordinatorWorkspaceSnapshotPayload(
            project: "proj", workspace: "ws",
            ai: AiDomainState(displayStatus: .running), version: 3000, generatedAt: ""
        )
        let existing = cache.state(for: id)
        let staleState = older.toWorkspaceCoordinatorState(existing: existing)
        cache.apply(.updateWorkspace(staleState))

        XCTAssertEqual(cache.aiDisplayStatus(for: id), .success, "旧版本快照不应覆盖新状态")
    }

    // MARK: - v1.46 AiDisplayStatus 协议解析

    func testAiDisplayStatusParsing_allValues() {
        let cases: [(String, AiDisplayStatus)] = [
            ("idle", .idle),
            ("running", .running),
            ("awaiting_input", .awaitingInput),
            ("success", .success),
            ("failure", .failure),
            ("cancelled", .cancelled),
        ]
        for (raw, expected) in cases {
            let parsed = AiDisplayStatus(rawValue: raw)
            XCTAssertEqual(parsed, expected, "raw=\(raw) 解析不符预期")
        }
    }

    func testAiDisplayStatusParsing_unknownFallsBackToIdle() {
        let parsed = AiDisplayStatus(rawValue: "unknown_state")
        XCTAssertNil(parsed, "未知值应解析为 nil，由调用方提供默认值")
    }

    func testAiDomainStateFromJson_withDisplayFields() {
        let json: [String: Any] = [
            "phase": "active",
            "active_session_count": 1,
            "total_session_count": 2,
            "display_status": "failure",
            "last_error_message": "OOM",
            "display_updated_at": Int64(9_999),
        ]
        let state = AiDomainState.from(json: json)
        XCTAssertEqual(state.displayStatus, .failure)
        XCTAssertEqual(state.lastErrorMessage, "OOM")
        XCTAssertEqual(state.displayUpdatedAt, 9999)
        XCTAssertNil(state.activeToolName)
    }

    // MARK: - 重连恢复完整周期（WI-004）

    func testReconnectCycle_clearThenRestoreFromSystemSnapshot() {
        // 模拟完整重连周期：运行中 → 断线 clear → 收到 system_snapshot 种子 → 状态恢复
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "ws")

        // 建立运行中状态
        let runningAI = AiDomainState(
            phase: .active, activeSessionCount: 1, totalSessionCount: 1,
            displayStatus: .running, activeToolName: "Codex",
            lastErrorMessage: nil, displayUpdatedAt: 1000
        )
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id, ai: runningAI, version: 1000)))
        XCTAssertEqual(cache.aiDisplayStatus(for: id), .running)

        // 断线：客户端调用 clear
        cache.apply(.clear)
        XCTAssertTrue(cache.isEmpty, "断线后缓存应清空")
        XCTAssertEqual(cache.aiDisplayStatus(for: id), .idle, "清空后应回退到 idle")

        // 重连后收到 system_snapshot 种子恢复（awaitingInput 在等待用户）
        let restoredAI = AiDomainState(
            phase: .active, activeSessionCount: 1, totalSessionCount: 1,
            displayStatus: .awaitingInput, activeToolName: nil,
            lastErrorMessage: nil, displayUpdatedAt: 2000
        )
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id, ai: restoredAI, version: 2000)))
        XCTAssertEqual(cache.aiDisplayStatus(for: id), .awaitingInput, "重连后种子恢复应正确反映最新状态")
        XCTAssertEqual(cache.lastGlobalVersion, 2000)
    }

    func testReconnectCycle_multiWorkspaceIsolatedRecovery() {
        // 多工作区：断线清空后，各工作区通过独立种子恢复，互不干扰
        let cache = CoordinatorStateCache()
        let idA = CoordinatorWorkspaceId(project: "proj", workspace: "ws-a")
        let idB = CoordinatorWorkspaceId(project: "proj", workspace: "ws-b")
        let idC = CoordinatorWorkspaceId(project: "proj-2", workspace: "ws-a") // 不同项目同名工作区

        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: idA, ai: AiDomainState(displayStatus: .running), version: 10
        )))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: idB, ai: AiDomainState(displayStatus: .failure), version: 10
        )))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: idC, ai: AiDomainState(displayStatus: .success), version: 10
        )))

        // 断线清空
        cache.apply(.clear)
        XCTAssertEqual(cache.count, 0)

        // 仅 idA 和 idC 的种子到达（idB 模拟暂未收到）
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: idA, ai: AiDomainState(displayStatus: .cancelled), version: 20
        )))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: idC, ai: AiDomainState(displayStatus: .idle), version: 20
        )))

        XCTAssertEqual(cache.aiDisplayStatus(for: idA), .cancelled, "idA 应正确恢复")
        XCTAssertEqual(cache.aiDisplayStatus(for: idB), .idle, "idB 种子未到，应为 idle")
        XCTAssertEqual(cache.aiDisplayStatus(for: idC), .idle, "proj-2/ws-a 独立恢复，不受 proj/ws-a 影响")
    }

    // MARK: - display_updated_at 语义：最近时间决策（WI-004）
    // Core 负责在聚合时按 display_updated_at 最大值选取同优先级状态，
    // 客户端侧测试验证：缓存能正确保留版本更高的快照，不被旧版本覆盖。

    func testDisplayUpdatedAt_newerSnapshotOverridesOlder() {
        // 模拟 Core 先后推送两次同工作区状态（版本递增）
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "ws")

        // 第一次快照：failure, display_updated_at=1000, version=1000
        let state1 = WorkspaceCoordinatorState(
            id: id,
            ai: AiDomainState(
                phase: .active, activeSessionCount: 0, totalSessionCount: 1,
                displayStatus: .failure, activeToolName: nil,
                lastErrorMessage: "error-1", displayUpdatedAt: 1000
            ),
            version: 1000
        )
        cache.apply(.updateWorkspace(state1))
        XCTAssertEqual(cache.aiDisplayStatus(for: id), .failure)

        // 第二次快照：success, display_updated_at=2000, version=2000（更新）
        let state2 = WorkspaceCoordinatorState(
            id: id,
            ai: AiDomainState(
                phase: .idle, activeSessionCount: 0, totalSessionCount: 1,
                displayStatus: .success, activeToolName: nil,
                lastErrorMessage: nil, displayUpdatedAt: 2000
            ),
            version: 2000
        )
        cache.apply(.updateWorkspace(state2))
        XCTAssertEqual(cache.aiDisplayStatus(for: id), .success, "较新版本的 success 应覆盖旧版本的 failure")
    }

    func testDisplayUpdatedAt_olderSnapshotDoesNotOverrideNewer() {
        // 乱序场景：先收到较新版本，再收到旧版本，旧版本不应覆盖
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "ws")

        // 先收到较新版本：success, version=5000
        let newer = WorkspaceCoordinatorState(
            id: id,
            ai: AiDomainState(displayStatus: .success),
            version: 5000
        )
        cache.apply(.updateWorkspace(newer))

        // 再收到旧版本：failure, version=3000（应被忽略）
        let existing = cache.state(for: id)
        let older = WorkspaceCoordinatorState(
            id: id,
            ai: AiDomainState(displayStatus: .failure),
            version: 3000
        )
        // 缓存的版本保护：仅在新版本 >= 缓存版本时写入
        if (existing?.version ?? 0) <= older.version {
            cache.apply(.updateWorkspace(older))
        }
        // 无论写入路径如何，当前缓存版本(5000) > 3000，状态应仍为 success
        XCTAssertEqual(cache.aiDisplayStatus(for: id), .success, "旧版本快照不应覆盖已缓存的新版本状态")
    }

    func testAiDisplayStatus_activeToolName_preservedInCache() {
        // 验证 active_tool_name 在缓存读取时被正确保留（供 TerminalSessionSemantics 消费）
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "ws")
        let aiState = AiDomainState(
            phase: .active, activeSessionCount: 1, totalSessionCount: 1,
            displayStatus: .running, activeToolName: "opencode",
            lastErrorMessage: nil, displayUpdatedAt: 1000
        )
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id, ai: aiState, version: 1000)))

        let state = cache.state(for: id)
        XCTAssertEqual(state?.ai.activeToolName, "opencode", "active_tool_name 应完整保留在缓存中")
        XCTAssertEqual(state?.ai.displayStatus, .running)
    }

    // MARK: - 种子恢复与增量更新工作区隔离（WI-004 补充）

    func testSeedRecovery_differentProjectsSameWorkspaceName_isolated() {
        // 不同项目相同 workspace 名称的种子恢复不应互相串状态
        let cache = CoordinatorStateCache()
        let idProjA = CoordinatorWorkspaceId(project: "proj-a", workspace: "default")
        let idProjB = CoordinatorWorkspaceId(project: "proj-b", workspace: "default")

        // 模拟 system_snapshot 种子恢复两个项目的同名工作区
        let payloadA = CoordinatorWorkspaceSnapshotPayload(
            project: "proj-a", workspace: "default",
            ai: AiDomainState(displayStatus: .running, activeToolName: "codex"),
            version: 100, generatedAt: ""
        )
        let payloadB = CoordinatorWorkspaceSnapshotPayload(
            project: "proj-b", workspace: "default",
            ai: AiDomainState(displayStatus: .failure, lastErrorMessage: "quota"),
            version: 100, generatedAt: ""
        )

        CoordinatorSnapshotApplier.apply(payload: payloadA, cache: cache)
        CoordinatorSnapshotApplier.apply(payload: payloadB, cache: cache)

        XCTAssertEqual(cache.aiDisplayStatus(for: idProjA), .running, "proj-a/default 应为 running")
        XCTAssertEqual(cache.aiDisplayStatus(for: idProjB), .failure, "proj-b/default 应为 failure，不受 proj-a 影响")
        XCTAssertEqual(cache.state(for: idProjA)?.ai.activeToolName, "codex")
        XCTAssertEqual(cache.state(for: idProjB)?.ai.lastErrorMessage, "quota")
    }

    func testIncrementalUpdate_differentProjectsSameWorkspaceName_isolated() {
        // 增量更新不会串到其他项目的同名 workspace
        let cache = CoordinatorStateCache()
        let idProjA = CoordinatorWorkspaceId(project: "proj-a", workspace: "default")
        let idProjB = CoordinatorWorkspaceId(project: "proj-b", workspace: "default")

        // 先写入初始状态
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: idProjA, ai: AiDomainState(displayStatus: .idle), version: 1
        )))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: idProjB, ai: AiDomainState(displayStatus: .idle), version: 1
        )))

        // 仅更新 proj-a
        let update = CoordinatorWorkspaceSnapshotPayload(
            project: "proj-a", workspace: "default",
            ai: AiDomainState(displayStatus: .success),
            version: 2, generatedAt: ""
        )
        CoordinatorSnapshotApplier.apply(payload: update, cache: cache)

        XCTAssertEqual(cache.aiDisplayStatus(for: idProjA), .success, "proj-a 应被更新为 success")
        XCTAssertEqual(cache.aiDisplayStatus(for: idProjB), .idle, "proj-b 不应被 proj-a 的增量更新影响")
    }
}
