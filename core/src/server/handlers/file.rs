use crate::server::ws::OutboundTx as WebSocket;

use crate::server::context::SharedAppState;
use crate::server::handlers::dispatch_handlers;
use crate::server::protocol::ClientMessage;

mod mutate;
mod query;
mod read_write;

/// 处理文件相关的客户端消息
pub async fn handle_file_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    dispatch_handlers!(
        query::handle_query_message(client_msg, socket, app_state),
        read_write::handle_read_write_message(client_msg, socket, app_state),
        mutate::handle_mutate_message(client_msg, socket, app_state),
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

    async fn dispatch_like_file(trace: Arc<Mutex<Vec<&'static str>>>) -> Result<bool, String> {
        dispatch_handlers!(
            push_and_return(trace.clone(), "query", false),
            push_and_return(trace.clone(), "read_write", true),
            push_and_return(trace.clone(), "mutate", true),
        );
        Ok(false)
    }

    #[tokio::test]
    async fn file_dispatch_order_short_circuit() {
        let trace = Arc::new(Mutex::new(Vec::new()));
        let handled = dispatch_like_file(trace.clone())
            .await
            .expect("dispatch should succeed");

        assert!(handled);
        assert_eq!(
            *trace.lock().expect("lock trace"),
            vec!["query", "read_write"]
        );
    }
}
