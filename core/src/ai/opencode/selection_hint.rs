use super::protocol::{MessageInfo, SessionResponse};
pub(crate) use crate::ai::shared::json_search::normalize_optional_token;
use crate::ai::shared::json_search::{canonical_meta_key, find_scalar_by_keys};

fn normalize_agent_hint(raw: &str) -> Option<String> {
    let normalized = raw.trim().to_lowercase();
    if normalized.is_empty() {
        None
    } else {
        Some(normalized)
    }
}

pub(crate) fn selection_hint_from_session(
    session: &SessionResponse,
) -> Option<crate::ai::AiSessionSelectionHint> {
    let mut root = serde_json::Map::<String, serde_json::Value>::new();
    for (k, v) in &session.extra {
        root.insert(k.clone(), v.clone());
    }
    // 把已知字段也放进统一搜索根，兼容不同服务端字段形态。
    root.insert(
        "id".to_string(),
        serde_json::Value::String(session.id.clone()),
    );
    root.insert(
        "title".to_string(),
        serde_json::Value::String(session.title.clone()),
    );
    if let Some(directory) = &session.directory {
        root.insert(
            "directory".to_string(),
            serde_json::Value::String(directory.clone()),
        );
    }
    let value = serde_json::Value::Object(root);

    selection_hint_from_value(&value)
}

pub(crate) fn selection_hint_from_value(
    value: &serde_json::Value,
) -> Option<crate::ai::AiSessionSelectionHint> {
    let agent = find_scalar_by_keys(
        value,
        &[
            "agent",
            "agent_name",
            "selected_agent",
            "current_agent",
            "mode",
            "mode_id",
            "current_mode_id",
        ],
    )
    .and_then(|v| normalize_agent_hint(&v));
    let model_provider_id = normalize_optional_token(find_scalar_by_keys(
        value,
        &[
            "model_provider_id",
            "model_provider",
            "provider_id",
            "providerID",
            "modelProviderID",
        ],
    ));
    let model_id = normalize_optional_token(find_scalar_by_keys(
        value,
        &[
            "model_id",
            "modelID",
            "selected_model",
            "current_model_id",
            "model",
        ],
    ));

    if agent.is_none() && model_id.is_none() {
        None
    } else {
        Some(crate::ai::AiSessionSelectionHint {
            agent,
            model_provider_id,
            model_id,
            config_options: None,
        })
    }
}

pub(crate) fn message_info_selection_source(info: &MessageInfo) -> Option<serde_json::Value> {
    let mut root = serde_json::Map::<String, serde_json::Value>::new();

    if let Some(agent) = normalize_optional_token(info.agent.clone()) {
        root.insert("agent".to_string(), serde_json::Value::String(agent));
    }
    if let Some(mode) = normalize_optional_token(info.mode.clone()) {
        root.insert("mode".to_string(), serde_json::Value::String(mode));
    }

    let provider_id = normalize_optional_token(
        info.model
            .as_ref()
            .and_then(|m| m.provider_id.clone())
            .or_else(|| info.provider_id.clone()),
    );
    if let Some(provider_id) = provider_id {
        root.insert(
            "providerID".to_string(),
            serde_json::Value::String(provider_id.clone()),
        );
        root.insert(
            "model_provider_id".to_string(),
            serde_json::Value::String(provider_id),
        );
    }

    let model_id = normalize_optional_token(
        info.model
            .as_ref()
            .and_then(|m| m.model_id.clone())
            .or_else(|| info.model_id.clone()),
    );
    if let Some(model_id) = model_id {
        root.insert(
            "modelID".to_string(),
            serde_json::Value::String(model_id.clone()),
        );
        root.insert("model_id".to_string(), serde_json::Value::String(model_id));
    }

    for (k, v) in &info.extra {
        let canonical = canonical_meta_key(k);
        if matches!(
            canonical.as_str(),
            "agent"
                | "mode"
                | "model"
                | "modelid"
                | "providerid"
                | "modelprovider"
                | "modelproviderid"
                | "currentmodelid"
                | "currentmodeid"
                | "selectedmodel"
                | "selectedagent"
        ) {
            root.insert(k.clone(), v.clone());
        }
    }

    if root.is_empty() {
        None
    } else {
        Some(serde_json::Value::Object(root))
    }
}

pub(crate) fn merge_part_source_with_message_info(
    part_source: Option<serde_json::Value>,
    message_info_source: Option<&serde_json::Value>,
) -> Option<serde_json::Value> {
    let Some(message_info_source) = message_info_source else {
        return part_source;
    };
    match part_source {
        Some(serde_json::Value::Object(mut part_obj)) => {
            if let serde_json::Value::Object(info_obj) = message_info_source {
                for (k, v) in info_obj {
                    if !part_obj.contains_key(k) {
                        part_obj.insert(k.clone(), v.clone());
                    }
                }
            }
            Some(serde_json::Value::Object(part_obj))
        }
        Some(other) => {
            let mut wrapped = serde_json::Map::<String, serde_json::Value>::new();
            wrapped.insert("source".to_string(), other);
            if let serde_json::Value::Object(info_obj) = message_info_source {
                for (k, v) in info_obj {
                    wrapped.insert(k.clone(), v.clone());
                }
            }
            Some(serde_json::Value::Object(wrapped))
        }
        None => Some(message_info_source.clone()),
    }
}
