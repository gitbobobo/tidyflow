import XCTest
@testable import TidyFlowShared

/// 编辑器格式化语义层测试：覆盖请求构建、结果回放、格式化状态生命周期、
/// 能力更新、配置编解码与 Core 错误码对齐。
final class EditorFormattingTests: XCTestCase {

    // MARK: - 请求构建（整文档）

    func testBuildDocumentRequest() {
        let key = EditorDocumentKey(project: "proj", workspace: "ws", path: "main.swift")
        let session = EditorDocumentSession(key: key, content: "let x = 1\n")
        let request = EditorFormattingRequestBuilder.buildDocumentRequest(session: session)

        XCTAssertEqual(request.project, "proj")
        XCTAssertEqual(request.workspace, "ws")
        XCTAssertEqual(request.path, "main.swift")
        XCTAssertEqual(request.scope, .document)
        XCTAssertEqual(request.text, "let x = 1\n")
        XCTAssertNil(request.selectionStart)
        XCTAssertNil(request.selectionEnd)
    }

    // MARK: - 请求构建（选区）

    func testBuildSelectionRequestWithZeroSelection() {
        let key = EditorDocumentKey(project: "proj", workspace: "ws", path: "main.swift")
        let session = EditorDocumentSession(key: key, content: "let x = 1\n", selectionSet: .zero)
        let request = EditorFormattingRequestBuilder.buildSelectionRequest(session: session)
        XCTAssertNil(request, "零长度选区不应生成选区格式化请求")
    }

    func testBuildSelectionRequestWithValidSelection() {
        let key = EditorDocumentKey(project: "proj", workspace: "ws", path: "main.swift")
        let sel = EditorSelectionSet.single(location: 4, length: 5)
        let session = EditorDocumentSession(key: key, content: "let x = 1\n", selectionSet: sel)
        let request = EditorFormattingRequestBuilder.buildSelectionRequest(session: session)

        XCTAssertNotNil(request)
        XCTAssertEqual(request?.scope, .selection)
        XCTAssertEqual(request?.selectionStart, 4)
        XCTAssertEqual(request?.selectionEnd, 9)
    }

    func testBuildDocumentRequestFromMultiProjectIsolation() {
        let keyA = EditorDocumentKey(project: "projA", workspace: "dev", path: "main.swift")
        let keyB = EditorDocumentKey(project: "projB", workspace: "dev", path: "main.swift")
        let sessionA = EditorDocumentSession(key: keyA, content: "A")
        let sessionB = EditorDocumentSession(key: keyB, content: "B")

        let reqA = EditorFormattingRequestBuilder.buildDocumentRequest(session: sessionA)
        let reqB = EditorFormattingRequestBuilder.buildDocumentRequest(session: sessionB)

        XCTAssertEqual(reqA.project, "projA")
        XCTAssertEqual(reqB.project, "projB")
        XCTAssertNotEqual(reqA.text, reqB.text)
    }

    // MARK: - 结果回放——无变化

    func testApplyFormatResultNoChange() {
        let result = EditorFormattingResult(
            project: "p", workspace: "w", path: "f.rs",
            formattedText: "same text",
            formatterId: "rustfmt",
            scope: .document,
            changed: false
        )
        let applied = EditorFormattingResultApplier.applyFormatResult(
            result: result,
            currentText: "same text",
            currentSelections: .zero,
            history: .empty
        )
        XCTAssertNil(applied, "文本未变化时不应生成历史记录")
    }

    // MARK: - 结果回放——单条撤销命令

    func testApplyFormatResultSingleUndoCommand() {
        let originalText = "fn   main(){}"
        let formattedText = "fn main() {}\n"
        let result = EditorFormattingResult(
            project: "p", workspace: "w", path: "main.rs",
            formattedText: formattedText,
            formatterId: "rustfmt",
            scope: .document,
            changed: true
        )
        let sel = EditorSelectionSet.single(location: 3, length: 0)
        let applied = EditorFormattingResultApplier.applyFormatResult(
            result: result,
            currentText: originalText,
            currentSelections: sel,
            history: .empty
        )

        XCTAssertNotNil(applied)
        XCTAssertEqual(applied!.text, formattedText)
        XCTAssertTrue(applied!.canUndo)
        XCTAssertFalse(applied!.canRedo)
        XCTAssertEqual(applied!.history.undoStack.count, 1, "格式化应生成恰好一条撤销记录")
    }

    // MARK: - 结果回放然后撤销

