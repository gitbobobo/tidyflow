use std::sync::Arc;

use axum::extract::ws::WebSocket;
use tokio::sync::{mpsc, Mutex};

use crate::server::context::{SharedAppState, TaskBroadcastTx};
use crate::server::handlers::dispatch_handlers;
use crate::server::protocol::{ClientMessage, ServerMessage};

pub mod ai_state;
#[cfg(test)]
mod ai_test;
pub mod file_ref;

mod route;
mod session;
mod stream;
mod utils;

pub use ai_state::AIState;
pub(crate) use utils::{
    ensure_agent, normalize_ai_tool, normalize_part_for_wire, resolve_directory,
};

pub type SharedAIState = Arc<Mutex<AIState>>;

pub async fn preload_agents_on_startup(ai_state: &SharedAIState) {
    utils::preload_agents_on_startup(ai_state).await;
}

pub async fn handle_ai_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    output_tx: &mpsc::Sender<ServerMessage>,
    task_broadcast_tx: &TaskBroadcastTx,
    origin_conn_id: &str,
) -> Result<bool, String> {
    utils::ensure_status_push_initialized(ai_state, task_broadcast_tx).await;

    dispatch_handlers!(
        route::handle_stream_routes(
            client_msg,
            socket,
            app_state,
            ai_state,
            output_tx,
            task_broadcast_tx,
            origin_conn_id,
        ),
        route::handle_session_routes(client_msg, socket, app_state, ai_state),
        route::handle_subscription_routes(client_msg, socket, app_state, ai_state, origin_conn_id),
    );

    Ok(false)
}
