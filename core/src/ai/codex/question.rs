use crate::ai::{AiPart, AiQuestionInfo, AiQuestionOption, AiQuestionRequest};
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

fn first_string_by_pointers(value: &Value, pointers: &[&str]) -> Option<String> {
    pointers.iter().find_map(|pointer| {
        value
            .pointer(pointer)
            .and_then(|v| v.as_str())
            .map(str::trim)
            .filter(|text| !text.is_empty())
            .map(str::to_string)
    })
}

pub(super) fn extract_question_nodes(value: &Value) -> Vec<Value> {
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
                        option_id: None,
                        label: normalized.to_string(),
                        description: String::new(),
                    })
                }
            }
            Value::Object(_) => {
                let label = first_string_by_pointers(
                    option,
                    &["/label", "/value", "/name", "/id", "/text"],
                )?;
                let description =
                    first_string_by_pointers(option, &["/description", "/hint", "/detail"])
                        .unwrap_or_default();
                let option_id =
                    first_string_by_pointers(option, &["/optionId", "/option_id", "/id"]);
                Some(AiQuestionOption {
                    option_id,
                    label,
                    description,
                })
            }
            _ => None,
        })
        .collect()
}

fn parse_question_info(node: &Value, index: usize) -> Option<(AiQuestionInfo, Option<String>)> {
    let question_text = first_string_by_pointers(
        node,
        &["/question", "/prompt", "/text", "/title", "/message"],
    )?;
    let question_id =
        first_string_by_pointers(node, &["/id", "/questionId", "/question_id", "/key"]);
    let header = first_string_by_pointers(node, &["/header", "/name", "/label"])
        .unwrap_or_else(|| format!("问题{}", index + 1));
    let options = parse_question_options(node.pointer("/options"));
    let multiple = first_string_by_pointers(
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
    let custom = first_string_by_pointers(
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

pub(super) fn build_question_prompt_part(request: &AiQuestionRequest) -> (String, AiPart) {
    let message_id = request
        .tool_message_id
        .clone()
        .or_else(|| request.tool_call_id.clone())
        .unwrap_or_else(|| format!("question-{}", request.id.replace(':', "-")));
    let part_id = format!("question-part-{}", request.id.replace(':', "-"));
    let tool_call_id = request
        .tool_call_id
        .clone()
        .or_else(|| request.tool_message_id.clone())
        .or_else(|| Some(request.id.clone()));
    let questions = question_infos_to_json(&request.questions);
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

pub(super) fn build_question_from_request(
    method: &str,
    request_id: &str,
    params: &Value,
) -> Option<(AiQuestionRequest, Vec<String>)> {
    let session_id = first_string_by_pointers(
        params,
        &["/threadId", "/thread_id", "/sessionId", "/session_id"],
    )?;
    let item_id = first_string_by_pointers(
        params,
        &[
            "/itemId",
            "/item_id",
            "/item/id",
            "/toolCall/toolCallId",
            "/tool_call/tool_call_id",
        ],
    );

    if method_in(
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
                    option_id: None,
                    label: "accept".to_string(),
                    description: "允许本次执行".to_string(),
                },
                AiQuestionOption {
                    option_id: None,
                    label: "decline".to_string(),
                    description: "拒绝本次执行".to_string(),
                },
                AiQuestionOption {
                    option_id: None,
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
    } else if method_in(
        method,
        &[
            "item/fileChange/requestApproval",
            "item/file_change/request_approval",
        ],
    ) {
        let q = AiQuestionInfo {
            question: "允许应用本次文件改动？".to_string(),
            header: "Codex Approval".to_string(),
            options: vec![
                AiQuestionOption {
                    option_id: None,
                    label: "accept".to_string(),
                    description: "应用改动".to_string(),
                },
                AiQuestionOption {
                    option_id: None,
                    label: "decline".to_string(),
                    description: "拒绝改动".to_string(),
                },
                AiQuestionOption {
                    option_id: None,
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
    } else if method_in(
        method,
        &[
            "request_user_input",
            "request-user-input",
            "requestUserInput",
            "item/tool/requestUserInput",
            "item/tool/request_user_input",
            "tool/requestUserInput",
            "tool/request_user_input",
        ],
    ) {
        let nodes = extract_question_nodes(params);
        if nodes.is_empty() {
            return None;
        }
        let mut questions = Vec::new();
        let mut question_ids = Vec::new();
        for (idx, node) in nodes.iter().enumerate() {
            if let Some((question, question_id)) = parse_question_info(node, idx) {
                questions.push(question);
                question_ids.push(question_id.unwrap_or_else(|| idx.to_string()));
            }
        }
        if questions.is_empty() {
            return None;
        }
        Some((
            AiQuestionRequest {
                id: request_id.to_string(),
                session_id,
                questions,
                tool_message_id: item_id.clone(),
                tool_call_id: item_id,
            },
            question_ids,
        ))
    } else {
        None
    }
}
