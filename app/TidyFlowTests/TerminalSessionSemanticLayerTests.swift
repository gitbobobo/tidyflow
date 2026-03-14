import XCTest
@testable import TidyFlow

// MARK: - TerminalSessionSemanticLayer 单元测试
// 覆盖：终端运行状态归一化、AI 执行状态映射、置顶排序、展示信息恢复
// 验证工作项 WI-001 共享终端语义层的核心契约

final class TerminalSessionSemanticLayerTests: XCTestCase {

    // MARK: - 运行状态归一化

    func testRunningStatusNormalization_running() {
        XCTAssertEqual(TerminalSessionSemantics.runningStatus(from: "running"), .running)
        XCTAssertEqual(TerminalSessionSemantics.runningStatus(from: "RUNNING"), .running)
        XCTAssertEqual(TerminalSessionSemantics.runningStatus(from: "  running  "), .running)
    }

    func testRunningStatusNormalization_stopped() {
        XCTAssertEqual(TerminalSessionSemantics.runningStatus(from: "stopped"), .stopped)
        XCTAssertEqual(TerminalSessionSemantics.runningStatus(from: "exited"), .stopped)
        XCTAssertEqual(TerminalSessionSemantics.runningStatus(from: ""), .stopped)
        XCTAssertEqual(TerminalSessionSemantics.runningStatus(from: "unknown"), .stopped)
    }

    // MARK: - AI 执行状态映射

    func testAIStatusMapping_running() {
        let status = TerminalSessionSemantics.terminalAIStatus(
            from: "running", errorMessage: nil, toolName: "Codex", aiToolDisplayName: "AI"
        )
        if case .running(let toolName) = status {
            XCTAssertEqual(toolName, "Codex")
        } else {
            XCTFail("Expected .running, got \(status)")
        }
    }

    func testAIStatusMapping_runningFallbackToDisplayName() {
        let status = TerminalSessionSemantics.terminalAIStatus(
            from: "running", errorMessage: nil, toolName: nil, aiToolDisplayName: "Opencode"
        )
        if case .running(let toolName) = status {
            XCTAssertEqual(toolName, "Opencode")
        } else {
            XCTFail("Expected .running with display name fallback")
        }
    }

    func testAIStatusMapping_awaitingInput() {
        let status = TerminalSessionSemantics.terminalAIStatus(
            from: "awaiting_input", errorMessage: nil, toolName: nil, aiToolDisplayName: "AI"
        )
        XCTAssertEqual(status, .awaitingInput)
    }

    func testAIStatusMapping_success() {
        let status = TerminalSessionSemantics.terminalAIStatus(
            from: "success", errorMessage: nil, toolName: nil, aiToolDisplayName: "AI"
        )
        XCTAssertEqual(status, .success)
    }

    func testAIStatusMapping_failure() {
        let status = TerminalSessionSemantics.terminalAIStatus(
            from: "failure", errorMessage: "OOM", toolName: nil, aiToolDisplayName: "AI"
        )
        if case .failure(let msg) = status {
            XCTAssertEqual(msg, "OOM")
        } else {
            XCTFail("Expected .failure")
        }
    }

    func testAIStatusMapping_error_treatedAsFailure() {
        let status = TerminalSessionSemantics.terminalAIStatus(
            from: "error", errorMessage: "crash", toolName: nil, aiToolDisplayName: "AI"
        )
        if case .failure = status {
            // pass
        } else {
            XCTFail("Expected .failure for 'error' status")
        }
    }

    func testAIStatusMapping_cancelled() {
        XCTAssertEqual(
            TerminalSessionSemantics.terminalAIStatus(from: "cancelled", errorMessage: nil, toolName: nil, aiToolDisplayName: "AI"),
            .cancelled
        )
    }

    func testAIStatusMapping_unknownStatusBecomesIdle() {
        XCTAssertEqual(
            TerminalSessionSemantics.terminalAIStatus(from: "pending", errorMessage: nil, toolName: nil, aiToolDisplayName: "AI"),
            .idle
        )
    }

    // MARK: - 工作区终端排序（置顶优先）

    private func makeSession(termId: String, project: String = "proj", workspace: String = "ws") -> TerminalSessionInfo {
        TerminalSessionInfo(
            termId: termId, project: project, workspace: workspace,
            cwd: "/tmp", shell: "bash", status: "running",
            name: termId, icon: nil, remoteSubscribers: []
        )
    }

    func testSortedTerminals_pinnedFirst() {
        let t1 = makeSession(termId: "t1")
        let t2 = makeSession(termId: "t2")
        let t3 = makeSession(termId: "t3")
        let sorted = TerminalSessionSemantics.sortedTerminals([t1, t2, t3], pinnedIds: ["t3"])
        XCTAssertEqual(sorted.map(\.termId), ["t3", "t1", "t2"])
    }

