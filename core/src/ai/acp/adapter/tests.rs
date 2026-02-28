use super::{AcpAgent, AcpBackendProfile, AcpPlanEntry};
use crate::ai::acp::client::AcpSessionSummary;
use crate::ai::codex::manager::{AcpContentEncodingMode, CodexAppServerManager};
use crate::ai::{AiAudioPart, AiImagePart, AiSession, AiSlashCommand};
use serde_json::json;
use std::{collections::HashMap, sync::Arc};
use tokio::sync::Mutex;

#[test]
fn map_update_to_output_should_follow_acp_mapping_contract() {
    assert_eq!(
        AcpAgent::map_update_to_output("agent_thought_chunk"),
        Some(("reasoning", true))
    );
    assert_eq!(
        AcpAgent::map_update_to_output("agent_message_chunk"),
        Some(("text", true))
    );
    assert_eq!(
        AcpAgent::map_update_to_output("user_message_chunk"),
        Some(("text", false))
    );
    assert_eq!(AcpAgent::map_update_to_output("unknown"), None);
}

#[test]
fn terminal_update_detection_should_cover_common_variants() {
    assert!(AcpAgent::is_terminal_update("turn_complete", ""));
    assert!(AcpAgent::is_terminal_update("session_idle", ""));
    assert!(AcpAgent::is_terminal_update("foo_completed", ""));
    assert!(AcpAgent::is_terminal_update("", "done"));
    assert!(!AcpAgent::is_terminal_update("agent_message_chunk", ""));
}

#[test]
fn extract_available_commands_should_parse_common_shapes_and_input_hint() {
    let update = json!({
        "availableCommands": [
            {
                "name": "/build",
                "description": "构建项目",
                "input": { "hint": "--release" }
            }
        ],
        "available_commands": [
            {
                "name": "test",
                "description": "运行测试",
                "input_hint": "--unit"
            }
        ],
        "content": {
            "commands": {
                "deploy": {
                    "description": "发布",
                    "input": { "hint": "--prod" }
                },
                "/lint": {
                    "description": "静态检查",
                    "inputHint": "--fix"
                }
            }
        }
    });

    let commands = AcpAgent::extract_available_commands(&update);
    assert_eq!(commands.len(), 4);

    let find = |name: &str| commands.iter().find(|command| command.name == name);
    assert_eq!(
        find("build").and_then(|command| command.input_hint.as_deref()),
        Some("--release")
    );
    assert_eq!(
        find("test").and_then(|command| command.input_hint.as_deref()),
        Some("--unit")
    );
    assert_eq!(
        find("deploy").and_then(|command| command.input_hint.as_deref()),
        Some("--prod")
    );
    assert_eq!(
        find("lint").and_then(|command| command.input_hint.as_deref()),
        Some("--fix")
    );
}

#[test]
fn extract_available_commands_should_dedup_case_insensitive_with_latest_overwrite() {
    let update = json!({
        "availableCommands": [
            { "name": "Build", "description": "旧描述" },
            { "name": "build", "description": "新描述", "input_hint": "--release" }
        ],
        "content": {
            "available_commands": [
                { "name": "BUILD", "description": "最终描述", "input": { "hint": "--fast" } }
            ]
        }
    });

    let commands = AcpAgent::extract_available_commands(&update);
    assert_eq!(commands.len(), 1);
    assert_eq!(commands[0].name, "BUILD");
    assert_eq!(commands[0].description, "最终描述");
    assert_eq!(commands[0].input_hint.as_deref(), Some("--fast"));
}

#[tokio::test]
async fn slash_commands_for_should_prefer_session_cache_then_fallback_directory() {
    let manager = Arc::new(CodexAppServerManager::new(std::env::temp_dir()));
    let agent = AcpAgent::new(manager, AcpBackendProfile::copilot());
    let directory = "/tmp/tidyflow";

    AcpAgent::cache_available_commands(
        &agent.slash_commands_by_directory,
        &agent.slash_commands_by_session,
        directory,
        None,
        vec![AiSlashCommand {
            name: "build".to_string(),
            description: "目录命令".to_string(),
            action: "agent".to_string(),
            input_hint: Some("--release".to_string()),
        }],
    )
    .await;

    let fallback = agent.slash_commands_for(directory, Some("session-A")).await;
    assert_eq!(fallback.len(), 1);
    assert_eq!(fallback[0].name, "build");

    AcpAgent::cache_available_commands(
        &agent.slash_commands_by_directory,
        &agent.slash_commands_by_session,
        directory,
        Some("session-A"),
        vec![AiSlashCommand {
            name: "test".to_string(),
            description: "会话命令".to_string(),
            action: "agent".to_string(),
            input_hint: Some("--unit".to_string()),
        }],
    )
    .await;

    let from_session = agent.slash_commands_for(directory, Some("session-A")).await;
    assert_eq!(from_session.len(), 1);
    assert_eq!(from_session[0].name, "test");
    assert_eq!(from_session[0].input_hint.as_deref(), Some("--unit"));

    let fallback_other_session = agent.slash_commands_for(directory, Some("session-B")).await;
    assert_eq!(fallback_other_session.len(), 1);
    assert_eq!(fallback_other_session[0].name, "test");
}

