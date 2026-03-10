import XCTest
@testable import TidyFlow

final class AIChatTextRunGroupingTests: XCTestCase {

    func testContiguousTextAndReasoningPartsCollapseIntoSingleDocumentNode() {
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
        XCTAssertEqual(nodes.count, 3)

        guard case .textGroup(let firstGroup) = nodes[0] else {
            return XCTFail("首个节点应为连续文本文档块")
        }
        XCTAssertEqual(firstGroup.segments.map(\.id), ["r1", "t1"])
        XCTAssertTrue(firstGroup.combinedText.contains("先分析问题"))
        XCTAssertTrue(firstGroup.combinedText.contains("再给出结论"))

        guard case .part(let toolPart) = nodes[1] else {
            return XCTFail("第二个节点应为工具卡")
        }
        XCTAssertEqual(toolPart.kind, .tool)

        guard case .textGroup(let secondGroup) = nodes[2] else {
            return XCTFail("第三个节点应为新的文本文档块")
        }
        XCTAssertEqual(secondGroup.segments.map(\.id), ["t2"])
    }

    func testWhitespaceOnlyTextDoesNotCreateTextRunGroup() {
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
        guard case .part(let part) = nodes[0] else {
            return XCTFail("只应剩下工具节点")
        }
        XCTAssertEqual(part.kind, .tool)
    }

    func testReasoningMarkdownUsesBlockQuoteSyntax() {
        let group = AIChatTextRunGroup(
            id: "g1",
            segments: [
                AIChatTextRunSegment(id: "r1", kind: .reasoning, text: "先分析\n再拆解"),
                AIChatTextRunSegment(id: "t1", kind: .text, text: "最终回答")
            ]
        )

        XCTAssertEqual(
            group.markdownText(renderReasoningAsBlockQuote: true),
            """
            > 先分析
            > 再拆解

            最终回答
            """
        )
    }
}
