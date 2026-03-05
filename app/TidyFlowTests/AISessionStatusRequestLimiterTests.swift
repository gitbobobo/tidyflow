import XCTest
@testable import TidyFlow

final class AISessionStatusRequestLimiterTests: XCTestCase {
    func testRejectsRequestsWithinInterval() {
        var limiter = AISessionStatusRequestLimiter()
        let base = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(limiter.shouldRequest(key: "p::w::tool::s1", now: base, minInterval: 1.2, force: false))
        XCTAssertFalse(limiter.shouldRequest(key: "p::w::tool::s1", now: base.addingTimeInterval(0.8), minInterval: 1.2, force: false))
        XCTAssertTrue(limiter.shouldRequest(key: "p::w::tool::s1", now: base.addingTimeInterval(1.2), minInterval: 1.2, force: false))
    }

    func testForceAlwaysAllowsRequest() {
        var limiter = AISessionStatusRequestLimiter()
        let base = Date(timeIntervalSince1970: 2_000)

        XCTAssertTrue(limiter.shouldRequest(key: "p::w::tool::s1", now: base, minInterval: 1.2, force: false))
        XCTAssertTrue(limiter.shouldRequest(key: "p::w::tool::s1", now: base.addingTimeInterval(0.1), minInterval: 1.2, force: true))
    }

    func testDifferentSessionKeysDoNotInterfere() {
        var limiter = AISessionStatusRequestLimiter()
        let base = Date(timeIntervalSince1970: 3_000)

        XCTAssertTrue(limiter.shouldRequest(key: "p::w::tool::s1", now: base, minInterval: 1.2, force: false))
        XCTAssertTrue(limiter.shouldRequest(key: "p::w::tool::s2", now: base.addingTimeInterval(0.2), minInterval: 1.2, force: false))
        XCTAssertFalse(limiter.shouldRequest(key: "p::w::tool::s1", now: base.addingTimeInterval(0.3), minInterval: 1.2, force: false))
    }
}
