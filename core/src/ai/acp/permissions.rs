use crate::ai::shared::request_id::request_id_key as shared_request_id_key;
use crate::ai::{AiQuestionInfo, AiQuestionOption, AiQuestionRequest};
use serde_json::Value;
use std::collections::HashSet;
use tracing::warn;

#[derive(Debug, Clone)]
pub(crate) struct PermissionOption {
    pub(crate) option_id: String,
    pub(crate) normalized_name: String,
}

#[derive(Debug, Clone)]
pub(crate) struct PendingPermission {
    pub(crate) request_id: Value,
    pub(crate) session_id: String,
    pub(crate) options: Vec<PermissionOption>,
}

fn normalize_mode_name(raw: &str) -> String {
    raw.trim()
        .to_lowercase()
        .replace('-', "_")
        .replace(' ', "_")
}

fn normalize_non_empty_token(raw: &str) -> Option<String> {
    let token = raw.trim();
    if token.is_empty() {
        None
    } else {
        Some(token.to_string())
    }
}

pub(crate) fn request_id_key(id: &Value) -> String {
    shared_request_id_key(id)
}

pub(crate) fn parse_permission_options(params: &Value) -> Vec<PermissionOption> {
    let mut options = Vec::new();
    let mut seen_option_ids = HashSet::new();
    let Some(rows) = params.get("options").and_then(|v| v.as_array()) else {
        return options;
    };
    for row in rows {
        let Some(option_id) = row
            .get("optionId")
            .or_else(|| row.get("option_id"))
            .or_else(|| row.get("id"))
            .and_then(|v| v.as_str())
            .and_then(normalize_non_empty_token)
        else {
            continue;
        };
        let option_id_key = option_id.to_lowercase();
        if !seen_option_ids.insert(option_id_key) {
            continue;
        }
        let name = row
            .get("name")
            .or_else(|| row.get("label"))
            .and_then(|v| v.as_str())
            .and_then(normalize_non_empty_token)
            .unwrap_or_else(|| option_id.clone());
        options.push(PermissionOption {
            option_id,
            normalized_name: normalize_mode_name(&name),
        });
    }
    options
}

pub(crate) fn resolve_permission_option_id(
    pending: &PendingPermission,
    answers: &[Vec<String>],
) -> Option<String> {
    let candidates = answers
        .iter()
        .flat_map(|group| group.iter())
        .filter_map(|answer| normalize_non_empty_token(answer))
        .collect::<Vec<_>>();

    for candidate in &candidates {
        if let Some(found) = pending.options.iter().find(|option| {
            option.option_id == *candidate || option.option_id.eq_ignore_ascii_case(candidate)
        }) {
            return Some(found.option_id.clone());
        }
    }

    for candidate in &candidates {
        let normalized = normalize_mode_name(candidate);
        if normalized.is_empty() {
            continue;
        }
        if let Some(found) = pending
            .options
            .iter()
            .find(|option| option.normalized_name == normalized)
        {
            return Some(found.option_id.clone());
        }
    }

    if let Some(found) = pending.options.iter().find(|option| {
        option.option_id.eq_ignore_ascii_case("allow-once")
            || option.option_id.eq_ignore_ascii_case("allow_once")
    }) {
        warn!(
            "permission request {} missing explicit optionId mapping, fallback to allow-once",
            request_id_key(&pending.request_id)
        );
        return Some(found.option_id.clone());
    }

    let fallback = pending
        .options
        .first()
        .map(|option| option.option_id.clone());
    if let Some(option_id) = fallback.as_deref() {
        warn!(
            "permission request {} missing optionId mapping, fallback to first option={}",
            request_id_key(&pending.request_id),
            option_id
        );
    }
    fallback
}

pub(crate) fn build_question_from_permission_request(
    request_id: &Value,
    params: &Value,
) -> Option<(AiQuestionRequest, Vec<PermissionOption>)> {
    let session_id = params.get("sessionId")?.as_str()?.to_string();
    let tool_call = params.get("toolCall")?;
    let tool_call_id = tool_call
        .get("toolCallId")
        .and_then(|v| v.as_str())
        .map(String::from);
    let permission_options = parse_permission_options(params);
    let raw_input = tool_call.get("rawInput").cloned().unwrap_or(Value::Null);
    let tool_kind = tool_call
        .get("kind")
        .or_else(|| tool_call.get("toolKind"))
        .or_else(|| tool_call.get("tool_kind"))
        .and_then(|v| v.as_str())
        .and_then(normalize_non_empty_token);

    let questions = if let Some(qs) = raw_input.get("questions").and_then(|v| v.as_array()) {
        qs.iter()
            .filter_map(|q| {
                let question = q.get("question")?.as_str()?.to_string();
                let header = q
                    .get("header")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let options = q
                    .get("options")
                    .and_then(|v| v.as_array())
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|opt| {
                                let label = opt
                                    .get("label")
                                    .or_else(|| opt.get("name"))
                                    .and_then(|v| v.as_str())
                                    .and_then(normalize_non_empty_token)?;
                                Some(AiQuestionOption {
                                    option_id: opt
                                        .get("optionId")
                                        .or_else(|| opt.get("option_id"))
                                        .or_else(|| opt.get("id"))
                                        .and_then(|v| v.as_str())
                                        .and_then(normalize_non_empty_token),
                                    label,
                                    description: opt
                                        .get("description")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or("")
                                        .to_string(),
                                })
                            })
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default();
                let multiple = q.get("multiple").and_then(|v| v.as_bool()).unwrap_or(false);
                let custom = q.get("custom").and_then(|v| v.as_bool()).unwrap_or(true);
                Some(AiQuestionInfo {
                    question,
                    header,
                    options,
                    multiple,
                    custom,
                })
            })
            .collect()
    } else {
        let title = tool_call
            .get("title")
            .and_then(|v| v.as_str())
            .unwrap_or("Permission required");
        let header = tool_kind
            .clone()
            .map(|kind| format!("Permission ({})", kind))
            .unwrap_or_else(|| "Permission".to_string());
        vec![AiQuestionInfo {
            question: title.to_string(),
            header,
            options: params
                .get("options")
                .and_then(|v| v.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|opt| {
                            let label = opt
                                .get("name")
                                .or_else(|| opt.get("label"))
                                .and_then(|v| v.as_str())
                                .and_then(normalize_non_empty_token)?;
                            Some(AiQuestionOption {
                                option_id: opt
                                    .get("optionId")
                                    .or_else(|| opt.get("option_id"))
                                    .or_else(|| opt.get("id"))
                                    .and_then(|v| v.as_str())
                                    .and_then(normalize_non_empty_token),
                                label,
                                description: opt
                                    .get("kind")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_string(),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default(),
            multiple: false,
            custom: false,
        }]
    };

    Some((
        AiQuestionRequest {
            id: request_id_key(request_id),
            session_id,
            questions,
            tool_message_id: tool_call_id.clone(),
            tool_call_id,
        },
        permission_options,
    ))
}
