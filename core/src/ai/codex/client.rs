use crate::ai::codex::manager::{CodexAppServerManager, CodexNotification, CodexServerRequest};
use serde_json::Value;
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::broadcast;
use tracing::warn;

#[derive(Debug, Clone)]
pub struct CodexThreadSummary {
    pub id: String,
    pub preview: String,
    pub updated_at_secs: i64,
    pub cwd: String,
}

#[derive(Debug, Clone)]
pub struct CodexModelInfo {
    pub id: String,
    pub model: String,
    pub display_name: String,
    pub input_modalities: Vec<String>,
    pub is_default: bool,
}

#[derive(Debug, Clone)]
pub struct CodexAgentInfo {
    pub name: String,
    pub collaboration_mode: String,
    pub is_default: bool,
}

#[derive(Debug, Clone)]
struct ParsedCollaborationMode {
    name: String,
    mode: String,
}

#[derive(Clone)]
pub struct CodexAppServerClient {
    manager: Arc<CodexAppServerManager>,
}

impl CodexAppServerClient {
    pub fn new(manager: Arc<CodexAppServerManager>) -> Self {
        Self { manager }
    }

    pub async fn ensure_started(&self) -> Result<(), String> {
        self.manager.ensure_server_running().await
    }

    pub async fn thread_start(
        &self,
        directory: &str,
        title: &str,
    ) -> Result<CodexThreadSummary, String> {
        let result = self
            .manager
            .send_request(
                "thread/start",
                Some(serde_json::json!({
                    "cwd": directory
                })),
            )
            .await?;

        let thread = result
            .get("thread")
            .ok_or("thread/start response missing thread")?;
        let id = thread
            .get("id")
            .and_then(|v| v.as_str())
            .ok_or("thread/start response missing thread.id")?
            .to_string();
        let preview = thread
            .get("preview")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let updated_at_secs = thread
            .get("updatedAt")
            .and_then(|v| v.as_i64())
            .unwrap_or_else(|| chrono::Utc::now().timestamp());
        let cwd = thread
            .get("cwd")
            .and_then(|v| v.as_str())
            .unwrap_or(directory)
            .to_string();

        let _ = self
            .manager
            .send_request(
                "thread/name/set",
                Some(serde_json::json!({
                    "threadId": id,
                    "name": title
                })),
            )
            .await;

        Ok(CodexThreadSummary {
            id,
            preview,
            updated_at_secs,
            cwd,
        })
    }

    pub async fn thread_resume(&self, directory: &str, thread_id: &str) -> Result<Value, String> {
        self.manager
            .send_request(
                "thread/resume",
                Some(serde_json::json!({
                    "threadId": thread_id,
                    "cwd": directory
                })),
            )
            .await
    }

    pub async fn thread_read(&self, thread_id: &str, include_turns: bool) -> Result<Value, String> {
        self.manager
            .send_request(
                "thread/read",
                Some(serde_json::json!({
                    "threadId": thread_id,
                    "includeTurns": include_turns
                })),
            )
            .await
    }

    pub async fn thread_list(
        &self,
        directory: &str,
        limit: u32,
    ) -> Result<Vec<CodexThreadSummary>, String> {
        const MAX_TOTAL: u32 = 500;
        const PAGE_SIZE: u32 = 100;

        let capped_limit = limit.min(MAX_TOTAL);
        let mut sessions = Vec::new();
        let mut cursor: Option<String> = None;

        while (sessions.len() as u32) < capped_limit {
            let remaining = capped_limit.saturating_sub(sessions.len() as u32);
            if remaining == 0 {
                break;
            }

            let mut params = serde_json::json!({
                "cwd": directory,
                "limit": remaining.min(PAGE_SIZE),
                "sortKey": "updated_at"
            });
            if let Some(ref value) = cursor {
                params["cursor"] = Value::String(value.clone());
            }

            let result = self
                .manager
                .send_request("thread/list", Some(params))
                .await?;
            let data = result
                .get("data")
                .and_then(|v| v.as_array())
                .ok_or("thread/list response missing data")?;

            for row in data {
                let Some(id) = row.get("id").and_then(|v| v.as_str()) else {
                    continue;
                };
                let cwd = row
                    .get("cwd")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                sessions.push(CodexThreadSummary {
                    id: id.to_string(),
                    preview: row
                        .get("preview")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string(),
                    updated_at_secs: row.get("updatedAt").and_then(|v| v.as_i64()).unwrap_or(0),
                    cwd,
                });
                if (sessions.len() as u32) >= capped_limit {
                    break;
                }
            }

            cursor = result
                .get("nextCursor")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            if cursor.is_none() {
                break;
            }
        }
        Ok(sessions)
    }

