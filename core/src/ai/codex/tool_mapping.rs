use crate::ai::AiPart;
use serde_json::Value;

fn canonical_method(method: &str) -> String {
    method
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .flat_map(|ch| ch.to_lowercase())
        .collect::<String>()
}

fn first_field<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    keys.iter().find_map(|key| value.get(*key))
}

fn value_to_string(value: &Value) -> Option<String> {
    match value {
        Value::String(v) => Some(v.to_string()),
        Value::Number(v) => Some(v.to_string()),
        Value::Bool(v) => Some(v.to_string()),
        Value::Object(_) | Value::Array(_) => serde_json::to_string(value).ok(),
        _ => None,
    }
}

fn normalize_tool_status(raw: &str) -> Option<&'static str> {
    let normalized = canonical_method(raw);
    match normalized.as_str() {
        "pending" | "queued" => Some("pending"),
        "running" | "inprogress" => Some("running"),
        "completed" | "success" | "succeeded" | "done" => Some("completed"),
        "failed" | "error" | "declined" | "cancelled" | "canceled" => Some("error"),
        _ => None,
    }
}

fn extract_tool_status(default_status: &str, item: &Value) -> String {
    if let Some(status) = item.get("status").and_then(|v| v.as_str()) {
        if let Some(mapped) = normalize_tool_status(status) {
            return mapped.to_string();
        }
    }
    normalize_tool_status(default_status)
        .unwrap_or("unknown")
        .to_string()
}

fn infer_command_execution_tool_name(item: &Value) -> Option<String> {
    let first_action = item
        .get("commandActions")
        .and_then(|v| v.as_array())
        .and_then(|actions| actions.first())?;
    let action_type = first_action.get("type").and_then(|v| v.as_str())?;
    match canonical_method(action_type).as_str() {
        "read" => Some("read".to_string()),
        "listfiles" => Some("list".to_string()),
        "search" => Some("grep".to_string()),
        _ => None,
    }
}

fn extract_file_change_metadata(item: &Value) -> Value {
    let mut metadata = item.as_object().cloned().unwrap_or_default();
    let mut file_paths = Vec::new();
    let mut diffs = Vec::new();
    if let Some(changes) = item.get("changes").and_then(|v| v.as_array()) {
        for change in changes {
            if let Some(path) = change.get("path").and_then(|v| v.as_str()) {
                file_paths.push(Value::String(path.to_string()));
            }
            if let Some(diff) = change
                .get("diff")
                .and_then(value_to_string)
                .filter(|text| !text.is_empty())
            {
                diffs.push(diff);
            }
        }
    }
    if !file_paths.is_empty() {
        metadata.insert("file_paths".to_string(), Value::Array(file_paths));
    }
    metadata.remove("files");
    if !diffs.is_empty() && !metadata.contains_key("diff") {
        metadata.insert("diff".to_string(), Value::String(diffs.join("\n\n")));
    }
    Value::Object(metadata)
}

fn extract_tool_metadata(tool_type: &str, tool_name: &str, item: &Value) -> Value {
    match tool_type {
        "filechange" => extract_file_change_metadata(item),
        "commandexecution" if tool_name == "list" => Value::Object(serde_json::Map::new()),
        _ => item.clone(),
    }
}

fn extract_tool_title(tool_name: &str, input: &Value, item: &Value) -> Option<String> {
    if tool_name == "list" {
        let command = item
            .get("command")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())?;
        return Some(format!("list({})", command));
    }
    let path = input
        .get("path")
        .and_then(|v| v.as_str())
        .or_else(|| input.get("filePath").and_then(|v| v.as_str()))
        .filter(|v| !v.is_empty())?;
    match tool_name {
        "read" => Some(format!("read({})", path)),
        "write" | "edit" | "apply_patch" | "multiedit" => Some(format!("write({})", path)),
        _ => None,
    }
}

fn is_known_tool_for_card(tool_name: &str) -> bool {
    matches!(
        tool_name,
        "read"
            | "grep"
            | "edit"
            | "write"
            | "apply_patch"
            | "multiedit"
            | "bash"
            | "glob"
            | "list"
            | "websearch"
            | "codesearch"
            | "webfetch"
            | "task"
            | "skill"
            | "question"
            | "plan_enter"
            | "plan_exit"
            | "todowrite"
            | "todoread"
            | "batch"
    )
}

