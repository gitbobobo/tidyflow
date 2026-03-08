import XCTest
@testable import TidyFlow

// MARK: - TerminalSessionStore 单元测试
// 覆盖：展示信息管理、置顶状态、attach/detach RTT 追踪、输出 ACK 计数、断线清理
// 验证工作项 WI-002 共享终端会话存储的核心契约

final class TerminalSessionStoreTests: XCTestCase {

    private var store: TerminalSessionStore!

    override func setUp() {
        super.setUp()
        store = TerminalSessionStore()
    }

    // MARK: - 展示信息

    func testSetAndGetDisplayInfo() {
        let info = TerminalDisplayInfo(
            termId: "t1", project: "proj", workspace: "ws",
            icon: "terminal", name: "Shell", sourceCommand: nil, isPinned: false
        )
        store.setDisplayInfo(info)
        let got = store.displayInfo(for: "t1")
        XCTAssertEqual(got?.name, "Shell")
        XCTAssertEqual(got?.icon, "terminal")
    }

    func testRestoreDisplayInfoIfAbsent_skipsIfExists() {
        let info1 = TerminalDisplayInfo(
            termId: "t1", project: "proj", workspace: "ws",
            icon: "terminal", name: "First", sourceCommand: nil, isPinned: false
        )
        store.setDisplayInfo(info1)

        let info2 = TerminalDisplayInfo(
            termId: "t1", project: "proj", workspace: "ws",
            icon: "star", name: "Second", sourceCommand: nil, isPinned: false
        )
        store.restoreDisplayInfoIfAbsent(info2)

        XCTAssertEqual(store.displayInfo(for: "t1")?.name, "First", "应保留已有展示信息")
    }

    func testRestoreDisplayInfoIfAbsent_setsWhenMissing() {
        let info = TerminalDisplayInfo(
            termId: "t99", project: "proj", workspace: "ws",
            icon: "terminal", name: "Fallback", sourceCommand: nil, isPinned: false
        )
        store.restoreDisplayInfoIfAbsent(info)
        XCTAssertEqual(store.displayInfo(for: "t99")?.name, "Fallback")
    }

    // MARK: - 置顶状态

    func testTogglePinned() {
        XCTAssertFalse(store.isPinned(termId: "t1"))
        store.togglePinned(termId: "t1")
        XCTAssertTrue(store.isPinned(termId: "t1"))
        store.togglePinned(termId: "t1")
        XCTAssertFalse(store.isPinned(termId: "t1"))
    }

    func testPinnedStatusReflectedInDisplayInfo() {
        let info = TerminalDisplayInfo(
            termId: "t1", project: "proj", workspace: "ws",
            icon: "terminal", name: "Shell", sourceCommand: nil, isPinned: false
        )
        store.setDisplayInfo(info)
        store.togglePinned(termId: "t1")
        XCTAssertTrue(store.displayInfo(for: "t1")?.isPinned ?? false)
        store.togglePinned(termId: "t1")
        XCTAssertFalse(store.displayInfo(for: "t1")?.isPinned ?? true)
    }

    // MARK: - Workspace Open Time

    func testRecordWorkspaceOpenTimeIfNeeded_onlyFirstTime() {
        store.recordWorkspaceOpenTimeIfNeeded(key: "proj:ws")
        let t1 = store.workspaceOpenTime["proj:ws"]
        XCTAssertNotNil(t1)

        // 第二次调用不覆盖
        store.recordWorkspaceOpenTimeIfNeeded(key: "proj:ws")
        let t2 = store.workspaceOpenTime["proj:ws"]
        XCTAssertEqual(t1, t2)
    }

    // MARK: - Attach/Detach RTT 追踪

    func testRecordAndConsumeAttachRequest() {
        store.recordAttachRequest(termId: "t1")
        XCTAssertNotNil(store.attachRequestedAt["t1"])
    }

    func testHandleTermAttached_returnsRTT() {
        store.recordAttachRequest(termId: "t1")
        let result = TermAttachedResult(
            termId: "t1", project: "proj", workspace: "ws",
            cwd: "/", shell: "bash", scrollback: [],
            name: "Shell", icon: nil
        )
        let rtt = store.handleTermAttached(result: result)
        XCTAssertNotNil(rtt)
        XCTAssertNil(store.attachRequestedAt["t1"], "attach 请求时间应在 handleTermAttached 后消费")
    }

    func testHandleTermAttached_restoresDisplayInfoIfAbsent() {
        let result = TermAttachedResult(
            termId: "t2", project: "proj", workspace: "ws",
            cwd: "/", shell: "bash", scrollback: [],
            name: "Named", icon: "star"
        )
        let _ = store.handleTermAttached(result: result)
        XCTAssertEqual(store.displayInfo(for: "t2")?.name, "Named")
        XCTAssertEqual(store.displayInfo(for: "t2")?.icon, "star")
    }

    // MARK: - 输出 ACK 计数

    func testAddAndClearUnackedBytes() {
        store.addUnackedBytes(1024, for: "t1")
        XCTAssertEqual(store.unackedBytes(for: "t1"), 1024)
        store.addUnackedBytes(512, for: "t1")
        XCTAssertEqual(store.unackedBytes(for: "t1"), 1536)
        store.clearUnackedBytes(for: "t1")
        XCTAssertEqual(store.unackedBytes(for: "t1"), 0)
    }

    func testResetUnackedBytes() {
        store.addUnackedBytes(10000, for: "t1")
        store.resetUnackedBytes(for: "t1")
        XCTAssertEqual(store.unackedBytes(for: "t1"), 0)
    }

