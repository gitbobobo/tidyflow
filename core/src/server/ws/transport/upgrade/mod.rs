use axum::{extract::ws::WebSocketUpgrade, extract::Query, response::Response};
use std::net::SocketAddr;

mod auth;
mod bind;
mod session;

pub(in crate::server::ws) async fn handle_ws_upgrade(
    ws: WebSocketUpgrade,
    ctx: crate::server::ws::transport::bootstrap::AppContext,
    addr: SocketAddr,
    query: Option<Query<crate::server::ws::auth_keys::WsAuthQuery>>,
) -> Response {
    let auth_query = auth::extract_auth_query(query);

    if let Err(resp) = auth::ensure_authorized_or_response(
        ctx.expected_ws_token.as_deref(),
        &auth_query,
        &ctx.api_key_registry,
    )
    .await
    {
        return resp;
    }

    let conn_meta = session::build_conn_meta(addr, &auth_query, &ctx.api_key_registry).await;
    if conn_meta.api_key_id.is_some() {
        if let Some(token) = auth_query.token.as_deref() {
            let _ = crate::server::ws::auth_keys::touch_api_key_last_used(
                &ctx.api_key_registry,
                token,
                &ctx.app_state,
                &ctx.save_tx,
            )
            .await;
        }
    }
    bind::bind_upgrade(ws, ctx, conn_meta)
}
