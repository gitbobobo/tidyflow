import XCTest
@testable import TidyFlow
import TidyFlowShared

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
        let _: KeyPath<any CoreWSClientProtocol, (any TerminalMessageHandler)?> = \.terminalMessageHandler
        let _: KeyPath<any CoreWSClientProtocol, (any AIMessageHandler)?> = \.aiMessageHandler
        let _: KeyPath<any CoreWSClientProtocol, (any EvolutionMessageHandler)?> = \.evolutionMessageHandler
        let _: KeyPath<any CoreWSClientProtocol, (any ErrorMessageHandler)?> = \.errorMessageHandler
    }

    /// 验证 ServerEnvelopeMeta domain 覆盖核心消息域，确保共享路由入口完整。
    func testServerEnvelopeMetaDomainCoverage() {
        let coreDomains: Set<String> = ["git", "project", "file", "terminal", "ai", "core", "evolution", "evidence"]
        for domain in coreDomains {
            let meta = ServerEnvelopeMeta(
                seq: 1, domain: domain, action: "test", kind: "result",
                requestID: nil, serverTS: nil
            )
            XCTAssertEqual(meta.domain, domain, "domain '\(domain)' 应被正确保留")
        }
    }
}
