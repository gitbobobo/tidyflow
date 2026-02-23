use axum::{
    routing::{get, post},
    Router,
};

use super::context::AppContext;

pub(in crate::server::ws) fn build_router(ctx: AppContext) -> Router {
    Router::new()
        .route(
            "/ws",
            get(crate::server::ws::transport::endpoint::ws_handler),
        )
        .route(
            "/pair/start",
            post(crate::server::ws::pairing::pair_start_handler),
        )
        .route(
            "/pair/exchange",
            post(crate::server::ws::pairing::pair_exchange_handler),
        )
        .route(
            "/pair/revoke",
            post(crate::server::ws::pairing::pair_revoke_handler),
        )
        .with_state(ctx)
}
