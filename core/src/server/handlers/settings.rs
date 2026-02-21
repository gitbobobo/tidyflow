use axum::extract::ws::WebSocket;

use crate::server::context::SharedAppState;
use crate::server::handlers::dispatch_handlers;
use crate::server::protocol::ClientMessage;

mod mutate;
mod query;

/// 处理设置相关的客户端消息
pub async fn handle_settings_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    save_tx: &tokio::sync::mpsc::Sender<()>,
) -> Result<bool, String> {
    dispatch_handlers!(
        query::handle_query_message(client_msg, socket, app_state),
        mutate::handle_mutate_message(client_msg, socket, app_state, save_tx),
    );

    Ok(false)
}

#[cfg(test)]
mod tests {
    use crate::server::handlers::dispatch_handlers;
    use std::sync::{Arc, Mutex};

    async fn push_and_return(
        trace: Arc<Mutex<Vec<&'static str>>>,
        label: &'static str,
        value: bool,
    ) -> Result<bool, String> {
        trace.lock().expect("lock trace").push(label);
        Ok(value)
    }

    async fn dispatch_like_settings(trace: Arc<Mutex<Vec<&'static str>>>) -> Result<bool, String> {
        dispatch_handlers!(
            push_and_return(trace.clone(), "query", false),
            push_and_return(trace.clone(), "mutate", true),
        );
        Ok(false)
    }

    #[tokio::test]
    async fn settings_dispatch_order_short_circuit() {
        let trace = Arc::new(Mutex::new(Vec::new()));
        let handled = dispatch_like_settings(trace.clone())
            .await
            .expect("dispatch should succeed");

        assert!(handled);
        assert_eq!(*trace.lock().expect("lock trace"), vec!["query", "mutate"]);
    }
}
