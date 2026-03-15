import XCTest
@testable import TidyFlow
import TidyFlowShared

/// Git stash 语义定向测试。
///
/// 覆盖：
/// 1. stash 列表缓存按 project:workspace 隔离
/// 2. stash 详情消费完整写入 entry/files/diff_text
/// 3. save/apply/pop/drop 结果触发 stash 列表与 git status 刷新
/// 4. pop 冲突时保留现有 stash 条目
/// 5. conflict_files 写入现有冲突向导缓存
final class GitStashSemanticsTests: XCTestCase {

    func testStashListCacheRoutesPerWorkspaceIsolation() {
        let state = GitCacheState()
        let firstEntry = makeStashEntry(id: "stash@{0}", message: "projA default")
        let secondEntry = makeStashEntry(id: "stash@{1}", message: "projB default")

        state.handleGitStashListResult(
            GitStashListResult(project: "projA", workspace: "default", entries: [firstEntry])
        )
        state.handleGitStashListResult(
            GitStashListResult(project: "projB", workspace: "default", entries: [secondEntry])
        )

        let projectA = state.getStashListCache(project: "projA", workspace: "default")
        let projectB = state.getStashListCache(project: "projB", workspace: "default")
        let missing = state.getStashListCache(project: "projA", workspace: "feature")

        XCTAssertEqual(projectA.entries.map(\.stashId), ["stash@{0}"])
        XCTAssertEqual(projectB.entries.map(\.stashId), ["stash@{1}"])
        XCTAssertTrue(missing.entries.isEmpty)
        XCTAssertEqual(state.selectedStashId["projA:default"], "stash@{0}")
        XCTAssertEqual(state.selectedStashId["projB:default"], "stash@{1}")
    }

    func testStashShowResultConsumesEntryFilesAndDiffText() {
        let state = GitCacheState()
        let entry = makeStashEntry(id: "stash@{0}", message: "detail payload")
        let files = [
            GitStashFileEntry(path: "Sources/App.swift", status: "M", additions: 12, deletions: 3, sourceKind: "tracked"),
            GitStashFileEntry(path: "README.md", status: "A", additions: 8, deletions: 0, sourceKind: "index")
        ]
        let diffText = "diff --git a/Sources/App.swift b/Sources/App.swift\n+print(\"stash\")"

        state.handleGitStashShowResult(
            GitStashShowResult(
                project: "proj",
                workspace: "default",
                stashId: "stash@{0}",
                entry: entry,
                files: files,
                diffText: diffText,
                isBinarySummaryTruncated: false
            )
        )

        let cache = state.getStashShowCache(project: "proj", workspace: "default", stashId: "stash@{0}")
        XCTAssertEqual(cache.stashId, "stash@{0}")
        XCTAssertEqual(cache.entry?.message, "detail payload")
        XCTAssertEqual(cache.files.map(\.path), ["Sources/App.swift", "README.md"])
        XCTAssertEqual(cache.files.map(\.sourceKind), ["tracked", "index"])
        XCTAssertEqual(cache.diffText, diffText)
        XCTAssertFalse(cache.isLoading)
    }

    func testStashOperationResultsRefreshListAndStatusForSaveApplyPopDrop() {
        for operation in ["save", "apply", "pop", "drop"] {
            let harness = makeRefreshHarness()
            let key = harness.state.stashCacheKey(project: "proj", workspace: "default")
            harness.state.stashOpInFlight[key] = true

            harness.state.handleGitStashOpResult(
                GitStashOpResult(
                    project: "proj",
                    workspace: "default",
                    op: operation,
                    stashId: "stash@{0}",
                    ok: true,
                    state: "completed",
                    message: nil,
                    affectedPaths: ["Sources/App.swift"],
                    conflictFiles: []
                )
            )

            let requests = waitForScheduledRefreshes(
                harness.recorder,
                description: "op=\(operation) 应触发 stash/status/branches 刷新"
            )

            XCTAssertFalse(harness.state.stashOpInFlight[key] ?? true, "\(operation) 完成后应清理 in-flight")
            XCTAssertNil(harness.state.stashLastError[key], "\(operation) 成功后不应残留错误")
            XCTAssertTrue(
                requests.contains { $0.domain == "git" && $0.path.hasSuffix("/git/stashes") },
                "\(operation) 应刷新 stash 列表"
            )
            XCTAssertTrue(
                requests.contains { $0.domain == "git" && $0.path.hasSuffix("/git/status") },
                "\(operation) 应刷新 git status"
            )
        }
    }

    func testPopConflictPreservesExistingStashEntry() {
        let harness = makeRefreshHarness()
        let entry = makeStashEntry(id: "stash@{0}", message: "keep me")
        harness.state.handleGitStashListResult(
            GitStashListResult(project: "proj", workspace: "default", entries: [entry])
        )

        let key = harness.state.stashCacheKey(project: "proj", workspace: "default")
        harness.state.stashOpInFlight[key] = true
        harness.state.handleGitStashOpResult(
            GitStashOpResult(
                project: "proj",
                workspace: "default",
                op: "pop",
                stashId: "stash@{0}",
                ok: false,
                state: "conflict",
                message: "Merge conflict",
                affectedPaths: ["Sources/App.swift"],
                conflictFiles: [ConflictFileEntry(path: "Sources/App.swift", conflictType: "content", staged: false)]
            )
        )

        _ = waitForScheduledRefreshes(harness.recorder, description: "pop conflict 也应触发刷新")

        let cache = harness.state.getStashListCache(project: "proj", workspace: "default")
        XCTAssertEqual(cache.entries.map(\.stashId), ["stash@{0}"])
        XCTAssertEqual(harness.state.selectedStashId[key], "stash@{0}")
        XCTAssertEqual(harness.state.stashLastError[key], "Merge conflict")
    }

