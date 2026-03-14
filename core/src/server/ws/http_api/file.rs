use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use base64::Engine;
use serde::{Deserialize, Serialize};

use super::auth::ensure_http_authorized;
use super::common::{json_from_server_message, ApiError, WorkspaceQueryContext};

#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct WorkspacePath {
    project: String,
    workspace: String,
}

#[derive(Debug, Deserialize, Default)]
pub(in crate::server::ws) struct FileListQuery {
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    token: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub(in crate::server::ws) struct FileIndexQuery {
    #[serde(default)]
    query: Option<String>,
    #[serde(default)]
    token: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub(in crate::server::ws) struct FileContentQuery {
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    token: Option<String>,
}

#[derive(Debug, Serialize)]
pub(in crate::server::ws) struct FileReadHTTPResponse {
    #[serde(rename = "type")]
    msg_type: &'static str,
    project: String,
    workspace: String,
    path: String,
    size: u64,
    content_base64: String,
}

pub(in crate::server::ws) async fn file_list_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<WorkspacePath>,
    Query(query): Query<FileListQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let response = crate::server::handlers::file::query::query_file_list(
        &ctx.app_state,
        &path.project,
        &path.workspace,
        query.path.as_deref().unwrap_or("."),
    )
    .await
    .map_err(|e| {
        qctx.map_query_error(match e {
            crate::server::protocol::ServerMessage::Error { message, .. } => message,
            _ => "file list failed".to_string(),
        })
    })?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn file_index_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<WorkspacePath>,
    Query(query): Query<FileIndexQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let response = crate::server::handlers::file::query::query_file_index(
        &ctx.app_state,
        &path.project,
        &path.workspace,
        query.query.as_deref(),
    )
    .await
    .map_err(|e| {
        qctx.map_query_error(match e {
            crate::server::protocol::ServerMessage::Error { message, .. } => message,
            _ => "file index failed".to_string(),
        })
    })?;
    json_from_server_message(response)
}

#[derive(Debug, Deserialize, Default)]
pub(in crate::server::ws) struct FileSearchQuery {
    #[serde(default)]
    query: Option<String>,
    #[serde(default)]
    case_sensitive: Option<bool>,
    #[serde(default)]
    token: Option<String>,
}

pub(in crate::server::ws) async fn file_search_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<WorkspacePath>,
    Query(query): Query<FileSearchQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let search_query = query.query.as_deref().unwrap_or("");
    let case_sensitive = query.case_sensitive.unwrap_or(false);
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let response = crate::server::handlers::file::query::query_file_content_search(
        &ctx.app_state,
        &path.project,
        &path.workspace,
        search_query,
        case_sensitive,
    )
    .await
    .map_err(|e| {
        qctx.map_query_error(match e {
            crate::server::protocol::ServerMessage::Error { message, .. } => message,
            _ => "file search failed".to_string(),
        })
    })?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn file_content_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<WorkspacePath>,
    Query(query): Query<FileContentQuery>,
) -> Result<Json<FileReadHTTPResponse>, ApiError> {
    let _identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let read_path = query
        .path
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| ApiError::BadRequest("missing path".to_string()))?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let response = crate::server::handlers::file::read_write::query_file_read(
        &ctx.app_state,
        &path.project,
        &path.workspace,
        read_path,
    )
    .await
    .map_err(|e| {
        qctx.map_query_error(match e {
            crate::server::protocol::ServerMessage::Error { message, .. } => message,
            _ => "file read failed".to_string(),
        })
    })?;

    match response {
        crate::server::protocol::ServerMessage::FileReadResult {
            project,
            workspace,
            path,
            content,
            size,
        } => Ok(Json(FileReadHTTPResponse {
            msg_type: "file_read_result",
            project,
            workspace,
            path,
            size,
            content_base64: BASE64_STANDARD.encode(content),
        })),
        _ => Err(ApiError::Internal(
            "unexpected file read response type".to_string(),
        )),
    }
}
