use axum::extract::ws::WebSocket;
use std::path::PathBuf;

use crate::server::protocol::ClientMessage;
use crate::server::ws::SharedAppState;
use crate::workspace::state::Project;

mod branch_commit;
mod history;
mod integration;
mod stage_ops;
mod status_diff;

/// 获取工作空间的根路径,支持 "default" 虚拟工作空间
/// 如果 workspace 是 "default"，返回项目根目录
fn get_workspace_root(project: &Project, workspace: &str) -> Option<PathBuf> {
    if workspace == "default" {
        Some(project.root_path.clone())
    } else {
        project
            .get_workspace(workspace)
            .map(|w| w.worktree_path.clone())
    }
}

/// 处理 Git 相关的客户端消息
pub async fn handle_git_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    if status_diff::try_handle_git_message(client_msg, socket, app_state).await? {
        return Ok(true);
    }

    if stage_ops::try_handle_git_message(client_msg, socket, app_state).await? {
        return Ok(true);
    }

    if branch_commit::try_handle_git_message(client_msg, socket, app_state).await? {
        return Ok(true);
    }

    if integration::try_handle_git_message(client_msg, socket, app_state).await? {
        return Ok(true);
    }

    if history::try_handle_git_message(client_msg, socket, app_state).await? {
        return Ok(true);
    }

    Ok(false)
}
