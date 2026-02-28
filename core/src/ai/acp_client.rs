use super::codex_manager::{
    AcpContentEncodingMode, AcpInitializationState, AppServerRequestError, CodexAppServerManager,
    CodexNotification, CodexServerRequest,
};
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde_json::Value;
use std::collections::HashMap;
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

#[derive(Debug, Clone)]
pub struct AcpConfigOptionChoice {
    pub value: Value,
    pub label: String,
    pub description: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AcpConfigOptionGroup {
    pub label: String,
    pub options: Vec<AcpConfigOptionChoice>,
}

#[derive(Debug, Clone)]
pub struct AcpConfigOptionInfo {
    pub option_id: String,
    pub category: Option<String>,
    pub name: String,
    pub description: Option<String>,
    pub current_value: Option<Value>,
    pub options: Vec<AcpConfigOptionChoice>,
    pub option_groups: Vec<AcpConfigOptionGroup>,
    pub raw: Option<Value>,
}

#[derive(Debug, Clone, Default)]
pub struct AcpSessionMetadata {
    pub models: Vec<AcpModelInfo>,
    pub current_model_id: Option<String>,
    pub modes: Vec<AcpModeInfo>,
    pub current_mode_id: Option<String>,
    pub config_options: Vec<AcpConfigOptionInfo>,
    pub config_values: HashMap<String, Value>,
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

