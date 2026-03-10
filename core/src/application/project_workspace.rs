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

    // 更新 last_accessed：让资源管理器能按 LRU 顺序释放非活跃工作区缓存。
    // 在终端 spawn 前更新，确保切换成功后立刻反映访问时间。
    {
        let mut state = ctx.app_state.write().await;
        state.touch_workspace_last_accessed(project, workspace);
    }

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
            project: None,
            workspace: None,
            session_id: None,
            cycle_id: None,
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

    /// 验证 SelectedWorkspace 消息携带完整的 project/workspace/session_id 三元组，
    /// 保证客户端可以用这三个字段唯一定位工作区状态，不会在多工作区场景下串台。
    #[test]
    fn workspace_selection_result_carries_full_project_workspace_session_key() {
        let project = "proj-a";
        let workspace = "feature-branch";
        let session_id = "sess-xyz";

        let msg = ServerMessage::SelectedWorkspace {
            project: project.to_string(),
            workspace: workspace.to_string(),
            root: "/tmp/proj-a".to_string(),
            session_id: session_id.to_string(),
            shell: "bash".to_string(),
        };

        // 三元组必须在消息中完整保留，客户端依赖此做工作区状态隔离
        match &msg {
            ServerMessage::SelectedWorkspace {
                project: p,
                workspace: w,
                session_id: s,
                ..
            } => {
                assert_eq!(p, project, "project 字段丢失或错误");
                assert_eq!(w, workspace, "workspace 字段丢失或错误");
                assert_eq!(s, session_id, "session_id 字段丢失或错误");
                // 复合键格式验证：客户端用 "<project>:<workspace>" 做侧边栏状态隔离
                let composite_key = format!("{}:{}", p, w);
                assert_eq!(composite_key, "proj-a:feature-branch");
            }
            _ => panic!("应为 SelectedWorkspace 消息"),
        }
    }

    /// 验证不同 project/workspace 组合产生不同的复合键，防止状态串台。
    #[test]
    fn different_project_workspace_pairs_produce_unique_composite_keys() {
        let pairs = vec![
            ("proj-a", "main"),
            ("proj-a", "feature"),
            ("proj-b", "main"),
            ("proj-b", "feature"),
        ];

        let keys: std::collections::HashSet<String> =
            pairs.iter().map(|(p, w)| format!("{}:{}", p, w)).collect();

        assert_eq!(
            keys.len(),
            pairs.len(),
            "每个 project/workspace 组合应产生唯一复合键，避免多工作区状态串台"
        );
    }
}
