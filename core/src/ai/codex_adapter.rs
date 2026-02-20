use super::codex_client::{CodexAppServerClient, CodexModelInfo};
use super::codex_manager::CodexAppServerManager;
use super::session_status::AiSessionStatus;
use super::{
    AiAgent, AiAgentInfo, AiEvent, AiEventStream, AiImagePart, AiMessage, AiModelInfo,
    AiModelSelection, AiPart, AiProviderInfo, AiQuestionInfo, AiQuestionOption, AiQuestionRequest,
    AiSession, AiSessionSelectionHint, AiSlashCommand,
};
use async_trait::async_trait;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};
use tokio_stream::wrappers::UnboundedReceiverStream;
use tracing::{debug, info, warn};
use uuid::Uuid;

#[derive(Debug, Clone)]
struct PendingApproval {
    id: Value,
    method: String,
    question_ids: Vec<String>,
    session_id: String,
    tool_message_id: Option<String>,
}

pub struct CodexAppServerAgent {
    client: CodexAppServerClient,
    pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>>,
    active_turns: Arc<Mutex<HashMap<String, String>>>,
    selection_hints: Arc<Mutex<HashMap<String, AiSessionSelectionHint>>>,
}

impl CodexAppServerAgent {
    pub fn new(manager: Arc<CodexAppServerManager>) -> Self {
        Self {
            client: CodexAppServerClient::new(manager),
            pending_approvals: Arc::new(Mutex::new(HashMap::new())),
            active_turns: Arc::new(Mutex::new(HashMap::new())),
            selection_hints: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn canonical_meta_key(raw: &str) -> String {
        raw.chars()
            .filter(|ch| *ch != '_' && *ch != '-')
            .flat_map(|ch| ch.to_lowercase())
            .collect::<String>()
    }

    fn json_value_to_trimmed_string(value: &Value) -> Option<String> {
        match value {
            Value::String(s) => {
                let trimmed = s.trim();
                if trimmed.is_empty() {
                    None
                } else {
                    Some(trimmed.to_string())
                }
            }
            Value::Number(n) => Some(n.to_string()),
            _ => None,
        }
    }

    fn find_scalar_by_keys(value: &Value, keys: &[&str]) -> Option<String> {
        let target = keys
            .iter()
            .map(|key| Self::canonical_meta_key(key))
            .collect::<Vec<_>>();
        let mut stack = vec![value];
        let mut visited = 0usize;
        const MAX_VISITS: usize = 400;

        while let Some(node) = stack.pop() {
            if visited >= MAX_VISITS {
                break;
            }
            visited += 1;
            match node {
                Value::Object(map) => {
                    for (k, v) in map {
                        let canonical = Self::canonical_meta_key(k);
                        if target.iter().any(|key| key == &canonical) {
                            if let Some(found) = Self::json_value_to_trimmed_string(v) {
                                return Some(found);
                            }
                        }
                        if matches!(v, Value::Object(_) | Value::Array(_)) {
                            stack.push(v);
                        }
                    }
                }
                Value::Array(arr) => {
                    for item in arr {
                        if matches!(item, Value::Object(_) | Value::Array(_)) {
                            stack.push(item);
                        }
                    }
                }
                _ => {}
            }
        }

        None
    }

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

    fn normalize_optional_token(raw: Option<String>) -> Option<String> {
        let token = raw?;
        let trimmed = token.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    }

    fn selection_hint_from_thread_payload(value: &Value) -> Option<AiSessionSelectionHint> {
        // 优先读取 Codex turn_start 对齐字段。
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
            .or_else(|| {
                Self::find_scalar_by_keys(value, &["collaboration_mode", "collaborationMode"])
            });
        let agent = collab_mode.and_then(|v| Self::normalize_agent_hint(&v));

        let model_provider_id = Self::normalize_optional_token(
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
                .or_else(|| Self::find_scalar_by_keys(value, &["model_provider", "modelProvider"])),
        );

        let model_id = Self::normalize_optional_token(
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
                .or_else(|| Self::find_scalar_by_keys(value, &["model_id", "modelID", "model"])),
        );

        if agent.is_none() && model_provider_id.is_none() && model_id.is_none() {
            None
        } else {
            Some(AiSessionSelectionHint {
                agent,
                model_provider_id,
                model_id,
            })
        }
    }

    fn request_id_key(id: &Value) -> String {
        match id {
            Value::String(s) => format!("s:{}", s),
            Value::Number(n) => format!("n:{}", n),
            _ => format!("j:{}", id),
        }
    }

    fn canonical_method(method: &str) -> String {
        method
            .chars()
            .filter(|ch| ch.is_ascii_alphanumeric())
            .flat_map(|ch| ch.to_lowercase())
            .collect::<String>()
    }

    fn method_in(method: &str, candidates: &[&str]) -> bool {
        let canonical = Self::canonical_method(method);
        candidates
            .iter()
            .any(|candidate| canonical == Self::canonical_method(candidate))
    }

    fn first_string_by_pointers(value: &Value, pointers: &[&str]) -> Option<String> {
        pointers.iter().find_map(|pointer| {
            value
                .pointer(pointer)
                .and_then(Self::json_value_to_trimmed_string)
        })
    }

    fn should_ignore_error_notification(params: &Value) -> bool {
        if params
            .pointer("/willRetry")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
        {
            return true;
        }
        if params
            .pointer("/will_retry")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
        {
            return true;
        }
        false
    }

    fn extract_question_nodes(value: &Value) -> Vec<Value> {
        let question_array_paths = [
            "/questions",
            "/input/questions",
            "/request/questions",
            "/toolInput/questions",
            "/rawInput/questions",
            "/schema/questions",
        ];
        for path in question_array_paths {
            if let Some(items) = value.pointer(path).and_then(|v| v.as_array()) {
                if !items.is_empty() {
                    return items.to_vec();
                }
            }
        }

        let single_question_paths = [
            "/question",
            "/input/question",
            "/request/question",
            "/toolInput/question",
            "/rawInput/question",
        ];
        for path in single_question_paths {
            if let Some(question) = value.pointer(path) {
                match question {
                    Value::Object(_) => return vec![question.clone()],
                    Value::String(text) => {
                        let trimmed = text.trim();
                        if !trimmed.is_empty() {
                            return vec![serde_json::json!({ "question": trimmed })];
                        }
                    }
                    _ => {}
                }
            }
        }

        Vec::new()
    }

    fn parse_question_options(value: Option<&Value>) -> Vec<AiQuestionOption> {
        let Some(value) = value else {
            return Vec::new();
        };
        let Some(options) = value.as_array() else {
            return Vec::new();
        };
        options
            .iter()
            .filter_map(|option| match option {
                Value::String(label) => {
                    let normalized = label.trim();
                    if normalized.is_empty() {
                        None
                    } else {
                        Some(AiQuestionOption {
                            label: normalized.to_string(),
                            description: String::new(),
                        })
                    }
                }
                Value::Object(_) => {
                    let label = Self::first_string_by_pointers(
                        option,
                        &["/label", "/value", "/name", "/id", "/text"],
                    )?;
                    let description = Self::first_string_by_pointers(
                        option,
                        &["/description", "/hint", "/detail"],
                    )
                    .unwrap_or_default();
                    Some(AiQuestionOption { label, description })
                }
                _ => None,
            })
            .collect()
    }

    fn parse_question_info(node: &Value, index: usize) -> Option<(AiQuestionInfo, Option<String>)> {
        let question_text = Self::first_string_by_pointers(
            node,
            &["/question", "/prompt", "/text", "/title", "/message"],
        )?;
        let question_id =
            Self::first_string_by_pointers(node, &["/id", "/questionId", "/question_id", "/key"]);
        let header = Self::first_string_by_pointers(node, &["/header", "/name", "/label"])
            .unwrap_or_else(|| format!("问题{}", index + 1));
        let options = Self::parse_question_options(node.pointer("/options"));
        let multiple = Self::first_string_by_pointers(
            node,
            &[
                "/multiple",
                "/multi",
                "/allowMultiple",
                "/allow_multiple",
                "/selectMany",
            ],
        )
        .and_then(|raw| {
            if raw.eq_ignore_ascii_case("true") || raw == "1" {
                Some(true)
            } else if raw.eq_ignore_ascii_case("false") || raw == "0" {
                Some(false)
            } else {
                None
            }
        })
        .unwrap_or_else(|| {
            node.pointer("/multiple")
                .and_then(|v| v.as_bool())
                .or_else(|| node.pointer("/allowMultiple").and_then(|v| v.as_bool()))
                .or_else(|| node.pointer("/allow_multiple").and_then(|v| v.as_bool()))
                .or_else(|| node.pointer("/selectMany").and_then(|v| v.as_bool()))
                .unwrap_or(false)
        });
        let custom = Self::first_string_by_pointers(
            node,
            &[
                "/custom",
                "/isOther",
                "/is_other",
                "/allowOther",
                "/allow_other",
            ],
        )
        .and_then(|raw| {
            if raw.eq_ignore_ascii_case("true") || raw == "1" {
                Some(true)
            } else if raw.eq_ignore_ascii_case("false") || raw == "0" {
                Some(false)
            } else {
                None
            }
        })
        .unwrap_or_else(|| {
            node.pointer("/custom")
                .and_then(|v| v.as_bool())
                .or_else(|| node.pointer("/isOther").and_then(|v| v.as_bool()))
                .or_else(|| node.pointer("/is_other").and_then(|v| v.as_bool()))
                .or_else(|| node.pointer("/allowOther").and_then(|v| v.as_bool()))
                .or_else(|| node.pointer("/allow_other").and_then(|v| v.as_bool()))
                .unwrap_or(true)
        });

        Some((
            AiQuestionInfo {
                question: question_text,
                header,
                options,
                multiple,
                custom,
            },
            question_id,
        ))
    }

    fn question_infos_to_json(questions: &[AiQuestionInfo]) -> Value {
        Value::Array(
            questions
                .iter()
                .map(|q| {
                    let options = q
                        .options
                        .iter()
                        .map(|opt| {
                            serde_json::json!({
                                "label": opt.label,
                                "description": opt.description
                            })
                        })
                        .collect::<Vec<_>>();
                    serde_json::json!({
                        "question": q.question,
                        "header": q.header,
                        "options": options,
                        "multiple": q.multiple,
                        "custom": q.custom
                    })
                })
                .collect::<Vec<_>>(),
        )
    }

    fn build_question_prompt_part(request: &AiQuestionRequest) -> (String, AiPart) {
        let message_id = request
            .tool_message_id
            .clone()
            .or_else(|| request.tool_call_id.clone())
            .unwrap_or_else(|| format!("question-{}", request.id.replace(':', "-")));
        // question part 需要稳定且与 message_id 解耦，避免覆盖同消息内已有 text part。
        let part_id = format!("question-part-{}", request.id.replace(':', "-"));
        let tool_call_id = request
            .tool_call_id
            .clone()
            .or_else(|| request.tool_message_id.clone())
            .or_else(|| Some(request.id.clone()));
        let questions = Self::question_infos_to_json(&request.questions);
        let tool_state = serde_json::json!({
            "status": "pending",
            "input": {
                "questions": questions
            },
            "metadata": {
                "request_id": request.id,
                "tool_message_id": message_id
            }
        });
        let part = AiPart {
            id: part_id,
            part_type: "tool".to_string(),
            tool_name: Some("question".to_string()),
            tool_call_id,
            tool_state: Some(tool_state),
            tool_part_metadata: Some(serde_json::json!({
                "request_id": request.id,
                "tool_message_id": message_id
            })),
            ..Default::default()
        };
        (message_id, part)
    }

    fn parse_model_selection(model: Option<AiModelSelection>) -> (Option<String>, Option<String>) {
        match model {
            Some(m) => (Some(m.model_id), Some(m.provider_id)),
            None => (None, None),
        }
    }

    fn parse_collaboration_mode(agent: Option<&str>) -> Option<String> {
        let normalized = agent?.trim().to_lowercase();
        if normalized.is_empty() {
            None
        } else {
            Some(normalized)
        }
    }

    fn is_thread_not_found_error(err: &str) -> bool {
        let normalized = err.to_lowercase();
        normalized.contains("thread not found")
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
        let normalized = Self::canonical_method(raw);
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
            if let Some(mapped) = Self::normalize_tool_status(status) {
                return mapped.to_string();
            }
        }
        Self::normalize_tool_status(default_status)
            .unwrap_or("unknown")
            .to_string()
    }

    fn infer_command_execution_tool_name(item: &Value) -> Option<String> {
        let first_action = item
            .get("commandActions")
            .and_then(|v| v.as_array())
            .and_then(|actions| actions.first())?;
        let action_type = first_action.get("type").and_then(|v| v.as_str())?;
        match Self::canonical_method(action_type).as_str() {
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
                    .and_then(Self::value_to_string)
                    .filter(|text| !text.is_empty())
                {
                    diffs.push(diff);
                }
            }
        }
        if !file_paths.is_empty() {
            metadata.insert("file_paths".to_string(), Value::Array(file_paths));
        }
        // ToolCardView 会展示 metadata.files 为“文件列表”；按产品要求，编辑卡片不显示该区块。
        metadata.remove("files");
        if !diffs.is_empty() && !metadata.contains_key("diff") {
            metadata.insert("diff".to_string(), Value::String(diffs.join("\n\n")));
        }
        Value::Object(metadata)
    }

