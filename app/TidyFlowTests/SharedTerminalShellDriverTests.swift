import XCTest
@testable import TidyFlow

// MARK: - SharedTerminalShellDriver 单元测试
// 覆盖 create/attach/select/close/disconnect/reconcile 全部输入
// 以及多工作区隔离、回退选择逻辑

final class SharedTerminalShellDriverTests: XCTestCase {

    private let ctx = SharedTerminalShellContext(projectName: "proj", workspaceName: "ws")
    private let ctx2 = SharedTerminalShellContext(projectName: "proj", workspaceName: "ws2")

    // MARK: - 辅助

    private func reduce(
        _ state: SharedTerminalShellWorkspaceState = .empty,
        _ input: SharedTerminalShellInput,
        liveTermIds: [String] = []
    ) -> (SharedTerminalShellWorkspaceState, SharedTerminalShellEffect) {
        SharedTerminalShellDriver.reduce(
            state: state,
            input: input,
            context: ctx,
            liveTermIds: liveTermIds
        )
    }

    // MARK: - createTerminal

    func testCreateTerminal_setsConnectingPhaseAndPendingCreate() {
        let (next, effect) = reduce(.empty, .createTerminal(command: nil, icon: nil, name: nil))
        XCTAssertEqual(next.phase, .connecting)
        XCTAssertTrue(next.selection.isPendingCreate)
        if case .requestCreate(let project, let workspace, _, _, _) = effect {
            XCTAssertEqual(project, "proj")
            XCTAssertEqual(workspace, "ws")
        } else {
            XCTFail("期望 requestCreate 副作用")
        }
    }

    func testCreateTerminalWithCommand_passesCommandAndMetadata() {
        let (next, effect) = reduce(
            .empty,
            .createTerminal(command: "ls -la", icon: "folder", name: "List")
        )
        XCTAssertTrue(next.selection.isPendingCreate)
        if case .requestCreate(_, _, let cmd, let icon, let name) = effect {
            XCTAssertEqual(cmd, "ls -la")
            XCTAssertEqual(icon, "folder")
            XCTAssertEqual(name, "List")
        } else {
            XCTFail("期望 requestCreate 副作用")
        }
    }

    // MARK: - serverTermCreated

    func testServerTermCreated_bindsPendingToActive() {
        let (pending, _) = reduce(.empty, .createTerminal(command: nil, icon: nil, name: nil))
        let (next, effect) = reduce(pending, .serverTermCreated(termId: "t1"))
        if case .active(let termId) = next.selection {
            XCTAssertEqual(termId, "t1")
        } else {
            XCTFail("期望 active 选中")
        }
        XCTAssertEqual(next.lastSelectedTermId, "t1")
        // 创建后自动 attach
        if case .requestAttach(let termId) = effect {
            XCTAssertEqual(termId, "t1")
        } else {
            XCTFail("期望 requestAttach 副作用")
        }
    }

    func testServerTermCreated_ignoredWhenNotPending() {
        let state = SharedTerminalShellWorkspaceState(
            selection: .active(termId: "t0"),
            phase: .ready,
            lastSelectedTermId: "t0"
        )
        let (next, effect) = reduce(state, .serverTermCreated(termId: "t1"))
        // 不应修改已有 active 选中
        XCTAssertEqual(next.selection, .active(termId: "t0"))
        XCTAssertEqual(effect, .none)
    }

    // MARK: - attachTerminal

    func testAttachTerminal_setsActiveAndConnecting() {
        let (next, effect) = reduce(.empty, .attachTerminal(termId: "t1"))
        XCTAssertEqual(next.selection, .active(termId: "t1"))
        XCTAssertEqual(next.phase, .connecting)
        XCTAssertEqual(next.lastSelectedTermId, "t1")
        if case .requestAttach(let termId) = effect {
            XCTAssertEqual(termId, "t1")
        } else {
            XCTFail("期望 requestAttach 副作用")
        }
    }

    // MARK: - serverTermAttached

    func testServerTermAttached_transitionsToReady() {
        let state = SharedTerminalShellWorkspaceState(
            selection: .active(termId: "t1"),
            phase: .connecting
        )
        let (next, effect) = reduce(state, .serverTermAttached(termId: "t1"))
        XCTAssertEqual(next.phase, .ready)
        if case .focusTerminal(let termId) = effect {
            XCTAssertEqual(termId, "t1")
        } else {
            XCTFail("期望 focusTerminal 副作用")
        }
    }

    func testServerTermAttached_ignoredForDifferentTerminal() {
        let state = SharedTerminalShellWorkspaceState(
            selection: .active(termId: "t1"),
            phase: .connecting
        )
        let (next, effect) = reduce(state, .serverTermAttached(termId: "t2"))
        XCTAssertEqual(next.phase, .connecting)
        XCTAssertEqual(effect, .none)
    }

