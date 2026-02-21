use std::path::Path;
use std::sync::Arc;

use tokio::io::AsyncBufReadExt;
use tokio::sync::Mutex;
use tracing::{info, warn};

use crate::server::context::{
    push_task_history, update_task_history, HandlerContext, RunningCommandEntry,
    TaskBroadcastEvent, TaskHistoryEntry,
};
use crate::server::protocol::ServerMessage;

pub struct HandlerReply {
    pub response: ServerMessage,
    pub broadcast: Option<ServerMessage>,
}

pub async fn run_project_command(
    ctx: &HandlerContext,
    project: &str,
    workspace: &str,
    command_id: &str,
) -> HandlerReply {
    let (command_text, command_name, cwd) = {
        let state = ctx.app_state.read().await;
        match state.get_project(project) {
            Some(p) => {
                let ws_root = if workspace == "default" {
                    Some(p.root_path.clone())
                } else {
                    p.get_workspace(workspace).map(|w| w.worktree_path.clone())
                };

                match (p.commands.iter().find(|c| c.id == command_id), ws_root) {
                    (Some(cmd), Some(cwd)) => (cmd.command.clone(), cmd.name.clone(), cwd),
                    _ => {
                        return HandlerReply {
                            response: ServerMessage::Error {
                                code: "command_not_found".to_string(),
                                message: format!(
                                    "Command '{}' not found or workspace '{}' not found",
                                    command_id, workspace
                                ),
                            },
                            broadcast: None,
                        };
                    }
                }
            }
            None => {
                return HandlerReply {
                    response: ServerMessage::Error {
                        code: "project_not_found".to_string(),
                        message: format!("Project '{}' not found", project),
                    },
                    broadcast: None,
                };
            }
        }
    };

    let task_id = uuid::Uuid::new_v4().to_string();

    let started_msg = ServerMessage::ProjectCommandStarted {
        project: project.to_string(),
        workspace: workspace.to_string(),
        command_id: command_id.to_string(),
        task_id: task_id.clone(),
    };

    let mut child = match tokio::process::Command::new(preferred_login_shell())
        .arg("-l")
        .arg("-c")
        .arg(&command_text)
        .current_dir(&cwd)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(e) => {
            let msg = ServerMessage::ProjectCommandCompleted {
                project: project.to_string(),
                workspace: workspace.to_string(),
                command_id: command_id.to_string(),
                task_id,
                ok: false,
                message: Some(format!("执行失败: {}", e)),
            };
            let _ = ctx.cmd_output_tx.send(msg.clone()).await;
            let _ = ctx.task_broadcast_tx.send(TaskBroadcastEvent {
                origin_conn_id: ctx.conn_meta.conn_id.clone(),
                message: msg,
            });
            return HandlerReply {
                response: started_msg.clone(),
                broadcast: Some(started_msg),
            };
        }
    };

    let stdout_pipe = child.stdout.take();
    let stderr_pipe = child.stderr.take();

    ctx.running_commands.lock().await.insert(
        task_id.clone(),
        RunningCommandEntry {
            task_id: task_id.clone(),
            project: project.to_string(),
            workspace: workspace.to_string(),
            command_id: command_id.to_string(),
            child,
        },
    );

    push_task_history(
        &ctx.task_history,
        TaskHistoryEntry {
            task_id: task_id.clone(),
            project: project.to_string(),
            workspace: workspace.to_string(),
            task_type: "project_command".to_string(),
            command_id: Some(command_id.to_string()),
            title: command_name,
            status: "running".to_string(),
            message: None,
            started_at: chrono::Utc::now().timestamp_millis(),
            completed_at: None,
        },
    )
    .await;

    let tx = ctx.cmd_output_tx.clone();
    let rc = ctx.running_commands.clone();
    let broadcast_tx = ctx.task_broadcast_tx.clone();
    let origin_conn_id = ctx.conn_meta.conn_id.clone();
    let task_history = ctx.task_history.clone();
    let p = project.to_string();
    let w = workspace.to_string();
    let c = command_id.to_string();
    let tid = task_id.clone();

    tokio::spawn(async move {
        let collected = Arc::new(Mutex::new(Vec::<String>::new()));

        let stdout_collected = collected.clone();
        let stdout_tx = tx.clone();
        let stdout_broadcast_tx = broadcast_tx.clone();
        let stdout_origin = origin_conn_id.clone();
        let stdout_tid = tid.clone();
        let stdout_handle = tokio::spawn(async move {
            if let Some(pipe) = stdout_pipe {
                let reader = tokio::io::BufReader::new(pipe);
                let mut lines = reader.lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    stdout_collected.lock().await.push(line.clone());
                    let msg = ServerMessage::ProjectCommandOutput {
                        task_id: stdout_tid.clone(),
                        line,
                    };
                    let _ = stdout_tx.send(msg.clone()).await;
                    let _ = stdout_broadcast_tx.send(TaskBroadcastEvent {
                        origin_conn_id: stdout_origin.clone(),
                        message: msg,
                    });
                }
            }
        });

        let stderr_collected = collected.clone();
        let stderr_tx = tx.clone();
        let stderr_broadcast_tx = broadcast_tx.clone();
        let stderr_origin = origin_conn_id.clone();
        let stderr_tid = tid.clone();
        let stderr_handle = tokio::spawn(async move {
            if let Some(pipe) = stderr_pipe {
                let reader = tokio::io::BufReader::new(pipe);
                let mut lines = reader.lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    stderr_collected.lock().await.push(line.clone());
                    let msg = ServerMessage::ProjectCommandOutput {
                        task_id: stderr_tid.clone(),
                        line,
                    };
                    let _ = stderr_tx.send(msg.clone()).await;
                    let _ = stderr_broadcast_tx.send(TaskBroadcastEvent {
                        origin_conn_id: stderr_origin.clone(),
                        message: msg,
                    });
                }
            }
        });

        let _ = stdout_handle.await;
        let _ = stderr_handle.await;

        let mut command_entry = {
            let mut cmds = rc.lock().await;
            cmds.remove(&tid)
        };
        let wait_result = if let Some(entry) = command_entry.as_mut() {
            Some(entry.child.wait().await)
        } else {
            None
        };

        let exit_status = match wait_result {
            Some(Ok(status)) => status,
            Some(Err(e)) => {
                update_task_history(
                    &task_history,
                    &tid,
                    "failed",
                    Some(format!("执行失败: {}", e)),
                )
                .await;
                let msg = ServerMessage::ProjectCommandCompleted {
                    project: p,
                    workspace: w,
                    command_id: c,
                    task_id: tid,
                    ok: false,
                    message: Some(format!("执行失败: {}", e)),
                };
                let _ = tx.send(msg.clone()).await;
                let _ = broadcast_tx.send(TaskBroadcastEvent {
                    origin_conn_id: origin_conn_id.clone(),
                    message: msg,
                });
                return;
            }
            None => return,
        };

        let all_lines = collected.lock().await;
        let message = summarize_command_output(&all_lines);
        let ok = exit_status.success();

        info!(
            "ProjectCommand completed: project={}, command_id={}, ok={}",
            p, c, ok
        );

        let _ = tx
            .send(ServerMessage::ProjectCommandCompleted {
                project: p.clone(),
                workspace: w.clone(),
                command_id: c.clone(),
                task_id: tid.clone(),
                ok,
                message: Some(message.clone()),
            })
            .await;
        let _ = broadcast_tx.send(TaskBroadcastEvent {
            origin_conn_id,
            message: ServerMessage::ProjectCommandCompleted {
                project: p,
                workspace: w,
                command_id: c,
                task_id: tid.clone(),
                ok,
                message: Some(message.clone()),
            },
        });
        let status = if ok { "completed" } else { "failed" };
        update_task_history(&task_history, &tid, status, Some(message)).await;
    });

    HandlerReply {
        response: started_msg.clone(),
        broadcast: Some(started_msg),
    }
}

