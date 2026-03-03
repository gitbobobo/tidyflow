use crate::server::context::{HandlerContext, SharedAppState};
use crate::server::protocol::{ProjectCommandInfo, ProjectInfo, ServerMessage, WorkspaceInfo};
use crate::workspace::state::WorkspaceStatus;

pub fn workspace_status_str(status: &WorkspaceStatus) -> String {
    match status {
        WorkspaceStatus::Ready => "ready".to_string(),
        WorkspaceStatus::SetupFailed => "setup_failed".to_string(),
        WorkspaceStatus::Creating => "creating".to_string(),
        WorkspaceStatus::Initializing => "initializing".to_string(),
        WorkspaceStatus::Destroying => "destroying".to_string(),
    }
}

pub async fn list_projects_message(app_state: &SharedAppState) -> ServerMessage {
    let state = app_state.read().await;
    let mut items: Vec<ProjectInfo> = state
        .projects
        .values()
        .map(|p| ProjectInfo {
            name: p.name.clone(),
            root: p.root_path.to_string_lossy().to_string(),
            workspace_count: p.workspaces.len(),
            commands: p
                .commands
                .iter()
                .map(|c| ProjectCommandInfo {
                    id: c.id.clone(),
                    name: c.name.clone(),
                    icon: c.icon.clone(),
                    command: c.command.clone(),
                    blocking: c.blocking,
                    interactive: c.interactive,
                })
                .collect(),
        })
        .collect();
    items.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    ServerMessage::Projects { items }
}

pub async fn list_workspaces_message(
    ctx: &HandlerContext,
    project: &str,
) -> Result<ServerMessage, ServerMessage> {
    let (default_root, default_branch, mut workspace_rows) = {
        let state = ctx.app_state.read().await;
        let Some(p) = state.get_project(project) else {
            return Err(ServerMessage::Error {
                code: "project_not_found".to_string(),
                message: format!("Project '{}' not found", project),
            });
        };

        let rows = p
            .workspaces
            .values()
            .map(|w| {
                (
                    w.name.clone(),
                    w.worktree_path.to_string_lossy().to_string(),
                    w.branch.clone(),
                    workspace_status_str(&w.status),
                )
            })
            .collect::<Vec<_>>();

        (
            p.root_path.to_string_lossy().to_string(),
            p.default_branch.clone(),
            rows,
        )
    };

    workspace_rows.sort_by(|a, b| a.0.cmp(&b.0));

    let mut items: Vec<WorkspaceInfo> = Vec::with_capacity(workspace_rows.len() + 1);
    items.push(WorkspaceInfo {
        name: "default".to_string(),
        root: default_root,
        branch: default_branch,
        status: "ready".to_string(),
        sidebar_status: crate::application::sidebar_status::workspace_sidebar_status(
            ctx, project, "default",
        )
        .await,
    });

    for (name, root, branch, status) in workspace_rows {
        let sidebar_status =
            crate::application::sidebar_status::workspace_sidebar_status(ctx, project, &name).await;
        items.push(WorkspaceInfo {
            name,
            root,
            branch,
            status,
            sidebar_status,
        });
    }

    Ok(ServerMessage::Workspaces {
        project: project.to_string(),
        items,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::state::AppState;
    use std::sync::Arc;
    use tokio::sync::RwLock;

    #[tokio::test]
    async fn list_projects_sorts_by_name() {
        let mut state = AppState::default();
        state.add_project(crate::workspace::state::Project {
            name: "zeta".to_string(),
            root_path: "/tmp/zeta".into(),
            remote_url: None,
            default_branch: "main".to_string(),
            created_at: chrono::Utc::now(),
            workspaces: std::collections::HashMap::new(),
            commands: vec![],
        });
        state.add_project(crate::workspace::state::Project {
            name: "alpha".to_string(),
            root_path: "/tmp/alpha".into(),
            remote_url: None,
            default_branch: "main".to_string(),
            created_at: chrono::Utc::now(),
            workspaces: std::collections::HashMap::new(),
            commands: vec![],
        });

        let shared: SharedAppState = Arc::new(RwLock::new(state));
        let msg = list_projects_message(&shared).await;
        let ServerMessage::Projects { items } = msg else {
            panic!("expected projects message");
        };
        assert_eq!(items.first().map(|i| i.name.as_str()), Some("alpha"));
        assert_eq!(items.last().map(|i| i.name.as_str()), Some("zeta"));
    }
}
