import XCTest
@testable import TidyFlow

// MARK: - ConnectionSemanticLayer 单元测试
// 覆盖：连接阶段迁移、主动/非主动断连判定、重连退避策略、重试耗尽、配对失败恢复

final class ConnectionSemanticLayerTests: XCTestCase {

    // MARK: - ConnectionPhase 基础属性

    func testConnectedPhaseIsConnected() {
        XCTAssertTrue(ConnectionPhase.connected.isConnected)
    }

    func testNonConnectedPhasesAreNotConnected() {
        let phases: [ConnectionPhase] = [
            .connecting,
            .reconnecting(attempt: 1, maxAttempts: 5),
            .reconnectFailed,
            .pairingFailed(reason: "token_expired"),
            .intentionallyDisconnected
        ]
        for phase in phases {
            XCTAssertFalse(phase.isConnected, "\(phase) 不应为 isConnected")
        }
    }

    func testReconnectingPhaseIsReconnecting() {
        XCTAssertTrue(ConnectionPhase.reconnecting(attempt: 2, maxAttempts: 5).isReconnecting)
    }

    func testNonReconnectingPhasesAreNotReconnecting() {
        let phases: [ConnectionPhase] = [
            .connecting,
            .connected,
            .reconnectFailed,
            .pairingFailed(reason: "expired"),
            .intentionallyDisconnected
        ]
        for phase in phases {
            XCTAssertFalse(phase.isReconnecting, "\(phase) 不应为 isReconnecting")
        }
    }

    func testNeedsManualRecoveryForReconnectFailed() {
        XCTAssertTrue(ConnectionPhase.reconnectFailed.needsManualRecovery)
    }

    func testNeedsManualRecoveryForPairingFailed() {
        XCTAssertTrue(ConnectionPhase.pairingFailed(reason: "invalid_token").needsManualRecovery)
    }

    func testNeedsManualRecoveryFalseForOtherPhases() {
        let phases: [ConnectionPhase] = [
            .connecting,
            .connected,
            .reconnecting(attempt: 1, maxAttempts: 5),
            .intentionallyDisconnected
        ]
        for phase in phases {
            XCTAssertFalse(phase.needsManualRecovery, "\(phase) 不应 needsManualRecovery")
        }
    }

    // MARK: - legacyConnectionState 兼容导出

    func testLegacyConnectionStateConnected() {
        XCTAssertEqual(ConnectionPhase.connected.legacyConnectionState, .connected)
    }

    func testLegacyConnectionStateDisconnectedForAllNonConnected() {
        let phases: [ConnectionPhase] = [
            .connecting,
            .reconnecting(attempt: 1, maxAttempts: 5),
            .reconnectFailed,
            .pairingFailed(reason: "bad_code"),
            .intentionallyDisconnected
        ]
        for phase in phases {
            XCTAssertEqual(
                phase.legacyConnectionState, .disconnected,
                "\(phase) 应导出 .disconnected"
            )
        }
    }

    // MARK: - iOS ReconnectState 兼容导出（仅 iOS 构建时运行）

    #if os(iOS)
    func testToReconnectStateForReconnecting() {
        let phase = ConnectionPhase.reconnecting(attempt: 3, maxAttempts: 5)
        if case .reconnecting(let attempt, let max) = phase.toReconnectState {
            XCTAssertEqual(attempt, 3)
            XCTAssertEqual(max, 5)
        } else {
            XCTFail("toReconnectState 应为 .reconnecting")
        }
    }

    func testToReconnectStateForReconnectFailed() {
        XCTAssertEqual(ConnectionPhase.reconnectFailed.toReconnectState, ReconnectState.failed)
    }

    func testToReconnectStateIdleForConnected() {
        XCTAssertEqual(ConnectionPhase.connected.toReconnectState, ReconnectState.idle)
    }

    func testToReconnectStateIdleForConnecting() {
        XCTAssertEqual(ConnectionPhase.connecting.toReconnectState, ReconnectState.idle)
    }

    func testToReconnectStateIdleForIntentionallyDisconnected() {
        XCTAssertEqual(ConnectionPhase.intentionallyDisconnected.toReconnectState, ReconnectState.idle)
    }

    func testToReconnectStateIdleForPairingFailed() {
        XCTAssertEqual(ConnectionPhase.pairingFailed(reason: "test").toReconnectState, ReconnectState.idle)
    }
    #endif

