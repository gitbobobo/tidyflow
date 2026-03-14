import XCTest
@testable import TidyFlowShared

final class GitWorkspaceStateDriverTests: XCTestCase {

    // MARK: - 辅助

    private func ctx(_ project: String = "proj", _ workspace: String = "ws") -> GitWorkspaceContext {
        GitWorkspaceContext(projectName: project, workspaceName: workspace)
    }

    private func drive(
        _ state: GitWorkspaceState = .empty,
        _ input: GitWorkspaceInput,
        context: GitWorkspaceContext? = nil
    ) -> (GitWorkspaceState, [GitWorkspaceEffect]) {
        GitWorkspaceStateDriver.reduce(state: state, input: input, context: context ?? ctx())
    }

    // MARK: - refreshStatus

    func test_refreshStatus_setsLoadingAndProducesEffect() {
        let (next, effects) = drive(.empty, .refreshStatus(cacheMode: .default))
        XCTAssertTrue(next.statusCache.isLoading)
        XCTAssertNil(next.statusCache.error)
        XCTAssertEqual(effects, [.requestStatus(cacheMode: .default)])
    }

    func test_refreshStatus_forceRefresh() {
        let (_, effects) = drive(.empty, .refreshStatus(cacheMode: .forceRefresh))
        XCTAssertEqual(effects, [.requestStatus(cacheMode: .forceRefresh)])
    }

    // MARK: - refreshBranches

    func test_refreshBranches_setsLoadingAndProducesEffect() {
        let (next, effects) = drive(.empty, .refreshBranches(cacheMode: .default))
        XCTAssertTrue(next.branchCache.isLoading)
        XCTAssertNil(next.branchCache.error)
        XCTAssertEqual(effects, [.requestBranches(cacheMode: .default)])
    }

    // MARK: - stage / unstage / discard

    func test_stage_addsOpInFlightAndProducesEffect() {
        let (next, effects) = drive(.empty, .stage(path: "file.txt", scope: "file"))
        XCTAssertTrue(next.opsInFlight.contains(GitOpInFlight(op: "stage", path: "file.txt", scope: "file")))
        XCTAssertEqual(effects, [.requestStage(path: "file.txt", scope: "file")])
    }

    func test_unstage_addsOpInFlightAndProducesEffect() {
        let (next, effects) = drive(.empty, .unstage(path: nil, scope: "all"))
        XCTAssertTrue(next.opsInFlight.contains(GitOpInFlight(op: "unstage", path: nil, scope: "all")))
        XCTAssertEqual(effects, [.requestUnstage(path: nil, scope: "all")])
    }

    func test_discard_addsOpInFlightAndProducesEffect() {
        let (next, effects) = drive(.empty, .discard(path: "a.swift", scope: "file", includeUntracked: true))
        XCTAssertTrue(next.opsInFlight.contains(GitOpInFlight(op: "discard", path: "a.swift", scope: "file")))
        XCTAssertEqual(effects, [.requestDiscard(path: "a.swift", scope: "file", includeUntracked: true)])
    }

    // MARK: - commit

    func test_commit_setsInFlightAndProducesEffect() {
        let (next, effects) = drive(.empty, .commit(message: "fix: bug"))
        XCTAssertTrue(next.commitInFlight)
        XCTAssertNil(next.commitResult)
        XCTAssertEqual(effects, [.requestCommit(message: "fix: bug")])
    }

    func test_commit_emptyMessageIsNoop() {
        let (next, effects) = drive(.empty, .commit(message: "   "))
        XCTAssertFalse(next.commitInFlight)
        XCTAssertTrue(effects.isEmpty)
    }

    func test_commit_trimsWhitespace() {
        let (_, effects) = drive(.empty, .commit(message: "  hello  "))
        XCTAssertEqual(effects, [.requestCommit(message: "hello")])
    }

    // MARK: - switchBranch / createBranch

    func test_switchBranch_setsInFlightAndProducesEffect() {
        let (next, effects) = drive(.empty, .switchBranch(name: "feature/x"))
        XCTAssertEqual(next.branchSwitchInFlight, "feature/x")
        XCTAssertEqual(effects, [.requestSwitchBranch(name: "feature/x")])
    }

    func test_switchBranch_blockedWhenAlreadySwitching() {
        var state = GitWorkspaceState.empty
        state.branchSwitchInFlight = "other"
        let (next, effects) = drive(state, .switchBranch(name: "new"))
        XCTAssertEqual(next.branchSwitchInFlight, "other") // 未变
        XCTAssertTrue(effects.isEmpty)
    }

    func test_createBranch_setsInFlightAndProducesEffect() {
        let (next, effects) = drive(.empty, .createBranch(name: "hotfix/1"))
        XCTAssertEqual(next.branchCreateInFlight, "hotfix/1")
        XCTAssertEqual(effects, [.requestCreateBranch(name: "hotfix/1")])
    }