#[test]
fn extract_plan_entries_should_parse_top_level_entries() {
    let update = json!({
        "sessionUpdate": "plan",
        "entries": [
            { "content": "实现解析器", "status": "in_progress", "priority": "high" },
            { "content": "补测试", "status": "pending" }
        ]
    });
    let entries = AcpAgent::extract_plan_entries(&update).expect("entries should parse");
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0].content, "实现解析器");
    assert_eq!(entries[0].status, "in_progress");
    assert_eq!(entries[0].priority.as_deref(), Some("high"));
    assert_eq!(entries[1].content, "补测试");
    assert_eq!(entries[1].status, "pending");
    assert_eq!(entries[1].priority, None);
}

#[test]
fn extract_plan_entries_should_parse_content_entries() {
    let update = json!({
        "sessionUpdate": "plan",
        "content": {
            "entries": [
                { "content": "A", "status": "completed" }
            ]
        }
    });
    let entries = AcpAgent::extract_plan_entries(&update).expect("entries should parse");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].content, "A");
    assert_eq!(entries[0].status, "completed");
}

#[test]
fn extract_plan_entries_should_allow_empty_entries() {
    let update = json!({
        "sessionUpdate": "plan",
        "entries": []
    });
    let entries = AcpAgent::extract_plan_entries(&update).expect("entries should parse");
    assert!(entries.is_empty());
}

#[test]
fn extract_plan_entries_should_skip_invalid_entries() {
    let update = json!({
        "sessionUpdate": "plan",
        "entries": [
            { "content": "有效", "status": "pending" },
            { "content": "", "status": "pending" },
            { "status": "pending" },
            { "content": "缺状态" }
        ]
    });
    let entries = AcpAgent::extract_plan_entries(&update).expect("entries should parse");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].content, "有效");
    assert_eq!(entries[0].status, "pending");
}

#[test]
fn apply_plan_update_should_replace_current_and_keep_history() {
    let mut current = None;
    let mut history = Vec::new();
    let mut revision = 0;

    let first = AcpAgent::apply_plan_update(
        &mut current,
        &mut history,
        &mut revision,
        vec![AcpPlanEntry {
            content: "步骤一".to_string(),
            status: "pending".to_string(),
            priority: None,
        }],
    );
    assert_eq!(first.revision, 1);
    assert!(history.is_empty());

    let second = AcpAgent::apply_plan_update(
        &mut current,
        &mut history,
        &mut revision,
        vec![AcpPlanEntry {
            content: "步骤一".to_string(),
            status: "completed".to_string(),
            priority: Some("high".to_string()),
        }],
    );
    assert_eq!(second.revision, 2);
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].revision, 1);
    assert_eq!(current.expect("current should exist").revision, 2);
}

#[test]
fn apply_plan_update_should_cap_history_size() {
    let mut current = None;
    let mut history = Vec::new();
    let mut revision = 0;

    for index in 0..25 {
        let status = if index % 2 == 0 {
            "pending".to_string()
        } else {
            "in_progress".to_string()
        };
        AcpAgent::apply_plan_update(
            &mut current,
            &mut history,
            &mut revision,
            vec![AcpPlanEntry {
                content: format!("步骤{}", index + 1),
                status,
                priority: None,
            }],
        );
    }

    assert_eq!(revision, 25);
    assert_eq!(history.len(), AcpAgent::PLAN_HISTORY_LIMIT);
    assert_eq!(history.first().map(|item| item.revision), Some(5));
    assert_eq!(history.last().map(|item| item.revision), Some(24));
    assert_eq!(current.as_ref().map(|item| item.revision), Some(25));
}

#[test]
fn build_plan_source_should_include_current_and_history() {
    let mut current = None;
    let mut history = Vec::new();
    let mut revision = 0;

    AcpAgent::apply_plan_update(
        &mut current,
        &mut history,
        &mut revision,
        vec![AcpPlanEntry {
            content: "实现解析器".to_string(),
            status: "pending".to_string(),
            priority: None,
        }],
    );
    let latest = AcpAgent::apply_plan_update(
        &mut current,
        &mut history,
        &mut revision,
        vec![AcpPlanEntry {
            content: "实现解析器".to_string(),
            status: "in_progress".to_string(),
            priority: Some("high".to_string()),
        }],
    );

    let source = super::plan::build_plan_source(&latest, &history);
    assert_eq!(source.get("vendor").and_then(|v| v.as_str()), Some("acp"));
    assert_eq!(
        source.get("item_type").and_then(|v| v.as_str()),
        Some("plan")
    );
    assert_eq!(
        source.get("protocol").and_then(|v| v.as_str()),
        Some("agent-plan")
    );
    assert_eq!(source.get("revision").and_then(|v| v.as_u64()), Some(2));
    assert_eq!(
        source
            .get("entries")
            .and_then(|v| v.as_array())
            .and_then(|items| items.first())
            .and_then(|entry| entry.get("status"))
            .and_then(|v| v.as_str()),
        Some("in_progress")
    );
    assert_eq!(
        source
            .get("history")
            .and_then(|v| v.as_array())
            .map(|items| items.len()),
        Some(1)
    );
    assert_eq!(
        source
            .get("history")
            .and_then(|v| v.as_array())
            .and_then(|items| items.first())
            .and_then(|snapshot| snapshot.get("revision"))
            .and_then(|v| v.as_u64()),
        Some(1)
    );
}

