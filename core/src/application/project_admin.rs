use std::path::PathBuf;

use crate::application::project::workspace_status_str;
use crate::server::context::SharedAppState;
use crate::server::protocol::{ProjectCommandInfo, ServerMessage, WorkspaceInfo};
use crate::workspace::project::ProjectManager;
use crate::workspace::workspace::WorkspaceManager;

pub async fn import_project_message(
    app_state: &SharedAppState,
    name: &str,
    path: &str,
) -> ServerMessage {
    let path_buf = PathBuf::from(path);
    let mut state = app_state.write().await;

    match ProjectManager::import_local(&mut state, name, &path_buf) {
        Ok(project) => ServerMessage::ProjectImported {
            name: name.to_string(),
            root: project.root_path.to_string_lossy().to_string(),
            default_branch: project.default_branch.clone(),
            workspace: None,
        },
        Err(e) => {
            let (code, message) = match &e {
                crate::workspace::project::ProjectError::AlreadyExists(_) => {
                    ("project_exists".to_string(), e.to_string())
                }
                crate::workspace::project::ProjectError::PathNotFound(_) => {
                    ("path_not_found".to_string(), e.to_string())
                }
                crate::workspace::project::ProjectError::NotGitRepo(_) => {
                    ("not_git_repo".to_string(), e.to_string())
                }
                _ => ("import_error".to_string(), e.to_string()),
            };
            ServerMessage::Error { code, message }
        }
    }
}

pub async fn create_workspace_message(
    app_state: &SharedAppState,
    project: &str,
    from_branch: Option<&str>,
) -> ServerMessage {
    let mut state = app_state.write().await;

    match WorkspaceManager::create(&mut state, project, from_branch, false) {
        Ok(ws) => ServerMessage::WorkspaceCreated {
            project: project.to_string(),
            workspace: WorkspaceInfo {
                name: ws.name,
                root: ws.worktree_path.to_string_lossy().to_string(),
                branch: ws.branch,
                status: workspace_status_str(&ws.status),
                sidebar_status: Default::default(),
            },
        },
        Err(e) => {
            let (code, message) = match &e {
                crate::workspace::workspace::WorkspaceError::AlreadyExists(_) => {
                    ("workspace_exists".to_string(), e.to_string())
                }
                crate::workspace::workspace::WorkspaceError::ProjectNotFound(_) => {
                    ("project_not_found".to_string(), e.to_string())
                }
                crate::workspace::workspace::WorkspaceError::NotGitRepo(_) => {
                    ("not_git_repo".to_string(), e.to_string())
                }
                _ => ("workspace_error".to_string(), e.to_string()),
            };
            ServerMessage::Error { code, message }
        }
    }
}

pub async fn remove_project_message(app_state: &SharedAppState, name: &str) -> ServerMessage {
    let mut state = app_state.write().await;

    match ProjectManager::remove(&mut state, name) {
        Ok(_) => ServerMessage::ProjectRemoved {
            name: name.to_string(),
            ok: true,
            message: Some("项目已移除".to_string()),
        },
        Err(e) => ServerMessage::ProjectRemoved {
            name: name.to_string(),
            ok: false,
            message: Some(e.to_string()),
        },
    }
}

pub async fn remove_workspace_message(
    app_state: &SharedAppState,
    project: &str,
    workspace: &str,
) -> ServerMessage {
    let mut state = app_state.write().await;

    match WorkspaceManager::remove(&mut state, project, workspace) {
        Ok(_) => ServerMessage::WorkspaceRemoved {
            project: project.to_string(),
            workspace: workspace.to_string(),
            ok: true,
            message: Some("工作空间已删除".to_string()),
        },
        Err(e) => ServerMessage::WorkspaceRemoved {
            project: project.to_string(),
            workspace: workspace.to_string(),
            ok: false,
            message: Some(e.to_string()),
        },
    }
}

pub async fn save_project_commands_message(
    app_state: &SharedAppState,
    project: &str,
    commands: &[ProjectCommandInfo],
) -> ServerMessage {
    let mut state = app_state.write().await;
    match state.get_project_mut(project) {
        Some(p) => {
            p.commands = commands
                .iter()
                .map(|c| crate::workspace::state::ProjectCommand {
                    id: c.id.clone(),
                    name: c.name.clone(),
                    icon: c.icon.clone(),
                    command: c.command.clone(),
                    blocking: c.blocking,
                    interactive: c.interactive,
                })
                .collect();

            ServerMessage::ProjectCommandsSaved {
                project: project.to_string(),
                ok: true,
                message: None,
            }
        }
        None => ServerMessage::ProjectCommandsSaved {
            project: project.to_string(),
            ok: false,
            message: Some(format!("Project '{}' not found", project)),
        },
    }
}

pub fn project_commands_saved_ok(msg: &ServerMessage) -> bool {
    matches!(msg, ServerMessage::ProjectCommandsSaved { ok: true, .. })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn project_commands_saved_ok_detects_success() {
        let ok_msg = ServerMessage::ProjectCommandsSaved {
            project: "p".to_string(),
            ok: true,
            message: None,
        };
        let fail_msg = ServerMessage::ProjectCommandsSaved {
            project: "p".to_string(),
            ok: false,
            message: Some("x".to_string()),
        };

        assert!(project_commands_saved_ok(&ok_msg));
        assert!(!project_commands_saved_ok(&fail_msg));
    }
}