pub async fn cancel_project_command(
    ctx: &HandlerContext,
    project: &str,
    workspace: &str,
    command_id: &str,
    task_id: Option<&str>,
) -> HandlerReply {
    let mut command_entry = {
        let mut cmds = ctx.running_commands.lock().await;
        if let Some(request_task_id) = task_id {
            let matched = cmds
                .get(request_task_id)
                .map(|entry| {
                    entry.project == project
                        && entry.workspace == workspace
                        && entry.command_id == command_id
                })
                .unwrap_or(false);
            if matched {
                cmds.remove(request_task_id)
            } else {
                None
            }
        } else {
            let matched_task_id = cmds
                .iter()
                .find(|(_, entry)| {
                    entry.project == project
                        && entry.workspace == workspace
                        && entry.command_id == command_id
                })
                .map(|(id, _)| id.clone());
            matched_task_id.and_then(|id| cmds.remove(&id))
        }
    };

    let Some(mut entry) = command_entry.take() else {
        return HandlerReply {
            response: ServerMessage::Error {
                code: "command_not_running".to_string(),
                message: "No matching running command".to_string(),
            },
            broadcast: None,
        };
    };

    let cancelled_task_id = entry.task_id.clone();
    if let Err(e) = entry.child.kill().await {
        ctx.running_commands
            .lock()
            .await
            .insert(cancelled_task_id.clone(), entry);
        warn!(
            "Failed to kill command process {} (project={}, workspace={}, command_id={}): {}",
            cancelled_task_id, project, workspace, command_id, e
        );
        return HandlerReply {
            response: ServerMessage::Error {
                code: "cancel_failed".to_string(),
                message: format!("Failed to cancel running command: {}", e),
            },
            broadcast: None,
        };
    }

    info!(
        "ProjectCommand cancelled: project={}, command_id={}, task_id={}",
        project, command_id, cancelled_task_id
    );
    let cancelled_msg = ServerMessage::ProjectCommandCancelled {
        project: project.to_string(),
        workspace: workspace.to_string(),
        command_id: command_id.to_string(),
        task_id: cancelled_task_id.clone(),
    };
    update_task_history(
        &ctx.task_history,
        &cancelled_task_id,
        "cancelled",
        Some("已取消".to_string()),
    )
    .await;

    HandlerReply {
        response: cancelled_msg.clone(),
        broadcast: Some(cancelled_msg),
    }
}