#[test]
fn flush_plan_snapshot_for_history_should_emit_plan_message() {
    let mut messages = Vec::new();
    let mut index = 0;
    let mut current = Some(super::AcpPlanSnapshot {
        revision: 2,
        updated_at_ms: 200,
        entries: vec![AcpPlanEntry {
            content: "补测试".to_string(),
            status: "in_progress".to_string(),
            priority: None,
        }],
    });
    let mut history = vec![super::AcpPlanSnapshot {
        revision: 1,
        updated_at_ms: 100,
        entries: vec![AcpPlanEntry {
            content: "补测试".to_string(),
            status: "pending".to_string(),
            priority: None,
        }],
    }];

    AcpAgent::flush_plan_snapshot_for_history(
        &mut messages,
        "tidyflow",
        &mut index,
        &mut current,
        &mut history,
    );

    assert_eq!(index, 1);
    assert!(current.is_none());
    assert!(history.is_empty());
    assert_eq!(messages.len(), 1);
    assert_eq!(messages[0].role, "assistant");
    assert_eq!(messages[0].parts.len(), 1);
    assert_eq!(messages[0].parts[0].part_type, "plan");
    let source = messages[0].parts[0]
        .source
        .as_ref()
        .expect("plan source should exist");
    assert_eq!(source.get("revision").and_then(|v| v.as_u64()), Some(2));
    assert_eq!(
        source
            .get("history")
            .and_then(|v| v.as_array())
            .map(|items| items.len()),
        Some(1)
    );
}

#[test]
fn compose_prompt_parts_should_build_native_contents_when_supported() {
    let parts = AcpAgent::compose_prompt_parts(
        "/tmp/workspace",
        "请分析这些内容",
        Some(vec![
            "/tmp/workspace/src/main.rs:12:5".to_string(),
            "docs/spec.md".to_string(),
        ]),
        Some(vec![AiImagePart {
            filename: "diagram.png".to_string(),
            mime: "image/png".to_string(),
            data: vec![1, 2, 3, 4],
        }]),
        Some(vec![AiAudioPart {
            filename: "voice.wav".to_string(),
            mime: "audio/wav".to_string(),
            data: vec![5, 6, 7, 8],
        }]),
        AcpContentEncodingMode::New,
        true,
        true,
        false,
        true,
    );

    assert_eq!(parts[0].get("type").and_then(|v| v.as_str()), Some("text"));
    assert_eq!(
        parts[0].get("text").and_then(|v| v.as_str()),
        Some("请分析这些内容")
    );
    assert_eq!(
        parts[1].get("type").and_then(|v| v.as_str()),
        Some("resource_link")
    );
    assert_eq!(
        parts[2].get("type").and_then(|v| v.as_str()),
        Some("resource_link")
    );
    assert_eq!(parts[3].get("type").and_then(|v| v.as_str()), Some("image"));
    assert_eq!(parts[4].get("type").and_then(|v| v.as_str()), Some("audio"));

    let image_count = parts
        .iter()
        .filter(|part| part.get("type").and_then(|v| v.as_str()) == Some("image"))
        .count();
    let audio_count = parts
        .iter()
        .filter(|part| part.get("type").and_then(|v| v.as_str()) == Some("audio"))
        .count();
    let resource_count = parts
        .iter()
        .filter(|part| part.get("type").and_then(|v| v.as_str()) == Some("resource_link"))
        .count();
    assert_eq!(image_count, 1);
    assert_eq!(audio_count, 1);
    assert_eq!(resource_count, 2);
}

#[test]
fn compose_prompt_parts_should_fallback_to_text_when_capability_missing() {
    let parts = AcpAgent::compose_prompt_parts(
        "/tmp/workspace",
        "原始问题",
        Some(vec!["docs/spec.md".to_string()]),
        Some(vec![AiImagePart {
            filename: "diagram.png".to_string(),
            mime: "image/png".to_string(),
            data: vec![9, 9, 9],
        }]),
        Some(vec![AiAudioPart {
            filename: "voice.wav".to_string(),
            mime: "audio/wav".to_string(),
            data: vec![1, 2, 3],
        }]),
        AcpContentEncodingMode::Legacy,
        false,
        false,
        false,
        false,
    );

    assert_eq!(parts.len(), 1);
    assert_eq!(parts[0].get("type").and_then(|v| v.as_str()), Some("text"));
    let text = parts[0].get("text").and_then(|v| v.as_str()).unwrap_or("");
    assert!(text.contains("原始问题"));
    assert!(text.contains("文件引用："));
    assert!(text.contains("图片附件："));
    assert!(text.contains("音频附件："));
}