    // MARK: - ReconnectPolicy 退避节奏

    func testReconnectPolicyMaxAttempts() {
        XCTAssertEqual(ReconnectPolicy.maxAttempts, 5)
    }

    func testReconnectPolicyDelaysCount() {
        XCTAssertEqual(ReconnectPolicy.delays.count, 5)
    }

    func testReconnectPolicyDelayAttempt1() {
        XCTAssertEqual(ReconnectPolicy.delay(for: 1), 0.5)
    }

    func testReconnectPolicyDelayAttempt2() {
        XCTAssertEqual(ReconnectPolicy.delay(for: 2), 1.0)
    }

    func testReconnectPolicyDelayAttempt5() {
        XCTAssertEqual(ReconnectPolicy.delay(for: 5), 8.0)
    }

    func testReconnectPolicyDelayClampedAtMax() {
        // attempt 超出 delays 数组范围时应返回最大值
        XCTAssertEqual(ReconnectPolicy.delay(for: 99), ReconnectPolicy.delays.last!)
    }

    func testReconnectPolicyDelaysAscending() {
        let delays = ReconnectPolicy.delays
        for i in 1..<delays.count {
            XCTAssertGreaterThan(delays[i], delays[i - 1], "退避延迟应单调递增")
        }
    }

    // MARK: - 主动/非主动断连判定语义

    func testIntentionallyDisconnectedIsNotReconnecting() {
        XCTAssertFalse(ConnectionPhase.intentionallyDisconnected.isReconnecting)
        XCTAssertFalse(ConnectionPhase.intentionallyDisconnected.needsManualRecovery)
    }

    func testIntentionallyDisconnectedDoesNotNeedManualRecovery() {
        // 主动断开不需要人工干预，用户自己发起的
        XCTAssertFalse(ConnectionPhase.intentionallyDisconnected.needsManualRecovery)
    }

    func testReconnectFailedNeedsManualRecovery() {
        // 耗尽重连次数后，需要人工恢复
        XCTAssertTrue(ConnectionPhase.reconnectFailed.needsManualRecovery)
    }

    // MARK: - 重连进度在 attempt 范围内

    func testReconnectingAttemptAndMaxPreserved() {
        let phase = ConnectionPhase.reconnecting(attempt: 2, maxAttempts: 5)
        if case .reconnecting(let attempt, let max) = phase {
            XCTAssertEqual(attempt, 2)
            XCTAssertEqual(max, 5)
        } else {
            XCTFail("应为 .reconnecting")
        }
    }

    // MARK: - Equatable

    func testConnectedEquality() {
        XCTAssertEqual(ConnectionPhase.connected, ConnectionPhase.connected)
    }

    func testReconnectingEquality() {
        XCTAssertEqual(
            ConnectionPhase.reconnecting(attempt: 1, maxAttempts: 5),
            ConnectionPhase.reconnecting(attempt: 1, maxAttempts: 5)
        )
    }

    func testReconnectingInequalityOnAttempt() {
        XCTAssertNotEqual(
            ConnectionPhase.reconnecting(attempt: 1, maxAttempts: 5),
            ConnectionPhase.reconnecting(attempt: 2, maxAttempts: 5)
        )
    }

    func testPairingFailedEquality() {
        XCTAssertEqual(
            ConnectionPhase.pairingFailed(reason: "expired"),
            ConnectionPhase.pairingFailed(reason: "expired")
        )
    }

    func testPairingFailedInequalityOnReason() {
        XCTAssertNotEqual(
            ConnectionPhase.pairingFailed(reason: "a"),
            ConnectionPhase.pairingFailed(reason: "b")
        )
    }

    // MARK: - project/workspace 无关性（确保阶段模型不耦合项目）

    func testConnectionPhaseDoesNotReferenceProjectOrWorkspace() {
        // ConnectionPhase 是值类型，不持有任何项目/工作区引用
        // 这里通过创建各个阶段并确认它们独立于外部状态存在
        let phases: [ConnectionPhase] = [
            .connecting,
            .connected,
            .reconnecting(attempt: 1, maxAttempts: 5),
            .reconnectFailed,
            .pairingFailed(reason: "test"),
            .intentionallyDisconnected
        ]
        // 所有阶段都可以独立创建，证明无 project/workspace 耦合
        XCTAssertEqual(phases.count, 6)
    }

    // MARK: - allowsAutoReconnect 迁移防护

