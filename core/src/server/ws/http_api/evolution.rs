use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use serde::Deserialize;

use super::auth::ensure_http_authorized;
use super::common::{
    build_http_handler_context, json_from_server_message, map_query_error, ApiError,
};

#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct EvolutionWorkspacePath {
    project: String,
    workspace: String,
}

#[derive(Debug, Deserialize, Default)]
pub(in crate::server::ws) struct EvolutionSnapshotQuery {
    #[serde(default)]
    project: Option<String>,
    #[serde(default)]
    workspace: Option<String>,
    #[serde(default)]
    token: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub(in crate::server::ws) struct EvolutionTokenQuery {
    #[serde(default)]
    token: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub(in crate::server::ws) struct EvolutionStageChatQuery {
    #[serde(default)]
    cycle_id: Option<String>,
    #[serde(default)]
    stage: Option<String>,
    #[serde(default)]
    token: Option<String>,
}

pub(in crate::server::ws) async fn evolution_snapshot_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Query(query): Query<EvolutionSnapshotQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let handler_ctx = build_http_handler_context(&ctx);

    let response = crate::server::handlers::evolution::query_evolution_snapshot(
        query.project.as_deref(),
        query.workspace.as_deref(),
        &handler_ctx,
    )
    .await
    .map_err(map_query_error)?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn evolution_agent_profile_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<EvolutionWorkspacePath>,
    Query(query): Query<EvolutionTokenQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let handler_ctx = build_http_handler_context(&ctx);

    let response = crate::server::handlers::evolution::query_evolution_agent_profile(
        &path.project,
        &path.workspace,
        &handler_ctx,
    )
    .await
    .map_err(map_query_error)?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn evolution_cycle_history_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<EvolutionWorkspacePath>,
    Query(query): Query<EvolutionTokenQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let handler_ctx = build_http_handler_context(&ctx);

    let response = crate::server::handlers::evolution::query_evolution_cycle_history(
        &path.project,
        &path.workspace,
        &handler_ctx,
    )
    .await
    .map_err(map_query_error)?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn evolution_stage_chat_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<EvolutionWorkspacePath>,
    Query(query): Query<EvolutionStageChatQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;

    let cycle_id = query
        .cycle_id
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::BadRequest("missing query parameter: cycle_id".to_string()))?;
    let stage = query
        .stage
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::BadRequest("missing query parameter: stage".to_string()))?;

    let response = crate::server::handlers::evolution::query_evolution_stage_chat(
        &path.project,
        &path.workspace,
        cycle_id,
        stage,
    )
    .await
    .map_err(map_query_error)?;
    json_from_server_message(response)
}
