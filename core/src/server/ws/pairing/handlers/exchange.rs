use axum::extract::State;
use axum::response::{IntoResponse, Response};
use axum::{http::StatusCode, Json};
use uuid::Uuid;

use crate::server::ws::pairing::model::{
    PairErrorResponse, PairExchangeRequest, PairExchangeResponse, PairTokenEntry,
    MAX_ISSUED_PAIR_TOKENS, PAIR_TOKEN_TTL_SECS,
};
use crate::server::ws::pairing::store::{
    cleanup_expired_pairing_entries, now_unix_ts, persist_tokens_to_state, unix_ts_to_rfc3339,
};

pub(in crate::server::ws) async fn pair_exchange_handler(
    State(ctx): State<super::super::super::transport::bootstrap::AppContext>,
    Json(payload): Json<PairExchangeRequest>,
) -> Response {
    let pair_code = payload.pair_code.trim().to_string();
    if pair_code.len() != 6 || !pair_code.chars().all(|c| c.is_ascii_digit()) {
        return (
            StatusCode::BAD_REQUEST,
            Json(PairErrorResponse {
                error: "invalid_pair_code".to_string(),
                message: "pair_code must be 6 digits".to_string(),
            }),
        )
            .into_response();
    }

    let device_name = payload
        .device_name
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "iOS Device".to_string());

    let mut reg = ctx.pairing_registry.lock().await;
    let now_ts = now_unix_ts();
    cleanup_expired_pairing_entries(&mut reg, now_ts);

    let Some(code_entry) = reg.pending_codes.remove(&pair_code) else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(PairErrorResponse {
                error: "pair_code_not_found".to_string(),
                message: "pair_code is invalid or expired".to_string(),
            }),
        )
            .into_response();
    };
    if code_entry.expires_at_unix <= now_ts {
        return (
            StatusCode::UNAUTHORIZED,
            Json(PairErrorResponse {
                error: "pair_code_expired".to_string(),
                message: "pair_code is expired".to_string(),
            }),
        )
            .into_response();
    }

    while reg.issued_tokens.len() >= MAX_ISSUED_PAIR_TOKENS {
        let oldest = reg
            .issued_tokens
            .iter()
            .min_by_key(|(_, entry)| entry.expires_at_unix)
            .map(|(token, _)| token.clone());
        if let Some(token) = oldest {
            reg.issued_tokens.remove(&token);
        } else {
            break;
        }
    }

    let ws_token = Uuid::new_v4().to_string();
    let token_id = Uuid::new_v4().to_string();
    let issued_at_unix = now_ts;
    let expires_at_unix = now_ts + PAIR_TOKEN_TTL_SECS;
    reg.issued_tokens.insert(
        ws_token.clone(),
        PairTokenEntry {
            token_id: token_id.clone(),
            device_name: device_name.clone(),
            issued_at_unix,
            expires_at_unix,
        },
    );

    let tokens_ref = reg.issued_tokens.clone();
    let app_state = ctx.app_state.clone();
    let save_tx = ctx.save_tx.clone();
    tokio::spawn(async move {
        persist_tokens_to_state(&tokens_ref, &app_state, &save_tx).await;
    });

    (
        StatusCode::OK,
        Json(PairExchangeResponse {
            token_id,
            ws_token,
            device_name,
            issued_at: unix_ts_to_rfc3339(issued_at_unix),
            issued_at_unix,
            expires_at: unix_ts_to_rfc3339(expires_at_unix),
            expires_at_unix,
        }),
    )
        .into_response()
}
