use axum::response::{IntoResponse, Response};
use axum::{http::StatusCode, Json};

use super::super::model::PairErrorResponse;

pub(super) fn forbidden_response(message: &str) -> Response {
    (
        StatusCode::FORBIDDEN,
        Json(PairErrorResponse {
            error: "forbidden".to_string(),
            message: message.to_string(),
        }),
    )
        .into_response()
}
