use axum::http::HeaderMap;

use super::common::ApiError;

#[derive(Debug, Clone)]
pub(in crate::server::ws) struct HttpRequestIdentity {
    pub api_key_id: Option<String>,
    pub client_id: Option<String>,
    pub subscriber_id: Option<String>,
    pub device_name: Option<String>,
    pub is_remote: bool,
}

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

fn parse_optional_header(headers: &HeaderMap, name: &str) -> Option<String> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.to_string())
}

pub(in crate::server::ws) async fn ensure_http_authorized(
    ctx: &crate::server::ws::transport::bootstrap::AppContext,
    headers: &HeaderMap,
    query_token: Option<&str>,
) -> Result<HttpRequestIdentity, ApiError> {
    let provided_token = parse_bearer_token(headers).or_else(|| normalize_token(query_token));
    let client_id = parse_optional_header(headers, "X-TidyFlow-Client-ID");
    let device_name = parse_optional_header(headers, "X-TidyFlow-Device-Name");

    match ctx.expected_ws_token.as_deref() {
        None => Ok(HttpRequestIdentity {
            api_key_id: None,
            client_id: None,
            subscriber_id: None,
            device_name: None,
            is_remote: false,
        }),
        Some(expected_token) => {
            let Some(token) = provided_token.as_deref() else {
                return Err(ApiError::Unauthorized);
            };
            if token == expected_token {
                return Ok(HttpRequestIdentity {
                    api_key_id: None,
                    client_id: None,
                    subscriber_id: None,
                    device_name: None,
                    is_remote: false,
                });
            }

            let Some(key_info) =
                crate::server::ws::auth_keys::authorize_token(
                    ctx.expected_ws_token.as_deref(),
                    Some(token),
                    &crate::server::ws::auth_keys::WsAuthQuery {
                        token: Some(token.to_string()),
                        client_id: client_id.clone(),
                        device_name: device_name.clone(),
                    },
                    &ctx.api_key_registry,
                )
                .await
            else {
                return Err(ApiError::Unauthorized);
            };
            if key_info.key_id.is_empty() {
                return Ok(HttpRequestIdentity {
                    api_key_id: None,
                    client_id: None,
                    subscriber_id: None,
                    device_name: None,
                    is_remote: false,
                });
            }
            let Some(client_id) = client_id else {
                return Err(ApiError::Unauthorized);
            };
            Ok(HttpRequestIdentity {
                api_key_id: Some(key_info.key_id.clone()),
                client_id: Some(client_id.clone()),
                subscriber_id: Some(format!("{}:{}", key_info.key_id, client_id)),
                device_name,
                is_remote: true,
            })
        }
    }
}
