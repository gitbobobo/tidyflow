use crate::ai::shared::json_search::{find_scalar_by_keys, normalize_optional_token};
use crate::ai::AiSessionSelectionHint;
use serde_json::Value;

fn normalize_agent_hint(raw: &str) -> Option<String> {
    let normalized = raw.trim().to_lowercase();
    if normalized.is_empty() {
        return None;
    }
    if normalized.contains("#plan") {
        return Some("plan".to_string());
    }
    if normalized.contains("#agent") {
        return Some("agent".to_string());
    }
    Some(normalized)
}

pub(super) fn selection_hint_from_thread_payload(value: &Value) -> Option<AiSessionSelectionHint> {
    let collab_mode = value
        .pointer("/thread/collaborationMode/mode")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .or_else(|| {
            value
                .pointer("/collaborationMode/mode")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
        })
        .or_else(|| find_scalar_by_keys(value, &["collaboration_mode", "collaborationMode"]));
    let agent = collab_mode.and_then(|v| normalize_agent_hint(&v));

    let model_provider_id = normalize_optional_token(
        value
            .pointer("/thread/modelProvider")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .or_else(|| {
                value
                    .pointer("/modelProvider")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            })
            .or_else(|| find_scalar_by_keys(value, &["model_provider", "modelProvider"])),
    );

    let model_id = normalize_optional_token(
        value
            .pointer("/thread/model")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .or_else(|| {
                value
                    .pointer("/model")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            })
            .or_else(|| {
                value
                    .pointer("/thread/collaborationMode/settings/model")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            })
            .or_else(|| {
                value
                    .pointer("/collaborationMode/settings/model")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            })
            .or_else(|| {
                value
                    .pointer("/thread/collaborationMode/modelSettings/model")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            })
            .or_else(|| find_scalar_by_keys(value, &["model_id", "modelID", "model"])),
    );

    if agent.is_none() && model_provider_id.is_none() && model_id.is_none() {
        None
    } else {
        Some(AiSessionSelectionHint {
            agent,
            model_provider_id,
            model_id,
            config_options: None,
        })
    }
}