    func testUnackedBytesForUnknownTermReturnsZero() {
        XCTAssertEqual(store.unackedBytes(for: "unknown"), 0)
    }

    // MARK: - term_closed 清理

    func testHandleTermClosed_clearsAllState() {
        // 设置各种状态
        let info = TerminalDisplayInfo(
            termId: "t1", project: "proj", workspace: "ws",
            icon: "terminal", name: "Shell", sourceCommand: nil, isPinned: false
        )
        store.setDisplayInfo(info)
        store.togglePinned(termId: "t1")
        store.addUnackedBytes(5000, for: "t1")
        store.recordAttachRequest(termId: "t1")
        store.recordDetachRequest(termId: "t1")

        // 关闭终端
        store.handleTermClosed(termId: "t1")

        XCTAssertNil(store.displayInfo(for: "t1"), "关闭后展示信息应清除")
        XCTAssertFalse(store.isPinned(termId: "t1"), "关闭后置顶状态应清除")
        XCTAssertEqual(store.unackedBytes(for: "t1"), 0, "关闭后 ACK 计数应清除")
        XCTAssertNil(store.attachRequestedAt["t1"], "关闭后 attach 请求时间应清除")
        XCTAssertNil(store.detachRequestedAt["t1"], "关闭后 detach 请求时间应清除")
    }

    // MARK: - 断线 stale 处理

    func testHandleDisconnect_clearsTrackingButKeepsDisplayInfo() {
        let info = TerminalDisplayInfo(
            termId: "t1", project: "proj", workspace: "ws",
            icon: "terminal", name: "Shell", sourceCommand: nil, isPinned: false
        )
        store.setDisplayInfo(info)
        store.togglePinned(termId: "t1")
        store.addUnackedBytes(10000, for: "t1")
        store.recordAttachRequest(termId: "t1")
        store.recordDetachRequest(termId: "t1")

        store.handleDisconnect()

        // 展示信息和置顶状态保留（用于重连恢复）
        XCTAssertNotNil(store.displayInfo(for: "t1"), "断线后展示信息应保留")
        XCTAssertTrue(store.isPinned(termId: "t1"), "断线后置顶状态应保留")
        // 追踪状态清除
        XCTAssertEqual(store.unackedBytes(for: "t1"), 0, "断线后 ACK 计数应清零")
        XCTAssertNil(store.attachRequestedAt["t1"], "断线后 attach 请求时间应清除")
        XCTAssertNil(store.detachRequestedAt["t1"], "断线后 detach 请求时间应清除")
    }

    // MARK: - term_list 恢复

    func testReconcileTermList_clearsExpiredEntries() {
        let info = TerminalDisplayInfo(
            termId: "stale", project: "proj", workspace: "ws",
            icon: "terminal", name: "Stale", sourceCommand: nil, isPinned: false
        )
        store.setDisplayInfo(info)
        store.togglePinned(termId: "stale")

        let live = TerminalSessionInfo(
            termId: "live", project: "proj", workspace: "ws",
            cwd: "/", shell: "bash", status: "running",
            name: "Live Shell", icon: nil, remoteSubscribers: []
        )
        store.reconcileTermList(
            items: [live],
            makeKey: { proj, ws in "\(proj):\(ws)" }
        )

        XCTAssertNil(store.displayInfo(for: "stale"), "term_list 后过期展示信息应清除")
        XCTAssertFalse(store.isPinned(termId: "stale"), "term_list 后过期置顶状态应清除")
        XCTAssertNotNil(store.displayInfo(for: "live"), "服务端有 name 的终端应被恢复")
    }

    // MARK: - 重连恢复链路回归

    /// 验证断线 → 重连 → 重新 attach 的完整流程中，追踪状态可被正确恢复。
    func testDisconnectThenReconnectAttachFlow() {
        let info = TerminalDisplayInfo(
            termId: "t1", project: "proj", workspace: "ws",
            icon: "terminal", name: "Shell", sourceCommand: nil, isPinned: false
        )
        store.setDisplayInfo(info)
        store.addUnackedBytes(5000, for: "t1")
        store.recordAttachRequest(termId: "t1")

        // 断线
        store.handleDisconnect()
        XCTAssertNotNil(store.displayInfo(for: "t1"), "展示信息保留用于重连恢复")
        XCTAssertEqual(store.unackedBytes(for: "t1"), 0, "断线后 ACK 清零")

        // 重连时发送新 attach 请求
        store.recordAttachRequest(termId: "t1")
        XCTAssertNotNil(store.attachRequestedAt["t1"])

        // 模拟 attach 成功
        let result = TermAttachedResult(
            termId: "t1", project: "proj", workspace: "ws",
            cwd: "/home", shell: "zsh", scrollback: [],
            name: "Shell", icon: nil
        )
        let rtt = store.handleTermAttached(result: result)
        XCTAssertNotNil(rtt, "重连后 attach 应返回 RTT")
        XCTAssertNil(store.attachRequestedAt["t1"], "attach 后请求时间应消费")
    }

    /// 验证 handleDisconnect 幂等性：连续调用不 crash 也不产生副作用。
    func testHandleDisconnectIsIdempotent() {
        let info = TerminalDisplayInfo(
            termId: "t1", project: "proj", workspace: "ws",
            icon: "terminal", name: "Shell", sourceCommand: nil, isPinned: false
        )
        store.setDisplayInfo(info)
        store.addUnackedBytes(1000, for: "t1")

        store.handleDisconnect()
        store.handleDisconnect()

        XCTAssertNotNil(store.displayInfo(for: "t1"), "多次断线后展示信息仍保留")
        XCTAssertEqual(store.unackedBytes(for: "t1"), 0)
    }
}
