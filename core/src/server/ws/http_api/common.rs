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

        (status, Json(ApiErrorBody { code, message })).into_response()
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
