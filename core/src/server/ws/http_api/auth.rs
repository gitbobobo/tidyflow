use axum::http::HeaderMap;

use super::common::ApiError;

fn parse_bearer_token(headers: &HeaderMap) -> Option<String> {
    let value = headers.get(axum::http::header::AUTHORIZATION)?;
    let raw = value.to_str().ok()?.trim();
    let lower = raw.to_ascii_lowercase();
    if !lower.starts_with("bearer ") {
        return None;
    }
    let token = raw[7..].trim();
    if token.is_empty() {
        None
    } else {
        Some(token.to_string())
    }
}

fn normalize_token(token: Option<&str>) -> Option<String> {
    token
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.to_string())
}

pub(in crate::server::ws) async fn ensure_http_authorized(
    ctx: &crate::server::ws::transport::bootstrap::AppContext,
    headers: &HeaderMap,
    query_token: Option<&str>,
) -> Result<(), ApiError> {
    let provided_token = parse_bearer_token(headers).or_else(|| normalize_token(query_token));

    if crate::server::ws::pairing::is_ws_token_authorized(
        ctx.expected_ws_token.as_deref(),
        provided_token.as_deref(),
        &ctx.pairing_registry,
    )
    .await
    {
        Ok(())
    } else {
        Err(ApiError::Unauthorized)
    }
}