    fn extract_tool_metadata(tool_type: &str, tool_name: &str, item: &Value) -> Value {
        match tool_type {
            "filechange" => Self::extract_file_change_metadata(item),
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
                | "lsp_diagnostics"
                | "lsp"
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

    /// 将 Codex item type 映射为与前端 ToolCardView 对齐的统一工具名
    fn normalize_codex_tool_name(raw_type: &str, item: &Value) -> String {
        match raw_type {
            "commandexecution" => {
                Self::infer_command_execution_tool_name(item).unwrap_or_else(|| "bash".to_string())
            }
            "filechange" => "write".to_string(),
            "fileread" => "read".to_string(),
            "codeexecution" => "code_execution".to_string(),
            "websearch" => "websearch".to_string(),
            "question" => "question".to_string(),
            other => other.to_string(),
        }
    }

    /// 从 Codex item 中提取结构化工具输入
    fn extract_tool_input(tool_type: &str, tool_name: &str, item: &Value) -> Value {
        match tool_type {
            "commandexecution" => {
                let mut input = serde_json::Map::new();
                if tool_name == "bash" {
                    if let Some(command) = Self::first_field(item, &["command"]) {
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
                } else if tool_name == "list" {
                    // list 卡片内容区仅展示输出结果，输入留空。
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
                } else if let Some(command) = Self::first_field(item, &["command"]) {
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
                let questions = Self::extract_question_nodes(item);
                if questions.is_empty() {
                    Value::Null
                } else {
                    serde_json::json!({ "questions": questions })
                }
            }
            _ => Value::Null,
        }
    }

    /// 从 Codex item 中提取工具输出（返回字符串，与前端 AIToolInvocationState.output: String? 对齐）
    fn extract_tool_output(tool_type: &str, item: &Value) -> Option<String> {
        match tool_type {
            "commandexecution" => Self::first_field(item, &["aggregatedOutput", "output"])
                .and_then(Self::value_to_string),
            "filechange" => {
                let direct = item
                    .get("diff")
                    .and_then(Self::value_to_string)
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
                                .and_then(Self::value_to_string)
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
            "fileread" => item.get("content").and_then(Self::value_to_string),
            "codeexecution" => item.get("output").and_then(Self::value_to_string),
            "websearch" => {
                // results 可能是数组/对象，序列化为 JSON 字符串
                item.get("results").map(|v| v.to_string())
            }
            _ => None,
        }
    }

    fn map_item_to_part(item: &Value, status: &str) -> Option<AiPart> {
        let part_id = item.get("id")?.as_str()?.to_string();
        let kind = item.get("type")?.as_str()?.to_lowercase();
        match kind.as_str() {
            "agentmessage" => Some(AiPart::new_text(
                part_id,
                item.get("text")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
            )),
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
                let tool_name = Self::normalize_codex_tool_name(other, item);
                let tool_call_id = item.get("id").and_then(|v| v.as_str()).map(String::from);
                let output = if tool_name == "read" {
                    None
                } else {
                    Self::extract_tool_output(other, item)
                };
                let input = Self::extract_tool_input(other, &tool_name, item);
                let mut tool_state = serde_json::json!({
                    "status": Self::extract_tool_status(status, item),
                    "input": input,
                    "output": output,
                    "metadata": Self::extract_tool_metadata(other, &tool_name, item),
                });
                if let Some(title) =
                    Self::extract_tool_title(&tool_name, &tool_state["input"], item)
                {
                    tool_state["title"] = Value::String(title);
                }
                if !Self::is_known_tool_for_card(&tool_name) {
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

    fn parse_user_text(item: &Value) -> String {
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

    fn render_turn_plan_update(params: &Value) -> String {
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

    fn map_turn_item_to_message(
        turn_id: &str,
        index: usize,
        item: &Value,
        pending_request_id: Option<&str>,
    ) -> Option<AiMessage> {
        let item_type = item
            .get("type")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_lowercase();
        let item_id = item
            .get("id")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| format!("{}-{}", turn_id, index));
        if item_type == "usermessage" {
            return Some(AiMessage {
                id: item_id.clone(),
                role: "user".to_string(),
                created_at: None,
                parts: vec![AiPart::new_text(
                    format!("{}-text", item_id),
                    Self::parse_user_text(item),
                )],
            });
        }
        Self::map_item_to_part(item, "completed").map(|mut part| {
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

            AiMessage {
                id: item_id,
                role: "assistant".to_string(),
                created_at: None,
                parts: vec![part],
            }
        })
    }

    fn normalize_filename(name: &str) -> String {
        let mut out = String::new();
        for ch in name.chars() {
            if ch.is_ascii_alphanumeric() || ch == '.' || ch == '-' || ch == '_' {
                out.push(ch);
            } else {
                out.push('_');
            }
        }
        if out.is_empty() {
            "image.bin".to_string()
        } else {
            out
        }
    }

    fn build_question_from_request(
        method: &str,
        request_id: &str,
        params: &Value,
    ) -> Option<(AiQuestionRequest, Vec<String>)> {
        let session_id = Self::first_string_by_pointers(
            params,
            &["/threadId", "/thread_id", "/sessionId", "/session_id"],
        )?;
        let item_id = Self::first_string_by_pointers(
            params,
            &[
                "/itemId",
                "/item_id",
                "/item/id",
                "/toolCall/toolCallId",
                "/tool_call/tool_call_id",
            ],
        );

        if Self::method_in(
            method,
            &[
                "item/commandExecution/requestApproval",
                "item/command_execution/request_approval",
            ],
        ) {
            let command = params
                .get("command")
                .and_then(|v| v.as_str())
                .unwrap_or("command");
            let q = AiQuestionInfo {
                question: format!("允许执行命令？\n{}", command),
                header: "Codex Approval".to_string(),
                options: vec![
                    AiQuestionOption {
                        label: "accept".to_string(),
                        description: "允许本次执行".to_string(),
                    },
                    AiQuestionOption {
                        label: "decline".to_string(),
                        description: "拒绝本次执行".to_string(),
                    },
                    AiQuestionOption {
                        label: "cancel".to_string(),
                        description: "拒绝并中断本轮".to_string(),
                    },
                ],
                multiple: false,
                custom: false,
            };
            Some((
                AiQuestionRequest {
                    id: request_id.to_string(),
                    session_id,
                    questions: vec![q],
                    tool_message_id: item_id.clone(),
                    tool_call_id: item_id,
                },
                vec!["decision".to_string()],
            ))
        } else if Self::method_in(
            method,
            &[
                "item/fileChange/requestApproval",
                "item/file_change/request_approval",
            ],
        ) {
            let q = AiQuestionInfo {
                question: "允许应用文件修改？".to_string(),
                header: "Codex Approval".to_string(),
                options: vec![
                    AiQuestionOption {
                        label: "accept".to_string(),
                        description: "允许本次修改".to_string(),
                    },
                    AiQuestionOption {
                        label: "decline".to_string(),
                        description: "拒绝本次修改".to_string(),
                    },
                    AiQuestionOption {
                        label: "cancel".to_string(),
                        description: "拒绝并中断本轮".to_string(),
                    },
                ],
                multiple: false,
                custom: false,
            };
            Some((
                AiQuestionRequest {
                    id: request_id.to_string(),
                    session_id,
                    questions: vec![q],
                    tool_message_id: item_id.clone(),
                    tool_call_id: item_id,
                },
                vec!["decision".to_string()],
            ))
        } else if Self::method_in(
            method,
            &[
                "item/tool/requestUserInput",
                "item/tool/request_user_input",
                "tool/requestUserInput",
                "tool/request_user_input",
            ],
        ) {
            let questions = Self::extract_question_nodes(params);
            let mut mapped = Vec::new();
            let mut ids = Vec::new();
            for (idx, q) in questions.iter().enumerate() {
                let Some((question, question_id)) = Self::parse_question_info(q, idx) else {
                    continue;
                };
                if let Some(question_id) = question_id {
                    ids.push(question_id);
                } else {
                    ids.push(format!("question_{}", idx + 1));
                }
                mapped.push(question);
            }

            if mapped.is_empty() {
                let fallback = Self::first_string_by_pointers(
                    params,
                    &["/prompt", "/question", "/message", "/title"],
                )
                .unwrap_or_else(|| "请提供输入".to_string());
                mapped.push(AiQuestionInfo {
                    question: fallback,
                    header: "Question".to_string(),
                    options: Vec::new(),
                    multiple: false,
                    custom: true,
                });
                if ids.is_empty() {
                    ids.push("question_1".to_string());
                }
            }
            Some((
                AiQuestionRequest {
                    id: request_id.to_string(),
                    session_id,
                    questions: mapped,
                    tool_message_id: item_id.clone(),
                    tool_call_id: item_id,
                },
                ids,
            ))
        } else {
            None
        }
    }

    async fn build_turn_stream(
        &self,
        session_id: String,
        turn_id: String,
        original_text: String,
    ) -> Result<AiEventStream, String> {
        let (tx, rx) = mpsc::unbounded_channel::<Result<AiEvent, String>>();
        let mut notifications = self.client.subscribe_notifications();
        let mut requests = self.client.subscribe_requests();
        let approvals = self.pending_approvals.clone();
        let active_turns = self.active_turns.clone();

        let user_message_id = format!("codex-user-{}-{}", session_id, turn_id);
        let _ = tx.send(Ok(AiEvent::MessageUpdated {
            message_id: user_message_id.clone(),
            role: "user".to_string(),
        }));
        let _ = tx.send(Ok(AiEvent::PartUpdated {
            message_id: user_message_id.clone(),
            part: AiPart::new_text(format!("{}-text", user_message_id), original_text),
        }));

        tokio::spawn(async move {
            let mut known_assistant_messages = HashSet::<String>::new();
            loop {
                tokio::select! {
                    recv = notifications.recv() => {
                        match recv {
                            Ok(event) => {
                                let params = event.params.unwrap_or(Value::Null);
                                let thread_id = Self::first_string_by_pointers(
                                    &params,
                                    &["/threadId", "/thread_id", "/sessionId", "/session_id"],
                                )
                                .unwrap_or_default();
                                let event_turn_id = Self::first_string_by_pointers(
                                    &params,
                                    &["/turnId", "/turn_id"],
                                )
                                .unwrap_or_default();
                                if thread_id != session_id || (!event_turn_id.is_empty() && event_turn_id != turn_id) {
                                    continue;
                                }
                                match event.method.as_str() {
                                    "item/agentMessage/delta" => {
                                        let item_id = params.get("itemId").and_then(|v| v.as_str()).unwrap_or("");
                                        if item_id.is_empty() {
                                            continue;
                                        }
                                        if !known_assistant_messages.contains(item_id) {
                                            known_assistant_messages.insert(item_id.to_string());
                                            let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                message_id: item_id.to_string(),
                                                role: "assistant".to_string(),
                                            }));
                                        }
                                        if let Some(delta) = params.get("delta").and_then(|v| v.as_str()) {
                                            let _ = tx.send(Ok(AiEvent::PartDelta {
                                                message_id: item_id.to_string(),
                                                part_id: item_id.to_string(),
                                                part_type: "text".to_string(),
                                                field: "text".to_string(),
                                                delta: delta.to_string(),
                                            }));
                                        }
                                    }
                                    "item/reasoning/textDelta" | "item/reasoning/summaryTextDelta" => {
                                        let item_id = params.get("itemId").and_then(|v| v.as_str()).unwrap_or("");
                                        if item_id.is_empty() {
                                            continue;
                                        }
                                        if !known_assistant_messages.contains(item_id) {
                                            known_assistant_messages.insert(item_id.to_string());
                                            let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                message_id: item_id.to_string(),
                                                role: "assistant".to_string(),
                                            }));
                                        }
                                        if let Some(delta) = params.get("delta").and_then(|v| v.as_str()) {
                                            let _ = tx.send(Ok(AiEvent::PartDelta {
                                                message_id: item_id.to_string(),
                                                part_id: item_id.to_string(),
                                                part_type: "reasoning".to_string(),
                                                field: "text".to_string(),
                                                delta: delta.to_string(),
                                            }));
                                        }
                                    }
                                    "item/plan/delta" => {
                                        let item_id = params
                                            .get("itemId")
                                            .or_else(|| params.get("item_id"))
                                            .and_then(|v| v.as_str())
                                            .unwrap_or("");
                                        if item_id.is_empty() {
                                            continue;
                                        }
                                        if !known_assistant_messages.contains(item_id) {
                                            known_assistant_messages.insert(item_id.to_string());
                                            let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                message_id: item_id.to_string(),
                                                role: "assistant".to_string(),
                                            }));
                                        }
                                        if let Some(delta) = params.get("delta").and_then(|v| v.as_str()) {
                                            let _ = tx.send(Ok(AiEvent::PartDelta {
                                                message_id: item_id.to_string(),
                                                part_id: item_id.to_string(),
                                                part_type: "text".to_string(),
                                                field: "text".to_string(),
                                                delta: delta.to_string(),
                                            }));
                                        }
                                    }
                                    "turn/plan/updated" => {
                                        let plan_turn_id = params
                                            .get("turnId")
                                            .or_else(|| params.get("turn_id"))
                                            .and_then(|v| v.as_str())
                                            .unwrap_or(turn_id.as_str());
                                        let message_id = format!("codex-plan-{}", plan_turn_id);
                                        let part_id = format!("{}-summary", message_id);
                                        if !known_assistant_messages.contains(&message_id) {
                                            known_assistant_messages.insert(message_id.clone());
                                            let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                message_id: message_id.clone(),
                                                role: "assistant".to_string(),
                                            }));
                                        }
                                        let _ = tx.send(Ok(AiEvent::PartUpdated {
                                            message_id,
                                            part: AiPart::new_text(
                                                part_id,
                                                CodexAppServerAgent::render_turn_plan_update(&params),
                                            ),
                                        }));
                                    }
                                    "item/started" | "item/completed" => {
                                        let Some(item) = params.get("item") else {
                                            continue;
                                        };
                                        let item_type = item
                                            .get("type")
                                            .and_then(|v| v.as_str())
                                            .unwrap_or("")
                                            .to_lowercase();
                                        if item_type == "usermessage" {
                                            continue;
                                        }
                                        let Some(message_id) = item.get("id").and_then(|v| v.as_str()) else {
                                            continue;
                                        };
                                        if !known_assistant_messages.contains(message_id) {
                                            known_assistant_messages.insert(message_id.to_string());
                                            let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                                message_id: message_id.to_string(),
                                                role: "assistant".to_string(),
                                            }));
                                        }
                                        let status = if event.method == "item/started" {
                                            "running"
                                        } else {
                                            "completed"
                                        };
                                        if let Some(part) = CodexAppServerAgent::map_item_to_part(item, status) {
                                            let _ = tx.send(Ok(AiEvent::PartUpdated {
                                                message_id: message_id.to_string(),
                                                part,
                                            }));
                                        }
                                    }
                                    "error" => {
                                        let message = params
                                            .get("error")
                                            .and_then(|v| v.get("message"))
                                            .and_then(|v| v.as_str())
                                            .unwrap_or("Codex app-server error");
                                        if Self::should_ignore_error_notification(&params) {
                                            info!(
                                                "Codex transient stream warning ignored: session_id={}, turn_id={}, message={}",
                                                session_id, turn_id, message
                                            );
                                            continue;
                                        }
                                        let _ = tx.send(Ok(AiEvent::Error {
                                            message: message.to_string(),
                                        }));
                                    }
                                    "turn/completed" => {
                                        let status = params
                                            .get("turn")
                                            .and_then(|v| v.get("status"))
                                            .and_then(|v| v.as_str())
                                            .unwrap_or("");
                                        if status.eq_ignore_ascii_case("failed") {
                                            let message = params
                                                .get("turn")
                                                .and_then(|v| v.get("error"))
                                                .and_then(|v| v.get("message"))
                                                .and_then(|v| v.as_str())
                                                .unwrap_or("Turn failed");
                                            let _ = tx.send(Ok(AiEvent::Error {
                                                message: message.to_string(),
                                            }));
                                        }
                                        let _ = tx.send(Ok(AiEvent::Done));
                                        active_turns.lock().await.remove(&session_id);
                                        break;
                                    }
                                    _ => {}
                                }
                            }
                            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                            Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                                let _ = tx.send(Err("Codex notification stream closed".to_string()));
                                active_turns.lock().await.remove(&session_id);
                                break;
                            }
                        }
                    }
                    recv = requests.recv() => {
                        match recv {
                            Ok(req) => {
                                let params = req.params.unwrap_or(Value::Null);
                                let thread_id = CodexAppServerAgent::first_string_by_pointers(
                                    &params,
                                    &["/threadId", "/thread_id", "/sessionId", "/session_id"],
                                )
                                .unwrap_or_default();
                                let request_turn_id = CodexAppServerAgent::first_string_by_pointers(
                                    &params,
                                    &["/turnId", "/turn_id"],
                                )
                                .unwrap_or_default();
                                if thread_id != session_id {
                                    continue;
                                }
                                if !request_turn_id.is_empty()
                                    && request_turn_id != turn_id
                                    && !CodexAppServerAgent::method_in(
                                        req.method.as_str(),
                                        &[
                                            "item/tool/requestUserInput",
                                            "item/tool/request_user_input",
                                            "tool/requestUserInput",
                                            "tool/request_user_input",
                                            "item/commandExecution/requestApproval",
                                            "item/command_execution/request_approval",
                                            "item/fileChange/requestApproval",
                                            "item/file_change/request_approval",
                                        ],
                                    )
                                {
                                    continue;
                                }
                                let request_key = CodexAppServerAgent::request_id_key(&req.id);
                                debug!(
                                    "Codex server request: method={}, request_key={}, thread_id={}, turn_id={}, params={}",
                                    req.method,
                                    request_key,
                                    thread_id,
                                    request_turn_id,
                                    params
                                );
                                if let Some((question, question_ids)) = CodexAppServerAgent::build_question_from_request(&req.method, &request_key, &params) {
                                    let (question_message_id, question_part) =
                                        CodexAppServerAgent::build_question_prompt_part(&question);
                                    let _ = tx.send(Ok(AiEvent::MessageUpdated {
                                        message_id: question_message_id.clone(),
                                        role: "assistant".to_string(),
                                    }));
                                    let _ = tx.send(Ok(AiEvent::PartUpdated {
                                        message_id: question_message_id.clone(),
                                        part: question_part,
                                    }));
                                    let pending = PendingApproval {
                                        id: req.id,
                                        method: req.method.clone(),
                                        question_ids,
                                        session_id: question.session_id.clone(),
                                        tool_message_id: Some(question_message_id),
                                    };
                                    approvals.lock().await.insert(
                                        request_key.clone(),
                                        pending,
                                    );
                                    let _ = tx.send(Ok(AiEvent::QuestionAsked { request: question }));
                                } else {
                                    if CodexAppServerAgent::method_in(
                                        req.method.as_str(),
                                        &[
                                            "item/tool/requestUserInput",
                                            "item/tool/request_user_input",
                                            "tool/requestUserInput",
                                            "tool/request_user_input",
                                        ],
                                    ) {
                                        warn!(
                                            "Codex request_user_input parse failed: request_key={}, params={}",
                                            request_key, params
                                        );
                                    }
                                    warn!(
                                        "Codex approval request ignored: method={}, request_key={}",
                                        req.method, request_key
                                    );
                                }
                            }
                            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                            Err(tokio::sync::broadcast::error::RecvError::Closed) => {}
                        }
                    }
                }
            }
        });

        Ok(Box::pin(UnboundedReceiverStream::new(rx)))
    }

    fn provider_from_models(models: Vec<CodexModelInfo>) -> Vec<AiProviderInfo> {
        let mapped = models
            .into_iter()
            .map(|m| AiModelInfo {
                id: m.id.clone(),
                name: if m.display_name.is_empty() {
                    m.model.clone()
                } else {
                    m.display_name.clone()
                },
                provider_id: "codex".to_string(),
                supports_image_input: m
                    .input_modalities
                    .iter()
                    .any(|modality| modality.eq_ignore_ascii_case("image")),
            })
            .collect::<Vec<_>>();
        vec![AiProviderInfo {
            id: "codex".to_string(),
            name: "Codex".to_string(),
            models: mapped,
        }]
    }
}