    pub async fn supports_set_config_option(&self) -> bool {
        self.initialization_state()
            .await
            .map(|state| state.agent_capabilities.set_config_option)
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
                    normalized == "text" || normalized == "resource_link"
                } else {
                    state
                        .prompt_capabilities
                        .content_types
                        .contains(&normalized)
                }
            })
            .unwrap_or_else(|| normalized == "text" || normalized == "resource_link")
    }

    pub async fn prompt_encoding_mode(&self) -> AcpContentEncodingMode {
        self.initialization_state()
            .await
            .map(|state| state.prompt_capabilities.encoding_mode)
            .unwrap_or(AcpContentEncodingMode::Unknown)
    }

    pub fn build_prompt_text_part(text: String) -> Value {
        serde_json::json!({
            "type": "text",
            "text": text
        })
    }

    pub fn build_prompt_image_part(
        mode: AcpContentEncodingMode,
        mime_type: String,
        data_base64: String,
    ) -> Value {
        match mode {
            AcpContentEncodingMode::New => {
                Self::build_prompt_image_part_new(mime_type, data_base64)
            }
            AcpContentEncodingMode::Legacy | AcpContentEncodingMode::Unknown => {
                let data_url = format!("data:{};base64,{}", mime_type, data_base64);
                Self::build_prompt_image_part_legacy(mime_type, data_url)
            }
        }
    }

    pub fn build_prompt_image_part_new(mime_type: String, data_base64: String) -> Value {
        serde_json::json!({
            "type": "image",
            "mimeType": mime_type,
            "data": data_base64
        })
    }

    pub fn build_prompt_image_part_legacy(mime_type: String, data_url: String) -> Value {
        serde_json::json!({
            "type": "image",
            "mimeType": mime_type,
            "url": data_url
        })
    }

    pub fn build_prompt_audio_part(
        mode: AcpContentEncodingMode,
        mime_type: String,
        data_base64: String,
    ) -> Value {
        match mode {
            AcpContentEncodingMode::New => {
                Self::build_prompt_audio_part_new(mime_type, data_base64)
            }
            AcpContentEncodingMode::Legacy | AcpContentEncodingMode::Unknown => {
                let data_url = format!("data:{};base64,{}", mime_type, data_base64);
                Self::build_prompt_audio_part_legacy(mime_type, data_url)
            }
        }
    }

    pub fn build_prompt_audio_part_new(mime_type: String, data_base64: String) -> Value {
        serde_json::json!({
            "type": "audio",
            "mimeType": mime_type,
            "data": data_base64
        })
    }

    pub fn build_prompt_audio_part_legacy(mime_type: String, data_url: String) -> Value {
        serde_json::json!({
            "type": "audio",
            "mimeType": mime_type,
            "url": data_url
        })
    }

    pub fn build_prompt_resource_text_part(
        uri: String,
        name: String,
        mime_type: String,
        text: String,
    ) -> Value {
        serde_json::json!({
            "type": "resource",
            "resource": {
                "uri": uri,
                "name": name,
                "mimeType": mime_type,
                "text": text
            }
        })
    }

    pub fn build_prompt_resource_blob_part(
        uri: String,
        name: String,
        mime_type: String,
        blob_base64: String,
    ) -> Value {
        serde_json::json!({
            "type": "resource",
            "resource": {
                "uri": uri,
                "name": name,
                "mimeType": mime_type,
                "blob": blob_base64
            }
        })
    }

    pub fn build_prompt_resource_link_part(
        mode: AcpContentEncodingMode,
        uri: String,
        name: String,
        mime_type: Option<String>,
    ) -> Value {
        match mode {
            AcpContentEncodingMode::New => {
                Self::build_prompt_resource_link_part_new(uri, name, mime_type)
            }
            AcpContentEncodingMode::Legacy | AcpContentEncodingMode::Unknown => {
                Self::build_prompt_resource_link_part_legacy(uri, name)
            }
        }
    }

    pub fn build_prompt_resource_link_part_new(
        uri: String,
        name: String,
        mime_type: Option<String>,
    ) -> Value {
        let mut payload = serde_json::json!({
            "type": "resource_link",
            "uri": uri,
            "name": name,
        });
        if let Some(mime_type) = mime_type.filter(|m| !m.trim().is_empty()) {
            payload["mimeType"] = Value::String(mime_type);
        }
        payload
    }

    pub fn build_prompt_resource_link_part_legacy(uri: String, name: String) -> Value {
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

    pub async fn session_set_config_option(
        &self,
        session_id: &str,
        option_id: &str,
        value: Value,
    ) -> Result<(), String> {
        let option_id = option_id.trim();
        if option_id.is_empty() {
            return Err("session/set_config_option requires non-empty option_id".to_string());
        }
        self.send_request_with_auth_retry(
            "session/set_config_option",
            Some(serde_json::json!({
                "sessionId": session_id,
                "optionId": option_id,
                "value": value
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

    /// ACP follow-along：创建终端句柄
    pub async fn terminal_create(
        &self,
        session_id: &str,
        tool_call_id: &str,
    ) -> Result<String, String> {
        let result = self
            .send_request_with_auth_retry(
                "terminal/create",
                Some(serde_json::json!({
                    "sessionId": session_id,
                    "toolCallId": tool_call_id
                })),
            )
            .await?;
        result
            .get("terminalId")
            .or_else(|| result.get("id"))
            .and_then(|v| v.as_str())
            .map(|v| v.to_string())
            .ok_or_else(|| "terminal/create response missing terminalId".to_string())
    }

    /// ACP follow-along：释放终端句柄
    pub async fn terminal_release(&self, terminal_id: &str) -> Result<(), String> {
        self.send_request_with_auth_retry(
            "terminal/release",
            Some(serde_json::json!({
                "terminalId": terminal_id
            })),
        )
        .await
        .map(|_| ())
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
            return Ok(path.to_string_lossy().to_string());
        }

        let path = Path::new(trimmed);
        if !path.is_absolute() {
            return Err(format!(
                "ACP session cwd 必须是绝对路径或 file URI: {}",
                trimmed
            ));
        }
        Ok(path.to_string_lossy().to_string())
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

    fn find_object_by_keys(value: &Value, keys: &[&str]) -> Option<serde_json::Map<String, Value>> {
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
                            if let Some(found) = v.as_object() {
                                return Some(found.clone());
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

    fn parse_config_option_choice(value: &Value) -> Option<AcpConfigOptionChoice> {
        let obj = value.as_object()?;
        let choice_value = obj
            .get("value")
            .or_else(|| obj.get("id"))
            .or_else(|| obj.get("optionId"))
            .or_else(|| obj.get("option_id"))
            .cloned()?;
        let label = obj
            .get("label")
            .and_then(|v| v.as_str())
            .or_else(|| obj.get("name").and_then(|v| v.as_str()))
            .or_else(|| choice_value.as_str())
            .unwrap_or("option")
            .to_string();
        let description = obj
            .get("description")
            .and_then(|v| v.as_str())
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty());
        Some(AcpConfigOptionChoice {
            value: choice_value,
            label,
            description,
        })
    }

    fn parse_config_option_option_groups(
        value: Option<&Value>,
    ) -> (Vec<AcpConfigOptionChoice>, Vec<AcpConfigOptionGroup>) {
        let mut options = Vec::new();
        let mut option_groups = Vec::new();
        let Some(items) = value.and_then(|v| v.as_array()) else {
            return (options, option_groups);
        };

        for item in items {
            if let Some(obj) = item.as_object() {
                let grouped = obj
                    .get("options")
                    .and_then(|v| v.as_array())
                    .or_else(|| obj.get("choices").and_then(|v| v.as_array()))
                    .or_else(|| obj.get("items").and_then(|v| v.as_array()));
                if let Some(group_items) = grouped {
                    let group_options = group_items
                        .iter()
                        .filter_map(Self::parse_config_option_choice)
                        .collect::<Vec<_>>();
                    if !group_options.is_empty() {
                        let label = obj
                            .get("label")
                            .and_then(|v| v.as_str())
                            .or_else(|| obj.get("name").and_then(|v| v.as_str()))
                            .or_else(|| obj.get("groupLabel").and_then(|v| v.as_str()))
                            .or_else(|| obj.get("group_label").and_then(|v| v.as_str()))
                            .unwrap_or("group")
                            .to_string();
                        option_groups.push(AcpConfigOptionGroup {
                            label,
                            options: group_options,
                        });
                    }
                    continue;
                }
            }

            if let Some(choice) = Self::parse_config_option_choice(item) {
                options.push(choice);
            }
        }

        (options, option_groups)
    }

    fn parse_config_option_info(value: Value) -> Option<AcpConfigOptionInfo> {
        let obj = value.as_object()?;
        let option_id = obj
            .get("optionId")
            .and_then(|v| v.as_str())
            .or_else(|| obj.get("option_id").and_then(|v| v.as_str()))
            .or_else(|| obj.get("id").and_then(|v| v.as_str()))
            .or_else(|| obj.get("key").and_then(|v| v.as_str()))
            .or_else(|| obj.get("name").and_then(|v| v.as_str()))
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())?;
        let category = obj
            .get("category")
            .and_then(|v| v.as_str())
            .or_else(|| obj.get("kind").and_then(|v| v.as_str()))
            .or_else(|| obj.get("group").and_then(|v| v.as_str()))
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        let name = obj
            .get("name")
            .and_then(|v| v.as_str())
            .or_else(|| obj.get("label").and_then(|v| v.as_str()))
            .or_else(|| obj.get("title").and_then(|v| v.as_str()))
            .unwrap_or(&option_id)
            .to_string();
        let description = obj
            .get("description")
            .and_then(|v| v.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        let current_value = obj
            .get("currentValue")
            .or_else(|| obj.get("current_value"))
            .or_else(|| obj.get("value"))
            .or_else(|| obj.get("selectedValue"))
            .or_else(|| obj.get("selected_value"))
            .cloned()
            .filter(|v| !v.is_null());
        let (options, option_groups) = Self::parse_config_option_option_groups(
            obj.get("options")
                .or_else(|| obj.get("choices"))
                .or_else(|| obj.get("values")),
        );
        Some(AcpConfigOptionInfo {
            option_id,
            category,
            name,
            description,
            current_value,
            options,
            option_groups,
            raw: Some(Value::Object(obj.clone())),
        })
    }

    fn parse_config_options(value: &Value) -> Vec<AcpConfigOptionInfo> {
        let mut rows = Vec::<Value>::new();
        for key in [
            "sessionConfigOptions",
            "session_config_options",
            "configOptions",
            "config_options",
            "options",
        ] {
            let found = Self::rows_from_key(value, key);
            if !found.is_empty() {
                rows = found;
                break;
            }
        }

        if rows.is_empty() {
            if let Some(found) = Self::find_object_by_keys(
                value,
                &[
                    "sessionConfigOptions",
                    "session_config_options",
                    "configOptions",
                    "config_options",
                ],
            ) {
                rows = found.into_values().collect::<Vec<_>>();
            }
        }

        let mut options = rows
            .into_iter()
            .filter_map(Self::parse_config_option_info)
            .collect::<Vec<_>>();
        options.sort_by(|a, b| a.option_id.cmp(&b.option_id));
        options
    }

    fn parse_config_values(value: &Value) -> HashMap<String, Value> {
        let mut out = HashMap::<String, Value>::new();
        for key in [
            "sessionConfig",
            "session_config",
            "configValues",
            "config_values",
            "selectedConfigOptions",
            "selected_config_options",
            "currentConfigOptions",
            "current_config_options",
            "config",
        ] {
            let Some(found) = Self::find_object_by_keys(value, &[key]) else {
                continue;
            };
            for (option_id, option_value) in found {
                if option_id.trim().is_empty() || option_value.is_null() {
                    continue;
                }
                out.insert(option_id, option_value);
            }
        }
        out
    }

    fn normalize_config_category(category: Option<&str>, option_id: &str) -> String {
        let from_category = category
            .map(|v| v.trim().to_lowercase())
            .filter(|v| !v.is_empty());
        if let Some(category) = from_category {
            return category;
        }
        option_id.trim().to_lowercase()
    }

    fn extract_config_value_as_id(value: &Value) -> Option<String> {
        if let Some(raw) = value.as_str() {
            let trimmed = raw.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
        let obj = value.as_object()?;
        obj.get("id")
            .or_else(|| obj.get("modeId"))
            .or_else(|| obj.get("mode_id"))
            .or_else(|| obj.get("modelId"))
            .or_else(|| obj.get("model_id"))
            .or_else(|| obj.get("value"))
            .and_then(Self::json_value_to_trimmed_string)
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

        let config_options = Self::parse_config_options(value);
        let mut config_values = Self::parse_config_values(value);
        for option in &config_options {
            if let Some(current_value) = option.current_value.clone() {
                config_values.insert(option.option_id.clone(), current_value);
            }
        }

        let current_mode_id = if current_mode_id.is_some() {
            current_mode_id
        } else {
            let from_config = config_options.iter().find_map(|option| {
                let category =
                    Self::normalize_config_category(option.category.as_deref(), &option.option_id);
                if category != "mode" {
                    return None;
                }
                let value = option
                    .current_value
                    .as_ref()
                    .or_else(|| config_values.get(&option.option_id))?;
                Self::extract_config_value_as_id(value)
            });
            Self::normalize_current_mode_id(from_config, &modes)
        };

        let current_model_id = if current_model_id.is_some() {
            current_model_id
        } else {
            let from_config = config_options.iter().find_map(|option| {
                let category =
                    Self::normalize_config_category(option.category.as_deref(), &option.option_id);
                if category != "model" {
                    return None;
                }
                let value = option
                    .current_value
                    .as_ref()
                    .or_else(|| config_values.get(&option.option_id))?;
                Self::extract_config_value_as_id(value)
            });
            Self::normalize_current_model_id(from_config, &models)
        };

        if models.is_empty()
            && modes.is_empty()
            && config_options.is_empty()
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
                "ACP session metadata parsed: models_count={}, modes_count={}, config_options_count={}, current_model_id={:?}, current_mode_id={:?}",
                models.len(),
                modes.len(),
                config_options.len(),
                current_model_id,
                current_mode_id
            );
        }

        AcpSessionMetadata {
            models,
            current_model_id,
            modes,
            current_mode_id,
            config_options,
            config_values,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{AcpClient, AcpTransport};
    use crate::ai::codex_manager::{
        AcpAuthMethod, AcpContentEncodingMode, AcpInitializationState, AppServerRequestError,
        CodexNotification, CodexServerRequest, JsonRpcError,
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
    fn normalize_cwd_for_request_should_keep_absolute_path() {
        let cwd = AcpClient::normalize_cwd_for_request("/tmp/workspace")
            .expect("absolute path should normalize");
        assert_eq!(cwd, "/tmp/workspace");
    }

    #[test]
    fn normalize_cwd_for_request_should_convert_file_uri_to_absolute_path() {
        let cwd = AcpClient::normalize_cwd_for_request("file:///tmp/workspace")
            .expect("file uri should normalize");
        assert_eq!(cwd, "/tmp/workspace");
    }

    #[test]
    fn normalize_cwd_for_request_should_reject_relative_path() {
        let err = AcpClient::normalize_cwd_for_request("relative/path")
            .expect_err("relative path should fail");
        assert!(err.contains("绝对路径"));
    }

    #[tokio::test]
    async fn session_new_should_send_absolute_path_cwd() {
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
        assert_eq!(params.get("cwd").and_then(|v| v.as_str()), Some("/tmp/workspace"));
        assert_eq!(
            params
                .get("mcpServers")
                .and_then(|v| v.as_array())
                .map(|arr| arr.len()),
            Some(0)
        );
    }

    #[tokio::test]
    async fn session_load_should_send_absolute_path_cwd() {
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
        assert_eq!(params.get("cwd").and_then(|v| v.as_str()), Some("/tmp/workspace"));
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
    async fn session_set_config_option_should_send_option_id_and_value() {
        let transport = Arc::new(MockTransport::new(vec![Ok(json!({}))], None));
        let client = AcpClient::new_with_transport(transport.clone());
        client
            .session_set_config_option(
                "session-1",
                "thought_level",
                json!({
                    "id": "high"
                }),
            )
            .await
            .expect("session/set_config_option should succeed");

        let params = transport
            .first_request_params("session/set_config_option")
            .await
            .expect("session/set_config_option params should exist");
        assert_eq!(
            params.get("sessionId").and_then(|v| v.as_str()),
            Some("session-1")
        );
        assert_eq!(
            params.get("optionId").and_then(|v| v.as_str()),
            Some("thought_level")
        );
        assert_eq!(
            params
                .get("value")
                .and_then(|v| v.get("id"))
                .and_then(|v| v.as_str()),
            Some("high")
        );
    }

    #[tokio::test]
    async fn terminal_create_should_send_session_and_tool_call_id() {
        let transport = Arc::new(MockTransport::new(
            vec![Ok(json!({
                "terminalId": "term-1"
            }))],
            None,
        ));
        let client = AcpClient::new_with_transport(transport.clone());
        let terminal_id = client
            .terminal_create("session-1", "call-1")
            .await
            .expect("terminal/create should succeed");
        assert_eq!(terminal_id, "term-1");

        let params = transport
            .first_request_params("terminal/create")
            .await
            .expect("terminal/create params should exist");
        assert_eq!(
            params.get("sessionId").and_then(|v| v.as_str()),
            Some("session-1")
        );
        assert_eq!(
            params.get("toolCallId").and_then(|v| v.as_str()),
            Some("call-1")
        );
    }

    #[tokio::test]
    async fn terminal_create_should_accept_id_alias_in_response() {
        let transport = Arc::new(MockTransport::new(
            vec![Ok(json!({ "id": "term-2" }))],
            None,
        ));
        let client = AcpClient::new_with_transport(transport);
        let terminal_id = client
            .terminal_create("session-2", "call-2")
            .await
            .expect("terminal/create should accept id fallback");
        assert_eq!(terminal_id, "term-2");
    }

    #[tokio::test]
    async fn terminal_create_should_fail_when_response_missing_terminal_id() {
        let transport = Arc::new(MockTransport::new(vec![Ok(json!({}))], None));
        let client = AcpClient::new_with_transport(transport);
        let err = client
            .terminal_create("session-3", "call-3")
            .await
            .expect_err("terminal/create should fail when terminal id missing");
        assert!(err.contains("terminalId"));
    }

    #[tokio::test]
    async fn terminal_release_should_send_terminal_id() {
        let transport = Arc::new(MockTransport::new(vec![Ok(json!({}))], None));
        let client = AcpClient::new_with_transport(transport.clone());
        client
            .terminal_release("term-9")
            .await
            .expect("terminal/release should succeed");

        let params = transport
            .first_request_params("terminal/release")
            .await
            .expect("terminal/release params should exist");
        assert_eq!(
            params.get("terminalId").and_then(|v| v.as_str()),
            Some("term-9")
        );
    }

    #[test]
    fn parse_session_metadata_should_parse_grouped_config_options() {
        let payload = json!({
            "configOptions": [
                {
                    "optionId": "mode",
                    "category": "mode",
                    "name": "模式",
                    "currentValue": "code",
                    "options": [
                        {
                            "label": "常用",
                            "options": [
                                {
                                    "value": "code",
                                    "label": "代码"
                                },
                                {
                                    "value": {
                                        "id": "plan"
                                    },
                                    "label": "规划"
                                }
                            ]
                        }
                    ]
                }
            ],
            "selectedConfigOptions": {
                "mode": "code"
            }
        });

        let metadata = AcpClient::parse_session_metadata(&payload);
        assert_eq!(metadata.config_options.len(), 1);
        let mode = &metadata.config_options[0];
        assert_eq!(mode.option_id, "mode");
        assert_eq!(mode.category.as_deref(), Some("mode"));
        assert_eq!(mode.current_value, Some(json!("code")));
        assert_eq!(mode.option_groups.len(), 1);
        assert_eq!(mode.option_groups[0].label, "常用");
        assert_eq!(mode.option_groups[0].options.len(), 2);
        assert_eq!(
            mode.option_groups[0].options[1]
                .value
                .get("id")
                .and_then(|v| v.as_str()),
            Some("plan")
        );
        assert_eq!(metadata.config_values.get("mode"), Some(&json!("code")));
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
        assert!(client.supports_content_type("resource_link").await);
        assert!(!client.supports_content_type("image").await);
    }

    #[tokio::test]
    async fn prompt_encoding_mode_should_follow_initialization_state() {
        let mut state = AcpInitializationState {
            negotiated_protocol_version: Some(1),
            ..Default::default()
        };
        state.prompt_capabilities.encoding_mode = AcpContentEncodingMode::New;
        let transport = Arc::new(MockTransport::new(vec![], Some(state)));
        let client = AcpClient::new_with_transport(transport);

        assert_eq!(
            client.prompt_encoding_mode().await,
            AcpContentEncodingMode::New
        );
    }

    #[test]
    fn prompt_image_audio_builder_should_follow_encoding_mode() {
        let new_image = AcpClient::build_prompt_image_part(
            AcpContentEncodingMode::New,
            "image/png".to_string(),
            "AQID".to_string(),
        );
        assert_eq!(
            new_image.get("type").and_then(|v| v.as_str()),
            Some("image")
        );
        assert_eq!(new_image.get("data").and_then(|v| v.as_str()), Some("AQID"));
        assert!(new_image.get("url").is_none());

        let legacy_image = AcpClient::build_prompt_image_part(
            AcpContentEncodingMode::Legacy,
            "image/png".to_string(),
            "AQID".to_string(),
        );
        assert!(legacy_image
            .get("url")
            .and_then(|v| v.as_str())
            .is_some_and(|v| v.starts_with("data:image/png;base64,AQID")));
        assert!(legacy_image.get("data").is_none());

        let new_audio = AcpClient::build_prompt_audio_part(
            AcpContentEncodingMode::New,
            "audio/wav".to_string(),
            "BAUG".to_string(),
        );
        assert_eq!(
            new_audio.get("type").and_then(|v| v.as_str()),
            Some("audio")
        );
        assert_eq!(new_audio.get("data").and_then(|v| v.as_str()), Some("BAUG"));
        assert!(new_audio.get("url").is_none());

        let legacy_audio = AcpClient::build_prompt_audio_part(
            AcpContentEncodingMode::Legacy,
            "audio/wav".to_string(),
            "BAUG".to_string(),
        );
        assert!(legacy_audio
            .get("url")
            .and_then(|v| v.as_str())
            .is_some_and(|v| v.starts_with("data:audio/wav;base64,BAUG")));
        assert!(legacy_audio.get("data").is_none());
    }

    #[test]
    fn prompt_resource_link_builder_should_support_new_and_legacy_shapes() {
        let new_part = AcpClient::build_prompt_resource_link_part(
            AcpContentEncodingMode::New,
            "file:///tmp/a.txt".to_string(),
            "a.txt".to_string(),
            Some("text/plain".to_string()),
        );
        assert_eq!(
            new_part.get("uri").and_then(|v| v.as_str()),
            Some("file:///tmp/a.txt")
        );
        assert_eq!(new_part.get("name").and_then(|v| v.as_str()), Some("a.txt"));
        assert_eq!(
            new_part.get("mimeType").and_then(|v| v.as_str()),
            Some("text/plain")
        );
        assert!(new_part.get("resource").is_none());

        let legacy_part = AcpClient::build_prompt_resource_link_part(
            AcpContentEncodingMode::Legacy,
            "file:///tmp/b.txt".to_string(),
            "b.txt".to_string(),
            None,
        );
        assert_eq!(
            legacy_part
                .get("resource")
                .and_then(|v| v.get("uri"))
                .and_then(|v| v.as_str()),
            Some("file:///tmp/b.txt")
        );
        assert_eq!(
            legacy_part
                .get("resource")
                .and_then(|v| v.get("name"))
                .and_then(|v| v.as_str()),
            Some("b.txt")
        );
    }
}
