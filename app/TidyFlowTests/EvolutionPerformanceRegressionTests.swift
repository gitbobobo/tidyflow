import XCTest
@testable import TidyFlow
import TidyFlowShared

final class EvolutionPerformanceRegressionTests: XCTestCase {
    func testKnownStageChangeDoesNotFallbackToSnapshot() {
        let appState = AppState()
        defer {
            appState.wsClient.disconnect()
            appState.coreProcessManager.stop()
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

        let wait = expectation(description: "等待无回退请求")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            wait.fulfill()
        }
        wait(for: [wait], timeout: 1.0)

        XCTAssertTrue(scheduledRequests.isEmpty, "已知工作区阶段切换不应回退到全量 snapshot")
        XCTAssertEqual(
            appState.evolutionItem(project: "proj", workspace: "ws")?.currentStage,
            "implement.general.1"
        )
    }

    func testMissingWorkspaceStatusEventFallsBackToTargetedSnapshot() {
        let appState = AppState()
        defer {
            appState.wsClient.disconnect()
            appState.coreProcessManager.stop()
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

        let wait = expectation(description: "等待 targeted snapshot fallback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            wait.fulfill()
        }
        wait(for: [wait], timeout: 1.0)

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
}
