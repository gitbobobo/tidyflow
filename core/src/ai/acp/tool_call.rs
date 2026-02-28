use crate::ai::AiToolCallLocation;
use serde_json::Value;

#[derive(Debug, Clone)]
pub(crate) struct ParsedToolCallUpdate {
    pub(crate) tool_call_id: Option<String>,
    pub(crate) tool_name: String,
    pub(crate) tool_kind: Option<String>,
    pub(crate) tool_title: Option<String>,
    pub(crate) status: Option<String>,
    pub(crate) raw_input: Option<Value>,
    pub(crate) raw_output: Option<Value>,
    pub(crate) locations: Option<Vec<AiToolCallLocation>>,
    pub(crate) progress_delta: Option<String>,
    pub(crate) output_delta: Option<String>,
    pub(crate) tool_part_metadata: Value,
}

fn normalize_non_empty_token(raw: &str) -> Option<String> {
    let token = raw.trim();
    if token.is_empty() {
        None
    } else {
        Some(token.to_string())
    }
}

fn normalized_update_token(raw: &str) -> String {
    raw.trim()
        .to_lowercase()
        .replace('-', "_")
        .replace(' ', "_")
}

fn normalized_content_type(content: &serde_json::Map<String, Value>) -> String {
    content
        .get("type")
        .and_then(|v| v.as_str())
        .map(|v| v.trim().to_ascii_lowercase())
        .unwrap_or_default()
}

pub(crate) fn normalize_tool_status(raw: Option<&str>, default_status: &str) -> String {
    let token = raw
        .map(normalized_update_token)
        .filter(|it| !it.is_empty())
        .unwrap_or_else(|| default_status.to_string());
    if token == "inprogress"
        || token == "in_progress"
        || token == "started"
        || token == "running"
        || token == "executing"
    {
        return "running".to_string();
    }
    if token == "requiresinput" || token == "requires_input" || token == "awaiting_input" {
        return "awaiting_input".to_string();
    }
    if token == "completed"
        || token == "complete"
        || token == "done"
        || token == "succeeded"
        || token == "success"
    {
        return "completed".to_string();
    }
    if token == "error"
        || token == "failed"
        || token == "rejected"
        || token == "cancelled"
        || token == "canceled"
        || token == "aborted"
    {
        return "error".to_string();
    }
    token
}

pub(crate) fn status_is_terminal(status: &str) -> bool {
    matches!(
        status,
        "completed" | "error" | "done" | "failed" | "cancelled" | "canceled"
    )
}

fn tool_status_rank(status: &str) -> u8 {
    match status {
        "unknown" => 0,
        "pending" => 1,
        "running" | "in_progress" | "awaiting_input" => 2,
        "completed" | "done" | "success" | "succeeded" => 3,
        "error" | "failed" | "rejected" | "cancelled" | "canceled" => 4,
        _ => 1,
    }
}

fn resolve_merged_tool_status(previous: Option<&str>, incoming: &str) -> String {
    let incoming_normalized = normalize_tool_status(Some(incoming), "running");
    let Some(previous_raw) = previous else {
        return incoming_normalized;
    };
    let previous_normalized = normalize_tool_status(Some(previous_raw), "running");

    if status_is_terminal(&previous_normalized) && !status_is_terminal(&incoming_normalized) {
        return previous_normalized;
    }

    let previous_rank = tool_status_rank(&previous_normalized);
    let incoming_rank = tool_status_rank(&incoming_normalized);
    if incoming_rank >= previous_rank {
        incoming_normalized
    } else {
        previous_normalized
    }
}

fn parse_u32_from_value(value: Option<&Value>) -> Option<u32> {
    match value {
        Some(Value::Number(num)) => num.as_u64().map(|v| v as u32),
        Some(Value::String(text)) => text.trim().parse::<u32>().ok(),
        _ => None,
    }
}

