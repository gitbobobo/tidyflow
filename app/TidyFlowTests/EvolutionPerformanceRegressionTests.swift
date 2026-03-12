import XCTest
@testable import TidyFlow
import TidyFlowShared

final class EvolutionPerformanceRegressionTests: XCTestCase {
    func testKnownStageChangeDoesNotFallbackToSnapshot() {
        let appState = AppState()
        defer {
            tearDownAppState(appState)
        }

        appState.selectedProjectName = "proj"
        appState.selectedWorkspaceKey = "ws"

        var scheduledRequests: [(String, String, [URLQueryItem])] = []
        appState.wsClient.currentURL = URL(string: "ws://127.0.0.1:8439/ws")
        appState.wsClient.onHTTPRequestScheduled = { domain, path, queryItems in
            scheduledRequests.append((domain, path, queryItems))
        }

        let existing = makeItem(
            project: "proj",
            workspace: "ws",
            cycleID: "cycle-1",
            status: "running",
            currentStage: "plan",
            globalLoopRound: 1
        )
        appState.replaceEvolutionWorkspaceItems([existing])

        appState.handleEvolutionWorkspaceStatusEvent(
            EvolutionWorkspaceStatusEventV2(
                kind: .stageChanged,
                project: "proj",
                workspace: "ws",
                cycleID: "cycle-1",
                status: nil,
                currentStage: "implement.general.1",
                verifyIteration: 0,
                reason: nil,
                source: "system"
            )
        )

        let exp = expectation(description: "等待无回退请求")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(scheduledRequests.isEmpty, "已知工作区阶段切换不应回退到全量 snapshot")
        XCTAssertEqual(
            appState.evolutionItem(project: "proj", workspace: "ws")?.currentStage,
            "implement.general.1"
        )
    }

