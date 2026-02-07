use axum::extract::ws::WebSocket;

use crate::server::git;
use crate::server::protocol::{ClientMessage, GitBranchInfo, ServerMessage};
use crate::server::ws::{send_message, SharedAppState};

use super::get_workspace_root;

pub async fn try_handle_git_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    match client_msg {
        // v1.8: Git branches
        ClientMessage::GitBranches { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => match get_workspace_root(p, workspace) {
                    Some(root) => {
                        drop(state);

                        let result =
                            tokio::task::spawn_blocking(move || git::git_branches(&root)).await;

                        match result {
                            Ok(Ok(branches_result)) => {
                                let branches: Vec<GitBranchInfo> = branches_result
                                    .branches
                                    .into_iter()
                                    .map(|b| GitBranchInfo { name: b.name })
                                    .collect();

                                send_message(
                                    socket,
                                    &ServerMessage::GitBranchesResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        current: branches_result.current,
                                        branches,
                                    },
                                )
                                .await?;
                            }
                            Ok(Err(e)) => {
                                send_message(
                                    socket,
                                    &ServerMessage::Error {
                                        code: "git_error".to_string(),
                                        message: format!("Git branches failed: {}", e),
                                    },
                                )
                                .await?;
                            }
                            Err(e) => {
                                send_message(
                                    socket,
                                    &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git branches task failed: {}", e),
                                    },
                                )
                                .await?;
                            }
                        }
                    }
                    None => {
                        send_message(
                            socket,
                            &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            },
                        )
                        .await?;
                    }
                },
                None => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "project_not_found".to_string(),
                            message: format!("Project '{}' not found", project),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        // v1.8: Git switch branch
        ClientMessage::GitSwitchBranch {
            project,
            workspace,
            branch,
        } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => match get_workspace_root(p, workspace) {
                    Some(root) => {
                        drop(state);

                        let branch_clone = branch.clone();
                        let result = tokio::task::spawn_blocking(move || {
                            git::git_switch_branch(&root, &branch_clone)
                        })
                        .await;

                        match result {
                            Ok(Ok(op_result)) => {
                                send_message(
                                    socket,
                                    &ServerMessage::GitOpResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        op: op_result.op,
                                        ok: op_result.ok,
                                        message: op_result.message,
                                        path: op_result.path,
                                        scope: op_result.scope,
                                    },
                                )
                                .await?;
                            }
                            Ok(Err(e)) => {
                                send_message(
                                    socket,
                                    &ServerMessage::GitOpResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        op: "switch_branch".to_string(),
                                        ok: false,
                                        message: Some(format!("{}", e)),
                                        path: Some(branch.clone()),
                                        scope: "branch".to_string(),
                                    },
                                )
                                .await?;
                            }
                            Err(e) => {
                                send_message(
                                    socket,
                                    &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git switch branch task failed: {}", e),
                                    },
                                )
                                .await?;
                            }
                        }
                    }
                    None => {
                        send_message(
                            socket,
                            &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            },
                        )
                        .await?;
                    }
                },
                None => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "project_not_found".to_string(),
                            message: format!("Project '{}' not found", project),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        // v1.9: Git create branch
        ClientMessage::GitCreateBranch {
            project,
            workspace,
            branch,
        } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => match get_workspace_root(p, workspace) {
                    Some(root) => {
                        drop(state);

                        let branch_clone = branch.clone();
                        let result = tokio::task::spawn_blocking(move || {
                            git::git_create_branch(&root, &branch_clone)
                        })
                        .await;

                        match result {
                            Ok(Ok(op_result)) => {
                                send_message(
                                    socket,
                                    &ServerMessage::GitOpResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        op: op_result.op,
                                        ok: op_result.ok,
                                        message: op_result.message,
                                        path: op_result.path,
                                        scope: op_result.scope,
                                    },
                                )
                                .await?;
                            }
                            Ok(Err(e)) => {
                                send_message(
                                    socket,
                                    &ServerMessage::GitOpResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        op: "create_branch".to_string(),
                                        ok: false,
                                        message: Some(format!("{}", e)),
                                        path: Some(branch.clone()),
                                        scope: "branch".to_string(),
                                    },
                                )
                                .await?;
                            }
                            Err(e) => {
                                send_message(
                                    socket,
                                    &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git create branch task failed: {}", e),
                                    },
                                )
                                .await?;
                            }
                        }
                    }
                    None => {
                        send_message(
                            socket,
                            &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            },
                        )
                        .await?;
                    }
                },
                None => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "project_not_found".to_string(),
                            message: format!("Project '{}' not found", project),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        // v1.10: Git commit
        ClientMessage::GitCommit {
            project,
            workspace,
            message,
        } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => match get_workspace_root(p, workspace) {
                    Some(root) => {
                        drop(state);

                        let message_clone = message.clone();
                        let result = tokio::task::spawn_blocking(move || {
                            git::git_commit(&root, &message_clone)
                        })
                        .await;

                        match result {
                            Ok(Ok(commit_result)) => {
                                send_message(
                                    socket,
                                    &ServerMessage::GitCommitResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        ok: commit_result.ok,
                                        message: commit_result.message,
                                        sha: commit_result.sha,
                                    },
                                )
                                .await?;
                            }
                            Ok(Err(e)) => {
                                send_message(
                                    socket,
                                    &ServerMessage::GitCommitResult {
                                        project: project.clone(),
                                        workspace: workspace.clone(),
                                        ok: false,
                                        message: Some(format!("{}", e)),
                                        sha: None,
                                    },
                                )
                                .await?;
                            }
                            Err(e) => {
                                send_message(
                                    socket,
                                    &ServerMessage::Error {
                                        code: "internal_error".to_string(),
                                        message: format!("Git commit task failed: {}", e),
                                    },
                                )
                                .await?;
                            }
                        }
                    }
                    None => {
                        send_message(
                            socket,
                            &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            },
                        )
                        .await?;
                    }
                },
                None => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "project_not_found".to_string(),
                            message: format!("Project '{}' not found", project),
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
