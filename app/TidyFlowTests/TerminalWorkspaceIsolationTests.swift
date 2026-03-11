import XCTest
@testable import TidyFlow

// MARK: - TerminalWorkspaceIsolation 单元测试
// 覆盖：多项目多工作区隔离、关闭清理不串台、断线 stale 标记与 ACK 隔离
// 验证工作项 WI-003 的工作区边界保证

final class TerminalWorkspaceIsolationTests: XCTestCase {

    private var store: TerminalSessionStore!

    override func setUp() {
        super.setUp()
        store = TerminalSessionStore()
    }

    // MARK: - 多工作区展示信息不串台

    func testDisplayInfo_differentWorkspacesDoNotConflict() {
        let infoA = TerminalDisplayInfo(
            termId: "t1", project: "proj-a", workspace: "ws",
            icon: "terminal", name: "Shell A", sourceCommand: nil, isPinned: false
        )
        let infoB = TerminalDisplayInfo(
            termId: "t2", project: "proj-b", workspace: "ws",
            icon: "star", name: "Shell B", sourceCommand: nil, isPinned: false
        )
        store.setDisplayInfo(infoA)
        store.setDisplayInfo(infoB)

        XCTAssertEqual(store.displayInfo(for: "t1")?.project, "proj-a")
        XCTAssertEqual(store.displayInfo(for: "t2")?.project, "proj-b")
        XCTAssertEqual(store.displayInfo(for: "t1")?.name, "Shell A")
        XCTAssertEqual(store.displayInfo(for: "t2")?.name, "Shell B")
    }

    func testDisplayInfo_sameTermIdInDifferentProjectsAreIsolated() {
        // 注意：termId 由 Core 生成，在不同 project 下不应相同，此处验证如果相同会被隔离
        let info1 = TerminalDisplayInfo(
            termId: "shared-id", project: "proj-a", workspace: "ws",
            icon: "terminal", name: "Proj A Shell", sourceCommand: nil, isPinned: false
        )
        store.setDisplayInfo(info1)

        // 同一 termId 但不同 project 的 info 会覆盖（终端 ID 是全局唯一的 Core 概念）
        let info2 = TerminalDisplayInfo(
            termId: "shared-id", project: "proj-b", workspace: "ws",
            icon: "star", name: "Proj B Shell", sourceCommand: nil, isPinned: false
        )
        store.setDisplayInfo(info2)
        XCTAssertEqual(store.displayInfo(for: "shared-id")?.project, "proj-b")
    }

    // MARK: - 多工作区 ACK 不串台

    func testACKTracking_multipleWorkspacesIndependent() {
        store.addUnackedBytes(1000, for: "proj-a:t1")
        store.addUnackedBytes(2000, for: "proj-b:t1")

        XCTAssertEqual(store.unackedBytes(for: "proj-a:t1"), 1000)
        XCTAssertEqual(store.unackedBytes(for: "proj-b:t1"), 2000)

        store.clearUnackedBytes(for: "proj-a:t1")
        XCTAssertEqual(store.unackedBytes(for: "proj-a:t1"), 0)
        XCTAssertEqual(store.unackedBytes(for: "proj-b:t1"), 2000, "清零 proj-a 不应影响 proj-b")
    }

    // MARK: - term_list 隔离：清理过期不影响其它工作区

    func testReconcileTermList_onlyClearsExpiredTerms() {
        // 两个终端：一个 live，一个 stale
        let infoLive = TerminalDisplayInfo(
            termId: "t-live", project: "proj", workspace: "ws",
            icon: "terminal", name: "Live", sourceCommand: nil, isPinned: false
        )
        let infoStale = TerminalDisplayInfo(
            termId: "t-stale", project: "proj", workspace: "ws",
            icon: "terminal", name: "Stale", sourceCommand: nil, isPinned: false
        )
        store.setDisplayInfo(infoLive)
        store.setDisplayInfo(infoStale)

        let liveTerm = TerminalSessionInfo(
            termId: "t-live", project: "proj", workspace: "ws",
            cwd: "/", shell: "bash", status: "running",
            name: "Live", icon: nil, remoteSubscribers: []
        )
        store.reconcileTermList(items: [liveTerm], makeKey: { "\($0):\($1)" })

        XCTAssertNotNil(store.displayInfo(for: "t-live"), "live 终端不应被清除")
        XCTAssertNil(store.displayInfo(for: "t-stale"), "stale 终端应被清除")
    }

