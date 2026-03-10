use super::CodexAppServerAgent;
use crate::ai::{AiQuestionInfo, AiQuestionRequest};
use std::collections::HashMap;

#[test]
fn map_turn_items_to_messages_groups_user_and_assistant_parts_by_turn() {
    let items = vec![
        serde_json::json!({
            "id": "item-user-1",
            "type": "userMessage",
            "content": [
                { "type": "text", "text": "请修复会话详情渲染。" }
            ]
        }),
        serde_json::json!({
            "id": "item-agent-1",
            "type": "agentMessage",
            "text": "先检查日志和原始结构。",
            "phase": "commentary"
        }),
        serde_json::json!({
            "id": "item-reason-1",
            "type": "reasoning",
            "summary": ["准备对照 thread/read 返回结构"],
            "content": []
        }),
        serde_json::json!({
            "id": "item-read-1",
            "type": "commandExecution",
            "status": "completed",
            "command": "sed -n '1,120p' docs/PROTOCOL.md",
            "commandActions": [
                { "type": "read", "path": "docs/PROTOCOL.md", "command": "sed -n '1,120p' docs/PROTOCOL.md" }
            ],
            "aggregatedOutput": "protocol"
        }),
    ];

    let messages = CodexAppServerAgent::map_turn_items_to_messages(
        "session-1",
        "turn-1",
        &items,
        &HashMap::new(),
    );

    assert_eq!(messages.len(), 2);
    assert_eq!(messages[0].id, "codex-user-session-1-turn-1");
    assert_eq!(messages[0].role, "user");
    assert_eq!(messages[0].parts.len(), 1);
    assert_eq!(messages[0].parts[0].text.as_deref(), Some("请修复会话详情渲染。"));

    assert_eq!(messages[1].id, "codex-assistant-session-1-turn-1");
    assert_eq!(messages[1].role, "assistant");
    assert_eq!(messages[1].parts.len(), 3);
    assert_eq!(messages[1].parts[0].part_type, "text");
    assert_eq!(messages[1].parts[1].part_type, "reasoning");
    assert_eq!(messages[1].parts[2].part_type, "tool");
}

#[test]
fn map_turn_items_to_messages_rewrites_question_tool_call_id_to_pending_request_id() {
    let items = vec![
        serde_json::json!({
            "id": "item-user-1",
            "type": "userMessage",
            "content": [
                { "type": "text", "text": "继续执行" }
            ]
        }),
        serde_json::json!({
            "id": "item-question-1",
            "type": "question",
            "status": "completed",
            "questions": [
                {
                    "id": "confirm",
                    "header": "确认",
                    "question": "继续吗？",
                    "options": [
                        { "label": "继续", "description": "继续当前流程" }
                    ],
                    "multiple": false,
                    "custom": false
                }
            ]
        }),
    ];
    let pending_request_id_by_item_id = HashMap::from([(
        "item-question-1".to_string(),
        "pending-request-1".to_string(),
    )]);

    let messages = CodexAppServerAgent::map_turn_items_to_messages(
        "session-1",
        "turn-1",
        &items,
        &pending_request_id_by_item_id,
    );

    assert_eq!(messages.len(), 2);
    assert_eq!(messages[1].parts.len(), 1);
    let part = &messages[1].parts[0];
    assert_eq!(part.part_type, "tool");
    assert_eq!(part.tool_call_id.as_deref(), Some("pending-request-1"));
    assert_eq!(
        part.tool_part_metadata
            .as_ref()
            .and_then(|value| value.get("request_id"))
            .and_then(|value| value.as_str()),
        Some("pending-request-1")
    );
}

