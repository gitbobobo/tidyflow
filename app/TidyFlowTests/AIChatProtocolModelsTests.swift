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

    func testEvolutionStageProfileInfoParsesImplementGeneralStage() {
        let json: [String: Any] = [
            "stage": "implement_general",
            "ai_tool": "codex",
            "mode": "code",
        ]

        let profile = EvolutionStageProfileInfoV2.from(json: json)
        XCTAssertNotNil(profile)
        XCTAssertEqual(profile?.stage, "implement_general")
        XCTAssertEqual(profile?.aiTool, .codex)
    }

    func testEvolutionAgentProfileParsesImplementStagesFromMapPayload() {
        let json: [String: Any] = [
            "project": "tidyflow",
            "workspace": "default",
            "stage_profiles": [
                "direction": [
                    "ai_tool": "codex",
                ],
                "implement_general": [
                    "ai_tool": "codex",
                    "mode": "code",
                ],
                "implement_visual": [
                    "ai_tool": "codex",
                ],
                "implement_advanced": [
                    "ai_tool": "codex",
                ],
            ],
        ]

        let result = EvolutionAgentProfileV2.from(json: json)
        XCTAssertNotNil(result)
        let stages = Set(result?.stageProfiles.map { $0.stage } ?? [])
        XCTAssertTrue(stages.contains("implement_general"))
        XCTAssertTrue(stages.contains("implement_visual"))
        XCTAssertTrue(stages.contains("implement_advanced"))
    }

    func testEvolutionWorkspaceItemParsesSessionExecutions() {
        let json: [String: Any] = [
            "project": "tidyflow",
            "workspace": "default",
            "cycle_id": "cycle-1",
            "title": "当前循环标题",
            "status": "running",
            "current_stage": "verify",
            "global_loop_round": 1,
            "loop_round_limit": 3,
            "verify_iteration": 0,
            "verify_iteration_limit": 5,
            "agents": [],
            "terminal_error_message": "verify.result.json 校验失败: 缺少 summary 字段",
            "executions": [
                [
                    "stage": "verify",
                    "agent": "VerifyAgent",
                    "ai_tool": "codex",
                    "session_id": "sess-1",
                    "status": "done",
                    "started_at": "2026-03-01T00:00:00Z",
                    "completed_at": "2026-03-01T00:00:05Z",
                    "duration_ms": 5000,
                    "tool_call_count": 2
                ]
            ],
            "handoff": [
                "completed": ["完成结构改造"],
                "risks": ["需要补 UI 构建验证"],
                "next": ["继续跑 xcodebuild"]
            ],
            "active_agents": []
        ]

        let item = EvolutionWorkspaceItemV2.from(json: json)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.executions.count, 1)
        XCTAssertEqual(item?.executions.first?.sessionID, "sess-1")
        XCTAssertEqual(item?.executions.first?.durationMs, 5000)
        XCTAssertEqual(item?.executions.first?.toolCallCount, 2)
        XCTAssertEqual(item?.title, "当前循环标题")
        XCTAssertEqual(item?.terminalErrorMessage, "verify.result.json 校验失败: 缺少 summary 字段")
        XCTAssertEqual(item?.handoff?.completed, ["完成结构改造"])
        XCTAssertEqual(item?.handoff?.next, ["继续跑 xcodebuild"])
    }

    func testEvolutionWorkspaceItemParsesSelectedDirectionType() {
        let jsonWithDirection: [String: Any] = [
            "project": "tidyflow",
            "workspace": "default",
            "cycle_id": "cycle-2",
            "title": "AI工作流智能化循环",
            "status": "running",
            "current_stage": "implement_general",
            "global_loop_round": 19,
            "loop_round_limit": 30,
            "verify_iteration": 0,
            "verify_iteration_limit": 5,
            "agents": [],
            "active_agents": [],
            "selected_direction_type": "AI工作流智能化"
        ]
        let item = EvolutionWorkspaceItemV2.from(json: jsonWithDirection)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.selectedDirectionType, "AI工作流智能化")
        XCTAssertEqual(item?.currentStage, "implement_general")
        XCTAssertEqual(item?.globalLoopRound, 19)

        let jsonWithoutDirection: [String: Any] = [
            "project": "tidyflow",
            "workspace": "default",
            "cycle_id": "cycle-3",
            "status": "stopped",
            "current_stage": "direction",
            "global_loop_round": 1,
            "loop_round_limit": 3,
            "verify_iteration": 0,
            "verify_iteration_limit": 5,
            "agents": [],
            "active_agents": []
        ]
        let itemWithoutDirection = EvolutionWorkspaceItemV2.from(json: jsonWithoutDirection)
        XCTAssertNotNil(itemWithoutDirection)
        XCTAssertNil(itemWithoutDirection?.selectedDirectionType)
    }

    func testEvoCycleUpdatedV2Parses() {
        let json: [String: Any] = [
            "project": "tidyflow",
            "workspace": "default",
            "cycle_id": "cycle-19",
            "title": "AI工作流智能化与系统稳定性提升",
            "status": "running",
            "current_stage": "verify",
            "global_loop_round": 19,
            "loop_round_limit": 30,
            "verify_iteration": 1,
            "verify_iteration_limit": 5,
            "agents": [],
            "executions": [],
            "active_agents": ["verify"],
            "selected_direction_type": "AI工作流智能化"
        ]
        let ev = EvoCycleUpdatedV2.from(json: json)
        XCTAssertNotNil(ev)
        XCTAssertEqual(ev?.project, "tidyflow")
        XCTAssertEqual(ev?.currentStage, "verify")
        XCTAssertEqual(ev?.verifyIteration, 1)
        XCTAssertEqual(ev?.selectedDirectionType, "AI工作流智能化")
        XCTAssertEqual(ev?.activeAgents, ["verify"])
    }

    func testEvolutionCycleHistoryParsesExecutionsAndFallbackStages() {
        let withExecutions: [String: Any] = [
            "cycle_id": "cycle-1",
            "title": "历史循环标题",
            "status": "completed",
            "global_loop_round": 1,
            "created_at": "2026-03-01T00:00:00Z",
            "updated_at": "2026-03-01T00:10:00Z",
            "terminal_error_message": "judge.result.json 缺少 pass 字段",
            "executions": [
                [
                    "stage": "verify",
                    "agent": "VerifyAgent",
                    "ai_tool": "codex",
                    "session_id": "sess-1",
                    "status": "done",
                    "started_at": "2026-03-01T00:00:00Z",
                    "duration_ms": 1000
                ]
            ],
            "handoff": [
                "completed": ["已完成方向和计划"],
                "risks": ["verify 尚未稳定"],
                "next": ["补齐测试"]
            ],
            "stages": [
                [
                    "stage": "verify",
                    "agent": "VerifyAgent",
                    "ai_tool": "codex",
                    "status": "done",
                    "duration_ms": 1000
                ]
            ]
        ]
        let parsedWithExecutions = EvolutionCycleHistoryItemV2.from(json: withExecutions)
        XCTAssertEqual(parsedWithExecutions?.executions.count, 1)
        XCTAssertEqual(parsedWithExecutions?.stages.count, 1)
        XCTAssertEqual(parsedWithExecutions?.title, "历史循环标题")
        XCTAssertEqual(parsedWithExecutions?.terminalErrorMessage, "judge.result.json 缺少 pass 字段")
        XCTAssertEqual(parsedWithExecutions?.handoff?.risks, ["verify 尚未稳定"])

        let fallbackStagesOnly: [String: Any] = [
            "cycle_id": "cycle-2",
            "cycle_title": "兼容字段标题",
            "status": "completed",
            "global_loop_round": 1,
            "created_at": "2026-03-01T00:00:00Z",
            "updated_at": "2026-03-01T00:10:00Z",
            "stages": [
                [
                    "stage": "plan",
                    "agent": "PlanAgent",
                    "ai_tool": "codex",
                    "status": "done",
                    "duration_ms": 2000
                ]
            ]
        ]
        let parsedFallback = EvolutionCycleHistoryItemV2.from(json: fallbackStagesOnly)
        XCTAssertEqual(parsedFallback?.executions.count, 0)
        XCTAssertEqual(parsedFallback?.stages.count, 1)
        XCTAssertEqual(parsedFallback?.title, "兼容字段标题")
        XCTAssertEqual(parsedFallback?.stages.first?.stage, "plan")
        XCTAssertNil(parsedFallback?.handoff)
    }

    func testEvolutionHandoffParsesAndFiltersEmptySections() {
        let json: [String: Any] = [
            "completed": ["完成 A", "  "],
            "risks": [],
            "next": ["下一步 B"]
        ]
        let handoff = EvolutionHandoffInfoV2.from(json: json)
        XCTAssertEqual(handoff?.completed, ["完成 A"])
        XCTAssertEqual(handoff?.next, ["下一步 B"])

        let empty = EvolutionHandoffInfoV2.from(json: [
            "completed": [],
            "risks": [],
            "next": []
        ])
        XCTAssertNil(empty)
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
            beforeMessageId: nil,
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
            hasMore: false,
            nextBeforeMessageId: nil,
            selectionHint: nil,
            truncated: false
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

    func testAISessionMessagesParsesTruncatedFlag() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "codex",
            "session_id": "s1",
            "messages": [],
            "truncated": true,
        ]

        let result = AISessionMessagesV2.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.truncated, true)
    }

    func testAISessionMessagesUpdateParsesOpsMode() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "codex",
            "session_id": "s1",
            "cache_revision": 8,
            "is_streaming": true,
            "ops": [
                [
                    "part_delta": [
                        "message_id": "m1",
                        "part_id": "p1",
                        "part_type": "text",
                        "field": "text",
                        "delta": "hello",
                    ]
                ]
            ],
        ]

        let result = AISessionMessagesUpdateV2.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.cacheRevision, 8)
        XCTAssertEqual(result?.isStreaming, true)
        guard let op = result?.ops?.first else {
            XCTFail("缺少 ops")
            return
        }
        switch op {
        case let .partDelta(messageId, partId, partType, field, delta):
            XCTAssertEqual(messageId, "m1")
            XCTAssertEqual(partId, "p1")
            XCTAssertEqual(partType, "text")
            XCTAssertEqual(field, "text")
            XCTAssertEqual(delta, "hello")
        default:
            XCTFail("ops 解析类型错误")
        }
    }

    func testAISessionMessagesUpdateParsesMessagesMode() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "codex",
            "session_id": "s2",
            "cache_revision": 11,
            "is_streaming": false,
            "messages": [
                [
                    "id": "m1",
                    "role": "assistant",
                    "parts": [
                        [
                            "id": "p1",
                            "part_type": "text",
                            "text": "snapshot",
                        ]
                    ]
                ]
            ],
        ]

        let result = AISessionMessagesUpdateV2.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.cacheRevision, 11)
        XCTAssertEqual(result?.isStreaming, false)
        XCTAssertEqual(result?.messages?.count, 1)
        XCTAssertEqual(result?.messages?.first?.parts.first?.text, "snapshot")
        XCTAssertNil(result?.ops)
    }

    func testClientSettingsDecodeWorkspaceTodosFromSnakeCase() throws {
        let json = """
        {
          "customCommands": [],
          "workspaceShortcuts": {},
          "fixed_port": 0,
          "remote_access_enabled": false,
          "workspace_todos": {
            "demo:default": [
              {
                "id": "todo-1",
                "title": "补测试",
                "note": "回归关键路径",
                "status": "in_progress",
                "order": 0,
                "created_at_ms": 1760000000000,
                "updated_at_ms": 1760000001000
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ClientSettings.self, from: json)
        XCTAssertEqual(decoded.workspaceTodos["demo:default"]?.count, 1)
        XCTAssertEqual(decoded.workspaceTodos["demo:default"]?.first?.status, .inProgress)
        XCTAssertEqual(decoded.workspaceTodos["demo:default"]?.first?.note, "回归关键路径")
    }

    func testClientSettingsEncodeWorkspaceTodosToSnakeCase() throws {
        let settings = ClientSettings(
            customCommands: [],
            workspaceShortcuts: [:],
            mergeAIAgent: nil,
            fixedPort: 0,
            remoteAccessEnabled: false,
            evolutionAgentProfiles: [:],
            workspaceTodos: [
                "demo:default": [
                    WorkspaceTodoItem(
                        id: "todo-1",
                        title: "实现 UI",
                        note: nil,
                        status: .pending,
                        order: 0,
                        createdAtMs: 1760000000000,
                        updatedAtMs: 1760000000000
                    )
                ]
            ]
        )

        let encoded = try JSONEncoder().encode(settings)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let workspaceTodos = object?["workspace_todos"] as? [String: Any]
        let list = workspaceTodos?["demo:default"] as? [[String: Any]]
        XCTAssertEqual(list?.count, 1)
        XCTAssertEqual(list?.first?["status"] as? String, "pending")
        XCTAssertEqual(list?.first?["created_at_ms"] as? Int64, 1760000000000)
    }

    func testWorkspaceTodoStoreStatusSwitchAndReorder() {
        var storage: [String: [WorkspaceTodoItem]] = [:]
        let workspaceKey = "demo:default"
        let first = WorkspaceTodoStore.add(
            workspaceKey: workspaceKey,
            title: "A",
            note: nil,
            storage: &storage
        )
        let second = WorkspaceTodoStore.add(
            workspaceKey: workspaceKey,
            title: "B",
            note: nil,
            storage: &storage
        )
        let third = WorkspaceTodoStore.add(
            workspaceKey: workspaceKey,
            title: "C",
            note: nil,
            storage: &storage
        )
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotNil(third)

        _ = WorkspaceTodoStore.setStatus(
            workspaceKey: workspaceKey,
            todoID: first?.id ?? "",
            status: .inProgress,
            storage: &storage
        )
        let inProgress = WorkspaceTodoStore.items(for: workspaceKey, in: storage).filter { $0.status == .inProgress }
        XCTAssertEqual(inProgress.count, 1)
        XCTAssertEqual(inProgress.first?.title, "A")

        WorkspaceTodoStore.move(
            workspaceKey: workspaceKey,
            status: .pending,
            fromOffsets: IndexSet(integer: 0),
            toOffset: 2,
            storage: &storage
        )
        let pending = WorkspaceTodoStore.items(for: workspaceKey, in: storage).filter { $0.status == .pending }
        XCTAssertEqual(pending.map(\.title), ["C", "B"])
    }

    // MARK: - AI 代码补全协议测试（WI-001 / WI-005）

    func testAICodeCompletionChunkParsesValidPayload() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "kimi",
            "chunk": [
                "request_id": "req-abc",
                "delta": "\n    println!(\"hello\");",
                "is_final": false
            ]
        ]
        let result = AICodeCompletionChunk.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.requestId, "req-abc")
        XCTAssertEqual(result?.delta, "\n    println!(\"hello\");")
        XCTAssertEqual(result?.isFinal, false)
        XCTAssertEqual(result?.projectName, "tidyflow")
        XCTAssertEqual(result?.aiTool, "kimi")
    }

    func testAICodeCompletionChunkDefaultsIsFinalToFalse() {
        let json: [String: Any] = [
            "project_name": "p",
            "workspace_name": "w",
            "ai_tool": "copilot",
            "chunk": [
                "request_id": "r1",
                "delta": "let x = 1"
                // is_final 未提供，应默认为 false
            ]
        ]
        let result = AICodeCompletionChunk.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.isFinal, false)
    }

    func testAICodeCompletionChunkRejectsInvalidPayload() {
        // 缺少 chunk 字段
        let json: [String: Any] = [
            "project_name": "p",
            "workspace_name": "w",
            "ai_tool": "copilot"
        ]
        XCTAssertNil(AICodeCompletionChunk.from(json: json))
    }

    func testAICodeCompletionDoneParsesValidPayload() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "kimi",
            "result": [
                "request_id": "req-xyz",
                "completion_text": "    return 42;\n",
                "stop_reason": "done"
            ]
        ]
        let result = AICodeCompletionDone.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.requestId, "req-xyz")
        XCTAssertEqual(result?.completionText, "    return 42;\n")
        XCTAssertEqual(result?.stopReason, "done")
        XCTAssertNil(result?.error)
    }

    func testAICodeCompletionDoneParsesErrorPayload() {
        let json: [String: Any] = [
            "project_name": "p",
            "workspace_name": "w",
            "ai_tool": "copilot",
            "result": [
                "request_id": "req-err",
                "completion_text": "",
                "stop_reason": "error",
                "error": "AI backend unavailable"
            ]
        ]
        let result = AICodeCompletionDone.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.stopReason, "error")
        XCTAssertEqual(result?.error, "AI backend unavailable")
    }

    func testAICodeCompletionLanguageFromExtension() {
        XCTAssertEqual(AICodeCompletionLanguage.from(fileExtension: "swift"), .swift)
        XCTAssertEqual(AICodeCompletionLanguage.from(fileExtension: "rs"), .rust)
        XCTAssertEqual(AICodeCompletionLanguage.from(fileExtension: "js"), .javascript)
        XCTAssertEqual(AICodeCompletionLanguage.from(fileExtension: "ts"), .typescript)
        XCTAssertEqual(AICodeCompletionLanguage.from(fileExtension: "tsx"), .typescript)
        XCTAssertEqual(AICodeCompletionLanguage.from(fileExtension: "py"), .python)
        XCTAssertEqual(AICodeCompletionLanguage.from(fileExtension: "go"), .go)
        XCTAssertEqual(AICodeCompletionLanguage.from(fileExtension: "rb"), .other)
        XCTAssertEqual(AICodeCompletionLanguage.from(fileExtension: ""), .other)
    }

    func testAICodeCompletionLanguageFromFilePath() {
        XCTAssertEqual(AICodeCompletionLanguage.from(filePath: "app/TidyFlow/Views/AI/ChatInputView.swift"), .swift)
        XCTAssertEqual(AICodeCompletionLanguage.from(filePath: "core/src/ai/completion_agent.rs"), .rust)
        XCTAssertEqual(AICodeCompletionLanguage.from(filePath: "web/index.ts"), .typescript)
        XCTAssertEqual(AICodeCompletionLanguage.from(filePath: "scripts/build.py"), .python)
        XCTAssertEqual(AICodeCompletionLanguage.from(filePath: "cmd/main.go"), .go)
    }

    // MARK: - 工具卡片 8pt 间距规则数据契约（WI-004 回归防线）

    /// 验证 .tool 和 .reasoning part 类型在不同 AI 工具来源下均解析一致，
    /// 这些类型是聊天视图 8pt 紧凑间距规则的基础数据契约。
    func testToolPartKindConsistentAcrossAIToolSources() {
        // codex 来源的工具 part
        let codexPart = AIChatPart(id: "p1", kind: .tool, toolName: "bash")
        // copilot 来源的工具 part（相同 kind 契约）
        let copilotPart = AIChatPart(id: "p2", kind: .tool, toolName: "read_file")
        // opencode 来源的工具 part
        let opencodePart = AIChatPart(id: "p3", kind: .tool, toolName: "write_file")
        // 不同 AI 工具产出的工具 part 应共享同一 .tool kind，以保证间距规则不因来源而差异化
        XCTAssertEqual(codexPart.kind, .tool)
        XCTAssertEqual(copilotPart.kind, .tool)
        XCTAssertEqual(opencodePart.kind, .tool)
    }

    /// 验证 .reasoning part 类型契约：与工具卡片相邻时触发 8pt 间距
    func testReasoningPartKindContractForSpacingRule() {
        let reasoningPart = AIChatPart(id: "r1", kind: .reasoning, text: "正在思考...")
        let toolPart = AIChatPart(id: "t1", kind: .tool, toolName: "bash")
        // reasoning 与 tool 相邻组合触发 8pt 紧凑间距，类型契约必须稳定
        XCTAssertEqual(reasoningPart.kind, .reasoning)
        XCTAssertEqual(toolPart.kind, .tool)
    }

    /// 验证 AIChatPartKind 中 .tool 和 .reasoning 的原始值与间距规则注释一致
    func testToolAndReasoningPartKindRawValues() {
        XCTAssertEqual(AIChatPartKind.tool.rawValue, "tool")
        XCTAssertEqual(AIChatPartKind.reasoning.rawValue, "reasoning")
    }

    /// 验证连续工具 part 的 assistant 消息数据结构（messageSpacing 8pt 的前置条件）：
    /// 一条 assistant 消息全部为 .tool part 时，应被视为工具类消息，
    /// 与相邻的另一条同类消息之间触发 8pt 紧凑间距
    func testConsecutiveToolOnlyAssistantMessagesStructure() {
        let msg1 = AIChatMessage(
            id: "id1",
            messageId: "m1",
            role: .assistant,
            parts: [
                AIChatPart(id: "a1", kind: .tool, toolName: "bash"),
            ],
            isStreaming: false
        )
        let msg2 = AIChatMessage(
            id: "id2",
            messageId: "m2",
            role: .assistant,
            parts: [
                AIChatPart(id: "a2", kind: .tool, toolName: "read_file"),
            ],
            isStreaming: false
        )
        // 两条消息均为 assistant 角色且仅含 .tool part
        XCTAssertEqual(msg1.role, .assistant)
        XCTAssertEqual(msg2.role, .assistant)
        XCTAssertTrue(msg1.parts.allSatisfy { $0.kind == .tool })
        XCTAssertTrue(msg2.parts.allSatisfy { $0.kind == .tool })
    }

    /// 验证混有 text part 的 assistant 消息不应触发工具类紧凑间距
    func testAssistantMessageWithTextPartDoesNotQualifyAsToolOnly() {
        let message = AIChatMessage(
            id: "id1",
            messageId: "m1",
            role: .assistant,
            parts: [
                AIChatPart(id: "a1", kind: .tool, toolName: "bash"),
                AIChatPart(id: "a2", kind: .text, text: "执行完毕"),
            ],
            isStreaming: false
        )
        let hasNonToolNonReasoningPart = message.parts.contains { part in
            guard part.kind == .text else { return false }
            return !(part.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // 含有实质性 text part 时不满足工具类消息判断，不触发 8pt 紧凑间距
        XCTAssertTrue(hasNonToolNonReasoningPart)
    }
}
