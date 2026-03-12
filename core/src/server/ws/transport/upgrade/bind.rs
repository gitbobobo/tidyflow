use axum::{
    extract::ws::WebSocketUpgrade,
    response::{IntoResponse, Response},
};

pub(in crate::server::ws) fn bind_upgrade(
    ws: WebSocketUpgrade,
    ctx: crate::server::ws::transport::bootstrap::AppContext,
    conn_meta: crate::server::context::ConnectionMeta,
) -> Response {
    ws.max_frame_size(crate::server::ws::MAX_WS_FRAME_SIZE)
        .max_message_size(crate::server::ws::MAX_WS_MESSAGE_SIZE)
        .on_upgrade(move |socket| {
            crate::server::ws::connection::handle_socket(
                socket,
                ctx.app_state,
                ctx.save_tx,
                ctx.terminal_registry,
                ctx.scrollback_tx,
                conn_meta,
                ctx.remote_sub_registry,
                ctx.task_broadcast_tx,
                ctx.running_commands,
                ctx.running_ai_tasks,
                ctx.task_history,
                ctx.ai_state,
                ctx.state_store,
            )
        })
        .into_response()
}