#[test]
fn compose_prompt_parts_should_encode_image_audio_by_mode() {
    let new_parts = AcpAgent::compose_prompt_parts(
        "/tmp/workspace",
        "hello",
        None,
        Some(vec![AiImagePart {
            filename: "a.png".to_string(),
            mime: "image/png".to_string(),
            data: vec![1, 2],
        }]),
        Some(vec![AiAudioPart {
            filename: "a.wav".to_string(),
            mime: "audio/wav".to_string(),
            data: vec![3, 4],
        }]),
        AcpContentEncodingMode::New,
        true,
        true,
        false,
        false,
    );
    let new_image = new_parts
        .iter()
        .find(|part| part.get("type").and_then(|v| v.as_str()) == Some("image"))
        .expect("new image part");
    assert!(new_image.get("data").is_some());
    assert!(new_image.get("url").is_none());
    let new_audio = new_parts
        .iter()
        .find(|part| part.get("type").and_then(|v| v.as_str()) == Some("audio"))
        .expect("new audio part");
    assert!(new_audio.get("data").is_some());
    assert!(new_audio.get("url").is_none());

    let legacy_parts = AcpAgent::compose_prompt_parts(
        "/tmp/workspace",
        "hello",
        None,
        Some(vec![AiImagePart {
            filename: "a.png".to_string(),
            mime: "image/png".to_string(),
            data: vec![1, 2],
        }]),
        Some(vec![AiAudioPart {
            filename: "a.wav".to_string(),
            mime: "audio/wav".to_string(),
            data: vec![3, 4],
        }]),
        AcpContentEncodingMode::Legacy,
        true,
        true,
        false,
        false,
    );
    let legacy_image = legacy_parts
        .iter()
        .find(|part| part.get("type").and_then(|v| v.as_str()) == Some("image"))
        .expect("legacy image part");
    assert!(legacy_image.get("url").is_some());
    assert!(legacy_image.get("data").is_none());
    let legacy_audio = legacy_parts
        .iter()
        .find(|part| part.get("type").and_then(|v| v.as_str()) == Some("audio"))
        .expect("legacy audio part");
    assert!(legacy_audio.get("url").is_some());
    assert!(legacy_audio.get("data").is_none());
}

#[test]
fn compose_prompt_parts_should_embed_resource_text_and_blob_when_supported() {
    let temp = tempfile::tempdir().expect("temp dir");
    let text_path = temp.path().join("a.txt");
    let bin_path = temp.path().join("b.bin");
    std::fs::write(&text_path, "hello resource text").expect("write text");
    std::fs::write(&bin_path, vec![0, 159, 1, 2, 3]).expect("write bin");

    let parts = AcpAgent::compose_prompt_parts(
        temp.path().to_string_lossy().as_ref(),
        "资源测试",
        Some(vec![
            text_path.to_string_lossy().to_string(),
            bin_path.to_string_lossy().to_string(),
        ]),
        None,
        None,
        AcpContentEncodingMode::New,
        false,
        false,
        true,
        true,
    );

    let resource_parts = parts
        .iter()
        .filter(|part| part.get("type").and_then(|v| v.as_str()) == Some("resource"))
        .collect::<Vec<_>>();
    assert_eq!(resource_parts.len(), 2);
    assert!(resource_parts.iter().any(|part| {
        part.get("resource")
            .and_then(|v| v.get("text"))
            .and_then(|v| v.as_str())
            == Some("hello resource text")
    }));
    assert!(resource_parts.iter().any(|part| {
        part.get("resource")
            .and_then(|v| v.get("blob"))
            .and_then(|v| v.as_str())
            .is_some()
    }));
}

#[test]
fn compose_prompt_parts_should_downgrade_large_text_resource_to_link() {
    let temp = tempfile::tempdir().expect("temp dir");
    let big_text_path = temp.path().join("big.txt");
    let payload = "a".repeat(AcpAgent::EMBED_TEXT_LIMIT_BYTES + 1);
    std::fs::write(&big_text_path, payload).expect("write big text");

    let parts = AcpAgent::compose_prompt_parts(
        temp.path().to_string_lossy().as_ref(),
        "资源超限",
        Some(vec![big_text_path.to_string_lossy().to_string()]),
        None,
        None,
        AcpContentEncodingMode::New,
        false,
        false,
        true,
        true,
    );

    assert!(parts
        .iter()
        .any(|part| part.get("type").and_then(|v| v.as_str()) == Some("resource_link")));
    assert!(!parts
        .iter()
        .any(|part| part.get("type").and_then(|v| v.as_str()) == Some("resource")));
}

