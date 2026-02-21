use axum::extract::{ConnectInfo, State};
use axum::response::{IntoResponse, Response};
use axum::{http::StatusCode, Json};
use std::net::SocketAddr;

use crate::server::ws::pairing::auth::is_request_from_loopback;
use crate::server::ws::pairing::model::{
    PairCodeEntry, PairStartResponse, MAX_PENDING_PAIR_CODES, PAIR_CODE_TTL_SECS,
};
use crate::server::ws::pairing::store::{
    cleanup_expired_pairing_entries, generate_pair_code, now_unix_ts, unix_ts_to_rfc3339,
};

use super::common::forbidden_response;

pub(in crate::server::ws) async fn pair_start_handler(
    State(ctx): State<super::super::super::transport::bootstrap::AppContext>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
) -> Response {
    if !is_request_from_loopback(addr) {
        return forbidden_response("pair/start only accepts loopback requests");
    }

    let now_ts = now_unix_ts();
    let expires_at_unix = now_ts + PAIR_CODE_TTL_SECS;
    let expires_at = unix_ts_to_rfc3339(expires_at_unix);

    let mut reg = ctx.pairing_registry.lock().await;
    cleanup_expired_pairing_entries(&mut reg, now_ts);
    while reg.pending_codes.len() >= MAX_PENDING_PAIR_CODES {
        let oldest = reg
            .pending_codes
            .iter()
            .min_by_key(|(_, entry)| entry.expires_at_unix)
            .map(|(code, _)| code.clone());
        if let Some(code) = oldest {
            reg.pending_codes.remove(&code);
        } else {
            break;
        }
    }

    let pair_code = loop {
        let code = generate_pair_code();
        if !reg.pending_codes.contains_key(&code) {
            break code;
        }
    };
    reg.pending_codes
        .insert(pair_code.clone(), PairCodeEntry { expires_at_unix });

    (
        StatusCode::OK,
        Json(PairStartResponse {
            pair_code,
            expires_at,
            expires_at_unix,
        }),
    )
        .into_response()
}
