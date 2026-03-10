import XCTest
@testable import TidyFlow

final class AIChatPendingInteractionProjectionTests: XCTestCase {

    func testLatestPendingQuestionBecomesActiveInteraction() {
        let firstRequest = makeRequest(id: "req-1", sessionId: "s1", title: "计划已就绪")
        let secondRequest = makeRequest(id: "req-2", sessionId: "s1", title: "需要权限")

        let messages = [
            makeInteractiveQuestionMessage(
                messageId: "m1",
                toolCallId: "call-1",
                request: firstRequest
            ),
            makeInteractiveQuestionMessage(
                messageId: "m2",
                toolCallId: "call-2",
                request: secondRequest
            ),
        ]

        let queue = AIChatMessageLayoutSemantics.pendingInteractionQueue(
            messages: messages,
            pendingQuestions: [
                "call-1": firstRequest,
                "call-2": secondRequest,
            ]
        )

        XCTAssertEqual(queue.active?.id, "req-2")
        XCTAssertEqual(queue.queuedCount, 1)
        XCTAssertEqual(queue.queued.first?.id, "req-1")
    }

    func testPendingInteractiveQuestionIsRemovedFromTranscriptNodes() {
        let request = makeRequest(id: "req-3", sessionId: "s1", title: "请确认")
        let message = makeInteractiveQuestionMessage(
            messageId: "m3",
            toolCallId: "call-3",
            request: request
        )

        let nodes = AIChatMessageLayoutSemantics.displayNodes(
            for: message,
            pendingQuestions: ["call-3": request]
        )

        XCTAssertTrue(nodes.isEmpty, "待处理交互不应继续出现在消息流")
    }

    private func makeRequest(id: String, sessionId: String, title: String) -> AIQuestionRequestInfo {
        AIQuestionRequestInfo(
            id: id,
            sessionId: sessionId,
            questions: [
                AIQuestionInfo(
                    question: title,
                    header: title,
                    options: [
                        AIQuestionOptionInfo(optionID: "yes", label: "是", description: "")
                    ],
                    multiple: false,
                    custom: false
                )
            ],
            toolMessageId: "tool-\(id)",
            toolCallId: "call-\(id)"
        )
    }

    private func makeInteractiveQuestionMessage(
        messageId: String,
        toolCallId: String,
        request: AIQuestionRequestInfo
    ) -> AIChatMessage {
        let question = AIToolViewQuestion(
            requestID: request.id,
            toolMessageID: request.toolMessageId,
            promptItems: request.questions,
            interactive: true,
            answers: nil
        )
        let toolView = AIToolView(
            status: .pending,
            displayTitle: "question",
            statusText: "pending",
            summary: nil,
            headerCommandSummary: nil,
            durationMs: nil,
            sections: [],
            locations: [],
            question: question,
            linkedSession: nil
        )
        let part = AIChatPart(
            id: "part-\(request.id)",
            kind: .tool,
            text: nil,
            mime: nil,
            filename: nil,
            url: nil,
            synthetic: nil,
            ignored: nil,
            source: nil,
            toolName: "question",
            toolCallId: toolCallId,
            toolView: toolView
        )
        return AIChatMessage(
            messageId: messageId,
            role: .assistant,
            parts: [part],
            isStreaming: false
        )
    }
}
