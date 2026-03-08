import XCTest
@testable import TidyFlow

/// 工作区缓存指标语义测试（WI-005）
///
/// 覆盖：
/// - `SystemSnapshotCacheMetrics.from()` 解析
/// - `metrics(project:workspace:)` 多项目隔离
/// - `FileCacheMetricsModel.from()` 字段语义
/// - `WorkspaceCacheMetricsModel` 字段语义
/// - 预算超限标志和淘汰原因不在客户端重算
final class WorkspaceCacheMetricsSemanticsTests: XCTestCase {

    // MARK: - SystemSnapshotCacheMetrics 解析

    func testFromJSON_nil_returnsEmptyMetrics() {
        let result = SystemSnapshotCacheMetrics.from(json: nil)
        XCTAssertTrue(result.index.isEmpty, "nil JSON 应产出空字典")
    }

    func testFromJSON_emptyArray_returnsEmptyMetrics() {
        let result = SystemSnapshotCacheMetrics.from(json: [])
        XCTAssertTrue(result.index.isEmpty, "空数组应产出空字典")
    }

    func testFromJSON_nonArray_returnsEmptyMetrics() {
        let result = SystemSnapshotCacheMetrics.from(json: "invalid")
        XCTAssertTrue(result.index.isEmpty, "非数组 JSON 应产出空字典")
    }

    func testFromJSON_parsesProjectAndWorkspace() {
        let json: [[String: Any]] = [
            makeRawMetrics(project: "proj_a", workspace: "ws1")
        ]
        let result = SystemSnapshotCacheMetrics.from(json: json)
        XCTAssertEqual(result.index.count, 1)
        XCTAssertNotNil(result.index["proj_a:ws1"], "应以 'project:workspace' 为键存储")
    }

    func testFromJSON_multipleEntries_indexedCorrectly() {
        let json: [[String: Any]] = [
            makeRawMetrics(project: "proj_a", workspace: "ws1"),
            makeRawMetrics(project: "proj_b", workspace: "ws1"),
            makeRawMetrics(project: "proj_a", workspace: "default"),
        ]
        let result = SystemSnapshotCacheMetrics.from(json: json)
        XCTAssertEqual(result.index.count, 3, "3 条目应全部解析")
        XCTAssertNotNil(result.index["proj_a:ws1"])
        XCTAssertNotNil(result.index["proj_b:ws1"])
        XCTAssertNotNil(result.index["proj_a:default"])
    }

    func testFromJSON_missingProjectFieldSkipsEntry() {
        let json: [[String: Any]] = [
            ["workspace": "ws1"],  // 缺少 project
        ]
        let result = SystemSnapshotCacheMetrics.from(json: json)
        XCTAssertTrue(result.index.isEmpty, "缺少 project 字段应跳过该条目")
    }

    func testFromJSON_missingWorkspaceFieldSkipsEntry() {
        let json: [[String: Any]] = [
            ["project": "proj_a"],  // 缺少 workspace
        ]
        let result = SystemSnapshotCacheMetrics.from(json: json)
        XCTAssertTrue(result.index.isEmpty, "缺少 workspace 字段应跳过该条目")
    }

    // MARK: - metrics(project:workspace:) 多项目隔离

    func testMetricsLookup_existingKey_returnsCorrectEntry() {
        let json: [[String: Any]] = [
            makeRawMetrics(project: "proj_a", workspace: "ws1", fileHit: 42),
        ]
        let snapshot = SystemSnapshotCacheMetrics.from(json: json)
        let m = snapshot.metrics(project: "proj_a", workspace: "ws1")
        XCTAssertEqual(m.fileCache.hitCount, 42)
    }

    func testMetricsLookup_missingKey_returnsEmptyDefaults() {
        let snapshot = SystemSnapshotCacheMetrics(index: [:])
        let m = snapshot.metrics(project: "nonexistent", workspace: "ws1")
        XCTAssertEqual(m.fileCache.hitCount, 0)
        XCTAssertEqual(m.gitCache.hitCount, 0)
        XCTAssertFalse(m.budgetExceeded)
        XCTAssertNil(m.lastEvictionReason)
        XCTAssertEqual(m.project, "nonexistent")
        XCTAssertEqual(m.workspace, "ws1")
    }

    func testMetricsLookup_sameWorkspaceNameDifferentProjects_isolated() {
        let json: [[String: Any]] = [
            makeRawMetrics(project: "proj_a", workspace: "default", fileHit: 100),
            makeRawMetrics(project: "proj_b", workspace: "default", fileHit: 5),
        ]
        let snapshot = SystemSnapshotCacheMetrics.from(json: json)

        let m_a = snapshot.metrics(project: "proj_a", workspace: "default")
        let m_b = snapshot.metrics(project: "proj_b", workspace: "default")

        XCTAssertEqual(m_a.fileCache.hitCount, 100, "proj_a/default 不应被 proj_b/default 覆盖")
        XCTAssertEqual(m_b.fileCache.hitCount, 5, "proj_b/default 不应读到 proj_a 的值")
        XCTAssertNotEqual(m_a.fileCache.hitCount, m_b.fileCache.hitCount, "不同项目的同名工作区指标必须隔离")
    }

    // MARK: - FileCacheMetricsModel 字段语义

