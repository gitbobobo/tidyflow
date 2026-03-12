import XCTest
@testable import TidyFlow

@MainActor
final class AISelectorHTTPFailureHandlingTests: XCTestCase {
    func testProviderFailureClearsCurrentToolModelLoading() {
        let appState = AppState()
        defer {
            tearDownAppState(appState)
        }

        appState.selectedProjectName = "proj"
        appState.selectedWorkspaceKey = "ws"
        appState.aiChatTool = .codex
        appState.isAILoadingModels = true

        appState.handleHTTPReadFailure(
            WSClient.HTTPReadFailure(
                context: .aiProviderList(project: "proj", workspace: "ws", aiTool: .codex),
                message: "HTTP 500"
            )
        )

        XCTAssertFalse(appState.isAILoadingModels)
    }

    func testAgentFailureDoesNotClearDifferentToolLoading() {
        let appState = AppState()
        defer {
            tearDownAppState(appState)
        }

        appState.selectedProjectName = "proj"
        appState.selectedWorkspaceKey = "ws"
        appState.aiChatTool = .opencode
        appState.isAILoadingAgents = true

        appState.handleHTTPReadFailure(
            WSClient.HTTPReadFailure(
                context: .aiAgentList(project: "proj", workspace: "ws", aiTool: .codex),
                message: "HTTP 500"
            )
        )

        XCTAssertTrue(appState.isAILoadingAgents)
    }

    func testBootstrapProviderFailureConsumesOnlyProviderPendingFlag() {
        let appState = AppState()
        defer {
            tearDownAppState(appState)
        }

        appState.selectedProjectName = "other"
        appState.selectedWorkspaceKey = "other-ws"
        appState.aiSelectorBootstrapContextByTool[.codex] = (
            project: "proj",
            workspace: "ws",
            providerPending: true,
            agentPending: true
        )

        appState.handleHTTPReadFailure(
            WSClient.HTTPReadFailure(
                context: .aiProviderList(project: "proj", workspace: "ws", aiTool: .codex),
                message: "HTTP 500"
            )
        )

        let pending = appState.aiSelectorBootstrapContextByTool[.codex]
        XCTAssertEqual(pending?.project, "proj")
        XCTAssertEqual(pending?.workspace, "ws")
        XCTAssertEqual(pending?.providerPending, false)
        XCTAssertEqual(pending?.agentPending, true)
    }
}