    // MARK: - selectTerminal

    func testSelectTerminal_switchesWithDetach() {
        let state = SharedTerminalShellWorkspaceState(
            selection: .active(termId: "t1"),
            phase: .ready,
            lastSelectedTermId: "t1"
        )
        let (next, effect) = reduce(state, .selectTerminal(termId: "t2"), liveTermIds: ["t1", "t2"])
        XCTAssertEqual(next.selection, .active(termId: "t2"))
        XCTAssertEqual(next.lastSelectedTermId, "t2")
        // 切换先 detach 旧终端
        if case .requestDetach(let termId) = effect {
            XCTAssertEqual(termId, "t1")
        } else {
            XCTFail("期望 requestDetach 副作用")
        }
    }

    func testSelectTerminal_sameIdNoop() {
        let state = SharedTerminalShellWorkspaceState(
            selection: .active(termId: "t1"),
            phase: .ready
        )
        let (next, effect) = reduce(state, .selectTerminal(termId: "t1"))
        XCTAssertEqual(next.selection, .active(termId: "t1"))
        XCTAssertEqual(effect, .none)
    }

    func testSelectTerminal_fromNone() {
        let (next, effect) = reduce(.empty, .selectTerminal(termId: "t1"))
        XCTAssertEqual(next.selection, .active(termId: "t1"))
        if case .requestAttach(let termId) = effect {
            XCTAssertEqual(termId, "t1")
        } else {
            XCTFail("期望 requestAttach 副作用")
        }
    }

    // MARK: - closeTerminal

    func testCloseTerminal_currentSelected_fallbackRight() {
        let state = SharedTerminalShellWorkspaceState(
            selection: .active(termId: "t2"),
            phase: .ready,
            lastSelectedTermId: "t2"
        )
        let (next, effect) = reduce(
            state,
            .closeTerminal(termId: "t2"),
            liveTermIds: ["t1", "t2", "t3"]
        )
        // 关闭 t2：回退到右侧 t3
        XCTAssertEqual(next.selection, .active(termId: "t3"))
        XCTAssertEqual(next.lastSelectedTermId, "t3")
        if case .requestClose(let termId) = effect {
            XCTAssertEqual(termId, "t2")
        } else {
            XCTFail("期望 requestClose 副作用")
        }
    }

    func testCloseTerminal_currentSelected_fallbackLeft() {
        let state = SharedTerminalShellWorkspaceState(
            selection: .active(termId: "t3"),
            phase: .ready
        )
        let (next, _) = reduce(
            state,
            .closeTerminal(termId: "t3"),
            liveTermIds: ["t1", "t2", "t3"]
        )
        // 关闭最后一个：回退到左侧 t2
        XCTAssertEqual(next.selection, .active(termId: "t2"))
    }

    func testCloseTerminal_lastTerminal_goesEmpty() {
        let state = SharedTerminalShellWorkspaceState(
            selection: .active(termId: "t1"),
            phase: .ready
        )
        let (next, _) = reduce(state, .closeTerminal(termId: "t1"), liveTermIds: ["t1"])
        XCTAssertEqual(next.selection, .none)
        XCTAssertEqual(next.phase, .idle)
    }

    func testCloseTerminal_notSelected_noSelectionChange() {
        let state = SharedTerminalShellWorkspaceState(
            selection: .active(termId: "t1"),
            phase: .ready
        )
        let (next, effect) = reduce(
            state,
            .closeTerminal(termId: "t2"),
            liveTermIds: ["t1", "t2"]
        )
        XCTAssertEqual(next.selection, .active(termId: "t1"))
        if case .requestClose(let termId) = effect {
            XCTAssertEqual(termId, "t2")
        } else {
            XCTFail("期望 requestClose 副作用")
        }
    }

    // MARK: - serverTermClosed

    func testServerTermClosed_currentSelected_fallback() {
        let state = SharedTerminalShellWorkspaceState(
            selection: .active(termId: "t2"),
            phase: .ready,
            lastSelectedTermId: "t2"
        )
        let (next, effect) = reduce(
            state,
            .serverTermClosed(termId: "t2"),
            liveTermIds: ["t1", "t2", "t3"]
        )
        XCTAssertEqual(next.selection, .active(termId: "t3"))
        if case .requestAttach(let termId) = effect {
            XCTAssertEqual(termId, "t3")
        } else {
            XCTFail("期望 requestAttach 副作用")
        }
    }

