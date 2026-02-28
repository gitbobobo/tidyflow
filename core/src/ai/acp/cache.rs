use crate::ai::acp::plan::{self, AcpPlanSnapshot};
use crate::ai::{AiMessage, AiPart, AiSession};
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub(crate) struct CachedSessionRecord {
    pub(crate) title: String,
    pub(crate) updated_at_ms: i64,
    pub(crate) messages: Vec<AiMessage>,
}

pub(crate) fn normalized_title(raw: Option<&str>) -> Option<String> {
    let title = raw?;
    let trimmed = title.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

pub(crate) fn merge_sessions(remote: Vec<AiSession>, cached: Vec<AiSession>) -> Vec<AiSession> {
    let mut merged = HashMap::<String, AiSession>::new();
    for session in cached.into_iter().chain(remote.into_iter()) {
        if let Some(existing) = merged.get_mut(&session.id) {
            existing.updated_at = existing.updated_at.max(session.updated_at);
            if existing.title.trim().is_empty() && !session.title.trim().is_empty() {
                existing.title = session.title;
            }
        } else {
            merged.insert(session.id.clone(), session);
        }
    }
    let mut sessions = merged.into_values().collect::<Vec<_>>();
    sessions.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
    sessions
}

pub(crate) fn build_cached_user_message(
    message_id: String,
    text: String,
    now_ms: i64,
) -> AiMessage {
    AiMessage {
        id: message_id.clone(),
        role: "user".to_string(),
        created_at: Some(now_ms),
        agent: None,
        model_provider_id: None,
        model_id: None,
        parts: vec![AiPart::new_text(format!("{}-text", message_id), text)],
    }
}

pub(crate) fn build_cached_assistant_message(
    message_id: String,
    reasoning_text: String,
    answer_text: String,
    plan_current: Option<AcpPlanSnapshot>,
    plan_history: Vec<AcpPlanSnapshot>,
    now_ms: i64,
) -> Option<AiMessage> {
    let mut parts = Vec::new();
    if !reasoning_text.is_empty() {
        parts.push(AiPart {
            id: format!("{}-reasoning", message_id),
            part_type: "reasoning".to_string(),
            text: Some(reasoning_text),
            ..Default::default()
        });
    }
    if !answer_text.is_empty() {
        parts.push(AiPart::new_text(
            format!("{}-text", message_id),
            answer_text,
        ));
    }
    if let Some(current) = plan_current {
        parts.push(plan::build_plan_part(&message_id, &current, &plan_history));
    }
    if parts.is_empty() {
        None
    } else {
        Some(AiMessage {
            id: message_id,
            role: "assistant".to_string(),
            created_at: Some(now_ms),
            agent: None,
            model_provider_id: None,
            model_id: None,
            parts,
        })
    }
}