    func testApplyFormatResultThenUndo() {
        let originalText = "fn   main(){}"
        let formattedText = "fn main() {}\n"
        let result = EditorFormattingResult(
            project: "p", workspace: "w", path: "main.rs",
            formattedText: formattedText,
            formatterId: "rustfmt",
            scope: .document,
            changed: true
        )
        let sel = EditorSelectionSet.single(location: 0, length: 0)
        let applied = EditorFormattingResultApplier.applyFormatResult(
            result: result,
            currentText: originalText,
            currentSelections: sel,
            history: .empty
        )!

        // 撤销应恢复原始文本
        let undone = EditorUndoHistorySemantics.undo(
            currentText: applied.text,
            history: applied.history
        )
        XCTAssertNotNil(undone)
        XCTAssertEqual(undone!.text, originalText)
        XCTAssertFalse(undone!.canUndo)
        XCTAssertTrue(undone!.canRedo)
    }

    // MARK: - 格式化状态生命周期

    func testFormattingStateInitiallyIdle() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.swift")
        let session = EditorDocumentSession(key: key, content: "")

        XCTAssertFalse(session.isFormatting)
        XCTAssertNil(session.lastFormattingError)
        XCTAssertTrue(session.supportedFormattingScopes.isEmpty)
    }

    func testFormattingStateStartedAndCompleted() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.swift")
        var session = EditorDocumentSession(key: key, content: "")

        session.markFormattingStarted()
        XCTAssertTrue(session.isFormatting)
        XCTAssertNil(session.lastFormattingError, "开始格式化时应清除之前的错误")

        session.markFormattingCompleted()
        XCTAssertFalse(session.isFormatting)
    }

    func testFormattingStateFailed() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.swift")
        var session = EditorDocumentSession(key: key, content: "")

        session.markFormattingStarted()
        let error = EditorFormattingError(
            project: "p", workspace: "w", path: "f.swift",
            errorCode: .toolUnavailable, message: "swift-format not found"
        )
        session.markFormattingFailed(error: error)

        XCTAssertFalse(session.isFormatting)
        XCTAssertEqual(session.lastFormattingError?.errorCode, .toolUnavailable)
        XCTAssertEqual(session.lastFormattingError?.message, "swift-format not found")
    }

    func testFormattingStartClearsLastError() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.swift")
        var session = EditorDocumentSession(key: key, content: "")

        // 先制造一次失败
        let error = EditorFormattingError(
            project: "p", workspace: "w", path: "f.swift",
            errorCode: .executionFailed, message: "timeout"
        )
        session.markFormattingFailed(error: error)
        XCTAssertNotNil(session.lastFormattingError)

        // 再次开始应清除
        session.markFormattingStarted()
        XCTAssertNil(session.lastFormattingError)
    }

    // MARK: - 能力更新

    func testUpdateFormattingCapabilities() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.swift")
        var session = EditorDocumentSession(key: key, content: "")

        let caps = [
            EditorFormattingCapability(
                formatterId: "swift-format",
                language: "swift",
                supportedScopes: [.document]
            )
        ]
        session.updateFormattingCapabilities(caps)
        XCTAssertEqual(session.supportedFormattingScopes, [.document])
    }

    func testUpdateFormattingCapabilitiesMultipleFormatters() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.swift")
        var session = EditorDocumentSession(key: key, content: "")

        let caps = [
            EditorFormattingCapability(
                formatterId: "fmt-a",
                language: "swift",
                supportedScopes: [.document]
            ),
            EditorFormattingCapability(
                formatterId: "fmt-b",
                language: "swift",
                supportedScopes: [.document, .selection]
            ),
        ]
        session.updateFormattingCapabilities(caps)
        // 去重后应包含两种作用域
        XCTAssertTrue(session.supportedFormattingScopes.contains(.document))
        XCTAssertTrue(session.supportedFormattingScopes.contains(.selection))
    }

    func testUpdateFormattingCapabilitiesEmptyClearsScopes() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.swift")
        var session = EditorDocumentSession(key: key, content: "")

        // 先设置有能力
        let caps = [
            EditorFormattingCapability(
                formatterId: "swift-format",
                language: "swift",
                supportedScopes: [.document]
            )
        ]
        session.updateFormattingCapabilities(caps)
        XCTAssertFalse(session.supportedFormattingScopes.isEmpty)

        // 空能力应清空
        session.updateFormattingCapabilities([])
        XCTAssertTrue(session.supportedFormattingScopes.isEmpty)
    }

    // MARK: - dirty 状态与格式化交互

    func testDirtyStateAfterFormat() {
        let key = EditorDocumentKey(project: "p", workspace: "w", path: "f.rs")
        let originalText = "fn main(){}"
        var session = EditorDocumentSession(key: key)
        session.applyLoadSuccess(content: originalText)
        XCTAssertFalse(session.isDirty)

        // 模拟格式化改变了文本
        let formattedText = "fn main() {}\n"
        session.applyContentEdit(formattedText)
        XCTAssertTrue(session.isDirty, "格式化导致的内容变化应使文档变 dirty")
    }

    // MARK: - 配置编解码

    func testFormattingLanguageConfigCoding() throws {
        let config = EditorFormattingLanguageConfig(
            language: "swift",
            preferredFormatterId: "swift-format",
            formatOnSave: false,
            allowFullDocumentFallback: false,
            extraArgs: ["--indent-width", "4"]
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(EditorFormattingLanguageConfig.self, from: data)
        XCTAssertEqual(decoded.language, "swift")
        XCTAssertEqual(decoded.preferredFormatterId, "swift-format")
        XCTAssertFalse(decoded.formatOnSave)
        XCTAssertEqual(decoded.extraArgs, ["--indent-width", "4"])
    }

    func testFormattingLanguageConfigDefaults() throws {
        let json = #"{"language":"rust"}"#
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(EditorFormattingLanguageConfig.self, from: data)
        XCTAssertEqual(config.language, "rust")
        XCTAssertNil(config.preferredFormatterId)
        XCTAssertFalse(config.formatOnSave)
        XCTAssertFalse(config.allowFullDocumentFallback)
        XCTAssertTrue(config.extraArgs.isEmpty)
    }

    func testFormattingLanguageConfigFullFields() throws {
        let json = #"{"language":"swift","preferred_formatter_id":"swift-format","format_on_save":true,"allow_full_document_fallback":true,"extra_args":["--arg"]}"#
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(EditorFormattingLanguageConfig.self, from: data)
        XCTAssertEqual(config.language, "swift")
        XCTAssertEqual(config.preferredFormatterId, "swift-format")
        XCTAssertTrue(config.formatOnSave)
        XCTAssertTrue(config.allowFullDocumentFallback)
        XCTAssertEqual(config.extraArgs, ["--arg"])
    }

    // MARK: - 错误码对齐验证

    func testErrorCodeRawValues() {
        // 验证 Swift 错误码 rawValue 与 Core snake_case 字符串一致
        XCTAssertEqual(EditorFormattingErrorCode.unsupportedLanguage.rawValue, "unsupported_language")
        XCTAssertEqual(EditorFormattingErrorCode.toolUnavailable.rawValue, "tool_unavailable")
        XCTAssertEqual(EditorFormattingErrorCode.unsupportedScope.rawValue, "unsupported_scope")
        XCTAssertEqual(EditorFormattingErrorCode.workspaceUnavailable.rawValue, "workspace_unavailable")
        XCTAssertEqual(EditorFormattingErrorCode.executionFailed.rawValue, "execution_failed")
        XCTAssertEqual(EditorFormattingErrorCode.invalidRequest.rawValue, "invalid_request")
    }

    // MARK: - EditorFormatScope 对齐验证

    func testFormatScopeRawValues() {
        XCTAssertEqual(EditorFormatScope.document.rawValue, "document")
        XCTAssertEqual(EditorFormatScope.selection.rawValue, "selection")
    }

    // MARK: - EditorFormattingState 初始值

    func testFormattingStateIdle() {
        let state = EditorFormattingState.idle
        XCTAssertFalse(state.isFormatting)
        XCTAssertNil(state.lastFormattingError)
        XCTAssertTrue(state.supportedFormattingScopes.isEmpty)
    }

    // MARK: - EditorFormattingCapability 编解码

    func testFormattingCapabilityCoding() throws {
        let cap = EditorFormattingCapability(
            formatterId: "rustfmt",
            language: "rust",
            supportedScopes: [.document]
        )
        let data = try JSONEncoder().encode(cap)
        let decoded = try JSONDecoder().decode(EditorFormattingCapability.self, from: data)
        XCTAssertEqual(decoded.formatterId, "rustfmt")
        XCTAssertEqual(decoded.language, "rust")
        XCTAssertEqual(decoded.supportedScopes, [.document])
    }

    func testFormattingCapabilityCodingKeys() throws {
        // 验证 CodingKeys 与 Core 字段名一致（snake_case）
        let json = #"{"formatter_id":"swift-format","language":"swift","supported_scopes":["document","selection"]}"#
        let data = json.data(using: .utf8)!
        let cap = try JSONDecoder().decode(EditorFormattingCapability.self, from: data)
        XCTAssertEqual(cap.formatterId, "swift-format")
        XCTAssertEqual(cap.supportedScopes.count, 2)
    }

    // MARK: - EditorFormattingRequestContext 值相等

    func testRequestContextEquality() {
        let a = EditorFormattingRequestContext(
            project: "p", workspace: "w", path: "f.rs",
            scope: .document, text: "hello"
        )
        let b = EditorFormattingRequestContext(
            project: "p", workspace: "w", path: "f.rs",
            scope: .document, text: "hello"
        )
        XCTAssertEqual(a, b)

        let c = EditorFormattingRequestContext(
            project: "p", workspace: "w", path: "f.rs",
            scope: .selection, text: "hello", selectionStart: 0, selectionEnd: 5
        )
        XCTAssertNotEqual(a, c)
    }
}
