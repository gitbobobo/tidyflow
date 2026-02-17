use super::codex_manager::{CodexAppServerManager, CodexNotification, CodexServerRequest};
use serde_json::Value;
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::broadcast;

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

    pub async fn thread_resume(&self, directory: &str, thread_id: &str) -> Result<(), String> {
        let _ = self
            .manager
            .send_request(
                "thread/resume",
                Some(serde_json::json!({
                    "threadId": thread_id,
                    "cwd": directory
                })),
            )
            .await?;
        Ok(())
    }

    pub async fn thread_list(
        &self,
        directory: &str,
        limit: u32,
    ) -> Result<Vec<CodexThreadSummary>, String> {
        let result = self
            .manager
            .send_request(
                "thread/list",
                Some(serde_json::json!({
                    "cwd": directory,
                    "limit": limit
                })),
            )
            .await?;
        let data = result
            .get("data")
            .and_then(|v| v.as_array())
            .ok_or("thread/list response missing data")?;

        let expected = directory.trim_end_matches('/');
        let mut sessions = Vec::new();
        for row in data {
            let Some(id) = row.get("id").and_then(|v| v.as_str()) else {
                continue;
            };
            let cwd = row
                .get("cwd")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if cwd.trim_end_matches('/') != expected {
                continue;
            }
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
        }
        Ok(sessions)
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
        let mut params = serde_json::json!({
            "threadId": thread_id,
            "input": input
        });
        if let Some(model_id) = model_id.clone() {
            params["model"] = Value::String(model_id);
        }
        if let Some(provider) = model_provider {
            params["modelProvider"] = Value::String(provider);
        }
        if let Some(mode) = collaboration_mode {
            let mode_model = model_id.unwrap_or_else(|| "default".to_string());
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
        let mut discovered_modes = self
            .manager
            .send_request("mode/list", Some(serde_json::json!({})))
            .await
            .ok()
            .map(|v| Self::parse_mode_list(&v))
            .unwrap_or_default();

        let mut ordered_names = Vec::new();
        ordered_names.append(&mut discovered_modes);
        ordered_names.push("default".to_string());
        ordered_names.push("plan".to_string());

        let mut dedup = HashSet::new();
        ordered_names.retain(|name| dedup.insert(name.clone()));
        let default_mode = ordered_names
            .first()
            .cloned()
            .unwrap_or_else(|| "default".to_string());

        Ok(ordered_names
            .into_iter()
            .map(|name| CodexAgentInfo {
                collaboration_mode: name.clone(),
                is_default: name == default_mode.as_str(),
                name,
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

    fn parse_mode_list(value: &Value) -> Vec<String> {
        let list = value
            .get("data")
            .and_then(|v| v.as_array())
            .or_else(|| value.as_array())
            .cloned()
            .unwrap_or_default();

        list.into_iter()
            .filter_map(|item| {
                if let Some(name) = item.as_str() {
                    return Self::normalize_mode_name(name);
                }
                let obj = item.as_object()?;
                obj.get("mode")
                    .and_then(|v| v.as_str())
                    .or_else(|| obj.get("id").and_then(|v| v.as_str()))
                    .or_else(|| obj.get("name").and_then(|v| v.as_str()))
                    .and_then(Self::normalize_mode_name)
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