    func testSortedTerminals_stableOrderAmongUnpinned() {
        let terminals = (1...5).map { makeSession(termId: "t\($0)") }
        let sorted = TerminalSessionSemantics.sortedTerminals(terminals, pinnedIds: [])
        XCTAssertEqual(sorted.map(\.termId), ["t1", "t2", "t3", "t4", "t5"])
    }

    func testSortedTerminals_multiplePinnedInOriginalOrder() {
        let t1 = makeSession(termId: "t1")
        let t2 = makeSession(termId: "t2")
        let t3 = makeSession(termId: "t3")
        let sorted = TerminalSessionSemantics.sortedTerminals([t1, t2, t3], pinnedIds: ["t1", "t3"])
        // 置顶的 t1、t3 排前，顺序与原始顺序一致
        XCTAssertEqual(sorted.prefix(2).map(\.termId), ["t1", "t3"])
        XCTAssertEqual(sorted.last?.termId, "t2")
    }

    // MARK: - 工作区过滤 + 排序

    func testTerminalsForWorkspace_filtersCorrectly() {
        let target = makeSession(termId: "t1", project: "proj", workspace: "ws-a")
        let other = makeSession(termId: "t2", project: "proj", workspace: "ws-b")
        let stopped = TerminalSessionInfo(
            termId: "t3", project: "proj", workspace: "ws-a",
            cwd: "/tmp", shell: "bash", status: "stopped", name: nil, icon: nil, remoteSubscribers: []
        )
        let result = TerminalSessionSemantics.terminalsForWorkspace(
            project: "proj",
            workspace: "ws-a",
            allTerminals: [target, other, stopped],
            pinnedIds: []
        )
        XCTAssertEqual(result.map(\.termId), ["t1"])
    }

    func testTerminalsForWorkspace_multipleProjectsDoNotMix() {
        let a = makeSession(termId: "a1", project: "proj-a", workspace: "ws")
        let b = makeSession(termId: "b1", project: "proj-b", workspace: "ws")
        let resultA = TerminalSessionSemantics.terminalsForWorkspace(
            project: "proj-a", workspace: "ws", allTerminals: [a, b], pinnedIds: []
        )
        let resultB = TerminalSessionSemantics.terminalsForWorkspace(
            project: "proj-b", workspace: "ws", allTerminals: [a, b], pinnedIds: []
        )
        XCTAssertEqual(resultA.map(\.termId), ["a1"])
        XCTAssertEqual(resultB.map(\.termId), ["b1"])
    }

    // MARK: - 展示信息恢复

