use super::codex_manager::{
    AcpInitializationState, AppServerRequestError, CodexAppServerManager, CodexNotification,
    CodexServerRequest,
};
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde_json::Value;
use std::path::Path;
use std::sync::Arc;
use tokio::sync::broadcast;
use tracing::{debug, warn};

const AUTH_REQUIRED_CODE: i64 = -32000;

#[async_trait]
trait AcpTransport: Send + Sync {
    async fn ensure_server_running(&self) -> Result<(), String>;
    async fn send_request_with_error(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<Value, AppServerRequestError>;
    async fn send_notification(&self, method: &str, params: Option<Value>) -> Result<(), String>;
    async fn send_response(&self, id: Value, result: Value) -> Result<(), String>;
    fn subscribe_notifications(&self) -> broadcast::Receiver<CodexNotification>;
    fn subscribe_requests(&self) -> broadcast::Receiver<CodexServerRequest>;
    async fn acp_initialization_state(&self) -> Option<AcpInitializationState>;
    async fn set_acp_authenticated(&self, authenticated: bool);
}

#[async_trait]
impl AcpTransport for CodexAppServerManager {
    async fn ensure_server_running(&self) -> Result<(), String> {
        CodexAppServerManager::ensure_server_running(self).await
    }

    async fn send_request_with_error(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<Value, AppServerRequestError> {
        CodexAppServerManager::send_request_with_error(self, method, params).await
    }

    async fn send_notification(&self, method: &str, params: Option<Value>) -> Result<(), String> {
        CodexAppServerManager::send_notification(self, method, params).await
    }

    async fn send_response(&self, id: Value, result: Value) -> Result<(), String> {
        CodexAppServerManager::send_response(self, id, result).await
    }

    fn subscribe_notifications(&self) -> broadcast::Receiver<CodexNotification> {
        CodexAppServerManager::subscribe_notifications(self)
    }

    fn subscribe_requests(&self) -> broadcast::Receiver<CodexServerRequest> {
        CodexAppServerManager::subscribe_requests(self)
    }

    async fn acp_initialization_state(&self) -> Option<AcpInitializationState> {
        CodexAppServerManager::acp_initialization_state(self).await
    }

    async fn set_acp_authenticated(&self, authenticated: bool) {
        CodexAppServerManager::set_acp_authenticated(self, authenticated).await;
    }
}

#[derive(Debug, Clone)]
pub struct AcpSessionSummary {
    pub id: String,
    pub title: String,
    pub cwd: String,
    pub updated_at_ms: i64,
}

#[derive(Debug, Clone)]
pub struct AcpModelInfo {
    pub id: String,
    pub name: String,
    pub supports_image_input: bool,
}

#[derive(Debug, Clone)]
pub struct AcpModeInfo {
    pub id: String,
    pub name: String,
    pub description: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct AcpSessionMetadata {
    pub models: Vec<AcpModelInfo>,
    pub current_model_id: Option<String>,
    pub modes: Vec<AcpModeInfo>,
    pub current_mode_id: Option<String>,
}

#[derive(Clone)]
pub struct AcpClient {
    transport: Arc<dyn AcpTransport>,
}

impl AcpClient {
    pub fn new(manager: Arc<CodexAppServerManager>) -> Self {
        Self { transport: manager }
    }

    #[cfg(test)]
    fn new_with_transport(transport: Arc<dyn AcpTransport>) -> Self {
        Self { transport }
    }

    pub async fn ensure_started(&self) -> Result<(), String> {
        self.transport.ensure_server_running().await
    }

    pub async fn initialization_state(&self) -> Option<AcpInitializationState> {
        self.transport.acp_initialization_state().await
    }

    pub async fn supports_load_session(&self) -> bool {
        self.initialization_state()
            .await
            .map(|state| state.agent_capabilities.load_session)
            .unwrap_or(false)
    }

