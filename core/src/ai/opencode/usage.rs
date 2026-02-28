use super::protocol::{MessageEnvelope, ProviderModelResponse, ProviderResponse};
use super::selection_hint::normalize_optional_token;

fn json_value_to_f64(value: &serde_json::Value) -> Option<f64> {
    match value {
        serde_json::Value::Number(n) => n.as_f64(),
        serde_json::Value::String(s) => s.trim().parse::<f64>().ok(),
        _ => None,
    }
}

fn message_total_tokens(message: &MessageEnvelope) -> Option<f64> {
    message
        .info
        .extra
        .get("tokens")
        .and_then(|v| v.get("total"))
        .and_then(json_value_to_f64)
        .or_else(|| {
            message
                .info
                .extra
                .get("usage")
                .and_then(|v| {
                    v.get("total_tokens")
                        .or_else(|| v.get("totalTokens"))
                        .or_else(|| v.get("total"))
                })
                .and_then(json_value_to_f64)
        })
}

fn message_model_identity(message: &MessageEnvelope) -> (Option<String>, Option<String>) {
    let provider_id = normalize_optional_token(
        message
            .info
            .model
            .as_ref()
            .and_then(|m| m.provider_id.clone())
            .or_else(|| message.info.provider_id.clone()),
    );
    let model_id = normalize_optional_token(
        message
            .info
            .model
            .as_ref()
            .and_then(|m| m.model_id.clone())
            .or_else(|| message.info.model_id.clone()),
    );
    (provider_id, model_id)
}

pub(crate) fn latest_assistant_usage(
    messages: &[MessageEnvelope],
) -> Option<(f64, Option<String>, Option<String>)> {
    let mut best: Option<(i64, f64, Option<String>, Option<String>)> = None;
    for message in messages {
        if !message.info.role.eq_ignore_ascii_case("assistant") {
            continue;
        }
        let Some(total_tokens) = message_total_tokens(message) else {
            continue;
        };
        let created_at = message.info.created_at.unwrap_or(0);
        let (provider_id, model_id) = message_model_identity(message);
        match best {
            Some((best_created_at, _, _, _)) if best_created_at > created_at => {}
            _ => best = Some((created_at, total_tokens, provider_id, model_id)),
        }
    }
    best.map(|(_, total_tokens, provider_id, model_id)| (total_tokens, provider_id, model_id))
}

fn context_window_from_model(model: &ProviderModelResponse) -> Option<f64> {
    let limit = model.limit.as_ref()?;
    let obj = limit.as_object()?;
    for key in [
        "context",
        "contextWindow",
        "context_window",
        "contextTokens",
        "context_tokens",
    ] {
        if let Some(value) = obj.get(key).and_then(json_value_to_f64) {
            if value > 0.0 {
                return Some(value);
            }
        }
    }
    None
}

pub(crate) fn resolve_context_window(
    providers: &[ProviderResponse],
    provider_id: Option<&str>,
    model_id: Option<&str>,
) -> Option<f64> {
    let model_id = model_id?.trim();
    if model_id.is_empty() {
        return None;
    }

    if let Some(provider_id) = provider_id.map(str::trim).filter(|v| !v.is_empty()) {
        if let Some(provider) = providers.iter().find(|p| p.id == provider_id) {
            if let Some(model) = provider.models_vec().into_iter().find(|m| m.id == model_id) {
                if let Some(window) = context_window_from_model(&model) {
                    return Some(window);
                }
            }
        }
    }

    for provider in providers {
        if let Some(model) = provider.models_vec().into_iter().find(|m| m.id == model_id) {
            if let Some(window) = context_window_from_model(&model) {
                return Some(window);
            }
        }
    }

    None
}

pub(crate) fn compute_remaining_percent(total_tokens: f64, context_window: f64) -> Option<f64> {
    if !total_tokens.is_finite() || !context_window.is_finite() || context_window <= 0.0 {
        return None;
    }
    Some((((context_window - total_tokens) / context_window) * 100.0).clamp(0.0, 100.0))
}
