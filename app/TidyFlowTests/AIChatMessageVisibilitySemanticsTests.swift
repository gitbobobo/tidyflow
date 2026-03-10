import XCTest
@testable import TidyFlow

final class AIChatMessageVisibilitySemanticsTests: XCTestCase {

    func testCompletedReasoningOnlyAssistantMessageRemainsRenderable() {
        let message = AIChatMessage(
            messageId: "m1",
            role: .assistant,
            parts: [
                AIChatPart(id: "r1", kind: .reasoning, text: "这里是思考内容")
            ],
            isStreaming: false
        )

        XCTAssertTrue(
            AIChatMessageLayoutSemantics.hasRenderableContent(in: message, pendingQuestions: [:]),
            "移除隐藏逻辑后，完成态 reasoning 也应显示"
        )
    }

    func testCompletedCommentaryLikeTextMessageRemainsRenderable() {
        let message = AIChatMessage(
            messageId: "m2",
            role: .assistant,
            parts: [
                AIChatPart(
                    id: "t1",
                    kind: .text,
                    text: "这是一段 commentary",
                    source: ["vendor": "codex", "message_phase": "commentary"]
                )
            ],
            isStreaming: false
        )

        let nodes = AIChatMessageLayoutSemantics.displayNodes(for: message, pendingQuestions: [:])
        XCTAssertEqual(nodes.count, 1)
        guard case .textGroup = nodes[0] else {
            return XCTFail("commentary 文本现在应进入普通文本文档链路")
        }
    }

    func testAnsweredQuestionToolPartReturnsToTranscript() {
        let question = AIToolViewQuestion(
            requestID: "req-1",
            toolMessageID: "tool-1",
            promptItems: [
                AIQuestionInfo(
                    question: "是否继续？",
                    header: "需要确认",
                    options: [AIQuestionOptionInfo(optionID: "go", label: "继续", description: "")],
                    multiple: false,
                    custom: false
                )
            ],
            interactive: false,
            answers: [["继续"]]
        )
        let toolView = AIToolView(
            status: .completed,
            displayTitle: "question",
            statusText: "completed",
            summary: nil,
            headerCommandSummary: nil,
            durationMs: nil,
            sections: [],
            locations: [],
            question: question,
            linkedSession: nil
        )
        let message = AIChatMessage(
            messageId: "m3",
            role: .assistant,
            parts: [
                AIChatPart(
                    id: "part-1",
                    kind: .tool,
                    text: nil,
                    mime: nil,
                    filename: nil,
                    url: nil,
                    synthetic: nil,
                    ignored: nil,
                    source: nil,
                    toolName: "question",
                    toolCallId: "call-1",
                    toolView: toolView
                )
            ],
            isStreaming: false
        )

        let nodes = AIChatMessageLayoutSemantics.displayNodes(for: message, pendingQuestions: [:])
        XCTAssertEqual(nodes.count, 1)
        guard case .part(let part) = nodes[0] else {
            return XCTFail("已完成的 question 应回到消息流")
        }
        XCTAssertEqual(part.kind, .tool)
    }
}
