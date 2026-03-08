import XCTest
@testable import TidyFlow

// MARK: - Git 冲突向导共享语义层单测（WI-006）
//
// 覆盖范围：
//   1. ConflictFileEntry 解析（from dict / listFrom）
//   2. ConflictSnapshot 解析与 allResolved 语义
//   3. ConflictWizardCache 派生属性（hasActiveConflicts / conflictFileCount / empty）
//   4. GitConflictDetailResultCache 从 GitConflictDetailResult 构造
//   5. GitCacheState.handleGitConflictDetailResult 更新隔离
//   6. GitCacheState.handleGitConflictActionResult 快照更新与详情清空
//   7. 多项目多工作区键隔离（workspace / integration 上下文）
//   8. IntegrationState 冲突变体字符串映射

final class GitConflictWizardSemanticTests: XCTestCase {

    // MARK: - 辅助工厂

    private func makeConflictFileEntryDict(
        path: String,
        conflictType: String = "content",
        staged: Bool = false
    ) -> [String: Any] {
        ["path": path, "conflict_type": conflictType, "staged": staged]
    }

    private func makeConflictSnapshotDict(
        context: String = "workspace",
        files: [[String: Any]] = [],
        allResolved: Bool = false
    ) -> [String: Any] {
        ["context": context, "files": files, "all_resolved": allResolved]
    }

    private func makeDetailResult(
        project: String = "proj",
        workspace: String = "ws-a",
        context: String = "workspace",
        path: String = "src/main.rs",
        oursContent: String? = "ours",
        theirsContent: String? = "theirs"
    ) -> GitConflictDetailResult {
        GitConflictDetailResult(
            project: project,
            workspace: workspace,
            context: context,
            path: path,
            baseContent: "base",
            oursContent: oursContent,
            theirsContent: theirsContent,
            currentContent: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch\n",
            conflictMarkersCount: 1,
            isBinary: false
        )
    }

    private func makeActionResult(
        project: String = "proj",
        workspace: String = "ws-a",
        context: String = "workspace",
        path: String = "src/main.rs",
        action: String = "accept_ours",
        ok: Bool = true,
        files: [ConflictFileEntry] = [],
        allResolved: Bool = true
    ) -> GitConflictActionResult {
        let snapshot = ConflictSnapshot(context: context, files: files, allResolved: allResolved)
        return GitConflictActionResult(
            project: project,
            workspace: workspace,
            context: context,
            path: path,
            action: action,
            ok: ok,
            message: nil,
            snapshot: snapshot
        )
    }

    // MARK: - 1. ConflictFileEntry 解析

