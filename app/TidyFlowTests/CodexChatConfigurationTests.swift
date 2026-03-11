import XCTest
@testable import TidyFlow

/// 覆盖 Codex 聊天配置持久化闭环的核心路径：
/// - selection hint 中 config_options 的解析（包括 model_variant）
/// - config_options 键名别名（config_options / configOptions / session_config_options）
/// - AISessionSelectionHint.isEmpty 语义
/// - 多工作区 provider/model 信息的独立性
final class CodexChatConfigurationTests: XCTestCase {

    // MARK: - AISessionSelectionHint 解析

    /// 验证 AIChatDoneV2 中 selection_hint 携带 model_variant=low/medium/high 时均能正确解析
    func testSelectionHintModelVariantAllValidValues() {
        for level in ["low", "medium", "high"] {
            let json: [String: Any] = [
                "project_name": "tidyflow",
                "workspace_name": "default",
                "ai_tool": "codex",
                "session_id": "s-\(level)",
                "selection_hint": [
                    "agent": "code",
                    "config_options": ["model_variant": level]
                ]
            ]
            let result = AIChatDoneV2.from(json: json)
            XCTAssertNotNil(result, "model_variant=\(level) 应能解析")
            let cfg = result?.selectionHint?.configOptions
            XCTAssertEqual(cfg?["model_variant"] as? String, level,
                           "model_variant=\(level) 应回填到 configOptions")
        }
    }

    /// 验证 session_config_options 别名与标准 config_options 键均能被解析
    func testSelectionHintConfigOptionsKeyAliases() {
        let aliasKeys: [String] = ["config_options", "configOptions", "session_config_options", "sessionConfigOptions"]
        for key in aliasKeys {
            let json: [String: Any] = [
                "project_name": "tidyflow",
                "workspace_name": "default",
                "ai_tool": "codex",
                "session_id": "s1",
                "selection_hint": [
                    "agent": "code",
                    key: ["model_variant": "medium"]
                ]
            ]
            let result = AIChatDoneV2.from(json: json)
            XCTAssertNotNil(result, "键名 \(key) 应能被解析")
            let cfg = result?.selectionHint?.configOptions
            XCTAssertEqual(cfg?["model_variant"] as? String, "medium",
                           "键名 \(key) 解析后 model_variant 应为 medium")
        }
    }

    /// 验证仅含 config_options 的 hint 不被视为空（isEmpty == false）
    func testSelectionHintWithOnlyConfigOptionsIsNotEmpty() {
        let hint = AISessionSelectionHint(
            agent: nil,
            modelProviderID: nil,
            modelID: nil,
            configOptions: ["model_variant": "high"]
        )
        XCTAssertFalse(hint.isEmpty, "只含 config_options 的 hint 不应被视为空")
    }

    /// 验证全部字段为空时 hint 被视为空
    func testSelectionHintAllNilIsEmpty() {
        let hint = AISessionSelectionHint(
            agent: nil,
            modelProviderID: nil,
            modelID: nil,
            configOptions: nil
        )
        XCTAssertTrue(hint.isEmpty)
    }

    /// 验证空 config_options 字典时 hint 仍被视为空
    func testSelectionHintEmptyConfigOptionsIsEmpty() {
        let hint = AISessionSelectionHint(
            agent: nil,
            modelProviderID: nil,
            modelID: nil,
            configOptions: [:]
        )
        XCTAssertTrue(hint.isEmpty)
    }

