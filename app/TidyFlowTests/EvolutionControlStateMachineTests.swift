import XCTest
@testable import TidyFlowShared

final class EvolutionControlStateMachineTests: XCTestCase {
    func testNoCurrentItemOnlyCanStart() {
        let capability = EvolutionControlCapability.evaluate(
            workspaceReady: true,
            currentStatus: nil,
            pendingAction: nil
        )
        XCTAssertTrue(capability.canStart)
        XCTAssertFalse(capability.canStop)
        XCTAssertFalse(capability.canResume)
    }

    func testRunningOrQueuedOnlyCanStop() {
        let running = EvolutionControlCapability.evaluate(
            workspaceReady: true,
            currentStatus: "running",
            pendingAction: nil
        )
        XCTAssertFalse(running.canStart)
        XCTAssertTrue(running.canStop)
        XCTAssertFalse(running.canResume)

        let queued = EvolutionControlCapability.evaluate(
            workspaceReady: true,
            currentStatus: "queued",
            pendingAction: nil
        )
        XCTAssertFalse(queued.canStart)
        XCTAssertTrue(queued.canStop)
        XCTAssertFalse(queued.canResume)
    }

    func testInterruptedOrStoppedOnlyCanResume() {
        let interrupted = EvolutionControlCapability.evaluate(
            workspaceReady: true,
            currentStatus: "interrupted",
            pendingAction: nil
        )
        XCTAssertFalse(interrupted.canStart)
        XCTAssertFalse(interrupted.canStop)
        XCTAssertTrue(interrupted.canResume)

        let stopped = EvolutionControlCapability.evaluate(
            workspaceReady: true,
            currentStatus: "stopped",
            pendingAction: nil
        )
        XCTAssertFalse(stopped.canStart)
        XCTAssertFalse(stopped.canStop)
        XCTAssertTrue(stopped.canResume)
    }

    func testTerminalOnlyCanStart() {
        for status in ["completed", "failed_exhausted", "failed_system"] {
            let capability = EvolutionControlCapability.evaluate(
                workspaceReady: true,
                currentStatus: status,
                pendingAction: nil
            )
            XCTAssertTrue(capability.canStart, "status=\(status)")
            XCTAssertFalse(capability.canStop, "status=\(status)")
            XCTAssertFalse(capability.canResume, "status=\(status)")
        }
    }

    func testPendingActionsDisableAllButtons() {
        for action in [EvolutionControlAction.start, .stop, .resume] {
            let pending = EvolutionPendingActionState(action: action)
            let capability = EvolutionControlCapability.evaluate(
                workspaceReady: true,
                currentStatus: "running",
                pendingAction: pending
            )
            XCTAssertFalse(capability.canStart)
            XCTAssertFalse(capability.canStop)
            XCTAssertFalse(capability.canResume)
        }
    }

    func testPendingStartKeepsRequestedLoopRoundLimit() {
        let pending = EvolutionPendingActionState(action: .start, requestedLoopRoundLimit: 5)
        XCTAssertEqual(pending.resolvedLoopRoundLimit(fallback: 1), 5)
    }

    func testShouldClearPendingActionWithSnapshotStatus() {
        XCTAssertTrue(
            EvolutionControlCapability.shouldClearPendingAction(
                EvolutionPendingActionState(action: .start),
                currentStatus: "queued"
            )
        )
        XCTAssertFalse(
            EvolutionControlCapability.shouldClearPendingAction(
                EvolutionPendingActionState(action: .stop),
                currentStatus: "running"
            )
        )
        XCTAssertTrue(
            EvolutionControlCapability.shouldClearPendingAction(
                EvolutionPendingActionState(action: .stop),
                currentStatus: "interrupted"
            )
        )
        XCTAssertTrue(
            EvolutionControlCapability.shouldClearPendingAction(
                EvolutionPendingActionState(action: .resume),
                currentStatus: "running"
            )
        )
    }

    // MARK: - pending 超时行为

    func testPendingActionBlocksWithin30Seconds() {
        let pending = EvolutionPendingActionState(action: .start, requestedAt: Date())
        let capability = EvolutionControlCapability.evaluate(
            workspaceReady: true,
            currentStatus: "completed",
            pendingAction: pending
        )
        XCTAssertFalse(capability.canStart)
        XCTAssertTrue(capability.isStartPending)
    }

    func testPendingActionExpiredAfter30Seconds() {
        let expiredDate = Date().addingTimeInterval(-31)
        let pending = EvolutionPendingActionState(action: .start, requestedAt: expiredDate)
        let capability = EvolutionControlCapability.evaluate(
            workspaceReady: true,
            currentStatus: "completed",
            pendingAction: pending
        )
        // 超时后跌回正常状态求值：completed → canStart
        XCTAssertTrue(capability.canStart)
        XCTAssertFalse(capability.isStartPending)
    }

    func testShouldClearPendingActionOnTimeout() {
        let expiredDate = Date().addingTimeInterval(-31)
        let pending = EvolutionPendingActionState(action: .stop, requestedAt: expiredDate)
        XCTAssertTrue(
            EvolutionControlCapability.shouldClearPendingAction(pending, currentStatus: "running")
        )
    }

    // MARK: - 工作区未就绪

    func testWorkspaceNotReadyDisablesAll() {
        let capability = EvolutionControlCapability.evaluate(
            workspaceReady: false,
            currentStatus: "running",
            pendingAction: nil
        )
        XCTAssertFalse(capability.canStart)
        XCTAssertFalse(capability.canStop)
        XCTAssertFalse(capability.canResume)
        XCTAssertNotNil(capability.startReason)
    }

    // MARK: - normalizedStatus

    func testNormalizedStatusTrimsAndLowercases() {
        XCTAssertEqual(EvolutionControlCapability.normalizedStatus("  RUNNING  "), "running")
        XCTAssertNil(EvolutionControlCapability.normalizedStatus(nil))
        XCTAssertNil(EvolutionControlCapability.normalizedStatus(""))
        XCTAssertNil(EvolutionControlCapability.normalizedStatus("   "))
    }
}
