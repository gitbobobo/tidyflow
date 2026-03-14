use crate::ai::acp::auth;
use crate::ai::acp::metadata_parser;
use crate::ai::acp::prompt_parts;
use crate::ai::acp::transport::AcpTransport;
use crate::ai::codex::manager::{
    AcpContentEncodingMode, AcpInitializationState, AppServerRequestError, CodexAppServerManager,
    CodexNotification, CodexServerRequest,
};
use crate::ai::shared::json_search::normalize_optional_token as shared_normalize_optional_token;
use chrono::{DateTime, Utc};
use serde_json::Value;
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use tokio::sync::broadcast;

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

impl AcpSessionMetadata {
    pub fn is_empty(&self) -> bool {
        self.models.is_empty()
            && self.current_model_id.is_none()
            && self.modes.is_empty()
            && self.current_mode_id.is_none()
            && self.config_options.is_empty()
            && self.config_values.is_empty()
    }
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
        prompt_parts::build_prompt_text_part(text)
    }

    pub fn build_prompt_image_part(
        mode: AcpContentEncodingMode,
        mime_type: String,
        data_base64: String,
    ) -> Value {
        prompt_parts::build_prompt_image_part(mode, mime_type, data_base64)
    }

    pub fn build_prompt_image_part_new(mime_type: String, data_base64: String) -> Value {
        prompt_parts::build_prompt_image_part_new(mime_type, data_base64)
    }

    pub fn build_prompt_image_part_legacy(mime_type: String, data_url: String) -> Value {
        prompt_parts::build_prompt_image_part_legacy(mime_type, data_url)
    }

    pub fn build_prompt_audio_part(
        mode: AcpContentEncodingMode,
        mime_type: String,
        data_base64: String,
    ) -> Value {
        prompt_parts::build_prompt_audio_part(mode, mime_type, data_base64)
    }

    pub fn build_prompt_audio_part_new(mime_type: String, data_base64: String) -> Value {
        prompt_parts::build_prompt_audio_part_new(mime_type, data_base64)
    }

    pub fn build_prompt_audio_part_legacy(mime_type: String, data_url: String) -> Value {
        prompt_parts::build_prompt_audio_part_legacy(mime_type, data_url)
    }

    pub fn build_prompt_resource_text_part(
        uri: String,
        name: String,
        mime_type: String,
        text: String,
    ) -> Value {
        prompt_parts::build_prompt_resource_text_part(uri, name, mime_type, text)
    }

    pub fn build_prompt_resource_blob_part(
        uri: String,
        name: String,
        mime_type: String,
        blob_base64: String,
    ) -> Value {
        prompt_parts::build_prompt_resource_blob_part(uri, name, mime_type, blob_base64)
    }

    pub fn build_prompt_resource_link_part(
        mode: AcpContentEncodingMode,
        uri: String,
        name: String,
        mime_type: Option<String>,
    ) -> Value {
        prompt_parts::build_prompt_resource_link_part(mode, uri, name, mime_type)
    }

    pub fn build_prompt_resource_link_part_new(
        uri: String,
        name: String,
        mime_type: Option<String>,
    ) -> Value {
        prompt_parts::build_prompt_resource_link_part_new(uri, name, mime_type)
    }

    pub fn build_prompt_resource_link_part_legacy(uri: String, name: String) -> Value {
        prompt_parts::build_prompt_resource_link_part_legacy(uri, name)
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
        auth::is_auth_required_error(error)
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
        directory: &str,
        cursor: Option<&str>,
    ) -> Result<(Vec<AcpSessionSummary>, Option<String>), String> {
        let cwd = Self::normalize_cwd_for_request(directory)?;
        let mut params = serde_json::json!({ "cwd": cwd });
        if let Some(value) = cursor {
            if !value.is_empty() {
                params["cursor"] = Value::String(value.to_string());
            }
        }
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
    ) -> Result<AcpSessionMetadata, String> {
        let option_id = option_id.trim();
        if option_id.is_empty() {
            return Err("session/set_config_option requires non-empty option_id".to_string());
        }
        let request_value = Self::config_option_request_value(&value)?;
        let stable_result = self
            .send_request_with_auth_retry(
                "session/set_config_option",
                Some(serde_json::json!({
                    "sessionId": session_id,
                    "configId": option_id,
                    "value": request_value
                })),
            )
            .await;

        match stable_result {
            Ok(result) => Ok(Self::parse_session_metadata(&result)),
            Err(err) if Self::should_retry_legacy_set_config_option(&err) => {
                let legacy_result = self
                    .send_request_with_auth_retry(
                        "session/set_config_option",
                        Some(serde_json::json!({
                            "sessionId": session_id,
                            "optionId": option_id,
                            "value": value
                        })),
                    )
                    .await?;
                Ok(Self::parse_session_metadata(&legacy_result))
            }
            Err(err) => Err(err),
        }
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
            return shared_normalize_optional_token(Some(text.to_string()));
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

    fn config_option_request_value(value: &Value) -> Result<Value, String> {
        match value {
            Value::String(text) => {
                let trimmed = text.trim();
                if trimmed.is_empty() {
                    Err("session/set_config_option requires non-empty scalar value".to_string())
                } else {
                    Ok(Value::String(trimmed.to_string()))
                }
            }
            Value::Bool(flag) => Ok(Value::Bool(*flag)),
            Value::Number(number) => Ok(Value::String(number.to_string())),
            Value::Object(map) => {
                for key in ["id", "value", "modeId", "mode_id", "modelId", "model_id"] {
                    if let Some(next) = map.get(key) {
                        return Self::config_option_request_value(next);
                    }
                }
                Err("session/set_config_option requires scalar-compatible value".to_string())
            }
            _ => Err("session/set_config_option requires scalar-compatible value".to_string()),
        }
    }

    fn should_retry_legacy_set_config_option(error: &str) -> bool {
        let normalized = error.trim().to_lowercase();
        let mentions_config_id = normalized.contains("configid");
        let mentions_option_id = normalized.contains("optionid");
        let is_parameter_shape_error = normalized.contains("missing")
            || normalized.contains("required")
            || normalized.contains("unknown")
            || normalized.contains("unexpected")
            || normalized.contains("unrecognized")
            || normalized.contains("not allowed")
            || normalized.contains("invalid params")
            || normalized.contains("invalid request");
        (mentions_config_id || mentions_option_id) && is_parameter_shape_error
    }

    fn parse_rfc3339_millis(raw: &str) -> Option<i64> {
        DateTime::parse_from_rfc3339(raw)
            .ok()
            .map(|dt| dt.with_timezone(&Utc).timestamp_millis())
    }

    fn parse_session_metadata(value: &Value) -> AcpSessionMetadata {
        metadata_parser::parse_session_metadata(value)
    }
}

#[cfg(test)]
mod tests;
