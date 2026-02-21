use std::path::PathBuf;

use crate::server::context::{resolve_workspace, HandlerContext};
use crate::server::protocol::ServerMessage;
use crate::server::ws::subscribe_terminal;

pub struct WorkspaceSelectionResult {
    pub message: ServerMessage,
    pub root_path: PathBuf,
}

pub async fn select_workspace_and_spawn_terminal(
    ctx: &HandlerContext,
    project: &str,
    workspace: &str,
) -> Result<WorkspaceSelectionResult, ServerMessage> {
    let ws_ctx = resolve_workspace(&ctx.app_state, project, workspace)
        .await
        .map_err(|e| e.to_server_error())?;

    let (session_id, shell_name) = {
        let mut reg = ctx.terminal_registry.lock().await;
        reg.spawn(
            Some(ws_ctx.root_path.clone()),
            Some(project.to_string()),
            Some(workspace.to_string()),
            ctx.scrollback_tx.clone(),
            None,
            None,
            None,
            None,
        )
        .map_err(|e| ServerMessage::Error {
            code: "spawn_error".to_string(),
            message: format!("Spawn error: {}", e),
        })?
    };

    subscribe_terminal(
        &session_id,
        &ctx.terminal_registry,
        &ctx.subscribed_terms,
        &ctx.agg_tx,
    )
    .await;

    let message = ServerMessage::SelectedWorkspace {
        project: project.to_string(),
        workspace: workspace.to_string(),
        root: ws_ctx.root_path.to_string_lossy().to_string(),
        session_id,
        shell: shell_name,
    };

    Ok(WorkspaceSelectionResult {
        message,
        root_path: ws_ctx.root_path,
    })
}

pub async fn cleanup_workspace_before_remove(
    ctx: &HandlerContext,
    project: &str,
    workspace: &str,
) -> Vec<String> {
    let _ = ctx.lsp_supervisor.stop_workspace(project, workspace).await;

    let mut reg = ctx.terminal_registry.lock().await;
    let term_ids: Vec<String> = reg
        .list()
        .into_iter()
        .filter(|t| t.project == project && t.workspace == workspace)
        .map(|t| t.term_id)
        .collect();

    for tid in &term_ids {
        reg.close(tid);
    }

    term_ids
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_selection_result_keeps_root_path() {
        let msg = ServerMessage::SelectedWorkspace {
            project: "p".to_string(),
            workspace: "w".to_string(),
            root: "/tmp/p".to_string(),
            session_id: "s".to_string(),
            shell: "zsh".to_string(),
        };
        let result = WorkspaceSelectionResult {
            message: msg,
            root_path: PathBuf::from("/tmp/p"),
        };
        assert_eq!(result.root_path, PathBuf::from("/tmp/p"));
    }
}