    func test_createBranch_blockedWhenSwitching() {
        var state = GitWorkspaceState.empty
        state.branchSwitchInFlight = "other"
        let (next, effects) = drive(state, .createBranch(name: "new"))
        XCTAssertNil(next.branchCreateInFlight)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - gitStatusResult

    func test_gitStatusResult_updatesStatusCacheAndResolved() {
        let result = GitStatusResult(
            project: "proj", workspace: "ws",
            items: [], isGitRepo: true, error: nil,
            hasStagedChanges: false, stagedCount: 0,
            currentBranch: "main", defaultBranch: "main",
            aheadBy: 0, behindBy: 0, comparedBranch: nil
        )
        let (next, effects) = drive(.empty, .gitStatusResult(result))
        XCTAssertTrue(next.hasResolvedStatus)
        XCTAssertFalse(next.statusCache.isLoading)
        XCTAssertEqual(next.statusCache.currentBranch, "main")
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - gitBranchesResult

    func test_gitBranchesResult_updatesBranchCache() {
        let branches = [GitBranchItem(id: "main", name: "main")]
        let result = GitBranchesResult(project: "proj", workspace: "ws", current: "main", branches: branches)
        let (next, effects) = drive(.empty, .gitBranchesResult(result))
        XCTAssertEqual(next.branchCache.current, "main")
        XCTAssertEqual(next.branchCache.branches.count, 1)
        XCTAssertFalse(next.branchCache.isLoading)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - gitOpResult

    func test_gitOpResult_stageSuccess_removesOpAndRefreshesStatus() {
        var state = GitWorkspaceState.empty
        state.opsInFlight.insert(GitOpInFlight(op: "stage", path: "a.swift", scope: "file"))
        let result = GitOpResult(project: "proj", workspace: "ws", op: "stage", ok: true, message: nil, path: "a.swift", scope: "file")
        let (next, effects) = drive(state, .gitOpResult(result))
        XCTAssertTrue(next.opsInFlight.isEmpty)
        XCTAssertEqual(effects, [.requestStatus(cacheMode: .default)])
    }

    func test_gitOpResult_switchBranchSuccess_clearsInFlightAndRefreshes() {
        var state = GitWorkspaceState.empty
        state.branchSwitchInFlight = "feature"
        let result = GitOpResult(project: "proj", workspace: "ws", op: "switch_branch", ok: true, message: nil, path: nil, scope: "branch")
        let (next, effects) = drive(state, .gitOpResult(result))
        XCTAssertNil(next.branchSwitchInFlight)
        XCTAssertEqual(effects, [.requestStatus(cacheMode: .default), .requestBranches(cacheMode: .default)])
    }

    func test_gitOpResult_switchBranchFailure_clearsInFlightNoRefresh() {
        var state = GitWorkspaceState.empty
        state.branchSwitchInFlight = "feature"
        let result = GitOpResult(project: "proj", workspace: "ws", op: "switch_branch", ok: false, message: "error", path: nil, scope: "branch")
        let (next, effects) = drive(state, .gitOpResult(result))
        XCTAssertNil(next.branchSwitchInFlight)
        XCTAssertTrue(effects.isEmpty)
    }

    func test_gitOpResult_createBranchSuccess() {
        var state = GitWorkspaceState.empty
        state.branchCreateInFlight = "hotfix"
        let result = GitOpResult(project: "proj", workspace: "ws", op: "create_branch", ok: true, message: nil, path: nil, scope: "branch")
        let (next, effects) = drive(state, .gitOpResult(result))
        XCTAssertNil(next.branchCreateInFlight)
        XCTAssertEqual(effects, [.requestStatus(cacheMode: .default), .requestBranches(cacheMode: .default)])
    }

    // MARK: - gitCommitResult

    func test_gitCommitResult_success_clearsMessageAndRefreshes() {
        var state = GitWorkspaceState.empty
        state.commitInFlight = true
        state.commitMessage = "fix: bug"
        let result = GitCommitResult(project: "proj", workspace: "ws", ok: true, message: "ok", sha: nil)
        let (next, effects) = drive(state, .gitCommitResult(result))
        XCTAssertFalse(next.commitInFlight)
        XCTAssertEqual(next.commitMessage, "")
        XCTAssertNotNil(next.commitResult)
        XCTAssertEqual(effects, [.requestStatus(cacheMode: .default)])
    }

    func test_gitCommitResult_failure_keepsMessage() {
        var state = GitWorkspaceState.empty
        state.commitInFlight = true
        state.commitMessage = "fix: bug"
        let result = GitCommitResult(project: "proj", workspace: "ws", ok: false, message: "conflict", sha: nil)
        let (next, effects) = drive(state, .gitCommitResult(result))
        XCTAssertFalse(next.commitInFlight)
        XCTAssertEqual(next.commitMessage, "fix: bug")
        XCTAssertEqual(next.commitResult, "conflict")
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - gitStatusChanged

    func test_gitStatusChanged_producesStatusAndBranchesRefresh() {
        let (_, effects) = drive(.empty, .gitStatusChanged)
        XCTAssertEqual(effects, [.requestStatus(cacheMode: .default), .requestBranches(cacheMode: .default)])
    }

    // MARK: - connectionChanged

    func test_connectionLost_clearsAllInFlight() {
        var state = GitWorkspaceState.empty
        state.opsInFlight.insert(GitOpInFlight(op: "stage", path: nil, scope: "all"))
        state.branchSwitchInFlight = "dev"
        state.branchCreateInFlight = "hotfix"
        state.commitInFlight = true
        let (next, effects) = drive(state, .connectionChanged(isConnected: false))
        XCTAssertTrue(next.opsInFlight.isEmpty)
        XCTAssertNil(next.branchSwitchInFlight)
        XCTAssertNil(next.branchCreateInFlight)
        XCTAssertFalse(next.commitInFlight)
        XCTAssertTrue(effects.isEmpty)
    }

    func test_connectionRestored_noStateChange() {
        let state = GitWorkspaceState.empty
        let (next, effects) = drive(state, .connectionChanged(isConnected: true))
        XCTAssertEqual(next, state)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - 多工作区隔离

    func test_multiWorkspaceIsolation() {
        let ctxA = GitWorkspaceContext(projectName: "projA", workspaceName: "ws1")
        let ctxB = GitWorkspaceContext(projectName: "projB", workspaceName: "ws2")

        // 两个工作区分别驱动不同输入
        let statusA = GitStatusResult(
            project: "projA", workspace: "ws1",
            items: [], isGitRepo: true, error: nil,
            hasStagedChanges: true, stagedCount: 3,
            currentBranch: "main", defaultBranch: "main",
            aheadBy: 0, behindBy: 0, comparedBranch: nil
        )

        let (stateA, _) = GitWorkspaceStateDriver.reduce(
            state: .empty, input: .gitStatusResult(statusA), context: ctxA
        )
        let (stateB, _) = GitWorkspaceStateDriver.reduce(
            state: .empty, input: .stage(path: "x.swift", scope: "file"), context: ctxB
        )

        // 工作区 A 有 resolved status；工作区 B 没有
        XCTAssertTrue(stateA.hasResolvedStatus)
        XCTAssertFalse(stateB.hasResolvedStatus)

        // 工作区 B 有 ops in-flight；工作区 A 没有
        XCTAssertTrue(stateA.opsInFlight.isEmpty)
        XCTAssertFalse(stateB.opsInFlight.isEmpty)
    }

    // MARK: - 派生属性

    func test_semanticSnapshot_fromStatusCache() {
        let statusResult = GitStatusResult(
            project: "proj", workspace: "ws",
            items: [
                GitStatusItem(id: "a.swift", path: "a.swift", status: "M", staged: true, renameFrom: nil, additions: nil, deletions: nil),
                GitStatusItem(id: "b.swift", path: "b.swift", status: "??", staged: false, renameFrom: nil, additions: nil, deletions: nil)
            ],
            isGitRepo: true, error: nil,
            hasStagedChanges: true, stagedCount: 1,
            currentBranch: "dev", defaultBranch: "main",
            aheadBy: 1, behindBy: 2, comparedBranch: "main"
        )
        let (next, _) = drive(.empty, .gitStatusResult(statusResult))
        let snap = next.semanticSnapshot
        XCTAssertEqual(snap.stagedItems.count, 1)
        XCTAssertEqual(snap.currentBranch, "dev")
        XCTAssertTrue(snap.hasStagedChanges)
    }

    func test_isStageAllInFlight() {
        var state = GitWorkspaceState.empty
        XCTAssertFalse(state.isStageAllInFlight)
        state.opsInFlight.insert(GitOpInFlight(op: "stage", path: nil, scope: "all"))
        XCTAssertTrue(state.isStageAllInFlight)
    }

    func test_canCommit() {
        var state = GitWorkspaceState.empty
        XCTAssertFalse(state.canCommit) // 无暂存
        // 模拟有暂存
        let statusResult = GitStatusResult(
            project: "proj", workspace: "ws",
            items: [GitStatusItem(id: "a.swift", path: "a.swift", status: "M", staged: true, renameFrom: nil, additions: nil, deletions: nil)],
            isGitRepo: true, error: nil,
            hasStagedChanges: true, stagedCount: 1,
            currentBranch: "main", defaultBranch: "main",
            aheadBy: 0, behindBy: 0, comparedBranch: nil
        )
        (state, _) = drive(state, .gitStatusResult(statusResult))
        XCTAssertTrue(state.canCommit)
        // 提交进行中时不可
        state.commitInFlight = true
        XCTAssertFalse(state.canCommit)
    }
}
