use std::env;
use tracing::info;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize logging
    tidyflow_core::util::init_logging();

    // Read port from environment variable, default to 47999
    let port = env::var("TIDYFLOW_PORT")
        .ok()
        .and_then(|p| p.parse::<u16>().ok())
        .unwrap_or(47999);

    // Log startup message
    info!("Starting TidyFlow Core server on port {}", port);

    // Run the server
    tidyflow_core::server::run_server(port).await
}
