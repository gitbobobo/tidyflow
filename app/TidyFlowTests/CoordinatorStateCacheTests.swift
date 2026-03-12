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
}