fn normalize_codex_tool_name(raw_type: &str, item: &Value) -> String {
    match raw_type {
        "commandexecution" => {
            infer_command_execution_tool_name(item).unwrap_or_else(|| "bash".to_string())
        }
        "filechange" => "write".to_string(),
        "fileread" => "read".to_string(),
        "codeexecution" => "code_execution".to_string(),
        "websearch" => "websearch".to_string(),
        "question" => "question".to_string(),
        other => other.to_string(),
    }
}

fn extract_tool_input(tool_type: &str, tool_name: &str, item: &Value) -> Value {
    match tool_type {
        "commandexecution" => {
            let mut input = serde_json::Map::new();
            if tool_name == "bash" {
                if let Some(command) = first_field(item, &["command"]) {
                    input.insert("command".to_string(), command.clone());
                }
            }

            if tool_name == "read" {
                if let Some(path) = item
                    .get("commandActions")
                    .and_then(|v| v.as_array())
                    .and_then(|actions| actions.first())
                    .and_then(|action| action.get("path"))
                    .and_then(|v| v.as_str())
                {
                    input.insert("path".to_string(), Value::String(path.to_string()));
                    input.insert("filePath".to_string(), Value::String(path.to_string()));
                }
            } else if tool_name == "grep" {
                if let Some(action) = item
                    .get("commandActions")
                    .and_then(|v| v.as_array())
                    .and_then(|actions| actions.first())
                {
                    if let Some(query) = action.get("query").and_then(|v| v.as_str()) {
                        input.insert("query".to_string(), Value::String(query.to_string()));
                        input.insert("pattern".to_string(), Value::String(query.to_string()));
                    }
                    if let Some(path) = action.get("path").and_then(|v| v.as_str()) {
                        input.insert("path".to_string(), Value::String(path.to_string()));
                    }
                }
            } else if let Some(command) = first_field(item, &["command"]) {
                input.insert("command".to_string(), command.clone());
            }

            if input.is_empty() {
                Value::Null
            } else {
                Value::Object(input)
            }
        }
        "filechange" => {
            let paths = item
                .get("changes")
                .and_then(|v| v.as_array())
                .into_iter()
                .flatten()
                .filter_map(|change| change.get("path").and_then(|v| v.as_str()))
                .filter(|path| !path.is_empty())
                .map(|path| path.to_string())
                .collect::<Vec<_>>();
            let mut input = serde_json::Map::new();
            if let Some(first_path) = paths.first() {
                input.insert("path".to_string(), Value::String(first_path.clone()));
            }
            if !paths.is_empty() {
                input.insert(
                    "paths".to_string(),
                    Value::Array(paths.into_iter().map(Value::String).collect()),
                );
            }
            if input.is_empty() {
                Value::Null
            } else {
                Value::Object(input)
            }
        }
        "fileread" => {
            let path = item.get("path").cloned().unwrap_or(Value::Null);
            serde_json::json!({ "path": path })
        }
        "codeexecution" => {
            let code = item.get("code").cloned().unwrap_or(Value::Null);
            serde_json::json!({ "code": code })
        }
        "websearch" => {
            let query = item.get("query").cloned().unwrap_or(Value::Null);
            serde_json::json!({ "query": query })
        }
        "question" => {
            let questions = crate::ai::codex::question::extract_question_nodes(item);
            if questions.is_empty() {
                Value::Null
            } else {
                serde_json::json!({ "questions": questions })
            }
        }
        _ => Value::Null,
    }
}

fn extract_tool_output(tool_type: &str, item: &Value) -> Option<String> {
    match tool_type {
        "commandexecution" => {
            first_field(item, &["aggregatedOutput", "output"]).and_then(value_to_string)
        }
        "filechange" => {
            let direct = item
                .get("diff")
                .and_then(value_to_string)
                .filter(|text| !text.is_empty());
            if direct.is_some() {
                direct
            } else {
                let diffs = item
                    .get("changes")
                    .and_then(|v| v.as_array())
                    .into_iter()
                    .flatten()
                    .filter_map(|change| {
                        change
                            .get("diff")
                            .and_then(value_to_string)
                            .filter(|text| !text.is_empty())
                    })
                    .collect::<Vec<_>>();
                if diffs.is_empty() {
                    None
                } else {
                    Some(diffs.join("\n\n"))
                }
            }
        }
        "fileread" => item.get("content").and_then(value_to_string),
        "codeexecution" => item.get("output").and_then(value_to_string),
        "websearch" => item.get("results").map(|v| v.to_string()),
        _ => None,
    }
}

