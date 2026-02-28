use super::selection_hint;
use crate::ai::{AiEvent, AiEventStream, AiPart};
use std::collections::HashMap;
use std::sync::{Arc as StdArc, Mutex as StdMutex};

pub(crate) fn map_opencode_hub_stream(
    rx: tokio::sync::broadcast::Receiver<crate::ai::event_hub::HubEvent>,
    directory: &str,
    session_id: &str,
) -> AiEventStream {
    let session_id = session_id.to_string();
    let directory = directory.to_string();
    let part_types: StdArc<StdMutex<HashMap<String, String>>> =
        StdArc::new(StdMutex::new(HashMap::new()));

    let stream = tokio_stream::wrappers::BroadcastStream::new(rx);
    let mapped = tokio_stream::StreamExt::filter_map(stream, move |result| {
        let part_types = part_types.clone();
        let session_id = session_id.clone();
        let directory = directory.clone();

        match result {
            Ok(hub_event) => {
                if hub_event.directory.as_deref() != Some(directory.as_str()) {
                    return None;
                }
                let bus_event = hub_event.event;
                match bus_event.event_type.as_str() {
                    // message.updated：透传 messageID + role
                    "message.updated" => {
                        let props = &bus_event.properties;
                        let info = props.get("info")?;
                        let info_session = info.get("sessionID").and_then(|v| v.as_str())?;
                        if info_session != session_id {
                            return None;
                        }
                        let role = info.get("role").and_then(|v| v.as_str()).unwrap_or("");
                        let selection_hint = selection_hint::selection_hint_from_value(info);
                        Some(Ok(AiEvent::MessageUpdated {
                            message_id: info.get("id")?.as_str()?.to_string(),
                            role: role.to_string(),
                            selection_hint,
                        }))
                    }

                    // part 全量：message.part.updated
                    "message.part.updated" => {
                        let props = &bus_event.properties;
                        let part = props.get("part")?;
                        let part_session = part.get("sessionID").and_then(|v| v.as_str())?;
                        if part_session != session_id {
                            return None;
                        }
                        let message_id =
                            part.get("messageID").and_then(|v| v.as_str()).unwrap_or("");
                        let part_id = part.get("id").and_then(|v| v.as_str()).unwrap_or("");

                        let part_type = part.get("type").and_then(|v| v.as_str()).unwrap_or("");

                        // 记录 partID -> type，用于后续 message.part.delta
                        if !part_id.is_empty() && !part_type.is_empty() {
                            if let Ok(mut map) = part_types.lock() {
                                map.insert(part_id.to_string(), part_type.to_string());
                            }
                        }

                        let part_id = part_id.to_string();
                        let part_type_s = part_type.to_string();
                        let message_id_s = message_id.to_string();

                        let tool_name = part
                            .get("name")
                            .and_then(|v| v.as_str())
                            .or_else(|| part.get("tool").and_then(|v| v.as_str()))
                            .map(|s| s.to_string());

                        let tool_state = part.get("state").cloned();
                        let tool_part_metadata = part.get("metadata").cloned();

                        let part_call_id = part.get("callID").and_then(|v| v.as_str());

                        let tool_call_id = part_call_id.map(|s| s.to_string()).or_else(|| {
                            tool_state.as_ref().and_then(|s| {
                                s.get("callID")
                                    .and_then(|v| v.as_str())
                                    .map(|s| s.to_string())
                            })
                        });

                        let text = if part_type == "subtask" {
                            part.get("prompt")
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string())
                                .or_else(|| {
                                    part.get("text")
                                        .and_then(|v| v.as_str())
                                        .map(|s| s.to_string())
                                })
                        } else {
                            part.get("text")
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string())
                        };

                        let mime = part
                            .get("mime")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string());
                        let filename = part
                            .get("filename")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string());
                        let url = part
                            .get("url")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string());
                        let synthetic = part.get("synthetic").and_then(|v| v.as_bool());
                        let ignored = part.get("ignored").and_then(|v| v.as_bool());
                        let source = part.get("source").cloned();

                        Some(Ok(AiEvent::PartUpdated {
                            message_id: message_id_s,
                            part: AiPart {
                                id: part_id,
                                part_type: part_type_s,
                                text,
                                mime,
                                filename,
                                url,
                                synthetic,
                                ignored,
                                source,
                                tool_name,
                                tool_call_id,
                                tool_kind: None,
                                tool_title: None,
                                tool_raw_input: None,
                                tool_raw_output: None,
                                tool_locations: None,
                                tool_state,
                                tool_part_metadata,
                            },
                        }))
                    }
                    // OpenCode 新版：message.part.delta 承载真正的流式增量（按 partID 分发）
                    "message.part.delta" => {
                        let props = &bus_event.properties;
                        let delta_session = props.get("sessionID").and_then(|v| v.as_str())?;
                        if delta_session != session_id {
                            return None;
                        }
                        let message_id = props
                            .get("messageID")
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        let part_id = props.get("partID").and_then(|v| v.as_str()).unwrap_or("");
                        let field = props.get("field").and_then(|v| v.as_str()).unwrap_or("");
                        let delta = props.get("delta").and_then(|v| v.as_str()).unwrap_or("");
                        if delta.is_empty() {
                            return None;
                        }

                        let normalized_field = match field {
                            "prompt" => "text",
                            "text" | "progress" | "output" => field,
                            _ => return None,
                        };

                        if normalized_field.is_empty() {
                            return None;
                        }

                        let part_type = if !part_id.is_empty() {
                            part_types.lock().ok().and_then(|m| m.get(part_id).cloned())
                        } else {
                            None
                        };

                        let part_type_s =
                            part_type.clone().unwrap_or_else(|| match normalized_field {
                                "progress" | "output" => "tool".to_string(),
                                _ => "text".to_string(),
                            });
                        Some(Ok(AiEvent::PartDelta {
                            message_id: message_id.to_string(),
                            part_id: part_id.to_string(),
                            part_type: part_type_s,
                            field: normalized_field.to_string(),
                            delta: delta.to_string(),
                        }))
                    }
                    // 会话状态变为 idle 表示处理完成
                    "session.idle" => {
                        let props = &bus_event.properties;
                        let idle_session = props
                            .get("sessionID")
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        if idle_session == session_id {
                            Some(Ok(AiEvent::Done { stop_reason: None }))
                        } else {
                            None
                        }
                    }
                    "session.status" => {
                        let props = &bus_event.properties;
                        // session.status 的 properties 可能直接包含 sessionID
                        // 也可能是 Record<sessionID, status>
                        let matches_session = props.get(&session_id).is_some()
                            || props
                                .get("sessionID")
                                .and_then(|v| v.as_str())
                                .map(|s| s == session_id)
                                .unwrap_or(false);
                        if !matches_session {
                            return None;
                        }
                        let is_idle = props
                            .get(&session_id)
                            .and_then(|v| v.get("type"))
                            .and_then(|v| v.as_str())
                            .map(|s| s == "idle")
                            .unwrap_or(false)
                            || props
                                .get("status")
                                .and_then(|v| v.get("type"))
                                .and_then(|v| v.as_str())
                                .map(|s| s == "idle")
                                .unwrap_or(false)
                            || props
                                .get("type")
                                .and_then(|v| v.as_str())
                                .map(|s| s == "idle")
                                .unwrap_or(false);
                        if is_idle {
                            Some(Ok(AiEvent::Done { stop_reason: None }))
                        } else {
                            None
                        }
                    }
                    // 会话错误
                    "session.error" => {
                        let props = &bus_event.properties;
                        let err_session = props
                            .get("sessionID")
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        if err_session != session_id {
                            return None;
                        }
                        let message = props
                            .get("error")
                            .and_then(|v| v.get("message"))
                            .and_then(|v| v.as_str())
                            .unwrap_or("Unknown error")
                            .to_string();
                        Some(Ok(AiEvent::Error { message }))
                    }
                    "question.asked" => {
                        let props = &bus_event.properties;
                        let asked_session = props.get("sessionID").and_then(|v| v.as_str())?;
                        if asked_session != session_id {
                            return None;
                        }

                        let request_id = props.get("id").and_then(|v| v.as_str())?.to_string();
                        let questions = props
                            .get("questions")
                            .and_then(|v| v.as_array())
                            .map(|arr| {
                                arr.iter()
                                    .filter_map(|item| {
                                        let obj = item.as_object()?;
                                        let question = obj
                                            .get("question")
                                            .and_then(|v| v.as_str())
                                            .unwrap_or("")
                                            .to_string();
                                        let header = obj
                                            .get("header")
                                            .and_then(|v| v.as_str())
                                            .unwrap_or("")
                                            .to_string();
                                        let options = obj
                                            .get("options")
                                            .and_then(|v| v.as_array())
                                            .map(|opts| {
                                                opts.iter()
                                                    .filter_map(|opt| {
                                                        let o = opt.as_object()?;
                                                        let label = o
                                                            .get("label")
                                                            .and_then(|v| v.as_str())
                                                            .unwrap_or("")
                                                            .to_string();
                                                        if label.is_empty() {
                                                            return None;
                                                        }
                                                        let description = o
                                                            .get("description")
                                                            .and_then(|v| v.as_str())
                                                            .unwrap_or("")
                                                            .to_string();
                                                        Some(crate::ai::AiQuestionOption {
                                                            option_id: o
                                                                .get("option_id")
                                                                .or_else(|| o.get("optionId"))
                                                                .and_then(|v| v.as_str())
                                                                .map(|v| v.to_string()),
                                                            label,
                                                            description,
                                                        })
                                                    })
                                                    .collect::<Vec<_>>()
                                            })
                                            .unwrap_or_default();
                                        if question.is_empty() {
                                            return None;
                                        }
                                        Some(crate::ai::AiQuestionInfo {
                                            question,
                                            header,
                                            options,
                                            multiple: obj
                                                .get("multiple")
                                                .and_then(|v| v.as_bool())
                                                .unwrap_or(false),
                                            custom: obj
                                                .get("custom")
                                                .and_then(|v| v.as_bool())
                                                .unwrap_or(true),
                                        })
                                    })
                                    .collect::<Vec<_>>()
                            })
                            .unwrap_or_default();

                        let (tool_message_id, tool_call_id) = props
                            .get("tool")
                            .and_then(|v| v.as_object())
                            .map(|tool| {
                                (
                                    tool.get("messageID")
                                        .and_then(|v| v.as_str())
                                        .map(|s| s.to_string()),
                                    tool.get("callID")
                                        .and_then(|v| v.as_str())
                                        .map(|s| s.to_string()),
                                )
                            })
                            .unwrap_or((None, None));

                        Some(Ok(AiEvent::QuestionAsked {
                            request: crate::ai::AiQuestionRequest {
                                id: request_id,
                                session_id: asked_session.to_string(),
                                questions,
                                tool_message_id,
                                tool_call_id,
                            },
                        }))
                    }
                    "question.replied" | "question.rejected" => {
                        let props = &bus_event.properties;
                        let asked_session = props
                            .get("sessionID")
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        if asked_session != session_id {
                            return None;
                        }
                        let request_id = props
                            .get("requestID")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string();
                        if request_id.is_empty() {
                            return None;
                        }
                        Some(Ok(AiEvent::QuestionCleared {
                            session_id: asked_session.to_string(),
                            request_id,
                        }))
                    }
                    // 心跳和连接事件忽略
                    "server.heartbeat" | "server.connected" => None,
                    _ => None,
                }
            }
            // Lagged 错误只记录日志，继续处理后续事件（不中断流）
            Err(tokio_stream::wrappers::errors::BroadcastStreamRecvError::Lagged(n)) => {
                tracing::warn!("OpenCode event hub lagged by {} messages, continuing...", n);
                None
            }
        }
    });

    Box::pin(mapped)
}
