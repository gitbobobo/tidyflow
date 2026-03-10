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
            cycleHistories: [],
            runningAgents: [],
            standbyAgents: [],
            totalDurationText: nil,
            isCurrentCycleFailed: false,
            currentCycleFailureSummary: nil,
            isCurrentCycleRetryable: false,
            predictionProjection: .empty
        )

        XCTAssertTrue(store.updateProjection(sample))
        XCTAssertFalse(store.updateProjection(sample))
        XCTAssertTrue(store.projection.control.canStop)
        XCTAssertEqual(store.projection.scheduler.runningCount, 1)
    }
}

final class EvolutionProfileOptionsProjectionStoreTests: XCTestCase {
    func testEvolutionProfileOptionsProjectionDeduplicatesModesAndEmptyProviders() {
        let projection = EvolutionProfileOptionsProjectionSemantics.make(
            contextKey: "settings",
            agentsByTool: { tool in
                guard tool == .codex else { return [] }
                return [
                    AIAgentInfo(
                        name: " planner ",
                        description: nil,
                        mode: nil,
                        color: nil,
                        defaultProviderID: "p-1",
                        defaultModelID: "m-1"
                    ),
                    AIAgentInfo(
                        name: "planner",
                        description: nil,
                        mode: nil,
                        color: nil,
                        defaultProviderID: "p-2",
                        defaultModelID: "m-2"
                    ),
                    AIAgentInfo(
                        name: " ",
                        description: nil,
                        mode: nil,
                        color: nil,
                        defaultProviderID: nil,
                        defaultModelID: nil
                    )
                ]
            },
            providersByTool: { tool in
                guard tool == .codex else { return [] }
                return [
                    AIProviderInfo(
                        id: "p-1",
                        name: "OpenAI",
                        models: [
                            AIModelInfo(
                                id: "m-1",
                                name: "GPT-5",
                                providerID: "p-1",
                                supportsImageInput: true
                            )
                        ]
                    ),
                    AIProviderInfo(id: "empty", name: "Empty", models: [])
                ]
            },
            thoughtLevelOptionIDByTool: { $0 == .codex ? "thought_level" : nil },
            thoughtLevelOptionsByTool: { $0 == .codex ? ["low", "medium", "high"] : [] }
        )

        let codex = projection.options(for: .codex)
        XCTAssertEqual(codex.modeOptions, ["planner"])
        XCTAssertEqual(codex.providers.map(\.id), ["p-1"])
        XCTAssertEqual(codex.providers.first?.models.map(\.modelID), ["m-1"])
        XCTAssertEqual(
            EvolutionProfileOptionsProjectionSemantics.defaultModelSelection(
                agentName: "Planner",
                options: codex
            ),
            EvolutionModelChoiceProjection(providerID: "p-1", modelID: "m-1")
        )
    }

    func testEvolutionProfileOptionsSelectionLabelsUseProjectionSemantics() {
        let options = EvolutionToolOptionsProjection(
            tool: .codex,
            agents: [],
            modeOptions: ["planner"],
            providers: [
                EvolutionProviderOptionProjection(
                    id: "p-1",
                    name: "OpenAI",
                    models: [
                        EvolutionModelOptionProjection(
                            AIModelInfo(
                                id: "m-1",
                                name: "GPT-5",
                                providerID: "p-1",
                                supportsImageInput: true
                            )
                        )
                    ]
                )
            ],
            thoughtLevelOptionID: "thought_level",
            thoughtLevelOptions: ["low", "medium", "high"]
        )

        XCTAssertEqual(
            EvolutionProfileOptionsProjectionSemantics.selectedModelDisplayName(
                providerID: "p-1",
                modelID: "m-1",
                options: options,
                defaultLabel: "默认"
            ),
            "GPT-5"
        )
        XCTAssertEqual(
            EvolutionProfileOptionsProjectionSemantics.selectedThoughtLevel(
                configOptions: ["thought_level": NSNumber(value: 2)],
                options: options
            ),
            "2"
        )
        XCTAssertEqual(
            EvolutionProfileOptionsProjectionSemantics.stageDisplayName("implement"),
            "Implement General"
        )
    }
}