    func testServerTermClosed_lastTerminal_empty() {
        let state = SharedTerminalShellWorkspaceState(
            selection: .active(termId: "t1"),
            phase: .ready
        )
        let (next, effect) = reduce(state, .serverTermClosed(termId: "t1"), liveTermIds: ["t1"])
        XCTAssertEqual(next.selection, .none)
        XCTAssertEqual(next.phase, .idle)
        XCTAssertNil(next.lastSelectedTermId)
        XCTAssertEqual(effect, .none)
    }

    func testServerTermClosed_otherTerminal_noChange() {
        let state = SharedTerminalShellWorkspaceState(
            selection: .active(termId: "t1"),
            phase: .ready
        )
        let (next, effect) = reduce(state, .serverTermClosed(termId: "t2"), liveTermIds: ["t1", "t2"])
        XCTAssertEqual(next.selection, .active(termId: "t1"))
        XCTAssertEqual(effect, .none)
    }

    // MARK: - reconcileLiveTerminals

    func testReconcileLiveTerminals_removesStaleSelection() {
        let state = SharedTerminalShellWorkspaceState(
            selection: .active(termId: "t2"),
            phase: .ready,
            lastSelectedTermId: "t2"
        )
        let (next, effect) = reduce(
            state,
            .reconcileLiveTerminals(liveTermIds: ["t1", "t3"]),
            liveTermIds: ["t1", "t3"]
        )
        // t2 不在 live 列表：回退到第一个
        XCTAssertEqual(next.selection, .active(termId: "t1"))
        if case .requestAttach(let termId) = effect {
            XCTAssertEqual(termId, "t1")
        } else {
            XCTFail("期望 requestAttach 副作用")
        }
    }

    func testReconcileLiveTerminals_allGone_goesEmpty() {
        let state = SharedTerminalShellWorkspaceState(
            selection: .active(termId: "t1"),
            phase: .ready
        )
        let (next, effect) = reduce(state, .reconcileLiveTerminals(liveTermIds: []))
        XCTAssertEqual(next.selection, .none)
        XCTAssertEqual(next.phase, .idle)
        XCTAssertEqual(effect, .none)
    }

    func testReconcileLiveTerminals_selectionStillLive_noChange() {
        let state = SharedTerminalShellWorkspaceState(
            selection: .active(termId: "t1"),
            phase: .ready
        )
        let (next, effect) = reduce(state, .reconcileLiveTerminals(liveTermIds: ["t1", "t2"]))
        XCTAssertEqual(next.selection, .active(termId: "t1"))
        XCTAssertEqual(effect, .none)
    }

    func testReconcileLiveTerminals_pendingCreate_noop() {
        let (pending, _) = reduce(.empty, .createTerminal(command: nil, icon: nil, name: nil))
        let (next, effect) = reduce(pending, .reconcileLiveTerminals(liveTermIds: ["t1"]))
        // pending create 不应被 reconcile 影响
        XCTAssertTrue(next.selection.isPendingCreate)
        XCTAssertEqual(effect, .none)
    }

    // MARK: - disconnect

    func testDisconnect_keepsSelectionSetsConnecting() {
        let state = SharedTerminalShellWorkspaceState(
            selection: .active(termId: "t1"),
            phase: .ready,
            lastSelectedTermId: "t1"
        )
        let (next, effect) = reduce(state, .disconnect)
        XCTAssertEqual(next.selection, .active(termId: "t1"))
        XCTAssertEqual(next.phase, .connecting)
        XCTAssertEqual(effect, .none)
    }

    func testDisconnect_emptyState_noPhaseChange() {
        let (next, _) = reduce(.empty, .disconnect)
        XCTAssertEqual(next.phase, .idle)
    }

    // MARK: - clearError / setError

    func testSetError_setsPhaseAndMessage() {
        let (next, _) = reduce(.empty, .setError(message: "连接失败"))
        XCTAssertEqual(next.phase, .error)
        XCTAssertEqual(next.lastError, "连接失败")
    }

    func testClearError_recoversPhaseFromSelection() {
        let state = SharedTerminalShellWorkspaceState(
            selection: .active(termId: "t1"),
            phase: .error,
            lastError: "err"
        )
        let (next, _) = reduce(state, .clearError)
        XCTAssertEqual(next.phase, .ready)
        XCTAssertNil(next.lastError)
    }

    func testClearError_noSelection_goesIdle() {
        let state = SharedTerminalShellWorkspaceState(
            selection: .none,
            phase: .error,
            lastError: "err"
        )
        let (next, _) = reduce(state, .clearError)
        XCTAssertEqual(next.phase, .idle)
    }

    // MARK: - openWorkspaceShell