    func testMissingWorkspaceStatusEventFallsBackToTargetedSnapshot() {
        let appState = AppState()
        defer {
            tearDownAppState(appState)
        }

        appState.selectedProjectName = "proj"
        appState.selectedWorkspaceKey = "ws"
        appState.wsClient.currentURL = URL(string: "ws://127.0.0.1:8439/ws")

        var scheduledRequests: [(String, String, [URLQueryItem])] = []
        appState.wsClient.onHTTPRequestScheduled = { domain, path, queryItems in
            scheduledRequests.append((domain, path, queryItems))
        }

        appState.handleEvolutionWorkspaceStatusEvent(
            EvolutionWorkspaceStatusEventV2(
                kind: .stageChanged,
                project: "proj",
                workspace: "ws",
                cycleID: "cycle-1",
                status: nil,
                currentStage: "plan",
                verifyIteration: 0,
                reason: nil,
                source: "system"
            )
        )

        let exp = expectation(description: "等待 targeted snapshot fallback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(scheduledRequests.count, 1)
        XCTAssertEqual(scheduledRequests[0].0, "evolution")
        XCTAssertEqual(scheduledRequests[0].1, "/api/v1/evolution/snapshot")
        XCTAssertTrue(
            scheduledRequests[0].2.contains(URLQueryItem(name: "project", value: "proj"))
        )
        XCTAssertTrue(
            scheduledRequests[0].2.contains(URLQueryItem(name: "workspace", value: "ws"))
        )
    }

    func testBackgroundCycleUpdateAppliesWithoutCrashingOrFallback() {
        let appState = AppState()
        defer {
            tearDownAppState(appState)
        }

        appState.selectedProjectName = "proj"
        appState.selectedWorkspaceKey = "ws"

        var scheduledRequests: [(String, String, [URLQueryItem])] = []
        appState.wsClient.currentURL = URL(string: "ws://127.0.0.1:8439/ws")
        appState.wsClient.onHTTPRequestScheduled = { domain, path, queryItems in
            scheduledRequests.append((domain, path, queryItems))
        }

        let existing = makeItem(
            project: "proj",
            workspace: "ws",
            cycleID: "cycle-1",
            status: "running",
            currentStage: "plan",
            globalLoopRound: 1
        )
        appState.replaceEvolutionWorkspaceItems([existing])

        DispatchQueue.global(qos: .userInitiated).async {
            appState.handleEvolutionCycleUpdated(
                EvoCycleUpdatedV2(
                    project: "proj",
                    workspace: "ws",
                    cycleID: "cycle-1",
                    title: "Cycle",
                    status: "running",
                    currentStage: "implement.general.1",
                    globalLoopRound: 2,
                    loopRoundLimit: 3,
                    verifyIteration: 0,
                    verifyIterationLimit: 3,
                    agents: [],
                    executions: [],
                    terminalReasonCode: nil,
                    terminalErrorMessage: nil,
                    rateLimitErrorMessage: nil
                )
            )
        }

        waitForEvolutionAsyncWork()

        XCTAssertTrue(scheduledRequests.isEmpty, "命中已有工作区时不应触发 snapshot fallback")
        XCTAssertEqual(
            appState.evolutionItem(project: "proj", workspace: "ws")?.currentStage,
            "implement.general.1"
        )
        XCTAssertEqual(
            appState.evolutionItem(project: "proj", workspace: "ws")?.globalLoopRound,
            2
        )
    }

    func testMissingCycleUpdateFallsBackToTargetedSnapshotFromBackground() {
        let appState = AppState()
        defer {
            tearDownAppState(appState)
        }

        appState.selectedProjectName = "proj"
        appState.selectedWorkspaceKey = "ws"
        appState.wsClient.currentURL = URL(string: "ws://127.0.0.1:8439/ws")

        var scheduledRequests: [(String, String, [URLQueryItem])] = []
        appState.wsClient.onHTTPRequestScheduled = { domain, path, queryItems in
            scheduledRequests.append((domain, path, queryItems))
        }

        DispatchQueue.global(qos: .userInitiated).async {
            appState.handleEvolutionCycleUpdated(
                EvoCycleUpdatedV2(
                    project: "proj",
                    workspace: "ws",
                    cycleID: "cycle-1",
                    title: "Cycle",
                    status: "running",
                    currentStage: "plan",
                    globalLoopRound: 1,
                    loopRoundLimit: 3,
                    verifyIteration: 0,
                    verifyIterationLimit: 3,
                    agents: [],
                    executions: [],
                    terminalReasonCode: nil,
                    terminalErrorMessage: nil,
                    rateLimitErrorMessage: nil
                )
            )
        }

        waitForEvolutionAsyncWork()

        XCTAssertEqual(scheduledRequests.count, 1)
        XCTAssertEqual(scheduledRequests[0].0, "evolution")
        XCTAssertEqual(scheduledRequests[0].1, "/api/v1/evolution/snapshot")
        XCTAssertTrue(
            scheduledRequests[0].2.contains(URLQueryItem(name: "project", value: "proj"))
        )
        XCTAssertTrue(
            scheduledRequests[0].2.contains(URLQueryItem(name: "workspace", value: "ws"))
        )
    }

    func testCycleUpdateAndSnapshotKeepProjectionConsistent() {
        let appState = AppState()
        defer {
            tearDownAppState(appState)
        }

        let existing = makeItem(
            project: "proj",
            workspace: "ws",
            cycleID: "cycle-1",
            status: "running",
            currentStage: "plan",
            globalLoopRound: 1
        )
        appState.replaceEvolutionWorkspaceItems([existing])

        DispatchQueue.global(qos: .userInitiated).async {
            appState.handleEvolutionCycleUpdated(
                EvoCycleUpdatedV2(
                    project: "proj",
                    workspace: "ws",
                    cycleID: "cycle-1",
                    title: "Cycle",
                    status: "running",
                    currentStage: "implement.general.1",
                    globalLoopRound: 2,
                    loopRoundLimit: 3,
                    verifyIteration: 0,
                    verifyIterationLimit: 3,
                    agents: [],
                    executions: [],
                    terminalReasonCode: nil,
                    terminalErrorMessage: nil,
                    rateLimitErrorMessage: nil
                )
            )
        }

        DispatchQueue.global(qos: .userInitiated).async {
            appState.handleEvolutionSnapshot(
                EvolutionSnapshotV2(
                    scheduler: .empty,
                    workspaceItems: [
                        self.makeItem(
                            project: "proj",
                            workspace: "ws",
                            cycleID: "cycle-1",
                            status: "running",
                            currentStage: "verify.1",
                            globalLoopRound: 2
                        ),
                        self.makeItem(
                            project: "proj",
                            workspace: "ws-2",
                            cycleID: "cycle-2",
                            status: "queued",
                            currentStage: "plan",
                            globalLoopRound: 1
                        )
                    ]
                )
            )
        }

        waitForEvolutionAsyncWork()

        XCTAssertEqual(appState.evolutionWorkspaceItems.count, 2)
        XCTAssertEqual(appState.evolutionWorkspaceItemIndexByKey.count, 2)
        for item in appState.evolutionWorkspaceItems {
            let indexed = appState.evolutionWorkspaceItemIndexByKey[item.workspaceKey]
            XCTAssertEqual(indexed?.projectionSignature, item.projectionSignature)
        }
    }

    private func makeItem(
        project: String,
        workspace: String,
        cycleID: String,
        status: String,
        currentStage: String,
        globalLoopRound: Int
    ) -> EvolutionWorkspaceItemV2 {
        EvolutionWorkspaceItemV2(
            project: project,
            workspace: workspace,
            cycleID: cycleID,
            title: "Cycle",
            status: status,
            currentStage: currentStage,
            globalLoopRound: globalLoopRound,
            loopRoundLimit: 3,
            verifyIteration: 0,
            verifyIterationLimit: 3,
            agents: [],
            executions: [],
            terminalReasonCode: nil,
            terminalErrorMessage: nil,
            rateLimitErrorMessage: nil
        )
    }

    func testAnalysisProjectionDoesNotTriggerSnapshotFallback() {
        let appState = AppState()
        defer {
            tearDownAppState(appState)
        }

        appState.selectedProjectName = "proj"
        appState.selectedWorkspaceKey = "ws"
        appState.wsClient.currentURL = URL(string: "ws://127.0.0.1:8439/ws")

        var scheduledRequests: [(String, String, [URLQueryItem])] = []
        appState.wsClient.onHTTPRequestScheduled = { domain, path, queryItems in
            scheduledRequests.append((domain, path, queryItems))
        }

        let existing = makeItem(
            project: "proj",
            workspace: "ws",
            cycleID: "cycle-1",
            status: "running",
            currentStage: "verify.1",
            globalLoopRound: 2
        )
        appState.replaceEvolutionWorkspaceItems([existing])

        // 模拟收到带分析数据的 cycle update
        appState.handleEvolutionCycleUpdated(
            EvoCycleUpdatedV2(
                project: "proj",
                workspace: "ws",
                cycleID: "cycle-1",
                title: "Cycle",
                status: "running",
                currentStage: "verify.1",
                globalLoopRound: 2,
                loopRoundLimit: 3,
                verifyIteration: 1,
                verifyIterationLimit: 5,
                agents: [],
                executions: [],
                terminalReasonCode: nil,
                terminalErrorMessage: nil,
                rateLimitErrorMessage: nil
            )
        )

        let exp = expectation(description: "等待无回退请求")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(scheduledRequests.isEmpty, "分析投影更新不应触发 snapshot fallback")
    }

    func testSystemEvolutionSummariesSeedWorkspaceItems() {
        let appState = AppState()
        defer {
            tearDownAppState(appState)
        }

        appState.handleSystemEvolutionWorkspaceSummaries([
            SystemSnapshotEvolutionWorkspaceSummary(
                project: "proj",
                workspace: "ws",
                status: "running",
                cycleID: "cycle-1",
                title: "Cycle",
                failureReason: nil
            ),
            SystemSnapshotEvolutionWorkspaceSummary(
                project: "proj",
                workspace: "ws-2",
                status: "failed",
                cycleID: "cycle-2",
                title: "Cycle 2",
                failureReason: "boom"
            )
        ])

        waitForEvolutionAsyncWork()

        XCTAssertEqual(appState.evolutionWorkspaceItems.count, 2)
        XCTAssertEqual(appState.evolutionItem(project: "proj", workspace: "ws")?.cycleID, "cycle-1")
        XCTAssertEqual(appState.evolutionItem(project: "proj", workspace: "ws")?.agents.count, 0)
        XCTAssertEqual(
            appState.evolutionItem(project: "proj", workspace: "ws-2")?.terminalErrorMessage,
            "boom"
        )
    }

    func testSystemEvolutionSummariesPreserveDetailForSameCycle() {
        let appState = AppState()
        defer {
            tearDownAppState(appState)
        }

        let detailed = EvolutionWorkspaceItemV2(
            project: "proj",
            workspace: "ws",
            cycleID: "cycle-1",
            title: "Old",
            status: "running",
            currentStage: "implement.general.1",
            globalLoopRound: 2,
            loopRoundLimit: 3,
            verifyIteration: 1,
            verifyIterationLimit: 5,
            agents: [
                EvolutionAgentInfoV2(
                    stage: "implement.general.1",
                    agent: "ImplementAgent",
                    status: "running",
                    toolCallCount: 3,
                    startedAt: "2026-03-11T00:00:00Z",
                    durationMs: nil
                )
            ],
            executions: [
                EvolutionSessionExecutionEntryV2(
                    stage: "implement.general.1",
                    agent: "ImplementAgent",
                    aiTool: "codex",
                    sessionID: "sess-1",
                    status: "running",
                    startedAt: "2026-03-11T00:00:00Z",
                    completedAt: nil,
                    durationMs: nil,
                    toolCallCount: 3
                )
            ],
            terminalReasonCode: nil,
            terminalErrorMessage: nil,
            rateLimitErrorMessage: nil
        )
        appState.replaceEvolutionWorkspaceItems([detailed])

        appState.handleSystemEvolutionWorkspaceSummaries([
            SystemSnapshotEvolutionWorkspaceSummary(
                project: "proj",
                workspace: "ws",
                status: "running",
                cycleID: "cycle-1",
                title: "Cycle",
                failureReason: nil
            )
        ])

        waitForEvolutionAsyncWork()

        let updated = appState.evolutionItem(project: "proj", workspace: "ws")
        XCTAssertEqual(updated?.title, "Cycle")
        XCTAssertEqual(updated?.currentStage, "implement.general.1")
        XCTAssertEqual(updated?.agents.count, 1)
        XCTAssertEqual(updated?.executions.count, 1)
    }

    private func waitForEvolutionAsyncWork() {
        let exp = expectation(description: "等待 Evolution 异步更新完成")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
}
