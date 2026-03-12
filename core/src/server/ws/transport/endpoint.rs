use axum::{
    extract::ws::WebSocketUpgrade,
    extract::{ConnectInfo, Query, State},
    response::IntoResponse,
};
use std::net::SocketAddr;

pub(in crate::server::ws) async fn ws_handler(
    ws: WebSocketUpgrade,
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    query: Option<Query<crate::server::ws::auth_keys::WsAuthQuery>>,
) -> impl IntoResponse {
    crate::server::ws::transport::upgrade::handle_ws_upgrade(ws, ctx, addr, query).await
}
