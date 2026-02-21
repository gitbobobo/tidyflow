use axum::extract::ws::WebSocket;

use crate::server::context::HandlerContext;
use crate::server::handlers::dispatch_handlers;
use crate::server::protocol::ClientMessage;

mod admin;
mod query;
mod runtime;

/// 处理项目和工作空间相关的客户端消息
///
/// 入口签名保持不变；按能力域顺序分发到子模块。
pub async fn handle_project_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    dispatch_handlers!(
        query::handle_query_message(client_msg, socket, ctx),
        admin::handle_admin_message(client_msg, socket, ctx),
        runtime::handle_runtime_message(client_msg, socket, ctx),
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

    async fn dispatch_like_project(trace: Arc<Mutex<Vec<&'static str>>>) -> Result<bool, String> {
        dispatch_handlers!(
            push_and_return(trace.clone(), "query", false),
            push_and_return(trace.clone(), "admin", true),
            push_and_return(trace.clone(), "runtime", true),
        );
        Ok(false)
    }

    #[tokio::test]
    async fn project_dispatch_order_short_circuit() {
        let trace = Arc::new(Mutex::new(Vec::new()));
        let handled = dispatch_like_project(trace.clone())
            .await
            .expect("dispatch should succeed");

        assert!(handled);
        assert_eq!(*trace.lock().expect("lock trace"), vec!["query", "admin"]);
    }
}