#[test]
fn build_question_from_request_supports_snake_case_user_input() {
    let params = serde_json::json!({
        "thread_id": "thread-1",
        "item": { "id": "item-42" },
        "request": {
            "questions": [
                {
                    "id": "math",
                    "question": "1+1 等于几？",
                    "header": "测试",
                    "options": [
                        { "label": "1" },
                        { "label": "2", "description": "正确答案" }
                    ],
                    "allow_other": false
                }
            ]
        }
    });

    let (request, ids) = CodexAppServerAgent::build_question_from_request(
        "item/tool/request_user_input",
        "n:99",
        &params,
    )
    .expect("should parse question request");

    assert_eq!(request.session_id, "thread-1");
    assert_eq!(request.tool_message_id.as_deref(), Some("item-42"));
    assert_eq!(ids, vec!["math".to_string()]);
    assert_eq!(request.questions.len(), 1);
    assert_eq!(request.questions[0].question, "1+1 等于几？");
    assert_eq!(request.questions[0].options.len(), 2);
    assert!(!request.questions[0].custom);
}

#[test]
fn build_question_from_request_supports_app_server_v2_request_user_input_shape() {
    let params = serde_json::json!({
        "threadId": "thread-v2",
        "turnId": "turn-v2",
        "itemId": "call-v2",
        "questions": [
            {
                "id": "confirm_path",
                "header": "确认路径",
                "question": "是否继续？",
                "isOther": true,
                "isSecret": false,
                "options": [
                    { "label": "继续", "description": "按当前路径继续" },
                    { "label": "取消", "description": "停止当前流程" }
                ]
            }
        ]
    });

    let (request, ids) = CodexAppServerAgent::build_question_from_request(
        "item/tool/requestUserInput",
        "n:12",
        &params,
    )
    .expect("should parse app-server v2 requestUserInput");

    assert_eq!(request.session_id, "thread-v2");
    assert_eq!(request.tool_message_id.as_deref(), Some("call-v2"));
    assert_eq!(request.tool_call_id.as_deref(), Some("call-v2"));
    assert_eq!(ids, vec!["confirm_path".to_string()]);
    assert_eq!(request.questions.len(), 1);
    assert_eq!(request.questions[0].header, "确认路径");
    assert_eq!(request.questions[0].question, "是否继续？");
    assert_eq!(request.questions[0].options.len(), 2);
    assert!(request.questions[0].custom);
}

#[test]
fn build_question_from_request_supports_snake_case_approval() {
    let params = serde_json::json!({
        "thread_id": "thread-2",
        "command": "echo hello"
    });
    let (request, ids) = CodexAppServerAgent::build_question_from_request(
        "item/command_execution/request_approval",
        "n:7",
        &params,
    )
    .expect("should parse approval request");

    assert_eq!(request.session_id, "thread-2");
    assert_eq!(ids, vec!["decision".to_string()]);
    assert_eq!(request.questions.len(), 1);
}

#[test]
fn build_question_prompt_part_uses_stable_part_id_without_overwriting_message_id() {
    let request = AiQuestionRequest {
        id: "n:123".to_string(),
        session_id: "thread-3".to_string(),
        questions: vec![AiQuestionInfo {
            question: "允许执行命令？".to_string(),
            header: "Codex Approval".to_string(),
            options: vec![],
            multiple: false,
            custom: false,
        }],
        tool_message_id: Some("item-approval-1".to_string()),
        tool_call_id: Some("item-approval-1".to_string()),
    };

    let (message_id, part) = CodexAppServerAgent::build_question_prompt_part(&request);
    assert_eq!(message_id, "item-approval-1");
    assert_eq!(part.part_type, "tool");
    assert_eq!(part.id, "question-part-n-123");
    assert_ne!(part.id, message_id);
}

#[test]
fn should_ignore_error_notification_rejects_without_will_retry() {
    let params = serde_json::json!({
        "error": { "message": "Reconnecting... 1/5" }
    });
    assert!(!CodexAppServerAgent::should_ignore_error_notification(
        &params
    ));
}

#[test]
fn should_ignore_error_notification_when_will_retry_true() {
    let params = serde_json::json!({
        "error": { "message": "Connection dropped" },
        "willRetry": true
    });
    assert!(CodexAppServerAgent::should_ignore_error_notification(
        &params
    ));
}

