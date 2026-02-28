use crate::ai::{AiMessage, AiPart};
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AcpPlanEntry {
    pub(crate) content: String,
    pub(crate) status: String,
    pub(crate) priority: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AcpPlanSnapshot {
    pub(crate) revision: u64,
    pub(crate) updated_at_ms: i64,
    pub(crate) entries: Vec<AcpPlanEntry>,
}

fn normalize_optional_string(value: Option<&Value>) -> Option<String> {
    value
        .and_then(|v| v.as_str())
        .map(|v| v.trim())
        .filter(|v| !v.is_empty())
        .map(|v| v.to_string())
}

fn normalized_update_token(raw: &str) -> String {
    raw.trim()
        .to_lowercase()
        .replace('-', "_")
        .replace(' ', "_")
}

pub(super) fn parse_plan_entry(value: &Value) -> Option<AcpPlanEntry> {
    let obj = value.as_object()?;
    let content = normalize_optional_string(obj.get("content"))?;
    let status = normalize_optional_string(obj.get("status"))?;
    let priority = normalize_optional_string(obj.get("priority"));
    Some(AcpPlanEntry {
        content,
        status,
        priority,
    })
}

pub(super) fn extract_plan_entries(update: &Value) -> Option<Vec<AcpPlanEntry>> {
    let entries_value = update
        .get("entries")
        .or_else(|| update.get("content").and_then(|v| v.get("entries")))?;
    let items = entries_value.as_array()?;
    Some(
        items
            .iter()
            .filter_map(parse_plan_entry)
            .collect::<Vec<_>>(),
    )
}

pub(super) fn is_plan_update(session_update: &str) -> bool {
    normalized_update_token(session_update) == "plan"
}

pub(super) fn apply_plan_update(
    current: &mut Option<AcpPlanSnapshot>,
    history: &mut Vec<AcpPlanSnapshot>,
    revision: &mut u64,
    entries: Vec<AcpPlanEntry>,
    plan_history_limit: usize,
    now_ms: i64,
) -> AcpPlanSnapshot {
    if let Some(previous) = current.take() {
        history.push(previous);
        if history.len() > plan_history_limit {
            let overflow = history.len() - plan_history_limit;
            history.drain(0..overflow);
        }
    }
    *revision = revision.saturating_add(1);
    let snapshot = AcpPlanSnapshot {
        revision: *revision,
        updated_at_ms: now_ms,
        entries,
    };
    *current = Some(snapshot.clone());
    snapshot
}

pub(super) fn plan_entries_to_value(entries: &[AcpPlanEntry]) -> Value {
    Value::Array(
        entries
            .iter()
            .map(|entry| {
                let mut obj = serde_json::Map::new();
                obj.insert("content".to_string(), Value::String(entry.content.clone()));
                obj.insert("status".to_string(), Value::String(entry.status.clone()));
                if let Some(priority) = entry.priority.clone() {
                    obj.insert("priority".to_string(), Value::String(priority));
                }
                Value::Object(obj)
            })
            .collect::<Vec<_>>(),
    )
}

pub(super) fn plan_snapshot_to_value(snapshot: &AcpPlanSnapshot) -> Value {
    serde_json::json!({
        "revision": snapshot.revision,
        "updated_at_ms": snapshot.updated_at_ms,
        "entries": plan_entries_to_value(&snapshot.entries),
    })
}

pub(super) fn build_plan_source(current: &AcpPlanSnapshot, history: &[AcpPlanSnapshot]) -> Value {
    let history_values = history
        .iter()
        .map(plan_snapshot_to_value)
        .collect::<Vec<_>>();
    serde_json::json!({
        "vendor": "acp",
        "item_type": "plan",
        "protocol": "agent-plan",
        "revision": current.revision,
        "updated_at_ms": current.updated_at_ms,
        "entries": plan_entries_to_value(&current.entries),
        "history": history_values,
    })
}

pub(super) fn build_plan_part(
    message_id: &str,
    current: &AcpPlanSnapshot,
    history: &[AcpPlanSnapshot],
) -> AiPart {
    AiPart {
        id: format!("{}-plan", message_id),
        part_type: "plan".to_string(),
        source: Some(build_plan_source(current, history)),
        ..Default::default()
    }
}

pub(super) fn flush_plan_snapshot_for_history(
    messages: &mut Vec<AiMessage>,
    message_id_prefix: &str,
    next_message_index: &mut u64,
    plan_current: &mut Option<AcpPlanSnapshot>,
    plan_history: &mut Vec<AcpPlanSnapshot>,
    now_ms: i64,
) {
    let Some(current) = plan_current.take() else {
        return;
    };
    *next_message_index = next_message_index.saturating_add(1);
    let message_id = format!(
        "{}-assistant-plan-{}",
        message_id_prefix, next_message_index
    );
    let plan_part = build_plan_part(&message_id, &current, plan_history);
    messages.push(AiMessage {
        id: message_id,
        role: "assistant".to_string(),
        created_at: Some(now_ms),
        agent: None,
        model_provider_id: None,
        model_id: None,
        parts: vec![plan_part],
    });
    plan_history.clear();
}
