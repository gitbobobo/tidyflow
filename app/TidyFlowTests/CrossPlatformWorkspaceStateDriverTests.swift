import XCTest
@testable import TidyFlowShared

// MARK: - 跨平台工作区状态驱动测试

final class CrossPlatformWorkspaceStateDriverTests: XCTestCase {

    // MARK: - SharedWorkspaceContext

    func testSharedWorkspaceContextEquality() {
        let a = SharedWorkspaceContext(projectName: "proj", workspaceName: "ws", globalKey: "proj:ws")
        let b = SharedWorkspaceContext(projectName: "proj", workspaceName: "ws", globalKey: "proj:ws")
        XCTAssertEqual(a, b)
    }

    func testSharedWorkspaceContextInequalityDifferentProject() {
        let a = SharedWorkspaceContext(projectName: "proj-a", workspaceName: "ws", globalKey: "proj-a:ws")
        let b = SharedWorkspaceContext(projectName: "proj-b", workspaceName: "ws", globalKey: "proj-b:ws")
        XCTAssertNotEqual(a, b)
    }

    func testSharedWorkspaceContextHashable() {
        let a = SharedWorkspaceContext(projectName: "proj", workspaceName: "ws", globalKey: "proj:ws")
        let b = SharedWorkspaceContext(projectName: "proj", workspaceName: "ws", globalKey: "proj:ws")
        XCTAssertEqual(a.hashValue, b.hashValue)
        let set: Set<SharedWorkspaceContext> = [a, b]
        XCTAssertEqual(set.count, 1)
    }

    // MARK: - WorkspaceSelectionTransition（工作区切换重置决策）

    func testTransitionFromNilIsContextChanged() {
        let target = SharedWorkspaceContext(projectName: "proj", workspaceName: "default", globalKey: "proj:default")
        let transition = SharedWorkspaceStateDriver.computeTransition(from: nil, to: target)
        XCTAssertTrue(transition.isContextChanged)
        XCTAssertTrue(transition.shouldResetAIChatStage)
        XCTAssertTrue(transition.shouldResetTerminalLifecycle)
        XCTAssertTrue(transition.shouldClearPreviousWorkspaceSessionList)
    }

    func testTransitionToSameContextIsNotChanged() {
        let ctx = SharedWorkspaceContext(projectName: "proj", workspaceName: "default", globalKey: "proj:default")
        let transition = SharedWorkspaceStateDriver.computeTransition(from: ctx, to: ctx)
        XCTAssertFalse(transition.isContextChanged)
        XCTAssertFalse(transition.shouldResetAIChatStage)
        XCTAssertFalse(transition.shouldResetTerminalLifecycle)
        XCTAssertFalse(transition.shouldClearPreviousWorkspaceSessionList)
    }

    func testTransitionToDifferentWorkspaceIsChanged() {
        let from = SharedWorkspaceContext(projectName: "proj", workspaceName: "ws-a", globalKey: "proj:ws-a")
        let to = SharedWorkspaceContext(projectName: "proj", workspaceName: "ws-b", globalKey: "proj:ws-b")
        let transition = SharedWorkspaceStateDriver.computeTransition(from: from, to: to)
        XCTAssertTrue(transition.isContextChanged)
        XCTAssertTrue(transition.shouldResetAIChatStage)
        XCTAssertTrue(transition.shouldResetTerminalLifecycle)
    }

    func testTransitionToDifferentProjectIsChanged() {
        let from = SharedWorkspaceContext(projectName: "proj-a", workspaceName: "default", globalKey: "proj-a:default")
        let to = SharedWorkspaceContext(projectName: "proj-b", workspaceName: "default", globalKey: "proj-b:default")
        let transition = SharedWorkspaceStateDriver.computeTransition(from: from, to: to)
        XCTAssertTrue(transition.isContextChanged)
    }

    // MARK: - AI 会话列表请求描述

