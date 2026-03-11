use axum::{
    extract::{Query, State},
    http::HeaderMap,
    Json,
};
use serde::Deserialize;

use super::auth::ensure_http_authorized;
use super::common::{build_http_handler_context, json_from_server_message, ApiError};

#[derive(Debug, Deserialize, Default)]
pub(in crate::server::ws) struct TerminalTokenQuery {
    #[serde(default)]
    token: Option<String>,
}

pub(in crate::server::ws) async fn terminals_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    headers: HeaderMap,
    Query(query): Query<TerminalTokenQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let identity = ensure_http_authorized(&ctx, &headers, query.token.as_deref()).await?;
    let handler_ctx = build_http_handler_context(&ctx, Some(&identity));
    let (response, _, _) = crate::server::handlers::terminal::query::query_term_list(
        &handler_ctx,
        &handler_ctx.conn_meta,
    )
    .await;
    json_from_server_message(response)
}
