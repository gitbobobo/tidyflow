use axum::{extract::ws::WebSocketUpgrade, extract::Query, response::Response};
use std::net::SocketAddr;

mod auth;
mod bind;
mod session;

pub(in crate::server::ws) async fn handle_ws_upgrade(
    ws: WebSocketUpgrade,
    ctx: crate::server::ws::transport::bootstrap::AppContext,
    addr: SocketAddr,
    query: Option<Query<crate::server::ws::pairing::WsAuthQuery>>,
) -> Response {
    let provided_token = auth::extract_provided_token(query);

    if let Err(resp) = auth::ensure_authorized_or_response(
        ctx.expected_ws_token.as_deref(),
        provided_token.as_deref(),
        &ctx.pairing_registry,
    )
    .await
    {
        return resp;
    }

    let conn_meta = session::build_conn_meta(addr, provided_token.as_deref(), &ctx.pairing_registry).await;
    bind::bind_upgrade(ws, ctx, conn_meta)
}
