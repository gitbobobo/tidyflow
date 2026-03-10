use crate::ai::codex::tool_mapping::{map_item_to_part, parse_user_text};
use crate::ai::{AiMessage, AiPart};
use std::collections::HashMap;
use serde_json::Value;

fn canonical_method(method: &str) -> String {
    method
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .flat_map(|ch| ch.to_lowercase())
        .collect::<String>()
}

fn method_in(method: &str, candidates: &[&str]) -> bool {
    let canonical = canonical_method(method);
    candidates
        .iter()
        .any(|candidate| canonical == canonical_method(candidate))
}

pub(super) fn render_turn_plan_update(params: &Value) -> String {
    let explanation = params
        .get("explanation")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_string);

    let mut lines = Vec::new();
    if let Some(explanation) = explanation {
        lines.push(explanation);
    }

    let plan_items = params
        .get("plan")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    if !plan_items.is_empty() {
        if !lines.is_empty() {
            lines.push(String::new());
        }
        lines.push("当前计划：".to_string());
        for entry in plan_items {
            let step = entry
                .get("step")
                .and_then(|v| v.as_str())
                .map(str::trim)
                .filter(|text| !text.is_empty())
                .unwrap_or("未命名步骤");
            let status = entry
                .get("status")
                .and_then(|v| v.as_str())
                .unwrap_or("pending")
                .to_lowercase();
            let badge = match status.as_str() {
                "completed" => "[x]",
                "inprogress" | "in_progress" => "[-]",
                _ => "[ ]",
            };
            lines.push(format!("- {} {}", badge, step));
        }
    }

    if lines.is_empty() {
        "计划已更新".to_string()
    } else {
        lines.join("\n")
    }
}

pub(super) fn extract_tool_output_delta(
    method: &str,
    params: &Value,
) -> Option<(String, String, String)> {
    if !method_in(
        method,
        &[
            "item/commandExecution/outputDelta",
            "item/commandExecution/terminalInteraction",
            "item/fileChange/outputDelta",
            "item/mcpToolCall/progress",
        ],
    ) {
        return None;
    }

    let item_id = params
        .get("itemId")
        .or_else(|| params.get("item_id"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    if item_id.is_empty() {
        return None;
    }

    let (field, payload) = if method_in(method, &["item/mcpToolCall/progress"]) {
        (
            "progress".to_string(),
            params
                .get("message")
                .and_then(|v| v.as_str())
                .map(|s| format!("{}\n", s))
                .unwrap_or_default(),
        )
    } else if method_in(method, &["item/commandExecution/terminalInteraction"]) {
        (
            "progress".to_string(),
            params
                .get("stdin")
                .and_then(|v| v.as_str())
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(|s| format!("stdin: {}\n", s))
                .unwrap_or_default(),
        )
    } else {
        (
            "output".to_string(),
            params
                .get("delta")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
        )
    };
    if payload.is_empty() {
        return None;
    }
    Some((item_id, field, payload))
}

pub(super) fn extract_generic_text_delta(
    method: &str,
    params: &Value,
) -> Option<(String, String, String, String)> {
    let method_lower = method.to_ascii_lowercase();
    let looks_like_delta = method_lower.contains("delta");
    if !looks_like_delta {
        return None;
    }

    if method_in(
        method,
        &[
            "item/agentMessage/delta",
            "item/reasoning/textDelta",
            "item/reasoning/summaryTextDelta",
            "item/commandExecution/outputDelta",
            "item/commandExecution/terminalInteraction",
            "item/fileChange/outputDelta",
            "item/mcpToolCall/progress",
            "item/plan/delta",
        ],
    ) {
        return None;
    }

    let item_id = params
        .get("itemId")
        .or_else(|| params.get("item_id"))
        .or_else(|| params.get("id"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    if item_id.is_empty() {
        return None;
    }

    let delta = params
        .get("delta")
        .or_else(|| params.get("textDelta"))
        .or_else(|| params.get("text_delta"))
        .or_else(|| params.get("contentDelta"))
        .or_else(|| params.get("content_delta"))
        .or_else(|| params.get("text"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    if delta.is_empty() {
        return None;
    }

    let part_type = if method_lower.contains("reason") {
        "reasoning".to_string()
    } else {
        "text".to_string()
    };

    Some((item_id.clone(), item_id, part_type, delta))
}

pub(super) fn user_message_id(session_id: &str, turn_id: &str) -> String {
    format!("codex-user-{}-{}", session_id, turn_id)
}

pub(super) fn assistant_message_id(session_id: &str, turn_id: &str) -> String {
    format!("codex-assistant-{}-{}", session_id, turn_id)
}

fn turn_item_id(turn_id: &str, index: usize, item: &Value) -> String {
    item.get("id")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .unwrap_or_else(|| format!("{}-{}", turn_id, index))
}

fn map_turn_item_to_part(
    turn_id: &str,
    index: usize,
    item: &Value,
    pending_request_id: Option<&str>,
) -> Option<AiPart> {
    let item_type = item
        .get("type")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_lowercase();
    if item_type == "usermessage" {
        return None;
    }
    let item_id = turn_item_id(turn_id, index, item);
    map_item_to_part(item, "completed").map(|mut part| {
        if part.part_type == "tool"
            && part
                .tool_name
                .as_deref()
                .map(|name| name.eq_ignore_ascii_case("question"))
                .unwrap_or(false)
        {
            if let Some(request_id) = pending_request_id {
                part.tool_call_id = Some(request_id.to_string());
                let mut metadata = part
                    .tool_part_metadata
                    .and_then(|v| v.as_object().cloned())
                    .unwrap_or_default();
                metadata.insert(
                    "request_id".to_string(),
                    Value::String(request_id.to_string()),
                );
                metadata.insert(
                    "tool_message_id".to_string(),
                    Value::String(item_id.clone()),
                );
                part.tool_part_metadata = Some(Value::Object(metadata));
            }
        }

        part
    })
}

pub(super) fn map_turn_items_to_messages(
    session_id: &str,
    turn_id: &str,
    items: &[Value],
    pending_request_id_by_item_id: &HashMap<String, String>,
) -> Vec<AiMessage> {
    let mut user_parts: Vec<AiPart> = Vec::new();
    let mut assistant_parts: Vec<AiPart> = Vec::new();

    for (idx, item) in items.iter().enumerate() {
        let item_type = item
            .get("type")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_lowercase();
        let item_id = turn_item_id(turn_id, idx, item);

        if item_type == "usermessage" {
            let text = parse_user_text(item);
            if !text.trim().is_empty() {
                user_parts.push(AiPart::new_text(format!("{}-text", item_id), text));
            }
            continue;
        }

        let pending_request_id = pending_request_id_by_item_id
            .get(&item_id)
            .map(|s| s.as_str());
        if let Some(part) = map_turn_item_to_part(turn_id, idx, item, pending_request_id) {
            assistant_parts.push(part);
        }
    }

    let mut messages = Vec::with_capacity(2);
    if !user_parts.is_empty() {
        messages.push(AiMessage {
            id: user_message_id(session_id, turn_id),
            role: "user".to_string(),
            created_at: None,
            agent: None,
            model_provider_id: None,
            model_id: None,
            parts: user_parts,
        });
    }
    if !assistant_parts.is_empty() {
        messages.push(AiMessage {
            id: assistant_message_id(session_id, turn_id),
            role: "assistant".to_string(),
            created_at: None,
            agent: None,
            model_provider_id: None,
            model_id: None,
            parts: assistant_parts,
        });
    }
    messages
}
