use axum::response::{IntoResponse, Response};
use axum::{http::StatusCode, Json};

use crate::server::ws::auth_keys::model::APIKeyErrorResponse;

pub(in crate::server::ws) fn forbidden_response(message: &str) -> Response {
    (
        StatusCode::FORBIDDEN,
        Json(APIKeyErrorResponse {
            error: "forbidden".to_string(),
            message: message.to_string(),
        }),
    )
        .into_response()
}
