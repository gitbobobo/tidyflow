import XCTest
@testable import TidyFlow
@testable import TidyFlowShared

private actor HTTPFetchCounter {
    private var value: Int = 0

    func increment() {
        value += 1
    }

    func current() -> Int {
        value
    }
}

final class HTTPQueryClientTests: XCTestCase {
    func testHTTPQueryKeyIgnoresQueryItemOrder() {
        let baseURL = URL(string: "http://127.0.0.1:47999")!
        let lhs = HTTPQueryKey(
            baseURL: baseURL,
            path: "/api/v1/projects/demo/workspaces/main/git/status",
            queryItems: [
                URLQueryItem(name: "cursor", value: "abc"),
                URLQueryItem(name: "limit", value: "50")
            ],
            fallbackAction: "ai_session_list"
        )
        let rhs = HTTPQueryKey(
            baseURL: baseURL,
            path: "/api/v1/projects/demo/workspaces/main/git/status",
            queryItems: [
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "cursor", value: "abc")
            ],
            fallbackAction: "ai_session_list"
        )

        XCTAssertEqual(lhs, rhs)
        XCTAssertEqual(lhs.hashValue, rhs.hashValue)
    }

    func testHTTPQueryClientDeduplicatesConcurrentFetches() async throws {
        let client = HTTPQueryClient()
        let counter = HTTPFetchCounter()
        let policy = HTTPQueryPolicy(staleTime: 60, gcTime: 600)
        let key = HTTPQueryKey(
            baseURL: URL(string: "http://127.0.0.1:47999")!,
            path: "/api/v1/projects/demo/workspaces/main/git/status",
            queryItems: [],
            fallbackAction: "git_status_result"
        )
        let payload = try XCTUnwrap(
            """
            {"project":"demo","workspace":"main","items":[],"is_git_repo":true}
            """.data(using: .utf8)
        )

        async let first = client.fetch(key: key, policy: policy, force: true) {
            await counter.increment()
            try await Task.sleep(nanoseconds: 50_000_000)
            return payload
        }
        async let second = client.fetch(key: key, policy: policy, force: true) {
            await counter.increment()
            try await Task.sleep(nanoseconds: 50_000_000)
            return payload
        }

        let (lhs, rhs) = try await (first, second)
        XCTAssertEqual(lhs, payload)
        XCTAssertEqual(rhs, payload)
        let fetchCount = await counter.current()
        XCTAssertEqual(fetchCount, 1)
    }

    func testHTTPQueryClientServesStaleEntryAndForceRefreshes() async throws {
        let client = HTTPQueryClient()
        let policy = HTTPQueryPolicy(staleTime: 0.01, gcTime: 600)
        let key = HTTPQueryKey(
            baseURL: URL(string: "http://127.0.0.1:47999")!,
            path: "/api/v1/projects/demo/workspaces/main/evidence/snapshot",
            queryItems: [],
            fallbackAction: "evidence_snapshot"
        )
        let stalePayload = try XCTUnwrap("{\"type\":\"evidence_snapshot\",\"version\":1}".data(using: .utf8))
        let freshPayload = try XCTUnwrap("{\"type\":\"evidence_snapshot\",\"version\":2}".data(using: .utf8))

        _ = try await client.fetch(key: key, policy: policy, force: true) {
            stalePayload
        }

        try await Task.sleep(nanoseconds: 30_000_000)

        switch await client.cachedValue(for: key, policy: policy, mode: .default) {
        case let .stale(payload):
            XCTAssertEqual(payload, stalePayload)
        default:
            XCTFail("过期缓存应先以 stale 形式返回")
        }

        let refreshed = try await client.fetch(key: key, policy: policy, force: true) {
            freshPayload
        }
        XCTAssertEqual(refreshed, freshPayload)
    }

    @MainActor
    func testWSClientUsesFreshCacheThenForceRefreshesAndGitInvalidation() async throws {
        let wsClient = WSClient(url: URL(string: "ws://127.0.0.1:47999/ws")!)
        let counter = HTTPFetchCounter()
        let payload = try makeJSONData([
            "project": "demo",
            "workspace": "main",
            "items": [],
            "is_git_repo": true
        ])

        wsClient.httpReadFetcherOverride = { _, _, _, _, _, _ in
            await counter.increment()
            return payload
        }

        let first = expectation(description: "first git status")
        wsClient.onGitStatusResult = { _ in first.fulfill() }
        wsClient.requestGitStatus(project: "demo", workspace: "main")
        await fulfillment(of: [first], timeout: 1.0)
        let countAfterFirst = await counter.current()
        XCTAssertEqual(countAfterFirst, 1)

        let second = expectation(description: "second git status from cache")
        wsClient.onGitStatusResult = { _ in second.fulfill() }
        wsClient.requestGitStatus(project: "demo", workspace: "main")
        await fulfillment(of: [second], timeout: 1.0)
        let countAfterSecond = await counter.current()
        XCTAssertEqual(countAfterSecond, 1)

        let third = expectation(description: "force refreshed git status")
        wsClient.onGitStatusResult = { _ in third.fulfill() }
        wsClient.requestGitStatus(project: "demo", workspace: "main", cacheMode: .forceRefresh)
        await fulfillment(of: [third], timeout: 1.0)
        let countAfterForceRefresh = await counter.current()
        XCTAssertEqual(countAfterForceRefresh, 2)

        XCTAssertTrue(wsClient.handleGitDomain("git_status_changed", json: [
            "project": "demo",
            "workspace": "main"
        ]))
        try await waitUntil {
            let key = HTTPQueryKey(
                baseURL: URL(string: "http://127.0.0.1:47999")!,
                path: "/api/v1/projects/demo/workspaces/main/git/status",
                queryItems: [],
                fallbackAction: "git_status_result"
            )
            return await wsClient.httpQueryClient.entry(for: key) == nil
        }

        let fourth = expectation(description: "git status after invalidation")
        wsClient.onGitStatusResult = { _ in fourth.fulfill() }
        wsClient.requestGitStatus(project: "demo", workspace: "main")
        await fulfillment(of: [fourth], timeout: 1.0)
        let countAfterInvalidation = await counter.current()
        XCTAssertEqual(countAfterInvalidation, 3)
    }

    @MainActor
    func testWSClientInvalidatesFileAndAIQueriesAfterEvents() async throws {
        let wsClient = WSClient(url: URL(string: "ws://127.0.0.1:47999/ws")!)
        let fileCounter = HTTPFetchCounter()
        let aiCounter = HTTPFetchCounter()

        wsClient.httpReadFetcherOverride = { _, path, _, _, _, _ in
            if path.contains("/files") {
                await fileCounter.increment()
                return try self.makeJSONData([
                    "project": "demo",
                    "workspace": "main",
                    "path": ".",
                    "items": []
                ])
            }
            await aiCounter.increment()
            return try self.makeJSONData([
                "project_name": "demo",
                "workspace_name": "main",
                "sessions": [[
                    "project_name": "demo",
                    "workspace_name": "main",
                    "ai_tool": "codex",
                    "id": "session-1",
                    "title": "会话",
                    "updated_at": 1
                ]],
                "has_more": false
            ])
        }

        let fileFirst = expectation(description: "first file list")
        wsClient.onFileListResult = { _ in fileFirst.fulfill() }
        wsClient.requestFileList(project: "demo", workspace: "main", path: ".")
        await fulfillment(of: [fileFirst], timeout: 1.0)
        let fileCountAfterFirst = await fileCounter.current()
        XCTAssertEqual(fileCountAfterFirst, 1)

        XCTAssertTrue(wsClient.handleFileDomain("file_changed", json: [
            "project": "demo",
            "workspace": "main",
            "paths": ["README.md"],
            "kind": "modified"
        ]))
        try await waitUntil {
            let key = HTTPQueryKey(
                baseURL: URL(string: "http://127.0.0.1:47999")!,
                path: "/api/v1/projects/demo/workspaces/main/files",
                queryItems: [URLQueryItem(name: "path", value: ".")],
                fallbackAction: "file_list_result"
            )
            return await wsClient.httpQueryClient.entry(for: key) == nil
        }

        let fileSecond = expectation(description: "file list after invalidation")
        wsClient.onFileListResult = { _ in fileSecond.fulfill() }
        wsClient.requestFileList(project: "demo", workspace: "main", path: ".")
        await fulfillment(of: [fileSecond], timeout: 1.0)
        let fileCountAfterInvalidation = await fileCounter.current()
        XCTAssertEqual(fileCountAfterInvalidation, 2)

        let aiFirst = expectation(description: "first ai session list")
        wsClient.onAISessionList = { _ in aiFirst.fulfill() }
        wsClient.requestAISessionList(projectName: "demo", workspaceName: "main", filter: .codex)
        await fulfillment(of: [aiFirst], timeout: 1.0)
        let aiCountAfterFirst = await aiCounter.current()
        XCTAssertEqual(aiCountAfterFirst, 1)

        XCTAssertTrue(wsClient.handleAiDomain("ai_session_messages_update", json: [
            "project_name": "demo",
            "workspace_name": "main",
            "ai_tool": "codex",
            "session_id": "session-1",
            "from_revision": 1,
            "to_revision": 2,
            "is_streaming": false
        ]))
        try await waitUntil {
            let key = HTTPQueryKey(
                baseURL: URL(string: "http://127.0.0.1:47999")!,
                path: "/api/v1/projects/demo/workspaces/main/ai/sessions",
                queryItems: [URLQueryItem(name: "ai_tool", value: "codex"), URLQueryItem(name: "limit", value: "50")],
                fallbackAction: "ai_session_list"
            )
            return await wsClient.httpQueryClient.entry(for: key) == nil
        }

        let aiSecond = expectation(description: "ai session list after invalidation")
        wsClient.onAISessionList = { _ in aiSecond.fulfill() }
        wsClient.requestAISessionList(projectName: "demo", workspaceName: "main", filter: .codex)
        await fulfillment(of: [aiSecond], timeout: 1.0)
        let aiCountAfterInvalidation = await aiCounter.current()
        XCTAssertEqual(aiCountAfterInvalidation, 2)
    }

    private func makeJSONData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func waitUntil(
        timeout: TimeInterval = 1.0,
        interval: UInt64 = 10_000_000,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: interval)
        }
        XCTFail("等待条件成立超时")
    }
}