@MainActor
final class GitWorkspaceProjectionStoreTests: XCTestCase {
    func testGitWorkspaceProjectionBuildsSharedListState() {
        let snapshot = GitPanelSemanticSnapshot(
            stagedItems: [
                GitStatusItem(id: "a.swift", path: "a.swift", status: "M", staged: true, renameFrom: nil, additions: 3, deletions: 1)
            ],
            trackedUnstagedItems: [
                GitStatusItem(id: "b.swift", path: "b.swift", status: "M", staged: false, renameFrom: nil, additions: 1, deletions: 0)
            ],
            untrackedItems: [
                GitStatusItem(id: "c.swift", path: "c.swift", status: "??", staged: false, renameFrom: nil, additions: nil, deletions: nil)
            ],
            isGitRepo: true,
            isLoading: false,
            currentBranch: "feature/refactor",
            defaultBranch: "main",
            aheadBy: 2,
            behindBy: 1
        )

        let projection = GitWorkspaceProjectionSemantics.make(
            workspaceKey: "proj:ws",
            snapshot: snapshot,
            isStageAllInFlight: true,
            hasResolvedStatus: true
        )

        XCTAssertEqual(projection.currentBranchDisplay, "feature/refactor")
        XCTAssertEqual(projection.stagedPaths, ["a.swift"])
        XCTAssertEqual(projection.unstagedCount, 2)
        XCTAssertTrue(projection.canDiscardAll)
        XCTAssertFalse(projection.canStageAll)
        XCTAssertEqual(projection.branchDivergenceText, "main vs default | +2 | -1")
    }

    func testGitWorkspaceProjectionStoreSkipsDuplicatePublication() {
        let store = GitWorkspaceProjectionStore()
        let sample = GitWorkspaceProjectionSemantics.make(
            workspaceKey: "proj:ws",
            snapshot: GitPanelSemanticSnapshot.empty(),
            isStageAllInFlight: false,
            hasResolvedStatus: false
        )

        XCTAssertTrue(store.updateProjection(sample))
        XCTAssertFalse(store.updateProjection(sample))
        XCTAssertEqual(store.projection.workspaceKey, "proj:ws")
    }

    func testGitWorkspaceProjectionMarksResolvedEmptyRefresh() {
        let projection = GitWorkspaceProjectionSemantics.make(
            workspaceKey: "proj:ws",
            snapshot: GitPanelSemanticSnapshot(
                stagedItems: [],
                trackedUnstagedItems: [],
                untrackedItems: [],
                isGitRepo: true,
                isLoading: true,
                currentBranch: "main",
                defaultBranch: "main",
                aheadBy: 0,
                behindBy: 0
            ),
            isStageAllInFlight: false,
            hasResolvedStatus: true
        )

        XCTAssertTrue(projection.isLoading)
        XCTAssertTrue(projection.isEmpty)
        XCTAssertTrue(projection.hasResolvedStatus, "已解析过的干净工作区在刷新时不应再回退为首次 loading")
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
            hasPendingFirstContent: true,
            pendingQuestions: [:]
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
                    messageListIdentity: "main-session-opencode-session-2-1",
                    shouldReplaceComposer: false
                ),
                sessionStatus: nil,
                contextRemainingPercent: nil,
                effectiveStreaming: false,
                canStopStreaming: false,
                isSendingPending: false,
                activePendingInteraction: nil,
                queuedPendingInteractionCount: 0
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
final class WorkspaceTaskTodoProjectionStoreTests: XCTestCase {
    func testWorkspaceTaskProjectionSemanticsKeepSectionOrder() {
        let now = Date(timeIntervalSince1970: 1_730_000_000)
        let tasks = [
            makeTask(id: "running", status: .running, createdAt: now.addingTimeInterval(-30), message: "执行中"),
            makeTask(id: "failed", status: .failed, createdAt: now.addingTimeInterval(-20), completedAt: now.addingTimeInterval(-5), message: "失败"),
            makeTask(id: "completed", status: .completed, createdAt: now.addingTimeInterval(-10), completedAt: now, message: "完成"),
            makeTask(id: "cancelled", status: .cancelled, createdAt: now.addingTimeInterval(-5), completedAt: now.addingTimeInterval(-1), message: "取消")
        ]

        let projection = WorkspaceTaskListProjectionSemantics.make(
            workspaceKey: "proj:default",
            tasks: tasks,
            canCancel: { $0.id == "running" }
        )

        XCTAssertEqual(projection.sections.map(\.id), ["进行中", "失败", "已完成", "已取消"])
        XCTAssertEqual(projection.sections.first?.items.first?.id, "running")
        XCTAssertTrue(projection.sections.first?.items.first?.canCancel == true)
        XCTAssertEqual(projection.terminalTaskCount, 3)
    }