#[test]
fn map_item_to_part_maps_command_execution_read_action() {
    let item = serde_json::json!({
        "id": "item-read-1",
        "type": "commandExecution",
        "command": "/bin/zsh -lc \"sed -n '1p' README.md\"",
        "cwd": "/tmp/demo",
        "status": "completed",
        "aggregatedOutput": "hello\n",
        "commandActions": [
            { "type": "read", "path": "README.md", "name": "README.md", "command": "sed -n '1p' README.md" }
        ]
    });

    let part =
        CodexAppServerAgent::map_item_to_part(&item, "completed").expect("map should succeed");
    assert_eq!(part.tool_name.as_deref(), Some("read"));

    let state = part.tool_state.expect("tool_state should exist");
    assert_eq!(
        state.get("status").and_then(|v| v.as_str()),
        Some("completed")
    );
    assert_eq!(
        state.pointer("/input/path").and_then(|v| v.as_str()),
        Some("README.md")
    );
    assert!(state.get("output").map(|v| v.is_null()).unwrap_or(true));
    assert_eq!(
        state.get("title").and_then(|v| v.as_str()),
        Some("read(README.md)")
    );
}

#[test]
fn map_item_to_part_marks_plan_source_metadata() {
    let item = serde_json::json!({
        "id": "item-plan-1",
        "type": "plan",
        "text": "- 第一步\n- 第二步"
    });

    let part =
        CodexAppServerAgent::map_item_to_part(&item, "completed").expect("map should succeed");
    assert_eq!(part.part_type, "text");
    assert_eq!(part.text.as_deref(), Some("- 第一步\n- 第二步"));
    assert_eq!(
        part.source
            .as_ref()
            .and_then(|v| v.get("vendor"))
            .and_then(|v| v.as_str()),
        Some("codex")
    );
    assert_eq!(
        part.source
            .as_ref()
            .and_then(|v| v.get("item_type"))
            .and_then(|v| v.as_str()),
        Some("plan")
    );
}

#[test]
fn map_item_to_part_marks_agent_message_phase_metadata() {
    let item = serde_json::json!({
        "id": "item-agent-1",
        "type": "agentMessage",
        "text": "处理中...",
        "phase": "commentary"
    });

    let part =
        CodexAppServerAgent::map_item_to_part(&item, "completed").expect("map should succeed");
    assert_eq!(part.part_type, "text");
    assert_eq!(part.text.as_deref(), Some("处理中..."));
    assert_eq!(
        part.source
            .as_ref()
            .and_then(|v| v.get("vendor"))
            .and_then(|v| v.as_str()),
        Some("codex")
    );
    assert_eq!(
        part.source
            .as_ref()
            .and_then(|v| v.get("item_type"))
            .and_then(|v| v.as_str()),
        Some("agentmessage")
    );
    assert_eq!(
        part.source
            .as_ref()
            .and_then(|v| v.get("message_phase"))
            .and_then(|v| v.as_str()),
        Some("commentary")
    );
}

#[test]
fn map_item_to_part_maps_file_change_changes_to_diff_and_files() {
    let item = serde_json::json!({
        "id": "item-change-1",
        "type": "fileChange",
        "status": "failed",
        "changes": [
            { "path": "a.txt", "kind": "update", "diff": "@@ -1 +1 @@\n-a\n+b\n" },
            { "path": "b.txt", "kind": "create", "diff": "@@ -0,0 +1 @@\n+new\n" }
        ]
    });

    let part =
        CodexAppServerAgent::map_item_to_part(&item, "completed").expect("map should succeed");
    assert_eq!(part.tool_name.as_deref(), Some("write"));

    let state = part.tool_state.expect("tool_state should exist");
    assert_eq!(state.get("status").and_then(|v| v.as_str()), Some("error"));
    assert_eq!(
        state.pointer("/input/path").and_then(|v| v.as_str()),
        Some("a.txt")
    );
    assert_eq!(
        state
            .pointer("/metadata/file_paths/0")
            .and_then(|v| v.as_str()),
        Some("a.txt")
    );
    assert!(state.pointer("/metadata/files").is_none());
    assert!(state
        .pointer("/metadata/diff")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .contains("@@ -1 +1 @@"));
}

