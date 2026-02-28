use crate::ai::acp::tool_call;
use crate::ai::{AiMessage, AiPart};
use serde_json::Value;
use uuid::Uuid;

fn normalize_non_empty_token(raw: &str) -> Option<String> {
    let token = raw.trim();
    if token.is_empty() {
        None
    } else {
        Some(token.to_string())
    }
}

fn build_acp_content_source(content: &serde_json::Map<String, Value>) -> Value {
    serde_json::json!({
        "vendor": "acp",
        "annotations": content.get("annotations").cloned().unwrap_or(Value::Null),
        "content": Value::Object(content.clone()),
    })
}

fn normalized_content_type(content: &serde_json::Map<String, Value>) -> String {
    content
        .get("type")
        .and_then(|v| v.as_str())
        .map(|v| v.trim().to_ascii_lowercase())
        .unwrap_or_default()
}

fn content_data_url(mime: Option<&str>, data: Option<&str>, url: Option<&str>) -> Option<String> {
    if let Some(url) = url.and_then(normalize_non_empty_token) {
        return Some(url);
    }
    let data = data.and_then(normalize_non_empty_token)?;
    let mime = mime
        .and_then(normalize_non_empty_token)
        .unwrap_or_else(|| "application/octet-stream".to_string());
    Some(format!("data:{};base64,{}", mime, data))
}

