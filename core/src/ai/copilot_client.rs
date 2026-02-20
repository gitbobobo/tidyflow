use super::codex_manager::{CodexAppServerManager, CodexNotification, CodexServerRequest};
use chrono::{DateTime, Utc};
use serde_json::Value;
use std::sync::Arc;
use tokio::sync::broadcast;
use tracing::{debug, warn};

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
        let result = self.session_load_raw(directory, session_id).await?;
        Ok(Self::parse_session_metadata(&result))
    }

    pub async fn session_load_raw(&self, directory: &str, session_id: &str) -> Result<Value, String> {
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
        Ok(result)
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

    pub fn subscribe_requests(&self) -> broadcast::Receiver<CodexServerRequest> {
        self.manager.subscribe_requests()
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

    /// 回复权限请求（包括 question 工具）
    pub async fn respond_to_permission_request(
        &self,
        request_id: serde_json::Value,
        option_id: &str,
    ) -> Result<(), String> {
        let result = serde_json::json!({
            "outcome": {
                "outcome": "selected",
                "optionId": option_id
            }
        });
        self.manager.send_response(request_id, result).await
    }

    /// 拒绝权限请求
    pub async fn reject_permission_request(
        &self,
        request_id: serde_json::Value,
    ) -> Result<(), String> {
        let result = serde_json::json!({
            "outcome": {
                "outcome": "cancelled"
            }
        });
        self.manager.send_response(request_id, result).await
    }

    fn parse_session_summary(value: Value) -> Option<CopilotSessionSummary> {
        let id = value
            .get("sessionId")
            .and_then(|v| v.as_str())
            .or_else(|| value.get("id").and_then(|v| v.as_str()))?
            .to_string();
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

    fn normalize_optional_token(raw: Option<String>) -> Option<String> {
        let token = raw?;
        let trimmed = token.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
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

    fn rows_from_key(root: &Value, key: &str) -> Vec<Value> {
        if let Some(arr) = root.get(key).and_then(|v| v.as_array()) {
            return arr.clone();
        }
        if let Some(obj) = root.get(key).and_then(|v| v.as_object()) {
            return obj.values().cloned().collect();
        }
        Vec::new()
    }

    fn rows_from_candidates(root: &Value, keys: &[&str]) -> Vec<Value> {
        for key in keys {
            let rows = Self::rows_from_key(root, key);
            if !rows.is_empty() {
                return rows;
            }
        }
        if let Some(arr) = root.as_array() {
            return arr.clone();
        }
        Vec::new()
    }

    fn normalize_current_model_id(
        raw: Option<String>,
        models: &[CopilotModelInfo],
    ) -> Option<String> {
        let current = Self::normalize_optional_token(raw)?;
        if models.is_empty() {
            return Some(current);
        }

        if let Some(found) = models
            .iter()
            .find(|row| row.id == current || row.id.eq_ignore_ascii_case(&current))
        {
            return Some(found.id.clone());
        }

        if let Some((_, suffix)) = current.split_once('/') {
            let normalized_suffix = suffix.trim();
            if !normalized_suffix.is_empty() {
                if let Some(found) = models.iter().find(|row| {
                    row.id == normalized_suffix || row.id.eq_ignore_ascii_case(normalized_suffix)
                }) {
                    return Some(found.id.clone());
                }
            }
        }

        Some(current)
    }

    fn normalize_current_mode_id(raw: Option<String>, modes: &[CopilotModeInfo]) -> Option<String> {
        let current = Self::normalize_optional_token(raw)?;
        if modes.is_empty() {
            return Some(current);
        }

        if let Some(found) = modes
            .iter()
            .find(|row| row.id == current || row.id.eq_ignore_ascii_case(&current))
        {
            return Some(found.id.clone());
        }

        Some(current)
    }

    fn parse_session_metadata(value: &Value) -> CopilotSessionMetadata {
        let models_root = value.get("models").unwrap_or(value);
        let modes_root = value.get("modes").unwrap_or(value);

        let models =
            Self::rows_from_candidates(models_root, &["availableModels", "available_models"])
                .into_iter()
                .filter_map(|row| {
                    let id = row
                        .get("modelId")
                        .and_then(|v| v.as_str())
                        .or_else(|| row.get("model_id").and_then(|v| v.as_str()))
                        .or_else(|| row.get("id").and_then(|v| v.as_str()))
                        .or_else(|| row.get("model").and_then(|v| v.as_str()))?
                        .to_string();
                    let name = row
                        .get("name")
                        .and_then(|v| v.as_str())
                        .or_else(|| row.get("displayName").and_then(|v| v.as_str()))
                        .or_else(|| row.get("display_name").and_then(|v| v.as_str()))
                        .unwrap_or(&id)
                        .to_string();
                    let supports_image_input = row
                        .get("inputModalities")
                        .and_then(|v| v.as_array())
                        .or_else(|| row.get("input_modalities").and_then(|v| v.as_array()))
                        .or_else(|| {
                            row.get("modalities")
                                .and_then(|v| v.get("input"))
                                .and_then(|v| v.as_array())
                        })
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
        let current_model_id = Self::normalize_current_model_id(
            models_root
                .get("currentModelId")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .or_else(|| {
                    models_root
                        .get("current_model_id")
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                })
                .or_else(|| {
                    Self::find_scalar_by_keys(
                        models_root,
                        &[
                            "currentModelId",
                            "current_model_id",
                            "selectedModelId",
                            "selected_model_id",
                        ],
                    )
                })
                .or_else(|| {
                    models_root
                        .get("currentModel")
                        .and_then(|v| {
                            v.get("modelId")
                                .or_else(|| v.get("modelID"))
                                .or_else(|| v.get("id"))
                        })
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                })
                .or_else(|| {
                    value
                        .get("currentModel")
                        .and_then(|v| {
                            v.get("modelId")
                                .or_else(|| v.get("modelID"))
                                .or_else(|| v.get("id"))
                        })
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                })
                .or_else(|| {
                    value.get("model").and_then(|v| {
                        v.as_str().map(|s| s.to_string()).or_else(|| {
                            v.get("modelId")
                                .or_else(|| v.get("modelID"))
                                .or_else(|| v.get("id"))
                                .and_then(|it| it.as_str())
                                .map(|s| s.to_string())
                        })
                    })
                }),
            &models,
        );

        let modes = Self::rows_from_candidates(modes_root, &["availableModes", "available_modes"])
            .into_iter()
            .filter_map(|row| {
                let id = row
                    .get("id")
                    .and_then(|v| v.as_str())
                    .or_else(|| row.get("modeId").and_then(|v| v.as_str()))
                    .or_else(|| row.get("mode_id").and_then(|v| v.as_str()))
                    .or_else(|| row.get("mode").and_then(|v| v.as_str()))
                    .or_else(|| row.get("name").and_then(|v| v.as_str()))?
                    .to_string();
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
        let current_mode_id = Self::normalize_current_mode_id(
            modes_root
                .get("currentModeId")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .or_else(|| {
                    modes_root
                        .get("current_mode_id")
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                })
                .or_else(|| {
                    Self::find_scalar_by_keys(
                        modes_root,
                        &[
                            "currentModeId",
                            "current_mode_id",
                            "selectedModeId",
                            "selected_mode_id",
                        ],
                    )
                })
                .or_else(|| {
                    modes_root
                        .get("currentMode")
                        .and_then(|v| {
                            v.get("modeId")
                                .or_else(|| v.get("modeID"))
                                .or_else(|| v.get("id"))
                        })
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                })
                .or_else(|| {
                    value
                        .get("currentMode")
                        .and_then(|v| {
                            v.get("modeId")
                                .or_else(|| v.get("modeID"))
                                .or_else(|| v.get("id"))
                        })
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                })
                .or_else(|| {
                    value.get("mode").and_then(|v| {
                        v.as_str().map(|s| s.to_string()).or_else(|| {
                            v.get("modeId")
                                .or_else(|| v.get("modeID"))
                                .or_else(|| v.get("id"))
                                .and_then(|it| it.as_str())
                                .map(|s| s.to_string())
                        })
                    })
                }),
            &modes,
        );

        if models.is_empty()
            && modes.is_empty()
            && current_model_id.is_none()
            && current_mode_id.is_none()
        {
            let top_keys = value
                .as_object()
                .map(|obj| obj.keys().cloned().collect::<Vec<_>>())
                .unwrap_or_default();
            let snippet = serde_json::to_string(value)
                .unwrap_or_default()
                .chars()
                .take(600)
                .collect::<String>();
            warn!(
                "Copilot session metadata parse empty: top_level_keys={:?}, raw_snippet={}",
                top_keys, snippet
            );
        } else {
            debug!(
                "Copilot session metadata parsed: models_count={}, modes_count={}, current_model_id={:?}, current_mode_id={:?}",
                models.len(),
                modes.len(),
                current_model_id,
                current_mode_id
            );
        }

        CopilotSessionMetadata {
            models,
            current_model_id,
            modes,
            current_mode_id,
        }
    }
}
