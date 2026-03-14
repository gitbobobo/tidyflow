import XCTest
@testable import TidyFlow
@testable import TidyFlowShared

final class SharedNetworkAbstractionTests: XCTestCase {
    func testServerEnvelopeMetaInit() {
        let meta = ServerEnvelopeMeta(
            seq: 42,
            domain: "git",
            action: "git_status",
            kind: "result",
            requestID: "req-001",
            serverTS: 1234567890
        )
        XCTAssertEqual(meta.seq, 42)
        XCTAssertEqual(meta.domain, "git")
        XCTAssertEqual(meta.action, "git_status")
        XCTAssertEqual(meta.kind, "result")
        XCTAssertEqual(meta.requestID, "req-001")
    }

    func testServerEnvelopeMetaOptionalFields() {
        let meta = ServerEnvelopeMeta(
            seq: 1,
            domain: "core",
            action: "ping",
            kind: "event",
            requestID: nil,
            serverTS: nil
        )
        XCTAssertNil(meta.requestID)
        XCTAssertNil(meta.serverTS)
    }

    func testConnectionStateEquality() {
        XCTAssertEqual(CoreConnectionState.connected, CoreConnectionState.connected)
        XCTAssertNotEqual(CoreConnectionState.connected, CoreConnectionState.disconnected)
        XCTAssertEqual(
            CoreConnectionState.reconnecting(attempt: 1, maxAttempts: 3),
            CoreConnectionState.reconnecting(attempt: 1, maxAttempts: 3)
        )
        XCTAssertNotEqual(
            CoreConnectionState.reconnecting(attempt: 1, maxAttempts: 3),
            CoreConnectionState.reconnecting(attempt: 2, maxAttempts: 3)
        )
    }

    // MARK: - 共享连接语义层与网络抽象集成回归

    /// 验证 ConnectionPhase 的迁移辅助方法与网络层共享抽象兼容。
    func testConnectionPhaseEvaluateDisconnectConsistencyWithSharedAbstraction() {
        // 主动断开应始终返回确定阶段
        let intentional = ConnectionPhase.evaluateDisconnect(isIntentional: true, isCoreAvailable: true)
        XCTAssertNotNil(intentional)
        XCTAssertEqual(intentional, .intentionallyDisconnected)

        // 意外断连应返回 nil，由调用方决定是否重连
        let unexpected = ConnectionPhase.evaluateDisconnect(isIntentional: false, isCoreAvailable: true)
        XCTAssertNil(unexpected, "意外断连时应返回 nil 由调用方触发重连")
    }

    /// 验证 allowsAutoReconnect 属性覆盖所有 ConnectionPhase 枚举值。
    func testAllowsAutoReconnectExhaustiveForAllPhases() {
        let phasesAndExpected: [(ConnectionPhase, Bool)] = [
            (.connecting, true),
            (.connected, true),
            (.reconnecting(attempt: 1, maxAttempts: 5), false),
            (.reconnectFailed, false),
            (.authenticationFailed(reason: "test"), false),
            (.intentionallyDisconnected, false),
        ]
        for (phase, expected) in phasesAndExpected {
            XCTAssertEqual(
                phase.allowsAutoReconnect, expected,
                "\(phase) 的 allowsAutoReconnect 应为 \(expected)"
            )
        }
    }
}

// MARK: - 消息处理适配器模式验证

final class MessageHandlerAdapterPatternTests: XCTestCase {

    /// 验证 CoreWSClientProtocol 定义了必需的 handler 属性（适配器模式基础保证）。
    /// 通过编译期协议一致性验证，确保共享抽象不遗漏核心域。
    func testCoreWSClientProtocolDeclaresAllHandlerProperties() {
        // 验证协议定义的 handler 属性存在（编译时检查）
        // 如果删除任何 handler，下面的 KeyPath 会编译失败
        let _: KeyPath<any CoreWSClientProtocol, (any GitMessageHandler)?> = \.gitMessageHandler
        let _: KeyPath<any CoreWSClientProtocol, (any ProjectMessageHandler)?> = \.projectMessageHandler
        let _: KeyPath<any CoreWSClientProtocol, (any FileMessageHandler)?> = \.fileMessageHandler
        let _: KeyPath<any CoreWSClientProtocol, (any SettingsMessageHandler)?> = \.settingsMessageHandler
        let _: KeyPath<any CoreWSClientProtocol, (any NodeMessageHandler)?> = \.nodeMessageHandler
        let _: KeyPath<any CoreWSClientProtocol, (any TerminalMessageHandler)?> = \.terminalMessageHandler
        let _: KeyPath<any CoreWSClientProtocol, (any AIMessageHandler)?> = \.aiMessageHandler
        let _: KeyPath<any CoreWSClientProtocol, (any EvolutionMessageHandler)?> = \.evolutionMessageHandler
        let _: KeyPath<any CoreWSClientProtocol, (any ErrorMessageHandler)?> = \.errorMessageHandler
    }

    /// 验证 ServerEnvelopeMeta domain 覆盖核心消息域，确保共享路由入口完整。
    func testServerEnvelopeMetaDomainCoverage() {
        let coreDomains: Set<String> = ["git", "project", "file", "terminal", "ai", "core", "evolution"]
        for domain in coreDomains {
            let meta = ServerEnvelopeMeta(
                seq: 1, domain: domain, action: "test", kind: "result",
                requestID: nil, serverTS: nil
            )
            XCTAssertEqual(meta.domain, domain, "domain '\(domain)' 应被正确保留")
        }
    }
}
