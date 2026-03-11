use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use serde::Deserialize;

use super::auth::ensure_http_authorized;
use super::common::{json_from_server_message, ApiError, WorkspaceQueryContext};

#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct WorkspacePath {
    project: String,
    workspace: String,
}

#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct ProjectPath {
    project: String,
}

#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct CommitPath {
    project: String,
    workspace: String,
    sha: String,
}

#[derive(Debug, Deserialize, Default)]
pub(in crate::server::ws) struct TokenQuery {
    #[serde(default)]
    token: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub(in crate::server::ws) struct GitDiffQuery {
    path: String,
    #[serde(default)]
    mode: Option<String>,
    #[serde(default)]
    base: Option<String>,
    #[serde(default)]
    token: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub(in crate::server::ws) struct GitLogQuery {
    #[serde(default)]
    limit: Option<usize>,
    #[serde(default)]
    token: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub(in crate::server::ws) struct GitConflictDetailQuery {
    path: String,
    context: String,
    #[serde(default)]
    token: Option<String>,
}

fn map_git_error(qctx: &WorkspaceQueryContext, err: String) -> ApiError {
    qctx.map_query_error(err)
}

pub(in crate::server::ws) async fn git_status_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<WorkspacePath>,
    Query(query): Query<TokenQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let response = crate::server::handlers::git::query::query_git_status(
        &ctx.app_state,
        &path.project,
        &path.workspace,
    )
    .await
    .map_err(|e| map_git_error(&qctx, e))?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn git_diff_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<WorkspacePath>,
    Query(query): Query<GitDiffQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let response = crate::server::handlers::git::query::query_git_diff(
        &ctx.app_state,
        &path.project,
        &path.workspace,
        &query.path,
        query.base,
        query.mode.as_deref().unwrap_or("working"),
    )
    .await
    .map_err(|e| map_git_error(&qctx, e))?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn git_branches_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<WorkspacePath>,
    Query(query): Query<TokenQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let response = crate::server::handlers::git::query::query_git_branches(
        &ctx.app_state,
        &path.project,
        &path.workspace,
    )
    .await
    .map_err(|e| map_git_error(&qctx, e))?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn git_log_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<WorkspacePath>,
    Query(query): Query<GitLogQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let response = crate::server::handlers::git::query::query_git_log(
        &ctx.app_state,
        &path.project,
        &path.workspace,
        query.limit.unwrap_or(50),
    )
    .await
    .map_err(|e| map_git_error(&qctx, e))?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn git_commit_show_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<CommitPath>,
    Query(query): Query<TokenQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let response = crate::server::handlers::git::query::query_git_show(
        &ctx.app_state,
        &path.project,
        &path.workspace,
        &path.sha,
    )
    .await
    .map_err(|e| map_git_error(&qctx, e))?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn git_op_status_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<WorkspacePath>,
    Query(query): Query<TokenQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let response = crate::server::handlers::git::query::query_git_op_status(
        &ctx.app_state,
        &path.project,
        &path.workspace,
    )
    .await
    .map_err(|e| map_git_error(&qctx, e))?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn git_integration_status_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<ProjectPath>,
    Query(query): Query<TokenQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let response = crate::server::handlers::git::query::query_git_integration_status(
        &ctx.app_state,
        &path.project,
    )
    .await
    .map_err(ApiError::BadRequest)?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn git_check_branch_up_to_date_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<WorkspacePath>,
    Query(query): Query<TokenQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let response = crate::server::handlers::git::query::query_git_check_branch_up_to_date(
        &ctx.app_state,
        &path.project,
        &path.workspace,
    )
    .await
    .map_err(|e| map_git_error(&qctx, e))?;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn git_conflict_detail_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<WorkspacePath>,
    Query(query): Query<GitConflictDetailQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let qctx = WorkspaceQueryContext::new(&path.project, &path.workspace);
    let response = crate::server::handlers::git::query::query_git_conflict_detail(
        &ctx.app_state,
        &path.project,
        &path.workspace,
        &query.path,
        &query.context,
    )
    .await
    .map_err(|e| map_git_error(&qctx, e))?;
    json_from_server_message(response)
}
