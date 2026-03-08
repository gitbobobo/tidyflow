import XCTest
@testable import TidyFlow

final class AISessionVisibilityTests: XCTestCase {
    func testSessionStartedDefaultsOriginToUserWhenMissing() {
        let json: [String: Any] = [
            "project_name": "demo",
            "workspace_name": "default",
            "ai_tool": "codex",
            "session_id": "s-1",
            "title": "普通会话",
            "updated_at": Int64(42),
        ]

        let result = AISessionStartedV2.from(json: json)

        XCTAssertEqual(result?.origin, .user)
    }

    func testSessionListParsesEvolutionOrigin() {
        let json: [String: Any] = [
            "project_name": "demo",
            "workspace_name": "default",
            "sessions": [
                [
                    "project_name": "demo",
                    "workspace_name": "default",
                    "ai_tool": "codex",
                    "id": "s-2",
                    "title": "系统会话",
                    "updated_at": Int64(99),
                    "session_origin": "evolution_system",
                ],
            ],
            "has_more": false,
        ]

        let result = AISessionListV2.from(json: json)

        XCTAssertEqual(result?.sessions.first?.origin, .evolutionSystem)
    }

    func testSetAISessionsKeepsHiddenCacheButHidesFromDefaultList() {
        let appState = AppState()
        let visible = makeSession(id: "visible", origin: .user)
        let hidden = makeSession(id: "hidden", origin: .evolutionSystem)

        appState.setAISessions([visible, hidden], for: .codex)

        XCTAssertEqual(appState.aiSessionsForTool(.codex), [visible])
        XCTAssertEqual(
            appState.cachedAISession(
                projectName: hidden.projectName,
                workspaceName: hidden.workspaceName,
                aiTool: hidden.aiTool,
                sessionId: hidden.id
            )?.origin,
            .evolutionSystem
        )
    }

    func testUpsertHiddenSessionDoesNotLeakIntoPageState() {
        let appState = AppState()
        appState.selectedProjectName = "demo"
        appState.selectedWorkspaceKey = "default"

        let visible = makeSession(id: "visible", origin: .user)
        let hidden = makeSession(id: "hidden", origin: .evolutionSystem)
        appState.updateSessionListPageState(
            AISessionListPageState(sessions: [visible], hasMore: false, nextCursor: nil, isLoadingInitial: false, isLoadingNextPage: false),
            project: "demo",
            workspace: "default",
            filter: .all
        )
        appState.setAISessions([visible], for: .codex)

        appState.upsertAISession(hidden, for: .codex)

        XCTAssertEqual(appState.sessionListPageState(for: .all).sessions, [visible])
        XCTAssertEqual(appState.aiSessionsForTool(.codex), [visible])
        XCTAssertEqual(
            appState.cachedAISession(
                projectName: hidden.projectName,
                workspaceName: hidden.workspaceName,
                aiTool: hidden.aiTool,
                sessionId: hidden.id
            )?.origin,
            .evolutionSystem
        )
    }

    private func makeSession(id: String, origin: AISessionOrigin) -> AISessionInfo {
        AISessionInfo(
            projectName: "demo",
            workspaceName: "default",
            aiTool: .codex,
            id: id,
            title: id,
            updatedAt: 100,
            origin: origin
        )
    }
}