#[test]
fn map_item_to_part_maps_command_execution_bash_with_minimal_input() {
    let item = serde_json::json!({
        "id": "item-bash-1",
        "type": "commandExecution",
        "status": "completed",
        "command": "/bin/zsh -lc 'git status --short'",
        "cwd": "/tmp/demo",
        "processId": "93504",
        "commandActions": [
            { "type": "unknown", "command": "git status --short" }
        ],
        "aggregatedOutput": "M core/src/ai/codex_adapter.rs\n"
    });

    let part =
        CodexAppServerAgent::map_item_to_part(&item, "completed").expect("map should succeed");
    assert_eq!(part.tool_name.as_deref(), Some("bash"));
    let state = part.tool_state.expect("tool_state should exist");
    assert_eq!(
        state.pointer("/input/command").and_then(|v| v.as_str()),
        Some("/bin/zsh -lc 'git status --short'")
    );
    assert!(state.pointer("/input/cwd").is_none());
    assert!(state.pointer("/input/process_id").is_none());
    assert!(state.pointer("/input/commandActions").is_none());
}

#[test]
fn map_item_to_part_maps_list_with_title_and_output_only() {
    let item = serde_json::json!({
        "id": "item-list-1",
        "type": "commandExecution",
        "status": "completed",
        "command": "/bin/zsh -lc \"ls -la app/TidyFlow | sed -n '1,220p'\"",
        "cwd": "/tmp/demo",
        "commandActions": [
            { "type": "listFiles", "command": "ls -la app/TidyFlow", "path": "app/TidyFlow" }
        ],
        "aggregatedOutput": "total 72\n-rw-r--r--  AppConfig.swift\n"
    });

    let part =
        CodexAppServerAgent::map_item_to_part(&item, "completed").expect("map should succeed");
    assert_eq!(part.tool_name.as_deref(), Some("list"));
    let state = part.tool_state.expect("tool_state should exist");
    assert_eq!(
        state.get("title").and_then(|v| v.as_str()),
        Some("list(/bin/zsh -lc \"ls -la app/TidyFlow | sed -n '1,220p'\")")
    );
    assert_eq!(
        state.get("output").and_then(|v| v.as_str()),
        Some("total 72\n-rw-r--r--  AppConfig.swift\n")
    );
    assert!(state.pointer("/input/path").is_none());
    assert!(state.pointer("/metadata/cwd").is_none());
    assert_eq!(
        state
            .pointer("/metadata")
            .and_then(|v| v.as_object())
            .map(|m| m.len()),
        Some(0)
    );
}

#[test]
fn extract_tool_output_delta_maps_command_execution_delta() {
    let params = serde_json::json!({
        "itemId": "item-cmd-1",
        "delta": "line1\n"
    });
    let mapped = CodexAppServerAgent::extract_tool_output_delta(
        "item/commandExecution/outputDelta",
        &params,
    )
    .expect("should map");
    assert_eq!(mapped.0, "item-cmd-1");
    assert_eq!(mapped.1, "output");
    assert_eq!(mapped.2, "line1\n");
}

#[test]
fn extract_tool_output_delta_maps_file_change_delta_with_snake_case_item_id() {
    let params = serde_json::json!({
        "item_id": "item-file-1",
        "delta": "diff chunk"
    });
    let mapped =
        CodexAppServerAgent::extract_tool_output_delta("item/fileChange/outputDelta", &params)
            .expect("should map");
    assert_eq!(mapped.0, "item-file-1");
    assert_eq!(mapped.1, "output");
    assert_eq!(mapped.2, "diff chunk");
}

#[test]
fn extract_tool_output_delta_maps_mcp_progress_message_to_output_line() {
    let params = serde_json::json!({
        "itemId": "item-mcp-1",
        "message": "正在读取 MCP 资源"
    });
    let mapped =
        CodexAppServerAgent::extract_tool_output_delta("item/mcpToolCall/progress", &params)
            .expect("should map");
    assert_eq!(mapped.0, "item-mcp-1");
    assert_eq!(mapped.1, "progress");
    assert_eq!(mapped.2, "正在读取 MCP 资源\n");
}

