use crate::server::context::SharedAppState;
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
    app_state: &SharedAppState,
    project: &str,
) -> Result<ServerMessage, ServerMessage> {
    let state = app_state.read().await;
    match state.get_project(project) {
        Some(p) => {
            let mut items: Vec<WorkspaceInfo> = p
                .workspaces
                .values()
                .map(|w| WorkspaceInfo {
                    name: w.name.clone(),
                    root: w.worktree_path.to_string_lossy().to_string(),
                    branch: w.branch.clone(),
                    status: workspace_status_str(&w.status),
                })
                .collect();

            let default_ws = WorkspaceInfo {
                name: "default".to_string(),
                root: p.root_path.to_string_lossy().to_string(),
                branch: p.default_branch.clone(),
                status: "ready".to_string(),
            };
            items.insert(0, default_ws);

            Ok(ServerMessage::Workspaces {
                project: project.to_string(),
                items,
            })
        }
        None => Err(ServerMessage::Error {
            code: "project_not_found".to_string(),
            message: format!("Project '{}' not found", project),
        }),
    }
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