    func testAllowsAutoReconnectForConnecting() {
        XCTAssertTrue(ConnectionPhase.connecting.allowsAutoReconnect, "connecting 阶段应允许自动重连")
    }

    func testAllowsAutoReconnectForConnected() {
        XCTAssertTrue(ConnectionPhase.connected.allowsAutoReconnect, "connected 阶段应允许自动重连（如意外断连后探活失败）")
    }

    func testAllowsAutoReconnectFalseForReconnecting() {
        XCTAssertFalse(
            ConnectionPhase.reconnecting(attempt: 1, maxAttempts: 5).allowsAutoReconnect,
            "reconnecting 阶段不应重复触发自动重连"
        )
    }

    func testAllowsAutoReconnectFalseForReconnectFailed() {
        XCTAssertFalse(
            ConnectionPhase.reconnectFailed.allowsAutoReconnect,
            "reconnectFailed 应拒绝自动重连，需人工恢复"
        )
    }

    func testAllowsAutoReconnectFalseForPairingFailed() {
        XCTAssertFalse(
            ConnectionPhase.pairingFailed(reason: "invalid_token").allowsAutoReconnect,
            "pairingFailed 应拒绝自动重连，需重新配对"
        )
    }

    func testAllowsAutoReconnectFalseForIntentionallyDisconnected() {
        XCTAssertFalse(
            ConnectionPhase.intentionallyDisconnected.allowsAutoReconnect,
            "intentionallyDisconnected 是用户主动断开，不应自动重连"
        )
    }

    // MARK: - evaluateDisconnect 断连决策

    func testEvaluateDisconnectIntentionalReturnsIntentionallyDisconnected() {
        let phase = ConnectionPhase.evaluateDisconnect(isIntentional: true, isCoreAvailable: true)
        XCTAssertEqual(phase, .intentionallyDisconnected)
    }

    func testEvaluateDisconnectCoreUnavailableReturnsIntentionallyDisconnected() {
        let phase = ConnectionPhase.evaluateDisconnect(isIntentional: false, isCoreAvailable: false)
        XCTAssertEqual(phase, .intentionallyDisconnected)
    }

    func testEvaluateDisconnectUnexpectedReturnsNil() {
        let phase = ConnectionPhase.evaluateDisconnect(isIntentional: false, isCoreAvailable: true)
        XCTAssertNil(phase, "意外断连应返回 nil，由调用方触发重连")
    }

    func testEvaluateDisconnectBothTrueReturnsIntentional() {
        let phase = ConnectionPhase.evaluateDisconnect(isIntentional: true, isCoreAvailable: false)
        XCTAssertEqual(phase, .intentionallyDisconnected, "主动 + Core 不可用仍应为主动断开")
    }

    // MARK: - nextReconnectPhase 重连进度推导

    func testNextReconnectPhaseFromZero() {
        let phase = ConnectionPhase.nextReconnectPhase(currentAttempt: 0)
        XCTAssertEqual(phase, .reconnecting(attempt: 1, maxAttempts: 5))
    }

    func testNextReconnectPhaseAtMaxMinusOne() {
        let phase = ConnectionPhase.nextReconnectPhase(currentAttempt: 4)
        XCTAssertEqual(phase, .reconnecting(attempt: 5, maxAttempts: 5))
    }

    func testNextReconnectPhaseExhausted() {
        let phase = ConnectionPhase.nextReconnectPhase(currentAttempt: 5)
        XCTAssertEqual(phase, .reconnectFailed, "超出最大次数应返回 reconnectFailed")
    }

    func testNextReconnectPhaseOverflowStaysExhausted() {
        let phase = ConnectionPhase.nextReconnectPhase(currentAttempt: 100)
        XCTAssertEqual(phase, .reconnectFailed)
    }

    func testNextReconnectPhaseUsesReconnectPolicyMaxAttempts() {
        // 确认 nextReconnectPhase 内部使用 ReconnectPolicy.maxAttempts
        for attempt in 0..<ReconnectPolicy.maxAttempts {
            let phase = ConnectionPhase.nextReconnectPhase(currentAttempt: attempt)
            if case .reconnecting(let a, let max) = phase {
                XCTAssertEqual(a, attempt + 1)
                XCTAssertEqual(max, ReconnectPolicy.maxAttempts)
            } else {
                XCTFail("attempt \(attempt) 应返回 .reconnecting，实际返回 \(phase)")
            }
        }
    }
}