#[test]
fn extract_tool_output_delta_maps_terminal_interaction_stdin_to_progress_line() {
    let params = serde_json::json!({
        "itemId": "item-cmd-stdin-1",
        "stdin": "y"
    });
    let mapped = CodexAppServerAgent::extract_tool_output_delta(
        "item/commandExecution/terminalInteraction",
        &params,
    )
    .expect("should map");
    assert_eq!(mapped.0, "item-cmd-stdin-1");
    assert_eq!(mapped.1, "progress");
    assert_eq!(mapped.2, "stdin: y\n");
}

#[test]
fn extract_tool_output_delta_ignores_empty_payload() {
    let params = serde_json::json!({
        "itemId": "item-empty-1",
        "delta": ""
    });
    assert!(CodexAppServerAgent::extract_tool_output_delta(
        "item/commandExecution/outputDelta",
        &params
    )
    .is_none());

    let terminal_params = serde_json::json!({
        "itemId": "item-empty-stdin-1",
        "stdin": ""
    });
    assert!(CodexAppServerAgent::extract_tool_output_delta(
        "item/commandExecution/terminalInteraction",
        &terminal_params
    )
    .is_none());
}

#[test]
fn map_item_to_part_keeps_raw_for_unknown_tool() {
    let item = serde_json::json!({
        "id": "item-unknown-1",
        "type": "mcpToolCall",
        "status": "completed",
        "tool": "search_docs",
        "arguments": { "q": "tidyflow" }
    });

    let part =
        CodexAppServerAgent::map_item_to_part(&item, "completed").expect("map should succeed");
    assert_eq!(part.tool_name.as_deref(), Some("mcptoolcall"));
    let state = part.tool_state.expect("tool_state should exist");
    assert!(state
        .get("raw")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .contains("\"mcpToolCall\""));
}

#[test]
fn map_item_to_part_all_tool_types_produce_stable_kind_tool() {
    // 所有工具调用型 item 必须映射为 part_type == "tool"，确保前端平铺缓存不依赖特例分支
    let tool_items = vec![
        serde_json::json!({
            "id": "item-tool-cmd",
            "type": "commandExecution",
            "status": "completed",
            "command": "/bin/zsh -lc 'echo hi'",
            "commandActions": [{ "type": "unknown", "command": "echo hi" }]
        }),
        serde_json::json!({
            "id": "item-tool-file",
            "type": "fileChange",
            "status": "completed",
            "changes": [{ "path": "main.rs", "kind": "update", "diff": "@@ -1 +1 @@\n-a\n+b\n" }]
        }),
        serde_json::json!({
            "id": "item-tool-mcp",
            "type": "mcpToolCall",
            "status": "completed",
            "tool": "fetch_url"
        }),
    ];
    for item in &tool_items {
        let part =
            CodexAppServerAgent::map_item_to_part(item, "completed").expect("map should succeed");
        assert_eq!(
            part.part_type, "tool",
            "item type {:?} should map to part_type 'tool'",
            item["type"]
        );
        assert!(
            part.tool_state.is_some(),
            "item type {:?} should have tool_state",
            item["type"]
        );
    }
}

#[test]
fn map_item_to_part_plan_and_agent_message_produce_text_kind() {
    // plan 和 agentMessage 映射为 part_type == "text"，不混入 tool 序列
    let text_items = vec![
        serde_json::json!({
            "id": "item-plan",
            "type": "plan",
            "text": "步骤 1\n步骤 2"
        }),
        serde_json::json!({
            "id": "item-agent",
            "type": "agentMessage",
            "text": "正在分析...",
            "phase": "commentary"
        }),
    ];
    for item in &text_items {
        let part =
            CodexAppServerAgent::map_item_to_part(item, "completed").expect("map should succeed");
        assert_eq!(
            part.part_type, "text",
            "item type {:?} should map to part_type 'text'",
            item["type"]
        );
        assert!(
            part.tool_state.is_none(),
            "text-kind part should not have tool_state for item type {:?}",
            item["type"]
        );
    }
}
