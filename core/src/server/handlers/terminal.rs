use crate::server::ws::OutboundTx as WebSocket;

use crate::server::context::HandlerContext;
use crate::server::handlers::dispatch_handlers;
use crate::server::protocol::ClientMessage;

mod clipboard;
mod io;
mod lifecycle;
pub(crate) mod query;

/// 处理终端相关的客户端消息
///
/// 入口签名保持不变，按能力域顺序分发。
pub async fn handle_terminal_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    if matches!(client_msg, ClientMessage::TermList) {
        crate::server::handlers::send_read_via_http_required(
            socket,
            "term_list",
            "/api/v1/terminals",
            None,
            None,
        )
        .await?;
        return Ok(true);
    }

    dispatch_handlers!(
        io::handle_io_message(client_msg, socket, ctx),
        lifecycle::handle_lifecycle_message(client_msg, socket, ctx),
        query::handle_query_message(client_msg, socket, ctx),
        clipboard::handle_clipboard_message(client_msg, socket, ctx),
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

    async fn dispatch_like_terminal(trace: Arc<Mutex<Vec<&'static str>>>) -> Result<bool, String> {
        dispatch_handlers!(
            push_and_return(trace.clone(), "io", false),
            push_and_return(trace.clone(), "lifecycle", false),
            push_and_return(trace.clone(), "query", true),
            push_and_return(trace.clone(), "clipboard", true),
        );
        Ok(false)
    }

    #[tokio::test]
    async fn terminal_dispatch_order_short_circuit() {
        let trace = Arc::new(Mutex::new(Vec::new()));
        let handled = dispatch_like_terminal(trace.clone())
            .await
            .expect("dispatch should succeed");

        assert!(handled);
        assert_eq!(
            *trace.lock().expect("lock trace"),
            vec!["io", "lifecycle", "query"]
        );
    }
}
