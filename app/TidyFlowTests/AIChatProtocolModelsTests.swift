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

    func testAIProtocolSlashCommandParsesInputHintAndDefaults() {
        let nested = AIProtocolSlashCommand.from(json: [
            "name": "build",
            "description": "构建项目",
            "action": "agent",
            "input": [
                "hint": "--release"
            ]
        ])
        XCTAssertNotNil(nested)
        XCTAssertEqual(nested?.name, "build")
        XCTAssertEqual(nested?.description, "构建项目")
        XCTAssertEqual(nested?.action, "agent")
        XCTAssertEqual(nested?.inputHint, "--release")

        let fallback = AIProtocolSlashCommand.from(json: [
            "name": "test",
            "hint": "--unit"
        ])
        XCTAssertNotNil(fallback)
        XCTAssertEqual(fallback?.description, "")
        XCTAssertEqual(fallback?.action, "client")
        XCTAssertEqual(fallback?.inputHint, "--unit")
    }

    func testAISlashCommandsResultParsesOptionalSessionIDAndDefaultFields() {
        let withoutSession: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "codex",
            "commands": [
                [
                    "name": "new"
                ]
            ]
        ]
        let resultWithoutSession = AISlashCommandsResult.from(json: withoutSession)
        XCTAssertNotNil(resultWithoutSession)
        XCTAssertNil(resultWithoutSession?.sessionID)
        XCTAssertEqual(resultWithoutSession?.commands.count, 1)
        XCTAssertEqual(resultWithoutSession?.commands.first?.name, "new")
        XCTAssertEqual(resultWithoutSession?.commands.first?.description, "")
        XCTAssertEqual(resultWithoutSession?.commands.first?.action, "client")

        let withSession: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "codex",
            "session_id": "session-1",
            "commands": []
        ]
        let resultWithSession = AISlashCommandsResult.from(json: withSession)
        XCTAssertNotNil(resultWithSession)
        XCTAssertEqual(resultWithSession?.sessionID, "session-1")
    }

    func testAISlashCommandsUpdateResultParsesAndRequiresSessionID() {
        let valid: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "codex",
            "session_id": "session-2",
            "commands": [
                [
                    "name": "build",
                    "input_hint": "--release"
                ]
            ]
        ]
        let parsed = AISlashCommandsUpdateResult.from(json: valid)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.sessionID, "session-2")
        XCTAssertEqual(parsed?.commands.first?.name, "build")
        XCTAssertEqual(parsed?.commands.first?.inputHint, "--release")

        let missingSession: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "codex",
            "commands": []
        ]
        XCTAssertNil(AISlashCommandsUpdateResult.from(json: missingSession))
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

    func testAIProtocolPartInfoParsesToolCallExtendedFields() {
        let json: [String: Any] = [
            "id": "tool-1",
            "part_type": "tool",
            "tool_name": "bash",
            "tool_call_id": "call-1",
            "tool_kind": "terminal",
            "tool_title": "执行测试",
            "tool_raw_input": [
                "command": "npm test"
            ],
            "tool_raw_output": [
                "type": "terminal",
                "output": "running"
            ],
            "tool_locations": [
                [
                    "path": "src/main.ts",
                    "line": 12,
                    "column": 4,
                    "endLine": 12,
                    "endColumn": 22,
                    "label": "诊断"
                ]
            ],
            "tool_state": [
                "status": "in_progress"
            ]
        ]

        let part = AIProtocolPartInfo.from(json: json)
        XCTAssertNotNil(part)
        XCTAssertEqual(part?.toolKind, "terminal")
        XCTAssertEqual(part?.toolTitle, "执行测试")
        XCTAssertEqual((part?.toolRawInput as? [String: Any])?["command"] as? String, "npm test")
        XCTAssertEqual((part?.toolRawOutput as? [String: Any])?["type"] as? String, "terminal")
        XCTAssertEqual(part?.toolLocations?.count, 1)
        XCTAssertEqual(part?.toolLocations?.first?.path, "src/main.ts")
        XCTAssertEqual(part?.toolLocations?.first?.endLine, 12)
    }

    func testAIToolInvocationStateNormalizesACPStatuses() {
        let running = AIToolInvocationState.from(state: ["status": "in_progress"])
        XCTAssertEqual(running?.status, .running)

        let completed = AIToolInvocationState.from(state: ["status": "done"])
        XCTAssertEqual(completed?.status, .completed)

        let failed = AIToolInvocationState.from(state: ["status": "failed"])
        XCTAssertEqual(failed?.status, .error)

        let awaitingInput = AIToolInvocationState.from(state: ["status": "requires_input"])
        XCTAssertEqual(awaitingInput?.status, .running)
    }

    func testAIQuestionLocalCompletionFallbackSkipsFailedAndSelectsInProgress() {
        var messages = [
            AIChatMessage(
                messageId: "m1",
                role: .assistant,
                parts: [
                    AIChatPart(
                        id: "p-running",
                        kind: .tool,
                        text: nil,
                        toolName: "question",
                        toolState: ["status": "in_progress"]
                    )
                ],
                isStreaming: false
            ),
            AIChatMessage(
                messageId: "m2",
                role: .assistant,
                parts: [
                    AIChatPart(
                        id: "p-failed",
                        kind: .tool,
                        text: nil,
                        toolName: "question",
                        toolState: ["status": "failed"]
                    )
                ],
                isStreaming: false
            )
        ]

        let request = AIQuestionRequestInfo(
            id: "req-fallback",
            sessionId: "s1",
            questions: [],
            toolMessageId: nil,
            toolCallId: nil
        )

        let updated = AIQuestionLocalCompletion.apply(
            to: &messages,
            requestId: "req-fallback",
            mappedKey: nil,
            request: request,
            answers: [["继续执行"]],
            allowFallback: true
        )

        XCTAssertTrue(updated)
        XCTAssertEqual(messages[0].parts[0].toolState?["status"] as? String, "completed")
        XCTAssertEqual(messages[1].parts[0].toolState?["status"] as? String, "failed")
    }

    func testAIChatPartNormalizationKeepsFieldsConsistent() {
        let proto = AIProtocolPartInfo(
            id: "tool-x",
            partType: "tool",
            text: "delta",
            mime: "text/plain",
            filename: "a.txt",
            url: "file:///a.txt",
            synthetic: true,
            ignored: false,
            source: ["vendor": "acp"],
            toolName: "edit",
            toolCallId: "call-x",
            toolKind: "diff",
            toolTitle: "补丁",
            toolRawInput: ["path": "a.txt"],
            toolRawOutput: ["diff": "+x"],
            toolLocations: [
                AIProtocolToolCallLocationInfo(
                    uri: nil,
                    path: "a.txt",
                    line: 3,
                    column: 1,
                    endLine: 4,
                    endColumn: 2,
                    label: "hunk"
                )
            ],
            toolState: ["status": "running"],
            toolPartMetadata: ["trace_id": "t1"]
        )

        let part = AIChatPartNormalization.makeChatPart(from: proto)
        XCTAssertEqual(part.kind, .tool)
        XCTAssertEqual(part.toolKind, "diff")
        XCTAssertEqual(part.toolTitle, "补丁")
        XCTAssertEqual((part.toolRawInput as? [String: Any])?["path"] as? String, "a.txt")
        XCTAssertEqual((part.toolRawOutput as? [String: Any])?["diff"] as? String, "+x")
        XCTAssertEqual(part.toolLocations?.first?.path, "a.txt")
        XCTAssertEqual(part.toolLocations?.first?.endColumn, 2)
        XCTAssertEqual(part.source?["vendor"] as? String, "acp")
    }

    func testToolCardViewBuildsMarkdownDiffTerminalAndLocationsSections() {
        let markdownView = ToolCardView(
            name: "markdown",
            state: [
                "status": "running",
                "output": "# 标题",
                "metadata": [
                    "locations": [
                        ["path": "doc.md", "line": 1]
                    ]
                ]
            ],
            callID: "c1",
            partMetadata: nil
        )
        let markdownSections = markdownView.debugPresentationForTests().sections.map(\.id)
        XCTAssertTrue(markdownSections.contains("markdown-output"))
        XCTAssertTrue(markdownSections.contains("markdown-locations"))

        let diffView = ToolCardView(
            name: "diff",
            state: [
                "status": "running",
                "output": "@@ -1 +1 @@\n-old\n+new"
            ],
            callID: "c2",
            partMetadata: nil
        )
        let diffSections = diffView.debugPresentationForTests().sections.map(\.id)
        XCTAssertTrue(diffSections.contains("edit-diff"))

        let terminalView = ToolCardView(
            name: "terminal",
            state: [
                "status": "running",
                "output": "npm test\nok",
                "metadata": [
                    "progress_lines": ["50%"]
                ]
            ],
            callID: "c3",
            partMetadata: nil
        )
        let terminalSections = terminalView.debugPresentationForTests().sections.map(\.id)
        XCTAssertTrue(terminalSections.contains("terminal-output"))
        XCTAssertTrue(terminalSections.contains("terminal-progress"))
    }

    func testAISessionMessagesToChatMessagesMapsToolCallExtendedFields() {
        let payload = AISessionMessagesV2(
            projectName: "tidyflow",
            workspaceName: "default",
            aiTool: .codex,
            sessionId: "s-tool",
            messages: [
                AIProtocolMessageInfo(
                    id: "m-tool",
                    role: "assistant",
                    createdAt: nil,
                    agent: nil,
                    modelProviderID: nil,
                    modelID: nil,
                    parts: [
                        AIProtocolPartInfo(
                            id: "p-tool",
                            partType: "tool",
                            text: nil,
                            mime: nil,
                            filename: nil,
                            url: nil,
                            synthetic: nil,
                            ignored: nil,
                            source: nil,
                            toolName: "bash",
                            toolCallId: "call-2",
                            toolKind: "terminal",
                            toolTitle: "运行命令",
                            toolRawInput: ["command": "ls"],
                            toolRawOutput: ["output": "ok"],
                            toolLocations: [
                                AIProtocolToolCallLocationInfo(
                                    uri: "file:///tmp/a",
                                    path: nil,
                                    line: 9,
                                    column: 3,
                                    endLine: nil,
                                    endColumn: nil,
                                    label: "ref"
                                )
                            ],
                            toolState: ["status": "running"],
                            toolPartMetadata: nil
                        )
                    ]
                )
            ],
            selectionHint: nil
        )

        let mapped = payload.toChatMessages()
        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped.first?.parts.count, 1)
        let part = mapped.first?.parts.first
        XCTAssertEqual(part?.toolKind, "terminal")
        XCTAssertEqual(part?.toolTitle, "运行命令")
        XCTAssertEqual((part?.toolRawInput as? [String: Any])?["command"] as? String, "ls")
        XCTAssertEqual(part?.toolLocations?.first?.uri, "file:///tmp/a")
        XCTAssertEqual(part?.toolLocations?.first?.line, 9)
    }
}
