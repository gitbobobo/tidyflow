use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use serde::Deserialize;

use super::auth::ensure_http_authorized;
use super::common::{
    build_http_handler_context, json_from_server_message, map_query_error, ApiError,
    WorkspaceQueryContext,
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

pub(in crate::server::ws) async fn evolution_snapshot_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Query(query): Query<EvolutionSnapshotQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let handler_ctx = build_http_handler_context(&ctx, Some(&identity));

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
    let identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let handler_ctx = build_http_handler_context(&ctx, Some(&identity));

    let response = crate::server::handlers::evolution::query_evolution_agent_profile(
        &path.project,
        &path.workspace,
        &handler_ctx,
    )
    .await
    .map_err(|e| qctx.map_query_error(e))?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn evolution_cycle_history_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<EvolutionWorkspacePath>,
    Query(query): Query<EvolutionTokenQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let handler_ctx = build_http_handler_context(&ctx, Some(&identity));

    let response = crate::server::handlers::evolution::query_evolution_cycle_history(
        &path.project,
        &path.workspace,
        &handler_ctx,
    )
    .await
    .map_err(|e| qctx.map_query_error(e))?;
    json_from_server_message(response)
}