fn parse_tool_call_location(value: &Value) -> Option<AiToolCallLocation> {
    let obj = value.as_object()?;
    let range = obj.get("range").and_then(|v| v.as_object());
    let start = range
        .and_then(|r| r.get("start"))
        .and_then(|v| v.as_object());
    let end = range.and_then(|r| r.get("end")).and_then(|v| v.as_object());
    let uri = obj
        .get("uri")
        .or_else(|| obj.get("url"))
        .and_then(|v| v.as_str())
        .and_then(normalize_non_empty_token);
    let path = obj
        .get("path")
        .or_else(|| obj.get("file"))
        .or_else(|| obj.get("filePath"))
        .or_else(|| obj.get("file_path"))
        .and_then(|v| v.as_str())
        .and_then(normalize_non_empty_token);
    let line = parse_u32_from_value(
        obj.get("line")
            .or_else(|| start.and_then(|it| it.get("line"))),
    );
    let column = parse_u32_from_value(
        obj.get("column")
            .or_else(|| start.and_then(|it| it.get("column"))),
    );
    let end_line = parse_u32_from_value(
        obj.get("endLine")
            .or_else(|| obj.get("end_line"))
            .or_else(|| end.and_then(|it| it.get("line"))),
    );
    let end_column = parse_u32_from_value(
        obj.get("endColumn")
            .or_else(|| obj.get("end_column"))
            .or_else(|| end.and_then(|it| it.get("column"))),
    );
    let label = obj
        .get("label")
        .or_else(|| obj.get("title"))
        .or_else(|| obj.get("name"))
        .and_then(|v| v.as_str())
        .and_then(normalize_non_empty_token);

    if uri.is_none()
        && path.is_none()
        && line.is_none()
        && column.is_none()
        && end_line.is_none()
        && end_column.is_none()
        && label.is_none()
    {
        return None;
    }
    Some(AiToolCallLocation {
        uri,
        path,
        line,
        column,
        end_line,
        end_column,
        label,
    })
}

fn parse_tool_call_locations(
    content: &serde_json::Map<String, Value>,
) -> Option<Vec<AiToolCallLocation>> {
    let locations_value = content
        .get("locations")
        .or_else(|| content.get("toolCallLocations"))
        .or_else(|| content.get("tool_call_locations"));
    let mut locations = Vec::new();
    if let Some(items) = locations_value.and_then(|v| v.as_array()) {
        for item in items {
            if let Some(parsed) = parse_tool_call_location(item) {
                locations.push(parsed);
            }
        }
    }
    if locations.is_empty() {
        None
    } else {
        Some(locations)
    }
}

fn tool_locations_to_json(locations: &[AiToolCallLocation]) -> Value {
    Value::Array(
        locations
            .iter()
            .map(|location| {
                serde_json::json!({
                    "uri": location.uri,
                    "path": location.path,
                    "line": location.line,
                    "column": location.column,
                    "endLine": location.end_line,
                    "endColumn": location.end_column,
                    "label": location.label,
                })
            })
            .collect::<Vec<_>>(),
    )
}

pub(crate) fn extract_tool_output_text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => normalize_non_empty_token(text),
        Value::Object(obj) => {
            let pick_str = |keys: &[&str]| -> Option<String> {
                keys.iter().find_map(|key| {
                    obj.get(*key)
                        .and_then(|v| v.as_str())
                        .and_then(normalize_non_empty_token)
                })
            };
            let content_type = obj
                .get("type")
                .and_then(|v| v.as_str())
                .map(normalized_update_token)
                .unwrap_or_default();
            if content_type == "terminal" {
                return pick_str(&["output", "text", "delta", "message"]);
            }
            if content_type == "diff" {
                return pick_str(&["diff", "patch", "text", "delta"]);
            }
            if content_type == "markdown" || content_type == "md" {
                return pick_str(&["markdown", "text", "content"]);
            }
            pick_str(&["text", "content", "output", "delta"])
        }
        _ => None,
    }
}

