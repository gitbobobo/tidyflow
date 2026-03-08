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

// MARK: - WI-001/WI-005 共享语义层回归测试

final class AISessionSemanticsTests: XCTestCase {

    // MARK: sessionKey 格式

    func testSessionKeyFormat() {
        let key = AISessionSemantics.sessionKey(
            project: "myproject",
            workspace: "main",
            aiTool: .codex,
            sessionId: "s-abc"
        )
        XCTAssertEqual(key, "myproject::main::codex::s-abc")
    }

    func testSessionKeyIsolatesAcrossProjects() {
        let key1 = AISessionSemantics.sessionKey(project: "p1", workspace: "ws", aiTool: .codex, sessionId: "s")
        let key2 = AISessionSemantics.sessionKey(project: "p2", workspace: "ws", aiTool: .codex, sessionId: "s")
        XCTAssertNotEqual(key1, key2, "同 session_id 但不同 project 的会话键必须不同")
    }

    func testSessionKeyIsolatesAcrossWorkspaces() {
        let key1 = AISessionSemantics.sessionKey(project: "p", workspace: "ws1", aiTool: .codex, sessionId: "s")
        let key2 = AISessionSemantics.sessionKey(project: "p", workspace: "ws2", aiTool: .codex, sessionId: "s")
        XCTAssertNotEqual(key1, key2, "同 session_id 但不同 workspace 的会话键必须不同")
    }

    func testSessionKeyIsolatesAcrossAITools() {
        let key1 = AISessionSemantics.sessionKey(project: "p", workspace: "ws", aiTool: .codex, sessionId: "s")
        let key2 = AISessionSemantics.sessionKey(project: "p", workspace: "ws", aiTool: .claude, sessionId: "s")
        XCTAssertNotEqual(key1, key2, "同 session_id 但不同 ai_tool 的会话键必须不同")
    }

    func testAISessionInfoSessionKeyMatchesSemantics() {
        let session = AISessionInfo(
            projectName: "proj",
            workspaceName: "ws",
            aiTool: .codex,
            id: "sid",
            title: "T",
            updatedAt: 0,
            origin: .user
        )
        let expected = AISessionSemantics.sessionKey(project: "proj", workspace: "ws", aiTool: .codex, sessionId: "sid")
        XCTAssertEqual(session.sessionKey, expected)
    }

    // MARK: 列表可见性

    func testUserOriginIsVisible() {
        XCTAssertTrue(AISessionSemantics.isSessionVisibleInDefaultList(origin: .user))
    }

    func testEvolutionSystemOriginIsHidden() {
        XCTAssertFalse(AISessionSemantics.isSessionVisibleInDefaultList(origin: .evolutionSystem))
    }

    func testAISessionInfoVisibilityDelegatesToSemantics() {
        let userSession = AISessionInfo(projectName: "p", workspaceName: "w", aiTool: .codex, id: "1", title: "", updatedAt: 0, origin: .user)
        let sysSession = AISessionInfo(projectName: "p", workspaceName: "w", aiTool: .codex, id: "2", title: "", updatedAt: 0, origin: .evolutionSystem)
        XCTAssertTrue(userSession.isVisibleInDefaultSessionList)
        XCTAssertFalse(sysSession.isVisibleInDefaultSessionList)
    }

    // MARK: normalizeMessageStream — pending question 重建

    func testNormalizeEmptyMessagesProducesNoRequests() {
        let output = AISessionSemantics.normalizeMessageStream(
            sessionId: "s",
            messages: [],
            primarySelectionHint: nil
        )
        XCTAssertTrue(output.pendingQuestionRequests.isEmpty)
    }

