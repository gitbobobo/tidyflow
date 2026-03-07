import XCTest
@testable import TidyFlow

// AC-004 & AC-005：循环恢复状态机与动态轮次调整测试
// AC-004：验证 pendingAction 30 秒超时逻辑，以及恢复路径下 shouldClearPendingAction 行为。
// AC-005：验证 EvolutionPendingActionState 的 resolvedLoopRoundLimit 及
//         EvolutionWorkspaceItemV2 的 loopRoundLimit 解析，确保动态调整轮次的
//         语义边界在协议模型层是正确的。

final class EvolutionLoopRoundAdjustmentTests: XCTestCase {

    // MARK: - AC-004: pendingAction 30 秒超时

    /// 超过 30 秒的 pendingAction 应触发超时清除
    func testPendingActionTimesOutAfter30Seconds() {
        let expiredAt = Date().addingTimeInterval(-31)  // 31 秒前发出
        let expired = EvolutionPendingActionState(action: .resume, requestedAt: expiredAt)

        // evaluate() 超时后应跌回正常状态求值：running 状态应能 stop
        let cap = EvolutionControlCapability.evaluate(
            workspaceReady: true,
            currentStatus: "running",
            pendingAction: expired
        )
        XCTAssertTrue(cap.canStop, "超时 pendingAction 后应跌回 running 状态可停止")
        XCTAssertFalse(cap.canResume, "running 状态下不可恢复")
    }

    /// 未超时的 pendingAction 应锁定所有按钮
    func testFreshPendingActionLocksAllControls() {
        let fresh = EvolutionPendingActionState(action: .stop, requestedAt: Date())
        let cap = EvolutionControlCapability.evaluate(
            workspaceReady: true,
            currentStatus: "running",
            pendingAction: fresh
        )
        XCTAssertFalse(cap.canStart)
        XCTAssertFalse(cap.canStop)
        XCTAssertFalse(cap.canResume)
        XCTAssertTrue(cap.isStopPending)
    }

    /// shouldClearPendingAction 对 30 秒超时的 action 应返回 true
    func testShouldClearPendingActionOnTimeout() {
        let expiredAt = Date().addingTimeInterval(-31)
        let expired = EvolutionPendingActionState(action: .start, requestedAt: expiredAt)

        XCTAssertTrue(
            EvolutionControlCapability.shouldClearPendingAction(expired, currentStatus: nil),
            "超时 pendingAction 无论状态如何都应清除"
        )
        XCTAssertTrue(
            EvolutionControlCapability.shouldClearPendingAction(expired, currentStatus: "queued"),
            "超时 pendingAction 在 queued 状态下也应清除"
        )
    }

    /// 未超时的 stop pending 在 interrupted 状态下应清除
    func testShouldClearStopPendingWhenInterrupted() {
        let fresh = EvolutionPendingActionState(action: .stop, requestedAt: Date())
        XCTAssertTrue(
            EvolutionControlCapability.shouldClearPendingAction(fresh, currentStatus: "interrupted"),
            "stop 已生效（interrupted），应清除 pendingAction"
        )
    }

    /// 未超时的 resume pending 在 running 状态下应清除
    func testShouldClearResumePendingWhenRunning() {
        let fresh = EvolutionPendingActionState(action: .resume, requestedAt: Date())
        XCTAssertTrue(
            EvolutionControlCapability.shouldClearPendingAction(fresh, currentStatus: "running"),
            "resume 已生效（running），应清除 pendingAction"
        )
    }

    /// 未超时的 start pending 在 queued 状态下应清除
    func testShouldClearStartPendingWhenQueued() {
        let fresh = EvolutionPendingActionState(action: .start, requestedAt: Date())
        XCTAssertTrue(
            EvolutionControlCapability.shouldClearPendingAction(fresh, currentStatus: "queued"),
            "start 已生效（queued），应清除 pendingAction"
        )
    }

    /// stop pending 在 running 状态下不应清除（操作尚未生效）
    func testShouldNotClearStopPendingWhileStillRunning() {
        let fresh = EvolutionPendingActionState(action: .stop, requestedAt: Date())
        XCTAssertFalse(
            EvolutionControlCapability.shouldClearPendingAction(fresh, currentStatus: "running"),
            "stop 操作尚未生效，不应清除"
        )
    }

    // MARK: - AC-004: interrupted/stopped 状态下恢复入口可见

    func testInterruptedStateCanResume() {
        let cap = EvolutionControlCapability.evaluate(
            workspaceReady: true,
            currentStatus: "interrupted",
            pendingAction: nil
        )
        XCTAssertTrue(cap.canResume, "interrupted 状态应可恢复")
        XCTAssertFalse(cap.canStart)
        XCTAssertFalse(cap.canStop)
    }

    func testStoppedStateCanResume() {
        let cap = EvolutionControlCapability.evaluate(
            workspaceReady: true,
            currentStatus: "stopped",
            pendingAction: nil
        )
        XCTAssertTrue(cap.canResume, "stopped 状态应可恢复")
    }