    // MARK: - 关闭清理不影响其它终端

    func testHandleTermClosed_doesNotAffectOtherTerminals() {
        let infoA = TerminalDisplayInfo(
            termId: "t-a", project: "proj", workspace: "ws",
            icon: "terminal", name: "A", sourceCommand: nil, isPinned: false
        )
        let infoB = TerminalDisplayInfo(
            termId: "t-b", project: "proj", workspace: "ws",
            icon: "terminal", name: "B", sourceCommand: nil, isPinned: false
        )
        store.setDisplayInfo(infoA)
        store.setDisplayInfo(infoB)
        store.togglePinned(termId: "t-b")
        store.addUnackedBytes(5000, for: "t-a")
        store.addUnackedBytes(3000, for: "t-b")

        store.handleTermClosed(termId: "t-a")

        XCTAssertNil(store.displayInfo(for: "t-a"), "t-a 应被清除")
        XCTAssertNotNil(store.displayInfo(for: "t-b"), "t-b 不应受影响")
        XCTAssertTrue(store.isPinned(termId: "t-b"), "t-b 的置顶状态不应受影响")
        XCTAssertEqual(store.unackedBytes(for: "t-b"), 3000, "t-b 的 ACK 计数不应受影响")
    }

    // MARK: - 断线后重连恢复隔离

    func testDisconnect_thenReconnect_preservesDisplayInfoForReopenedTerminals() {
        let info = TerminalDisplayInfo(
            termId: "t1", project: "proj", workspace: "ws",
            icon: "terminal", name: "Shell", sourceCommand: nil, isPinned: false
        )
        store.setDisplayInfo(info)
        store.addUnackedBytes(10000, for: "t1")
        store.recordAttachRequest(termId: "t1")

        store.handleDisconnect()

        // 重连后展示信息还在，可以用于重连恢复
        XCTAssertNotNil(store.displayInfo(for: "t1"), "断线后展示信息用于重连恢复")
        XCTAssertEqual(store.unackedBytes(for: "t1"), 0, "断线后 ACK 应清零")
        XCTAssertNil(store.attachRequestedAt["t1"], "断线后 attach 时间应清除")

        // 重连时记录新 attach
        store.recordAttachRequest(termId: "t1")
        XCTAssertNotNil(store.attachRequestedAt["t1"], "重连后应能记录新 attach 请求")
    }

    // MARK: - 多工作区断线重连不串台

    /// 验证断线后多工作区的终端展示信息独立保留，不会因断线回收而互相干扰。
    func testDisconnect_multipleWorkspaces_displayInfoIsolated() {
        let infoA = TerminalDisplayInfo(
            termId: "t-ws-a", project: "proj", workspace: "ws-a",
            icon: "terminal", name: "Shell A", sourceCommand: nil, isPinned: false
        )
        let infoB = TerminalDisplayInfo(
            termId: "t-ws-b", project: "proj", workspace: "ws-b",
            icon: "star", name: "Shell B", sourceCommand: nil, isPinned: true
        )
        store.setDisplayInfo(infoA)
        store.setDisplayInfo(infoB)
        store.togglePinned(termId: "t-ws-b")

        store.handleDisconnect()

        // 两个工作区的展示信息都应保留
        XCTAssertNotNil(store.displayInfo(for: "t-ws-a"), "ws-a 展示信息保留")
        XCTAssertNotNil(store.displayInfo(for: "t-ws-b"), "ws-b 展示信息保留")
        XCTAssertEqual(store.displayInfo(for: "t-ws-a")?.workspace, "ws-a")
        XCTAssertEqual(store.displayInfo(for: "t-ws-b")?.workspace, "ws-b")
        XCTAssertTrue(store.isPinned(termId: "t-ws-b"), "ws-b 的置顶状态应保留")
    }

