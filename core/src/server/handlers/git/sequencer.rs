//! Workspace sequencer handlers（cherry-pick、revert、rollback）

use crate::server::context::{resolve_workspace, SharedAppState};
use crate::server::git;
use crate::server::git::sequencer::{RollbackReceipt, WorkspaceOperationKind};
use crate::server::protocol::{ClientMessage, ConflictFileEntryInfo, ServerMessage};
use crate::server::ws::send_message;
use crate::server::ws::OutboundTx as WebSocket;

pub async fn handle_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::GitCherryPick {
            project,
            workspace,
            commit_shas,
        } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let root = ws_ctx.root_path;
            let shas = commit_shas.clone();
            let project_c = project.clone();
            let workspace_c = workspace.clone();
            let result = tokio::task::spawn_blocking(move || {
                let original_head =
                    git::sequencer::get_full_head_sha(&root).unwrap_or_default();
                let res = git::git_cherry_pick(&root, &shas);
                (res, original_head, root, shas)
            })
            .await;

            match result {
                Ok((Ok(seq_result), original_head, root, shas)) => {
                    if seq_result.ok && seq_result.state == "completed" {
                        let result_head =
                            git::sequencer::get_full_head_sha(&root).unwrap_or_default();
                        git::sequencer::save_rollback_receipt(
                            &project_c,
                            &workspace_c,
                            RollbackReceipt {
                                operation_kind: WorkspaceOperationKind::CherryPick,
                                original_head,
                                result_head,
                                commit_shas: shas,
                                created_at: chrono::Utc::now().to_rfc3339(),
                            },
                        );
                    }
                    send_sequencer_result(socket, &project_c, &workspace_c, &seq_result).await?;
                }
                Ok((Err(e), _, _, _)) => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "git_error".to_string(),
                            message: format!("Cherry-pick failed: {}", e),
                            project: None,
                            workspace: None,
                            session_id: None,
                            cycle_id: None,
                        },
                    )
                    .await?;
                }
                Err(e) => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "internal_error".to_string(),
                            message: format!("Cherry-pick task failed: {}", e),
                            project: None,
                            workspace: None,
                            session_id: None,
                            cycle_id: None,
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        ClientMessage::GitCherryPickContinue { project, workspace } => {
            handle_sequencer_continue_abort(
                socket,
                app_state,
                project,
                workspace,
                "cherry_pick_continue",
            )
            .await
        }

        ClientMessage::GitCherryPickAbort { project, workspace } => {
            handle_sequencer_continue_abort(
                socket,
                app_state,
                project,
                workspace,
                "cherry_pick_abort",
            )
            .await
        }

        ClientMessage::GitRevert {
            project,
            workspace,
            commit_shas,
        } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let root = ws_ctx.root_path;
            let shas = commit_shas.clone();
            let project_c = project.clone();
            let workspace_c = workspace.clone();
            let result = tokio::task::spawn_blocking(move || {
                let original_head =
                    git::sequencer::get_full_head_sha(&root).unwrap_or_default();
                let res = git::git_revert(&root, &shas);
                (res, original_head, root, shas)
            })
            .await;

            match result {
                Ok((Ok(seq_result), original_head, root, shas)) => {
                    if seq_result.ok && seq_result.state == "completed" {
                        let result_head =
                            git::sequencer::get_full_head_sha(&root).unwrap_or_default();
                        git::sequencer::save_rollback_receipt(
                            &project_c,
                            &workspace_c,
                            RollbackReceipt {
                                operation_kind: WorkspaceOperationKind::Revert,
                                original_head,
                                result_head,
                                commit_shas: shas,
                                created_at: chrono::Utc::now().to_rfc3339(),
                            },
                        );
                    }
                    send_sequencer_result(socket, &project_c, &workspace_c, &seq_result).await?;
                }
                Ok((Err(e), _, _, _)) => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "git_error".to_string(),
                            message: format!("Revert failed: {}", e),
                            project: None,
                            workspace: None,
                            session_id: None,
                            cycle_id: None,
                        },
                    )
                    .await?;
                }
                Err(e) => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "internal_error".to_string(),
                            message: format!("Revert task failed: {}", e),
                            project: None,
                            workspace: None,
                            session_id: None,
                            cycle_id: None,
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        ClientMessage::GitRevertContinue { project, workspace } => {
            handle_sequencer_continue_abort(
                socket,
                app_state,
                project,
                workspace,
                "revert_continue",
            )
            .await
        }

        ClientMessage::GitRevertAbort { project, workspace } => {
            handle_sequencer_continue_abort(
                socket,
                app_state,
                project,
                workspace,
                "revert_abort",
            )
            .await
        }

        ClientMessage::GitWorkspaceOpRollback { project, workspace } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let root = ws_ctx.root_path;
            let project_c = project.clone();
            let workspace_c = workspace.clone();
            let result = tokio::task::spawn_blocking(move || {
                git::git_workspace_op_rollback(&root, &project_c, &workspace_c)
            })
            .await;

            let (project_c, workspace_c) = (project.clone(), workspace.clone());
            match result {
                Ok(Ok(rb_result)) => {
                    send_message(
                        socket,
                        &ServerMessage::GitWorkspaceOpRollbackResult {
                            project: project_c,
                            workspace: workspace_c,
                            ok: rb_result.ok,
                            message: rb_result.message,
                        },
                    )
                    .await?;
                }
                Ok(Err(e)) => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "git_error".to_string(),
                            message: format!("Rollback failed: {}", e),
                            project: None,
                            workspace: None,
                            session_id: None,
                            cycle_id: None,
                        },
                    )
                    .await?;
                }
                Err(e) => {
                    send_message(
                        socket,
                        &ServerMessage::Error {
                            code: "internal_error".to_string(),
                            message: format!("Rollback task failed: {}", e),
                            project: None,
                            workspace: None,
                            session_id: None,
                            cycle_id: None,
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

async fn handle_sequencer_continue_abort(
    socket: &WebSocket,
    app_state: &SharedAppState,
    project: &str,
    workspace: &str,
    op: &str,
) -> Result<bool, String> {
    let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
        Ok(ctx) => ctx,
        Err(e) => {
            send_message(socket, &e.to_server_error()).await?;
            return Ok(true);
        }
    };

    let root = ws_ctx.root_path;
    let op_str = op.to_string();
    let project_c = project.to_string();
    let workspace_c = workspace.to_string();

    let result = tokio::task::spawn_blocking(move || {
        match op_str.as_str() {
            "cherry_pick_continue" => git::git_cherry_pick_continue(&root),
            "cherry_pick_abort" => {
                let r = git::git_cherry_pick_abort(&root);
                if r.as_ref().is_ok_and(|r| r.ok) {
                    git::sequencer::clear_rollback_receipt(&project_c, &workspace_c);
                }
                r
            }
            "revert_continue" => git::git_revert_continue(&root),
            "revert_abort" => {
                let r = git::git_revert_abort(&root);
                if r.as_ref().is_ok_and(|r| r.ok) {
                    git::sequencer::clear_rollback_receipt(&project_c, &workspace_c);
                }
                r
            }
            _ => Err(git::GitError::CommandFailed(format!(
                "Unknown op: {}",
                op_str
            ))),
        }
    })
    .await;

    let (project_c, workspace_c) = (project.to_string(), workspace.to_string());
    match result {
        Ok(Ok(seq_result)) => {
            send_sequencer_result(socket, &project_c, &workspace_c, &seq_result).await?;
        }
        Ok(Err(e)) => {
            send_message(
                socket,
                &ServerMessage::Error {
                    code: "git_error".to_string(),
                    message: format!("Git operation failed: {}", e),
                    project: None,
                    workspace: None,
                    session_id: None,
                    cycle_id: None,
                },
            )
            .await?;
        }
        Err(e) => {
            send_message(
                socket,
                &ServerMessage::Error {
                    code: "internal_error".to_string(),
                    message: format!("Git task failed: {}", e),
                    project: None,
                    workspace: None,
                    session_id: None,
                    cycle_id: None,
                },
            )
            .await?;
        }
    }
    Ok(true)
}

async fn send_sequencer_result(
    socket: &WebSocket,
    project: &str,
    workspace: &str,
    result: &git::SequencerResult,
) -> Result<(), String> {
    send_message(
        socket,
        &ServerMessage::GitSequencerResult {
            project: project.to_string(),
            workspace: workspace.to_string(),
            operation_kind: result.operation_kind.as_str().to_string(),
            ok: result.ok,
            state: result.state.clone(),
            message: result.message.clone(),
            conflicts: result.conflicts.clone(),
            conflict_files: result
                .conflict_files
                .iter()
                .map(|f| ConflictFileEntryInfo {
                    path: f.path.clone(),
                    conflict_type: f.conflict_type.clone(),
                    staged: f.staged,
                })
                .collect(),
            completed_count: result.completed_count,
            pending_count: result.pending_count,
            current_commit: result.current_commit.clone(),
        },
    )
    .await
}
