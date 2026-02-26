use std::net::SocketAddr;

use tracing::info;

use crate::server::protocol::PROTOCOL_VERSION;

pub(in crate::server::ws) async fn run_server(port: u16) -> Result<(), Box<dyn std::error::Error>> {
    info!("Starting WebSocket server on port {}", port);

    let shutdown_tx = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    crate::server::ws::transport::lifecycle::spawn_parent_monitor(shutdown_tx.clone());

    let (ctx, bind_addr) = crate::server::ws::transport::bootstrap::build_app_context().await;
    let ai_state = ctx.ai_state.clone();
    let app = crate::server::ws::transport::bootstrap::build_router(ctx);

    let addr = format!("{}:{}", bind_addr, port);
    let listener = match tokio::net::TcpListener::bind(&addr).await {
        Ok(listener) => listener,
        Err(e) => {
            crate::server::handlers::ai::shutdown_agents(&ai_state).await;
            return Err(Box::new(e));
        }
    };

    info!(
        "Listening on ws://{}/ws (protocol v{})",
        addr, PROTOCOL_VERSION
    );

    crate::server::ws::transport::lifecycle::spawn_shutdown_signal_listener(shutdown_tx.clone());

    let serve_result = axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(async move {
        while !shutdown_tx.load(std::sync::atomic::Ordering::SeqCst) {
            tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
        }
        info!("Graceful shutdown initiated");
    })
    .await;

    crate::server::handlers::ai::shutdown_agents(&ai_state).await;
    serve_result?;

    Ok(())
}
