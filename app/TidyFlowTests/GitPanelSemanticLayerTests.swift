import XCTest
import AppIntents
@testable import TidyFlow

// MARK: - Git 面板共享语义层单测
//
// 覆盖范围：
//   1. 状态分类：staged / trackedUnstaged / untracked
//   2. isEmpty / hasStagedChanges / hasTrackedChanges / hasUntrackedChanges 派生属性
//   3. 分支 divergence 格式化静态方法（不依赖本地化字符串的结构断言）
//   4. 多工作区隔离：不同 project:workspace 键的快照互不干扰
//   5. isGitRepo = false 时快照的正确呈现

final class GitPanelSemanticLayerTests: XCTestCase {

    // MARK: - Helpers

    /// 构建一个带有指定字段的 GitStatusItem（其余字段取合理默认值）
    private func makeItem(path: String, status: String, staged: Bool) -> GitStatusItem {
        GitStatusItem(
            id: path,
            path: path,
            status: status,
            staged: staged,
            renameFrom: nil,
            additions: nil,
            deletions: nil
        )
    }

    /// 从 items 构建 GitStatusCache，覆盖测试所需字段
    private func makeCache(
        items: [GitStatusItem],
        isGitRepo: Bool = true,
        isLoading: Bool = false,
        currentBranch: String? = "main",
        defaultBranch: String? = "main",
        aheadBy: Int? = nil,
        behindBy: Int? = nil
    ) -> GitStatusCache {
        let staged = items.filter { $0.staged == true }
        let hasStagedChanges = !staged.isEmpty
        return GitStatusCache(
            items: items,
            isLoading: isLoading,
            error: nil,
            isGitRepo: isGitRepo,
            updatedAt: Date(),
            hasStagedChanges: hasStagedChanges,
            stagedCount: staged.count,
            currentBranch: currentBranch,
            defaultBranch: defaultBranch,
            aheadBy: aheadBy,
            behindBy: behindBy,
            comparedBranch: defaultBranch
        )
    }

    // MARK: - 1. 状态分类

    func test_stagedItemsAreClassifiedCorrectly() {
        let items = [
            makeItem(path: "a.swift", status: "M", staged: true),
            makeItem(path: "b.swift", status: "A", staged: true),
            makeItem(path: "c.swift", status: "M", staged: false),
        ]
        let snapshot = makeCache(items: items).semanticSnapshot

        XCTAssertEqual(snapshot.stagedItems.count, 2)
        XCTAssertTrue(snapshot.stagedItems.allSatisfy { $0.staged == true })
    }

    func test_trackedUnstagedItemsExcludeUntrackedStatus() {
        let items = [
            makeItem(path: "modified.swift", status: "M", staged: false),
            makeItem(path: "deleted.swift", status: "D", staged: false),
            makeItem(path: "new_untracked.swift", status: "??", staged: false),
        ]
        let snapshot = makeCache(items: items).semanticSnapshot

        XCTAssertEqual(snapshot.trackedUnstagedItems.count, 2)
        XCTAssertTrue(snapshot.trackedUnstagedItems.allSatisfy { $0.status != "??" })
    }

    func test_untrackedItemsOnlyContainQuestionMarkStatus() {
        let items = [
            makeItem(path: "modified.swift", status: "M", staged: false),
            makeItem(path: "new1.swift", status: "??", staged: false),
            makeItem(path: "new2.swift", status: "??", staged: false),
        ]
        let snapshot = makeCache(items: items).semanticSnapshot

        XCTAssertEqual(snapshot.untrackedItems.count, 2)
        XCTAssertTrue(snapshot.untrackedItems.allSatisfy { $0.status == "??" })
    }

    func test_unstagedItemsCombinesTrackedAndUntracked() {
        let items = [
            makeItem(path: "modified.swift", status: "M", staged: false),
            makeItem(path: "new.swift", status: "??", staged: false),
        ]
        let snapshot = makeCache(items: items).semanticSnapshot

        // unstagedItems 是 trackedUnstaged + untracked 的合并
        XCTAssertEqual(snapshot.unstagedItems.count, 2)
        let paths = snapshot.unstagedItems.map { $0.path }
        XCTAssertTrue(paths.contains("modified.swift"))
        XCTAssertTrue(paths.contains("new.swift"))
    }

    // MARK: - 2. 派生属性

    func test_isEmptyWhenNoChanges() {
        let snapshot = makeCache(items: []).semanticSnapshot
        XCTAssertTrue(snapshot.isEmpty)
    }

    func test_isNotEmptyWhenStagedChangesExist() {
        let items = [makeItem(path: "a.swift", status: "M", staged: true)]
        let snapshot = makeCache(items: items).semanticSnapshot
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertTrue(snapshot.hasStagedChanges)
    }

