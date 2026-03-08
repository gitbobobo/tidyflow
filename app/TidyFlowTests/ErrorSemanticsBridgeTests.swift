import XCTest
@testable import TidyFlow

// MARK: - 共享错误语义桥接回归测试
//
// 覆盖目标：
// 1. CoreErrorCode 枚举的解析与分类行为
// 2. CoreError 从 JSON payload 的解析（通用错误 & EvoError）
// 3. CoreError 多工作区归属过滤（belongsTo）
// 4. AIChatErrorV2 携带结构化错误码
// 5. 错误码可恢复性分类一致性（macOS/iOS 语义不漂移）

final class ErrorSemanticsBridgeTests: XCTestCase {

    // MARK: - CoreErrorCode 解析

    func testParsesKnownErrorCodes() {
        XCTAssertEqual(CoreErrorCode.parse("project_not_found"), .projectNotFound)
        XCTAssertEqual(CoreErrorCode.parse("workspace_not_found"), .workspaceNotFound)
        XCTAssertEqual(CoreErrorCode.parse("git_error"), .gitError)
        XCTAssertEqual(CoreErrorCode.parse("file_error"), .fileError)
        XCTAssertEqual(CoreErrorCode.parse("internal_error"), .internalError)
        XCTAssertEqual(CoreErrorCode.parse("ai_session_error"), .aiSessionError)
        XCTAssertEqual(CoreErrorCode.parse("evolution_error"), .evolutionError)
        XCTAssertEqual(CoreErrorCode.parse("artifact_contract_violation"), .artifactContractViolation)
        XCTAssertEqual(CoreErrorCode.parse("error"), .unknown)
    }

    func testParsesUnknownCodeAsFallback() {
        XCTAssertEqual(CoreErrorCode.parse("some_future_code"), .unknown)
        XCTAssertEqual(CoreErrorCode.parse(nil), .unknown)
        XCTAssertEqual(CoreErrorCode.parse(""), .unknown)
    }

    func testRawValuePreserved() {
        XCTAssertEqual(CoreErrorCode.projectNotFound.rawValue, "project_not_found")
        XCTAssertEqual(CoreErrorCode.aiSessionError.rawValue, "ai_session_error")
        XCTAssertEqual(CoreErrorCode.evolutionError.rawValue, "evolution_error")
    }

    // MARK: - CoreErrorCode 可恢复性分类

    func testRecoverableErrors() {
        XCTAssertTrue(CoreErrorCode.projectNotFound.isRecoverable)
        XCTAssertTrue(CoreErrorCode.workspaceNotFound.isRecoverable)
        XCTAssertTrue(CoreErrorCode.wsNotConnected.isRecoverable)
        XCTAssertTrue(CoreErrorCode.wsReceiveError.isRecoverable)
    }

    func testNonRecoverableErrors() {
        XCTAssertFalse(CoreErrorCode.gitError.isRecoverable)
        XCTAssertFalse(CoreErrorCode.aiSessionError.isRecoverable)
        XCTAssertFalse(CoreErrorCode.evolutionError.isRecoverable)
        XCTAssertFalse(CoreErrorCode.artifactContractViolation.isRecoverable)
        XCTAssertFalse(CoreErrorCode.internalError.isRecoverable)
    }

    /// macOS 与 iOS 对同一错误码的可恢复性判断必须一致（通过 CoreErrorCode 共享，不再各自判断）
    func testRecoverabilityIsSharedAcrossPlatforms() {
        // 可恢复错误集合（测试不同端不会重新分叉）
        let recoverableCodes: [CoreErrorCode] = [.projectNotFound, .workspaceNotFound, .wsNotConnected]
        let nonRecoverableCodes: [CoreErrorCode] = [.gitError, .aiSessionError, .evolutionError, .internalError]

        for code in recoverableCodes {
            XCTAssertTrue(code.isRecoverable, "\(code.rawValue) 应为可恢复错误")
        }
        for code in nonRecoverableCodes {
            XCTAssertFalse(code.isRecoverable, "\(code.rawValue) 应为不可恢复错误")
        }
    }

    // MARK: - CoreError 通用 JSON 解析

    func testParsesErrorPayloadWithAllFields() {
        let json: [String: Any] = [
            "code": "project_not_found",
            "message": "Project 'foo' not found",
            "project": "foo",
            "workspace": "default",
            "session_id": "sess-123",
            "cycle_id": "2026-03-08T06-39-28-187Z"
        ]
        let error = CoreError.from(json: json)
        XCTAssertEqual(error.code, .projectNotFound)
        XCTAssertEqual(error.message, "Project 'foo' not found")
        XCTAssertEqual(error.project, "foo")
        XCTAssertEqual(error.workspace, "default")
        XCTAssertEqual(error.sessionId, "sess-123")
        XCTAssertEqual(error.cycleId, "2026-03-08T06-39-28-187Z")
    }

