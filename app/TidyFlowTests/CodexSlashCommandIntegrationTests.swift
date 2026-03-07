import XCTest
@testable import TidyFlow

/// 覆盖 Codex slash command 补全与分发路径的集成测试：
/// - 6 个内置命令（new / code / explain / fix / review / ask）的协议层解析
/// - action 字段语义（client vs agent）
/// - inputHint 字段的存在性
/// - AISlashCommandsResult / AISlashCommandsUpdateResult 解析
/// - session 边界隔离（多工作区、多 session 场景）
/// - 命令前缀过滤（补全路径）
final class CodexSlashCommandIntegrationTests: XCTestCase {

    // MARK: - 内置命令协议层解析

    /// 验证 /new 命令：action=client，无 inputHint
    func testSlashCommandNewParsesAsClientAction() {
        let json: [String: Any] = [
            "name": "new",
            "description": "新建会话",
            "action": "client"
        ]
        let cmd = AIProtocolSlashCommand.from(json: json)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.name, "new")
        XCTAssertEqual(cmd?.action, "client")
        XCTAssertNil(cmd?.inputHint, "/new 不应有 inputHint")
    }

    /// 验证 /code 命令：action=agent，有 inputHint
    func testSlashCommandCodeParsesAsAgentAction() {
        let json: [String: Any] = [
            "name": "code",
            "description": "生成或修改代码",
            "action": "agent",
            "input": ["hint": "<任务描述>"]
        ]
        let cmd = AIProtocolSlashCommand.from(json: json)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.name, "code")
        XCTAssertEqual(cmd?.action, "agent")
        XCTAssertEqual(cmd?.inputHint, "<任务描述>")
    }

    /// 验证 /explain 命令：action=agent，有 inputHint
    func testSlashCommandExplainParsesAsAgentAction() {
        let json: [String: Any] = [
            "name": "explain",
            "description": "解释代码或概念",
            "action": "agent",
            "input": ["hint": "<代码或概念>"]
        ]
        let cmd = AIProtocolSlashCommand.from(json: json)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.name, "explain")
        XCTAssertEqual(cmd?.action, "agent")
        XCTAssertEqual(cmd?.inputHint, "<代码或概念>")
    }

    /// 验证 /fix 命令：action=agent，有 inputHint
    func testSlashCommandFixParsesAsAgentAction() {
        let json: [String: Any] = [
            "name": "fix",
            "description": "修复错误或问题",
            "action": "agent",
            "input_hint": "<错误描述>"
        ]
        let cmd = AIProtocolSlashCommand.from(json: json)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.name, "fix")
        XCTAssertEqual(cmd?.action, "agent")
        XCTAssertEqual(cmd?.inputHint, "<错误描述>")
    }

    /// 验证 /review 命令：action=agent，有 inputHint
    func testSlashCommandReviewParsesAsAgentAction() {
        let json: [String: Any] = [
            "name": "review",
            "description": "审查代码质量与风格",
            "action": "agent",
            "input": ["hint": "<代码片段或文件路径>"]
        ]
        let cmd = AIProtocolSlashCommand.from(json: json)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.name, "review")
        XCTAssertEqual(cmd?.action, "agent")
        XCTAssertEqual(cmd?.inputHint, "<代码片段或文件路径>")
    }

    /// 验证 /ask 命令：action=agent，有 inputHint
    func testSlashCommandAskParsesAsAgentAction() {
        let json: [String: Any] = [
            "name": "ask",
            "description": "向 Codex 提问",
            "action": "agent",
            "hint": "<问题>"
        ]
        let cmd = AIProtocolSlashCommand.from(json: json)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.name, "ask")
        XCTAssertEqual(cmd?.action, "agent")
        XCTAssertEqual(cmd?.inputHint, "<问题>")
    }

    /// 验证 name 缺失时解析返回 nil
    func testSlashCommandReturnsNilWhenNameMissing() {
        let cmd = AIProtocolSlashCommand.from(json: [:])
        XCTAssertNil(cmd, "name 缺失时不应返回有效命令")
    }

    /// 验证 action 字段缺失时默认为 "client"
    func testSlashCommandDefaultActionIsClient() {
        let cmd = AIProtocolSlashCommand.from(json: ["name": "custom"])
        XCTAssertEqual(cmd?.action, "client", "action 缺失时默认应为 client")
    }

    // MARK: - 全量命令批量解析

    /// 验证完整的 6 条内置命令列表都能被正确解析
    func testAllSixBuiltinCommandsParseCorrectly() {
        let commandPayloads: [[String: Any]] = [
            ["name": "new",     "description": "新建会话",        "action": "client"],
            ["name": "code",    "description": "生成或修改代码",   "action": "agent", "input": ["hint": "<任务描述>"]],
            ["name": "explain", "description": "解释代码或概念",   "action": "agent", "input": ["hint": "<代码或概念>"]],
            ["name": "fix",     "description": "修复错误或问题",   "action": "agent", "input": ["hint": "<错误描述>"]],
            ["name": "review",  "description": "审查代码质量与风格","action": "agent", "input": ["hint": "<代码片段或文件路径>"]],
            ["name": "ask",     "description": "向 Codex 提问",   "action": "agent", "input": ["hint": "<问题>"]],
        ]
        let parsed = commandPayloads.compactMap { AIProtocolSlashCommand.from(json: $0) }
        XCTAssertEqual(parsed.count, 6, "6 条内置命令应全部解析成功")

        let clientCommands = parsed.filter { $0.action == "client" }
        let agentCommands  = parsed.filter { $0.action == "agent" }
        XCTAssertEqual(clientCommands.count, 1, "只有 /new 是 client action")
        XCTAssertEqual(agentCommands.count, 5, "其余 5 条均为 agent action")

        // agent 命令都应有 inputHint
        for cmd in agentCommands {
            XCTAssertNotNil(cmd.inputHint, "/\(cmd.name) 应有 inputHint")
        }
    }

    // MARK: - AISlashCommandsResult 解析

    /// 验证不含 session_id 的 AISlashCommandsResult 解析（标准 HTTP 读取场景）
    func testSlashCommandsResultParsesWithoutSessionID() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "codex",
            "commands": [
                ["name": "new", "action": "client"],
                ["name": "code", "action": "agent"]
            ]
        ]
        let result = AISlashCommandsResult.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.projectName, "tidyflow")
        XCTAssertEqual(result?.workspaceName, "default")
        XCTAssertEqual(result?.aiTool, .codex)
        XCTAssertNil(result?.sessionID, "不含 session_id 时 sessionID 应为 nil")
        XCTAssertEqual(result?.commands.count, 2)
    }

    /// 验证含 session_id 的 AISlashCommandsResult 解析（会话级缓存场景）
    func testSlashCommandsResultParsesWithSessionID() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "ws1",
            "ai_tool": "codex",
            "session_id": "s-abc",
            "commands": [
                ["name": "new", "action": "client"],
                ["name": "ask", "action": "agent", "input": ["hint": "<问题>"]]
            ]
        ]
        let result = AISlashCommandsResult.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.sessionID, "s-abc")
        XCTAssertEqual(result?.commands.count, 2)
    }

    /// 验证 commands 为空时仍能解析
    func testSlashCommandsResultParsesEmptyCommands() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "codex",
            "commands": []
        ]
        let result = AISlashCommandsResult.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.commands.isEmpty ?? false)
    }

    /// 验证必填字段缺失时返回 nil
    func testSlashCommandsResultReturnsNilWhenRequiredFieldsMissing() {
        let noProject: [String: Any] = ["workspace_name": "ws", "ai_tool": "codex"]
        let noTool: [String: Any] = ["project_name": "p", "workspace_name": "ws"]
        XCTAssertNil(AISlashCommandsResult.from(json: noProject))
        XCTAssertNil(AISlashCommandsResult.from(json: noTool))
    }

    // MARK: - AISlashCommandsUpdateResult 解析

    /// 验证 AISlashCommandsUpdateResult（WS 推送更新）包含 session_id
    func testSlashCommandsUpdateResultParsesSessionID() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "codex",
            "session_id": "s-live",
            "commands": [
                ["name": "fix", "action": "agent", "input": ["hint": "<错误描述>"]]
            ]
        ]
        let result = AISlashCommandsUpdateResult.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.sessionID, "s-live")
        XCTAssertEqual(result?.commands.count, 1)
        XCTAssertEqual(result?.commands.first?.name, "fix")
    }

    /// 验证 session_id 缺失时 AISlashCommandsUpdateResult 返回 nil
    func testSlashCommandsUpdateResultReturnsNilWhenSessionIDMissing() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "codex",
            "commands": [["name": "fix", "action": "agent"]]
        ]
        XCTAssertNil(AISlashCommandsUpdateResult.from(json: json),
                     "session_id 缺失时 update result 不应解析成功")
    }

    // MARK: - 多工作区 session 隔离

    /// 验证不同工作区的命令列表彼此独立，不因解析顺序产生交叉污染
    func testMultiWorkspaceSlashCommandsAreIndependent() {
        let jsonWs1: [String: Any] = [
            "project_name": "project-a",
            "workspace_name": "ws1",
            "ai_tool": "codex",
            "session_id": "s-ws1",
            "commands": [["name": "new", "action": "client"]]
        ]
        let jsonWs2: [String: Any] = [
            "project_name": "project-b",
            "workspace_name": "ws2",
            "ai_tool": "codex",
            "session_id": "s-ws2",
            "commands": [
                ["name": "code",    "action": "agent"],
                ["name": "explain", "action": "agent"]
            ]
        ]

        let ws1 = AISlashCommandsResult.from(json: jsonWs1)
        let ws2 = AISlashCommandsResult.from(json: jsonWs2)

        XCTAssertEqual(ws1?.workspaceName, "ws1")
        XCTAssertEqual(ws2?.workspaceName, "ws2")
        XCTAssertEqual(ws1?.sessionID, "s-ws1")
        XCTAssertEqual(ws2?.sessionID, "s-ws2")
        XCTAssertEqual(ws1?.commands.count, 1)
        XCTAssertEqual(ws2?.commands.count, 2)
        // 两个工作区的命令列表不交叉
        XCTAssertNotEqual(ws1?.sessionID, ws2?.sessionID)
    }

    /// 验证同一工作区不同 session 的命令结果不互相覆盖（通过 sessionID 区分）
    func testSameWorkspaceDifferentSessionsAreIsolated() {
        let sessionA: [String: Any] = [
            "project_name": "p",
            "workspace_name": "ws",
            "ai_tool": "codex",
            "session_id": "s-a",
            "commands": [["name": "code", "action": "agent"]]
        ]
        let sessionB: [String: Any] = [
            "project_name": "p",
            "workspace_name": "ws",
            "ai_tool": "codex",
            "session_id": "s-b",
            "commands": [["name": "fix", "action": "agent"]]
        ]

        let resultA = AISlashCommandsResult.from(json: sessionA)
        let resultB = AISlashCommandsResult.from(json: sessionB)

        XCTAssertEqual(resultA?.sessionID, "s-a")
        XCTAssertEqual(resultB?.sessionID, "s-b")
        XCTAssertEqual(resultA?.commands.first?.name, "code")
        XCTAssertEqual(resultB?.commands.first?.name, "fix")
        XCTAssertNotEqual(resultA?.commands.first?.name, resultB?.commands.first?.name)
    }

    // MARK: - 补全前缀过滤

    /// 验证 "/" 前缀过滤：输入 "/c" 应匹配 /code，不匹配 /fix
    func testPrefixFilterMatchesCorrectCommands() {
        let commands = [
            AIProtocolSlashCommand(name: "new",     description: "", action: "client", inputHint: nil),
            AIProtocolSlashCommand(name: "code",    description: "", action: "agent",  inputHint: "<任务>"),
            AIProtocolSlashCommand(name: "explain", description: "", action: "agent",  inputHint: "<代码>"),
            AIProtocolSlashCommand(name: "fix",     description: "", action: "agent",  inputHint: "<错误>"),
        ]
        let prefix = "c"
        let filtered = commands.filter { $0.name.hasPrefix(prefix) }
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.name, "code")
    }

    /// 验证空前缀时返回所有命令
    func testEmptyPrefixMatchesAllCommands() {
        let commands = [
            AIProtocolSlashCommand(name: "new",  description: "", action: "client", inputHint: nil),
            AIProtocolSlashCommand(name: "code", description: "", action: "agent",  inputHint: "<任务>"),
        ]
        let filtered = commands.filter { $0.name.hasPrefix("") }
        XCTAssertEqual(filtered.count, 2)
    }

    /// 验证不存在的前缀返回空数组
    func testNonMatchingPrefixReturnsEmpty() {
        let commands = [
            AIProtocolSlashCommand(name: "new",  description: "", action: "client", inputHint: nil),
            AIProtocolSlashCommand(name: "code", description: "", action: "agent",  inputHint: "<任务>"),
        ]
        let filtered = commands.filter { $0.name.hasPrefix("xyz") }
        XCTAssertTrue(filtered.isEmpty, "不存在的前缀不应匹配任何命令")
    }

    // MARK: - inputHint 多种字段路径解析

    /// 验证 inputHint 从 input.hint 嵌套路径正确提取
    func testInputHintFromNestedInputHint() {
        let cmd = AIProtocolSlashCommand.from(json: [
            "name": "code",
            "action": "agent",
            "input": ["hint": "<nested-hint>"]
        ])
        XCTAssertEqual(cmd?.inputHint, "<nested-hint>")
    }

    /// 验证 inputHint 从顶层 input_hint 字段正确提取（fallback）
    func testInputHintFromTopLevelInputHint() {
        let cmd = AIProtocolSlashCommand.from(json: [
            "name": "code",
            "action": "agent",
            "input_hint": "<flat-hint>"
        ])
        XCTAssertEqual(cmd?.inputHint, "<flat-hint>")
    }

    /// 验证 inputHint 从顶层 hint 字段正确提取（最后 fallback）
    func testInputHintFromTopLevelHintField() {
        let cmd = AIProtocolSlashCommand.from(json: [
            "name": "ask",
            "action": "agent",
            "hint": "<hint-field>"
        ])
        XCTAssertEqual(cmd?.inputHint, "<hint-field>")
    }
}
