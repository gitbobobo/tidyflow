import XCTest
@testable import TidyFlow

final class AIChatProtocolModelsTests: XCTestCase {
    func testAISessionListParsesAllFilterAndPaginationFields() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "sessions": [
                [
                    "project_name": "tidyflow",
                    "workspace_name": "default",
                    "ai_tool": "codex",
                    "id": "s1",
                    "title": "实现分页",
                    "updated_at": 123
                ],
                [
                    "project_name": "tidyflow",
                    "workspace_name": "default",
                    "ai_tool": "opencode",
                    "id": "s2",
                    "title": "修复 bug",
                    "updated_at": 122
                ]
            ],
            "has_more": true,
            "next_cursor": "cursor-1"
        ]

        let result = AISessionListV2.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.filterAIChatTool)
        XCTAssertEqual(result?.sessions.count, 2)
        XCTAssertEqual(result?.sessions.first?.aiTool, .codex)
        XCTAssertEqual(result?.sessions.last?.aiTool, .opencode)
        XCTAssertEqual(result?.hasMore, true)
        XCTAssertEqual(result?.nextCursor, "cursor-1")
    }

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
        ]

        let item = EvolutionWorkspaceItemV2.from(json: json)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.executions.count, 1)
        XCTAssertEqual(item?.executions.first?.sessionID, "sess-1")
        XCTAssertEqual(item?.executions.first?.durationMs, 5000)
        XCTAssertEqual(item?.executions.first?.toolCallCount, 2)
        XCTAssertEqual(item?.title, "当前循环标题")
        XCTAssertEqual(item?.terminalErrorMessage, "verify.result.json 校验失败: 缺少 summary 字段")
    }

    func testEvolutionWorkspaceItemLatestResolvedExecutionMatchesCurrentStageProfile() {
        let item = EvolutionWorkspaceItemV2(
            project: "tidyflow",
            workspace: "default",
            cycleID: "cycle-1",
            title: "当前循环",
            status: "running",
            currentStage: "verify.1",
            globalLoopRound: 1,
            loopRoundLimit: 3,
            verifyIteration: 1,
            verifyIterationLimit: 5,
            agents: [],
            executions: [
                EvolutionSessionExecutionEntryV2(
                    stage: "plan",
                    agent: "PlanAgent",
                    aiTool: "codex",
                    sessionID: "sess-plan",
                    status: "done",
                    startedAt: "2026-03-09T10:00:00Z",
                    completedAt: "2026-03-09T10:01:00Z",
                    durationMs: 60_000,
                    toolCallCount: 2
                ),
                EvolutionSessionExecutionEntryV2(
                    stage: "verify.1",
                    agent: "VerifyAgent",
                    aiTool: "codex",
                    sessionID: "sess-verify-1",
                    status: "running",
                    startedAt: "2026-03-09T10:02:00Z",
                    completedAt: nil,
                    durationMs: nil,
                    toolCallCount: 0
                )
            ],
            terminalReasonCode: nil,
            terminalErrorMessage: nil,
            rateLimitErrorMessage: nil
        )

        let execution = item.latestResolvedExecution(forStage: "verify")
        XCTAssertEqual(execution?.sessionID, "sess-verify-1")
        XCTAssertEqual(execution?.stage, "verify.1")
    }

    func testEvolutionWorkspaceItemLatestResolvedExecutionReturnsNilWhenStageHasNoSession() {
        let item = EvolutionWorkspaceItemV2(
            project: "tidyflow",
            workspace: "default",
            cycleID: "cycle-2",
            title: nil,
            status: "running",
            currentStage: "implement.general.1",
            globalLoopRound: 1,
            loopRoundLimit: 3,
            verifyIteration: 0,
            verifyIterationLimit: 5,
            agents: [],
            executions: [],
            terminalReasonCode: nil,
            terminalErrorMessage: nil,
            rateLimitErrorMessage: nil
        )

        XCTAssertNil(item.latestResolvedExecution(forStage: "implement_general"))
    }

    func testEvolutionWorkspaceItemLatestResolvedExecutionKeepsNewestRetry() {
        let item = EvolutionWorkspaceItemV2(
            project: "tidyflow",
            workspace: "default",
            cycleID: "cycle-3",
            title: nil,
            status: "running",
            currentStage: "implement.general.2",
            globalLoopRound: 1,
            loopRoundLimit: 3,
            verifyIteration: 0,
            verifyIterationLimit: 5,
            agents: [],
            executions: [
                EvolutionSessionExecutionEntryV2(
                    stage: "implement.general.1",
                    agent: "ImplementGeneralAgent",
                    aiTool: "copilot",
                    sessionID: "sess-old",
                    status: "failed",
                    startedAt: "2026-03-09T09:00:00Z",
                    completedAt: "2026-03-09T09:02:00Z",
                    durationMs: 120_000,
                    toolCallCount: 4
                ),
                EvolutionSessionExecutionEntryV2(
                    stage: "implement.general.2",
                    agent: "ImplementGeneralAgent",
                    aiTool: "copilot",
                    sessionID: "sess-new",
                    status: "running",
                    startedAt: "2026-03-09T09:05:00Z",
                    completedAt: nil,
                    durationMs: nil,
                    toolCallCount: 1
                )
            ],
            terminalReasonCode: nil,
            terminalErrorMessage: nil,
            rateLimitErrorMessage: nil
        )

        let execution = item.latestResolvedExecution(forStage: "implement_general")
        XCTAssertEqual(execution?.sessionID, "sess-new")
        XCTAssertEqual(execution?.stage, "implement.general.2")
    }

    func testEvolutionWorkspaceItemLatestResolvedExecutionByExactStageDoesNotCrossStageInstance() {
        let item = EvolutionWorkspaceItemV2(
            project: "tidyflow",
            workspace: "default",
            cycleID: "cycle-4",
            title: nil,
            status: "running",
            currentStage: "implement.general.2",
            globalLoopRound: 1,
            loopRoundLimit: 3,
            verifyIteration: 0,
            verifyIterationLimit: 5,
            agents: [],
            executions: [
                EvolutionSessionExecutionEntryV2(
                    stage: "implement.general.1",
                    agent: "ImplementGeneralAgent",
                    aiTool: "codex",
                    sessionID: "sess-general-1",
                    status: "done",
                    startedAt: "2026-03-09T09:00:00Z",
                    completedAt: "2026-03-09T09:01:00Z",
                    durationMs: 60_000,
                    toolCallCount: 2
                ),
                EvolutionSessionExecutionEntryV2(
                    stage: "implement.general.2",
                    agent: "ImplementGeneralAgent",
                    aiTool: "codex",
                    sessionID: "sess-general-2",
                    status: "running",
                    startedAt: "2026-03-09T09:02:00Z",
                    completedAt: nil,
                    durationMs: nil,
                    toolCallCount: 1
                )
            ],
            terminalReasonCode: nil,
            terminalErrorMessage: nil,
            rateLimitErrorMessage: nil
        )

        let exact = item.latestResolvedExecution(forExactStage: "implement.general.1")
        XCTAssertEqual(exact?.sessionID, "sess-general-1")
    }

    func testEvolutionWorkspaceItemDerivesActiveAgentsFromAgentStatus() {
        let json: [String: Any] = [
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
            "agents": [
                [
                    "stage": "implement_general",
                    "agent": "ImplementGeneralAgent",
                    "status": "running",
                    "tool_call_count": 1
                ],
                [
                    "stage": "verify",
                    "agent": "VerifyAgent",
                    "status": "completed",
                    "tool_call_count": 0
                ]
            ]
        ]
        let item = EvolutionWorkspaceItemV2.from(json: json)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.currentStage, "implement_general")
        XCTAssertEqual(item?.globalLoopRound, 19)
        XCTAssertEqual(item?.activeAgents, ["ImplementGeneralAgent"])
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
            "executions": []
        ]
        let ev = EvoCycleUpdatedV2.from(json: json)
        XCTAssertNotNil(ev)
        XCTAssertEqual(ev?.project, "tidyflow")
        XCTAssertEqual(ev?.currentStage, "verify")
        XCTAssertEqual(ev?.verifyIteration, 1)
    }

    func testEvolutionCycleHistoryParsesExecutionsAndStrictTitleField() {
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

        let withoutTitle: [String: Any] = [
            "cycle_id": "cycle-2",
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
        let parsedWithoutTitle = EvolutionCycleHistoryItemV2.from(json: withoutTitle)
        XCTAssertEqual(parsedWithoutTitle?.executions.count, 0)
        XCTAssertEqual(parsedWithoutTitle?.stages.count, 1)
        XCTAssertNil(parsedWithoutTitle?.title)
        XCTAssertEqual(parsedWithoutTitle?.stages.first?.stage, "plan")
    }

    func testAIProtocolPartInfoParsesStructuredToolView() {
        let json: [String: Any] = [
            "id": "tool-1",
            "part_type": "tool",
            "tool_name": "bash",
            "tool_call_id": "call-1",
            "tool_kind": "terminal",
            "tool_view": [
                "status": "running",
                "display_title": "执行测试",
                "status_text": "running",
                "summary": "正在执行 npm test",
                "header_command_summary": "npm test",
                "duration_ms": 321.5,
                "sections": [
                    [
                        "id": "terminal-output",
                        "title": "output",
                        "content": "running",
                        "style": "terminal",
                        "copyable": true,
                        "collapsed_by_default": false
                    ]
                ],
                "locations": [
                    [
                        "path": "src/main.ts",
                        "line": 12,
                        "column": 4,
                        "end_line": 12,
                        "end_column": 22,
                        "label": "诊断"
                    ]
                ]
            ]
        ]

        let part = AIProtocolPartInfo.from(json: json)
        XCTAssertNotNil(part)
        XCTAssertEqual(part?.toolKind, "terminal")
        XCTAssertEqual(part?.toolView?.status, .running)
        XCTAssertEqual(part?.toolView?.displayTitle, "执行测试")
        XCTAssertEqual(part?.toolView?.summary, "正在执行 npm test")
        XCTAssertEqual(part?.toolView?.headerCommandSummary, "npm test")
        XCTAssertEqual(part?.toolView?.durationMs, 321.5)
        XCTAssertEqual(part?.toolView?.sections.count, 1)
        XCTAssertEqual(part?.toolView?.sections.first?.style, .terminal)
        XCTAssertEqual(part?.toolView?.sections.first?.content, "running")
        XCTAssertEqual(part?.toolView?.locations.count, 1)
        XCTAssertEqual(part?.toolView?.locations.first?.path, "src/main.ts")
        XCTAssertEqual(part?.toolView?.locations.first?.endLine, 12)
    }

    func testAIToolViewQuestionParsesStructuredPromptAndAnswers() {
        let question = AIToolViewQuestion.from(json: [
            "request_id": "req-1",
            "tool_message_id": "tool-msg-1",
            "interactive": true,
            "prompt_items": [
                [
                    "question": "是否继续？",
                    "header": "确认",
                    "multiple": false,
                    "custom": true,
                    "options": [
                        [
                            "option_id": "allow-once",
                            "label": "继续",
                            "description": "仅本次允许"
                        ]
                    ]
                ]
            ],
            "answers": [
                ["继续"]
            ]
        ])

        XCTAssertNotNil(question)
        XCTAssertEqual(question?.requestID, "req-1")
        XCTAssertEqual(question?.toolMessageID, "tool-msg-1")
        XCTAssertEqual(question?.interactive, true)
        XCTAssertEqual(question?.promptItems.count, 1)
        XCTAssertEqual(question?.promptItems.first?.question, "是否继续？")
        XCTAssertEqual(question?.promptItems.first?.options.first?.optionID, "allow-once")
        XCTAssertEqual(question?.answers?.first?.first, "继续")
    }

    func testAIToolViewParsesLinkedSessionAndUnknownStatusFallback() {
        let toolView = AIToolView.from(json: [
            "status": "not-supported",
            "display_title": "方向",
            "status_text": "unknown",
            "sections": [],
            "locations": [],
            "linked_session": [
                "session_id": "session-1",
                "agent_name": "DirectionAgent",
                "description": "继续在子会话中执行"
            ]
        ])

        XCTAssertNotNil(toolView)
        XCTAssertEqual(toolView?.status, .unknown)
        XCTAssertEqual(toolView?.linkedSession?.sessionID, "session-1")
        XCTAssertEqual(toolView?.linkedSession?.agentName, "DirectionAgent")
        XCTAssertEqual(toolView?.linkedSession?.description, "继续在子会话中执行")
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
                        toolView: makeQuestionToolView(status: .running, requestId: "req-fallback")
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
                        toolView: makeQuestionToolView(status: .error, requestId: "req-fallback-failed")
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
        XCTAssertEqual(messages[0].parts[0].toolView?.status, .completed)
        XCTAssertEqual(messages[0].parts[0].toolView?.question?.answers?.first?.first, "继续执行")
        XCTAssertEqual(messages[1].parts[0].toolView?.status, .error)
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
            toolView: AIToolView(
                status: .running,
                displayTitle: "补丁",
                statusText: "running",
                summary: "正在编辑 a.txt",
                headerCommandSummary: nil,
                durationMs: 18,
                sections: [
                    AIToolViewSection(
                        id: "edit-diff",
                        title: "diff",
                        content: "+x",
                        style: .diff,
                        language: "diff",
                        copyable: true,
                        collapsedByDefault: false
                    )
                ],
                locations: [
                    AIToolViewLocation(
                        uri: nil,
                        path: "a.txt",
                        line: 3,
                        column: 1,
                        endLine: 4,
                        endColumn: 2,
                        label: "hunk"
                    )
                ],
                question: nil,
                linkedSession: nil
            )
        )

        let part = AIChatPartNormalization.makeChatPart(from: proto)
        XCTAssertEqual(part.kind, .tool)
        XCTAssertEqual(part.toolKind, "diff")
        XCTAssertEqual(part.toolView?.displayTitle, "补丁")
        XCTAssertEqual(part.toolView?.summary, "正在编辑 a.txt")
        XCTAssertEqual(part.toolView?.sections.first?.content, "+x")
        XCTAssertEqual(part.toolView?.locations.first?.path, "a.txt")
        XCTAssertEqual(part.toolView?.locations.first?.endColumn, 2)
        XCTAssertEqual(part.source?["vendor"] as? String, "acp")
    }

    func testStructuredToolViewPreservesMarkdownDiffTerminalAndLocationsSections() {
        let toolView = AIToolView(
            status: .running,
            displayTitle: "终端",
            statusText: "running",
            summary: "正在处理",
            headerCommandSummary: "npm test",
            durationMs: nil,
            sections: [
                AIToolViewSection(
                    id: "markdown-output",
                    title: "markdown",
                    content: "# 标题",
                    style: .markdown,
                    language: nil,
                    copyable: true,
                    collapsedByDefault: false
                ),
                AIToolViewSection(
                    id: "edit-diff",
                    title: "diff",
                    content: "@@ -1 +1 @@\n-old\n+new",
                    style: .diff,
                    language: "diff",
                    copyable: true,
                    collapsedByDefault: false
                ),
                AIToolViewSection(
                    id: "terminal-output",
                    title: "output",
                    content: "npm test\nok",
                    style: .terminal,
                    language: "bash",
                    copyable: true,
                    collapsedByDefault: false
                ),
                AIToolViewSection(
                    id: "terminal-progress",
                    title: "progress",
                    content: "50%",
                    style: .text,
                    language: nil,
                    copyable: false,
                    collapsedByDefault: true
                )
            ],
            locations: [
                AIToolViewLocation(
                    uri: nil,
                    path: "doc.md",
                    line: 1,
                    column: nil,
                    endLine: nil,
                    endColumn: nil,
                    label: "标题"
                )
            ],
            question: nil,
            linkedSession: nil
        )

        XCTAssertEqual(toolView.sections.map(\.id), ["markdown-output", "edit-diff", "terminal-output", "terminal-progress"])
        XCTAssertEqual(toolView.sections[0].style, .markdown)
        XCTAssertEqual(toolView.sections[1].style, .diff)
        XCTAssertEqual(toolView.sections[2].style, .terminal)
        XCTAssertEqual(toolView.locations.first?.path, "doc.md")
        XCTAssertEqual(toolView.locations.first?.line, 1)
    }

    func testStructuredToolViewUsesCommandSummaryAndDisplayTitleFromProtocol() {
        let toolView = AIToolView(
            status: .completed,
            displayTitle: "terminal",
            statusText: "completed",
            summary: nil,
            headerCommandSummary: "ls -la",
            durationMs: 1200,
            sections: [
                AIToolViewSection(
                    id: "terminal-output",
                    title: "output",
                    content: "total 8",
                    style: .terminal,
                    language: "bash",
                    copyable: true,
                    collapsedByDefault: false
                )
            ],
            locations: [],
            question: nil,
            linkedSession: nil
        )

        XCTAssertEqual(toolView.displayTitle, "terminal")
        XCTAssertEqual(toolView.headerCommandSummary, "ls -la")
        XCTAssertEqual(toolView.sections.map(\.id), ["terminal-output"])
    }

    func testStructuredToolViewCarriesLinkedSessionAndQuestionPayload() {
        let toolView = AIToolView(
            status: .pending,
            displayTitle: "方向",
            statusText: "pending",
            summary: "等待用户确认",
            headerCommandSummary: nil,
            durationMs: nil,
            sections: [],
            locations: [],
            question: AIToolViewQuestion(
                requestID: "req-structured",
                toolMessageID: "tool-msg-9",
                promptItems: [
                    AIQuestionInfo(
                        question: "是否继续？",
                        header: "确认",
                        options: [
                            AIQuestionOptionInfo(optionID: "continue", label: "继续", description: "继续执行")
                        ],
                        multiple: false,
                        custom: false
                    )
                ],
                interactive: true,
                answers: nil
            ),
            linkedSession: AIToolLinkedSession(
                sessionID: "session-2",
                agentName: "DirectionAgent",
                description: "继续在子会话中执行"
            )
        )

        XCTAssertEqual(toolView.question?.requestID, "req-structured")
        XCTAssertEqual(toolView.question?.promptItems.first?.options.first?.optionID, "continue")
        XCTAssertEqual(toolView.linkedSession?.sessionID, "session-2")
        XCTAssertEqual(toolView.linkedSession?.agentName, "DirectionAgent")
    }

    func testAISessionMessagesToChatMessagesMapsStructuredToolView() {
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
                            toolView: AIToolView(
                                status: .running,
                                displayTitle: "运行命令",
                                statusText: "running",
                                summary: "列出目录",
                                headerCommandSummary: "ls",
                                durationMs: nil,
                                sections: [
                                    AIToolViewSection(
                                        id: "terminal-output",
                                        title: "output",
                                        content: "ok",
                                        style: .terminal,
                                        language: "bash",
                                        copyable: true,
                                        collapsedByDefault: false
                                    )
                                ],
                                locations: [
                                    AIToolViewLocation(
                                        uri: "file:///tmp/a",
                                        path: nil,
                                        line: 9,
                                        column: 3,
                                        endLine: nil,
                                        endColumn: nil,
                                        label: "ref"
                                    )
                                ],
                                question: nil,
                                linkedSession: nil
                            )
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
        XCTAssertEqual(part?.toolView?.displayTitle, "运行命令")
        XCTAssertEqual(part?.toolView?.headerCommandSummary, "ls")
        XCTAssertEqual(part?.toolView?.locations.first?.uri, "file:///tmp/a")
        XCTAssertEqual(part?.toolView?.locations.first?.line, 9)
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

    // MARK: - Codex thought_level / reasoning_effort 相关测试

    /// 验证 AISessionConfigOptionsResult 能正确解析 Codex 静态 thought_level 选项（含 low/medium/high 三档）
    func testCodexThoughtLevelSessionConfigOptionParsesThreeChoices() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "codex",
            "session_id": "s-codex-1",
            "options": [
                [
                    "option_id": "thought_level",
                    "category": "thought_level",
                    "name": "思考强度",
                    "description": "控制 Codex 推理深度：low 快速，medium 均衡，high 深入",
                    "options": [
                        ["value": "low",    "label": "low"],
                        ["value": "medium", "label": "medium"],
                        ["value": "high",   "label": "high"]
                    ],
                    "option_groups": []
                ]
            ]
        ]

        let result = AISessionConfigOptionsResult.from(json: json)
        XCTAssertNotNil(result, "AISessionConfigOptionsResult 不应为 nil")
        XCTAssertEqual(result?.aiTool, .codex)
        XCTAssertEqual(result?.sessionId, "s-codex-1")
        XCTAssertEqual(result?.options.count, 1)

        let option = result?.options.first
        XCTAssertEqual(option?.optionID, "thought_level")
        XCTAssertEqual(option?.category, "thought_level")
        XCTAssertEqual(option?.name, "思考强度")
        XCTAssertEqual(option?.options.count, 3)
        XCTAssertEqual(option?.optionGroups.count, 0)

        let labels = option?.options.map { $0.label } ?? []
        XCTAssertTrue(labels.contains("low"),    "缺少 low 选项")
        XCTAssertTrue(labels.contains("medium"), "缺少 medium 选项")
        XCTAssertTrue(labels.contains("high"),   "缺少 high 选项")

        let values = option?.options.compactMap { $0.value as? String } ?? []
        XCTAssertEqual(values, ["low", "medium", "high"])
    }

    /// 验证 thought_level 选项在 category 缺失时 optionID 可用作 category 兜底（协议松散解析）
    func testCodexThoughtLevelCategoryFallsBackToOptionID() {
        // category 缺失 —— 协议允许 nil，客户端以 optionID 推导
        let json: [String: Any] = [
            "option_id": "thought_level",
            "name": "思考强度",
            "options": [
                ["value": "medium", "label": "medium"]
            ],
            "option_groups": []
        ]
        let option = AIProtocolSessionConfigOptionInfo.from(json: json)
        XCTAssertNotNil(option)
        XCTAssertEqual(option?.optionID, "thought_level")
        // category 为 nil 时，AppState 通过 normalizedConfigCategory 将 optionID 作为 category
        XCTAssertNil(option?.category, "category 未提供时应为 nil，由调用方兜底")
    }

    /// 验证 AISessionConfigOptionsResult 解析时 thought_level currentValue 能正确传递
    func testCodexThoughtLevelCurrentValueRoundTrip() {
        let json: [String: Any] = [
            "project_name": "tidyflow",
            "workspace_name": "default",
            "ai_tool": "codex",
            "options": [
                [
                    "option_id": "thought_level",
                    "category": "thought_level",
                    "name": "思考强度",
                    "current_value": "high",
                    "options": [
                        ["value": "low",    "label": "low"],
                        ["value": "medium", "label": "medium"],
                        ["value": "high",   "label": "high"]
                    ],
                    "option_groups": []
                ]
            ]
        ]

        let result = AISessionConfigOptionsResult.from(json: json)
        XCTAssertNotNil(result)
        let option = result?.options.first
        XCTAssertEqual(option?.currentValue as? String, "high")
    }

    /// 验证 EvolutionStageProfileInfoV2 在 Codex 工具下对 low/medium/high 三档 thought_level 均可正确往返序列化
    func testEvolutionStageProfileInfoCodexThoughtLevelAllValues() {
        for level in ["low", "medium", "high"] {
            let json: [String: Any] = [
                "stage": "implement_general",
                "ai_tool": "codex",
                "mode": "code",
                "config_options": [
                    "thought_level": level
                ]
            ]
            let profile = EvolutionStageProfileInfoV2.from(json: json)
            XCTAssertNotNil(profile, "thought_level=\(level) 应能解析")
            XCTAssertEqual(profile?.configOptions["thought_level"] as? String, level)

            // 往返序列化
            let encoded = profile?.toJSON()
            let configOptions = encoded?["config_options"] as? [String: Any]
            XCTAssertEqual(configOptions?["thought_level"] as? String, level,
                           "thought_level=\(level) 序列化后应保持一致")
        }
    }

    /// 验证多工作区场景下不同工作区各自的 thought_level 配置不互相污染
    func testCodexThoughtLevelMultiWorkspaceIsolation() {
        // 模拟两个独立工作区的 EvolutionStageProfileInfo，配置值不同
        let jsonWs1: [String: Any] = [
            "stage": "direction",
            "ai_tool": "codex",
            "config_options": ["thought_level": "low"]
        ]
        let jsonWs2: [String: Any] = [
            "stage": "direction",
            "ai_tool": "codex",
            "config_options": ["thought_level": "high"]
        ]

        let profileWs1 = EvolutionStageProfileInfoV2.from(json: jsonWs1)
        let profileWs2 = EvolutionStageProfileInfoV2.from(json: jsonWs2)

        XCTAssertEqual(profileWs1?.configOptions["thought_level"] as? String, "low")
        XCTAssertEqual(profileWs2?.configOptions["thought_level"] as? String, "high")
        // 两个工作区配置对象独立，不应相互影响
        XCTAssertNotEqual(
            profileWs1?.configOptions["thought_level"] as? String,
            profileWs2?.configOptions["thought_level"] as? String
        )
    }

    // MARK: - AISessionSemantics 共享语义层

    func testMergedSelectionHintPrimaryWins() {
        let primary = AISessionSelectionHint(agent: "my-agent", modelProviderID: "anthropic", modelID: "claude-3", configOptions: nil)
        let fallback = AISessionSelectionHint(agent: "fallback-agent", modelProviderID: "openai", modelID: "gpt-4", configOptions: nil)
        let merged = AISessionSemantics.mergedSelectionHint(primary: primary, fallback: fallback)
        XCTAssertEqual(merged?.agent, "my-agent")
        XCTAssertEqual(merged?.modelProviderID, "anthropic")
        XCTAssertEqual(merged?.modelID, "claude-3")
    }

    func testMergedSelectionHintFallbackFillsMissingFields() {
        let primary = AISessionSelectionHint(agent: "my-agent", modelProviderID: nil, modelID: nil, configOptions: nil)
        let fallback = AISessionSelectionHint(agent: nil, modelProviderID: "openai", modelID: "gpt-4", configOptions: nil)
        let merged = AISessionSemantics.mergedSelectionHint(primary: primary, fallback: fallback)
        XCTAssertEqual(merged?.agent, "my-agent")
        XCTAssertEqual(merged?.modelProviderID, "openai")
        XCTAssertEqual(merged?.modelID, "gpt-4")
    }

    func testMergedSelectionHintNilPrimaryReturnsFallback() {
        let fallback = AISessionSelectionHint(agent: "fb", modelProviderID: nil, modelID: nil, configOptions: nil)
        let merged = AISessionSemantics.mergedSelectionHint(primary: nil, fallback: fallback)
        XCTAssertEqual(merged?.agent, "fb")
    }

    func testMergedSelectionHintConfigOptionsMerged() {
        let primary = AISessionSelectionHint(agent: nil, modelProviderID: nil, modelID: nil, configOptions: ["thought_level": "high"])
        let fallback = AISessionSelectionHint(agent: nil, modelProviderID: nil, modelID: nil, configOptions: ["thought_level": "low", "other": "value"])
        let merged = AISessionSemantics.mergedSelectionHint(primary: primary, fallback: fallback)
        XCTAssertEqual(merged?.configOptions?["thought_level"] as? String, "high", "primary configOptions 应覆盖 fallback")
        XCTAssertEqual(merged?.configOptions?["other"] as? String, "value", "fallback 独有字段应保留")
    }

    func testInferSelectionHintFromMessagesUserMessageFirst() {
        let userMsg = AIProtocolMessageInfo(
            id: "m1",
            role: "user",
            createdAt: nil,
            agent: "claude-agent",
            modelProviderID: "anthropic",
            modelID: "claude-3",
            parts: []
        )
        let assistantMsg = AIProtocolMessageInfo(
            id: "m2",
            role: "assistant",
            createdAt: nil,
            agent: "other-agent",
            modelProviderID: "openai",
            modelID: "gpt-4",
            parts: []
        )
        let hint = AISessionSemantics.inferSelectionHintFromMessages([userMsg, assistantMsg])
        XCTAssertEqual(hint?.agent, "claude-agent", "应优先从 user 消息推导 agent")
    }

    func testInferSelectionHintFromMessagesEmptyReturnsNil() {
        let hint = AISessionSemantics.inferSelectionHintFromMessages([])
        XCTAssertNil(hint)
    }

    func testRebuildPendingQuestionRequestsSkipsCompletedStatus() {
        let completedPart = AIProtocolPartInfo(
            id: "p-completed",
            partType: "tool",
            text: nil, mime: nil, filename: nil, url: nil,
            synthetic: nil, ignored: nil, source: nil,
            toolName: "question",
            toolCallId: "call-1",
            toolKind: nil,
            toolView: makeQuestionToolView(status: .completed, requestId: "req-1", question: "Hello?")
        )
        let message = AIProtocolMessageInfo(
            id: "m1", role: "assistant", createdAt: nil, agent: nil,
            modelProviderID: nil, modelID: nil, parts: [completedPart]
        )
        let requests = AISessionSemantics.rebuildPendingQuestionRequests(sessionId: "s1", messages: [message])
        XCTAssertTrue(requests.isEmpty, "completed 状态的 question part 不应重建为 pending request")
    }

    func testRebuildPendingQuestionRequestsBuildsActiveRequest() {
        let activePart = AIProtocolPartInfo(
            id: "p-active",
            partType: "tool",
            text: nil, mime: nil, filename: nil, url: nil,
            synthetic: nil, ignored: nil, source: nil,
            toolName: "question",
            toolCallId: "call-2",
            toolKind: nil,
            toolView: makeQuestionToolView(status: .pending, requestId: "req-2", question: "Continue?")
        )
        let message = AIProtocolMessageInfo(
            id: "m2", role: "assistant", createdAt: nil, agent: nil,
            modelProviderID: nil, modelID: nil, parts: [activePart]
        )
        let requests = AISessionSemantics.rebuildPendingQuestionRequests(sessionId: "sess-abc", messages: [message])
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.id, "req-2")
        XCTAssertEqual(requests.first?.sessionId, "sess-abc")
        XCTAssertEqual(requests.first?.questions.count, 1)
    }

    func testRebuildPendingQuestionRequestsDeduplicatesByRequestId() {
        func makePart(id: String, callId: String) -> AIProtocolPartInfo {
            AIProtocolPartInfo(
                id: id, partType: "tool",
                text: nil, mime: nil, filename: nil, url: nil,
                synthetic: nil, ignored: nil, source: nil,
                toolName: "question", toolCallId: callId,
                toolKind: nil,
                toolView: makeQuestionToolView(status: .pending, requestId: "same-req-id", question: "Q?")
            )
        }
        let msg1 = AIProtocolMessageInfo(id: "m1", role: "assistant", createdAt: nil, agent: nil, modelProviderID: nil, modelID: nil, parts: [makePart(id: "p1", callId: "c1")])
        let msg2 = AIProtocolMessageInfo(id: "m2", role: "assistant", createdAt: nil, agent: nil, modelProviderID: nil, modelID: nil, parts: [makePart(id: "p2", callId: "c2")])
        let requests = AISessionSemantics.rebuildPendingQuestionRequests(sessionId: "s1", messages: [msg1, msg2])
        XCTAssertEqual(requests.count, 1, "相同 request_id 只应建立一条 pending request")
    }

    func testDefaultMessagesPageSizeIs50() {
        XCTAssertEqual(AISessionSemantics.defaultMessagesPageSize, 50)
    }

    private func makeQuestionToolView(
        status: AIToolStatus,
        requestId: String,
        question: String = "Q?"
    ) -> AIToolView {
        AIToolView(
            status: status,
            displayTitle: "question",
            statusText: status.rawValue,
            summary: nil,
            headerCommandSummary: nil,
            durationMs: nil,
            sections: [],
            locations: [],
            question: AIToolViewQuestion(
                requestID: requestId,
                toolMessageID: nil,
                promptItems: [
                    AIQuestionInfo(
                        question: question,
                        header: "确认",
                        options: [
                            AIQuestionOptionInfo(
                                optionID: "yes",
                                label: "yes",
                                description: "继续"
                            )
                        ],
                        multiple: false,
                        custom: false
                    )
                ],
                interactive: status != .completed && status != .error,
                answers: nil
            ),
            linkedSession: nil
        )
    }
}