pub(crate) fn extract_update(event: &Value) -> Option<(String, String, String)> {
    let session_update = event
        .get("sessionUpdate")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let content = event.get("content");
    let content_type = content
        .and_then(|v| v.get("type"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let text = content
        .and_then(|v| v.as_object())
        .and_then(|obj| {
            obj.get("text")
                .and_then(|v| v.as_str())
                .and_then(normalize_non_empty_token)
                .or_else(|| tool_call::extract_tool_output_text(&Value::Object(obj.clone())))
        })
        .unwrap_or_default();
    // content 可能为空（如 terminal update），此时返回空 type/text 供上层判定。
    Some((session_update, content_type, text))
}

pub(crate) fn map_content_to_non_text_parts(
    message_id: &str,
    content: &serde_json::Map<String, Value>,
) -> Vec<AiPart> {
    let content_type = normalized_content_type(content);
    if content_type.is_empty() {
        return Vec::new();
    }

    let source = Some(build_acp_content_source(content));
    let resource = content.get("resource").and_then(|v| v.as_object());

    let pick_str = |keys: &[&str], map: &serde_json::Map<String, Value>| -> Option<String> {
        keys.iter().find_map(|key| {
            map.get(*key)
                .and_then(|v| v.as_str())
                .and_then(normalize_non_empty_token)
        })
    };

    let make_file_part =
        |mime: Option<String>, filename: Option<String>, url: Option<String>| -> Option<AiPart> {
            if mime.is_none() && filename.is_none() && url.is_none() {
                return None;
            }
            Some(AiPart {
                id: format!("{}-file-{}", message_id, Uuid::new_v4()),
                part_type: "file".to_string(),
                mime,
                filename,
                url,
                source: source.clone(),
                ..Default::default()
            })
        };

    match content_type.as_str() {
        "image" | "audio" => {
            let mime = pick_str(&["mimeType", "mime"], content);
            let filename = pick_str(&["filename", "name"], content);
            let url = content_data_url(
                mime.as_deref(),
                pick_str(&["data"], content).as_deref(),
                pick_str(&["url"], content).as_deref(),
            );
            make_file_part(mime, filename, url)
                .into_iter()
                .collect::<Vec<_>>()
        }
        "resource" => {
            let text = resource
                .and_then(|res| pick_str(&["text"], res))
                .or_else(|| pick_str(&["text"], content));
            if let Some(text) = text {
                return vec![AiPart {
                    id: format!("{}-text-{}", message_id, Uuid::new_v4()),
                    part_type: "text".to_string(),
                    text: Some(text),
                    source,
                    ..Default::default()
                }];
            }

            let mime = resource
                .and_then(|res| pick_str(&["mimeType", "mime"], res))
                .or_else(|| pick_str(&["mimeType", "mime"], content));
            let filename = resource
                .and_then(|res| pick_str(&["name", "filename"], res))
                .or_else(|| pick_str(&["name", "filename"], content));
            let uri = resource
                .and_then(|res| pick_str(&["uri"], res))
                .or_else(|| pick_str(&["uri"], content));
            let blob = resource
                .and_then(|res| pick_str(&["blob"], res))
                .or_else(|| pick_str(&["blob"], content));
            let url = content_data_url(mime.as_deref(), blob.as_deref(), uri.as_deref());
            make_file_part(mime, filename, url)
                .into_iter()
                .collect::<Vec<_>>()
        }
        "resource_link" => {
            let mime = pick_str(&["mimeType", "mime"], content)
                .or_else(|| resource.and_then(|res| pick_str(&["mimeType", "mime"], res)));
            let filename = pick_str(&["name", "filename"], content)
                .or_else(|| resource.and_then(|res| pick_str(&["name", "filename"], res)));
            let uri = pick_str(&["uri"], content)
                .or_else(|| resource.and_then(|res| pick_str(&["uri"], res)));
            let url = content_data_url(mime.as_deref(), None, uri.as_deref());
            make_file_part(mime, filename, url)
                .into_iter()
                .collect::<Vec<_>>()
        }
        "markdown" | "diff" | "terminal" => {
            let text = tool_call::extract_tool_output_text(&Value::Object(content.clone()))
                .or_else(|| pick_str(&["text"], content));
            if let Some(text) = text {
                vec![AiPart {
                    id: format!("{}-text-{}", message_id, Uuid::new_v4()),
                    part_type: "text".to_string(),
                    text: Some(text),
                    source,
                    ..Default::default()
                }]
            } else {
                Vec::new()
            }
        }
        _ => Vec::new(),
    }
}

pub(crate) fn role_for_session_update(session_update: &str) -> &'static str {
    if session_update.eq_ignore_ascii_case("user_message_chunk") {
        "user"
    } else {
        "assistant"
    }
}

pub(crate) fn push_structured_parts_message(
    messages: &mut Vec<AiMessage>,
    message_id_prefix: &str,
    role: &str,
    parts: Vec<AiPart>,
) {
    if parts.is_empty() {
        return;
    }
    if let Some(last) = messages.last_mut() {
        if last.role.eq_ignore_ascii_case(role) {
            last.parts.extend(parts);
            return;
        }
    }
    let message_id = format!("{}-history-{}", message_id_prefix, Uuid::new_v4());
    messages.push(AiMessage {
        id: message_id,
        role: role.to_string(),
        created_at: None,
        agent: None,
        model_provider_id: None,
        model_id: None,
        parts,
    });
}

pub(crate) fn map_update_to_output(session_update: &str) -> Option<(&'static str, bool)> {
    let normalized = normalized_update_token(session_update);
    match normalized.as_str() {
        "agent_thought_chunk" => Some(("reasoning", true)),
        "agent_message_chunk" => Some(("text", true)),
        "user_message_chunk" => Some(("text", false)),
        _ => None,
    }
}

pub(crate) fn normalized_update_token(raw: &str) -> String {
    raw.trim()
        .to_lowercase()
        .replace('-', "_")
        .replace(' ', "_")
}

pub(crate) fn is_terminal_update(session_update: &str, content_type: &str) -> bool {
    let update = normalized_update_token(session_update);
    if !update.is_empty() {
        if update.contains("chunk") {
            return false;
        }
        if matches!(
            update.as_str(),
            "done"
                | "idle"
                | "session_idle"
                | "session_done"
                | "session_completed"
                | "session_complete"
                | "turn_done"
                | "turn_completed"
                | "turn_complete"
                | "agent_turn_done"
                | "agent_turn_completed"
                | "agent_turn_complete"
        ) {
            return true;
        }
        if update.contains("complete")
            || update.contains("finished")
            || update.ends_with("_end")
            || update.ends_with("_ended")
            || update.contains("cancelled")
            || update.contains("canceled")
        {
            return true;
        }
    }

    let content = normalized_update_token(content_type);
    matches!(content.as_str(), "done" | "end" | "completed" | "finished")
}

pub(crate) fn is_error_update(session_update: &str, content_type: &str) -> bool {
    let update = normalized_update_token(session_update);
    if update.contains("error") || update.contains("failed") || update.contains("failure") {
        return true;
    }
    let content = normalized_update_token(content_type);
    content == "error" || content == "failed"
}

pub(crate) fn parse_prompt_stop_reason(result: &Value) -> Result<String, String> {
    let stop_reason = result
        .get("stopReason")
        .or_else(|| result.get("stop_reason"))
        .and_then(|v| v.as_str())
        .map(|v| v.trim().to_lowercase())
        .filter(|v| !v.is_empty())
        .ok_or_else(|| "ACP session/prompt result missing string stopReason".to_string())?;
    const ALLOWED: &[&str] = &[
        "end_turn",
        "max_tokens",
        "stop_sequence",
        "tool_use",
        "cancelled",
        "error",
    ];
    if !ALLOWED
        .iter()
        .any(|allowed| allowed == &stop_reason.as_str())
    {
        return Err(format!(
            "ACP session/prompt returned unsupported stopReason: {}",
            stop_reason
        ));
    }
    Ok(stop_reason)
}