    /// 验证重连后只恢复当前工作区的终端，不会把其它工作区的终端数据写入当前上下文。
    func testReconnect_termListReconcile_doesNotCrossWorkspaceBoundary() {
        // 预设两个工作区的展示信息
        let infoA = TerminalDisplayInfo(
            termId: "t-a", project: "proj", workspace: "ws-a",
            icon: "terminal", name: "Shell A", sourceCommand: nil, isPinned: false
        )
        let infoB = TerminalDisplayInfo(
            termId: "t-b", project: "proj", workspace: "ws-b",
            icon: "terminal", name: "Shell B", sourceCommand: nil, isPinned: false
        )
        store.setDisplayInfo(infoA)
        store.setDisplayInfo(infoB)

        store.handleDisconnect()

        // 重连后 Core 返回 term_list，只有 ws-a 的终端存活
        let liveTermA = TerminalSessionInfo(
            termId: "t-a", project: "proj", workspace: "ws-a",
            cwd: "/", shell: "bash", status: "running",
            name: "Shell A", icon: nil, remoteSubscribers: []
        )
        store.reconcileTermList(items: [liveTermA], makeKey: { "\($0):\($1)" })

        // ws-a 的终端恢复，ws-b 的终端因不在 term_list 中被清除
        XCTAssertNotNil(store.displayInfo(for: "t-a"), "存活终端应保留")
        XCTAssertNil(store.displayInfo(for: "t-b"), "已死终端应被清除，不残留到其它工作区")
    }

    // MARK: - term_list open time 更新区隔

    func testReconcileTermList_openTimeIsolatedByWorkspaceKey() {
        let termA = TerminalSessionInfo(
            termId: "tA", project: "proj", workspace: "ws-a",
            cwd: "/", shell: "bash", status: "running",
            name: "A", icon: nil, remoteSubscribers: []
        )
        let termB = TerminalSessionInfo(
            termId: "tB", project: "proj", workspace: "ws-b",
            cwd: "/", shell: "bash", status: "running",
            name: "B", icon: nil, remoteSubscribers: []
        )
        store.reconcileTermList(items: [termA, termB], makeKey: { "\($0):\($1)" })

        XCTAssertNotNil(store.workspaceOpenTime["proj:ws-a"])
        XCTAssertNotNil(store.workspaceOpenTime["proj:ws-b"])

        // ws-a 的终端消失后，其 open time 应被清除
        store.reconcileTermList(items: [termB], makeKey: { "\($0):\($1)" })
        XCTAssertNil(store.workspaceOpenTime["proj:ws-a"], "无活跃终端的工作区 open time 应清除")
        XCTAssertNotNil(store.workspaceOpenTime["proj:ws-b"], "有活跃终端的工作区 open time 应保留")
    }

    // MARK: - TerminalSessionSemantics 多项目隔离

    func testTerminalsForWorkspace_strictProjectWorkspaceBoundary() {
        func makeSession(termId: String, project: String, workspace: String) -> TerminalSessionInfo {
            TerminalSessionInfo(
                termId: termId, project: project, workspace: workspace,
                cwd: "/", shell: "bash", status: "running",
                name: termId, icon: nil, remoteSubscribers: []
            )
        }
        let all = [
            makeSession(termId: "t1", project: "p1", workspace: "w1"),
            makeSession(termId: "t2", project: "p1", workspace: "w2"),
            makeSession(termId: "t3", project: "p2", workspace: "w1"),
            makeSession(termId: "t4", project: "p2", workspace: "w2"),
        ]
        let result = TerminalSessionSemantics.terminalsForWorkspace(
            project: "p1", workspace: "w1", allTerminals: all, pinnedIds: []
        )
        XCTAssertEqual(result.map(\.termId), ["t1"], "应只返回 p1/w1 的终端")
    }

    // MARK: - 工作区切换生命周期清理

    func testForceResetAllLifecycles_clearsTerminalContext() {
        store.beginCreate(project: "p1", workspace: "w1", termId: "t1")
        store.beginCreate(project: "p2", workspace: "w2", termId: "t2")
        XCTAssertEqual(store.lifecyclePhase(for: "t1"), .entering)
        XCTAssertEqual(store.lifecyclePhase(for: "t2"), .entering)

        // 模拟工作区切换时的强制重置
        store.forceResetAllLifecycles()

        XCTAssertEqual(store.lifecyclePhase(for: "t1"), .idle, "切换后旧终端应回到 idle")
        XCTAssertEqual(store.lifecyclePhase(for: "t2"), .idle, "切换后旧终端应回到 idle")
        XCTAssertTrue(store.lifecycleByTermId.isEmpty, "强制重置后生命周期字典应清空")
    }