#[test]
fn map_content_to_non_text_parts_should_parse_supported_blocks() {
    let image = json!({
        "type": "image",
        "mimeType": "image/png",
        "data": "AQID",
        "annotations": { "origin": "stream" }
    });
    let image_parts =
        AcpAgent::map_content_to_non_text_parts("m1", image.as_object().expect("object"));
    assert_eq!(image_parts.len(), 1);
    assert_eq!(image_parts[0].part_type, "file");
    assert_eq!(image_parts[0].mime.as_deref(), Some("image/png"));
    assert!(image_parts[0]
        .url
        .as_deref()
        .is_some_and(|url| url.starts_with("data:image/png;base64,AQID")));

    let audio = json!({
        "type": "audio",
        "mime": "audio/wav",
        "url": "https://example.com/a.wav"
    });
    let audio_parts =
        AcpAgent::map_content_to_non_text_parts("m2", audio.as_object().expect("object"));
    assert_eq!(audio_parts.len(), 1);
    assert_eq!(audio_parts[0].part_type, "file");
    assert_eq!(
        audio_parts[0].url.as_deref(),
        Some("https://example.com/a.wav")
    );

    let resource_text = json!({
        "type": "resource",
        "resource": {
            "text": "embedded text"
        }
    });
    let resource_text_parts =
        AcpAgent::map_content_to_non_text_parts("m3", resource_text.as_object().expect("object"));
    assert_eq!(resource_text_parts.len(), 1);
    assert_eq!(resource_text_parts[0].part_type, "text");
    assert_eq!(
        resource_text_parts[0].text.as_deref(),
        Some("embedded text")
    );

    let resource_blob = json!({
        "type": "resource",
        "resource": {
            "mimeType": "application/octet-stream",
            "blob": "AAEC"
        }
    });
    let resource_blob_parts =
        AcpAgent::map_content_to_non_text_parts("m4", resource_blob.as_object().expect("object"));
    assert_eq!(resource_blob_parts.len(), 1);
    assert_eq!(resource_blob_parts[0].part_type, "file");
    assert!(resource_blob_parts[0]
        .url
        .as_deref()
        .is_some_and(|url| url.starts_with("data:application/octet-stream;base64,AAEC")));

    let resource_link_new = json!({
        "type": "resource_link",
        "uri": "file:///tmp/a.txt",
        "name": "a.txt"
    });
    let resource_link_new_parts = AcpAgent::map_content_to_non_text_parts(
        "m5",
        resource_link_new.as_object().expect("object"),
    );
    assert_eq!(resource_link_new_parts.len(), 1);
    assert_eq!(
        resource_link_new_parts[0].url.as_deref(),
        Some("file:///tmp/a.txt")
    );

    let resource_link_legacy = json!({
        "type": "resource_link",
        "resource": {
            "uri": "file:///tmp/b.txt",
            "name": "b.txt"
        }
    });
    let resource_link_legacy_parts = AcpAgent::map_content_to_non_text_parts(
        "m6",
        resource_link_legacy.as_object().expect("object"),
    );
    assert_eq!(resource_link_legacy_parts.len(), 1);
    assert_eq!(
        resource_link_legacy_parts[0].url.as_deref(),
        Some("file:///tmp/b.txt")
    );

    let markdown = json!({
        "type": "markdown",
        "markdown": "## 标题"
    });
    let markdown_parts =
        AcpAgent::map_content_to_non_text_parts("m7", markdown.as_object().expect("object"));
    assert_eq!(markdown_parts.len(), 1);
    assert_eq!(markdown_parts[0].part_type, "text");
    assert_eq!(markdown_parts[0].text.as_deref(), Some("## 标题"));

    let diff = json!({
        "type": "diff",
        "diff": "@@ -1 +1 @@\n-old\n+new"
    });
    let diff_parts =
        AcpAgent::map_content_to_non_text_parts("m8", diff.as_object().expect("object"));
    assert_eq!(diff_parts.len(), 1);
    assert_eq!(diff_parts[0].part_type, "text");
    assert!(diff_parts[0]
        .text
        .as_deref()
        .is_some_and(|text| text.contains("+new")));

    let terminal = json!({
        "type": "terminal",
        "output": "npm test"
    });
    let terminal_parts =
        AcpAgent::map_content_to_non_text_parts("m9", terminal.as_object().expect("object"));
    assert_eq!(terminal_parts.len(), 1);
    assert_eq!(terminal_parts[0].part_type, "text");
    assert_eq!(terminal_parts[0].text.as_deref(), Some("npm test"));
}

#[test]
fn parse_tool_call_update_content_should_extract_full_tool_fields() {
    let content = json!({
        "type": "tool_call_update",
        "toolCallId": "call-1",
        "toolName": "bash",
        "kind": "terminal",
        "title": "执行测试",
        "status": "in_progress",
        "rawInput": {
            "command": "npm test"
        },
        "rawOutput": {
            "type": "terminal",
            "output": "running..."
        },
        "locations": [
            {
                "path": "src/main.ts",
                "line": 10,
                "column": 2,
                "endLine": 10,
                "endColumn": 20,
                "label": "diagnostic"
            }
        ],
        "progress": "30%",
        "output": "running..."
    });
    let parsed =
        super::tool_call::parse_tool_call_update_content(content.as_object().expect("object"))
            .expect("should parse tool_call_update");
    assert_eq!(parsed.tool_call_id.as_deref(), Some("call-1"));
    assert_eq!(parsed.tool_name, "bash");
    assert_eq!(parsed.tool_kind.as_deref(), Some("terminal"));
    assert_eq!(parsed.tool_title.as_deref(), Some("执行测试"));
    assert_eq!(parsed.status.as_deref(), Some("running"));
    assert!(parsed.raw_input.is_some());
    assert!(parsed.raw_output.is_some());
    assert_eq!(
        parsed
            .locations
            .as_ref()
            .and_then(|rows| rows.first())
            .and_then(|row| row.path.as_deref()),
        Some("src/main.ts")
    );
    assert_eq!(parsed.progress_delta.as_deref(), Some("30%"));
    assert_eq!(parsed.output_delta.as_deref(), Some("running..."));
}

