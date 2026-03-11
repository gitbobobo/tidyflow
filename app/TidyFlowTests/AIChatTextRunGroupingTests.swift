import XCTest
@testable import TidyFlow

final class AIChatMessageDisplayNodeTests: XCTestCase {

    func testContiguousTextAndReasoningPartsRemainIndependentNodes() {
        let message = AIChatMessage(
            messageId: "m1",
            role: .assistant,
            parts: [
                AIChatPart(id: "r1", kind: .reasoning, text: "先分析问题"),
                AIChatPart(id: "t1", kind: .text, text: "再给出结论"),
                AIChatPart(id: "tool", kind: .tool, toolName: "bash"),
                AIChatPart(id: "t2", kind: .text, text: "收尾说明"),
            ]
        )

        let nodes = AIChatMessageLayoutSemantics.displayNodes(for: message, pendingQuestions: [:])
        XCTAssertEqual(nodes.map(\.part.id), ["r1", "t1", "tool", "t2"])
        XCTAssertEqual(nodes.map(\.part.kind), [.reasoning, .text, .tool, .text])
    }

    func testWhitespaceOnlyTextDoesNotCreateDisplayNode() {
        let message = AIChatMessage(
            messageId: "m2",
            role: .assistant,
            parts: [
                AIChatPart(id: "empty", kind: .text, text: " \n "),
                AIChatPart(id: "tool", kind: .tool, toolName: "read_file"),
            ]
        )

        let nodes = AIChatMessageLayoutSemantics.displayNodes(for: message, pendingQuestions: [:])
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].part.kind, .tool)
    }
}