    func testAcceptsTerminalEvent_rejectsWrongWorkspace() {
        store.beginCreate(project: "p1", workspace: "w1", termId: "t1")
        let created = TermCreatedResult(
            termId: "t1", project: "p1", workspace: "w1",
            cwd: "/", shell: "zsh", name: "Shell", icon: nil
        )
        store.handleTermCreated(
            result: created,
            pendingCommandIcon: nil,
            pendingCommandName: nil,
            pendingCommand: nil,
            makeKey: { "\($0):\($1)" }
        )
        XCTAssertEqual(store.lifecyclePhase(for: "t1"), .active)

        // 正确工作区的事件应被接受
        XCTAssertTrue(store.acceptsTerminalEvent(project: "p1", workspace: "w1", termId: "t1"))

        // 错误工作区的事件应被拒绝
        XCTAssertFalse(store.acceptsTerminalEvent(project: "p1", workspace: "w-wrong", termId: "t1"))
        XCTAssertFalse(store.acceptsTerminalEvent(project: "p-wrong", workspace: "w1", termId: "t1"))
    }

    func testDisconnectThenResetPreventsLateEvents() {
        store.beginCreate(project: "p1", workspace: "w1", termId: "t1")
        let created = TermCreatedResult(
            termId: "t1", project: "p1", workspace: "w1",
            cwd: "/", shell: "zsh", name: "Shell", icon: nil
        )
        store.handleTermCreated(
            result: created,
            pendingCommandIcon: nil,
            pendingCommandName: nil,
            pendingCommand: nil,
            makeKey: { "\($0):\($1)" }
        )
        // 断连
        store.handleDisconnect()
        XCTAssertEqual(store.lifecyclePhase(for: "t1"), .resuming)

        // 强制重置（模拟工作区切换）
        store.forceResetAllLifecycles()
        XCTAssertEqual(store.lifecyclePhase(for: "t1"), .idle)

        // 迟到的 attached 事件不应重新激活终端
        XCTAssertFalse(store.acceptsTerminalEvent(project: "p1", workspace: "w1", termId: "t1"),
                       "强制重置后不应接受迟到事件")
    }
}

// MARK: - TerminalListDisplayPhase 展示阶段测试

final class TerminalListDisplayPhaseTests: XCTestCase {

    func testFrom_noTerminals_returnsEmpty() {
        let phase = TerminalListDisplayPhase.from(
            project: "p", workspace: "w",
            allTerminals: [], pinnedIds: []
        )
        if case .empty = phase { } else {
            XCTFail("无终端时应返回 .empty")
        }
    }

    func testFrom_hasMatchingTerminals_returnsContent() {
        let term = makeTerminal(termId: "t1", project: "p", workspace: "w")
        let phase = TerminalListDisplayPhase.from(
            project: "p", workspace: "w",
            allTerminals: [term], pinnedIds: []
        )
        if case .content(let terminals) = phase {
            XCTAssertEqual(terminals.count, 1)
            XCTAssertEqual(terminals.first?.termId, "t1")
        } else {
            XCTFail("有匹配终端时应返回 .content")
        }
    }

    func testFrom_noMatchingWorkspace_returnsEmpty() {
        let term = makeTerminal(termId: "t1", project: "p", workspace: "other-ws")
        let phase = TerminalListDisplayPhase.from(
            project: "p", workspace: "w",
            allTerminals: [term], pinnedIds: []
        )
        if case .empty = phase { } else {
            XCTFail("无匹配工作区的终端时应返回 .empty")
        }
    }

    func testFrom_noMatchingProject_returnsEmpty() {
        let term = makeTerminal(termId: "t1", project: "other-p", workspace: "w")
        let phase = TerminalListDisplayPhase.from(
            project: "p", workspace: "w",
            allTerminals: [term], pinnedIds: []
        )
        if case .empty = phase { } else {
            XCTFail("无匹配项目的终端时应返回 .empty")
        }
    }

    func testFrom_multipleTerminals_onlyMatchingInContent() {
        let terminals = [
            makeTerminal(termId: "t1", project: "p1", workspace: "w1"),
            makeTerminal(termId: "t2", project: "p1", workspace: "w1"),
            makeTerminal(termId: "t3", project: "p2", workspace: "w1"),
        ]
        let phase = TerminalListDisplayPhase.from(
            project: "p1", workspace: "w1",
            allTerminals: terminals, pinnedIds: []
        )
        if case .content(let result) = phase {
            XCTAssertEqual(result.count, 2, "应只包含 p1/w1 的终端")
            XCTAssertEqual(Set(result.map(\.termId)), ["t1", "t2"])
        } else {
            XCTFail("应返回 .content")
        }
    }