#[test]
fn parse_tool_call_update_content_should_preserve_unknown_fields_in_metadata() {
    let content = json!({
        "type": "tool_call_update",
        "toolCallId": "call-meta",
        "toolName": "task",
        "status": "running",
        "customPayload": {
            "foo": "bar",
            "nested": [1, 2, 3]
        }
    });
    let parsed =
        super::tool_call::parse_tool_call_update_content(content.as_object().expect("object"))
            .expect("should parse");
    assert_eq!(
        parsed
            .tool_part_metadata
            .get("customPayload")
            .and_then(|v| v.get("foo"))
            .and_then(|v| v.as_str()),
        Some("bar")
    );
}

#[test]
fn parse_tool_call_update_event_should_parse_root_level_tool_update() {
    let update = json!({
        "sessionUpdate": "tool_call_update",
        "toolCallId": "call-root",
        "toolName": "bash",
        "kind": "terminal",
        "status": "in_progress",
        "output": "running..."
    });
    let parsed = AcpAgent::parse_tool_call_update_event(&update, "tool_call_update")
        .expect("should parse root level tool update");
    assert_eq!(parsed.tool_call_id.as_deref(), Some("call-root"));
    assert_eq!(parsed.tool_name, "bash");
    assert_eq!(parsed.tool_kind.as_deref(), Some("terminal"));
    assert_eq!(parsed.status.as_deref(), Some("running"));
    assert_eq!(parsed.output_delta.as_deref(), Some("running..."));
}

#[test]
fn parse_tool_call_update_event_should_parse_nested_tool_call_payload() {
    let update = json!({
        "sessionUpdate": "tool_call_update",
        "status": "completed",
        "content": {
            "type": "terminal",
            "output": "done"
        },
        "toolCall": {
            "toolCallId": "call-nested",
            "toolName": "bash",
            "kind": "terminal",
            "rawInput": {
                "command": "npm test"
            }
        }
    });
    let parsed = AcpAgent::parse_tool_call_update_event(&update, "tool_call_update")
        .expect("should parse nested toolCall payload");
    assert_eq!(parsed.tool_call_id.as_deref(), Some("call-nested"));
    assert_eq!(parsed.tool_name, "bash");
    assert_eq!(parsed.tool_kind.as_deref(), Some("terminal"));
    assert_eq!(parsed.status.as_deref(), Some("completed"));
    assert_eq!(parsed.output_delta.as_deref(), Some("done"));
    assert_eq!(
        parsed
            .raw_input
            .as_ref()
            .and_then(|v| v.get("command"))
            .and_then(|v| v.as_str()),
        Some("npm test")
    );
}

#[test]
fn merge_tool_state_should_handle_incremental_and_out_of_order_updates() {
    let completed = super::ParsedToolCallUpdate {
        tool_call_id: Some("call-merge".to_string()),
        tool_name: "terminal".to_string(),
        tool_kind: Some("terminal".to_string()),
        tool_title: Some("执行".to_string()),
        status: Some("completed".to_string()),
        raw_input: Some(json!({"command": "npm test"})),
        raw_output: Some(json!({"type": "terminal", "output": "done"})),
        locations: None,
        progress_delta: Some("100%".to_string()),
        output_delta: Some("done".to_string()),
        tool_part_metadata: json!({ "type": "tool_call_update" }),
    };
    let late_running = super::ParsedToolCallUpdate {
        tool_call_id: Some("call-merge".to_string()),
        tool_name: "terminal".to_string(),
        tool_kind: Some("terminal".to_string()),
        tool_title: None,
        status: Some("running".to_string()),
        raw_input: None,
        raw_output: Some(json!({"type": "terminal", "output": "late"})),
        locations: None,
        progress_delta: Some("50%".to_string()),
        output_delta: Some("late".to_string()),
        tool_part_metadata: json!({ "type": "tool_call_update" }),
    };

    let merged_first = AcpAgent::merge_tool_state(None, &completed);
    assert_eq!(
        merged_first.get("status").and_then(|v| v.as_str()),
        Some("completed")
    );
    assert_eq!(
        merged_first.get("output").and_then(|v| v.as_str()),
        Some("done")
    );

    let merged_second = AcpAgent::merge_tool_state(Some(&merged_first), &late_running);
    assert_eq!(
        merged_second.get("status").and_then(|v| v.as_str()),
        Some("completed")
    );
    assert_eq!(
        merged_second.get("output").and_then(|v| v.as_str()),
        Some("donelate")
    );
    let progress_len = merged_second
        .get("metadata")
        .and_then(|v| v.get("progress_lines"))
        .and_then(|v| v.as_array())
        .map(|rows| rows.len());
    assert_eq!(progress_len, Some(2));
}