    func testWorkspaceTodoProjectionSemanticsKeepStatusBuckets() {
        let items = [
            makeTodo(id: "pending-1", title: "待办 1", status: .pending, order: 0),
            makeTodo(id: "progress-1", title: "进行中", status: .inProgress, order: 0),
            makeTodo(id: "done-1", title: "已完成", status: .completed, order: 0)
        ]

        let projection = WorkspaceTodoProjectionSemantics.make(
            workspaceKey: "proj:default",
            items: items
        )

        XCTAssertEqual(projection.pendingCount, 2)
        XCTAssertEqual(projection.sections.map(\.status), [.pending, .inProgress, .completed])
        XCTAssertEqual(projection.sections.flatMap(\.items).map(\.id), ["pending-1", "progress-1", "done-1"])
    }

    func testWorkspaceTaskProjectionStoreSkipsDuplicatePublication() {
        let store = WorkspaceTaskListProjectionStore()
        let projection = WorkspaceTaskListProjection(
            workspaceKey: "proj:default",
            hasWorkspace: true,
            terminalTaskCount: 1,
            sections: [
                WorkspaceTaskSectionProjection(
                    id: "进行中",
                    title: "进行中",
                    items: [
                        WorkspaceTaskRowProjection(
                            makeTask(id: "running", status: .running, createdAt: Date(), message: "执行中"),
                            canCancel: true
                        )
                    ]
                )
            ]
        )

        XCTAssertTrue(store.updateProjection(projection))
        XCTAssertFalse(store.updateProjection(projection))
    }

    func testWorkspaceTodoProjectionStoreSkipsDuplicatePublication() {
        let store = WorkspaceTodoProjectionStore()
        let projection = WorkspaceTodoProjection(
            workspaceKey: "proj:default",
            workspaceReady: true,
            totalCount: 1,
            pendingCount: 1,
            sections: [
                WorkspaceTodoSectionProjection(
                    id: WorkspaceTodoStatus.pending.rawValue,
                    title: WorkspaceTodoStatus.pending.localizedTitle,
                    status: .pending,
                    items: [
                        WorkspaceTodoRowProjection(
                            makeTodo(id: "todo-1", title: "待办", status: .pending, order: 0)
                        )
                    ]
                )
            ]
        )

        XCTAssertTrue(store.updateProjection(projection))
        XCTAssertFalse(store.updateProjection(projection))
    }

    private func makeTask(
        id: String,
        status: WorkspaceTaskStatus,
        createdAt: Date,
        completedAt: Date? = nil,
        message: String
    ) -> WorkspaceTaskItem {
        WorkspaceTaskItem(
            id: id,
            project: "proj",
            workspace: "default",
            workspaceGlobalKey: "proj:default",
            type: .projectCommand,
            title: id,
            iconName: "hammer",
            status: status,
            message: message,
            createdAt: createdAt,
            startedAt: createdAt,
            completedAt: completedAt,
            lastOutputLine: "line",
            isCancellable: status.isActive
        )
    }

    private func makeTodo(
        id: String,
        title: String,
        status: WorkspaceTodoStatus,
        order: Int64
    ) -> WorkspaceTodoItem {
        WorkspaceTodoItem(
            id: id,
            title: title,
            note: "说明",
            status: status,
            order: order,
            createdAtMs: 1,
            updatedAtMs: 1
        )
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
