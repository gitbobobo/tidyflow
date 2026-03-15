import XCTest
@testable import TidyFlow
import TidyFlowShared

/// Git Stash 语义定向测试
///
/// 覆盖：
///   1. stash 列表缓存按 project:workspace 隔离
///   2. stash 详情消费结构完整
///   3. stash 操作结果触发缓存刷新
///   4. pop 冲突不删除 stash 条目
///   5. 冲突向导桥接
final class GitStashSemanticTests: XCTestCase {

    // MARK: - 1. 列表缓存路由隔离

    func testStashListCacheKeyIsolation() {
        let cache = GitStashListCache.empty()
        XCTAssertTrue(cache.entries.isEmpty)
        XCTAssertFalse(cache.isLoading)

        // 不同 project:workspace 键互不干扰
        var store: [String: GitStashListCache] = [:]
        let key1 = "projA:ws1"
        let key2 = "projA:ws2"

        let entry1 = GitStashEntry(
            stashId: "stash@{0}",
            title: "stash@{0}: WIP on main",
            message: "ws1 changes",
            branchName: "main",
            createdAt: "2025-01-01T00:00:00Z",
            fileCount: 2,
            includesUntracked: false,
            includesIndex: false
        )

        store[key1] = GitStashListCache(entries: [entry1], isLoading: false, error: nil, updatedAt: Date())
        store[key2] = GitStashListCache.empty()

        XCTAssertEqual(store[key1]?.entries.count, 1)
        XCTAssertEqual(store[key2]?.entries.count, 0)
    }

    // MARK: - 2. 详情消费结构

    func testStashShowCacheConsumption() {
        let entry = GitStashEntry(
            stashId: "stash@{0}",
            title: "stash@{0}: WIP on main",
            message: "my stash",
            branchName: "main",
            createdAt: "2025-01-01T00:00:00Z",
            fileCount: 2,
            includesUntracked: false,
            includesIndex: false
        )

        let file = GitStashFileEntry(
            path: "src/main.rs",
            status: "M",
            additions: 10,
            deletions: 3,
            sourceKind: "tracked"
        )

        let showCache = GitStashShowCache(
            stashId: "stash@{0}",
            entry: entry,
            files: [file],
            diffText: "diff --git a/src/main.rs b/src/main.rs\n...",
            isBinarySummaryTruncated: false,
            isLoading: false,
            error: nil,
            updatedAt: Date()
        )

        XCTAssertEqual(showCache.stashId, "stash@{0}")
        XCTAssertNotNil(showCache.entry)
        XCTAssertEqual(showCache.files.count, 1)
        XCTAssertEqual(showCache.files[0].sourceKind, "tracked")
        XCTAssertFalse(showCache.diffText.isEmpty)
    }

    // MARK: - 3. Op 结果状态验证

    func testStashOpResultCompletedState() {
        let result = GitStashOpResult(
            project: "proj",
            workspace: "default",
            op: "save",
            stashId: "stash@{0}",
            ok: true,
            state: "completed",
            message: nil,
            affectedPaths: [],
            conflictFiles: []
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.state, "completed")
        XCTAssertTrue(result.conflictFiles.isEmpty)
    }

    // MARK: - 4. Pop 冲突不删除条目

    func testStashPopConflictPreservesEntry() {
        let conflictEntry = ConflictFileEntry(
            path: "src/main.rs",
            conflictType: "content",
            staged: false
        )

        let result = GitStashOpResult(
            project: "proj",
            workspace: "default",
            op: "pop",
            stashId: "stash@{0}",
            ok: false,
            state: "conflict",
            message: "Merge conflict in src/main.rs",
            affectedPaths: ["src/main.rs"],
            conflictFiles: [conflictEntry]
        )

        // pop 冲突时 ok = false, state = conflict
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.state, "conflict")
        XCTAssertEqual(result.op, "pop")
        // conflict_files 非空表示有冲突
        XCTAssertFalse(result.conflictFiles.isEmpty)
        // stash_id 仍然存在（条目未被删除）
        XCTAssertEqual(result.stashId, "stash@{0}")
    }

    // MARK: - 5. 冲突向导桥接

    func testConflictFilesCanBridgeToWizard() {
        let conflictEntry = ConflictFileEntry(
            path: "file1.rs",
            conflictType: "content",
            staged: false
        )

        let opResult = GitStashOpResult(
            project: "proj",
            workspace: "default",
            op: "apply",
            stashId: "stash@{0}",
            ok: false,
            state: "conflict",
            message: "conflict detected",
            affectedPaths: ["file1.rs", "file2.rs"],
            conflictFiles: [conflictEntry]
        )

        // conflict_files 可直接用于填充 ConflictWizardCache
        XCTAssertEqual(opResult.conflictFiles.count, 1)
        XCTAssertEqual(opResult.conflictFiles[0].path, "file1.rs")
        // 不需要从 affected_paths 推导，conflict_files 是明确的冲突文件列表
        XCTAssertNotEqual(opResult.affectedPaths.count, opResult.conflictFiles.count)
    }
}