pub(crate) fn parse_tool_call_update_content(
    content: &serde_json::Map<String, Value>,
) -> Option<ParsedToolCallUpdate> {
    let content_type = normalized_content_type(content);
    if content_type != "tool_call" && content_type != "tool_call_update" {
        return None;
    }
    let tool_call_id = content
        .get("toolCallId")
        .or_else(|| content.get("tool_call_id"))
        .or_else(|| content.get("id"))
        .and_then(|v| v.as_str())
        .and_then(normalize_non_empty_token);
    let tool_kind = content
        .get("kind")
        .or_else(|| content.get("toolKind"))
        .or_else(|| content.get("tool_kind"))
        .and_then(|v| v.as_str())
        .and_then(normalize_non_empty_token);
    let tool_name = content
        .get("toolName")
        .or_else(|| content.get("tool_name"))
        .or_else(|| content.get("name"))
        .and_then(|v| v.as_str())
        .and_then(normalize_non_empty_token)
        .or_else(|| tool_kind.clone())
        .unwrap_or_else(|| "unknown".to_string());
    let tool_title = content
        .get("title")
        .or_else(|| content.get("label"))
        .and_then(|v| v.as_str())
        .and_then(normalize_non_empty_token);
    let status = Some(normalize_tool_status(
        content
            .get("status")
            .or_else(|| content.get("state"))
            .and_then(|v| v.as_str()),
        if content_type == "tool_call" {
            "running"
        } else {
            "unknown"
        },
    ));
    let raw_input = content
        .get("rawInput")
        .or_else(|| content.get("raw_input"))
        .or_else(|| content.get("input"))
        .cloned()
        .filter(|v| !v.is_null());
    let nested_content = content.get("content").cloned().filter(|v| !v.is_null());
    let raw_output = content
        .get("rawOutput")
        .or_else(|| content.get("raw_output"))
        .cloned()
        .filter(|v| !v.is_null())
        .or_else(|| nested_content.clone());
    let locations = parse_tool_call_locations(content).or_else(|| {
        raw_output
            .as_ref()
            .and_then(|v| v.get("locations"))
            .and_then(|v| v.as_array())
            .map(|rows| {
                rows.iter()
                    .filter_map(parse_tool_call_location)
                    .collect::<Vec<_>>()
            })
            .filter(|rows| !rows.is_empty())
    });

    let progress_delta = content
        .get("progress")
        .or_else(|| content.get("message"))
        .and_then(|v| v.as_str())
        .and_then(normalize_non_empty_token)
        .or_else(|| {
            nested_content
                .as_ref()
                .and_then(extract_tool_output_text)
                .filter(|_| {
                    nested_content
                        .as_ref()
                        .and_then(|v| v.get("type"))
                        .and_then(|v| v.as_str())
                        .map(|token| normalized_update_token(token) == "terminal")
                        .unwrap_or(false)
                })
        });

    let output_delta = content
        .get("output")
        .or_else(|| content.get("text"))
        .or_else(|| content.get("delta"))
        .and_then(|v| v.as_str())
        .and_then(normalize_non_empty_token)
        .or_else(|| nested_content.as_ref().and_then(extract_tool_output_text));

    Some(ParsedToolCallUpdate {
        tool_call_id,
        tool_name,
        tool_kind,
        tool_title,
        status,
        raw_input,
        raw_output,
        locations,
        progress_delta,
        output_delta,
        tool_part_metadata: Value::Object(content.clone()),
    })
}

fn is_tool_call_session_update(session_update: &str) -> bool {
    matches!(
        normalized_update_token(session_update).as_str(),
        "tool_call" | "tool_call_update"
    )
}

