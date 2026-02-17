use super::codex_manager::{CodexAppServerManager, CodexNotification};
use chrono::{DateTime, Utc};
use serde_json::Value;
use std::sync::Arc;
use tokio::sync::broadcast;

#[derive(Debug, Clone)]
pub struct CopilotSessionSummary {
    pub id: String,
    pub title: String,
    pub cwd: String,
    pub updated_at_ms: i64,
}

#[derive(Debug, Clone)]
pub struct CopilotModelInfo {
    pub id: String,
    pub name: String,
    pub supports_image_input: bool,
}

#[derive(Debug, Clone)]
pub struct CopilotModeInfo {
    pub id: String,
    pub name: String,
    pub description: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct CopilotSessionMetadata {
    pub models: Vec<CopilotModelInfo>,
    pub current_model_id: Option<String>,
    pub modes: Vec<CopilotModeInfo>,
    pub current_mode_id: Option<String>,
}

#[derive(Clone)]
pub struct CopilotAcpClient {
    manager: Arc<CodexAppServerManager>,
}

impl CopilotAcpClient {
    pub fn new(manager: Arc<CodexAppServerManager>) -> Self {
        Self { manager }
    }

    pub async fn ensure_started(&self) -> Result<(), String> {
        self.manager.ensure_server_running().await
    }

    pub async fn session_new(
        &self,
        directory: &str,
    ) -> Result<(String, CopilotSessionMetadata), String> {
        let result = self
            .manager
            .send_request(
                "session/new",
                Some(serde_json::json!({
                    "cwd": directory,
                    "mcpServers": []
                })),
            )
            .await?;

        let session_id = result
            .get("sessionId")
            .and_then(|v| v.as_str())
            .ok_or("session/new response missing sessionId")?
            .to_string();
        let metadata = Self::parse_session_metadata(&result);
        Ok((session_id, metadata))
    }

    pub async fn session_load(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<CopilotSessionMetadata, String> {
        let result = self
            .manager
            .send_request(
                "session/load",
                Some(serde_json::json!({
                    "sessionId": session_id,
                    "cwd": directory,
                    "mcpServers": []
                })),
            )
            .await?;
        Ok(Self::parse_session_metadata(&result))
    }

    pub async fn session_list_page(
        &self,
        cursor: Option<&str>,
    ) -> Result<(Vec<CopilotSessionSummary>, Option<String>), String> {
        let params = match cursor {
            Some(value) if !value.is_empty() => serde_json::json!({ "cursor": value }),
            _ => serde_json::json!({}),
        };
        let result = self
            .manager
            .send_request("session/list", Some(params))
            .await?;

        let sessions = result
            .get("sessions")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter_map(Self::parse_session_summary)
            .collect::<Vec<_>>();
        let next_cursor = result
            .get("nextCursor")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        Ok((sessions, next_cursor))
    }

    pub async fn session_prompt(
        &self,
        session_id: &str,
        prompt: Vec<Value>,
        model: Option<String>,
        mode: Option<String>,
    ) -> Result<Value, String> {
        let mut params = serde_json::json!({
            "sessionId": session_id,
            "prompt": prompt
        });
        if let Some(model_id) = model {
            params["model"] = Value::String(model_id);
        }
        if let Some(mode_id) = mode {
            params["mode"] = Value::String(mode_id);
        }
        self.manager
            .send_request("session/prompt", Some(params))
            .await
    }

    pub fn subscribe_notifications(&self) -> broadcast::Receiver<CodexNotification> {
        self.manager.subscribe_notifications()
    }

    pub async fn session_cancel(&self, session_id: &str) -> Result<(), String> {
        self.manager
            .send_notification(
                "session/cancel",
                Some(serde_json::json!({
                    "sessionId": session_id
                })),
            )
            .await
    }

    fn parse_session_summary(value: Value) -> Option<CopilotSessionSummary> {
        let id = value.get("sessionId")?.as_str()?.to_string();
        let title = value
            .get("title")
            .and_then(|v| v.as_str())
            .unwrap_or("New Chat")
            .to_string();
        let cwd = value
            .get("cwd")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        let updated_at_ms = value
            .get("updatedAt")
            .and_then(|v| v.as_str())
            .and_then(Self::parse_rfc3339_millis)
            .unwrap_or_else(|| Utc::now().timestamp_millis());

        Some(CopilotSessionSummary {
            id,
            title,
            cwd,
            updated_at_ms,
        })
    }

    fn parse_rfc3339_millis(raw: &str) -> Option<i64> {
        DateTime::parse_from_rfc3339(raw)
            .ok()
            .map(|dt| dt.with_timezone(&Utc).timestamp_millis())
    }

    fn parse_session_metadata(value: &Value) -> CopilotSessionMetadata {
        let models_root = value.get("models").unwrap_or(value);
        let modes_root = value.get("modes").unwrap_or(value);

        let models = models_root
            .get("availableModels")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter_map(|row| {
                let id = row.get("modelId").and_then(|v| v.as_str())?.to_string();
                let name = row
                    .get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or(&id)
                    .to_string();
                let supports_image_input = row
                    .get("inputModalities")
                    .and_then(|v| v.as_array())
                    .map(|arr| {
                        arr.iter().any(|it| {
                            it.as_str()
                                .map(|s| s.eq_ignore_ascii_case("image"))
                                .unwrap_or(false)
                        })
                    })
                    .unwrap_or(true);
                Some(CopilotModelInfo {
                    id,
                    name,
                    supports_image_input,
                })
            })
            .collect::<Vec<_>>();
        let current_model_id = models_root
            .get("currentModelId")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        let modes = modes_root
            .get("availableModes")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter_map(|row| {
                let id = row.get("id").and_then(|v| v.as_str())?.to_string();
                let name = row
                    .get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or(&id)
                    .to_string();
                let description = row
                    .get("description")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string());
                Some(CopilotModeInfo {
                    id,
                    name,
                    description,
                })
            })
            .collect::<Vec<_>>();
        let current_mode_id = modes_root
            .get("currentModeId")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        CopilotSessionMetadata {
            models,
            current_model_id,
            modes,
            current_mode_id,
        }
    }
}
