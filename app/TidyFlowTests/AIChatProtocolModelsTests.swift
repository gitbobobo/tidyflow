import XCTest
@testable import TidyFlow

final class AIChatProtocolModelsTests: XCTestCase {
    func testAIProviderListParsesClaudeCodeUnderscoreTool() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "claude_code",
            "providers": [
                [
                    "id": "anthropic",
                    "name": "Anthropic",
                    "models": [
                        [
                            "id": "claude-sonnet-4-5",
                            "name": "Claude Sonnet 4.5",
                            "provider_id": "anthropic",
                            "supports_image_input": true
                        ]
                    ]
                ]
            ]
        ]

        let result = AIProviderListResult.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.aiTool, .claude_code)
        XCTAssertEqual(result?.providers.first?.id, "anthropic")
    }

    func testAIAgentListParsesClaudeCodeHyphenTool() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "claude-code",
            "agents": [
                [
                    "name": "default",
                    "description": "Claude Code default mode",
                    "mode": "primary"
                ]
            ]
        ]

        let result = AIAgentListResult.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.aiTool, .claude_code)
        XCTAssertEqual(result?.agents.first?.name, "default")
    }

    func testAIChatDoneParsesOptionalStopReason() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "copilot",
            "session_id": "s1",
            "stop_reason": "cancelled",
        ]

        let result = AIChatDoneV2.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.stopReason, "cancelled")
    }

    func testAIChatDoneAllowsMissingStopReason() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "copilot",
            "session_id": "s1",
        ]

        let result = AIChatDoneV2.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.stopReason)
    }

    func testAIProtocolPartInfoParsesPlanPartAndSource() {
        let json: [String: Any] = [
            "id": "assistant-1-plan",
            "part_type": "plan",
            "source": [
                "vendor": "acp",
                "item_type": "plan",
                "protocol": "agent-plan",
                "revision": 2,
                "entries": [
                    ["content": "实现解析器", "status": "in_progress"],
                ],
            ],
        ]

        let part = AIProtocolPartInfo.from(json: json)
        XCTAssertNotNil(part)
        XCTAssertEqual(part?.partType, "plan")
        XCTAssertEqual(part?.source?["protocol"] as? String, "agent-plan")
        XCTAssertEqual(part?.source?["revision"] as? Int, 2)
    }

    func testAIQuestionOptionParsesOptionIDSnakeAndCamel() {
        let snake = AIQuestionOptionInfo.from(json: [
            "option_id": "code",
            "label": "开始实现",
            "description": "切换到实现模式"
        ])
        XCTAssertEqual(snake?.optionID, "code")
        XCTAssertEqual(snake?.label, "开始实现")

        let camel = AIQuestionOptionInfo.from(json: [
            "optionId": "ask",
            "label": "继续规划"
        ])
        XCTAssertEqual(camel?.optionID, "ask")
        XCTAssertEqual(camel?.label, "继续规划")
    }

    func testAIQuestionRequestMapsDisplayAnswersToProtocolAnswers() {
        let request = AIQuestionRequestInfo(
            id: "req-1",
            sessionId: "s1",
            questions: [
                AIQuestionInfo(
                    question: "是否开始实现？",
                    header: "模式",
                    options: [
                        AIQuestionOptionInfo(optionID: "code", label: "开始实现", description: ""),
                        AIQuestionOptionInfo(optionID: "ask", label: "继续规划", description: ""),
                    ],
                    multiple: false,
                    custom: false
                ),
                AIQuestionInfo(
                    question: "补充说明",
                    header: "备注",
                    options: [],
                    multiple: false,
                    custom: true
                ),
            ],
            toolMessageId: nil,
            toolCallId: nil
        )

        let protocolAnswers = request.protocolAnswers(from: [
            ["开始实现"],
            ["保留当前计划并补测试"],
        ])

        XCTAssertEqual(protocolAnswers.count, 2)
        XCTAssertEqual(protocolAnswers[0], ["code"])
        XCTAssertEqual(protocolAnswers[1], ["保留当前计划并补测试"])
    }

    func testAISessionConfigOptionsParsesGroupedOptions() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "codex",
            "session_id": "s1",
            "options": [
                [
                    "option_id": "mode",
                    "category": "mode",
                    "name": "模式",
                    "current_value": "code",
                    "options": [
                        [
                            "value": "code",
                            "label": "代码"
                        ]
                    ],
                    "option_groups": [
                        [
                            "label": "高级",
                            "options": [
                                [
                                    "value": [
                                        "id": "plan"
                                    ],
                                    "label": "规划"
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let result = AISessionConfigOptionsResult.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.aiTool, .codex)
        XCTAssertEqual(result?.sessionId, "s1")
        XCTAssertEqual(result?.options.count, 1)

        let option = result?.options.first
        XCTAssertEqual(option?.optionID, "mode")
        XCTAssertEqual(option?.category, "mode")
        XCTAssertEqual(option?.currentValue as? String, "code")
        XCTAssertEqual(option?.options.count, 1)
        XCTAssertEqual(option?.optionGroups.count, 1)
        XCTAssertEqual(option?.optionGroups.first?.label, "高级")
        let groupedValue = option?.optionGroups.first?.options.first?.value as? [String: Any]
        XCTAssertEqual(groupedValue?["id"] as? String, "plan")
    }

    func testAIChatDoneParsesSelectionHintConfigOptions() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "codex",
            "session_id": "s2",
            "selection_hint": [
                "agent": "code",
                "config_options": [
                    "mode": "code",
                    "thought_level": "high",
                    "model": [
                        "provider_id": "openai",
                        "model_id": "gpt-5"
                    ],
                    "tags": ["fast", "safe"]
                ]
            ]
        ]

        let result = AIChatDoneV2.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.selectionHint?.agent, "code")
        let configOptions = result?.selectionHint?.configOptions
        XCTAssertEqual(configOptions?["mode"] as? String, "code")
        XCTAssertEqual(configOptions?["thought_level"] as? String, "high")
        let model = configOptions?["model"] as? [String: Any]
        XCTAssertEqual(model?["provider_id"] as? String, "openai")
        XCTAssertEqual(model?["model_id"] as? String, "gpt-5")
        let tags = configOptions?["tags"] as? [String]
        XCTAssertEqual(tags, ["fast", "safe"])
    }

    func testEvolutionStageProfileInfoParsesAndSerializesConfigOptions() {
        let json: [String: Any] = [
            "stage": "direction",
            "ai_tool": "codex",
            "mode": "code",
            "model": [
                "provider_id": "openai",
                "model_id": "gpt-5"
            ],
            "config_options": [
                "thought_level": "high",
                "custom_group": [
                    "id": "advanced",
                    "enabled": true
                ]
            ]
        ]

        let profile = EvolutionStageProfileInfoV2.from(json: json)
        XCTAssertNotNil(profile)
        XCTAssertEqual(profile?.stage, "direction")
        XCTAssertEqual(profile?.configOptions["thought_level"] as? String, "high")
        let nested = profile?.configOptions["custom_group"] as? [String: Any]
        XCTAssertEqual(nested?["id"] as? String, "advanced")
        XCTAssertEqual(nested?["enabled"] as? Bool, true)

        let encoded = profile?.toJSON()
        let encodedConfig = encoded?["config_options"] as? [String: Any]
        XCTAssertEqual(encodedConfig?["thought_level"] as? String, "high")
        let encodedNested = encodedConfig?["custom_group"] as? [String: Any]
        XCTAssertEqual(encodedNested?["id"] as? String, "advanced")
    }
}