    func testParsesErrorPayloadWithMissingOptionalFields() {
        let json: [String: Any] = [
            "code": "internal_error",
            "message": "Something went wrong"
        ]
        let error = CoreError.from(json: json)
        XCTAssertEqual(error.code, .internalError)
        XCTAssertNil(error.project)
        XCTAssertNil(error.workspace)
        XCTAssertNil(error.sessionId)
        XCTAssertNil(error.cycleId)
    }

    func testParsesErrorPayloadWithMissingCode() {
        let json: [String: Any] = [
            "message": "Unknown failure"
        ]
        let error = CoreError.from(json: json)
        XCTAssertEqual(error.code, .unknown)
        XCTAssertEqual(error.message, "Unknown failure")
    }

    // MARK: - CoreError EvoError JSON 解析

    func testParsesEvoErrorPayload() {
        let json: [String: Any] = [
            "code": "artifact_contract_violation",
            "message": "Artifact format invalid",
            "project": "myproject",
            "workspace": "feature-x",
            "cycle_id": "2026-03-08T06-39-28-187Z",
            "source": "implement.general.1",
            "ts": "2026-03-08T06:45:00.000+00:00"
        ]
        let error = CoreError.fromEvoError(json: json)
        XCTAssertEqual(error.code, .artifactContractViolation)
        XCTAssertEqual(error.project, "myproject")
        XCTAssertEqual(error.workspace, "feature-x")
        XCTAssertEqual(error.cycleId, "2026-03-08T06-39-28-187Z")
        XCTAssertNil(error.sessionId)
    }

    func testParsesEvoErrorFallsBackToEvolutionError() {
        // 当 evo_error 没有 code 字段时，应使用 evolution_error 作为默认码
        let json: [String: Any] = [
            "message": "Evolution stage failed",
            "project": "myproject"
        ]
        let error = CoreError.fromEvoError(json: json)
        XCTAssertEqual(error.code, .evolutionError)
    }

    // MARK: - CoreError 多工作区归属过滤

    func testBelongsToWithMatchingProjectAndWorkspace() {
        let error = CoreError(
            code: .aiSessionError,
            message: "AI error",
            project: "proj-a",
            workspace: "ws-1"
        )
        XCTAssertTrue(error.belongsTo(project: "proj-a", workspace: "ws-1"))
    }

    func testDoesNotBelongToWithDifferentProject() {
        let error = CoreError(
            code: .evolutionError,
            message: "Evolution error",
            project: "proj-a",
            workspace: "ws-1"
        )
        XCTAssertFalse(error.belongsTo(project: "proj-b", workspace: "ws-1"))
    }

    func testDoesNotBelongToWithDifferentWorkspace() {
        let error = CoreError(
            code: .evolutionError,
            message: "Evolution error",
            project: "proj-a",
            workspace: "ws-1"
        )
        XCTAssertFalse(error.belongsTo(project: "proj-a", workspace: "ws-2"))
    }

    func testBelongsToWithNilContextInError() {
        // 错误没有归属上下文（如全局错误），应匹配所有工作区
        let error = CoreError(code: .internalError, message: "Internal")
        XCTAssertTrue(error.belongsTo(project: "any-project", workspace: "any-workspace"))
        XCTAssertTrue(error.belongsTo(project: nil, workspace: nil))
    }

    func testBelongsToWithNilCurrentContext() {
        // 当前没有选中工作区时，无法过滤，应允许错误通过
        let error = CoreError(
            code: .projectNotFound,
            message: "Not found",
            project: "proj-a",
            workspace: "ws-1"
        )
        XCTAssertTrue(error.belongsTo(project: nil, workspace: nil))
    }

    // MARK: - AIChatErrorV2 错误码携带

    func testAIChatErrorV2ParsesErrorCode() {
        let json: [String: Any] = [
            "project_name": "myproject",
            "workspace_name": "default",
            "ai_tool": "opencode",
            "session_id": "sess-123",
            "error": "Context window exceeded",
            "error_code": "ai_session_error"
        ]
        let ev = AIChatErrorV2.from(json: json)
        XCTAssertNotNil(ev)
        XCTAssertEqual(ev?.errorCode, .aiSessionError)
        XCTAssertEqual(ev?.sessionId, "sess-123")
    }

    func testAIChatErrorV2FallsBackToAISessionError() {
        // 当 error_code 字段缺失时，应默认为 ai_session_error
        let json: [String: Any] = [
            "project_name": "myproject",
            "workspace_name": "default",
            "ai_tool": "opencode",
            "session_id": "sess-456",
            "error": "Some failure"
        ]
        let ev = AIChatErrorV2.from(json: json)
        XCTAssertNotNil(ev)
        XCTAssertEqual(ev?.errorCode, .aiSessionError)
    }

    func testAIChatErrorV2RequiresWorkspaceContext() {
        // 验证 AI 错误码在 requiresWorkspaceContext 分类中
        XCTAssertTrue(CoreErrorCode.aiSessionError.requiresWorkspaceContext)
        XCTAssertTrue(CoreErrorCode.evolutionError.requiresWorkspaceContext)
        XCTAssertTrue(CoreErrorCode.projectNotFound.requiresWorkspaceContext)
        XCTAssertFalse(CoreErrorCode.internalError.requiresWorkspaceContext)
    }
}