    func testNormalizeExtractsPendingQuestionFromToolView() {
        let questionInfo = AIQuestionInfo(
            question: "确认继续？",
            header: "",
            options: [],
            multiple: false,
            custom: false
        )
        let toolViewQuestion = AIToolViewQuestion(
            requestID: "req-1",
            toolMessageID: "tm-1",
            promptItems: [questionInfo],
            interactive: true,
            answers: nil
        )
        let toolView = AIToolView(
            status: .running,
            displayTitle: "question",
            statusText: "running",
            summary: nil,
            headerCommandSummary: nil,
            durationMs: nil,
            sections: [],
            locations: [],
            question: toolViewQuestion,
            linkedSession: nil
        )
        let part = AIProtocolPartInfo(
            id: "p-1",
            partType: "tool",
            text: nil,
            mime: nil,
            filename: nil,
            url: nil,
            synthetic: nil,
            ignored: nil,
            source: nil,
            toolName: "question",
            toolCallId: "tc-1",
            toolKind: nil,
            toolView: toolView
        )
        let message = AIProtocolMessageInfo(
            id: "m-1",
            role: "assistant",
            createdAt: nil,
            agent: nil,
            modelProviderID: nil,
            modelID: nil,
            parts: [part]
        )

        let output = AISessionSemantics.normalizeMessageStream(
            sessionId: "s",
            messages: [message],
            primarySelectionHint: nil
        )

        XCTAssertEqual(output.pendingQuestionRequests.count, 1)
        XCTAssertEqual(output.pendingQuestionRequests.first?.id, "req-1")
    }

    func testNormalizeSkipsCompletedQuestion() {
        let questionInfo = AIQuestionInfo(
            question: "是否继续？",
            header: "",
            options: [],
            multiple: false,
            custom: false
        )
        let toolViewQuestion = AIToolViewQuestion(
            requestID: "req-2",
            toolMessageID: "tm-2",
            promptItems: [questionInfo],
            interactive: true,
            answers: [["OK"]]
        )
        let toolView = AIToolView(
            status: .completed,
            displayTitle: "question",
            statusText: "completed",
            summary: nil,
            headerCommandSummary: nil,
            durationMs: nil,
            sections: [],
            locations: [],
            question: toolViewQuestion,
            linkedSession: nil
        )
        let part = AIProtocolPartInfo(
            id: "p-2",
            partType: "tool",
            text: nil,
            mime: nil,
            filename: nil,
            url: nil,
            synthetic: nil,
            ignored: nil,
            source: nil,
            toolName: "question",
            toolCallId: "tc-2",
            toolKind: nil,
            toolView: toolView
        )
        let message = AIProtocolMessageInfo(
            id: "m-2",
            role: "assistant",
            createdAt: nil,
            agent: nil,
            modelProviderID: nil,
            modelID: nil,
            parts: [part]
        )

        let output = AISessionSemantics.normalizeMessageStream(
            sessionId: "s",
            messages: [message],
            primarySelectionHint: nil
        )

        XCTAssertTrue(output.pendingQuestionRequests.isEmpty, "completed 状态的 question 不应重建为 pending request")
    }

    // MARK: normalizeMessageStream — 多工作区数据隔离

    func testMultiWorkspaceSessionKeysAreIndependent() {
        let appState = AppState()
        let ws1Session = AISessionInfo(projectName: "proj", workspaceName: "ws1", aiTool: .codex, id: "s-shared", title: "A", updatedAt: 10, origin: .user)
        let ws2Session = AISessionInfo(projectName: "proj", workspaceName: "ws2", aiTool: .codex, id: "s-shared", title: "B", updatedAt: 20, origin: .user)
        appState.upsertAISession(ws1Session, for: .codex)
        appState.upsertAISession(ws2Session, for: .codex)

        // 两个工作区的同名 session_id 应互不干扰
        let fetched1 = appState.cachedAISession(projectName: "proj", workspaceName: "ws1", aiTool: .codex, sessionId: "s-shared")
        let fetched2 = appState.cachedAISession(projectName: "proj", workspaceName: "ws2", aiTool: .codex, sessionId: "s-shared")
        XCTAssertEqual(fetched1?.title, "A")
        XCTAssertEqual(fetched2?.title, "B")
        XCTAssertNotEqual(fetched1?.sessionKey, fetched2?.sessionKey)
    }
}

// MARK: - AISessionListSemantics 共享语义层测试

final class AISessionListSemanticsTests: XCTestCase {

    // MARK: 当前选中判定