    pub async fn supports_content_type(&self, content_type: &str) -> bool {
        let normalized = content_type.trim().to_lowercase();
        if normalized.is_empty() {
            return false;
        }
        self.initialization_state()
            .await
            .map(|state| {
                if state.prompt_capabilities.content_types.is_empty() {
                    normalized == "text"
                } else {
                    state.prompt_capabilities.content_types.contains(&normalized)
                }
            })
            .unwrap_or_else(|| normalized == "text")
    }

    pub fn build_prompt_text_part(text: String) -> Value {
        serde_json::json!({
            "type": "text",
            "text": text
        })
    }

    pub fn build_prompt_image_part(mime_type: String, data_url: String) -> Value {
        serde_json::json!({
            "type": "image",
            "mimeType": mime_type,
            "url": data_url
        })
    }

    pub fn build_prompt_resource_link_part(uri: String, name: String) -> Value {
        serde_json::json!({
            "type": "resource_link",
            "resource": {
                "uri": uri,
                "name": name
            }
        })
    }

    pub async fn authenticate(&self, method_id: &str) -> Result<(), String> {
        let method_id = method_id.trim();
        if method_id.is_empty() {
            return Err("authenticate requires non-empty methodId".to_string());
        }
        self.transport.set_acp_authenticated(false).await;
        self.transport
            .send_request_with_error(
                "authenticate",
                Some(serde_json::json!({
                    "methodId": method_id
                })),
            )
            .await
            .map_err(|e| e.to_user_string())?;
        self.transport.set_acp_authenticated(true).await;
        Ok(())
    }