#[async_trait]
impl AiAgent for CodexAppServerAgent {
    async fn start(&self) -> Result<(), String> {
        self.client.ensure_started().await
    }

    async fn stop(&self) -> Result<(), String> {
        // 由 manager 生命周期管理，当前无需显式 stop。
        Ok(())
    }

    async fn create_session(&self, directory: &str, title: &str) -> Result<AiSession, String> {
        self.client.ensure_started().await?;
        let thread = self.client.thread_start(directory, title).await?;
        Ok(AiSession {
            id: thread.id,
            title: title.to_string(),
            updated_at: thread.updated_at_secs.saturating_mul(1000),
        })
    }

    async fn send_message(
        &self,
        directory: &str,
        session_id: &str,
        message: &str,
        file_refs: Option<Vec<String>>,
        image_parts: Option<Vec<AiImagePart>>,
        model: Option<AiModelSelection>,
        agent: Option<String>,
    ) -> Result<AiEventStream, String> {
        self.client.ensure_started().await?;

        let mut input = vec![CodexAppServerClient::text_input(message)];
        if let Some(files) = file_refs {
            for file in files {
                let absolute = format!("{}/{}", directory.trim_end_matches('/'), file);
                let name = PathBuf::from(&file)
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("file")
                    .to_string();
                input.push(CodexAppServerClient::mention_input(&name, &absolute));
            }
        }
        if let Some(images) = image_parts {
            let temp_dir = std::env::temp_dir().join("tidyflow-codex-images");
            tokio::fs::create_dir_all(&temp_dir)
                .await
                .map_err(|e| format!("Failed to create Codex image temp dir: {}", e))?;
            for img in images {
                let filename = format!(
                    "{}-{}",
                    Uuid::new_v4(),
                    Self::normalize_filename(&img.filename)
                );
                let path = temp_dir.join(filename);
                tokio::fs::write(&path, &img.data)
                    .await
                    .map_err(|e| format!("Failed to write image temp file: {}", e))?;
                input.push(CodexAppServerClient::local_image_input(path));
            }
        }

        let (model_id, model_provider) = Self::parse_model_selection(model);
        let collaboration_mode = Self::parse_collaboration_mode(agent.as_deref());
        let outbound_hint = AiSessionSelectionHint {
            agent: collaboration_mode.clone(),
            model_provider_id: model_provider.clone(),
            model_id: model_id.clone(),
        };
        let turn_id = match self
            .client
            .turn_start(
                session_id,
                input.clone(),
                model_id.clone(),
                model_provider.clone(),
                collaboration_mode.clone(),
            )
            .await
        {
            Ok(turn_id) => turn_id,
            Err(err) if Self::is_thread_not_found_error(&err) => {
                let resume = self.client.thread_resume(directory, session_id).await?;
                if let Some(hint) = Self::selection_hint_from_thread_payload(&resume) {
                    self.selection_hints
                        .lock()
                        .await
                        .insert(session_id.to_string(), hint.clone());
                    info!(
                        "Codex session hint from thread/resume: session_id={}, agent={:?}, model_provider_id={:?}, model_id={:?}",
                        session_id, hint.agent, hint.model_provider_id, hint.model_id
                    );
                }
                self.client
                    .turn_start(
                        session_id,
                        input,
                        model_id,
                        model_provider,
                        collaboration_mode,
                    )
                    .await?
            }
            Err(err) => return Err(err),
        };
        if outbound_hint.agent.is_some()
            || outbound_hint.model_provider_id.is_some()
            || outbound_hint.model_id.is_some()
        {
            self.selection_hints
                .lock()
                .await
                .insert(session_id.to_string(), outbound_hint);
        }
        self.active_turns
            .lock()
            .await
            .insert(session_id.to_string(), turn_id.clone());

        self.build_turn_stream(session_id.to_string(), turn_id, message.to_string())
            .await
    }

