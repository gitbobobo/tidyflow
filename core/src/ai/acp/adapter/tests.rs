use super::{AcpAgent, AcpBackendProfile, AcpPlanEntry};
use crate::ai::acp::client::AcpSessionSummary;
use crate::ai::codex::manager::{AcpContentEncodingMode, CodexAppServerManager};
use crate::ai::{AiAgent, AiAudioPart, AiImagePart, AiSession, AiSlashCommand};
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
fn stream_chunk_part_id_should_reuse_only_within_same_sequence() {
    let assistant_message_id = "assistant-message";
    let mut part_type: Option<String> = None;
    let mut part_id: Option<String> = None;

    let first_reasoning = AcpAgent::resolve_stream_chunk_part_id(
        assistant_message_id,
        "reasoning",
        &mut part_type,
        &mut part_id,
    );
    assert!(first_reasoning.starts_with("assistant-message-reasoning-"));

    let second_reasoning = AcpAgent::resolve_stream_chunk_part_id(
        assistant_message_id,
        "reasoning",
        &mut part_type,
        &mut part_id,
    );
    assert_eq!(first_reasoning, second_reasoning);

    let text_part = AcpAgent::resolve_stream_chunk_part_id(
        assistant_message_id,
        "text",
        &mut part_type,
        &mut part_id,
    );
    assert!(text_part.starts_with("assistant-message-text-"));
    assert_ne!(first_reasoning, text_part);

    AcpAgent::break_stream_chunk_part_sequence(&mut part_type, &mut part_id);
    let third_reasoning = AcpAgent::resolve_stream_chunk_part_id(
        assistant_message_id,
        "reasoning",
        &mut part_type,
        &mut part_id,
    );
    assert!(third_reasoning.starts_with("assistant-message-reasoning-"));
    assert_ne!(first_reasoning, third_reasoning);
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
fn extract_update_should_preserve_text_chunk_newlines() {
    let update = json!({
        "sessionUpdate": "agent_message_chunk",
        "content": {
            "type": "text",
            "text": "\n| 文件 | 大小 |\n"
        }
    });
    let (_session_update, _content_type, text) =
        AcpAgent::extract_update(&update).expect("update should parse");
    assert_eq!(text, "\n| 文件 | 大小 |\n");
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
fn compose_prompt_parts_should_keep_image_base64_under_64kb() {
    let mut img = image::RgbaImage::new(320, 320);
    for (x, y, pixel) in img.enumerate_pixels_mut() {
        let r = ((x * 31 + y * 17) % 256) as u8;
        let g = ((x * 13 + y * 29) % 256) as u8;
        let b = ((x * 7 + y * 43) % 256) as u8;
        *pixel = image::Rgba([r, g, b, 255]);
    }
    let mut png = Vec::new();
    image::DynamicImage::ImageRgba8(img)
        .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
        .expect("encode png");

    let parts = AcpAgent::compose_prompt_parts(
        "/tmp/workspace",
        "图片限流测试",
        None,
        Some(vec![AiImagePart {
            filename: "large.png".to_string(),
            mime: "image/png".to_string(),
            data: png,
        }]),
        None,
        AcpContentEncodingMode::New,
        true,
        false,
        false,
        false,
    );

    let image = parts
        .iter()
        .find(|part| part.get("type").and_then(|v| v.as_str()) == Some("image"))
        .expect("image part should exist");
    let data = image
        .get("data")
        .and_then(|v| v.as_str())
        .expect("image data should exist");
    assert!(data.len() < 64 * 1024);
}

#[test]
fn compose_prompt_parts_should_fallback_when_oversized_image_unencodable() {
    let oversized_invalid = vec![0_u8; 49 * 1024];

    let parts = AcpAgent::compose_prompt_parts(
        "/tmp/workspace",
        "图片降级测试",
        None,
        Some(vec![AiImagePart {
            filename: "bad.bin".to_string(),
            mime: "image/png".to_string(),
            data: oversized_invalid,
        }]),
        None,
        AcpContentEncodingMode::New,
        true,
        false,
        false,
        false,
    );

    assert!(!parts
        .iter()
        .any(|part| part.get("type").and_then(|v| v.as_str()) == Some("image")));
    let text = parts
        .iter()
        .find(|part| part.get("type").and_then(|v| v.as_str()) == Some("text"))
        .and_then(|part| part.get("text"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    assert!(text.contains("图片附件："));
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
fn apply_current_mode_to_metadata_should_canonicalize_known_mode_token() {
    let mut metadata = crate::ai::acp_client::AcpSessionMetadata::default();
    AcpAgent::apply_current_mode_to_metadata(&mut metadata, "agent");
    assert_eq!(
        metadata.current_mode_id.as_deref(),
        Some("https://agentclientprotocol.com/protocol/session-modes#agent")
    );
    assert_eq!(metadata.modes.len(), 1);
    assert_eq!(
        metadata.modes[0].id,
        "https://agentclientprotocol.com/protocol/session-modes#agent"
    );
}

#[test]
fn apply_current_model_to_metadata_should_add_unknown_model() {
    let mut metadata = crate::ai::acp_client::AcpSessionMetadata::default();
    AcpAgent::apply_current_model_to_metadata(&mut metadata, "gpt-5");
    assert_eq!(metadata.current_model_id.as_deref(), Some("gpt-5"));
    assert_eq!(metadata.models.len(), 1);
    assert_eq!(metadata.models[0].id, "gpt-5");
    assert_eq!(metadata.models[0].name, "gpt-5");
}

#[test]
fn resolve_mode_id_should_match_mode_semantic_token_and_return_canonical_mode_id() {
    let metadata = crate::ai::acp_client::AcpSessionMetadata {
        modes: vec![crate::ai::acp_client::AcpModeInfo {
            id: "https://agentclientprotocol.com/protocol/session-modes#plan".to_string(),
            name: "Plan".to_string(),
            description: None,
        }],
        ..Default::default()
    };
    assert_eq!(
        AcpAgent::resolve_mode_id(&metadata, Some("plan")).as_deref(),
        Some("https://agentclientprotocol.com/protocol/session-modes#plan")
    );
}

#[test]
fn resolve_mode_id_should_canonicalize_fallback_current_mode_token() {
    let metadata = crate::ai::acp_client::AcpSessionMetadata {
        current_mode_id: Some("autopilot".to_string()),
        ..Default::default()
    };
    assert_eq!(
        AcpAgent::resolve_mode_id(&metadata, None).as_deref(),
        Some("https://agentclientprotocol.com/protocol/session-modes#autopilot")
    );
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

#[tokio::test]
async fn apply_current_model_to_caches_should_update_directory_and_session() {
    let metadata_by_directory = Arc::new(Mutex::new(HashMap::new()));
    let metadata_by_session = Arc::new(Mutex::new(HashMap::new()));
    AcpAgent::apply_current_model_to_caches(
        &metadata_by_directory,
        &metadata_by_session,
        "/tmp/workspace",
        "session-1",
        "gpt-5",
    )
    .await;

    let dir_meta = metadata_by_directory
        .lock()
        .await
        .get("/tmp/workspace")
        .cloned()
        .expect("directory metadata should exist");
    assert_eq!(dir_meta.current_model_id.as_deref(), Some("gpt-5"));

    let session_meta = metadata_by_session
        .lock()
        .await
        .get("/tmp/workspace::session-1")
        .cloned()
        .expect("session metadata should exist");
    assert_eq!(session_meta.current_model_id.as_deref(), Some("gpt-5"));
}

// Kimi 适配器专项测试：tool_id 与 message_id_prefix 标识符
#[test]
fn kimi_backend_profile_should_expose_tool_id_and_message_prefix() {
    let kimi = AcpBackendProfile::kimi();
    assert_eq!(kimi.tool_id, "kimi");
    assert_eq!(kimi.message_id_prefix, "kimi");

    let copilot = AcpBackendProfile::copilot();
    assert_eq!(copilot.tool_id, "copilot");
    assert_eq!(copilot.message_id_prefix, "copilot");

    // 两种后端 provider_id 必须不同，保证路由隔离
    assert_ne!(kimi.tool_id, copilot.tool_id);
}

// Kimi 适配器专项测试：自动启用 runtime yolo 行为
#[test]
fn kimi_adapter_should_auto_enable_runtime_yolo() {
    let manager = Arc::new(CodexAppServerManager::new(std::env::temp_dir()));
    let kimi_agent = AcpAgent::new_kimi(manager.clone());
    assert!(
        kimi_agent.should_auto_enable_runtime_yolo(),
        "Kimi 适配器应自动启用 runtime yolo"
    );

    let copilot_agent = AcpAgent::new_copilot(manager);
    assert!(
        !copilot_agent.should_auto_enable_runtime_yolo(),
        "Copilot 适配器不应自动启用 runtime yolo"
    );
}

// Kimi 适配器专项测试：session not found 错误检测
#[test]
fn kimi_is_session_not_found_should_detect_error_patterns() {
    assert!(AcpAgent::is_session_not_found("session not found"));
    assert!(AcpAgent::is_session_not_found("Session Not Found"));
    assert!(AcpAgent::is_session_not_found(
        "error: session id 123 not found"
    ));
    assert!(!AcpAgent::is_session_not_found("connection refused"));
    assert!(!AcpAgent::is_session_not_found("session already loaded"));
}

// Kimi 适配器专项测试：session already loaded 错误检测
#[test]
fn kimi_is_session_already_loaded_should_detect_error_patterns() {
    assert!(AcpAgent::is_session_already_loaded(
        "session already loaded"
    ));
    assert!(AcpAgent::is_session_already_loaded(
        "Session Already Loaded"
    ));
    assert!(!AcpAgent::is_session_already_loaded("session not found"));
    assert!(!AcpAgent::is_session_already_loaded("timeout"));
}

// 跨适配器契约测试：Kimi 与 Copilot 的 selection_hint 输出结构兼容
#[test]
fn kimi_and_copilot_selection_hint_should_produce_compatible_structure() {
    let metadata_with_model = crate::ai::acp_client::AcpSessionMetadata {
        current_model_id: Some("kimi-k2".to_string()),
        ..Default::default()
    };

    let kimi_hint = AcpAgent::selection_hint_from_metadata(&metadata_with_model, "kimi");
    let copilot_hint = AcpAgent::selection_hint_from_metadata(&metadata_with_model, "copilot");

    // 两端的 hint 结构必须一致
    let kimi_hint = kimi_hint.expect("Kimi hint should be Some when model is set");
    let copilot_hint = copilot_hint.expect("Copilot hint should be Some when model is set");

    assert_eq!(kimi_hint.model_id.as_deref(), Some("kimi-k2"));
    assert_eq!(copilot_hint.model_id.as_deref(), Some("kimi-k2"));
    assert_eq!(kimi_hint.model_provider_id.as_deref(), Some("kimi"));
    assert_eq!(copilot_hint.model_provider_id.as_deref(), Some("copilot"));

    // 无 model 时两者均返回 None
    let empty_meta = crate::ai::acp_client::AcpSessionMetadata::default();
    assert!(AcpAgent::selection_hint_from_metadata(&empty_meta, "kimi").is_none());
    assert!(AcpAgent::selection_hint_from_metadata(&empty_meta, "copilot").is_none());
}

// 跨适配器契约测试：normalize_mode_name 对 Kimi 模式名不出现空名
#[test]
fn kimi_normalize_mode_name_should_not_produce_empty_for_standard_modes() {
    assert!(!AcpAgent::normalize_mode_name("agent").is_empty());
    assert!(!AcpAgent::normalize_mode_name("plan").is_empty());
    assert!(!AcpAgent::normalize_mode_name("code").is_empty());
    // 空字符串作为退化输入，结果应为空
    assert!(AcpAgent::normalize_mode_name("").is_empty());
}

// 多模态格式归一化：JPEG 输入应在 64KB 限制内正常编码
#[test]
fn compose_prompt_parts_should_handle_jpeg_source_image() {
    let mut jpeg = Vec::new();
    let img = image::RgbImage::from_fn(4, 4, |x, y| {
        image::Rgb([(x * 60) as u8, (y * 60) as u8, 128_u8])
    });
    image::DynamicImage::ImageRgb8(img)
        .write_to(
            &mut std::io::Cursor::new(&mut jpeg),
            image::ImageFormat::Jpeg,
        )
        .expect("encode jpeg");

    let parts = AcpAgent::compose_prompt_parts(
        "/tmp/workspace",
        "JPEG 格式图像测试",
        None,
        Some(vec![AiImagePart {
            filename: "photo.jpg".to_string(),
            mime: "image/jpeg".to_string(),
            data: jpeg,
        }]),
        None,
        AcpContentEncodingMode::New,
        true,
        false,
        false,
        false,
    );

    let image = parts
        .iter()
        .find(|p| p.get("type").and_then(|v| v.as_str()) == Some("image"))
        .expect("JPEG 输入应产生 image 部分");
    let data_str = image
        .get("data")
        .and_then(|v| v.as_str())
        .expect("New 模式应有 data 字段");
    assert!(!data_str.is_empty(), "base64 data 不能为空");
    assert!(
        data_str.len() <= 64 * 1024,
        "base64 编码长度不应超过 64KB 限制"
    );
}

// 多模态格式归一化：WebP 来源声明应产生 image 部分或降级文本
#[test]
fn compose_prompt_parts_should_handle_webp_declared_mime() {
    // 使用实际 PNG 数据但声明 mime 为 webp，测试适配层对 mime 字段的传递与处理
    let mut png = Vec::new();
    let img = image::RgbaImage::from_fn(4, 4, |x, y| {
        image::Rgba([(x * 60) as u8, (y * 60) as u8, 128_u8, 255_u8])
    });
    image::DynamicImage::ImageRgba8(img)
        .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
        .expect("encode png");

    let parts = AcpAgent::compose_prompt_parts(
        "/tmp/workspace",
        "WebP MIME 声明测试",
        None,
        Some(vec![AiImagePart {
            filename: "image.webp".to_string(),
            mime: "image/webp".to_string(),
            data: png,
        }]),
        None,
        AcpContentEncodingMode::New,
        true,
        false,
        false,
        false,
    );

    // 适配层应产生 image 部分（压缩后可正常编码）或降级为 text 通知
    let has_image = parts
        .iter()
        .any(|p| p.get("type").and_then(|v| v.as_str()) == Some("image"));
    let has_fallback = parts.iter().any(|p| {
        p.get("type").and_then(|v| v.as_str()) == Some("text")
            && p.get("text")
                .and_then(|v| v.as_str())
                .map(|t| t.contains("图片附件"))
                .unwrap_or(false)
    });
    assert!(
        has_image || has_fallback,
        "WebP 声明应产生 image 部分或降级文本，实际 parts: {:?}",
        parts
    );
}

// 多模态格式归一化：批量 JPEG + PNG 混合输入均应成功编码
#[test]
fn compose_prompt_parts_should_normalize_mixed_jpeg_png_batch() {
    let mut jpeg = Vec::new();
    image::DynamicImage::ImageRgb8(image::RgbImage::from_fn(2, 2, |_, _| {
        image::Rgb([100_u8, 150_u8, 200_u8])
    }))
    .write_to(
        &mut std::io::Cursor::new(&mut jpeg),
        image::ImageFormat::Jpeg,
    )
    .expect("encode jpeg");

    let mut png = Vec::new();
    image::DynamicImage::ImageRgba8(image::RgbaImage::from_fn(2, 2, |_, _| {
        image::Rgba([50_u8, 100_u8, 150_u8, 255_u8])
    }))
    .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
    .expect("encode png");

    let parts = AcpAgent::compose_prompt_parts(
        "/tmp/workspace",
        "批量 JPEG+PNG 格式归一化测试",
        None,
        Some(vec![
            AiImagePart {
                filename: "a.jpg".to_string(),
                mime: "image/jpeg".to_string(),
                data: jpeg,
            },
            AiImagePart {
                filename: "b.png".to_string(),
                mime: "image/png".to_string(),
                data: png,
            },
        ]),
        None,
        AcpContentEncodingMode::New,
        true,
        false,
        false,
        false,
    );

    let image_count = parts
        .iter()
        .filter(|p| p.get("type").and_then(|v| v.as_str()) == Some("image"))
        .count();
    assert_eq!(image_count, 2, "JPEG 和 PNG 均应编码为独立 image 部分");
}

// 多模态格式归一化：服务商不支持图像时应回退且不丢失文本
#[test]
fn compose_prompt_parts_should_fallback_gracefully_when_vendor_disallows_image() {
    let mut jpeg = Vec::new();
    image::DynamicImage::ImageRgb8(image::RgbImage::from_fn(2, 2, |_, _| {
        image::Rgb([80_u8, 80_u8, 80_u8])
    }))
    .write_to(
        &mut std::io::Cursor::new(&mut jpeg),
        image::ImageFormat::Jpeg,
    )
    .expect("encode jpeg");

    let parts = AcpAgent::compose_prompt_parts(
        "/tmp/workspace",
        "服务商不支持图像",
        None,
        Some(vec![AiImagePart {
            filename: "screenshot.jpg".to_string(),
            mime: "image/jpeg".to_string(),
            data: jpeg,
        }]),
        None,
        AcpContentEncodingMode::New,
        false, // supports_image = false
        false,
        false,
        false,
    );

    // 不应有 image 部分
    assert!(
        !parts
            .iter()
            .any(|p| p.get("type").and_then(|v| v.as_str()) == Some("image")),
        "服务商不支持图像时不应产生 image 部分"
    );
    // 文本部分应包含原始问题
    let text = parts
        .iter()
        .find(|p| p.get("type").and_then(|v| v.as_str()) == Some("text"))
        .and_then(|p| p.get("text"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    assert!(text.contains("服务商不支持图像"), "原始文本不应丢失");
    assert!(text.contains("图片附件："), "应在降级文本中说明图片附件");
}

// ACP 历史加载错误分类（WI-001）

#[test]
fn is_session_not_found_should_match_known_error_patterns() {
    assert!(
        AcpAgent::is_session_not_found("session not found"),
        "小写 session not found 应匹配"
    );
    assert!(
        AcpAgent::is_session_not_found("Session Not Found"),
        "混合大小写 Session Not Found 应匹配"
    );
    assert!(
        AcpAgent::is_session_not_found("error: session 'abc' not found in registry"),
        "包含 session 和 not found 的长错误描述应匹配"
    );
    assert!(
        !AcpAgent::is_session_not_found("session already loaded"),
        "session already loaded 不应匹配 session_not_found"
    );
    assert!(
        !AcpAgent::is_session_not_found("connection refused"),
        "无关错误不应误匹配"
    );
    assert!(
        !AcpAgent::is_session_not_found("not found"),
        "缺少 session 关键词时不应匹配"
    );
}

#[test]
fn is_session_already_loaded_should_match_known_error_patterns() {
    assert!(
        AcpAgent::is_session_already_loaded("session already loaded"),
        "小写完整短语应匹配"
    );
    assert!(
        AcpAgent::is_session_already_loaded("Session Already Loaded"),
        "混合大小写应匹配"
    );
    assert!(
        AcpAgent::is_session_already_loaded("acp: session 'ses_1' is already loaded"),
        "包含 session + already + loaded 的长描述应匹配"
    );
    assert!(
        !AcpAgent::is_session_already_loaded("session not found"),
        "session not found 不应匹配 session_already_loaded"
    );
    assert!(
        !AcpAgent::is_session_already_loaded("already connected"),
        "缺少 session 关键词时不应匹配"
    );
    assert!(
        !AcpAgent::is_session_already_loaded("already loaded"),
        "缺少 session 关键词时不应匹配（仅有 already + loaded）"
    );
}

#[test]
fn thought_level_category_should_map_to_model_variant_for_app_contract() {
    let options = AcpAgent::map_config_options(&[crate::ai::acp_client::AcpConfigOptionInfo {
        option_id: "thought_level".to_string(),
        category: Some("thought_level".to_string()),
        name: "推理档位".to_string(),
        description: None,
        current_value: Some(json!("high")),
        options: vec![crate::ai::acp_client::AcpConfigOptionChoice {
            value: json!("high"),
            label: "高".to_string(),
            description: None,
        }],
        option_groups: Vec::new(),
        raw: None,
    }]);

    assert_eq!(options.len(), 1);
    assert_eq!(options[0].category.as_deref(), Some("model_variant"));
}

#[test]
fn config_override_priority_should_apply_mode_model_then_variant() {
    let mut categories = [
        "model_variant".to_string(),
        "other".to_string(),
        "model".to_string(),
        "mode".to_string(),
    ];
    categories.sort_by_key(|category| AcpAgent::config_option_priority(category));
    assert_eq!(
        categories,
        [
            "mode".to_string(),
            "model".to_string(),
            "model_variant".to_string(),
            "other".to_string()
        ]
    );
}

#[test]
fn merge_metadata_from_delta_should_refresh_model_and_variant_selection_hint() {
    let mut metadata = crate::ai::acp_client::AcpSessionMetadata {
        current_model_id: Some("model-old".to_string()),
        config_options: vec![
            crate::ai::acp_client::AcpConfigOptionInfo {
                option_id: "model".to_string(),
                category: Some("model".to_string()),
                name: "模型".to_string(),
                description: None,
                current_value: Some(json!("model-old")),
                options: vec![crate::ai::acp_client::AcpConfigOptionChoice {
                    value: json!("model-old"),
                    label: "旧模型".to_string(),
                    description: None,
                }],
                option_groups: Vec::new(),
                raw: None,
            },
            crate::ai::acp_client::AcpConfigOptionInfo {
                option_id: "thought_level".to_string(),
                category: Some("thought_level".to_string()),
                name: "推理档位".to_string(),
                description: None,
                current_value: Some(json!("low")),
                options: vec![crate::ai::acp_client::AcpConfigOptionChoice {
                    value: json!("low"),
                    label: "低".to_string(),
                    description: None,
                }],
                option_groups: Vec::new(),
                raw: None,
            },
        ],
        config_values: HashMap::from([
            ("model".to_string(), json!("model-old")),
            ("thought_level".to_string(), json!("low")),
        ]),
        ..Default::default()
    };
    let delta = crate::ai::acp_client::AcpSessionMetadata {
        current_model_id: Some("model-new".to_string()),
        config_options: vec![
            crate::ai::acp_client::AcpConfigOptionInfo {
                option_id: "model".to_string(),
                category: Some("model".to_string()),
                name: "模型".to_string(),
                description: None,
                current_value: Some(json!("model-new")),
                options: vec![crate::ai::acp_client::AcpConfigOptionChoice {
                    value: json!("model-new"),
                    label: "新模型".to_string(),
                    description: None,
                }],
                option_groups: Vec::new(),
                raw: None,
            },
            crate::ai::acp_client::AcpConfigOptionInfo {
                option_id: "thought_level".to_string(),
                category: Some("thought_level".to_string()),
                name: "推理档位".to_string(),
                description: None,
                current_value: Some(json!("high")),
                options: vec![
                    crate::ai::acp_client::AcpConfigOptionChoice {
                        value: json!("medium"),
                        label: "中".to_string(),
                        description: None,
                    },
                    crate::ai::acp_client::AcpConfigOptionChoice {
                        value: json!("high"),
                        label: "高".to_string(),
                        description: None,
                    },
                ],
                option_groups: Vec::new(),
                raw: None,
            },
        ],
        config_values: HashMap::from([
            ("model".to_string(), json!("model-new")),
            ("thought_level".to_string(), json!("high")),
        ]),
        ..Default::default()
    };

    AcpAgent::merge_metadata_from_delta(&mut metadata, delta);

    assert_eq!(metadata.current_model_id.as_deref(), Some("model-new"));
    assert_eq!(
        metadata.config_values.get("thought_level"),
        Some(&json!("high"))
    );
    let hint = AcpAgent::selection_hint_from_metadata(&metadata, "copilot")
        .expect("selection hint should exist");
    assert_eq!(hint.model_id.as_deref(), Some("model-new"));
    assert_eq!(
        hint.config_options
            .as_ref()
            .and_then(|values| values.get("thought_level")),
        Some(&json!("high"))
    );
}

#[tokio::test]
async fn list_providers_should_attach_variants_only_to_current_model() {
    let manager = Arc::new(CodexAppServerManager::new(std::env::temp_dir()));
    let agent = AcpAgent::new_copilot(manager);
    let directory = "/tmp/tidyflow-provider-variants";
    let directory_key = AcpAgent::normalize_directory(directory);

    {
        let mut metadata_by_directory = agent.metadata_by_directory.lock().await;
        metadata_by_directory.insert(
            directory_key,
            crate::ai::acp_client::AcpSessionMetadata {
                models: vec![
                    crate::ai::acp_client::AcpModelInfo {
                        id: "model-a".to_string(),
                        name: "Model A".to_string(),
                        supports_image_input: true,
                    },
                    crate::ai::acp_client::AcpModelInfo {
                        id: "model-b".to_string(),
                        name: "Model B".to_string(),
                        supports_image_input: true,
                    },
                ],
                current_model_id: Some("model-b".to_string()),
                config_options: vec![crate::ai::acp_client::AcpConfigOptionInfo {
                    option_id: "thought_level".to_string(),
                    category: Some("thought_level".to_string()),
                    name: "推理档位".to_string(),
                    description: None,
                    current_value: Some(json!("high")),
                    options: vec![
                        crate::ai::acp_client::AcpConfigOptionChoice {
                            value: json!("low"),
                            label: "低".to_string(),
                            description: None,
                        },
                        crate::ai::acp_client::AcpConfigOptionChoice {
                            value: json!("high"),
                            label: "高".to_string(),
                            description: None,
                        },
                    ],
                    option_groups: Vec::new(),
                    raw: None,
                }],
                config_values: HashMap::from([("thought_level".to_string(), json!("high"))]),
                ..Default::default()
            },
        );
    }

    let providers = agent
        .list_providers(directory)
        .await
        .expect("list_providers should succeed");
    assert_eq!(providers.len(), 1);
    let models = &providers[0].models;
    assert_eq!(models.len(), 2);
    assert!(models[0].variants.is_empty());
    assert_eq!(models[1].id, "model-b");
    assert_eq!(
        models[1].variants,
        vec!["low".to_string(), "high".to_string()]
    );
}
