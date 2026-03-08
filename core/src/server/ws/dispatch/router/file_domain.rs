use axum::extract::ws::WebSocket;
use tracing::{info, trace};

use crate::server::context::HandlerContext;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::dispatch::shared_types::DispatchWatcher;
use crate::server::ws::send_message;

pub(super) async fn handle_file_domain(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
    watcher: &DispatchWatcher,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::WatchSubscribe { project, workspace } => {
            handle_watch_subscribe(project, workspace, socket, ctx, watcher).await?;
            Ok(true)
        }
        ClientMessage::WatchUnsubscribe => {
            handle_watch_unsubscribe(socket, watcher).await?;
            Ok(true)
        }
        _ => handle_regular_file_message(client_msg, socket, ctx).await,
    }
}

async fn handle_watch_subscribe(
    project: &str,
    workspace: &str,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
    watcher: &DispatchWatcher,
) -> Result<(), String> {
    trace!(
        "WatchSubscribe: project={}, workspace={}",
        project,
        workspace
    );
    match crate::server::context::resolve_workspace(&ctx.app_state, project, workspace).await {
        Ok(ws_ctx) => {
            let mut w = watcher.lock().await;
            match w.subscribe(project.to_string(), workspace.to_string(), ws_ctx.root_path) {
                Ok(_) => {
                    send_message(
                        socket,
                        &ServerMessage::WatchSubscribed {
                            project: project.to_string(),
                            workspace: workspace.to_string(),
                        },
                    )
                    .await?;
                }
                Err(e) => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "watch_subscribe_failed".to_string(),
                            message: e,
                            project: None,
                            workspace: None,
                            session_id: None,
                            cycle_id: None,
                        },
                    )
                    .await?;
                }
            }
        }
        Err(e) => {
            send_message(socket, &e.to_server_error()).await?;
        }
    }
    Ok(())
}

async fn handle_watch_unsubscribe(
    socket: &mut WebSocket,
    watcher: &DispatchWatcher,
) -> Result<(), String> {
    info!("WatchUnsubscribe");
    let mut w = watcher.lock().await;
    w.unsubscribe();
    send_message(socket, &ServerMessage::WatchUnsubscribed).await
}

async fn handle_regular_file_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    crate::server::handlers::file::handle_file_message(client_msg, socket, &ctx.app_state).await
}
