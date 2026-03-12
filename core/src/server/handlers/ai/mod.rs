use std::sync::Arc;

use crate::server::ws::OutboundTx as WebSocket;
use tokio::sync::{mpsc, Mutex};

use crate::server::context::{SharedAppState, TaskBroadcastTx};
use crate::server::handlers::dispatch_handlers;
use crate::server::protocol::ai::AiSessionOrigin;
use crate::server::protocol::{ClientMessage, ServerMessage};

pub mod ai_state;
#[cfg(test)]
mod ai_test;
pub mod file_ref;
pub mod multi_project_context;
mod session_index_store;

mod route;
pub(crate) mod session;
mod stream;
mod utils;

pub use ai_state::AIState;
pub(crate) use session_index_store::{AiSessionIndexPage, AiSessionIndexStore};
pub(crate) use utils::{
    apply_stream_snapshot_cache_op, build_ai_session_messages_update, emit_ops_for_cache_op,
    ensure_agent, infer_selection_hint_from_messages, map_ai_messages_for_wire,
    map_ai_selection_hint_to_wire, mark_stream_snapshot_terminal, merge_session_selection_hint,
    normalize_ai_tool, normalize_part_for_wire, resolve_directory, seed_stream_snapshot,
    split_utf8_text_by_max_bytes, stream_key,
};

pub type SharedAIState = Arc<Mutex<AIState>>;

pub async fn shutdown_agents(ai_state: &SharedAIState) {
    utils::shutdown_agents(ai_state).await;
}

pub(crate) async fn record_session_index_created(
    ai_state: &SharedAIState,
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
    directory: &str,
    session_id: &str,
    title: &str,
    created_at_ms: i64,
    session_origin: AiSessionOrigin,
) -> Result<(), String> {
    let store = {
        let ai = ai_state.lock().await;
        ai.session_index_store.clone()
    };
    store
        .record_created(
            project_name,
            workspace_name,
            ai_tool,
            directory,
            session_id,
            title,
            created_at_ms,
            session_origin,
        )
        .await
}

pub(crate) async fn list_session_index_page(
    ai_state: &SharedAIState,
    project_name: &str,
    workspace_name: &str,
    filter_ai_tool: Option<&str>,
    cursor: Option<&str>,
    limit: Option<u32>,
) -> Result<AiSessionIndexPage, String> {
    let store = {
        let ai = ai_state.lock().await;
        ai.session_index_store.clone()
    };
    store
        .list_page(project_name, workspace_name, filter_ai_tool, cursor, limit)
        .await
}

pub(crate) async fn touch_session_index_updated_at(
    ai_state: &SharedAIState,
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
    session_id: &str,
    updated_at_ms: i64,
) -> Result<bool, String> {
    let store = {
        let ai = ai_state.lock().await;
        ai.session_index_store.clone()
    };
    store
        .touch_updated_at(
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            updated_at_ms,
        )
        .await
}

pub(crate) async fn delete_session_index_entry(
    ai_state: &SharedAIState,
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
    session_id: &str,
) -> Result<bool, String> {
    let store = {
        let ai = ai_state.lock().await;
        ai.session_index_store.clone()
    };
    store
        .delete(project_name, workspace_name, ai_tool, session_id)
        .await
}

pub(crate) async fn save_session_context_snapshot(
    ai_state: &SharedAIState,
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
    session_id: &str,
    snapshot: &session_index_store::AiSessionContextSnapshotStored,
) -> Result<(), String> {
    let store = {
        let ai = ai_state.lock().await;
        ai.session_index_store.clone()
    };
    store
        .save_context_snapshot(project_name, workspace_name, ai_tool, session_id, snapshot)
        .await
}

pub(crate) async fn get_session_context_snapshot(
    ai_state: &SharedAIState,
    project_name: &str,
    workspace_name: &str,
    ai_tool: &str,
    session_id: &str,
) -> Result<Option<session_index_store::AiSessionContextSnapshotStored>, String> {
    let store = {
        let ai = ai_state.lock().await;
        ai.session_index_store.clone()
    };
    store
        .get_context_snapshot(project_name, workspace_name, ai_tool, session_id)
        .await
}

pub(crate) async fn list_session_context_snapshots(
    ai_state: &SharedAIState,
    project_name: &str,
    workspace_name: &str,
    filter_ai_tool: Option<&str>,
) -> Result<
    Vec<(
        session_index_store::AiSessionIndexEntry,
        session_index_store::AiSessionContextSnapshotStored,
    )>,
    String,
> {
    let store = {
        let ai = ai_state.lock().await;
        ai.session_index_store.clone()
    };
    store
        .list_context_snapshots(project_name, workspace_name, filter_ai_tool)
        .await
}

pub async fn handle_ai_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
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