    async fn send_request_with_auth_retry(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<Value, String> {
        let first = self
            .transport
            .send_request_with_error(method, params.clone())
            .await;
        match first {
            Ok(result) => Ok(result),
            Err(error) if Self::is_auth_required_error(&error) => {
                self.try_authenticate_with_server_methods().await?;
                let retry = self.transport.send_request_with_error(method, params).await;
                match retry {
                    Ok(result) => Ok(result),
                    Err(retry_error) if Self::is_auth_required_error(&retry_error) => {
                        Err("ACP 请求在认证后仍返回 auth_required，已停止重试以避免循环"
                            .to_string())
                    }
                    Err(retry_error) => Err(retry_error.to_user_string()),
                }
            }
            Err(error) => Err(error.to_user_string()),
        }
    }

    async fn try_authenticate_with_server_methods(&self) -> Result<(), String> {
        let state = self
            .transport
            .acp_initialization_state()
            .await
            .ok_or_else(|| "ACP 服务要求认证，但当前连接不是 ACP 模式".to_string())?;
        if state.auth_methods.is_empty() {
            return Err("ACP 服务要求认证，但 initialize 响应未提供 authMethods".to_string());
        }

        let mut failures = Vec::new();
        for method in state.auth_methods {
            match self.authenticate(&method.id).await {
                Ok(()) => return Ok(()),
                Err(err) => failures.push(format!("{}: {}", method.id, err)),
            }
        }

        Err(format!(
            "ACP 认证失败：所有认证方法均不可用（{}）",
            failures.join("; ")
        ))
    }

    fn is_auth_required_error(error: &AppServerRequestError) -> bool {
        matches!(error, AppServerRequestError::Rpc(rpc_error) if rpc_error.code == AUTH_REQUIRED_CODE)
    }

    pub async fn session_new(
        &self,
        directory: &str,
    ) -> Result<(String, AcpSessionMetadata), String> {
        let cwd_uri = Self::normalize_cwd_for_request(directory)?;
        let result = self
            .send_request_with_auth_retry(
                "session/new",
                Some(serde_json::json!({
                    "cwd": cwd_uri,
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
    ) -> Result<AcpSessionMetadata, String> {
        let result = self.session_load_raw(directory, session_id).await?;
        Ok(Self::parse_session_metadata(&result))
    }

    pub async fn session_load_raw(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<Value, String> {
        let cwd_uri = Self::normalize_cwd_for_request(directory)?;
        let result = self
            .send_request_with_auth_retry(
                "session/load",
                Some(serde_json::json!({
                    "sessionId": session_id,
                    "cwd": cwd_uri,
                    "mcpServers": []
                })),
            )
            .await?;
        Ok(result)
    }

    pub async fn session_list_page(
        &self,
        cursor: Option<&str>,
    ) -> Result<(Vec<AcpSessionSummary>, Option<String>), String> {
        let params = match cursor {
            Some(value) if !value.is_empty() => serde_json::json!({ "cursor": value }),
            _ => serde_json::json!({}),
        };
        let result = self
            .send_request_with_auth_retry("session/list", Some(params))
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
        self.send_request_with_auth_retry("session/prompt", Some(params))
            .await
    }

    pub async fn session_set_mode(&self, session_id: &str, mode_id: &str) -> Result<(), String> {
        self.send_request_with_auth_retry(
            "session/set_mode",
            Some(serde_json::json!({
                "sessionId": session_id,
                "modeId": mode_id
            })),
        )
        .await
        .map(|_| ())
    }

    pub fn subscribe_notifications(&self) -> broadcast::Receiver<CodexNotification> {
        self.transport.subscribe_notifications()
    }

    pub fn subscribe_requests(&self) -> broadcast::Receiver<CodexServerRequest> {
        self.transport.subscribe_requests()
    }

    pub async fn session_cancel(&self, session_id: &str) -> Result<(), String> {
        self.transport
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
        self.transport.send_response(request_id, result).await
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
        self.transport.send_response(request_id, result).await
    }

    fn parse_session_summary(value: Value) -> Option<AcpSessionSummary> {
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
        let cwd = Self::parse_session_cwd(&value).unwrap_or_default();
        let updated_at_ms = Self::parse_session_updated_at_ms(&value)
            .unwrap_or_else(|| Utc::now().timestamp_millis());

        Some(AcpSessionSummary {
            id,
            title,
            cwd,
            updated_at_ms,
        })
    }

    fn parse_session_cwd(value: &Value) -> Option<String> {
        for key in [
            "cwd",
            "cwdUri",
            "cwd_uri",
            "directory",
            "root",
            "workspace",
            "workdir",
            "path",
        ] {
            if let Some(raw) = value.get(key) {
                if let Some(parsed) = Self::parse_directory_value(raw) {
                    return Some(Self::decode_file_url_if_needed(&parsed));
                }
            }
        }
        None
    }

    fn parse_directory_value(value: &Value) -> Option<String> {
        if let Some(text) = value.as_str() {
            return Self::normalize_optional_token(Some(text.to_string()));
        }

        let obj = value.as_object()?;
        for key in [
            "cwd",
            "cwdUri",
            "cwd_uri",
            "directory",
            "root",
            "workspace",
            "workdir",
            "path",
            "uri",
            "value",
        ] {
            if let Some(next) = obj.get(key) {
                if let Some(parsed) = Self::parse_directory_value(next) {
                    return Some(parsed);
                }
            }
        }
        None
    }

    fn decode_file_url_if_needed(raw: &str) -> String {
        let trimmed = raw.trim();
        if let Ok(url) = url::Url::parse(trimmed) {
            if url.scheme().eq_ignore_ascii_case("file") {
                if let Ok(path) = url.to_file_path() {
                    return path.to_string_lossy().to_string();
                }
            }
        }
        trimmed.to_string()
    }

    fn normalize_cwd_for_request(directory: &str) -> Result<String, String> {
        let trimmed = directory.trim();
        if trimmed.is_empty() {
            return Err("ACP session cwd 不能为空".to_string());
        }

        if let Ok(url) = url::Url::parse(trimmed) {
            if !url.scheme().eq_ignore_ascii_case("file") {
                return Err(format!(
                    "ACP session cwd 仅支持绝对路径或 file URI，当前 scheme={}",
                    url.scheme()
                ));
            }
            let path = url
                .to_file_path()
                .map_err(|_| format!("ACP session cwd file URI 非法: {}", trimmed))?;
            let normalized = url::Url::from_file_path(&path)
                .map_err(|_| format!("ACP session cwd 无法转换为 file URI: {}", trimmed))?;
            return Ok(normalized.to_string());
        }

        let path = Path::new(trimmed);
        if !path.is_absolute() {
            return Err(format!(
                "ACP session cwd 必须是绝对路径或 file URI: {}",
                trimmed
            ));
        }
        let normalized = url::Url::from_file_path(path)
            .map_err(|_| format!("ACP session cwd 无法转换为 file URI: {}", trimmed))?;
        Ok(normalized.to_string())
    }

    fn parse_session_updated_at_ms(value: &Value) -> Option<i64> {
        for key in [
            "updatedAt",
            "updated_at",
            "lastUpdatedAt",
            "last_updated_at",
        ] {
            if let Some(raw) = value.get(key) {
                if let Some(parsed) = Self::parse_timestamp_millis(raw) {
                    return Some(parsed);
                }
            }
        }

        if let Some(time) = value.get("time") {
            for key in ["updated", "updatedAt", "updated_at", "timestamp", "ms"] {
                if let Some(raw) = time.get(key) {
                    if let Some(parsed) = Self::parse_timestamp_millis(raw) {
                        return Some(parsed);
                    }
                }
            }
        }
        None
    }

    fn parse_timestamp_millis(value: &Value) -> Option<i64> {
        if let Some(text) = value.as_str() {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                return None;
            }
            if let Some(ts) = Self::parse_rfc3339_millis(trimmed) {
                return Some(ts);
            }
            if let Ok(numeric) = trimmed.parse::<i64>() {
                return Some(Self::normalize_epoch_millis(numeric));
            }
            return None;
        }

        if let Some(number) = value.as_i64() {
            return Some(Self::normalize_epoch_millis(number));
        }

        if let Some(number) = value.as_u64() {
            if let Ok(number) = i64::try_from(number) {
                return Some(Self::normalize_epoch_millis(number));
            }
            return None;
        }

        if let Some(number) = value.as_f64() {
            if !number.is_finite() {
                return None;
            }
            return Some(Self::normalize_epoch_millis(number as i64));
        }

        let obj = value.as_object()?;
        for key in [
            "ms",
            "millis",
            "timestampMs",
            "timestamp_ms",
            "updatedAt",
            "updated_at",
            "timestamp",
        ] {
            if let Some(raw) = obj.get(key) {
                if let Some(parsed) = Self::parse_timestamp_millis(raw) {
                    return Some(parsed);
                }
            }
        }
        for key in ["seconds", "sec", "ts", "unix"] {
            if let Some(raw) = obj.get(key).and_then(|v| v.as_i64()) {
                return Some(raw.saturating_mul(1000));
            }
        }
        None
    }

    fn normalize_epoch_millis(raw: i64) -> i64 {
        if raw.abs() < 10_000_000_000 {
            raw.saturating_mul(1000)
        } else {
            raw
        }
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

    fn normalize_current_model_id(raw: Option<String>, models: &[AcpModelInfo]) -> Option<String> {
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

    fn normalize_current_mode_id(raw: Option<String>, modes: &[AcpModeInfo]) -> Option<String> {
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

    fn parse_session_metadata(value: &Value) -> AcpSessionMetadata {
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
                    Some(AcpModelInfo {
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
                Some(AcpModeInfo {
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
                "ACP session metadata parse empty: top_level_keys={:?}, raw_snippet={}",
                top_keys, snippet
            );
        } else {
            debug!(
                "ACP session metadata parsed: models_count={}, modes_count={}, current_model_id={:?}, current_mode_id={:?}",
                models.len(),
                modes.len(),
                current_model_id,
                current_mode_id
            );
        }

        AcpSessionMetadata {
            models,
            current_model_id,
            modes,
            current_mode_id,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{AcpClient, AcpTransport};
    use crate::ai::codex_manager::{
        AcpAuthMethod, AcpInitializationState, AppServerRequestError, CodexNotification,
        CodexServerRequest, JsonRpcError,
    };
    use async_trait::async_trait;
    use serde_json::{json, Value};
    use std::collections::{HashSet, VecDeque};
    use std::sync::Arc;
    use tokio::sync::{broadcast, Mutex};

    struct MockTransport {
        responses: Mutex<VecDeque<Result<Value, AppServerRequestError>>>,
        requests: Mutex<Vec<(String, Option<Value>)>>,
        init_state: Mutex<Option<AcpInitializationState>>,
        notifications_tx: broadcast::Sender<CodexNotification>,
        requests_tx: broadcast::Sender<CodexServerRequest>,
    }

    impl MockTransport {
        fn new(
            responses: Vec<Result<Value, AppServerRequestError>>,
            init_state: Option<AcpInitializationState>,
        ) -> Self {
            let (notifications_tx, _) = broadcast::channel(16);
            let (requests_tx, _) = broadcast::channel(16);
            Self {
                responses: Mutex::new(VecDeque::from(responses)),
                requests: Mutex::new(Vec::new()),
                init_state: Mutex::new(init_state),
                notifications_tx,
                requests_tx,
            }
        }

        async fn request_methods(&self) -> Vec<String> {
            self.requests
                .lock()
                .await
                .iter()
                .map(|(method, _)| method.clone())
                .collect()
        }

        async fn state_snapshot(&self) -> Option<AcpInitializationState> {
            self.init_state.lock().await.clone()
        }

        async fn first_request_params(&self, method: &str) -> Option<Value> {
            self.requests
                .lock()
                .await
                .iter()
                .find(|(m, _)| m == method)
                .and_then(|(_, params)| params.clone())
        }
    }

    #[async_trait]
    impl AcpTransport for MockTransport {
        async fn ensure_server_running(&self) -> Result<(), String> {
            Ok(())
        }

        async fn send_request_with_error(
            &self,
            method: &str,
            params: Option<Value>,
        ) -> Result<Value, AppServerRequestError> {
            self.requests
                .lock()
                .await
                .push((method.to_string(), params.clone()));
            self.responses
                .lock()
                .await
                .pop_front()
                .unwrap_or_else(|| Ok(json!({})))
        }

        async fn send_notification(
            &self,
            _method: &str,
            _params: Option<Value>,
        ) -> Result<(), String> {
            Ok(())
        }

        async fn send_response(&self, _id: Value, _result: Value) -> Result<(), String> {
            Ok(())
        }

        fn subscribe_notifications(&self) -> broadcast::Receiver<CodexNotification> {
            self.notifications_tx.subscribe()
        }

        fn subscribe_requests(&self) -> broadcast::Receiver<CodexServerRequest> {
            self.requests_tx.subscribe()
        }

        async fn acp_initialization_state(&self) -> Option<AcpInitializationState> {
            self.init_state.lock().await.clone()
        }

        async fn set_acp_authenticated(&self, authenticated: bool) {
            if let Some(state) = self.init_state.lock().await.as_mut() {
                state.authenticated = authenticated;
            }
        }
    }

    #[test]
    fn parse_session_summary_should_accept_file_url_and_epoch_millis() {
        let payload = json!({
            "sessionId": "ses_1",
            "title": "Kimi Chat",
            "cwdUri": "file:///tmp/demo",
            "updatedAt": 1_706_000_000_123i64
        });

        let session = AcpClient::parse_session_summary(payload).expect("session should parse");
        assert_eq!(session.id, "ses_1");
        assert_eq!(session.title, "Kimi Chat");
        assert_eq!(session.cwd, "/tmp/demo");
        assert_eq!(session.updated_at_ms, 1_706_000_000_123i64);
    }

    #[test]
    fn parse_session_summary_should_accept_nested_directory_and_rfc3339_time() {
        let payload = json!({
            "id": "ses_2",
            "directory": { "path": "/Users/test/workspace" },
            "time": { "updated": "2026-02-27T11:00:00Z" }
        });

        let session = AcpClient::parse_session_summary(payload).expect("session should parse");
        assert_eq!(session.id, "ses_2");
        assert_eq!(session.title, "New Chat");
        assert_eq!(session.cwd, "/Users/test/workspace");
        assert_eq!(session.updated_at_ms, 1_772_190_000_000i64);
    }

    #[test]
    fn parse_timestamp_millis_should_treat_seconds_as_epoch_seconds() {
        let millis = AcpClient::parse_timestamp_millis(&json!(1_706_000_000i64))
            .expect("timestamp should parse");
        assert_eq!(millis, 1_706_000_000_000i64);
    }

    #[test]
    fn normalize_cwd_for_request_should_convert_absolute_path_to_file_uri() {
        let cwd = AcpClient::normalize_cwd_for_request("/tmp/workspace")
            .expect("absolute path should normalize");
        assert_eq!(cwd, "file:///tmp/workspace");
    }

    #[test]
    fn normalize_cwd_for_request_should_reject_relative_path() {
        let err = AcpClient::normalize_cwd_for_request("relative/path")
            .expect_err("relative path should fail");
        assert!(err.contains("绝对路径"));
    }

    #[tokio::test]
    async fn session_new_should_send_file_uri_cwd() {
        let transport = Arc::new(MockTransport::new(
            vec![Ok(json!({"sessionId": "session-1"}))],
            None,
        ));
        let client = AcpClient::new_with_transport(transport.clone());
        let _ = client
            .session_new("/tmp/workspace")
            .await
            .expect("session/new should succeed");

        let params = transport
            .first_request_params("session/new")
            .await
            .expect("session/new params should exist");
        assert_eq!(
            params.get("cwd").and_then(|v| v.as_str()),
            Some("file:///tmp/workspace")
        );
        assert_eq!(
            params
                .get("mcpServers")
                .and_then(|v| v.as_array())
                .map(|arr| arr.len()),
            Some(0)
        );
    }

    #[tokio::test]
    async fn session_load_should_send_file_uri_cwd() {
        let transport = Arc::new(MockTransport::new(vec![Ok(json!({}))], None));
        let client = AcpClient::new_with_transport(transport.clone());
        let _ = client
            .session_load("/tmp/workspace", "session-1")
            .await
            .expect("session/load should succeed");

        let params = transport
            .first_request_params("session/load")
            .await
            .expect("session/load params should exist");
        assert_eq!(
            params.get("cwd").and_then(|v| v.as_str()),
            Some("file:///tmp/workspace")
        );
        assert_eq!(
            params.get("sessionId").and_then(|v| v.as_str()),
            Some("session-1")
        );
    }

    #[tokio::test]
    async fn session_set_mode_should_send_mode_id() {
        let transport = Arc::new(MockTransport::new(vec![Ok(json!({}))], None));
        let client = AcpClient::new_with_transport(transport.clone());
        client
            .session_set_mode("session-1", "code")
            .await
            .expect("session/set_mode should succeed");

        let params = transport
            .first_request_params("session/set_mode")
            .await
            .expect("session/set_mode params should exist");
        assert_eq!(
            params.get("sessionId").and_then(|v| v.as_str()),
            Some("session-1")
        );
        assert_eq!(params.get("modeId").and_then(|v| v.as_str()), Some("code"));
    }

    #[tokio::test]
    async fn auth_required_should_authenticate_then_retry_original_request_once() {
        let state = AcpInitializationState {
            negotiated_protocol_version: Some(1),
            auth_methods: vec![AcpAuthMethod {
                id: "oauth".to_string(),
                name: None,
                description: None,
            }],
            ..Default::default()
        };
        let transport = Arc::new(MockTransport::new(
            vec![
                Err(AppServerRequestError::Rpc(JsonRpcError {
                    code: -32000,
                    message: "Authentication required".to_string(),
                    data: None,
                })),
                Ok(json!({"ok": true})),
                Ok(json!({"sessionId": "session-1"})),
            ],
            Some(state),
        ));
        let client = AcpClient::new_with_transport(transport.clone());

        let (session_id, _) = client
            .session_new("/tmp/workspace")
            .await
            .expect("session/new should succeed after authentication");
        assert_eq!(session_id, "session-1");
        assert_eq!(
            transport.request_methods().await,
            vec!["session/new", "authenticate", "session/new"]
        );
        assert!(transport
            .state_snapshot()
            .await
            .map(|state| state.authenticated)
            .unwrap_or(false));
    }

    #[tokio::test]
    async fn auth_required_after_retry_should_fail_without_infinite_loop() {
        let state = AcpInitializationState {
            negotiated_protocol_version: Some(1),
            auth_methods: vec![AcpAuthMethod {
                id: "oauth".to_string(),
                name: None,
                description: None,
            }],
            ..Default::default()
        };
        let transport = Arc::new(MockTransport::new(
            vec![
                Err(AppServerRequestError::Rpc(JsonRpcError {
                    code: -32000,
                    message: "Authentication required".to_string(),
                    data: None,
                })),
                Ok(json!({"ok": true})),
                Err(AppServerRequestError::Rpc(JsonRpcError {
                    code: -32000,
                    message: "Authentication required".to_string(),
                    data: None,
                })),
            ],
            Some(state),
        ));
        let client = AcpClient::new_with_transport(transport.clone());

        let err = client
            .session_new("/tmp/workspace")
            .await
            .expect_err("second auth_required should stop retry loop");
        assert!(err.contains("停止重试"));
        assert_eq!(
            transport.request_methods().await,
            vec!["session/new", "authenticate", "session/new"]
        );
    }

    #[tokio::test]
    async fn auth_required_without_auth_methods_should_return_diagnostic_error() {
        let state = AcpInitializationState {
            negotiated_protocol_version: Some(1),
            auth_methods: Vec::new(),
            ..Default::default()
        };
        let transport = Arc::new(MockTransport::new(
            vec![Err(AppServerRequestError::Rpc(JsonRpcError {
                code: -32000,
                message: "Authentication required".to_string(),
                data: None,
            }))],
            Some(state),
        ));
        let client = AcpClient::new_with_transport(transport);

        let err = client
            .session_new("/tmp/workspace")
            .await
            .expect_err("missing auth methods should fail");
        assert!(err.contains("authMethods"));
    }

    #[tokio::test]
    async fn supports_content_type_should_follow_prompt_capabilities() {
        let mut state = AcpInitializationState {
            negotiated_protocol_version: Some(1),
            ..Default::default()
        };
        state.prompt_capabilities.content_types = HashSet::from([
            "text".to_string(),
            "image".to_string(),
            "resource_link".to_string(),
        ]);
        let transport = Arc::new(MockTransport::new(vec![], Some(state)));
        let client = AcpClient::new_with_transport(transport);

        assert!(client.supports_content_type("text").await);
        assert!(client.supports_content_type("image").await);
        assert!(client.supports_content_type("resource_link").await);
        assert!(!client.supports_content_type("audio").await);
    }

    #[tokio::test]
    async fn supports_content_type_should_default_to_text_when_missing_capabilities() {
        let state = AcpInitializationState {
            negotiated_protocol_version: Some(1),
            ..Default::default()
        };
        let transport = Arc::new(MockTransport::new(vec![], Some(state)));
        let client = AcpClient::new_with_transport(transport);

        assert!(client.supports_content_type("text").await);
        assert!(!client.supports_content_type("image").await);
    }
}
