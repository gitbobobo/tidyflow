use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use serde::Deserialize;

use super::auth::ensure_http_authorized;
use super::common::{
    build_http_handler_context, json_from_server_message, ApiError, WorkspaceQueryContext,
};

#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct EvidenceWorkspacePath {
    project: String,
    workspace: String,
}

#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct EvidenceItemPath {
    project: String,
    workspace: String,
    item_id: String,
}

#[derive(Debug, Deserialize, Default)]
pub(in crate::server::ws) struct EvidenceTokenQuery {
    #[serde(default)]
    token: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub(in crate::server::ws) struct EvidenceChunkQuery {
    #[serde(default)]
    offset: Option<u64>,
    #[serde(default)]
    limit: Option<u32>,
    #[serde(default)]
    token: Option<String>,
}

pub(in crate::server::ws) async fn evidence_snapshot_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<EvidenceWorkspacePath>,
    Query(query): Query<EvidenceTokenQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let handler_ctx = build_http_handler_context(&ctx);

    let response = crate::server::handlers::evidence::query_evidence_snapshot(
        &path.project,
        &path.workspace,
        &handler_ctx,
    )
    .await
    .map_err(|e| qctx.map_query_error(e))?;

    json_from_server_message(response)
}

pub(in crate::server::ws) async fn evidence_rebuild_prompt_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<EvidenceWorkspacePath>,
    Query(query): Query<EvidenceTokenQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let handler_ctx = build_http_handler_context(&ctx);

    let response = crate::server::handlers::evidence::query_evidence_rebuild_prompt(
        &path.project,
        &path.workspace,
        &handler_ctx,
    )
    .await
    .map_err(|e| qctx.map_query_error(e))?;

    json_from_server_message(response)
}

pub(in crate::server::ws) async fn evidence_item_chunk_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<EvidenceItemPath>,
    Query(query): Query<EvidenceChunkQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let handler_ctx = build_http_handler_context(&ctx);

    let response = crate::server::handlers::evidence::query_evidence_item_chunk(
        &path.project,
        &path.workspace,
        &path.item_id,
        query.offset.unwrap_or(0),
        query.limit,
        &handler_ctx,
    )
    .await
    .map_err(|e| qctx.map_query_error(e))?;

    json_from_server_message(response)
}
