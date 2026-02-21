use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use tracing::info;

pub(in crate::server::ws) fn spawn_shutdown_signal_listener(shutdown_flag: Arc<AtomicBool>) {
    #[cfg(unix)]
    {
        tokio::spawn(async move {
            use tokio::signal::unix::{signal, SignalKind};
            let mut sigterm = signal(SignalKind::terminate()).unwrap();
            let mut sigint = signal(SignalKind::interrupt()).unwrap();
            tokio::select! {
                _ = sigterm.recv() => {
                    info!("Received SIGTERM, shutting down gracefully");
                }
                _ = sigint.recv() => {
                    info!("Received SIGINT, shutting down gracefully");
                }
            }
            shutdown_flag.store(true, Ordering::SeqCst);
        });
    }
    #[cfg(not(unix))]
    let _ = shutdown_flag;
}
