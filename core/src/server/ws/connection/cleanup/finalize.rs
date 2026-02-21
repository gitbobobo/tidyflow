use tracing::info;

use crate::server::context::HandlerContext;

pub(in crate::server::ws) async fn shutdown_lsp_and_log(handler_ctx: &HandlerContext) {
    handler_ctx.lsp_supervisor.shutdown_all().await;
    info!("WebSocket connection handler finished");
}