    func testIsSessionSelected_matchesIdAndTool() {
        let session = AISessionInfo(projectName: "p", workspaceName: "w", aiTool: .codex, id: "s1", title: "T", updatedAt: 0, origin: .user)
        XCTAssertTrue(AISessionListSemantics.isSessionSelected(session: session, currentSessionId: "s1", currentTool: .codex))
    }

    func testIsSessionSelected_mismatchId() {
        let session = AISessionInfo(projectName: "p", workspaceName: "w", aiTool: .codex, id: "s1", title: "T", updatedAt: 0, origin: .user)
        XCTAssertFalse(AISessionListSemantics.isSessionSelected(session: session, currentSessionId: "s2", currentTool: .codex))
    }

    func testIsSessionSelected_mismatchTool() {
        let session = AISessionInfo(projectName: "p", workspaceName: "w", aiTool: .codex, id: "s1", title: "T", updatedAt: 0, origin: .user)
        XCTAssertFalse(AISessionListSemantics.isSessionSelected(session: session, currentSessionId: "s1", currentTool: .claude))
    }

    func testIsSessionSelected_nilSessionId() {
        let session = AISessionInfo(projectName: "p", workspaceName: "w", aiTool: .codex, id: "s1", title: "T", updatedAt: 0, origin: .user)
        XCTAssertFalse(AISessionListSemantics.isSessionSelected(session: session, currentSessionId: nil, currentTool: .codex))
    }

    // MARK: 分页缓存键

    func testPageKeyFormat() {
        let key = AISessionListSemantics.pageKey(project: "proj", workspace: "ws", filter: .all)
        XCTAssertEqual(key, "proj::ws::all")
    }

    func testPageKeyIsolatesAcrossWorkspaces() {
        let key1 = AISessionListSemantics.pageKey(project: "p", workspace: "ws1", filter: .all)
        let key2 = AISessionListSemantics.pageKey(project: "p", workspace: "ws2", filter: .all)
        XCTAssertNotEqual(key1, key2, "不同工作区的分页键必须不同")
    }

    func testPageKeyIsolatesAcrossProjects() {
        let key1 = AISessionListSemantics.pageKey(project: "p1", workspace: "ws", filter: .all)
        let key2 = AISessionListSemantics.pageKey(project: "p2", workspace: "ws", filter: .all)
        XCTAssertNotEqual(key1, key2, "不同项目的分页键必须不同")
    }

    func testPageKeyIsolatesAcrossFilters() {
        let key1 = AISessionListSemantics.pageKey(project: "p", workspace: "ws", filter: .all)
        let key2 = AISessionListSemantics.pageKey(project: "p", workspace: "ws", filter: .tool(.codex))
        XCTAssertNotEqual(key1, key2, "不同筛选条件的分页键必须不同")
    }

    // MARK: 分页防重入

    func testRequestAISessionList_preventsDoubleInitialLoad() {
        let appState = AppState()
        appState.selectedProjectName = "proj"
        appState.selectedWorkspaceKey = "ws"
        // 手动模拟已在加载
        let pageKey = appState.sessionListPageKey(project: "proj", workspace: "ws", filter: .all)
        appState.aiSessionListPageStates[pageKey] = AISessionListPageState(
            sessions: [], hasMore: false, nextCursor: nil,
            isLoadingInitial: true, isLoadingNextPage: false
        )
        // 再次请求应被拒绝
        let result = appState.requestAISessionList(for: .all)
        XCTAssertFalse(result, "已在初始加载时不应重复发起请求")
    }

    func testClearPageStates_resetsAllKeys() {
        let appState = AppState()
        appState.selectedProjectName = "proj"
        appState.selectedWorkspaceKey = "ws"
        appState.updateSessionListPageState(
            AISessionListPageState(sessions: [], hasMore: true, nextCursor: "c1",
                                   isLoadingInitial: false, isLoadingNextPage: false),
            project: "proj", workspace: "ws", filter: .all
        )
        XCTAssertFalse(appState.aiSessionListPageStates.isEmpty)
        appState.clearAISessionListPageStates()
        XCTAssertTrue(appState.aiSessionListPageStates.isEmpty, "清理后分页状态应为空")
    }
}