    // MARK: - AC-005: 动态轮次调整语义

    /// resolvedLoopRoundLimit 使用 requestedLoopRoundLimit，fallback 到默认值
    func testResolvedLoopRoundLimitUsesRequested() {
        let pending = EvolutionPendingActionState(action: .start, requestedLoopRoundLimit: 7)
        XCTAssertEqual(pending.resolvedLoopRoundLimit(fallback: 3), 7)
    }

    func testResolvedLoopRoundLimitFallsBackWhenNil() {
        let pending = EvolutionPendingActionState(action: .start, requestedLoopRoundLimit: nil)
        XCTAssertEqual(pending.resolvedLoopRoundLimit(fallback: 5), 5)
    }

    /// resolvedLoopRoundLimit 下限为 1，防止非法值 <= 0
    func testResolvedLoopRoundLimitEnforcesMinimumOne() {
        let pendingZero = EvolutionPendingActionState(action: .start, requestedLoopRoundLimit: 0)
        XCTAssertEqual(pendingZero.resolvedLoopRoundLimit(fallback: 3), 1, "0 应被夹到 1")

        let pendingNegative = EvolutionPendingActionState(action: .start, requestedLoopRoundLimit: -5)
        XCTAssertEqual(pendingNegative.resolvedLoopRoundLimit(fallback: 3), 1, "负数应被夹到 1")
    }

    // MARK: - AC-005: EvolutionWorkspaceItemV2 loopRoundLimit 协议解析

    /// 快照数据中的 loop_round_limit 字段应被正确解析
    func testWorkspaceItemParsesLoopRoundLimit() {
        let json = makeWorkspaceItemJSON(loopRoundLimit: 5, status: "running")
        let item = EvolutionWorkspaceItemV2.from(json: json)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.loopRoundLimit, 5)
    }

    /// loop_round_limit 动态更新到新值（模拟服务端接受 evo_adjust_loop_round 后的快照）
    func testWorkspaceItemLoopRoundLimitCanBeUpdatedDynamically() {
        let before = EvolutionWorkspaceItemV2.from(json: makeWorkspaceItemJSON(loopRoundLimit: 3, status: "running"))
        XCTAssertEqual(before?.loopRoundLimit, 3)

        // 模拟服务端 adjust 后推送新快照
        let after = EvolutionWorkspaceItemV2.from(json: makeWorkspaceItemJSON(loopRoundLimit: 7, status: "running"))
        XCTAssertEqual(after?.loopRoundLimit, 7, "调整后快照的 loopRoundLimit 应反映新值")
    }

    /// 当新 limit 等于当前轮次时，循环仍处于 running 状态（不应自动推进到非法轮次）
    func testWorkspaceItemParsesGlobalLoopRoundConsistently() {
        let json = makeWorkspaceItemJSON(loopRoundLimit: 2, status: "running", globalLoopRound: 2)
        let item = EvolutionWorkspaceItemV2.from(json: json)
        XCTAssertEqual(item?.loopRoundLimit, 2)
        XCTAssertEqual(item?.globalLoopRound, 2)
        // 约束：globalLoopRound == loopRoundLimit 时系统应以可预测方式收敛，
        // 此处验证协议解析正确，行为层由 Core 保证。
        XCTAssertEqual(item?.status, "running")
    }

    // MARK: - AC-005: 多工作区隔离（loopRoundLimit 按 workspaceKey 独立）

    /// 两个不同 workspace 的 loopRoundLimit 互相独立，调整一个不影响另一个
    func testMultipleWorkspacesHaveIndependentLoopRoundLimits() {
        let ws1 = EvolutionWorkspaceItemV2.from(
            json: makeWorkspaceItemJSON(loopRoundLimit: 3, status: "running", workspace: "ws-a")
        )
        let ws2 = EvolutionWorkspaceItemV2.from(
            json: makeWorkspaceItemJSON(loopRoundLimit: 8, status: "running", workspace: "ws-b")
        )

        XCTAssertEqual(ws1?.loopRoundLimit, 3)
        XCTAssertEqual(ws2?.loopRoundLimit, 8)
        XCTAssertNotEqual(ws1?.workspaceKey, ws2?.workspaceKey)
    }

    // MARK: - 私有辅助

    private func makeWorkspaceItemJSON(
        loopRoundLimit: Int,
        status: String,
        globalLoopRound: Int = 1,
        workspace: String = "default"
    ) -> [String: Any] {
        [
            "project": "tidyflow",
            "workspace": workspace,
            "cycle_id": "cycle-test",
            "status": status,
            "current_stage": "implement_general",
            "global_loop_round": globalLoopRound,
            "loop_round_limit": loopRoundLimit,
            "verify_iteration": 0,
            "verify_iteration_limit": 5,
        ]
    }
}
