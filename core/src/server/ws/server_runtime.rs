use std::io::Write;
use std::net::SocketAddr;

use tracing::info;

use crate::server::protocol::PROTOCOL_VERSION;

pub(in crate::server::ws) async fn run_server(port: u16) -> Result<(), Box<dyn std::error::Error>> {
    info!("Starting WebSocket server on port {}", port);

    let shutdown_tx = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    crate::server::ws::transport::lifecycle::spawn_parent_monitor(shutdown_tx.clone());

    let (ctx, bind_addr) = crate::server::ws::transport::bootstrap::build_app_context().await;
    let (fixed_port, remote_access_enabled) = {
        let state = ctx.app_state.read().await;
        (
            state.client_settings.fixed_port,
            state.client_settings.remote_access_enabled,
        )
    };
    let ai_state = ctx.ai_state.clone();

    let addr = format!("{}:{}", bind_addr, port);
    let listener = match tokio::net::TcpListener::bind(&addr).await {
        Ok(listener) => listener,
        Err(e) => {
            crate::server::handlers::ai::shutdown_agents(&ai_state).await;
            return Err(Box::new(e));
        }
    };
    let local_addr = listener.local_addr()?;

    let bootstrap = serde_json::json!({
        "port": local_addr.port(),
        "bind_addr": bind_addr,
        "fixed_port": fixed_port,
        "remote_access_enabled": remote_access_enabled,
        "protocol_version": PROTOCOL_VERSION,
        "core_version": env!("CARGO_PKG_VERSION"),
    });
    if let Ok(payload) = serde_json::to_string(&bootstrap) {
        println!("TIDYFLOW_BOOTSTRAP {}", payload);
        let _ = std::io::stdout().flush();
    }

    let app = crate::server::ws::transport::bootstrap::build_router(ctx);

    info!(
        "Listening on ws://{}/ws (protocol v{})",
        local_addr, PROTOCOL_VERSION
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