    func testMakeAISessionListRequestReturnsNilWhenContextIsNil() {
        let result = SharedWorkspaceStateDriver.makeAISessionListRequest(
            context: nil, isConnectionReady: true, filter: nil, limit: 50, cursor: nil, append: false, forceRefresh: false
        )
        XCTAssertNil(result)
    }

    func testMakeAISessionListRequestReturnsNilWhenNotConnected() {
        let ctx = SharedWorkspaceContext(projectName: "proj", workspaceName: "ws", globalKey: "proj:ws")
        let result = SharedWorkspaceStateDriver.makeAISessionListRequest(
            context: ctx, isConnectionReady: false, filter: nil, limit: 50, cursor: nil, append: false, forceRefresh: false
        )
        XCTAssertNil(result)
    }

    func testMakeAISessionListRequestReturnsNilWhenProjectEmpty() {
        let ctx = SharedWorkspaceContext(projectName: "", workspaceName: "ws", globalKey: ":ws")
        let result = SharedWorkspaceStateDriver.makeAISessionListRequest(
            context: ctx, isConnectionReady: true, filter: nil, limit: 50, cursor: nil, append: false, forceRefresh: false
        )
        XCTAssertNil(result)
    }

    func testMakeAISessionListRequestReturnsNilWhenWorkspaceEmpty() {
        let ctx = SharedWorkspaceContext(projectName: "proj", workspaceName: "", globalKey: "proj:")
        let result = SharedWorkspaceStateDriver.makeAISessionListRequest(
            context: ctx, isConnectionReady: true, filter: nil, limit: 50, cursor: nil, append: false, forceRefresh: false
        )
        XCTAssertNil(result)
    }

    func testMakeAISessionListRequestSuccessFirstPage() {
        let ctx = SharedWorkspaceContext(projectName: "proj", workspaceName: "ws", globalKey: "proj:ws")
        let result = SharedWorkspaceStateDriver.makeAISessionListRequest(
            context: ctx, isConnectionReady: true, filter: nil, limit: 50, cursor: nil, append: false, forceRefresh: true
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.projectName, "proj")
        XCTAssertEqual(result?.workspaceName, "ws")
        XCTAssertNil(result?.filter)
        XCTAssertEqual(result?.limit, 50)
        XCTAssertNil(result?.cursor)
        XCTAssertFalse(result!.append)
        XCTAssertTrue(result!.forceRefresh)
    }

    func testMakeAISessionListRequestSuccessPagination() {
        let ctx = SharedWorkspaceContext(projectName: "proj", workspaceName: "ws", globalKey: "proj:ws")
        let result = SharedWorkspaceStateDriver.makeAISessionListRequest(
            context: ctx, isConnectionReady: true, filter: "codex", limit: 20, cursor: "abc123", append: true, forceRefresh: false
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.filter, "codex")
        XCTAssertEqual(result?.cursor, "abc123")
        XCTAssertTrue(result!.append)
    }

    /// 同名 workspace 位于不同 project 时，请求描述不会串项目。
    func testAISessionListRequestIsolationAcrossProjects() {
        let ctxA = SharedWorkspaceContext(projectName: "proj-a", workspaceName: "default", globalKey: "proj-a:default")
        let ctxB = SharedWorkspaceContext(projectName: "proj-b", workspaceName: "default", globalKey: "proj-b:default")
        let reqA = SharedWorkspaceStateDriver.makeAISessionListRequest(
            context: ctxA, isConnectionReady: true, filter: nil, limit: 50, cursor: nil, append: false, forceRefresh: false
        )
        let reqB = SharedWorkspaceStateDriver.makeAISessionListRequest(
            context: ctxB, isConnectionReady: true, filter: nil, limit: 50, cursor: nil, append: false, forceRefresh: false
        )
        XCTAssertNotEqual(reqA?.projectName, reqB?.projectName)
        XCTAssertEqual(reqA?.workspaceName, reqB?.workspaceName) // 同名
    }

    // MARK: - Bootstrap 请求描述