#[test]
fn normalize_tool_status_should_cover_acp_variants() {
    assert_eq!(
        super::tool_call::normalize_tool_status(Some("in_progress"), "running"),
        "running"
    );
    assert_eq!(
        super::tool_call::normalize_tool_status(Some("requires_input"), "running"),
        "awaiting_input"
    );
    assert_eq!(
        super::tool_call::normalize_tool_status(Some("done"), "running"),
        "completed"
    );
    assert_eq!(
        super::tool_call::normalize_tool_status(Some("failed"), "running"),
        "error"
    );
}

#[test]
fn parse_prompt_stop_reason_should_validate_contract() {
    assert_eq!(
        AcpAgent::parse_prompt_stop_reason(&json!({ "stopReason": "end_turn" }))
            .expect("end_turn should be accepted"),
        "end_turn"
    );
    assert!(AcpAgent::parse_prompt_stop_reason(&json!({})).is_err());
    assert!(AcpAgent::parse_prompt_stop_reason(&json!({ "stopReason": "custom_reason" })).is_err());
}

#[test]
fn select_sessions_for_directory_should_fallback_to_unknown_cwd_when_needed() {
    let page = vec![
        AcpSessionSummary {
            id: "a".to_string(),
            title: "A".to_string(),
            cwd: "".to_string(),
            updated_at_ms: 1,
        },
        AcpSessionSummary {
            id: "b".to_string(),
            title: "B".to_string(),
            cwd: "".to_string(),
            updated_at_ms: 2,
        },
    ];

    let (selected, used_fallback) = AcpAgent::select_sessions_for_directory(page, "/tmp/workspace");
    assert!(used_fallback);
    assert_eq!(selected.len(), 2);
}

#[test]
fn select_sessions_for_directory_should_prefer_exact_matches() {
    let page = vec![
        AcpSessionSummary {
            id: "a".to_string(),
            title: "A".to_string(),
            cwd: "/tmp/workspace".to_string(),
            updated_at_ms: 1,
        },
        AcpSessionSummary {
            id: "b".to_string(),
            title: "B".to_string(),
            cwd: "".to_string(),
            updated_at_ms: 2,
        },
        AcpSessionSummary {
            id: "c".to_string(),
            title: "C".to_string(),
            cwd: "/tmp/other".to_string(),
            updated_at_ms: 3,
        },
    ];

    let (selected, used_fallback) = AcpAgent::select_sessions_for_directory(page, "/tmp/workspace");
    assert!(!used_fallback);
    assert_eq!(selected.len(), 1);
    assert_eq!(selected[0].id, "a");
}

#[test]
fn normalize_directory_should_handle_file_urls() {
    assert_eq!(
        AcpAgent::normalize_directory("file:///tmp/workspace"),
        "/tmp/workspace"
    );
}

#[test]
fn backend_profile_should_expose_expected_provider_ids() {
    let copilot = AcpBackendProfile::copilot();
    assert_eq!(copilot.provider_id, "copilot");
    assert_eq!(copilot.provider_name, "Copilot");

    let kimi = AcpBackendProfile::kimi();
    assert_eq!(kimi.provider_id, "kimi");
    assert_eq!(kimi.provider_name, "Kimi");
}

#[test]
fn merge_sessions_should_include_cached_sessions_when_remote_empty() {
    let cached = vec![AiSession {
        id: "cached-1".to_string(),
        title: "Cached".to_string(),
        updated_at: 42,
    }];
    let merged = AcpAgent::merge_sessions(Vec::new(), cached);
    assert_eq!(merged.len(), 1);
    assert_eq!(merged[0].id, "cached-1");
}

#[test]
fn merge_sessions_should_merge_same_id_and_keep_newest_timestamp() {
    let remote = vec![AiSession {
        id: "same".to_string(),
        title: "Remote".to_string(),
        updated_at: 100,
    }];
    let cached = vec![AiSession {
        id: "same".to_string(),
        title: "Cached".to_string(),
        updated_at: 200,
    }];
    let merged = AcpAgent::merge_sessions(remote, cached);
    assert_eq!(merged.len(), 1);
    assert_eq!(merged[0].id, "same");
    assert_eq!(merged[0].updated_at, 200);
}

#[test]
fn build_cached_assistant_message_should_capture_reasoning_and_text() {
    let message = AcpAgent::build_cached_assistant_message(
        "assistant-1".to_string(),
        "思考".to_string(),
        "回答".to_string(),
        None,
        Vec::new(),
    )
    .expect("assistant message should exist");
    assert_eq!(message.role, "assistant");
    assert_eq!(message.parts.len(), 2);
    assert_eq!(message.parts[0].part_type, "reasoning");
    assert_eq!(message.parts[1].part_type, "text");
}