    func testConflictFilesBridgeIntoExistingConflictWizardCache() {
        let state = GitCacheState()
        let wizardKey = state.conflictWizardKey(project: "proj", workspace: "default", context: "workspace")
        let existingDetail = GitConflictDetailResultCache(
            from: GitConflictDetailResult(
                project: "proj",
                workspace: "default",
                context: "workspace",
                path: "Sources/App.swift",
                baseContent: "base",
                oursContent: "ours",
                theirsContent: "theirs",
                currentContent: "<<<<<<< HEAD",
                conflictMarkersCount: 1,
                isBinary: false
            )
        )
        state.conflictWizardCache[wizardKey] = ConflictWizardCache(
            snapshot: nil,
            selectedFilePath: "Sources/App.swift",
            currentDetail: existingDetail,
            isLoading: true,
            updatedAt: .distantPast
        )

        state.handleGitStashOpResult(
            GitStashOpResult(
                project: "proj",
                workspace: "default",
                op: "apply",
                stashId: "stash@{0}",
                ok: false,
                state: "conflict",
                message: "Conflict",
                affectedPaths: ["Sources/App.swift", "README.md"],
                conflictFiles: [
                    ConflictFileEntry(path: "Sources/App.swift", conflictType: "content", staged: false),
                    ConflictFileEntry(path: "README.md", conflictType: "add_add", staged: false)
                ]
            )
        )

        let wizard = state.getConflictWizardCache(project: "proj", workspace: "default", context: "workspace")
        XCTAssertEqual(wizard.snapshot?.context, "workspace")
        XCTAssertEqual(wizard.snapshot?.files.map(\.path), ["Sources/App.swift", "README.md"])
        XCTAssertFalse(wizard.snapshot?.allResolved ?? true)
        XCTAssertEqual(wizard.selectedFilePath, "Sources/App.swift")
        XCTAssertEqual(wizard.currentDetail?.path, "Sources/App.swift")
    }

    // MARK: - Helpers

    private func makeStashEntry(id: String, message: String) -> GitStashEntry {
        GitStashEntry(
            stashId: id,
            title: "\(id): WIP on main",
            message: message,
            branchName: "main",
            createdAt: "2026-03-14T23:59:12Z",
            fileCount: 2,
            includesUntracked: false,
            includesIndex: false
        )
    }

    private func makeRefreshHarness() -> (state: GitCacheState, recorder: HTTPRequestRecorder) {
        let recorder = HTTPRequestRecorder(expectedRequestCount: 3)
        let client = WSClient()
        client.currentURL = URL(string: "ws://127.0.0.1:47999/ws")
        client.httpReadFetcherOverride = { _, path, _, _, _, _ in
            if path.hasSuffix("/git/stashes") {
                return try Self.makeJSONData([
                    "project": "proj",
                    "workspace": "default",
                    "entries": []
                ])
            }
            if path.hasSuffix("/git/status") {
                return try Self.makeJSONData([
                    "project": "proj",
                    "workspace": "default",
                    "items": [],
                    "is_git_repo": true,
                    "has_staged_changes": false,
                    "staged_count": 0,
                    "current_branch": "main",
                    "default_branch": "main",
                    "ahead_by": 0,
                    "behind_by": 0,
                    "compared_branch": "main"
                ])
            }
            if path.hasSuffix("/git/branches") {
                return try Self.makeJSONData([
                    "project": "proj",
                    "workspace": "default",
                    "current": "main",
                    "branches": []
                ])
            }
            throw NSError(domain: "GitStashSemanticsTests", code: 1)
        }
        client.onHTTPRequestScheduled = { domain, path, queryItems in
            recorder.record(domain: domain, path: path, queryItems: queryItems)
        }

        let state = GitCacheState()
        state.wsClient = client
        return (state, recorder)
    }

    private func waitForScheduledRefreshes(
        _ recorder: HTTPRequestRecorder,
        description: String,
        timeout: TimeInterval = 2.0
    ) -> [HTTPRequestRecorder.Request] {
        let expectation = expectation(description: description)
        recorder.onSatisfied = {
            expectation.fulfill()
        }
        recorder.fireIfSatisfied()
        wait(for: [expectation], timeout: timeout)
        return recorder.requests
    }

    private static func makeJSONData(_ json: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: json, options: [])
    }
}

private final class HTTPRequestRecorder {
    struct Request: Equatable {
        let domain: String
        let path: String
        let queryItems: [URLQueryItem]
    }

    private let expectedRequestCount: Int
    private let lock = NSLock()
    private var didFire = false
    private(set) var requests: [Request] = []
    var onSatisfied: (() -> Void)?

    init(expectedRequestCount: Int) {
        self.expectedRequestCount = expectedRequestCount
    }

    func record(domain: String, path: String, queryItems: [URLQueryItem]) {
        lock.lock()
        requests.append(Request(domain: domain, path: path, queryItems: queryItems))
        let shouldFire = !didFire && requests.count >= expectedRequestCount
        if shouldFire {
            didFire = true
        }
        let callback = shouldFire ? onSatisfied : nil
        lock.unlock()
        callback?()
    }

    func fireIfSatisfied() {
        lock.lock()
        let shouldFire = !didFire && requests.count >= expectedRequestCount
        if shouldFire {
            didFire = true
        }
        let callback = shouldFire ? onSatisfied : nil
        lock.unlock()
        callback?()
    }
}