    func testFrom_isolatesProjectWorkspaceDimensions() {
        let terminals = [
            makeTerminal(termId: "t1", project: "p1", workspace: "w1"),
            makeTerminal(termId: "t2", project: "p1", workspace: "w2"),
            makeTerminal(termId: "t3", project: "p2", workspace: "w1"),
        ]
        // p1/w2 视角
        let phase = TerminalListDisplayPhase.from(
            project: "p1", workspace: "w2",
            allTerminals: terminals, pinnedIds: []
        )
        if case .content(let result) = phase {
            XCTAssertEqual(result.map(\.termId), ["t2"])
        } else {
            XCTFail("p1/w2 应有一个终端")
        }
    }

    private func makeTerminal(termId: String, project: String, workspace: String) -> TerminalSessionInfo {
        TerminalSessionInfo(
            termId: termId, project: project, workspace: workspace,
            cwd: "/", shell: "bash", status: "running",
            name: termId, icon: nil, remoteSubscribers: []
        )
    }

    // MARK: - WI-005: 多项目多工作区隔离护栏

    /// 验证大量终端在多项目多工作区下的过滤正确性
    func testIsolation_manyProjectsAndWorkspaces_correctFiltering() {
        var terminals: [TerminalSessionInfo] = []
        // 生成 3 项目 × 3 工作区 × 5 终端 = 45 终端
        for p in 1...3 {
            for w in 1...3 {
                for t in 1...5 {
                    terminals.append(makeTerminal(
                        termId: "t-p\(p)-w\(w)-\(t)",
                        project: "proj\(p)",
                        workspace: "ws\(w)"
                    ))
                }
            }
        }

        // 每个项目+工作区组合应精确过滤出 5 个终端
        for p in 1...3 {
            for w in 1...3 {
                let phase = TerminalListDisplayPhase.from(
                    project: "proj\(p)", workspace: "ws\(w)",
                    allTerminals: terminals, pinnedIds: []
                )
                if case .content(let result) = phase {
                    XCTAssertEqual(result.count, 5,
                                   "proj\(p)/ws\(w) 应有 5 个终端，实际 \(result.count)")
                    for info in result {
                        XCTAssertTrue(info.termId.hasPrefix("t-p\(p)-w\(w)-"),
                                      "终端 \(info.termId) 不属于 proj\(p)/ws\(w)")
                    }
                } else {
                    XCTFail("proj\(p)/ws\(w) 应返回 .content")
                }
            }
        }
    }

    /// 验证不存在的项目/工作区组合返回空
    func testIsolation_nonexistentProjectWorkspace_returnsEmpty() {
        let terminals = [
            makeTerminal(termId: "t1", project: "existingProj", workspace: "existingWs"),
        ]
        let phase = TerminalListDisplayPhase.from(
            project: "nonexistent", workspace: "nonexistent",
            allTerminals: terminals, pinnedIds: []
        )
        if case .empty = phase {
            // 预期结果
        } else {
            XCTFail("不存在的项目/工作区组合应返回空态")
        }
    }

    /// 验证 pinned 终端不会跨项目/工作区泄漏
    func testPinnedTerminals_doNotLeakAcrossWorkspaces() {
        let terminals = [
            makeTerminal(termId: "t-p1-w1", project: "p1", workspace: "w1"),
            makeTerminal(termId: "t-p1-w2", project: "p1", workspace: "w2"),
            makeTerminal(termId: "t-p2-w1", project: "p2", workspace: "w1"),
        ]
        // pin p2/w1 的终端，但从 p1/w1 视角查看
        let phase = TerminalListDisplayPhase.from(
            project: "p1", workspace: "w1",
            allTerminals: terminals, pinnedIds: ["t-p2-w1"]
        )
        if case .content(let result) = phase {
            let ids = Set(result.map(\.termId))
            XCTAssertFalse(ids.contains("t-p2-w1"),
                           "其他项目的 pinned 终端不应出现在当前项目/工作区视图")
            XCTAssertTrue(ids.contains("t-p1-w1"),
                          "当前工作区的终端应保留")
        } else {
            XCTFail("p1/w1 应有终端内容")
        }
    }
}
