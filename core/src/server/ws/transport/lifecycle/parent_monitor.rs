#[cfg(unix)]
use std::os::unix::process::parent_id;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use tracing::{info, warn};

pub(in crate::server::ws) fn spawn_parent_monitor(shutdown_flag: Arc<AtomicBool>) {
    #[cfg(unix)]
    {
        let initial_ppid = parent_id();
        info!("Parent process monitor started, PPID: {}", initial_ppid);

        if initial_ppid <= 1 {
            info!("Running without parent process, skipping monitor");
            return;
        }

        tokio::spawn(async move {
            let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(1));
            loop {
                interval.tick().await;

                let current_ppid = parent_id();
                if current_ppid != initial_ppid {
                    warn!(
                        "Parent process died (PPID changed from {} to {}), requesting graceful shutdown",
                        initial_ppid, current_ppid
                    );
                    shutdown_flag.store(true, Ordering::SeqCst);
                    break;
                }
            }
        });
    }

    #[cfg(not(unix))]
    let _ = shutdown_flag;
}
