use std::io::Write;
use tracing_subscriber::{fmt, prelude::*, EnvFilter};

/// Initialize structured logging with tracing.
///
/// Log level can be controlled via RUST_LOG env var.
/// Default level is "info".
pub fn init_logging() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));

    tracing_subscriber::registry()
        .with(
            fmt::layer()
                .with_target(true)
                .with_thread_ids(false)
                .with_ansi(false),
        )
        .with(filter)
        .init();
}

/// Flush stdout to ensure logs are written immediately
pub fn flush_logs() {
    let _ = std::io::stdout().flush();
    let _ = std::io::stderr().flush();
}
