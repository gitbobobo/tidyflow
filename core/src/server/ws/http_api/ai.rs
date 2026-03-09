use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use serde::Deserialize;

use super::auth::ensure_http_authorized;
use super::common::{json_from_server_message, ApiError, WorkspaceQueryContext};

#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct AiWorkspacePath {
    project: String,
    workspace: String,
    ai_tool: String,
}

#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct WorkspacePath {
    project: String,
    workspace: String,
}

#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct AiSessionPath {
    project: String,
    workspace: String,
    ai_tool: String,
    session_id: String,
}

#[derive(Debug, Deserialize, Default)]
pub(in crate::server::ws) struct SessionListQuery {
    #[serde(default)]
    limit: Option<u32>,
    #[serde(default)]
    cursor: Option<String>,
    #[serde(default)]
    ai_tool: Option<String>,
    #[serde(default)]
    token: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub(in crate::server::ws) struct SessionMessagesQuery {
    #[serde(default)]
    before_message_id: Option<String>,
    #[serde(default)]
    limit: Option<i64>,
    #[serde(default)]
    token: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub(in crate::server::ws) struct OptionalSessionQuery {
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    token: Option<String>,
}

pub(in crate::server::ws) async fn ai_sessions_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<WorkspacePath>,
    Query(query): Query<SessionListQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let response = crate::server::handlers::ai::session::query_ai_session_list(
        &ctx.app_state,
        &ctx.ai_state,
        &path.project,
        &path.workspace,
        query.ai_tool.as_deref(),
        query.cursor.as_deref(),
        query.limit,
    )
    .await
    .map_err(|e| qctx.map_query_error(e))?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn ai_session_messages_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<AiSessionPath>,
    Query(query): Query<SessionMessagesQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx =
        WorkspaceQueryContext::new(&path.project, &path.workspace).with_session(&path.session_id);
    let response = crate::server::handlers::ai::session::query_ai_session_messages(
        &ctx.app_state,
        &ctx.ai_state,
        &path.project,
        &path.workspace,
        &path.ai_tool,
        &path.session_id,
        query.before_message_id,
        query.limit,
    )
    .await
    .map_err(|e| qctx.map_query_error(e))?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn ai_session_status_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<AiSessionPath>,
    Query(query): Query<OptionalSessionQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx =
        WorkspaceQueryContext::new(&path.project, &path.workspace).with_session(&path.session_id);
    let response = crate::server::handlers::ai::session::query_ai_session_status(
        &ctx.app_state,
        &ctx.ai_state,
        &path.project,
        &path.workspace,
        &path.ai_tool,
        &path.session_id,
    )
    .await
    .map_err(|e| qctx.map_query_error(e))?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn ai_provider_list_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<AiWorkspacePath>,
    Query(query): Query<OptionalSessionQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let response = crate::server::handlers::ai::session::query_ai_provider_list(
        &ctx.app_state,
        &ctx.ai_state,
        &path.project,
        &path.workspace,
        &path.ai_tool,
    )
    .await
    .map_err(|e| qctx.map_query_error(e))?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn ai_agent_list_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<AiWorkspacePath>,
    Query(query): Query<OptionalSessionQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let response = crate::server::handlers::ai::session::query_ai_agent_list(
        &ctx.app_state,
        &ctx.ai_state,
        &path.project,
        &path.workspace,
        &path.ai_tool,
    )
    .await
    .map_err(|e| qctx.map_query_error(e))?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn ai_session_slash_commands_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<AiWorkspacePath>,
    Query(query): Query<OptionalSessionQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let response = crate::server::handlers::ai::session::query_ai_slash_commands(
        &ctx.app_state,
        &ctx.ai_state,
        &path.project,
        &path.workspace,
        &path.ai_tool,
        query.session_id,
    )
    .await
    .map_err(|e| qctx.map_query_error(e))?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn ai_session_config_options_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<AiWorkspacePath>,
    Query(query): Query<OptionalSessionQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let response = crate::server::handlers::ai::session::query_ai_session_config_options(
        &ctx.app_state,
        &ctx.ai_state,
        &path.project,
        &path.workspace,
        &path.ai_tool,
        query.session_id,
    )
    .await
    .map_err(|e| qctx.map_query_error(e))?;
    json_from_server_message(response)
}