pub(crate) fn parse_tool_call_update_event(
    update: &Value,
    session_update: &str,
) -> Option<ParsedToolCallUpdate> {
    let update_obj = update.as_object()?;
    if let Some(content_obj) = update_obj.get("content").and_then(|v| v.as_object()) {
        if let Some(parsed) = parse_tool_call_update_content(content_obj) {
            return Some(parsed);
        }
    }

    if !is_tool_call_session_update(session_update) {
        return None;
    }
    let update_type = normalized_update_token(session_update);

    if let Some(tool_call_obj) = update_obj.get("toolCall").and_then(|v| v.as_object()) {
        let mut candidate = tool_call_obj.clone();
        if !candidate.contains_key("type") {
            candidate.insert("type".to_string(), Value::String(update_type.clone()));
        }
        for key in [
            "toolCallId",
            "tool_call_id",
            "id",
            "toolName",
            "tool_name",
            "name",
            "kind",
            "toolKind",
            "tool_kind",
            "title",
            "label",
            "status",
            "state",
            "rawInput",
            "raw_input",
            "input",
            "rawOutput",
            "raw_output",
            "output",
            "delta",
            "progress",
            "message",
            "content",
            "locations",
            "toolCallLocations",
            "tool_call_locations",
        ] {
            if candidate.contains_key(key) {
                continue;
            }
            if let Some(value) = update_obj.get(key) {
                candidate.insert(key.to_string(), value.clone());
            }
        }
        if let Some(parsed) = parse_tool_call_update_content(&candidate) {
            return Some(parsed);
        }
    }

    let mut candidate = update_obj.clone();
    if !candidate.contains_key("type") {
        candidate.insert("type".to_string(), Value::String(update_type));
    }
    parse_tool_call_update_content(&candidate)
}

fn tool_state_from_parsed_tool_update(parsed: &ParsedToolCallUpdate) -> Value {
    let mut state = serde_json::Map::<String, Value>::new();
    state.insert(
        "status".to_string(),
        Value::String(
            parsed
                .status
                .clone()
                .unwrap_or_else(|| "running".to_string()),
        ),
    );
    if let Some(title) = parsed.tool_title.clone() {
        state.insert("title".to_string(), Value::String(title));
    }
    if let Some(raw_input) = parsed.raw_input.clone() {
        state.insert("input".to_string(), raw_input);
    }
    if let Some(raw_output) = parsed.raw_output.clone() {
        state.insert("raw".to_string(), raw_output.clone());
        if let Some(output_text) = extract_tool_output_text(&raw_output) {
            state.insert("output".to_string(), Value::String(output_text));
        }
    }
    let mut metadata = serde_json::Map::<String, Value>::new();
    if let Some(kind) = parsed.tool_kind.clone() {
        metadata.insert("kind".to_string(), Value::String(kind));
    }
    if let Some(tool_call_id) = parsed.tool_call_id.clone() {
        metadata.insert("tool_call_id".to_string(), Value::String(tool_call_id));
    }
    if let Some(locations) = parsed.locations.as_ref() {
        metadata.insert("locations".to_string(), tool_locations_to_json(locations));
    }
    if !metadata.is_empty() {
        state.insert("metadata".to_string(), Value::Object(metadata));
    }
    Value::Object(state)
}

fn append_tool_state_deltas(
    tool_state: &mut Value,
    progress_delta: Option<&str>,
    output_delta: Option<&str>,
) {
    let Some(obj) = tool_state.as_object_mut() else {
        return;
    };
    if let Some(progress) = progress_delta.and_then(normalize_non_empty_token) {
        let metadata = obj
            .entry("metadata".to_string())
            .or_insert_with(|| Value::Object(serde_json::Map::new()));
        if let Some(metadata_obj) = metadata.as_object_mut() {
            let lines = metadata_obj
                .entry("progress_lines".to_string())
                .or_insert_with(|| Value::Array(Vec::new()));
            if let Some(array) = lines.as_array_mut() {
                array.push(Value::String(progress));
            }
        }
    }
    if let Some(output) = output_delta.and_then(normalize_non_empty_token) {
        let previous = obj.get("output").and_then(|v| v.as_str()).unwrap_or("");
        let merged = if previous.ends_with(&output) {
            previous.to_string()
        } else {
            format!("{}{}", previous, output)
        };
        obj.insert("output".to_string(), Value::String(merged));
    }
}