fn preferred_login_shell() -> &'static str {
    if Path::new("/bin/zsh").exists() {
        "/bin/zsh"
    } else {
        "/bin/bash"
    }
}

fn summarize_command_output(lines: &[String]) -> String {
    let combined = lines.join("\n");
    if combined.len() > 4096 {
        format!("{}...(truncated)", &combined[..4096])
    } else {
        combined
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summarize_command_output_truncates_long_text() {
        let long = "a".repeat(5000);
        let msg = summarize_command_output(&[long]);
        assert!(msg.ends_with("...(truncated)"));
        assert!(msg.len() > 4096);
    }

    #[test]
    fn preferred_login_shell_returns_known_shell() {
        let shell = preferred_login_shell();
        assert!(shell == "/bin/zsh" || shell == "/bin/bash");
    }

    #[test]
    fn summarize_command_output_keeps_short_text() {
        let msg = summarize_command_output(&["line1".to_string(), "line2".to_string()]);
        assert_eq!(msg, "line1\nline2");
    }

    #[test]
    fn preferred_login_shell_fallback_when_zsh_missing() {
        let chosen = if Path::new("/bin/zsh").exists() {
            "/bin/zsh"
        } else {
            "/bin/bash"
        };
        assert_eq!(preferred_login_shell(), chosen);
    }
}
