import XCTest
@testable import TidyFlow

#if os(macOS)
final class TerminalOutputReentrancyRegressionTests: XCTestCase {
    func testReentrantTerminalOutputDuringFlushDoesNotDropBufferedChunks() {
        let appState = AppState()
        defer {
            tearDownAppState(appState)
        }

        let tabId = UUID()
        let termId = "term-reentrant"
        let sink = ReentrantTerminalSink()
        sink.onWrite = { [weak appState, weak sink] in
            guard let appState, let sink else { return }
            guard sink.received.count == 1 else { return }
            appState.handleTerminalOutput(termId: termId, bytes: Array("world".utf8))
        }

        let flushed = expectation(description: "等待重入输出完成第二次 flush")

        DispatchQueue.main.async {
            appState.terminalSessionByTabId[tabId] = termId
            appState.terminalTabIdBySessionId[termId] = tabId
            appState.attachTerminalSink(sink, tabId: tabId)
            appState.handleTerminalOutput(termId: termId, bytes: Array("hello".utf8))

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                XCTAssertEqual(sink.received, ["hello", "world"])
                XCTAssertTrue(appState.pendingTerminalOutputByTermId[termId]?.isEmpty ?? true)
                flushed.fulfill()
            }
        }

        wait(for: [flushed], timeout: 1.0)
    }
}

private final class ReentrantTerminalSink: MacTerminalOutputSink {
    var received: [String] = []
    var onWrite: (() -> Void)?

    func writeOutput(_ bytes: [UInt8]) {
        received.append(String(decoding: bytes, as: UTF8.self))
        onWrite?()
    }

    func focusTerminal() {}

    func resetTerminal() {}
}
#endif
