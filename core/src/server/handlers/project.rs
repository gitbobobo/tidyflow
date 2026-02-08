use axum::extract::ws::WebSocket;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio::task::JoinHandle;
use tracing::{info, warn};

use crate::server::protocol::{
    ClientMessage, ProjectInfo, ServerMessage, WorkspaceInfo,
};
use crate::server::terminal_registry::SharedTerminalRegistry;
use crate::server::ws::{send_message, subscribe_terminal, SharedAppState};
use crate::workspace::project::ProjectManager;
use crate::workspace::state::WorkspaceStatus;
use crate::workspace::workspace::WorkspaceManager;

/// 处理项目和工作空间相关的客户端消息
pub async fn handle_project_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    registry: &SharedTerminalRegistry,
    app_state: &SharedAppState,
    scrollback_tx: &tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
    subscribed_terms: &Arc<Mutex<HashMap<String, JoinHandle<()>>>>,
    agg_tx: &tokio::sync::mpsc::Sender<(String, Vec<u8>)>,
) -> Result<bool, String> {
    match client_msg {
        // v1: List projects
        ClientMessage::ListProjects => {
            let state = app_state.lock().await;
            let mut items: Vec<ProjectInfo> = state
                .projects
                .values()
                .map(|p| ProjectInfo {
                    name: p.name.clone(),
                    root: p.root_path.to_string_lossy().to_string(),
                    workspace_count: p.workspaces.len(),
                })
                .collect();
            // HashMap 迭代顺序不稳定；在服务端固定字母序，避免客户端启动时顺序随机
            items.sort_by(|a, b| {
                a.name.to_lowercase().cmp(&b.name.to_lowercase())
            });
            send_message(socket, &ServerMessage::Projects { items })
                .await?;
            Ok(true)
        }

        // v1: List workspaces for a project
        ClientMessage::ListWorkspaces { project } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => {
                    let mut items: Vec<WorkspaceInfo> = p
                        .workspaces
                        .values()
                        .map(|w| WorkspaceInfo {
                            name: w.name.clone(),
                            root: w.worktree_path
                                .to_string_lossy()
                                .to_string(),
                            branch: w.branch.clone(),
                            status: match w.status {
                                WorkspaceStatus::Ready => {
                                    "ready".to_string()
                                }
                                WorkspaceStatus::SetupFailed => {
                                    "setup_failed".to_string()
                                }
                                WorkspaceStatus::Creating => {
                                    "creating".to_string()
                                }
                                WorkspaceStatus::Initializing => {
                                    "initializing".to_string()
                                }
                                WorkspaceStatus::Destroying => {
                                    "destroying".to_string()
                                }
                            },
                        })
                        .collect();

                    let default_ws = WorkspaceInfo {
                        name: "default".to_string(),
                        root: p.root_path.to_string_lossy().to_string(),
                        branch: p.default_branch.clone(),
                        status: "ready".to_string(),
                    };
                    items.insert(0, default_ws);

                    send_message(
                        socket,
                        &ServerMessage::Workspaces {
                            project: project.clone(),
                            items,
                        },
                    )
                    .await?;
                }
                None => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "project_not_found".to_string(),
                            message: format!(
                                "Project '{}' not found",
                                project
                            ),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        // v1.2: Select workspace and spawn terminal
        ClientMessage::SelectWorkspace { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => {
                    let (root_path, _branch) = if workspace == "default" {
                        (p.root_path.clone(), p.default_branch.clone())
                    } else {
                        match p.get_workspace(workspace) {
                            Some(w) => {
                                (w.worktree_path.clone(), w.branch.clone())
                            }
                            None => {
                                drop(state);
                                send_message(
                                    socket,
                                    &ServerMessage::Error {
                                        code: "workspace_not_found"
                                            .to_string(),
                                        message: format!(
                                            "Workspace '{}' not found in project '{}'",
                                            workspace, project
                                        ),
                                    },
                                )
                                .await?;
                                return Ok(true);
                            }
                        }
                    };
                    drop(state);

                    let (session_id, shell_name) = {
                        let mut reg = registry.lock().await;
                        reg.spawn(
                            Some(root_path.clone()),
                            Some(project.clone()),
                            Some(workspace.clone()),
                            scrollback_tx.clone(),
                        )
                        .map_err(|e| format!("Spawn error: {}", e))?
                    };

                    // 自动订阅新创建的终端
                    subscribe_terminal(
                        &session_id,
                        registry,
                        subscribed_terms,
                        agg_tx,
                    )
                    .await;

                    info!(
                        project = %project,
                        workspace = %workspace,
                        root = %root_path.display(),
                        term_id = %session_id,
                        "Terminal spawned in workspace"
                    );

                    send_message(
                        socket,
                        &ServerMessage::SelectedWorkspace {
                            project: project.clone(),
                            workspace: workspace.clone(),
                            root: root_path.to_string_lossy().to_string(),
                            session_id,
                            shell: shell_name,
                        },
                    )
                    .await?;
                }
                None => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "project_not_found".to_string(),
                            message: format!(
                                "Project '{}' not found",
                                project
                            ),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        // v1.16: Import project
        ClientMessage::ImportProject { name, path } => {
            info!("ImportProject request: name={}, path={}", name, path);
            let path_buf = PathBuf::from(&path);
            info!("Acquiring app_state lock...");
            let mut state = app_state.lock().await;
            info!(
                "app_state lock acquired, calling ProjectManager::import_local"
            );

            match ProjectManager::import_local(&mut state, name, &path_buf) {
                Ok(project) => {
                    info!(
                        "Project imported successfully: {}",
                        project.name
                    );
                    let default_branch = project.default_branch.clone();
                    let root =
                        project.root_path.to_string_lossy().to_string();

                    info!("Sending ProjectImported response...");
                    send_message(
                        socket,
                        &ServerMessage::ProjectImported {
                            name: name.clone(),
                            root,
                            default_branch,
                            workspace: None,
                        },
                    )
                    .await?;
                    info!("ProjectImported response sent successfully");
                }
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
                    send_message(
                        socket,
                        &ServerMessage::Error { code, message },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        // v1.16: Create workspace
        ClientMessage::CreateWorkspace {
            project,
            from_branch,
        } => {
            let mut state = app_state.lock().await;

            match WorkspaceManager::create(
                &mut state,
                project,
                from_branch.as_deref(),
                false,
            ) {
                Ok(ws) => {
                    send_message(
                        socket,
                        &ServerMessage::WorkspaceCreated {
                            project: project.clone(),
                            workspace: WorkspaceInfo {
                                name: ws.name,
                                root: ws
                                    .worktree_path
                                    .to_string_lossy()
                                    .to_string(),
                                branch: ws.branch,
                                status: match ws.status {
                                    WorkspaceStatus::Ready => {
                                        "ready".to_string()
                                    }
                                    WorkspaceStatus::SetupFailed => {
                                        "setup_failed".to_string()
                                    }
                                    WorkspaceStatus::Creating => {
                                        "creating".to_string()
                                    }
                                    WorkspaceStatus::Initializing => {
                                        "initializing".to_string()
                                    }
                                    WorkspaceStatus::Destroying => {
                                        "destroying".to_string()
                                    }
                                },
                            },
                        },
                    )
                    .await?;
                }
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
                        _ => {
                            ("workspace_error".to_string(), e.to_string())
                        }
                    };
                    send_message(
                        socket,
                        &ServerMessage::Error { code, message },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        // v1.17: Remove project
        ClientMessage::RemoveProject { name } => {
            info!("RemoveProject request: name={}", name);
            let mut state = app_state.lock().await;

            match ProjectManager::remove(&mut state, name) {
                Ok(_) => {
                    info!("Project removed successfully: {}", name);
                    send_message(
                        socket,
                        &ServerMessage::ProjectRemoved {
                            name: name.clone(),
                            ok: true,
                            message: Some("项目已移除".to_string()),
                        },
                    )
                    .await?;
                }
                Err(e) => {
                    warn!(
                        "Failed to remove project: {}, error: {}",
                        name, e
                    );
                    send_message(
                        socket,
                        &ServerMessage::ProjectRemoved {
                            name: name.clone(),
                            ok: false,
                            message: Some(e.to_string()),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        // v1.18: Remove workspace
        ClientMessage::RemoveWorkspace { project, workspace } => {
            info!(
                "RemoveWorkspace request: project={}, workspace={}",
                project, workspace
            );

            // 关闭该工作空间的所有终端
            {
                let mut reg = registry.lock().await;
                let term_ids: Vec<String> = reg
                    .list()
                    .into_iter()
                    .filter(|t| t.project == *project && t.workspace == *workspace)
                    .map(|t| t.term_id)
                    .collect();
                for tid in &term_ids {
                    reg.close(tid);
                    info!("Closed terminal {} for workspace {}/{}", tid, project, workspace);
                }
            }

            let mut state = app_state.lock().await;

            match WorkspaceManager::remove(&mut state, project, workspace) {
                Ok(_) => {
                    info!(
                        "Workspace removed successfully: {} / {}",
                        project, workspace
                    );
                    send_message(
                        socket,
                        &ServerMessage::WorkspaceRemoved {
                            project: project.clone(),
                            workspace: workspace.clone(),
                            ok: true,
                            message: Some("工作空间已删除".to_string()),
                        },
                    )
                    .await?;
                }
                Err(e) => {
                    warn!(
                        "Failed to remove workspace: {} / {}, error: {}",
                        project, workspace, e
                    );
                    send_message(
                        socket,
                        &ServerMessage::WorkspaceRemoved {
                            project: project.clone(),
                            workspace: workspace.clone(),
                            ok: false,
                            message: Some(e.to_string()),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        _ => Ok(false),
    }
}