fn merge_progress_lines(previous: Option<&Value>, incoming: Option<&Value>) -> Option<Value> {
    let mut lines = Vec::<String>::new();
    if let Some(rows) = previous.and_then(|v| v.as_array()) {
        for row in rows {
            if let Some(text) = row.as_str().and_then(normalize_non_empty_token) {
                lines.push(text);
            }
        }
    }
    if let Some(rows) = incoming.and_then(|v| v.as_array()) {
        for row in rows {
            if let Some(text) = row.as_str().and_then(normalize_non_empty_token) {
                lines.push(text);
            }
        }
    }
    if lines.is_empty() {
        None
    } else {
        Some(Value::Array(
            lines.into_iter().map(Value::String).collect::<Vec<_>>(),
        ))
    }
}

fn merge_tool_output(
    previous: Option<&str>,
    incoming: Option<&str>,
    output_delta: Option<&str>,
) -> Option<String> {
    let prev = previous.unwrap_or("");
    let incoming = incoming.unwrap_or("");
    let delta = output_delta.and_then(normalize_non_empty_token);

    if let Some(delta) = delta {
        let mut merged = String::from(prev);
        merged.push_str(&delta);
        return normalize_non_empty_token(&merged);
    }

    if prev.is_empty() {
        return normalize_non_empty_token(incoming);
    }
    if incoming.is_empty() {
        return normalize_non_empty_token(prev);
    }
    if incoming.starts_with(prev) {
        return Some(incoming.to_string());
    }
    if prev.ends_with(incoming) {
        return Some(prev.to_string());
    }
    let mut merged = String::from(prev);
    merged.push_str(incoming);
    normalize_non_empty_token(&merged)
}

pub(crate) fn merge_tool_state(previous: Option<&Value>, parsed: &ParsedToolCallUpdate) -> Value {
    let mut incoming = tool_state_from_parsed_tool_update(parsed);
    append_tool_state_deltas(
        &mut incoming,
        parsed.progress_delta.as_deref(),
        parsed.output_delta.as_deref(),
    );

    let mut merged_obj = previous
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default();
    let incoming_obj = incoming.as_object().cloned().unwrap_or_default();

    let previous_status = merged_obj.get("status").and_then(|v| v.as_str());
    let incoming_status = incoming_obj
        .get("status")
        .and_then(|v| v.as_str())
        .unwrap_or("running");
    let resolved_status = resolve_merged_tool_status(previous_status, incoming_status);
    merged_obj.insert("status".to_string(), Value::String(resolved_status));

    for key in ["title", "input", "raw", "error", "attachments", "time"] {
        if let Some(value) = incoming_obj.get(key) {
            merged_obj.insert(key.to_string(), value.clone());
        }
    }

    let merged_output = merge_tool_output(
        merged_obj.get("output").and_then(|v| v.as_str()),
        incoming_obj.get("output").and_then(|v| v.as_str()),
        parsed.output_delta.as_deref(),
    );
    if let Some(output) = merged_output {
        merged_obj.insert("output".to_string(), Value::String(output));
    }

    let mut merged_metadata = merged_obj
        .get("metadata")
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default();
    let incoming_metadata = incoming_obj
        .get("metadata")
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default();
    for (key, value) in incoming_metadata {
        if key == "progress_lines" {
            if let Some(lines) =
                merge_progress_lines(merged_metadata.get("progress_lines"), Some(&value))
            {
                merged_metadata.insert("progress_lines".to_string(), lines);
            }
        } else {
            merged_metadata.insert(key, value);
        }
    }
    if !merged_metadata.is_empty() {
        merged_obj.insert("metadata".to_string(), Value::Object(merged_metadata));
    }

    Value::Object(merged_obj)
}
