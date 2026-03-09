import XCTest
import Combine
@testable import TidyFlow
import TidyFlowShared

@MainActor
final class SidebarProjectionStoreTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testMacSidebarStoreSkipsDuplicatePublication() {
        let store = MacSidebarProjectionStore()
        var changeCount = 0
        store.objectWillChange
            .sink { changeCount += 1 }
            .store(in: &cancellables)

        let sample = [
            SidebarProjectProjection(
                id: "mac-project-1",
                projectID: UUID(),
                projectName: "proj",
                projectPath: "/tmp/proj",
                primaryWorkspaceName: "default",
                defaultWorkspaceName: "default",
                defaultWorkspacePath: "/tmp/proj",
                defaultGlobalWorkspaceKey: "proj:default",
                isSelectedDefaultWorkspace: true,
                shortcutDisplayText: "⌘1",
                terminalCount: 1,
                hasOpenTabs: true,
                isDeleting: false,
                hasUnseenCompletion: false,
                activityIndicators: [
                    SidebarActivityIndicatorProjection(id: "chat", iconName: "bubble.left.and.bubble.right.fill")
                ],
                visibleWorkspaces: [],
                isLoadingWorkspaces: false
            )
        ]

        XCTAssertTrue(store.updateProjects(sample))
        XCTAssertFalse(store.updateProjects(sample))
        XCTAssertEqual(changeCount, 1)
    }

    func testSidebarActivityIndicatorsKeepStablePriority() {
        let indicators = SidebarProjectionSemantics.activityIndicators(
            chatIconName: "bubble.left.and.bubble.right.fill",
            hasActiveEvolutionLoop: true,
            taskIconName: "hammer"
        )
        XCTAssertEqual(indicators.map(\.id), ["chat", "evolution", "task"])
    }
}

final class AIChatPresentationProjectionTests: XCTestCase {
    func testLoadingProjectionDisablesToolSwitchDuringRecentHistoryBootstrap() {
        let projection = AIChatPresentationSemantics.make(
            tool: .codex,
            currentSessionId: "session-1",
            messages: [],
            recentHistoryIsLoading: true,
            historyHasMore: true,
            historyIsLoading: false,
            canSwitchTool: true,
            scrollSessionToken: 2
        )

        XCTAssertTrue(projection.showsEmptyState)
        XCTAssertTrue(projection.isLoadingMessages)
        XCTAssertFalse(projection.canSwitchTool)
        XCTAssertTrue(projection.canLoadOlderMessages)
        XCTAssertEqual(projection.messageListIdentity, "main-session-codex-session-1-2")
    }

    func testProjectionTracksNonEmptyMessagesWithoutLoadingState() {
        let projection = AIChatPresentationSemantics.make(
            tool: .opencode,
            currentSessionId: "session-2",
            messages: [
                AIChatMessage(
                    id: "m1",
                    messageId: "m1",
                    role: .assistant,
                    parts: [AIChatPart(id: "p1", kind: .text, text: "hello")]
                )
            ],
            recentHistoryIsLoading: true,
            historyHasMore: false,
            historyIsLoading: false,
            canSwitchTool: true,
            scrollSessionToken: 4
        )

        XCTAssertFalse(projection.showsEmptyState)
        XCTAssertFalse(projection.isLoadingMessages)
        XCTAssertTrue(projection.canSwitchTool)
        XCTAssertFalse(projection.canLoadOlderMessages)
        XCTAssertEqual(projection.messageListIdentity, "main-session-opencode-session-2-4")
    }
}

@MainActor
final class EvolutionPipelineProjectionStoreTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testEvolutionProjectionStoreSkipsDuplicatePublication() {
        let store = EvolutionPipelineProjectionStore()
        var changeCount = 0
        store.objectWillChange
            .sink { changeCount += 1 }
            .store(in: &cancellables)

        let sample = EvolutionPipelineProjection(
            project: "proj",
            workspace: "ws",
            workspaceReady: true,
            workspaceContextKey: "proj/ws",
            currentItem: nil,
            cycleHistories: []
        )

        XCTAssertTrue(store.updateProjection(sample))
        XCTAssertFalse(store.updateProjection(sample))
        XCTAssertEqual(changeCount, 1)
    }
}

final class SwiftUIRenderDiagnosticsTests: XCTestCase {
    override func tearDown() {
        SwiftUIRenderDiagnostics.reset()
        SwiftUIRenderDiagnostics.setTrackingEnabledForTesting(nil)
        super.tearDown()
    }

    func testRenderDiagnosticsAccumulatePerKey() {
        SwiftUIRenderDiagnostics.setTrackingEnabledForTesting(true)

        XCTAssertEqual(
            SwiftUIRenderDiagnostics.recordRender(
                name: "ProjectsSidebar",
                metadata: ["workspace": "proj:default"]
            ),
            1
        )
        XCTAssertEqual(
            SwiftUIRenderDiagnostics.recordRender(
                name: "ProjectsSidebar",
                metadata: ["workspace": "proj:default"]
            ),
            2
        )
        XCTAssertEqual(
            SwiftUIRenderDiagnostics.renderCount(
                name: "ProjectsSidebar",
                metadata: ["workspace": "proj:default"]
            ),
            2
        )
    }
}
