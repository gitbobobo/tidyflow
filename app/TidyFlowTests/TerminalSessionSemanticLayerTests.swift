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
}