    func test_conflictFileEntry_parsesFromDict() {
        let dict = makeConflictFileEntryDict(path: "src/a.rs", conflictType: "add_add", staged: false)
        let entry = ConflictFileEntry.from(dict: dict)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.path, "src/a.rs")
        XCTAssertEqual(entry?.conflictType, "add_add")
        XCTAssertFalse(entry?.staged ?? true)
    }

    func test_conflictFileEntry_parsesStaged() {
        let dict = makeConflictFileEntryDict(path: "src/b.rs", staged: true)
        let entry = ConflictFileEntry.from(dict: dict)
        XCTAssertTrue(entry?.staged ?? false, "staged=true 应被正确解析")
    }

    func test_conflictFileEntry_returnsNilOnMissingPath() {
        let dict: [String: Any] = ["conflict_type": "content", "staged": false]
        let entry = ConflictFileEntry.from(dict: dict)
        XCTAssertNil(entry, "缺少 path 字段时应返回 nil")
    }

    func test_conflictFileEntry_listFrom_parsesArray() {
        let arr: [[String: Any]] = [
            makeConflictFileEntryDict(path: "a.rs"),
            makeConflictFileEntryDict(path: "b.rs"),
        ]
        let entries = ConflictFileEntry.listFrom(json: arr)
        XCTAssertEqual(entries.count, 2)
    }

    func test_conflictFileEntry_listFrom_emptyOnNil() {
        let entries = ConflictFileEntry.listFrom(json: nil)
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - 2. ConflictSnapshot 解析与 allResolved

    func test_conflictSnapshot_parsesFromDict_empty() {
        let dict = makeConflictSnapshotDict(context: "workspace", files: [], allResolved: true)
        let snap = ConflictSnapshot.from(dict: dict)
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.context, "workspace")
        XCTAssertTrue(snap?.allResolved ?? false)
        XCTAssertTrue(snap?.files.isEmpty ?? false)
    }

    func test_conflictSnapshot_parsesFromDict_withFiles() {
        let files = [makeConflictFileEntryDict(path: "src/c.rs")]
        let dict = makeConflictSnapshotDict(context: "integration", files: files, allResolved: false)
        let snap = ConflictSnapshot.from(dict: dict)
        XCTAssertEqual(snap?.context, "integration")
        XCTAssertFalse(snap?.allResolved ?? true)
        XCTAssertEqual(snap?.files.count, 1)
    }

    func test_conflictSnapshot_parsesFromDict_returnsNilOnMissingContext() {
        let dict: [String: Any] = ["files": [], "all_resolved": true]
        let snap = ConflictSnapshot.from(dict: dict)
        XCTAssertNil(snap, "缺少 context 字段时应返回 nil")
    }

    // MARK: - 3. ConflictWizardCache 派生属性

    func test_conflictWizardCache_emptyReturnsInactiveDefaults() {
        let cache = ConflictWizardCache.empty()
        XCTAssertNil(cache.snapshot)
        XCTAssertFalse(cache.hasActiveConflicts)
        XCTAssertEqual(cache.conflictFileCount, 0)
        XCTAssertNil(cache.selectedFilePath)
        XCTAssertNil(cache.currentDetail)
    }

    func test_conflictWizardCache_hasActiveConflicts_whenFilesExist() {
        let files = [ConflictFileEntry(path: "a.rs", conflictType: "content", staged: false)]
        let snap = ConflictSnapshot(context: "workspace", files: files, allResolved: false)
        var cache = ConflictWizardCache.empty()
        cache.snapshot = snap
        XCTAssertTrue(cache.hasActiveConflicts)
        XCTAssertEqual(cache.conflictFileCount, 1)
    }

    func test_conflictWizardCache_hasNoActiveConflicts_whenAllResolved() {
        let snap = ConflictSnapshot(context: "workspace", files: [], allResolved: true)
        var cache = ConflictWizardCache.empty()
        cache.snapshot = snap
        XCTAssertFalse(cache.hasActiveConflicts)
        XCTAssertEqual(cache.conflictFileCount, 0)
    }

    func test_conflictWizardCache_hasNoActiveConflicts_whenSnapshotNil() {
        let cache = ConflictWizardCache.empty()
        XCTAssertFalse(cache.hasActiveConflicts)
    }

    func test_conflictWizardCache_conflictFileCount_matchesSnapshotFiles() {
        let files = [
            ConflictFileEntry(path: "a.rs", conflictType: "content", staged: false),
            ConflictFileEntry(path: "b.rs", conflictType: "add_add", staged: false),
            ConflictFileEntry(path: "c.rs", conflictType: "delete_modify", staged: true),
        ]
        let snap = ConflictSnapshot(context: "workspace", files: files, allResolved: false)
        var cache = ConflictWizardCache.empty()
        cache.snapshot = snap
        XCTAssertEqual(cache.conflictFileCount, 3)
    }

    // MARK: - 4. GitConflictDetailResultCache 构造

    func test_conflictDetailResultCache_constructedFromResult() {
        let result = makeDetailResult()
        let cache = GitConflictDetailResultCache(from: result)
        XCTAssertEqual(cache.path, "src/main.rs")
        XCTAssertEqual(cache.context, "workspace")
        XCTAssertEqual(cache.oursContent, "ours")
        XCTAssertEqual(cache.theirsContent, "theirs")
        XCTAssertEqual(cache.baseContent, "base")
        XCTAssertFalse(cache.isBinary)
        XCTAssertEqual(cache.conflictMarkersCount, 1)
    }

    func test_conflictDetailResultCache_handlesNilContents() {
        let result = makeDetailResult(oursContent: nil, theirsContent: nil)
        let cache = GitConflictDetailResultCache(from: result)
        XCTAssertNil(cache.oursContent)
        XCTAssertNil(cache.theirsContent)
    }

    // MARK: - 5. GitCacheState.handleGitConflictDetailResult 隔离

    func test_handleConflictDetailResult_updatesCorrectWorkspaceCache() {
        let state = GitCacheState()
        let resultA = makeDetailResult(project: "proj", workspace: "ws-a", path: "src/a.rs")
        let resultB = makeDetailResult(project: "proj", workspace: "ws-b", path: "src/b.rs")

        state.handleGitConflictDetailResult(resultA)
        state.handleGitConflictDetailResult(resultB)

        let wizardA = state.getConflictWizardCache(project: "proj", workspace: "ws-a", context: "workspace")
        let wizardB = state.getConflictWizardCache(project: "proj", workspace: "ws-b", context: "workspace")

        // 两个工作区的详情互不干扰
        XCTAssertEqual(wizardA.currentDetail?.path, "src/a.rs")
        XCTAssertEqual(wizardB.currentDetail?.path, "src/b.rs")
        XCTAssertEqual(wizardA.selectedFilePath, "src/a.rs")
        XCTAssertEqual(wizardB.selectedFilePath, "src/b.rs")
    }

    func test_handleConflictDetailResult_setsSelectedFile() {
        let state = GitCacheState()
        let result = makeDetailResult(path: "src/conflict.rs")
        state.handleGitConflictDetailResult(result)

        let wizard = state.getConflictWizardCache(project: "proj", workspace: "ws-a", context: "workspace")
        XCTAssertEqual(wizard.selectedFilePath, "src/conflict.rs")
        XCTAssertFalse(wizard.isLoading)
    }

    // MARK: - 6. GitCacheState.handleGitConflictActionResult 快照更新

    func test_handleConflictActionResult_updatesSnapshot() {
        let state = GitCacheState()
        let result = makeActionResult(files: [], allResolved: true)
        state.handleGitConflictActionResult(result)

        let wizard = state.getConflictWizardCache(project: "proj", workspace: "ws-a", context: "workspace")
        XCTAssertNotNil(wizard.snapshot)
        XCTAssertTrue(wizard.snapshot?.allResolved ?? false)
        XCTAssertFalse(wizard.isLoading)
    }

    func test_handleConflictActionResult_clearsDetailOnResolvedSelectedFile() {
        let state = GitCacheState()
        // 先注入详情，使 selectedFilePath 指向 src/main.rs
        let detail = makeDetailResult(path: "src/main.rs")
        state.handleGitConflictDetailResult(detail)

        // 对同一文件执行解决动作
        let actionResult = makeActionResult(path: "src/main.rs", ok: true, allResolved: true)
        state.handleGitConflictActionResult(actionResult)

        let wizard = state.getConflictWizardCache(project: "proj", workspace: "ws-a", context: "workspace")
        // 已解决且路径匹配时，详情缓存应被清空
        XCTAssertNil(wizard.currentDetail, "解决选中文件后 currentDetail 应被清空")
    }

    func test_handleConflictActionResult_keepsDetailWhenDifferentFile() {
        let state = GitCacheState()
        // 详情指向 src/a.rs
        let detail = makeDetailResult(path: "src/a.rs")
        state.handleGitConflictDetailResult(detail)

        // 解决另一个文件 src/b.rs
        let actionResult = makeActionResult(path: "src/b.rs", ok: true, allResolved: false)
        state.handleGitConflictActionResult(actionResult)

        let wizard = state.getConflictWizardCache(project: "proj", workspace: "ws-a", context: "workspace")
        // 路径不同，不应清空 a.rs 的详情
        XCTAssertNotNil(wizard.currentDetail, "未解决选中文件时 currentDetail 应保留")
        XCTAssertEqual(wizard.currentDetail?.path, "src/a.rs")
    }

    // MARK: - 7. 多项目多工作区隔离

    func test_multiProjectIsolation_wizardCachesAreSeparate() {
        let state = GitCacheState()

        let detailProj1 = makeDetailResult(project: "proj-1", workspace: "ws", path: "src/p1.rs")
        let detailProj2 = makeDetailResult(project: "proj-2", workspace: "ws", path: "src/p2.rs")
        state.handleGitConflictDetailResult(detailProj1)
        state.handleGitConflictDetailResult(detailProj2)

        let w1 = state.getConflictWizardCache(project: "proj-1", workspace: "ws", context: "workspace")
        let w2 = state.getConflictWizardCache(project: "proj-2", workspace: "ws", context: "workspace")

        XCTAssertEqual(w1.currentDetail?.path, "src/p1.rs")
        XCTAssertEqual(w2.currentDetail?.path, "src/p2.rs")
    }

    func test_integrationContext_isolatedFromWorkspaceContext() {
        let state = GitCacheState()

        // workspace 上下文的详情
        let wsDetail = makeDetailResult(project: "proj", workspace: "ws", context: "workspace", path: "src/ws.rs")
        state.handleGitConflictDetailResult(wsDetail)

        // integration 上下文的动作结果（workspace 字段约定为空）
        let intFiles = [ConflictFileEntry(path: "src/int.rs", conflictType: "content", staged: false)]
        let intSnap = ConflictSnapshot(context: "integration", files: intFiles, allResolved: false)
        let intAction = GitConflictActionResult(
            project: "proj",
            workspace: "",
            context: "integration",
            path: "src/int.rs",
            action: "accept_ours",
            ok: true,
            message: nil,
            snapshot: intSnap
        )
        state.handleGitConflictActionResult(intAction)

        let wsWizard = state.getConflictWizardCache(project: "proj", workspace: "ws", context: "workspace")
        let intWizard = state.getConflictWizardCache(project: "proj", workspace: "", context: "integration")

        // workspace 与 integration 上下文完全独立
        XCTAssertEqual(wsWizard.currentDetail?.path, "src/ws.rs", "workspace 上下文应保持 ws 详情")
        XCTAssertNil(wsWizard.snapshot, "workspace 上下文不应有 integration 的快照")
        XCTAssertNotNil(intWizard.snapshot, "integration 上下文应有快照")
        XCTAssertEqual(intWizard.snapshot?.files.count, 1)
    }

    // MARK: - 8. IntegrationState 冲突变体映射

    func test_integrationState_conflictVariantsMapCorrectly() {
        XCTAssertEqual(IntegrationState.conflict.rawValue, "conflict")
        XCTAssertEqual(IntegrationState.rebaseConflict.rawValue, "rebase_conflict")
    }

    func test_integrationState_isMergeState_forMergeVariants() {
        XCTAssertTrue(IntegrationState.conflict.isMergeState, "conflict 应属于 merge 状态")
        XCTAssertTrue(IntegrationState.merging.isMergeState, "merging 应属于 merge 状态")
        XCTAssertFalse(IntegrationState.rebasing.isMergeState)
        XCTAssertFalse(IntegrationState.rebaseConflict.isMergeState)
        XCTAssertFalse(IntegrationState.idle.isMergeState)
    }

    func test_integrationState_isRebaseState_forRebaseVariants() {
        XCTAssertTrue(IntegrationState.rebasing.isRebaseState, "rebasing 应属于 rebase 状态")
        XCTAssertTrue(IntegrationState.rebaseConflict.isRebaseState, "rebase_conflict 应属于 rebase 状态")
        XCTAssertFalse(IntegrationState.merging.isRebaseState)
        XCTAssertFalse(IntegrationState.conflict.isRebaseState)
    }

    func test_integrationState_displayName_isNonEmpty() {
        // 所有 IntegrationState 变体都应有非空 displayName
        let allStates: [IntegrationState] = [.idle, .merging, .conflict, .completed, .failed, .rebasing, .rebaseConflict]
        for state in allStates {
            XCTAssertFalse(state.displayName.isEmpty, "\(state.rawValue) 的 displayName 不应为空")
        }
    }
}