    /// 验证 agent + model + config_options 组合解析全部字段
    func testSelectionHintFullCombinationParses() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "ws1",
            "ai_tool": "codex",
            "session_id": "full-session",
            "selection_hint": [
                "agent": "code",
                "model_provider_id": "openai",
                "model_id": "gpt-5",
                "config_options": ["model_variant": "high"]
            ]
        ]
        let result = AIChatDoneV2.from(json: json)
        XCTAssertNotNil(result)
        let hint = result?.selectionHint
        XCTAssertEqual(hint?.agent, "code")
        XCTAssertEqual(hint?.modelProviderID, "openai")
        XCTAssertEqual(hint?.modelID, "gpt-5")
        XCTAssertEqual(hint?.configOptions?["model_variant"] as? String, "high")
    }

    /// 验证 model_variant 不在枚举范围内时，configOptions 中该字段仍会透传（协议层不过滤）
    func testSelectionHintUnknownModelVariantPassesThrough() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "codex",
            "session_id": "s-unknown",
                "selection_hint": [
                    "agent": "code",
                    "config_options": ["model_variant": "ultra"]
                ]
            ]
        let result = AIChatDoneV2.from(json: json)
        XCTAssertNotNil(result)
        // 协议层透传原始值，不做枚举过滤
        let cfg = result?.selectionHint?.configOptions
        XCTAssertEqual(cfg?["model_variant"] as? String, "ultra")
    }

    // MARK: - AISessionCreatedV2 / AISessionResumedV2 中的 selection_hint

    /// 验证 AISessionStartedV2 中的 selection_hint 解析 model_variant
    func testSessionStartedParsesSelectionHintModelVariant() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "codex",
            "session_id": "started-session",
            "title": "新会话",
            "updated_at": Int64(0),
            "selection_hint": [
                "config_options": ["model_variant": "low"]
            ]
        ]
        let result = AISessionStartedV2.from(json: json)
        XCTAssertNotNil(result)
        let cfg = result?.selectionHint?.configOptions
        XCTAssertEqual(cfg?["model_variant"] as? String, "low")
    }

    /// 验证 AISessionMessagesV2 中的 selection_hint 解析 model_variant
    func testSessionMessagesParsesSelectionHintModelVariant() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "codex",
            "session_id": "messages-session",
            "selection_hint": [
                "agent": "code",
                "config_options": ["model_variant": "medium"]
            ]
        ]
        let result = AISessionMessagesV2.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.selectionHint?.agent, "code")
        let cfg = result?.selectionHint?.configOptions
        XCTAssertEqual(cfg?["model_variant"] as? String, "medium")
    }

    // MARK: - Provider/Model 多工作区隔离

    /// 验证两个独立工作区的 AIProviderListResult 数据彼此独立，不互相污染
    func testMultiWorkspaceProviderListsAreIndependent() {
        let jsonWs1: [String: Any] = [
            "project_name": "project-a",
            "workspace_name": "ws1",
            "ai_tool": "codex",
            "providers": [[
                "id": "openai",
                "name": "OpenAI",
                "models": [[
                    "id": "gpt-4o",
                    "name": "GPT-4o",
                    "provider_id": "openai",
                    "supports_image_input": false,
                    "variants": ["low", "medium", "high"]
                ]]
            ]]
        ]
        let jsonWs2: [String: Any] = [
            "project_name": "project-b",
            "workspace_name": "ws2",
            "ai_tool": "codex",
            "providers": [[
                "id": "anthropic",
                "name": "Anthropic",
                "models": [[
                    "id": "claude-4",
                    "name": "Claude 4",
                    "provider_id": "anthropic",
                    "supports_image_input": true
                ]]
            ]]
        ]

        let ws1 = AIProviderListResult.from(json: jsonWs1)
        let ws2 = AIProviderListResult.from(json: jsonWs2)

        XCTAssertEqual(ws1?.workspaceName, "ws1")
        XCTAssertEqual(ws2?.workspaceName, "ws2")
        XCTAssertEqual(ws1?.providers.first?.id, "openai")
        XCTAssertEqual(ws2?.providers.first?.id, "anthropic")
        XCTAssertEqual(ws1?.providers.first?.models.first?.variants, ["low", "medium", "high"])
        // 两个工作区的数据对象独立
        XCTAssertNotEqual(ws1?.workspaceName, ws2?.workspaceName)
        XCTAssertNotEqual(ws1?.providers.first?.id, ws2?.providers.first?.id)
    }

    /// 验证模型 supportsImageInput 字段能正确解析
    func testModelSupportsImageInputParsedCorrectly() {
        let jsonTrue: [String: Any] = [
            "project_name": "p",
            "workspace_name": "ws",
            "ai_tool": "codex",
            "providers": [[
                "id": "openai",
                "name": "OpenAI",
                "models": [[
                    "id": "gpt-5",
                    "name": "GPT-5",
                    "provider_id": "openai",
                    "supports_image_input": true
                ]]
            ]]
        ]
        let jsonFalse: [String: Any] = [
            "project_name": "p",
            "workspace_name": "ws",
            "ai_tool": "codex",
            "providers": [[
                "id": "openai",
                "name": "OpenAI",
                "models": [[
                    "id": "gpt-4o",
                    "name": "GPT-4o",
                    "provider_id": "openai",
                    "supports_image_input": false
                ]]
            ]]
        ]

        let resultTrue = AIProviderListResult.from(json: jsonTrue)
        let resultFalse = AIProviderListResult.from(json: jsonFalse)

        XCTAssertTrue(resultTrue?.providers.first?.models.first?.supportsImageInput ?? false)
        XCTAssertFalse(resultFalse?.providers.first?.models.first?.supportsImageInput ?? true)
    }

    // MARK: - AIModelSelection 有效性校验

    /// 验证模型 ID 在 provider 列表中存在时的正向校验
    func testModelSelectionValidWhenPresentInProviders() {
        let providers: [AIProviderInfo] = [
            AIProviderInfo(
                id: "openai",
                name: "OpenAI",
                models: [
                    AIModelInfo(id: "gpt-4o", name: "GPT-4o", providerID: "openai", supportsImageInput: false, variants: []),
                    AIModelInfo(id: "gpt-5", name: "GPT-5", providerID: "openai", supportsImageInput: true, variants: [])
                ]
            )
        ]
        let allModels = providers.flatMap { $0.models }
        let selection = AIModelSelection(providerID: "openai", modelID: "gpt-4o")
        let isValid = allModels.contains(where: {
            $0.id == selection.modelID && $0.providerID == selection.providerID
        })
        XCTAssertTrue(isValid, "gpt-4o 在 provider 列表中存在，应为有效选择")
    }

    /// 验证模型 ID 不在 provider 列表中时的失效检测
    func testModelSelectionInvalidWhenRemovedFromProviders() {
        let providers: [AIProviderInfo] = [
            AIProviderInfo(
                id: "openai",
                name: "OpenAI",
                models: [
                    AIModelInfo(id: "gpt-4o", name: "GPT-4o", providerID: "openai", supportsImageInput: false, variants: [])
                ]
            )
        ]
        let allModels = providers.flatMap { $0.models }
        // 之前选中的 gpt-5 已从列表移除
        let selection = AIModelSelection(providerID: "openai", modelID: "gpt-5")
        let isValid = allModels.contains(where: {
            $0.id == selection.modelID && $0.providerID == selection.providerID
        })
        XCTAssertFalse(isValid, "gpt-5 已从 provider 列表移除，应被检测为失效")
    }

    /// 验证跨 provider 的模型 ID 不会误判为有效
    func testModelSelectionWithWrongProviderIsInvalid() {
        let providers: [AIProviderInfo] = [
            AIProviderInfo(
                id: "openai",
                name: "OpenAI",
                models: [
                    AIModelInfo(id: "gpt-4o", name: "GPT-4o", providerID: "openai", supportsImageInput: false, variants: [])
                ]
            )
        ]
        let allModels = providers.flatMap { $0.models }
        // 模型 ID 存在但 provider 错误
        let wrongProviderSelection = AIModelSelection(providerID: "anthropic", modelID: "gpt-4o")
        let isValid = allModels.contains(where: {
            $0.id == wrongProviderSelection.modelID && $0.providerID == wrongProviderSelection.providerID
        })
        XCTAssertFalse(isValid, "modelID 存在但 providerID 不匹配，不应视为有效选择")
    }

    /// 验证空 provider 列表时任何选择均失效
    func testModelSelectionAlwaysInvalidWithEmptyProviders() {
        let allModels: [AIModelInfo] = []
        let selection = AIModelSelection(providerID: "openai", modelID: "gpt-4o")
        let isValid = allModels.contains(where: {
            $0.id == selection.modelID && $0.providerID == selection.providerID
        })
        XCTAssertFalse(isValid, "provider 列表为空时任何模型选择均失效")
    }
}