    func testOpenWorkspaceShell_withInitialTermId() {
        let (next, effect) = reduce(.empty, .openWorkspaceShell(initialTermId: "t1"), liveTermIds: ["t1", "t2"])
        XCTAssertEqual(next.selection, .active(termId: "t1"))
        XCTAssertEqual(next.phase, .connecting)
        if case .requestAttach(let termId) = effect {
            XCTAssertEqual(termId, "t1")
        } else {
            XCTFail("期望 requestAttach")
        }
    }

    func testOpenWorkspaceShell_noInitialButLastSelected() {
        let state = SharedTerminalShellWorkspaceState(
            selection: .none,
            phase: .idle,
            lastSelectedTermId: "t2"
        )
        let (next, effect) = reduce(state, .openWorkspaceShell(initialTermId: nil), liveTermIds: ["t1", "t2"])
        XCTAssertEqual(next.selection, .active(termId: "t2"))
        if case .requestAttach(let termId) = effect {
            XCTAssertEqual(termId, "t2")
        } else {
            XCTFail("期望 requestAttach")
        }
    }

    func testOpenWorkspaceShell_noLiveTerminals_createsNew() {
        let (next, effect) = reduce(.empty, .openWorkspaceShell(initialTermId: nil))
        XCTAssertTrue(next.selection.isPendingCreate)
        XCTAssertEqual(next.phase, .connecting)
        if case .requestCreate = effect {
            // OK
        } else {
            XCTFail("期望 requestCreate")
        }
    }

    // MARK: - 多工作区隔离

    func testMultiWorkspaceIsolation() {
        var shellState = SharedTerminalShellState()

        // 工作区 1 创建终端
        let (ws1Created, _) = SharedTerminalShellDriver.reduce(
            state: shellState.state(for: ctx.globalKey),
            input: .createTerminal(command: nil, icon: nil, name: nil),
            context: ctx,
            liveTermIds: []
        )
        shellState.workspaceStates[ctx.globalKey] = ws1Created

        // 工作区 2 创建终端
        let (ws2Created, _) = SharedTerminalShellDriver.reduce(
            state: shellState.state(for: ctx2.globalKey),
            input: .createTerminal(command: nil, icon: nil, name: nil),
            context: ctx2,
            liveTermIds: []
        )
        shellState.workspaceStates[ctx2.globalKey] = ws2Created

        // 两个工作区应独立
        XCTAssertTrue(shellState.state(for: ctx.globalKey).selection.isPendingCreate)
        XCTAssertTrue(shellState.state(for: ctx2.globalKey).selection.isPendingCreate)

        // 工作区 1 收到 term_created
        let (ws1Ready, _) = SharedTerminalShellDriver.reduce(
            state: shellState.state(for: ctx.globalKey),
            input: .serverTermCreated(termId: "t1"),
            context: ctx,
            liveTermIds: ["t1"]
        )
        shellState.workspaceStates[ctx.globalKey] = ws1Ready

        // 工作区 1 已绑定，工作区 2 仍 pending
        XCTAssertEqual(shellState.state(for: ctx.globalKey).selection, .active(termId: "t1"))
        XCTAssertTrue(shellState.state(for: ctx2.globalKey).selection.isPendingCreate)

        // 断连影响所有工作区
        for key in shellState.workspaceStates.keys {
            var ws = shellState.state(for: key)
            let (disconnected, _) = SharedTerminalShellDriver.reduce(
                state: ws,
                input: .disconnect,
                context: key == ctx.globalKey ? ctx : ctx2,
                liveTermIds: []
            )
            shellState.workspaceStates[key] = disconnected
        }

        // 工作区 1 保留 selection，进入 connecting
        XCTAssertEqual(shellState.state(for: ctx.globalKey).selection, .active(termId: "t1"))
        XCTAssertEqual(shellState.state(for: ctx.globalKey).phase, .connecting)
    }

    // MARK: - 回退选择逻辑

    func testSelectFallback_rightFirst() {
        let result = SharedTerminalShellDriver.selectFallback(
            closingTermId: "t2",
            liveTermIds: ["t1", "t2", "t3"]
        )
        XCTAssertEqual(result, "t3")
    }

    func testSelectFallback_leftWhenRightmost() {
        let result = SharedTerminalShellDriver.selectFallback(
            closingTermId: "t3",
            liveTermIds: ["t1", "t2", "t3"]
        )
        XCTAssertEqual(result, "t2")
    }

    func testSelectFallback_nilWhenOnly() {
        let result = SharedTerminalShellDriver.selectFallback(
            closingTermId: "t1",
            liveTermIds: ["t1"]
        )
        XCTAssertNil(result)
    }

    func testSelectFallback_notInList() {
        let result = SharedTerminalShellDriver.selectFallback(
            closingTermId: "t99",
            liveTermIds: ["t1", "t2"]
        )
        XCTAssertEqual(result, "t1")
    }
}
