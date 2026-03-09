use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::Serialize;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};

use crate::server::context::{ConnectionMeta, HandlerContext};
use crate::server::protocol::ServerMessage;

#[derive(Debug)]
pub(in crate::server::ws) enum ApiError {
    Unauthorized,
    BadRequest(String),
    NotFound(String),
    Internal(String),
}

#[derive(Debug, Serialize)]
struct ApiErrorBody {
    code: String,
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    project: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    workspace: Option<String>,
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, code, message) = match self {
            ApiError::Unauthorized => (
                StatusCode::UNAUTHORIZED,
                "unauthorized".to_string(),
                "unauthorized".to_string(),
            ),
            ApiError::BadRequest(message) => {
                (StatusCode::BAD_REQUEST, "bad_request".to_string(), message)
            }
            ApiError::NotFound(message) => {
                (StatusCode::NOT_FOUND, "not_found".to_string(), message)
            }
            ApiError::Internal(message) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal_error".to_string(),
                message,
            ),
        };

        (
            status,
            Json(ApiErrorBody {
                code,
                message,
                project: None,
                workspace: None,
            }),
        )
            .into_response()
    }
}

pub(in crate::server::ws) fn json_from_server_message(
    message: ServerMessage,
) -> Result<Json<serde_json::Value>, ApiError> {
    serde_json::to_value(message)
        .map(Json)
        .map_err(|e| ApiError::Internal(format!("serialize response failed: {}", e)))
}

pub(in crate::server::ws) fn map_query_error(err: String) -> ApiError {
    let lower = err.to_ascii_lowercase();
    if lower.contains("not found") || lower.contains("not_found") {
        return ApiError::NotFound(err);
    }
    if lower.contains("unsupported")
        || lower.contains("invalid")
        || lower.contains("missing")
        || lower.contains("must be")
    {
        return ApiError::BadRequest(err);
    }
    ApiError::Internal(err)
}

/// 多工作区 HTTP 查询上下文。
///
/// 所有需要 `(project, workspace)` 边界的 HTTP 处理器共享此结构，
/// 避免各 domain 各自手写字段解析导致漂移。
/// session_id 和 cycle_id 在各自 domain 的上下文中按需填入。
#[derive(Debug, Clone)]
pub(in crate::server::ws) struct WorkspaceQueryContext {
    pub project: String,
    pub workspace: String,
    pub session_id: Option<String>,
    pub cycle_id: Option<String>,
}

impl WorkspaceQueryContext {
    /// 从 path 参数构建基础工作区上下文。
    pub fn new(project: impl Into<String>, workspace: impl Into<String>) -> Self {
        Self {
            project: project.into(),
            workspace: workspace.into(),
            session_id: None,
            cycle_id: None,
        }
    }

    /// 附加 session_id（AI 相关查询）。
    pub fn with_session(mut self, session_id: impl Into<String>) -> Self {
        let id = session_id.into();
        if !id.is_empty() {
            self.session_id = Some(id);
        }
        self
    }

    /// 附加 cycle_id（Evolution 相关查询）。
    pub fn with_cycle(mut self, cycle_id: impl Into<String>) -> Self {
        let id = cycle_id.into();
        if !id.is_empty() {
            self.cycle_id = Some(id);
        }
        self
    }

    /// 将上下文字段注入 ApiError::NotFound，携带归属信息。
    pub fn not_found_error(&self, msg: impl Into<String>) -> ApiError {
        ApiError::NotFound(format!(
            "[{}/{}] {}",
            self.project,
            self.workspace,
            msg.into()
        ))
    }

    /// 将上下文字段注入 ApiError::BadRequest，携带归属信息。
    pub fn bad_request_error(&self, msg: impl Into<String>) -> ApiError {
        ApiError::BadRequest(format!(
            "[{}/{}] {}",
            self.project,
            self.workspace,
            msg.into()
        ))
    }

    /// 将查询错误字符串映射到携带工作区归属信息的 ApiError。
    /// 与顶层 map_query_error 相同的语义，但错误消息前缀包含 project/workspace 上下文。
    pub fn map_query_error(&self, err: String) -> ApiError {
        let lower = err.to_ascii_lowercase();
        if lower.contains("not found") || lower.contains("not_found") {
            return self.not_found_error(err);
        }
        if lower.contains("unsupported")
            || lower.contains("invalid")
            || lower.contains("missing")
            || lower.contains("must be")
        {
            return self.bad_request_error(err);
        }
        ApiError::Internal(err)
    }
}

pub(in crate::server::ws) fn build_http_handler_context(
    ctx: &crate::server::ws::transport::bootstrap::AppContext,
) -> HandlerContext {
    let (agg_tx, _agg_rx) = mpsc::channel::<(String, Vec<u8>)>(1);
    let (cmd_output_tx, _cmd_output_rx) = mpsc::channel::<ServerMessage>(1);

    HandlerContext {
        app_state: ctx.app_state.clone(),
        terminal_registry: ctx.terminal_registry.clone(),
        save_tx: ctx.save_tx.clone(),
        scrollback_tx: ctx.scrollback_tx.clone(),
        subscribed_terms: Arc::new(Mutex::new(HashMap::new())),
        agg_tx,
        running_commands: ctx.running_commands.clone(),
        running_ai_tasks: ctx.running_ai_tasks.clone(),
        cmd_output_tx,
        task_broadcast_tx: ctx.task_broadcast_tx.clone(),
        task_history: ctx.task_history.clone(),
        conn_meta: ConnectionMeta {
            conn_id: "http-api".to_string(),
            token_id: None,
            is_remote: false,
            device_name: None,
        },
        remote_sub_registry: ctx.remote_sub_registry.clone(),
        ai_state: ctx.ai_state.clone(),
    }
}