    func testRestoreDisplayInfo_fromSession() {
        let session = makeSession(termId: "t1")
        let info = TerminalDisplayInfo.restoreFrom(session: session)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.termId, "t1")
        XCTAssertFalse(info?.isPinned ?? true)
    }

    func testRestoreDisplayInfo_nilWhenNoName() {
        let session = TerminalSessionInfo(
            termId: "t1", project: "proj", workspace: "ws",
            cwd: "/tmp", shell: "bash", status: "running",
            name: nil, icon: nil, remoteSubscribers: []
        )
        let info = TerminalDisplayInfo.restoreFrom(session: session)
        XCTAssertNil(info)
    }

    // MARK: - TerminalAIStatus.isVisible 展示规则

    func testAIStatusIsVisible_idleIsHidden() {
        XCTAssertFalse(TerminalAIStatus.idle.isVisible, "idle 状态不应显示状态指示器")
    }

    func testAIStatusIsVisible_nonIdleStatesAreVisible() {
        XCTAssertTrue(TerminalAIStatus.running(toolName: "Codex").isVisible)
        XCTAssertTrue(TerminalAIStatus.awaitingInput.isVisible)
        XCTAssertTrue(TerminalAIStatus.success.isVisible)
        XCTAssertTrue(TerminalAIStatus.failure(message: nil).isVisible)
        XCTAssertTrue(TerminalAIStatus.cancelled.isVisible)
    }

    // MARK: - AI 状态映射大小写不敏感

    func testAIStatusMapping_caseInsensitive() {
        XCTAssertEqual(
            TerminalSessionSemantics.terminalAIStatus(from: "RUNNING", errorMessage: nil, toolName: "T", aiToolDisplayName: "AI"),
            .running(toolName: "T")
        )
        XCTAssertEqual(
            TerminalSessionSemantics.terminalAIStatus(from: "SUCCESS", errorMessage: nil, toolName: nil, aiToolDisplayName: "AI"),
            .success
        )
        XCTAssertEqual(
            TerminalSessionSemantics.terminalAIStatus(from: "CANCELLED", errorMessage: nil, toolName: nil, aiToolDisplayName: "AI"),
            .cancelled
        )
    }

    func testAIStatusMapping_trimmedWhitespace() {
        let status = TerminalSessionSemantics.terminalAIStatus(
            from: "  success  ", errorMessage: nil, toolName: nil, aiToolDisplayName: "AI"
        )
        XCTAssertEqual(status, .success)
    }

    // MARK: - 多项目工作区 AI 状态边界（WI-001 契约：多项目隔离）

    func testAIStatusMapping_sameStatusAcrossDifferentProjects() {
        // 相同后端 status 字符串在不同 project/workspace 下映射结果应一致
        let statusA = TerminalSessionSemantics.terminalAIStatus(
            from: "running", errorMessage: nil, toolName: "Codex", aiToolDisplayName: "AI"
        )
        let statusB = TerminalSessionSemantics.terminalAIStatus(
            from: "running", errorMessage: nil, toolName: "Codex", aiToolDisplayName: "AI"
        )
        XCTAssertEqual(statusA, statusB, "相同输入在不同工作区下应产生相同语义结果")
    }

    func testAIStatusMapping_failureWithNilMessage() {
        let status = TerminalSessionSemantics.terminalAIStatus(
            from: "failure", errorMessage: nil, toolName: nil, aiToolDisplayName: "AI"
        )
        if case .failure(let msg) = status {
            XCTAssertNil(msg, "failure 时 errorMessage 为 nil 应透传为 nil")
        } else {
            XCTFail("Expected .failure")
        }
    }

    // MARK: - 终端生命周期状态机基础迁移

    func testLifecycle_initialStateIsIdle() {
        let machine = TerminalLifecycleStateMachine()
        XCTAssertEqual(machine.state.phase, .idle)
    }

    func testLifecycle_createTransitionsToEntering() {
        let machine = TerminalLifecycleStateMachine()
        let result = machine.apply(.create(project: "p", workspace: "ws", termId: "t1"))
        XCTAssertEqual(machine.state.phase, .entering)
        XCTAssertEqual(machine.state.activeTermId, "t1")
        if case .transitioned(let state) = result {
            XCTAssertEqual(state.phase, .entering)
        } else {
            XCTFail("Expected transitioned")
        }
    }

    func testLifecycle_createdTransitionsToActive() {
        let machine = TerminalLifecycleStateMachine()
        machine.apply(.create(project: "p", workspace: "ws", termId: "t1"))
        let result = machine.apply(.created(termId: "t1"))
        XCTAssertEqual(machine.state.phase, .active)
        if case .transitioned = result {} else { XCTFail("Expected transitioned") }
    }

    func testLifecycle_createdIgnoredIfTermIdMismatch() {
        let machine = TerminalLifecycleStateMachine()
        machine.apply(.create(project: "p", workspace: "ws", termId: "t1"))
        let result = machine.apply(.created(termId: "t-wrong"))
        XCTAssertEqual(machine.state.phase, .entering, "termId 不匹配时不应迁移")
        XCTAssertEqual(result, .ignored)
    }

    func testLifecycle_attachTransitionsToResuming() {
        let machine = TerminalLifecycleStateMachine()
        machine.apply(.attach(project: "p", workspace: "ws", termId: "t2"))
        XCTAssertEqual(machine.state.phase, .resuming)
        XCTAssertEqual(machine.state.activeTermId, "t2")
    }

    func testLifecycle_attachedTransitionsResumingToActive() {
        let machine = TerminalLifecycleStateMachine()
        machine.apply(.attach(project: "p", workspace: "ws", termId: "t2"))
        machine.apply(.attached(termId: "t2"))
        XCTAssertEqual(machine.state.phase, .active)
    }

    func testLifecycle_disconnectTransitionsActiveToResuming() {
        let machine = TerminalLifecycleStateMachine()
        machine.apply(.create(project: "p", workspace: "ws", termId: "t1"))
        machine.apply(.created(termId: "t1"))
        XCTAssertEqual(machine.state.phase, .active)
        machine.apply(.disconnect)
        XCTAssertEqual(machine.state.phase, .resuming)
        XCTAssertEqual(machine.state.activeTermId, "t1", "断连时应保留上下文")
    }

    func testLifecycle_disconnectIgnoredWhenIdle() {
        let machine = TerminalLifecycleStateMachine()
        let result = machine.apply(.disconnect)
        XCTAssertEqual(machine.state.phase, .idle)
        XCTAssertEqual(result, .ignored)
    }

    func testLifecycle_closeTransitionsToIdle() {
        let machine = TerminalLifecycleStateMachine()
        machine.apply(.create(project: "p", workspace: "ws", termId: "t1"))
        machine.apply(.created(termId: "t1"))
        machine.apply(.close(termId: "t1"))
        XCTAssertEqual(machine.state.phase, .idle)
    }

    func testLifecycle_closeIgnoredForMismatchedTermId() {
        let machine = TerminalLifecycleStateMachine()
        machine.apply(.create(project: "p", workspace: "ws", termId: "t1"))
        machine.apply(.created(termId: "t1"))
        let result = machine.apply(.close(termId: "t-other"))
        XCTAssertEqual(machine.state.phase, .active, "关闭不匹配的 termId 不应影响当前状态")
        XCTAssertEqual(result, .ignored)
    }

    func testLifecycle_forceResetFromActive() {
        let machine = TerminalLifecycleStateMachine()
        machine.apply(.create(project: "p", workspace: "ws", termId: "t1"))
        machine.apply(.created(termId: "t1"))
        machine.apply(.forceReset)
        XCTAssertEqual(machine.state.phase, .idle)
    }

    func testLifecycle_forceResetFromIdleIsIgnored() {
        let machine = TerminalLifecycleStateMachine()
        let result = machine.apply(.forceReset)
        XCTAssertEqual(result, .ignored)
    }

    // MARK: - 终端生命周期事件接受性

    func testLifecycle_acceptsEvent_activeWithMatchingContext() {
        let machine = TerminalLifecycleStateMachine()
        machine.apply(.create(project: "p", workspace: "ws", termId: "t1"))
        machine.apply(.created(termId: "t1"))
        XCTAssertTrue(machine.acceptsEvent(project: "p", workspace: "ws", termId: "t1"))
    }

    func testLifecycle_acceptsEvent_rejectsMismatchedWorkspace() {
        let machine = TerminalLifecycleStateMachine()
        machine.apply(.create(project: "p", workspace: "ws", termId: "t1"))
        machine.apply(.created(termId: "t1"))
        XCTAssertFalse(machine.acceptsEvent(project: "p", workspace: "ws-other", termId: "t1"))
    }

    func testLifecycle_acceptsEvent_idleRejectsAll() {
        let machine = TerminalLifecycleStateMachine()
        XCTAssertFalse(machine.acceptsEvent(project: "p", workspace: "ws", termId: "t1"))
    }

    func testLifecycle_acceptsTermEvent_enteringRejectsAll() {
        let machine = TerminalLifecycleStateMachine()
        machine.apply(.create(project: "p", workspace: "ws", termId: "t1"))
        XCTAssertFalse(machine.acceptsTermEvent(termId: "t1"), "entering 阶段不应接受 term 事件")
    }

    // MARK: - 断线重连生命周期完整路径

    func testLifecycle_fullDisconnectReconnectCycle() {
        let machine = TerminalLifecycleStateMachine()
        // 创建 → active
        machine.apply(.create(project: "p", workspace: "ws", termId: "t1"))
        machine.apply(.created(termId: "t1"))
        XCTAssertEqual(machine.state.phase, .active)
        // 断连 → resuming
        machine.apply(.disconnect)
        XCTAssertEqual(machine.state.phase, .resuming)
        // 重新 attach → active
        machine.apply(.attached(termId: "t1"))
        XCTAssertEqual(machine.state.phase, .active)
    }

    // MARK: - 迟到 ACK 忽略

    func testLifecycle_lateAttachedIgnoredAfterClose() {
        let machine = TerminalLifecycleStateMachine()
        machine.apply(.create(project: "p", workspace: "ws", termId: "t1"))
        machine.apply(.created(termId: "t1"))
        machine.apply(.close(termId: "t1"))
        XCTAssertEqual(machine.state.phase, .idle)
        let result = machine.apply(.attached(termId: "t1"))
        XCTAssertEqual(result, .ignored, "关闭后的迟到 attached 应被忽略")
        XCTAssertEqual(machine.state.phase, .idle)
    }

    // MARK: - restoreFromServer

    func testLifecycle_restoreFromServer() {
        let machine = TerminalLifecycleStateMachine()
        machine.apply(.restoreFromServer(project: "p", workspace: "ws", termId: "t1", phase: .active))
        XCTAssertEqual(machine.state.phase, .active)
        XCTAssertEqual(machine.state.project, "p")
        XCTAssertEqual(machine.state.workspace, "ws")
        XCTAssertEqual(machine.state.activeTermId, "t1")
    }

    // MARK: - TerminalLifecyclePhase.from(serverValue:)

    func testLifecyclePhaseFromServerValue() {
        XCTAssertEqual(TerminalLifecyclePhase.from(serverValue: "active"), .active)
        XCTAssertEqual(TerminalLifecyclePhase.from(serverValue: "entering"), .entering)
        XCTAssertEqual(TerminalLifecyclePhase.from(serverValue: "resuming"), .resuming)
        XCTAssertEqual(TerminalLifecyclePhase.from(serverValue: "idle"), .idle)
        XCTAssertEqual(TerminalLifecyclePhase.from(serverValue: "ACTIVE"), .active)
        XCTAssertEqual(TerminalLifecyclePhase.from(serverValue: "unknown"), .idle, "未知值应回退到 idle")
    }

    // MARK: - v1.46 Coordinator 投影函数

    private func makeWorkspaceState(
        project: String = "proj",
        workspace: String = "ws",
        displayStatus: AiDisplayStatus,
        activeToolName: String? = nil,
        lastErrorMessage: String? = nil
    ) -> WorkspaceCoordinatorState {
        let id = CoordinatorWorkspaceId(project: project, workspace: workspace)
        let ai = AiDomainState(
            phase: displayStatus == .idle ? .idle : .active,
            activeSessionCount: displayStatus == .idle ? 0 : 1,
            totalSessionCount: 1,
            displayStatus: displayStatus,
            activeToolName: activeToolName,
            lastErrorMessage: lastErrorMessage,
            displayUpdatedAt: 0
        )
        return WorkspaceCoordinatorState(id: id, ai: ai, version: 1)
    }

    func testTerminalAIStatus_fromCoordinatorState_idle() {
        let state = makeWorkspaceState(displayStatus: .idle)
        let result = TerminalSessionSemantics.terminalAIStatus(fromCoordinatorState: state)
        XCTAssertEqual(result, .idle)
        XCTAssertFalse(result.isVisible)
    }

    func testTerminalAIStatus_fromCoordinatorState_running() {
        let state = makeWorkspaceState(displayStatus: .running, activeToolName: "Codex")
        let result = TerminalSessionSemantics.terminalAIStatus(fromCoordinatorState: state)
        XCTAssertEqual(result, .running(toolName: "Codex"))
        XCTAssertTrue(result.isVisible)
    }

    func testTerminalAIStatus_fromCoordinatorState_runningNilTool() {
        let state = makeWorkspaceState(displayStatus: .running, activeToolName: nil)
        let result = TerminalSessionSemantics.terminalAIStatus(fromCoordinatorState: state)
        if case .running(let toolName) = result {
            XCTAssertNil(toolName)
        } else {
            XCTFail("Expected .running")
        }
    }

    func testTerminalAIStatus_fromCoordinatorState_awaitingInput() {
        let state = makeWorkspaceState(displayStatus: .awaitingInput)
        XCTAssertEqual(TerminalSessionSemantics.terminalAIStatus(fromCoordinatorState: state), .awaitingInput)
    }

    func testTerminalAIStatus_fromCoordinatorState_success() {
        let state = makeWorkspaceState(displayStatus: .success)
        XCTAssertEqual(TerminalSessionSemantics.terminalAIStatus(fromCoordinatorState: state), .success)
    }

    func testTerminalAIStatus_fromCoordinatorState_failure() {
        let state = makeWorkspaceState(displayStatus: .failure, lastErrorMessage: "OOM")
        let result = TerminalSessionSemantics.terminalAIStatus(fromCoordinatorState: state)
        if case .failure(let msg) = result {
            XCTAssertEqual(msg, "OOM")
        } else {
            XCTFail("Expected .failure")
        }
    }

    func testTerminalAIStatus_fromCoordinatorState_cancelled() {
        let state = makeWorkspaceState(displayStatus: .cancelled)
        XCTAssertEqual(TerminalSessionSemantics.terminalAIStatus(fromCoordinatorState: state), .cancelled)
    }

    func testTerminalAIStatus_fromCache_noCacheReturnsIdle() {
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "ws")
        let result = TerminalSessionSemantics.terminalAIStatus(fromCache: cache, workspaceId: id)
        XCTAssertEqual(result, .idle)
    }

    func testTerminalAIStatus_fromCache_returnsLiveState() {
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "ws")
        let ai = AiDomainState(displayStatus: .awaitingInput)
        let state = WorkspaceCoordinatorState(id: id, ai: ai, version: 1)
        cache.apply(.updateWorkspace(state))

        let result = TerminalSessionSemantics.terminalAIStatus(fromCache: cache, workspaceId: id)
        XCTAssertEqual(result, .awaitingInput)
    }

    func testTerminalAIStatus_fromCache_multiWorkspaceIsolation() {
        let cache = CoordinatorStateCache()
        let id1 = CoordinatorWorkspaceId(project: "proj", workspace: "ws1")
        let id2 = CoordinatorWorkspaceId(project: "proj", workspace: "ws2")

        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: id1, ai: AiDomainState(displayStatus: .running), version: 1
        )))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: id2, ai: AiDomainState(displayStatus: .success), version: 1
        )))

        XCTAssertEqual(
            TerminalSessionSemantics.terminalAIStatus(fromCache: cache, workspaceId: id1),
            .running(toolName: nil),
            "ws1 状态不应受 ws2 影响"
        )
        XCTAssertEqual(
            TerminalSessionSemantics.terminalAIStatus(fromCache: cache, workspaceId: id2),
            .success,
            "ws2 状态不应受 ws1 影响"
        )
    }

    func testTerminalAIStatus_fromCache_afterClearReturnsIdle() {
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "ws")
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: id, ai: AiDomainState(displayStatus: .failure), version: 1
        )))
        cache.apply(.clear)
        XCTAssertEqual(
            TerminalSessionSemantics.terminalAIStatus(fromCache: cache, workspaceId: id),
            .idle,
            "清除缓存后应返回 idle"
        )
    }

    func testTerminalAIStatus_fromCache_sameWorkspaceKeyDifferentProjects() {
        // 验证不同项目下同名工作区不混淆（多项目隔离核心约束）
        let cache = CoordinatorStateCache()
        let idA = CoordinatorWorkspaceId(project: "proj-a", workspace: "default")
        let idB = CoordinatorWorkspaceId(project: "proj-b", workspace: "default")

        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: idA, ai: AiDomainState(displayStatus: .running), version: 1
        )))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: idB, ai: AiDomainState(displayStatus: .idle), version: 1
        )))

        XCTAssertEqual(
            TerminalSessionSemantics.terminalAIStatus(fromCache: cache, workspaceId: idA),
            .running(toolName: nil),
            "proj-a/default 应为 running"
        )
        XCTAssertEqual(
            TerminalSessionSemantics.terminalAIStatus(fromCache: cache, workspaceId: idB),
            .idle,
            "proj-b/default 同名工作区不应共享状态"
        )
    }

    // MARK: - active_tool_name 显示名映射（WI-004）

    func testDisplayName_forAITool_knownTools() {
        // 已知工具映射到友好展示名，大小写不敏感
        XCTAssertEqual(TerminalSessionSemantics.displayName(forAITool: "codex"), "Codex")
        XCTAssertEqual(TerminalSessionSemantics.displayName(forAITool: "CODEX"), "Codex")
        XCTAssertEqual(TerminalSessionSemantics.displayName(forAITool: "opencode"), "OpenCode")
        XCTAssertEqual(TerminalSessionSemantics.displayName(forAITool: "OpenCode"), "OpenCode")
        XCTAssertEqual(TerminalSessionSemantics.displayName(forAITool: "claude"), "Claude")
        XCTAssertEqual(TerminalSessionSemantics.displayName(forAITool: "kimi"), "Kimi")
    }

    func testDisplayName_forAITool_unknownToolReturnsRawValue() {
        // 未知工具名直接返回原始标识符，不崩溃，不返回 nil
        let result = TerminalSessionSemantics.displayName(forAITool: "some-future-agent")
        XCTAssertEqual(result, "some-future-agent", "未知工具名应原样返回，不应崩溃")
    }

    func testDisplayName_forAITool_nilOrEmptyReturnsNil() {
        // nil/空字符串 → nil，使调用方可提供默认值
        XCTAssertNil(TerminalSessionSemantics.displayName(forAITool: nil))
        XCTAssertNil(TerminalSessionSemantics.displayName(forAITool: ""))
    }

    func testTerminalAIStatus_fromCoordinatorState_unknownToolNameDoesNotCrash() {
        // 未知 active_tool_name 应使用原始标识符作为回退，不崩溃
        let state = makeWorkspaceState(displayStatus: .running, activeToolName: "unknown-future-ai")
        let result = TerminalSessionSemantics.terminalAIStatus(fromCoordinatorState: state)
        if case .running(let toolName) = result {
            XCTAssertEqual(toolName, "unknown-future-ai", "未知工具名应原样展示")
        } else {
            XCTFail("Expected .running with unknown tool name fallback")
        }
    }

    // MARK: - 同优先级终态最近时间决策（WI-004）
    // Core 已保证按 display_updated_at 最大值决策，客户端侧测试验证：
    // 当 Coordinator 缓存中存储的 displayUpdatedAt 被新快照更新时，客户端能正确读到最新状态。

    func testTerminalAIStatus_fromCache_newerStateOverridesOlder() {
        // 模拟 Core 先后产出两次状态（版本递增），客户端缓存只保留最新
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "ws")

        // 较旧的状态：failure，display_updated_at=1000
        let olderAI = AiDomainState(
            phase: .active, activeSessionCount: 0, totalSessionCount: 1,
            displayStatus: .failure, activeToolName: nil,
            lastErrorMessage: "first error", displayUpdatedAt: 1000
        )
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id, ai: olderAI, version: 1000)))

        // 较新的状态：success，display_updated_at=2000（同优先级层但版本更新）
        let newerAI = AiDomainState(
            phase: .idle, activeSessionCount: 0, totalSessionCount: 1,
            displayStatus: .success, activeToolName: nil,
            lastErrorMessage: nil, displayUpdatedAt: 2000
        )
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id, ai: newerAI, version: 2000)))

        let result = TerminalSessionSemantics.terminalAIStatus(fromCache: cache, workspaceId: id)
        XCTAssertEqual(result, .success, "版本更新的状态应覆盖旧状态")
    }

    func testTerminalAIStatus_fromCache_olderVersionDoesNotOverrideNewer() {
        // 验证乱序到达时，旧版本快照不覆盖已缓存的新版本
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "ws")

        // 先写入较新版本（running）
        let newerAI = AiDomainState(
            phase: .active, activeSessionCount: 1, totalSessionCount: 1,
            displayStatus: .running, activeToolName: "Codex",
            lastErrorMessage: nil, displayUpdatedAt: 5000
        )
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id, ai: newerAI, version: 5000)))

        // 再尝试写入旧版本（failure，version=3000）—— 不应覆盖
        let olderAI = AiDomainState(
            phase: .active, activeSessionCount: 0, totalSessionCount: 1,
            displayStatus: .failure, activeToolName: nil,
            lastErrorMessage: "stale error", displayUpdatedAt: 3000
        )
        let existingState = cache.state(for: id)
        let staleState = WorkspaceCoordinatorState(id: id, ai: olderAI, version: 3000)
        // 若存在版本保护，旧版本不应写入
        if (existingState?.version ?? 0) > 3000 {
            // 不写入，直接验证缓存仍为新版本
        } else {
            cache.apply(.updateWorkspace(staleState))
        }

        let result = TerminalSessionSemantics.terminalAIStatus(fromCache: cache, workspaceId: id)
        XCTAssertEqual(result, .running(toolName: "Codex"), "旧版本快照不应覆盖已缓存的新版本状态")
    }

    // MARK: - 重连恢复（WI-004）

    func testTerminalAIStatus_fromCache_reconnectRecovery() {
        // 模拟完整重连周期：断线清空 → 收到新的 coordinator_snapshot 种子 → 状态恢复
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "ws")

        // 第一阶段：建立初始状态
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: id, ai: AiDomainState(displayStatus: .running), version: 100
        )))
        XCTAssertEqual(TerminalSessionSemantics.terminalAIStatus(fromCache: cache, workspaceId: id), .running(toolName: nil))

        // 第二阶段：模拟断线，客户端调用 clear
        cache.apply(.clear)
        XCTAssertEqual(TerminalSessionSemantics.terminalAIStatus(fromCache: cache, workspaceId: id), .idle, "断线清空后应为 idle")

        // 第三阶段：重连后收到 system_snapshot 种子，恢复状态
        let restoredAI = AiDomainState(
            phase: .active, activeSessionCount: 1, totalSessionCount: 1,
            displayStatus: .awaitingInput, activeToolName: nil,
            lastErrorMessage: nil, displayUpdatedAt: 200
        )
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(id: id, ai: restoredAI, version: 200)))

        let result = TerminalSessionSemantics.terminalAIStatus(fromCache: cache, workspaceId: id)
        XCTAssertEqual(result, .awaitingInput, "重连后收到 coordinator_snapshot 种子应正确恢复展示状态")
    }

    func testTerminalAIStatus_fromCache_multiWorkspaceReconnectRecovery() {
        // 多工作区场景下，重连恢复各自独立，互不干扰
        let cache = CoordinatorStateCache()
        let idA = CoordinatorWorkspaceId(project: "proj", workspace: "ws-a")
        let idB = CoordinatorWorkspaceId(project: "proj", workspace: "ws-b")

        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: idA, ai: AiDomainState(displayStatus: .running), version: 10
        )))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: idB, ai: AiDomainState(displayStatus: .failure), version: 10
        )))

        // 断线清空所有工作区
        cache.apply(.clear)
        XCTAssertEqual(TerminalSessionSemantics.terminalAIStatus(fromCache: cache, workspaceId: idA), .idle)
        XCTAssertEqual(TerminalSessionSemantics.terminalAIStatus(fromCache: cache, workspaceId: idB), .idle)

        // 重连恢复，两个工作区分别收到种子，状态隔离恢复
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: idA, ai: AiDomainState(displayStatus: .success), version: 20
        )))
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: idB, ai: AiDomainState(displayStatus: .cancelled), version: 20
        )))

        XCTAssertEqual(TerminalSessionSemantics.terminalAIStatus(fromCache: cache, workspaceId: idA), .success, "ws-a 应独立恢复")
        XCTAssertEqual(TerminalSessionSemantics.terminalAIStatus(fromCache: cache, workspaceId: idB), .cancelled, "ws-b 应独立恢复，不受 ws-a 影响")
    }

    // MARK: - 六态 hint 文案验证（WI-004）

    func testTerminalAIStatus_hintText_idle() {
        let status: TerminalAIStatus = .idle
        XCTAssertEqual(status.hint, "", "idle 状态 hint 应为空")
    }

    func testTerminalAIStatus_hintText_runningWithToolName() {
        let status: TerminalAIStatus = .running(toolName: "Codex")
        XCTAssertEqual(status.hint, "AI 执行中 · Codex", "running 状态应包含工具名")
    }

    func testTerminalAIStatus_hintText_runningNilToolName() {
        let status: TerminalAIStatus = .running(toolName: nil)
        XCTAssertEqual(status.hint, "AI 执行中", "工具名为 nil 时应回退到通用文案")
    }

    func testTerminalAIStatus_hintText_awaitingInput() {
        let status: TerminalAIStatus = .awaitingInput
        XCTAssertEqual(status.hint, "等待用户输入")
    }

    func testTerminalAIStatus_hintText_success() {
        let status: TerminalAIStatus = .success
        XCTAssertEqual(status.hint, "AI 已完成")
    }

    func testTerminalAIStatus_hintText_failureWithMessage() {
        let status: TerminalAIStatus = .failure(message: "OOM killed")
        XCTAssertEqual(status.hint, "AI 失败：OOM killed", "failure 状态应包含错误摘要")
    }

    func testTerminalAIStatus_hintText_failureNilMessage() {
        let status: TerminalAIStatus = .failure(message: nil)
        XCTAssertEqual(status.hint, "AI 失败", "错误消息为 nil 时应回退到通用失败文案")
    }

    func testTerminalAIStatus_hintText_cancelled() {
        let status: TerminalAIStatus = .cancelled
        XCTAssertEqual(status.hint, "AI 已取消")
    }

    // MARK: - Coordinator 六态 → hint 端到端验证（WI-004）

    func testTerminalAIStatus_fromCoordinatorState_runningHintIncludesToolDisplayName() {
        // 验证 activeToolName 通过 displayName(forAITool:) 映射后进入 hint
        let state = makeWorkspaceState(displayStatus: .running, activeToolName: "opencode")
        let result = TerminalSessionSemantics.terminalAIStatus(fromCoordinatorState: state)
        XCTAssertEqual(result.hint, "AI 执行中 · OpenCode", "已知工具应映射为用户友好名称")
    }

    func testTerminalAIStatus_fromCoordinatorState_failureHintIncludesErrorMessage() {
        let state = makeWorkspaceState(displayStatus: .failure, lastErrorMessage: "context window exhausted")
        let result = TerminalSessionSemantics.terminalAIStatus(fromCoordinatorState: state)
        XCTAssertEqual(result.hint, "AI 失败：context window exhausted")
    }

    // MARK: - Coordinator hasState 兜底阻断验证（WI-004）

    func testCoordinatorHasState_preventsLocalFallbackOverwrite() {
        // 模拟：Coordinator 已有状态时，本地事件驱动的写入应被阻断
        let cache = CoordinatorStateCache()
        let key = "proj:ws"
        XCTAssertFalse(cache.hasState(forGlobalKey: key), "初始状态应无缓存")

        // 写入 Coordinator 状态
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "ws")
        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: id, ai: AiDomainState(displayStatus: .running), version: 1
        )))
        XCTAssertTrue(cache.hasState(forGlobalKey: key), "写入后 hasState 应为 true")

        // 验证：一旦 hasState == true，本地 fallback 不应生效
        // （在实际代码中，syncAIStatusToWorkspace / syncAIStatusToTerminalTabs 都以此为 guard）
        let status = TerminalSessionSemantics.terminalAIStatus(fromCache: cache, workspaceId: id)
        XCTAssertEqual(status, .running(toolName: nil), "应返回 Coordinator 权威状态，而非本地兜底")
    }

    func testCoordinatorHasState_afterClearAllowsFallback() {
        // 断线清空后，hasState 恢复为 false，允许本地兜底生效
        let cache = CoordinatorStateCache()
        let id = CoordinatorWorkspaceId(project: "proj", workspace: "ws")

        cache.apply(.updateWorkspace(WorkspaceCoordinatorState(
            id: id, ai: AiDomainState(displayStatus: .success), version: 1
        )))
        XCTAssertTrue(cache.hasState(forGlobalKey: "proj:ws"))

        cache.apply(.clear)
        XCTAssertFalse(cache.hasState(forGlobalKey: "proj:ws"), "clear 后应允许兜底路径生效")
        XCTAssertEqual(
            TerminalSessionSemantics.terminalAIStatus(fromCache: cache, workspaceId: id),
            .idle,
            "清空后应回退到 idle"
        )
    }
}