    func testBootstrapRequestIsForceRefreshAllFilter() {
        let ctx = SharedWorkspaceContext(projectName: "proj", workspaceName: "ws", globalKey: "proj:ws")
        let result = SharedWorkspaceStateDriver.makeBootstrapAISessionListRequest(context: ctx, isConnectionReady: true)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.forceRefresh)
        XCTAssertNil(result?.filter)
        XCTAssertNil(result?.cursor)
        XCTAssertFalse(result!.append)
    }

    // MARK: - Evolution 计划文档请求描述

    func testMakeEvolutionPlanDocumentRequestSuccess() {
        let ctx = SharedWorkspaceContext(projectName: "proj", workspaceName: "default", globalKey: "proj:default")
        let result = SharedWorkspaceStateDriver.makeEvolutionPlanDocumentRequest(
            context: ctx, isConnectionReady: true, cycleID: "2025-01-01T00-00-00-000Z"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.path, ".tidyflow/evolution/2025-01-01T00-00-00-000Z/plan.md")
        XCTAssertEqual(result?.projectName, "proj")
        XCTAssertEqual(result?.workspaceName, "default")
    }

    func testMakeEvolutionPlanDocumentRequestReturnsNilWhenNotConnected() {
        let ctx = SharedWorkspaceContext(projectName: "proj", workspaceName: "ws", globalKey: "proj:ws")
        let result = SharedWorkspaceStateDriver.makeEvolutionPlanDocumentRequest(
            context: ctx, isConnectionReady: false, cycleID: "cycle-1"
        )
        XCTAssertNil(result)
    }

    func testMakeEvolutionPlanDocumentRequestReturnsNilWhenCycleIDEmpty() {
        let ctx = SharedWorkspaceContext(projectName: "proj", workspaceName: "ws", globalKey: "proj:ws")
        let result = SharedWorkspaceStateDriver.makeEvolutionPlanDocumentRequest(
            context: ctx, isConnectionReady: true, cycleID: ""
        )
        XCTAssertNil(result)
    }

    func testMakeEvolutionPlanDocumentRequestReturnsNilWhenContextNil() {
        let result = SharedWorkspaceStateDriver.makeEvolutionPlanDocumentRequest(
            context: nil, isConnectionReady: true, cycleID: "cycle-1"
        )
        XCTAssertNil(result)
    }

    /// 同名 workspace 位于不同 project 时，plan 文档请求描述不会串项目。
    func testPlanDocumentRequestIsolationAcrossProjects() {
        let ctxA = SharedWorkspaceContext(projectName: "proj-a", workspaceName: "default", globalKey: "proj-a:default")
        let ctxB = SharedWorkspaceContext(projectName: "proj-b", workspaceName: "default", globalKey: "proj-b:default")
        let reqA = SharedWorkspaceStateDriver.makeEvolutionPlanDocumentRequest(
            context: ctxA, isConnectionReady: true, cycleID: "cycle-1"
        )
        let reqB = SharedWorkspaceStateDriver.makeEvolutionPlanDocumentRequest(
            context: ctxB, isConnectionReady: true, cycleID: "cycle-1"
        )
        XCTAssertNotEqual(reqA?.projectName, reqB?.projectName)
        XCTAssertEqual(reqA?.path, reqB?.path) // 同 cycleID → 同路径
    }

    // MARK: - CoordinatorSnapshotApplier

    func testCoordinatorSnapshotApplierUsesCache() {
        let cache = CoordinatorStateCache()
        let payload = CoordinatorWorkspaceSnapshotPayload(
            project: "proj",
            workspace: "default",
            ai: AiDomainState(
                phase: .active,
                activeSessionCount: 1,
                totalSessionCount: 1,
                displayStatus: .running
            ),
            terminal: nil,
            file: nil,
            version: 1,
            generatedAt: "2025-01-01T00:00:00Z"
        )
        let result = CoordinatorSnapshotApplier.apply(payload: payload, cache: cache)
        XCTAssertTrue(result.changed)

        // 同一快照再次应用不应产生变化
        let result2 = CoordinatorSnapshotApplier.apply(payload: payload, cache: cache)
        XCTAssertFalse(result2.changed)
    }
}
