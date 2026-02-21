use std::net::SocketAddr;

use tracing::info;

use crate::server::protocol::PROTOCOL_VERSION;

pub(in crate::server::ws) async fn run_server(port: u16) -> Result<(), Box<dyn std::error::Error>> {
    info!("Starting WebSocket server on port {}", port);

    crate::server::ws::transport::lifecycle::spawn_parent_monitor();

    let (ctx, bind_addr) = crate::server::ws::transport::bootstrap::build_app_context().await;
    let app = crate::server::ws::transport::bootstrap::build_router(ctx);

    let addr = format!("{}:{}", bind_addr, port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;

    info!(
        "Listening on ws://{}/ws (protocol v{})",
        addr, PROTOCOL_VERSION
    );

    let shutdown_tx = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    crate::server::ws::transport::lifecycle::spawn_shutdown_signal_listener(shutdown_tx.clone());

    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(async move {
        while !shutdown_tx.load(std::sync::atomic::Ordering::SeqCst) {
            tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
        }
        info!("Graceful shutdown initiated");
    })
    .await?;

    Ok(())
}