    func testFileCacheMetricsModel_parsesAllFields() {
        let json: [String: Any] = [
            "hit_count": 10,
            "miss_count": 2,
            "rebuild_count": 1,
            "incremental_update_count": 5,
            "eviction_count": 0,
            "item_count": 850,
        ]
        let m = FileCacheMetricsModel.from(json: json)
        XCTAssertEqual(m.hitCount, 10)
        XCTAssertEqual(m.missCount, 2)
        XCTAssertEqual(m.rebuildCount, 1)
        XCTAssertEqual(m.incrementalUpdateCount, 5)
        XCTAssertEqual(m.evictionCount, 0)
        XCTAssertEqual(m.itemCount, 850)
    }

    func testFileCacheMetricsModel_missingFields_defaultsToZero() {
        let m = FileCacheMetricsModel.from(json: [:])
        XCTAssertEqual(m.hitCount, 0)
        XCTAssertEqual(m.missCount, 0)
        XCTAssertEqual(m.rebuildCount, 0)
        XCTAssertEqual(m.incrementalUpdateCount, 0)
        XCTAssertEqual(m.evictionCount, 0)
        XCTAssertEqual(m.itemCount, 0)
    }

    func testFileCacheMetricsModel_empty_allZero() {
        let m = FileCacheMetricsModel.empty()
        XCTAssertEqual(m.hitCount, 0)
        XCTAssertEqual(m.rebuildCount, 0)
    }

    // MARK: - GitCacheMetricsModel 字段语义

    func testGitCacheMetricsModel_parsesAllFields() {
        let json: [String: Any] = [
            "hit_count": 7,
            "miss_count": 3,
            "rebuild_count": 2,
            "eviction_count": 1,
            "item_count": 42,
        ]
        let m = GitCacheMetricsModel.from(json: json)
        XCTAssertEqual(m.hitCount, 7)
        XCTAssertEqual(m.missCount, 3)
        XCTAssertEqual(m.rebuildCount, 2)
        XCTAssertEqual(m.evictionCount, 1)
        XCTAssertEqual(m.itemCount, 42)
    }

    // MARK: - WorkspaceCacheMetricsModel 字段语义

    func testWorkspaceCacheMetricsModel_globalKeyIsProjectColonWorkspace() {
        let json = makeRawMetrics(project: "my_project", workspace: "ws_dev")
        let m = WorkspaceCacheMetricsModel.from(json: json)!
        XCTAssertEqual(m.globalKey, "my_project:ws_dev", "globalKey 格式必须是 'project:workspace'")
    }

    func testWorkspaceCacheMetricsModel_budgetExceeded_fromCore() {
        // budgetExceeded 由 Core 计算，客户端只读取这个字段，不自行推导
        var json = makeRawMetrics(project: "p", workspace: "w")
        json["budget_exceeded"] = true
        let m = WorkspaceCacheMetricsModel.from(json: json)!
        XCTAssertTrue(m.budgetExceeded, "budgetExceeded 应直接来自 Core JSON 字段")
    }

    func testWorkspaceCacheMetricsModel_budgetExceeded_false_default() {
        let json = makeRawMetrics(project: "p", workspace: "w")  // 不含 budget_exceeded 字段
        let m = WorkspaceCacheMetricsModel.from(json: json)!
        XCTAssertFalse(m.budgetExceeded, "缺失字段时 budgetExceeded 默认为 false")
    }

    func testWorkspaceCacheMetricsModel_lastEvictionReason_fromCore() {
        var json = makeRawMetrics(project: "p", workspace: "w")
        json["last_eviction_reason"] = "memory_pressure"
        let m = WorkspaceCacheMetricsModel.from(json: json)!
        XCTAssertEqual(m.lastEvictionReason, "memory_pressure", "淘汰原因应来自 Core JSON 字段")
    }

    func testWorkspaceCacheMetricsModel_noEvictionReason_isNil() {
        let json = makeRawMetrics(project: "p", workspace: "w")
        let m = WorkspaceCacheMetricsModel.from(json: json)!
        XCTAssertNil(m.lastEvictionReason, "无淘汰原因时应为 nil")
    }

    // MARK: - default 虚拟工作区保持独立

    func testDefaultVirtualWorkspace_isolatedFromNamedWorkspaces() {
        let json: [[String: Any]] = [
            makeRawMetrics(project: "proj", workspace: "default", fileHit: 99),
            makeRawMetrics(project: "proj", workspace: "ws1", fileHit: 1),
        ]
        let snapshot = SystemSnapshotCacheMetrics.from(json: json)
        let mDefault = snapshot.metrics(project: "proj", workspace: "default")
        let mWs1 = snapshot.metrics(project: "proj", workspace: "ws1")
        XCTAssertEqual(mDefault.fileCache.hitCount, 99)
        XCTAssertEqual(mWs1.fileCache.hitCount, 1)
    }

    // MARK: - 辅助

    private func makeRawMetrics(
        project: String,
        workspace: String,
        fileHit: Int = 0,
        gitHit: Int = 0
    ) -> [String: Any] {
        [
            "project": project,
            "workspace": workspace,
            "file_cache": [
                "hit_count": fileHit,
                "miss_count": 0,
                "rebuild_count": 0,
                "incremental_update_count": 0,
                "eviction_count": 0,
                "item_count": 0,
            ] as [String: Any],
            "git_cache": [
                "hit_count": gitHit,
                "miss_count": 0,
                "rebuild_count": 0,
                "eviction_count": 0,
                "file_count": 0,
            ] as [String: Any],
        ]
    }
}