    async fn list_sessions(&self, directory: &str) -> Result<Vec<AiSession>, String> {
        self.client.ensure_started().await?;
        let sessions = self.client.thread_list(directory, 500).await?;
        Ok(sessions
            .into_iter()
            .map(|s| AiSession {
                id: s.id,
                title: if s.preview.trim().is_empty() {
                    "New Chat".to_string()
                } else {
                    s.preview
                },
                updated_at: s.updated_at_secs.saturating_mul(1000),
            })
            .collect())
    }

    async fn delete_session(&self, _directory: &str, session_id: &str) -> Result<(), String> {
        self.client.thread_archive(session_id).await
    }

    async fn list_messages(
        &self,
        directory: &str,
        session_id: &str,
        limit: Option<u32>,
    ) -> Result<Vec<AiMessage>, String> {
        self.client.ensure_started().await?;
        let response = self.client.thread_read(session_id, true).await?;
        if let Some(hint) = Self::selection_hint_from_thread_payload(&response) {
            self.selection_hints
                .lock()
                .await
                .insert(session_id.to_string(), hint.clone());
            info!(
                "Codex session hint from thread/read(history): session_id={}, agent={:?}, model_provider_id={:?}, model_id={:?}",
                session_id, hint.agent, hint.model_provider_id, hint.model_id
            );
        } else {
            debug!(
                "Codex thread/read(history) returned no selection hint: directory={}, session_id={}",
                directory, session_id
            );
        }
        let turns = response
            .get("thread")
            .and_then(|v| v.get("turns"))
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();

        let pending_request_id_by_item_id: HashMap<String, String> = self
            .pending_approvals
            .lock()
            .await
            .iter()
            .filter_map(|(request_id, pending)| {
                if pending.session_id != session_id {
                    return None;
                }
                let tool_message_id = pending.tool_message_id.clone()?;
                Some((tool_message_id, request_id.clone()))
            })
            .collect();

        let mut messages = Vec::new();
        for turn in turns {
            let turn_id = turn
                .get("id")
                .and_then(|v| v.as_str())
                .unwrap_or("turn")
                .to_string();
            let items = turn
                .get("items")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default();
            for (idx, item) in items.iter().enumerate() {
                let item_id = item
                    .get("id")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| format!("{}-{}", turn_id, idx));
                let pending_request_id = pending_request_id_by_item_id
                    .get(&item_id)
                    .map(|s| s.as_str());
                if let Some(msg) =
                    Self::map_turn_item_to_message(&turn_id, idx, item, pending_request_id)
                {
                    messages.push(msg);
                }
            }
        }
        if let Some(limit) = limit {
            let keep = limit as usize;
            if keep == 0 {
                messages.clear();
            } else if messages.len() > keep {
                messages = messages.split_off(messages.len() - keep);
            }
        }
        Ok(messages)
    }

    async fn session_selection_hint(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<Option<AiSessionSelectionHint>, String> {
        if let Some(hint) = self.selection_hints.lock().await.get(session_id).cloned() {
            debug!(
                "Codex session hint cache hit: session_id={}, agent={:?}, model_provider_id={:?}, model_id={:?}",
                session_id, hint.agent, hint.model_provider_id, hint.model_id
            );
            return Ok(Some(hint));
        }
        self.client.ensure_started().await?;
        match self.client.thread_read(session_id, false).await {
            Ok(read_response) => {
                let hint = Self::selection_hint_from_thread_payload(&read_response);
                if let Some(ref value) = hint {
                    self.selection_hints
                        .lock()
                        .await
                        .insert(session_id.to_string(), value.clone());
                    info!(
                        "Codex session hint resolved by thread/read: session_id={}, agent={:?}, model_provider_id={:?}, model_id={:?}",
                        session_id, value.agent, value.model_provider_id, value.model_id
                    );
                } else {
                    debug!(
                        "Codex thread/read returned no selection hint: directory={}, session_id={}",
                        directory, session_id
                    );
                }
                Ok(hint)
            }
            Err(err) => {
                warn!(
                    "Codex thread/read for selection hint failed: directory={}, session_id={}, error={}",
                    directory, session_id, err
                );
                Ok(None)
            }
        }
    }

    async fn abort_session(&self, _directory: &str, session_id: &str) -> Result<(), String> {
        let turn_id = self.active_turns.lock().await.get(session_id).cloned();
        if let Some(turn_id) = turn_id {
            self.client.turn_interrupt(session_id, &turn_id).await?;
        }
        Ok(())
    }

    async fn dispose_instance(&self, _directory: &str) -> Result<(), String> {
        Ok(())
    }

    async fn get_session_status(
        &self,
        _directory: &str,
        session_id: &str,
    ) -> Result<AiSessionStatus, String> {
        let is_busy = self.active_turns.lock().await.contains_key(session_id);
        Ok(if is_busy {
            AiSessionStatus::Busy
        } else {
            AiSessionStatus::Idle
        })
    }

    async fn list_providers(&self, _directory: &str) -> Result<Vec<AiProviderInfo>, String> {
        self.client.ensure_started().await?;
        let models = self.client.model_list().await?;
        Ok(Self::provider_from_models(models))
    }

    async fn list_agents(&self, directory: &str) -> Result<Vec<AiAgentInfo>, String> {
        let providers = self.list_providers(directory).await?;
        let default_model_id = providers
            .first()
            .and_then(|p| {
                p.models
                    .iter()
                    .find(|m| m.id == "default")
                    .or_else(|| p.models.first())
            })
            .map(|m| m.id.clone());

        let agents = self.client.agent_list().await?;
        Ok(agents
            .into_iter()
            .map(|agent| AiAgentInfo {
                name: agent.name.clone(),
                description: Some(format!("Codex {} mode", agent.name)),
                mode: Some("primary".to_string()),
                color: Some(if agent.collaboration_mode == "plan" {
                    "orange".to_string()
                } else {
                    "blue".to_string()
                }),
                default_provider_id: Some("codex".to_string()),
                default_model_id: default_model_id.clone(),
            })
            .collect())
    }

    async fn list_slash_commands(&self, _directory: &str) -> Result<Vec<AiSlashCommand>, String> {
        Ok(vec![AiSlashCommand {
            name: "new".to_string(),
            description: "新建会话".to_string(),
            action: "client".to_string(),
        }])
    }

    async fn reply_question(
        &self,
        _directory: &str,
        request_id: &str,
        answers: Vec<Vec<String>>,
    ) -> Result<(), String> {
        let key = request_id.to_string();
        let pending = self
            .pending_approvals
            .lock()
            .await
            .remove(&key)
            .ok_or_else(|| format!("Unknown Codex approval request: {}", request_id))?;

        let response = if Self::method_in(
            pending.method.as_str(),
            &[
                "item/commandExecution/requestApproval",
                "item/command_execution/request_approval",
            ],
        ) {
            let decision = answers
                .first()
                .and_then(|a| a.first())
                .map(|s| s.to_lowercase())
                .unwrap_or_else(|| "accept".to_string());
            serde_json::json!({ "decision": decision })
        } else if Self::method_in(
            pending.method.as_str(),
            &[
                "item/fileChange/requestApproval",
                "item/file_change/request_approval",
            ],
        ) {
            let decision = answers
                .first()
                .and_then(|a| a.first())
                .map(|s| s.to_lowercase())
                .unwrap_or_else(|| "accept".to_string());
            serde_json::json!({ "decision": decision })
        } else if Self::method_in(
            pending.method.as_str(),
            &[
                "item/tool/requestUserInput",
                "item/tool/request_user_input",
                "tool/requestUserInput",
                "tool/request_user_input",
            ],
        ) {
            let mut answer_map = serde_json::Map::new();
            for (idx, qid) in pending.question_ids.iter().enumerate() {
                let ans = answers.get(idx).cloned().unwrap_or_default();
                answer_map.insert(qid.clone(), serde_json::json!({ "answers": ans }));
            }
            if answer_map.is_empty() {
                serde_json::json!({ "answers": answers })
            } else {
                serde_json::json!({ "answers": answer_map })
            }
        } else {
            warn!(
                "Unsupported Codex request method in reply_question: {}",
                pending.method
            );
            serde_json::json!({})
        };
        self.client
            .send_approval_response(pending.id, response)
            .await
    }

    async fn reject_question(&self, _directory: &str, request_id: &str) -> Result<(), String> {
        let key = request_id.to_string();
        let pending = self
            .pending_approvals
            .lock()
            .await
            .remove(&key)
            .ok_or_else(|| format!("Unknown Codex approval request: {}", request_id))?;

        let response = if Self::method_in(
            pending.method.as_str(),
            &[
                "item/commandExecution/requestApproval",
                "item/command_execution/request_approval",
                "item/fileChange/requestApproval",
                "item/file_change/request_approval",
            ],
        ) {
            serde_json::json!({ "decision": "cancel" })
        } else if Self::method_in(
            pending.method.as_str(),
            &[
                "item/tool/requestUserInput",
                "item/tool/request_user_input",
                "tool/requestUserInput",
                "tool/request_user_input",
            ],
        ) {
            serde_json::json!({ "answers": {} })
        } else {
            serde_json::json!({})
        };
        self.client
            .send_approval_response(pending.id, response)
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::CodexAppServerAgent;
    use crate::ai::{AiQuestionInfo, AiQuestionRequest};

    #[test]
    fn build_question_from_request_supports_snake_case_user_input() {
        let params = serde_json::json!({
            "thread_id": "thread-1",
            "item": { "id": "item-42" },
            "request": {
                "questions": [
                    {
                        "id": "math",
                        "question": "1+1 等于几？",
                        "header": "测试",
                        "options": [
                            { "label": "1" },
                            { "label": "2", "description": "正确答案" }
                        ],
                        "allow_other": false
                    }
                ]
            }
        });

        let (request, ids) = CodexAppServerAgent::build_question_from_request(
            "item/tool/request_user_input",
            "n:99",
            &params,
        )
        .expect("should parse question request");

        assert_eq!(request.session_id, "thread-1");
        assert_eq!(request.tool_message_id.as_deref(), Some("item-42"));
        assert_eq!(ids, vec!["math".to_string()]);
        assert_eq!(request.questions.len(), 1);
        assert_eq!(request.questions[0].question, "1+1 等于几？");
        assert_eq!(request.questions[0].options.len(), 2);
        assert!(!request.questions[0].custom);
    }

    #[test]
    fn build_question_from_request_supports_app_server_v2_request_user_input_shape() {
        let params = serde_json::json!({
            "threadId": "thread-v2",
            "turnId": "turn-v2",
            "itemId": "call-v2",
            "questions": [
                {
                    "id": "confirm_path",
                    "header": "确认路径",
                    "question": "是否继续？",
                    "isOther": true,
                    "isSecret": false,
                    "options": [
                        { "label": "继续", "description": "按当前路径继续" },
                        { "label": "取消", "description": "停止当前流程" }
                    ]
                }
            ]
        });

        let (request, ids) = CodexAppServerAgent::build_question_from_request(
            "item/tool/requestUserInput",
            "n:12",
            &params,
        )
        .expect("should parse app-server v2 requestUserInput");

        assert_eq!(request.session_id, "thread-v2");
        assert_eq!(request.tool_message_id.as_deref(), Some("call-v2"));
        assert_eq!(request.tool_call_id.as_deref(), Some("call-v2"));
        assert_eq!(ids, vec!["confirm_path".to_string()]);
        assert_eq!(request.questions.len(), 1);
        assert_eq!(request.questions[0].header, "确认路径");
        assert_eq!(request.questions[0].question, "是否继续？");
        assert_eq!(request.questions[0].options.len(), 2);
        assert!(request.questions[0].custom);
    }

    #[test]
    fn build_question_from_request_supports_snake_case_approval() {
        let params = serde_json::json!({
            "thread_id": "thread-2",
            "command": "echo hello"
        });
        let (request, ids) = CodexAppServerAgent::build_question_from_request(
            "item/command_execution/request_approval",
            "n:7",
            &params,
        )
        .expect("should parse approval request");

        assert_eq!(request.session_id, "thread-2");
        assert_eq!(ids, vec!["decision".to_string()]);
        assert_eq!(request.questions.len(), 1);
    }

    #[test]
    fn build_question_prompt_part_uses_stable_part_id_without_overwriting_message_id() {
        let request = AiQuestionRequest {
            id: "n:123".to_string(),
            session_id: "thread-3".to_string(),
            questions: vec![AiQuestionInfo {
                question: "允许执行命令？".to_string(),
                header: "Codex Approval".to_string(),
                options: vec![],
                multiple: false,
                custom: false,
            }],
            tool_message_id: Some("item-approval-1".to_string()),
            tool_call_id: Some("item-approval-1".to_string()),
        };

        let (message_id, part) = CodexAppServerAgent::build_question_prompt_part(&request);
        assert_eq!(message_id, "item-approval-1");
        assert_eq!(part.part_type, "tool");
        assert_eq!(part.id, "question-part-n-123");
        assert_ne!(part.id, message_id);
    }

    #[test]
    fn should_ignore_error_notification_rejects_without_will_retry() {
        let params = serde_json::json!({
            "error": { "message": "Reconnecting... 1/5" }
        });
        assert!(!CodexAppServerAgent::should_ignore_error_notification(
            &params
        ));
    }

    #[test]
    fn should_ignore_error_notification_when_will_retry_true() {
        let params = serde_json::json!({
            "error": { "message": "Connection dropped" },
            "willRetry": true
        });
        assert!(CodexAppServerAgent::should_ignore_error_notification(
            &params
        ));
    }

    #[test]
    fn map_item_to_part_maps_command_execution_read_action() {
        let item = serde_json::json!({
            "id": "item-read-1",
            "type": "commandExecution",
            "command": "/bin/zsh -lc \"sed -n '1p' README.md\"",
            "cwd": "/tmp/demo",
            "status": "completed",
            "aggregatedOutput": "hello\n",
            "commandActions": [
                { "type": "read", "path": "README.md", "name": "README.md", "command": "sed -n '1p' README.md" }
            ]
        });

        let part =
            CodexAppServerAgent::map_item_to_part(&item, "completed").expect("map should succeed");
        assert_eq!(part.tool_name.as_deref(), Some("read"));

        let state = part.tool_state.expect("tool_state should exist");
        assert_eq!(
            state.get("status").and_then(|v| v.as_str()),
            Some("completed")
        );
        assert_eq!(
            state.pointer("/input/path").and_then(|v| v.as_str()),
            Some("README.md")
        );
        assert!(state.get("output").map(|v| v.is_null()).unwrap_or(true));
        assert_eq!(
            state.get("title").and_then(|v| v.as_str()),
            Some("read(README.md)")
        );
    }

    #[test]
    fn map_item_to_part_marks_plan_source_metadata() {
        let item = serde_json::json!({
            "id": "item-plan-1",
            "type": "plan",
            "text": "- 第一步\n- 第二步"
        });

        let part =
            CodexAppServerAgent::map_item_to_part(&item, "completed").expect("map should succeed");
        assert_eq!(part.part_type, "text");
        assert_eq!(part.text.as_deref(), Some("- 第一步\n- 第二步"));
        assert_eq!(
            part.source
                .as_ref()
                .and_then(|v| v.get("vendor"))
                .and_then(|v| v.as_str()),
            Some("codex")
        );
        assert_eq!(
            part.source
                .as_ref()
                .and_then(|v| v.get("item_type"))
                .and_then(|v| v.as_str()),
            Some("plan")
        );
    }

    #[test]
    fn map_item_to_part_maps_file_change_changes_to_diff_and_files() {
        let item = serde_json::json!({
            "id": "item-change-1",
            "type": "fileChange",
            "status": "failed",
            "changes": [
                { "path": "a.txt", "kind": "update", "diff": "@@ -1 +1 @@\n-a\n+b\n" },
                { "path": "b.txt", "kind": "create", "diff": "@@ -0,0 +1 @@\n+new\n" }
            ]
        });

        let part =
            CodexAppServerAgent::map_item_to_part(&item, "completed").expect("map should succeed");
        assert_eq!(part.tool_name.as_deref(), Some("write"));

        let state = part.tool_state.expect("tool_state should exist");
        assert_eq!(state.get("status").and_then(|v| v.as_str()), Some("error"));
        assert_eq!(
            state.pointer("/input/path").and_then(|v| v.as_str()),
            Some("a.txt")
        );
        assert_eq!(
            state
                .pointer("/metadata/file_paths/0")
                .and_then(|v| v.as_str()),
            Some("a.txt")
        );
        assert!(state.pointer("/metadata/files").is_none());
        assert!(state
            .pointer("/metadata/diff")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .contains("@@ -1 +1 @@"));
    }

    #[test]
    fn map_item_to_part_maps_command_execution_bash_with_minimal_input() {
        let item = serde_json::json!({
            "id": "item-bash-1",
            "type": "commandExecution",
            "status": "completed",
            "command": "/bin/zsh -lc 'git status --short'",
            "cwd": "/tmp/demo",
            "processId": "93504",
            "commandActions": [
                { "type": "unknown", "command": "git status --short" }
            ],
            "aggregatedOutput": "M core/src/ai/codex_adapter.rs\n"
        });

        let part =
            CodexAppServerAgent::map_item_to_part(&item, "completed").expect("map should succeed");
        assert_eq!(part.tool_name.as_deref(), Some("bash"));
        let state = part.tool_state.expect("tool_state should exist");
        assert_eq!(
            state.pointer("/input/command").and_then(|v| v.as_str()),
            Some("/bin/zsh -lc 'git status --short'")
        );
        assert!(state.pointer("/input/cwd").is_none());
        assert!(state.pointer("/input/process_id").is_none());
        assert!(state.pointer("/input/commandActions").is_none());
    }

    #[test]
    fn map_item_to_part_maps_list_with_title_and_output_only() {
        let item = serde_json::json!({
            "id": "item-list-1",
            "type": "commandExecution",
            "status": "completed",
            "command": "/bin/zsh -lc \"ls -la app/TidyFlow | sed -n '1,220p'\"",
            "cwd": "/tmp/demo",
            "commandActions": [
                { "type": "listFiles", "command": "ls -la app/TidyFlow", "path": "app/TidyFlow" }
            ],
            "aggregatedOutput": "total 72\n-rw-r--r--  AppConfig.swift\n"
        });

        let part =
            CodexAppServerAgent::map_item_to_part(&item, "completed").expect("map should succeed");
        assert_eq!(part.tool_name.as_deref(), Some("list"));
        let state = part.tool_state.expect("tool_state should exist");
        assert_eq!(
            state.get("title").and_then(|v| v.as_str()),
            Some("list(/bin/zsh -lc \"ls -la app/TidyFlow | sed -n '1,220p'\")")
        );
        assert_eq!(
            state.get("output").and_then(|v| v.as_str()),
            Some("total 72\n-rw-r--r--  AppConfig.swift\n")
        );
        assert!(state.pointer("/input/path").is_none());
        assert!(state.pointer("/metadata/cwd").is_none());
        assert_eq!(
            state
                .pointer("/metadata")
                .and_then(|v| v.as_object())
                .map(|m| m.len()),
            Some(0)
        );
    }

    #[test]
    fn map_item_to_part_keeps_raw_for_unknown_tool() {
        let item = serde_json::json!({
            "id": "item-unknown-1",
            "type": "mcpToolCall",
            "status": "completed",
            "tool": "search_docs",
            "arguments": { "q": "tidyflow" }
        });

        let part =
            CodexAppServerAgent::map_item_to_part(&item, "completed").expect("map should succeed");
        assert_eq!(part.tool_name.as_deref(), Some("mcptoolcall"));
        let state = part.tool_state.expect("tool_state should exist");
        assert!(state
            .get("raw")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .contains("\"mcpToolCall\""));
    }
}