#[test]
fn build_cached_assistant_message_should_capture_plan_part() {
    let message = AcpAgent::build_cached_assistant_message(
        "assistant-2".to_string(),
        String::new(),
        String::new(),
        Some(super::AcpPlanSnapshot {
            revision: 2,
            updated_at_ms: 123,
            entries: vec![AcpPlanEntry {
                content: "实现计划卡".to_string(),
                status: "in_progress".to_string(),
                priority: Some("high".to_string()),
            }],
        }),
        vec![super::AcpPlanSnapshot {
            revision: 1,
            updated_at_ms: 122,
            entries: vec![AcpPlanEntry {
                content: "实现计划卡".to_string(),
                status: "pending".to_string(),
                priority: None,
            }],
        }],
    )
    .expect("assistant message should exist");
    assert_eq!(message.role, "assistant");
    assert_eq!(message.parts.len(), 1);
    assert_eq!(message.parts[0].part_type, "plan");
    let source = message.parts[0]
        .source
        .as_ref()
        .expect("plan source should exist");
    assert_eq!(
        source.get("protocol").and_then(|v| v.as_str()),
        Some("agent-plan")
    );
    assert_eq!(source.get("revision").and_then(|v| v.as_u64()), Some(2));
    assert_eq!(
        source
            .get("history")
            .and_then(|v| v.as_array())
            .map(|items| items.len()),
        Some(1)
    );
}

#[test]
fn resolve_permission_option_id_should_prefer_option_id_and_name_fallback() {
    let pending = super::PendingPermission {
        request_id: json!(1),
        session_id: "s1".to_string(),
        options: vec![
            super::PermissionOption {
                option_id: "code".to_string(),
                normalized_name: "开始实现".to_string(),
            },
            super::PermissionOption {
                option_id: "allow-once".to_string(),
                normalized_name: "手动确认".to_string(),
            },
        ],
    };

    let by_id = AcpAgent::resolve_permission_option_id(&pending, &[vec!["code".to_string()]]);
    assert_eq!(by_id.as_deref(), Some("code"));

    let by_name = AcpAgent::resolve_permission_option_id(&pending, &[vec!["开始实现".to_string()]]);
    assert_eq!(by_name.as_deref(), Some("code"));
}

#[test]
fn resolve_permission_option_id_should_fallback_to_allow_once_then_first() {
    let pending_with_allow_once = super::PendingPermission {
        request_id: json!(1),
        session_id: "s1".to_string(),
        options: vec![
            super::PermissionOption {
                option_id: "reject".to_string(),
                normalized_name: "拒绝".to_string(),
            },
            super::PermissionOption {
                option_id: "allow-once".to_string(),
                normalized_name: "一次允许".to_string(),
            },
        ],
    };
    let resolved = AcpAgent::resolve_permission_option_id(&pending_with_allow_once, &[]);
    assert_eq!(resolved.as_deref(), Some("allow-once"));

    let pending_without_allow_once = super::PendingPermission {
        request_id: json!(1),
        session_id: "s1".to_string(),
        options: vec![
            super::PermissionOption {
                option_id: "reject".to_string(),
                normalized_name: "拒绝".to_string(),
            },
            super::PermissionOption {
                option_id: "code".to_string(),
                normalized_name: "开始实现".to_string(),
            },
        ],
    };
    let fallback_first = AcpAgent::resolve_permission_option_id(&pending_without_allow_once, &[]);
    assert_eq!(fallback_first.as_deref(), Some("reject"));
}

#[test]
fn apply_current_mode_to_metadata_should_add_unknown_mode() {
    let mut metadata = crate::ai::acp_client::AcpSessionMetadata::default();
    AcpAgent::apply_current_mode_to_metadata(&mut metadata, "code");
    assert_eq!(metadata.current_mode_id.as_deref(), Some("code"));
    assert_eq!(metadata.modes.len(), 1);
    assert_eq!(metadata.modes[0].id, "code");
    assert_eq!(metadata.modes[0].name, "code");
}

#[test]
fn extract_current_mode_id_should_support_common_payload_shapes() {
    let top_level = json!({
        "currentModeId": "code"
    });
    assert_eq!(
        AcpAgent::extract_current_mode_id(&top_level).as_deref(),
        Some("code")
    );

    let mode_id = json!({
        "modeId": "plan"
    });
    assert_eq!(
        AcpAgent::extract_current_mode_id(&mode_id).as_deref(),
        Some("plan")
    );

    let nested_mode = json!({
        "content": {
            "mode": {
                "id": "agent"
            }
        }
    });
    assert_eq!(
        AcpAgent::extract_current_mode_id(&nested_mode).as_deref(),
        Some("agent")
    );
}

#[tokio::test]
async fn apply_current_mode_to_caches_should_update_directory_and_session() {
    let metadata_by_directory = Arc::new(Mutex::new(HashMap::new()));
    let metadata_by_session = Arc::new(Mutex::new(HashMap::new()));
    AcpAgent::apply_current_mode_to_caches(
        &metadata_by_directory,
        &metadata_by_session,
        "/tmp/workspace",
        "session-1",
        "code",
    )
    .await;

    let dir_meta = metadata_by_directory
        .lock()
        .await
        .get("/tmp/workspace")
        .cloned()
        .expect("directory metadata should exist");
    assert_eq!(dir_meta.current_mode_id.as_deref(), Some("code"));

    let session_meta = metadata_by_session
        .lock()
        .await
        .get("/tmp/workspace::session-1")
        .cloned()
        .expect("session metadata should exist");
    assert_eq!(session_meta.current_mode_id.as_deref(), Some("code"));
}
