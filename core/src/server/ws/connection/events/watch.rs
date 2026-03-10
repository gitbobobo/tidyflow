use crate::server::ws::OutboundTx as WebSocket;
use tracing::debug;

use crate::application::file::{invalidate_file_index_cache, update_file_index_incrementally};
use crate::server::context::{HandlerContext, SharedAppState};
use crate::server::git::status::invalidate_git_status_cache;
use crate::server::protocol::ServerMessage;
use crate::server::watcher::WatchEvent;

use super::common::emit_message;

/// 单次 FileChanged 事件中路径数量超过此阈值时，放弃增量更新，直接全量失效。
/// 避免大批量文件操作（如 npm install、git checkout）时做无效的逐条插入。
const INCREMENTAL_UPDATE_PATH_THRESHOLD: usize = 32;

pub(in crate::server::ws) async fn handle_watch_event(
    watch_event: WatchEvent,
    socket: &WebSocket,
    app_state: &SharedAppState,
    _handler_ctx: &HandlerContext,
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

            let ws_ctx =
                crate::server::context::resolve_workspace(app_state, &project, &workspace).await;
            if let Ok(ctx) = ws_ctx {
                invalidate_git_status_cache(&ctx.root_path);

                // 增量更新策略：
                // - 路径数量较少且 kind 明确时，尝试增量更新索引（避免全量重扫）
                // - 路径数量超过阈值时（如 npm install），直接失效让下次全量重建
                if paths.len() <= INCREMENTAL_UPDATE_PATH_THRESHOLD {
                    update_file_index_incrementally(&ctx.root_path, &paths, &kind);
                } else {
                    invalidate_file_index_cache(&ctx.root_path);
                }
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
                // Git 状态变化不影响文件路径列表，无需失效文件索引
            }

            let msg = ServerMessage::GitStatusChanged { project, workspace };
            emit_message(socket, &msg, "Failed to send git status changed message").await;
        }
    }
}

pub(in crate::server::ws) async fn forward_command_output(
    msg: ServerMessage,
    socket: &WebSocket,
) {
    emit_message(socket, &msg, "Failed to send command output message").await;
}
