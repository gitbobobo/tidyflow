// handlers module - Protocol message handlers
// Contains handlers for workspace, terminal, git, file operations

pub mod ai;
pub mod evidence;
pub mod evolution;
pub mod evolution_prompts;
pub mod file;
pub mod git;
pub mod health;
pub mod log;
pub mod project;
pub mod settings;
pub mod terminal;

use crate::server::protocol::ServerMessage;
use crate::server::ws::{send_message, OutboundTx as WebSocket};

macro_rules! dispatch_handlers {
    ($($call:expr),+ $(,)?) => {{
        $(
            if $call.await? {
                return Ok(true);
            }
        )+
    }};
}

pub(crate) use dispatch_handlers;

pub(crate) async fn send_read_via_http_required(
    socket: &WebSocket,
    action: &str,
    http_path_hint: &str,
    project: Option<String>,
    workspace: Option<String>,
) -> Result<(), String> {
    send_message(
        socket,
        &ServerMessage::Error {
            code: "read_via_http_required".to_string(),
            message: format!("{action} must be fetched via HTTP API ({http_path_hint})"),
            project,
            workspace,
            session_id: None,
            cycle_id: None,
        },
    )
    .await
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    async fn push_and_return(
        trace: Arc<Mutex<Vec<&'static str>>>,
        label: &'static str,
        value: bool,
    ) -> Result<bool, String> {
        trace.lock().expect("lock trace").push(label);
        Ok(value)
    }

    async fn run_dispatch(trace: Arc<Mutex<Vec<&'static str>>>) -> Result<bool, String> {
        dispatch_handlers!(
            push_and_return(trace.clone(), "first", false),
            push_and_return(trace.clone(), "second", true),
            push_and_return(trace.clone(), "third", true),
        );
        Ok(false)
    }

    #[tokio::test]
    async fn dispatch_handlers_short_circuits_in_order() {
        let trace = Arc::new(Mutex::new(Vec::new()));
        let handled = run_dispatch(trace.clone())
            .await
            .expect("dispatch should succeed");

        assert!(handled);
        assert_eq!(*trace.lock().expect("lock trace"), vec!["first", "second"]);
    }
}
