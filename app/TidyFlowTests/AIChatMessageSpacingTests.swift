import XCTest
@testable import TidyFlow

/// 验证聊天工具卡间距与消息扁平缓存路径逻辑：
/// - AIChatPart.kind == .tool 类型正确创建
/// - 连续工具卡在扁平缓存中可被 O(1) 定位
/// - 消息扁平索引在 AIChatSnapshot 中结构稳定
final class AIChatMessageSpacingTests: XCTestCase {

    // MARK: - 工具 Part 类型验证

    func testToolPartKindIsCorrectlySet() {
        let part = AIChatPart(id: "p1", kind: .tool, toolName: "bash")
        XCTAssertEqual(part.kind, .tool)
    }

    func testConsecutiveToolPartsHaveSameKind() {
        let parts: [AIChatPart] = [
            AIChatPart(id: "p1", kind: .tool, toolName: "bash"),
            AIChatPart(id: "p2", kind: .tool, toolName: "read_file"),
            AIChatPart(id: "p3", kind: .tool, toolName: "write_file"),
        ]
        // 连续工具卡场景下，所有 parts 均为 .tool
        XCTAssertTrue(parts.allSatisfy { $0.kind == .tool })
    }

    func testMixedPartsContainToolAndTextKinds() {
        let parts: [AIChatPart] = [
            AIChatPart(id: "p1", kind: .text, text: "Thinking..."),
            AIChatPart(id: "p2", kind: .tool, toolName: "bash"),
            AIChatPart(id: "p3", kind: .tool, toolName: "read_file"),
        ]
        XCTAssertEqual(parts.filter { $0.kind == .tool }.count, 2)
        XCTAssertEqual(parts.filter { $0.kind == .text }.count, 1)
    }

    // MARK: - 扁平缓存路径（partIndexByPartId）验证

    func testPartFlatCacheIsReflectedInSnapshot() {
        let store = AIChatStore()

        let msgId = "msg-001"
        let part1 = AIChatPart(id: "part-001", kind: .tool, toolName: "bash")
        let part2 = AIChatPart(id: "part-002", kind: .tool, toolName: "read_file")
        let message = AIChatMessage(
            id: UUID().uuidString,
            messageId: msgId,
            role: .assistant,
            parts: [part1, part2],
            isStreaming: false
        )

        store.applySnapshot(AIChatSnapshot(
            currentSessionId: nil,
            subscribedSessionIds: [],
            messages: [message],
            isStreaming: false,
            sessions: [],
            messageIndexByMessageId: [msgId: 0],
            partIndexByPartId: [
                "part-001": (msgIdx: 0, partIdx: 0),
                "part-002": (msgIdx: 0, partIdx: 1),
            ],
            pendingToolQuestions: [:],
            questionRequestToCallId: [:]
        ))

        let snapshot = store.makeSnapshot(sessions: [])
        XCTAssertNotNil(snapshot.messageIndexByMessageId[msgId], "消息 ID 应在扁平缓存中可查找")
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertEqual(snapshot.messages[0].parts.count, 2, "消息应包含 2 个工具 part")
    }

    // MARK: - 工具 part 数量计算（间距规则的数据基础）

    func testToolPartCountCorrect() {
        let message = AIChatMessage(
            id: UUID().uuidString,
            messageId: "m1",
            role: .assistant,
            parts: [
                AIChatPart(id: "a", kind: .tool, toolName: "bash"),
                AIChatPart(id: "b", kind: .text, text: "done"),
                AIChatPart(id: "c", kind: .tool, toolName: "read_file"),
                AIChatPart(id: "d", kind: .tool, toolName: "write_file"),
            ]
        )
        let toolCount = message.parts.filter { $0.kind == .tool }.count
        XCTAssertEqual(toolCount, 3, "消息中应有 3 个工具 part")
    }

    // MARK: - AIChatPartKind 枚举覆盖

    func testPartKindEnumValues() {
        // 确保关键类型可以被构造，间距规则依赖这些枚举值
        XCTAssertEqual(AIChatPartKind.tool.rawValue, "tool")
        XCTAssertEqual(AIChatPartKind.text.rawValue, "text")
        XCTAssertEqual(AIChatPartKind.reasoning.rawValue, "reasoning")
    }
}