    pub async fn thread_archive(&self, thread_id: &str) -> Result<(), String> {
        let _ = self
            .manager
            .send_request(
                "thread/archive",
                Some(serde_json::json!({
                    "threadId": thread_id
                })),
            )
            .await?;
        Ok(())
    }

    pub async fn turn_start(
        &self,
        thread_id: &str,
        input: Vec<Value>,
        model_id: Option<String>,
        model_provider: Option<String>,
        collaboration_mode: Option<String>,
    ) -> Result<String, String> {
        let explicit_model_id = model_id.clone();
        let mut params = serde_json::json!({
            "threadId": thread_id,
            "input": input
        });
        if let Some(model_id) = explicit_model_id.clone() {
            params["model"] = Value::String(model_id);
        }
        if let Some(provider) = model_provider {
            params["modelProvider"] = Value::String(provider);
        }
        if let Some(mode) = collaboration_mode {
            let mode_model = if let Some(model) = explicit_model_id.clone() {
                model
            } else {
                match self.model_list().await {
                    Ok(models) => models
                        .iter()
                        .find(|m| m.is_default && m.id != "default")
                        .or_else(|| models.iter().find(|m| m.id != "default"))
                        .map(|m| m.id.clone())
                        .unwrap_or_else(|| "default".to_string()),
                    Err(err) => {
                        warn!(
                            "turn_start fallback model_list failed, use `default` for collaboration mode: {}",
                            err
                        );
                        "default".to_string()
                    }
                }
            };
            if explicit_model_id.is_none() && mode_model != "default" {
                params["model"] = Value::String(mode_model.clone());
            }
            params["collaborationMode"] = serde_json::json!({
                "mode": mode,
                "settings": {
                    "model": mode_model,
                    "reasoning_effort": null,
                    "developer_instructions": null
                }
            });
        }

        let result = self
            .manager
            .send_request("turn/start", Some(params))
            .await?;
        let turn_id = result
            .get("turn")
            .and_then(|v| v.get("id"))
            .and_then(|v| v.as_str())
            .ok_or("turn/start response missing turn.id")?;
        Ok(turn_id.to_string())
    }

    pub async fn turn_interrupt(&self, thread_id: &str, turn_id: &str) -> Result<(), String> {
        let _ = self
            .manager
            .send_request(
                "turn/interrupt",
                Some(serde_json::json!({
                    "threadId": thread_id,
                    "turnId": turn_id
                })),
            )
            .await?;
        Ok(())
    }