pub(super) fn map_item_to_part(item: &Value, status: &str) -> Option<AiPart> {
    let part_id = item.get("id")?.as_str()?.to_string();
    let kind = item.get("type")?.as_str()?.to_lowercase();
    match kind.as_str() {
        "agentmessage" => {
            let text = item
                .get("text")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let mut source = serde_json::Map::new();
            source.insert("vendor".to_string(), Value::String("codex".to_string()));
            source.insert(
                "item_type".to_string(),
                Value::String("agentmessage".to_string()),
            );
            if let Some(phase) = item
                .get("phase")
                .and_then(|v| v.as_str())
                .map(|s| s.trim().to_lowercase())
                .filter(|s| !s.is_empty())
            {
                source.insert("message_phase".to_string(), Value::String(phase));
            }
            Some(AiPart {
                id: part_id,
                part_type: "text".to_string(),
                text: Some(text),
                source: Some(Value::Object(source)),
                ..Default::default()
            })
        }
        "plan" => {
            let text = item
                .get("text")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            Some(AiPart {
                id: part_id,
                part_type: "text".to_string(),
                text: Some(text),
                source: Some(serde_json::json!({
                    "vendor": "codex",
                    "item_type": "plan"
                })),
                ..Default::default()
            })
        }
        "reasoning" => {
            let summary = item
                .get("summary")
                .and_then(|v| v.as_array())
                .into_iter()
                .flatten()
                .filter_map(|v| v.as_str())
                .collect::<Vec<_>>()
                .join("\n");
            let content = item
                .get("content")
                .and_then(|v| v.as_array())
                .into_iter()
                .flatten()
                .filter_map(|v| v.as_str())
                .collect::<Vec<_>>()
                .join("\n");
            let text = if summary.is_empty() {
                content
            } else if content.is_empty() {
                summary
            } else {
                format!("{}\n{}", summary, content)
            };
            Some(AiPart {
                id: part_id,
                part_type: "reasoning".to_string(),
                text: Some(text),
                ..Default::default()
            })
        }
        "imageview" => Some(AiPart {
            id: part_id,
            part_type: "file".to_string(),
            url: item
                .get("path")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string()),
            ..Default::default()
        }),
        "usermessage" => None,
        other => {
            let tool_name = normalize_codex_tool_name(other, item);
            let tool_call_id = item.get("id").and_then(|v| v.as_str()).map(String::from);
            let output = if tool_name == "read" {
                None
            } else {
                extract_tool_output(other, item)
            };
            let input = extract_tool_input(other, &tool_name, item);
            let mut tool_state = serde_json::json!({
                "status": extract_tool_status(status, item),
                "input": input,
                "output": output,
                "metadata": extract_tool_metadata(other, &tool_name, item),
            });
            if let Some(title) = extract_tool_title(&tool_name, &tool_state["input"], item) {
                tool_state["title"] = Value::String(title);
            }
            if !is_known_tool_for_card(&tool_name) {
                tool_state["raw"] = Value::String(item.to_string());
            }
            Some(AiPart {
                id: part_id,
                part_type: "tool".to_string(),
                tool_name: Some(tool_name),
                tool_call_id,
                tool_state: Some(tool_state),
                ..Default::default()
            })
        }
    }
}

pub(super) fn parse_user_text(item: &Value) -> String {
    let mut chunks = Vec::new();
    let content = item
        .get("content")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    for input in content {
        let kind = input
            .get("type")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_lowercase();
        match kind.as_str() {
            "text" => {
                if let Some(text) = input.get("text").and_then(|v| v.as_str()) {
                    chunks.push(text.to_string());
                }
            }
            "mention" => {
                if let Some(path) = input.get("path").and_then(|v| v.as_str()) {
                    chunks.push(format!("@{}", path));
                }
            }
            "localimage" => {
                if let Some(path) = input.get("path").and_then(|v| v.as_str()) {
                    chunks.push(format!("[image:{}]", path));
                }
            }
            "image" => {
                if let Some(url) = input.get("url").and_then(|v| v.as_str()) {
                    chunks.push(format!("[image:{}]", url));
                }
            }
            _ => {}
        }
    }
    chunks.join("\n")
}
