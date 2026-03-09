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
    func testEvolutionProjectionStoreSkipsDuplicatePublication() {
        let store = EvolutionPipelineProjectionStore()
        let sample = EvolutionPipelineProjection(
            project: "proj",
            workspace: "ws",
            workspaceReady: true,
            workspaceContextKey: "proj/ws",
            scheduler: EvolutionSchedulerInfoV2(
                activationState: "active",
                maxParallelWorkspaces: 2,
                runningCount: 1,
                queuedCount: 0
            ),
            control: EvolutionControlProjection(
                canStart: false,
                canStop: true,
                canResume: false,
                isStartPending: false,
                isStopPending: false,
                isResumePending: false
            ),
            currentItem: nil,
            blockingRequest: nil,
            cycleHistories: []
        )

        XCTAssertTrue(store.updateProjection(sample))
        XCTAssertFalse(store.updateProjection(sample))
        XCTAssertTrue(store.projection.control.canStop)
        XCTAssertEqual(store.projection.scheduler.runningCount, 1)
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

@MainActor
final class AIChatShellProjectionStoreTests: XCTestCase {
    func testAIChatShellProjectionTracksStreamingAndStopCapability() {
        let projection = AIChatShellProjectionSemantics.make(
            tool: .codex,
            currentSessionId: "session-1",
            messages: [
                AIChatMessage(
                    id: "m1",
                    messageId: "m1",
                    role: .assistant,
                    parts: [AIChatPart(id: "p1", kind: .text, text: "hello")]
                )
            ],
            recentHistoryIsLoading: false,
            historyHasMore: true,
            historyIsLoading: false,
            canSwitchTool: true,
            scrollSessionToken: 3,
            sessionStatus: AISessionStatusSnapshot(
                status: "running",
                errorMessage: nil,
                contextRemainingPercent: 0.42
            ),
            localIsStreaming: false,
            awaitingUserEcho: false,
            abortPendingSessionId: nil,
            hasPendingFirstContent: true
        )

        XCTAssertFalse(projection.presentation.showsEmptyState)
        XCTAssertTrue(projection.effectiveStreaming)
        XCTAssertTrue(projection.canStopStreaming)
        XCTAssertEqual(projection.contextRemainingPercent, 0.42)
        XCTAssertTrue(projection.isSendingPending)
    }

    func testAIChatShellProjectionStoreSkipsDuplicatePublication() {
        let store = AIChatShellProjectionStore()
        let sample = AIChatShellProjection.empty

        XCTAssertFalse(store.updateProjection(sample))
        XCTAssertTrue(store.updateProjection(
            AIChatShellProjection(
                presentation: AIChatPresentationProjection(
                    tool: .opencode,
                    currentSessionId: "session-2",
                    showsEmptyState: false,
                    canSwitchTool: true,
                    isLoadingMessages: false,
                    canLoadOlderMessages: true,
                    isLoadingOlderMessages: false,
                    messageListIdentity: "main-session-opencode-session-2-1"
                ),
                sessionStatus: nil,
                contextRemainingPercent: nil,
                effectiveStreaming: false,
                canStopStreaming: false,
                isSendingPending: false
            )
        ))
        XCTAssertFalse(store.updateProjection(store.projection))
    }
}

@MainActor
final class BottomPanelProjectionStoreTests: XCTestCase {
    func testBottomPanelProjectionStoreSkipsDuplicatePublication() {
        let store = BottomPanelProjectionStore()
        let tab = TabModel(
            id: UUID(),
            title: "Terminal",
            kind: .terminal,
            workspaceKey: "proj:default",
            payload: ""
        )
        let projection = BottomPanelProjection(
            workspaceKey: "proj:default",
            specialPage: nil,
            activeCategory: .terminal,
            displayedTabs: [tab],
            activeTab: tab
        )

        XCTAssertTrue(store.updateProjection(projection))
        XCTAssertFalse(store.updateProjection(projection))
    }
}

@MainActor
final class WorkspaceOverviewProjectionStoreTests: XCTestCase {
    func testWorkspaceOverviewProjectionStoreSkipsDuplicatePublication() {
        let store = WorkspaceOverviewProjectionStore()
        let projection = WorkspaceOverviewProjection(
            gitSnapshot: GitPanelSemanticSnapshot.empty(),
            hasActiveConflicts: true,
            terminals: [
                WorkspaceTerminalProjection(
                    id: "term-1",
                    termId: "term-1",
                    title: "终端 1",
                    shortId: "term-1",
                    iconName: "terminal",
                    isPinned: false,
                    aiStatus: .running(toolName: "Codex"),
                    hasTerminalsToRight: false
                )
            ],
            runningTasks: [
                WorkspaceRunningTaskProjection(
                    id: "task-1",
                    iconName: "hammer",
                    title: "构建",
                    message: "执行中",
                    canCancel: true
                )
            ],
            completedTaskCount: 2,
            pendingTodoCount: 3,
            projectCommands: []
        )

        XCTAssertTrue(store.updateProjection(projection))
        XCTAssertFalse(store.updateProjection(projection))
        XCTAssertTrue(store.projection.hasActiveConflicts)
        XCTAssertEqual(store.projection.pendingTodoCount, 3)
    }
}

@MainActor
final class EvidenceProjectionStoreTests: XCTestCase {
    func testEvidenceProjectionStoreSkipsDuplicatePublication() {
        let store = EvidenceProjectionStore()
        let projection = EvidenceProjection(
            project: "proj",
            workspace: "default",
            workspaceReady: true,
            workspaceContextKey: "proj/default",
            selectedTab: .screenshot,
            snapshotAvailable: true,
            snapshotLoading: false,
            snapshotError: nil,
            snapshotUpdatedAt: "2026-03-10T12:00:00Z",
            currentTabItemCount: 1,
            tabCounts: [
                EvidenceTabCountProjection(tab: .screenshot, count: 1),
                EvidenceTabCountProjection(tab: .log, count: 0)
            ],
            deviceSections: [
                EvidenceDeviceSectionProjection(
                    deviceType: "iPhone",
                    items: [makeEvidenceItemProjection(id: "shot-1", deviceType: "iPhone", evidenceType: "screenshot", mimeType: "image/png")]
                )
            ],
            allItemIDs: Set(["shot-1"]),
            screenshotItemIDs: Set(["shot-1"])
        )

        XCTAssertTrue(store.updateProjection(projection))
        XCTAssertFalse(store.updateProjection(projection))
        XCTAssertEqual(store.projection.currentTabItemCount, 1)
    }

    func testEvidenceProjectionSemanticsKeepsDeviceOrderAndTabCounts() {
        let snapshot = EvidenceSnapshotV2(
            project: "proj",
            workspace: "default",
            evidenceRoot: "/tmp/evidence",
            indexFile: "/tmp/evidence/index.json",
            indexExists: true,
            detectedSubsystems: [],
            detectedDeviceTypes: [],
            items: [
                makeEvidenceItem(id: "shot-1", deviceType: "iPad", evidenceType: "screenshot", mimeType: "image/png", order: 3),
                makeEvidenceItem(id: "log-1", deviceType: "Mac", evidenceType: "log", mimeType: "text/plain", order: 1),
                makeEvidenceItem(id: "shot-2", deviceType: "iPhone", evidenceType: "capture", mimeType: "image/jpeg", order: 2),
                makeEvidenceItem(id: "log-2", deviceType: "Mac", evidenceType: "log", mimeType: "text/plain", order: 4)
            ],
            issues: [],
            updatedAt: "2026-03-10T12:00:00Z"
        )

        let screenshotProjection = EvidenceProjectionSemantics.make(
            project: "proj",
            workspace: "default",
            selectedTab: .screenshot,
            snapshot: snapshot,
            snapshotLoading: false,
            snapshotError: nil
        )
        XCTAssertEqual(screenshotProjection.tabCount(for: .screenshot), 2)
        XCTAssertEqual(screenshotProjection.tabCount(for: .log), 2)
        XCTAssertEqual(screenshotProjection.deviceSections.map(\.deviceType), ["iPhone", "iPad"])
        XCTAssertEqual(screenshotProjection.currentTabItems.map(\.itemID), ["shot-2", "shot-1"])

        let logProjection = EvidenceProjectionSemantics.make(
            project: "proj",
            workspace: "default",
            selectedTab: .log,
            snapshot: snapshot,
            snapshotLoading: false,
            snapshotError: nil
        )
        XCTAssertEqual(logProjection.deviceSections.map(\.deviceType), ["Mac"])
        XCTAssertEqual(logProjection.currentTabItems.map(\.itemID), ["log-1", "log-2"])
        XCTAssertEqual(logProjection.screenshotItemIDs, Set(["shot-1", "shot-2"]))
    }

    private func makeEvidenceItemProjection(
        id: String,
        deviceType: String,
        evidenceType: String,
        mimeType: String,
        order: Int = 0
    ) -> EvidenceItemProjection {
        EvidenceItemProjection(
            makeEvidenceItem(
                id: id,
                deviceType: deviceType,
                evidenceType: evidenceType,
                mimeType: mimeType,
                order: order
            )
        )
    }

    private func makeEvidenceItem(
        id: String,
        deviceType: String,
        evidenceType: String,
        mimeType: String,
        order: Int
    ) -> EvidenceItemInfoV2 {
        EvidenceItemInfoV2(
            itemID: id,
            deviceType: deviceType,
            evidenceType: evidenceType,
            order: order,
            path: "/tmp/\(id)",
            title: id,
            description: "",
            scenario: nil,
            subsystem: nil,
            createdAt: nil,
            sizeBytes: 0,
            exists: true,
            mimeType: mimeType
        )
    }
}
