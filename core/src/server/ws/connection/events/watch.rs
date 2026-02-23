use axum::extract::ws::WebSocket;
use tracing::debug;

use crate::server::context::{HandlerContext, SharedAppState};
use crate::server::git::status::invalidate_git_status_cache;
use crate::server::protocol::ServerMessage;
use crate::server::watcher::WatchEvent;

use super::common::emit_message;

pub(in crate::server::ws) async fn handle_watch_event(
    watch_event: WatchEvent,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    handler_ctx: &HandlerContext,
) {
    match watch_event {
        WatchEvent::FileChanged {
            project,
            workspace,
            paths,
            kind,
        } => {
            debug!(
                "File changed: project={}, workspace={}, paths={:?}",
                project, workspace, paths
            );

            handler_ctx
                .lsp_supervisor
                .handle_paths_changed(&project, &workspace, &paths)
                .await;

            let ws_ctx =
                crate::server::context::resolve_workspace(app_state, &project, &workspace).await;
            if let Ok(ctx) = ws_ctx {
                invalidate_git_status_cache(&ctx.root_path);
            }

            let msg = ServerMessage::FileChanged {
                project,
                workspace,
                paths,
                kind,
            };
            emit_message(socket, &msg, "Failed to send file changed message").await;
        }
        WatchEvent::GitStatusChanged { project, workspace } => {
            debug!(
                "Git status changed: project={}, workspace={}",
                project, workspace
            );

            let ws_ctx =
                crate::server::context::resolve_workspace(app_state, &project, &workspace).await;
            if let Ok(ctx) = ws_ctx {
                invalidate_git_status_cache(&ctx.root_path);
            }

            let msg = ServerMessage::GitStatusChanged { project, workspace };
            emit_message(socket, &msg, "Failed to send git status changed message").await;
        }
    }
}

pub(in crate::server::ws) async fn forward_command_output(
    msg: ServerMessage,
    socket: &mut WebSocket,
) {
    emit_message(socket, &msg, "Failed to send command output message").await;
}
