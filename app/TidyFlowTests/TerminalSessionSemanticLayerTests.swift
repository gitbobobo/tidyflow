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
}
