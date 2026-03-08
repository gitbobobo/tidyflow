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
