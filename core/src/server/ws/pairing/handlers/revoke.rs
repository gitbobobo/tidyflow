use axum::extract::{ConnectInfo, State};
use axum::response::{IntoResponse, Response};
use axum::{http::StatusCode, Json};
use std::collections::HashSet;
use std::net::SocketAddr;

use crate::server::ws::pairing::auth::is_request_from_loopback;
use crate::server::ws::pairing::model::{PairErrorResponse, PairRevokeRequest, PairRevokeResponse};
use crate::server::ws::pairing::store::{
    cleanup_expired_pairing_entries, now_unix_ts, persist_tokens_to_state,
};

use super::common::forbidden_response;

pub(in crate::server::ws) async fn pair_revoke_handler(
    State(ctx): State<super::super::super::transport::bootstrap::AppContext>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(payload): Json<PairRevokeRequest>,
) -> Response {
    if !is_request_from_loopback(addr) {
        return forbidden_response("pair/revoke only accepts loopback requests");
    }

    if payload.token_id.is_none() && payload.ws_token.is_none() {
        return (
            StatusCode::BAD_REQUEST,
            Json(PairErrorResponse {
                error: "invalid_request".to_string(),
                message: "token_id or ws_token is required".to_string(),
            }),
        )
            .into_response();
    }

    let mut reg = ctx.pairing_registry.lock().await;
    let now_ts = now_unix_ts();
    cleanup_expired_pairing_entries(&mut reg, now_ts);

    let mut revoked = 0usize;
    let mut revoked_subscriber_ids = HashSet::new();
    if let Some(ws_token) = payload.ws_token {
        if let Some(entry) = reg.issued_tokens.remove(ws_token.trim()) {
            revoked += 1;
            revoked_subscriber_ids.insert(entry.token_id);
        }
    }
    if let Some(token_id) = payload.token_id {
        let token_id = token_id.trim();
        let matches: Vec<String> = reg
            .issued_tokens
            .iter()
            .filter_map(|(token, entry)| {
                if entry.token_id == token_id {
                    Some(token.clone())
                } else {
                    None
                }
            })
            .collect();
        for token in matches {
            if let Some(entry) = reg.issued_tokens.remove(&token) {
                revoked += 1;
                revoked_subscriber_ids.insert(entry.token_id);
            }
        }
    }

    if revoked > 0 {
        let tokens_ref = reg.issued_tokens.clone();
        let app_state = ctx.app_state.clone();
        let save_tx = ctx.save_tx.clone();
        tokio::spawn(async move {
            persist_tokens_to_state(&tokens_ref, &app_state, &save_tx).await;
        });
    }
    drop(reg);

    if !revoked_subscriber_ids.is_empty() {
        let mut rsub = ctx.remote_sub_registry.lock().await;
        for subscriber_id in revoked_subscriber_ids {
            rsub.unsubscribe_all(&subscriber_id);
        }
    }

    (
        StatusCode::OK,
        Json(PairRevokeResponse { ok: true, revoked }),
    )
        .into_response()
}