    func test_isNotEmptyWhenTrackedUnstagedChangesExist() {
        let items = [makeItem(path: "b.swift", status: "M", staged: false)]
        let snapshot = makeCache(items: items).semanticSnapshot
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertFalse(snapshot.hasStagedChanges)
        XCTAssertTrue(snapshot.hasTrackedChanges)
    }

    func test_isNotEmptyWhenUntrackedFilesExist() {
        let items = [makeItem(path: "new.swift", status: "??", staged: false)]
        let snapshot = makeCache(items: items).semanticSnapshot
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertFalse(snapshot.hasStagedChanges)
        XCTAssertFalse(snapshot.hasTrackedChanges)
        XCTAssertTrue(snapshot.hasUntrackedChanges)
    }

    // MARK: - 3. 非 Git 仓库快照

    func test_nonGitRepoSnapshot() {
        let snapshot = makeCache(items: [], isGitRepo: false).semanticSnapshot
        XCTAssertFalse(snapshot.isGitRepo)
        XCTAssertTrue(snapshot.isEmpty)
    }

    // MARK: - 4. 分支 divergence 格式化（结构断言，不依赖本地化字符串内容）

    func test_formatBranchDivergence_returnsNonEmptyStringWhenAllFieldsPresent() {
        let text = GitPanelSemanticSnapshot.formatBranchDivergence(
            defaultBranch: "main",
            aheadBy: 2,
            behindBy: 1,
            isLoading: false
        )
        XCTAssertFalse(text.isEmpty)
    }

    func test_formatBranchDivergence_upToDateBranchReturnsDifferentTextThanDiverged() {
        let upToDate = GitPanelSemanticSnapshot.formatBranchDivergence(
            defaultBranch: "main",
            aheadBy: 0,
            behindBy: 0,
            isLoading: false
        )
        let diverged = GitPanelSemanticSnapshot.formatBranchDivergence(
            defaultBranch: "main",
            aheadBy: 2,
            behindBy: 1,
            isLoading: false
        )
        XCTAssertNotEqual(upToDate, diverged)
    }

    func test_formatBranchDivergence_missingFieldsReturnsFallback() {
        let text = GitPanelSemanticSnapshot.formatBranchDivergence(
            defaultBranch: nil,
            aheadBy: nil,
            behindBy: nil,
            isLoading: false
        )
        XCTAssertFalse(text.isEmpty)
    }

    func test_formatBranchDivergence_loadingReturnsDifferentTextThanFallback() {
        let loading = GitPanelSemanticSnapshot.formatBranchDivergence(
            defaultBranch: nil,
            aheadBy: nil,
            behindBy: nil,
            isLoading: true
        )
        let fallback = GitPanelSemanticSnapshot.formatBranchDivergence(
            defaultBranch: nil,
            aheadBy: nil,
            behindBy: nil,
            isLoading: false
        )
        XCTAssertNotEqual(loading, fallback)
    }

    // MARK: - 5. 多工作区隔离

    func test_multiWorkspaceIsolation() {
        let cache = GitCacheState()

        // 工作区 A：有变更
        let resultA = GitStatusResult(
            project: "proj",
            workspace: "ws-a",
            items: [makeItem(path: "a.swift", status: "M", staged: false)],
            isGitRepo: true,
            error: nil,
            hasStagedChanges: false,
            stagedCount: 0,
            currentBranch: "feature-a",
            defaultBranch: "main",
            aheadBy: 1,
            behindBy: 0,
            comparedBranch: "main"
        )
        cache.handleGitStatusResult(resultA)

        // 工作区 B：干净
        let resultB = GitStatusResult(
            project: "proj",
            workspace: "ws-b",
            items: [],
            isGitRepo: true,
            error: nil,
            hasStagedChanges: false,
            stagedCount: 0,
            currentBranch: "main",
            defaultBranch: "main",
            aheadBy: 0,
            behindBy: 0,
            comparedBranch: "main"
        )
        cache.handleGitStatusResult(resultB)

        // 注入 project 名以便 cache key 解析
        cache.getProjectName = { "proj" }

        let snapshotA = cache.getGitSemanticSnapshot(workspaceKey: "ws-a")
        let snapshotB = cache.getGitSemanticSnapshot(workspaceKey: "ws-b")

        // 两个工作区的快照完全独立
        XCTAssertFalse(snapshotA.isEmpty, "工作区 A 应有变更")
        XCTAssertTrue(snapshotB.isEmpty, "工作区 B 应为干净状态")
        XCTAssertEqual(snapshotA.currentBranch, "feature-a")
        XCTAssertEqual(snapshotB.currentBranch, "main")
    }

    // MARK: - 6. empty() 工厂

    func test_emptyFactory() {
        let empty = GitPanelSemanticSnapshot.empty()
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(empty.isGitRepo)
        XCTAssertNil(empty.currentBranch)
        XCTAssertNil(empty.defaultBranch)
    }

    // MARK: - 7. totalAdditions / totalDeletions 汇总（WI-001 验证）

