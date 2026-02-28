import XCTest
@testable import TidyFlow

final class AIPlanCardViewModelTests: XCTestCase {
    func testPayloadParsesEntriesAndHistory() {
        let source: [String: Any] = [
            "vendor": "acp",
            "item_type": "plan",
            "protocol": "agent-plan",
            "revision": 3,
            "updated_at_ms": 1760000000000 as Int64,
            "entries": [
                ["content": "实现解析器", "status": "in_progress", "priority": "high"],
                ["content": "补测试", "status": "pending"],
            ],
            "history": [
                [
                    "revision": 1,
                    "updated_at_ms": 1759999999000 as Int64,
                    "entries": [
                        ["content": "实现解析器", "status": "pending"],
                    ],
                ],
                [
                    "revision": 2,
                    "updated_at_ms": 1759999999500 as Int64,
                    "entries": [
                        ["content": "实现解析器", "status": "in_progress"],
                    ],
                ],
            ],
        ]

        let payload = AIPlanCardPayload.from(source: source)
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.revision, 3)
        XCTAssertEqual(payload?.entries.count, 2)
        XCTAssertEqual(payload?.entries.first?.content, "实现解析器")
        XCTAssertEqual(payload?.entries.first?.displayStatus, "进行中")
        XCTAssertEqual(payload?.entries.first?.displayPriority, "高")
        XCTAssertEqual(payload?.history.count, 2)
        XCTAssertEqual(payload?.history.first?.revision, 1)
    }

    func testPayloadParsesEmptyEntriesForPlanClear() {
        let source: [String: Any] = [
            "vendor": "acp",
            "item_type": "plan",
            "protocol": "agent-plan",
            "revision": 4,
            "entries": [],
            "history": [],
        ]

        let payload = AIPlanCardPayload.from(source: source)
        XCTAssertNotNil(payload)
        XCTAssertTrue(payload?.entries.isEmpty == true)
        XCTAssertEqual(payload?.summaryLine, "[计划] 0 项 · v4")
    }

    func testPayloadSkipsInvalidEntryAndKeepsValidEntries() {
        let source: [String: Any] = [
            "entries": [
                ["content": "有效", "status": "completed", "priority": "low"],
                ["content": "", "status": "pending"],
                ["content": "缺状态"],
            ],
        ]

        let payload = AIPlanCardPayload.from(source: source)
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.entries.count, 1)
        XCTAssertEqual(payload?.entries.first?.displayStatus, "已完成")
        XCTAssertEqual(payload?.entries.first?.displayPriority, "低")
    }

    func testPayloadKeepsUnknownStatusRawValue() {
        let source: [String: Any] = [
            "entries": [
                ["content": "等待外部依赖", "status": "blocked"],
            ],
        ]

        let payload = AIPlanCardPayload.from(source: source)
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.entries.count, 1)
        XCTAssertEqual(payload?.entries.first?.displayStatus, "blocked")
    }
}
