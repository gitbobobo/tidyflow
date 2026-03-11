use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use serde::Deserialize;

use super::auth::ensure_http_authorized;
use super::common::{build_http_handler_context, json_from_server_message, ApiError};

#[derive(Debug, Deserialize, Default)]
pub(in crate::server::ws) struct TokenQuery {
    #[serde(default)]
    token: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct ProjectPath {
    project: String,
}

#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct TemplatePath {
    template_id: String,
}

pub(in crate::server::ws) async fn projects_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Query(query): Query<TokenQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let handler_ctx = build_http_handler_context(&ctx, Some(&identity));
    let response = crate::server::handlers::project::query::query_list_projects(&handler_ctx).await;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn workspaces_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<ProjectPath>,
    Query(query): Query<TokenQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let handler_ctx = build_http_handler_context(&ctx, Some(&identity));
    match crate::server::handlers::project::query::query_list_workspaces(
        &handler_ctx,
        &path.project,
    )
    .await
    {
        Ok(response) | Err(response) => json_from_server_message(response),
    }
}

pub(in crate::server::ws) async fn tasks_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Query(query): Query<TokenQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let handler_ctx = build_http_handler_context(&ctx, Some(&identity));
    let response = crate::server::handlers::project::query::query_list_tasks(&handler_ctx).await;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn client_settings_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Query(query): Query<TokenQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let handler_ctx = build_http_handler_context(&ctx, Some(&identity));
    let response =
        crate::server::handlers::settings::query::query_client_settings(&handler_ctx).await;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn templates_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Query(query): Query<TokenQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let _handler_ctx = build_http_handler_context(&ctx, Some(&identity));
    let response = crate::application::project_admin::list_templates_message(&ctx.app_state).await;
    json_from_server_message(response)
}

pub(in crate::server::ws) async fn template_export_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Path(path): Path<TemplatePath>,
    Query(query): Query<TokenQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let _handler_ctx = build_http_handler_context(&ctx, Some(&identity));
    let response = crate::application::project_admin::export_template_message(
        &ctx.app_state,
        &path.template_id,
    )
    .await;
    json_from_server_message(response)
}