    pub async fn model_list(&self) -> Result<Vec<CodexModelInfo>, String> {
        let result = self
            .manager
            .send_request("model/list", Some(serde_json::json!({})))
            .await?;
        let data = result
            .get("data")
            .and_then(|v| v.as_array())
            .ok_or("model/list response missing data")?;
        let mut models = Vec::new();
        for row in data {
            let Some(id) = row.get("id").and_then(|v| v.as_str()) else {
                continue;
            };
            let model = row
                .get("model")
                .and_then(|v| v.as_str())
                .unwrap_or(id)
                .to_string();
            let display_name = row
                .get("displayName")
                .and_then(|v| v.as_str())
                .unwrap_or(&model)
                .to_string();
            let input_modalities = row
                .get("inputModalities")
                .and_then(|v| v.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|it| it.as_str().map(|s| s.to_string()))
                        .collect()
                })
                .unwrap_or_else(Vec::new);
            let is_default = row
                .get("isDefault")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);

            models.push(CodexModelInfo {
                id: id.to_string(),
                model,
                display_name,
                input_modalities,
                is_default,
            });
        }
        Ok(models)
    }

    pub async fn agent_list(&self) -> Result<Vec<CodexAgentInfo>, String> {
        let mut discovered_modes = match self
            .manager
            .send_request("collaborationMode/list", Some(serde_json::json!({})))
            .await
        {
            Ok(value) => Self::parse_mode_list(&value),
            Err(err) => {
                warn!(
                    "collaborationMode/list failed, fallback to builtin modes: {}",
                    err
                );
                Vec::new()
            }
        };

        discovered_modes.push(ParsedCollaborationMode {
            name: "Default".to_string(),
            mode: "default".to_string(),
        });
        discovered_modes.push(ParsedCollaborationMode {
            name: "Plan".to_string(),
            mode: "plan".to_string(),
        });

        let mut dedup = HashSet::new();
        discovered_modes.retain(|item| dedup.insert(item.mode.clone()));
        discovered_modes.sort_by_key(|item| Self::mode_priority(&item.mode));
        let default_mode = discovered_modes
            .first()
            .map(|item| item.mode.clone())
            .unwrap_or_else(|| "default".to_string());

        Ok(discovered_modes
            .into_iter()
            .map(|item| CodexAgentInfo {
                collaboration_mode: item.mode.clone(),
                is_default: item.mode == default_mode.as_str(),
                name: item.name,
            })
            .collect())
    }

    fn normalize_mode_name(raw: &str) -> Option<String> {
        let normalized = raw.trim().to_lowercase();
        if normalized.is_empty() {
            None
        } else {
            Some(normalized)
        }
    }

    fn mode_priority(name: &str) -> u8 {
        match name {
            "default" => 0,
            "plan" => 1,
            _ => 2,
        }
    }

    fn parse_mode_list(value: &Value) -> Vec<ParsedCollaborationMode> {
        let list = value
            .get("data")
            .and_then(|v| v.as_array())
            .or_else(|| value.as_array())
            .cloned()
            .unwrap_or_default();

        list.into_iter()
            .filter_map(|item| {
                if let Some(name) = item.as_str() {
                    let normalized = Self::normalize_mode_name(name)?;
                    return Some(ParsedCollaborationMode {
                        name: name.trim().to_string(),
                        mode: normalized,
                    });
                }
                let obj = item.as_object()?;
                let mode = obj
                    .get("mode")
                    .and_then(|v| v.as_str())
                    .or_else(|| obj.get("id").and_then(|v| v.as_str()))
                    .or_else(|| obj.get("name").and_then(|v| v.as_str()))
                    .and_then(Self::normalize_mode_name)?;
                let display_name = obj
                    .get("name")
                    .and_then(|v| v.as_str())
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .unwrap_or_else(|| mode.clone());
                Some(ParsedCollaborationMode {
                    name: display_name,
                    mode,
                })
            })
            .collect()
    }

    pub async fn send_approval_response(&self, id: Value, result: Value) -> Result<(), String> {
        self.manager.send_response(id, result).await
    }

    pub fn subscribe_notifications(&self) -> broadcast::Receiver<CodexNotification> {
        self.manager.subscribe_notifications()
    }

    pub fn subscribe_requests(&self) -> broadcast::Receiver<CodexServerRequest> {
        self.manager.subscribe_requests()
    }

    pub fn local_image_input(path: PathBuf) -> Value {
        serde_json::json!({
            "type": "localImage",
            "path": path
        })
    }

    pub fn mention_input(name: &str, path: &str) -> Value {
        serde_json::json!({
            "type": "mention",
            "name": name,
            "path": path
        })
    }

    pub fn text_input(text: &str) -> Value {
        serde_json::json!({
            "type": "text",
            "text": text,
            "textElements": []
        })
    }
}

#[cfg(test)]
mod tests;