    private func makeItemWithStats(path: String, status: String, staged: Bool, additions: Int, deletions: Int) -> GitStatusItem {
        GitStatusItem(
            id: path,
            path: path,
            status: status,
            staged: staged,
            renameFrom: nil,
            additions: additions,
            deletions: deletions
        )
    }

    func test_totalAdditions_aggregatesAcrossStagedAndUnstaged() {
        let items = [
            makeItemWithStats(path: "a.swift", status: "M", staged: true, additions: 10, deletions: 2),
            makeItemWithStats(path: "b.swift", status: "M", staged: false, additions: 5, deletions: 3),
            makeItemWithStats(path: "c.swift", status: "??", staged: false, additions: 0, deletions: 0),
        ]
        let snapshot = makeCache(items: items).semanticSnapshot

        XCTAssertEqual(snapshot.totalAdditions, 15, "staged 和 unstaged 的 additions 应合并计算")
        XCTAssertEqual(snapshot.totalDeletions, 5, "staged 和 unstaged 的 deletions 应合并计算")
    }

    func test_totalAdditions_handlesNilAsZero() {
        let items = [
            makeItem(path: "a.swift", status: "M", staged: true),   // additions = nil
            makeItem(path: "b.swift", status: "M", staged: false),  // additions = nil
        ]
        let snapshot = makeCache(items: items).semanticSnapshot

        XCTAssertEqual(snapshot.totalAdditions, 0)
        XCTAssertEqual(snapshot.totalDeletions, 0)
    }

    func test_totalAdditions_emptySnapshotIsZero() {
        let snapshot = makeCache(items: []).semanticSnapshot
        XCTAssertEqual(snapshot.totalAdditions, 0)
        XCTAssertEqual(snapshot.totalDeletions, 0)
    }

    // MARK: - 8. empty() 中 totalAdditions/totalDeletions 为零
    func test_emptySnapshot_totalAdditionsDeletionsAreZero() {
        let empty = GitPanelSemanticSnapshot.empty()
        XCTAssertEqual(empty.totalAdditions, 0)
        XCTAssertEqual(empty.totalDeletions, 0)
    }

    // MARK: - 9. 冲突状态下快照的 hasStagedChanges（WI-006）
    //
    // 验证冲突文件在 staged=true 后被计入 stagedCount，语义层不因冲突状态而失效。

    func test_conflictResolved_stagedItemCountsCorrectly() {
        // 冲突文件在标记解决（staged=true）后应被纳入 staged 分组
        let items = [
            makeItem(path: "conflict.swift", status: "U", staged: true),  // 已解决并暂存
            makeItem(path: "clean.swift", status: "M", staged: false),
        ]
        let cache = makeCache(items: items)
        let snapshot = cache.semanticSnapshot

        XCTAssertTrue(snapshot.hasStagedChanges, "冲突解决并暂存后 hasStagedChanges 应为 true")
        XCTAssertEqual(snapshot.stagedItems.count, 1)
        XCTAssertEqual(snapshot.stagedItems.first?.path, "conflict.swift")
    }

    // MARK: - 10. 多工作区下冲突向导缓存独立（WI-006）

    func test_conflictWizardCache_multiWorkspaceIsolation() {
        let state = GitCacheState()

        // 注入工作区 A 的冲突详情
        let detailA = GitConflictDetailResult(
            project: "proj",
            workspace: "ws-a",
            context: "workspace",
            path: "src/feature_a.rs",
            baseContent: nil,
            oursContent: "a_ours",
            theirsContent: "a_theirs",
            currentContent: "<<<<<<< HEAD\na_ours\n=======\na_theirs\n>>>>>>> branch\n",
            conflictMarkersCount: 1,
            isBinary: false
        )
        state.handleGitConflictDetailResult(detailA)

        // 注入工作区 B 的冲突详情
        let detailB = GitConflictDetailResult(
            project: "proj",
            workspace: "ws-b",
            context: "workspace",
            path: "src/feature_b.rs",
            baseContent: nil,
            oursContent: "b_ours",
            theirsContent: "b_theirs",
            currentContent: "<<<<<<< HEAD\nb_ours\n=======\nb_theirs\n>>>>>>> branch\n",
            conflictMarkersCount: 1,
            isBinary: false
        )
        state.handleGitConflictDetailResult(detailB)

        let wizardA = state.getConflictWizardCache(project: "proj", workspace: "ws-a", context: "workspace")
        let wizardB = state.getConflictWizardCache(project: "proj", workspace: "ws-b", context: "workspace")

        // 两个工作区的冲突向导缓存完全独立
        XCTAssertEqual(wizardA.currentDetail?.path, "src/feature_a.rs")
        XCTAssertEqual(wizardB.currentDetail?.path, "src/feature_b.rs")
        XCTAssertEqual(wizardA.currentDetail?.oursContent, "a_ours")
        XCTAssertEqual(wizardB.currentDetail?.oursContent, "b_ours")
    }
}
