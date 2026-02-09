use axum::extract::ws::WebSocket;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::AsyncBufReadExt;
use tokio::sync::Mutex;
use tracing::{info, warn};

use crate::server::context::{resolve_workspace, HandlerContext};
use crate::server::protocol::{
    ClientMessage, ProjectCommandInfo, ProjectInfo, ServerMessage, WorkspaceInfo,
};
use crate::server::ws::{send_message, subscribe_terminal};
use crate::workspace::project::ProjectManager;
use crate::workspace::state::WorkspaceStatus;
use crate::workspace::workspace::WorkspaceManager;

/// WorkspaceStatus → 协议字符串（统一映射，消除重复）
fn ws_status_str(status: &WorkspaceStatus) -> String {
    match status {
        WorkspaceStatus::Ready => "ready".to_string(),
        WorkspaceStatus::SetupFailed => "setup_failed".to_string(),
        WorkspaceStatus::Creating => "creating".to_string(),
        WorkspaceStatus::Initializing => "initializing".to_string(),
        WorkspaceStatus::Destroying => "destroying".to_string(),
    }
}

/// 处理项目和工作空间相关的客户端消息
pub async fn handle_project_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    match client_msg {
        // v1: List projects
        ClientMessage::ListProjects => {
            let state = ctx.app_state.read().await;
            let mut items: Vec<ProjectInfo> = state
                .projects
                .values()
                .map(|p| ProjectInfo {
                    name: p.name.clone(),
                    root: p.root_path.to_string_lossy().to_string(),
                    workspace_count: p.workspaces.len(),
                    commands: p.commands.iter().map(|c| ProjectCommandInfo {
                        id: c.id.clone(),
                        name: c.name.clone(),
                        icon: c.icon.clone(),
                        command: c.command.clone(),
                        blocking: c.blocking,
                    }).collect(),
                })
                .collect();
            // HashMap 迭代顺序不稳定；在服务端固定字母序
            items.sort_by(|a, b| {
                a.name.to_lowercase().cmp(&b.name.to_lowercase())
            });
            send_message(socket, &ServerMessage::Projects { items })
                .await?;
            Ok(true)
        }

        // v1: List workspaces for a project
        ClientMessage::ListWorkspaces { project } => {
            let state = ctx.app_state.read().await;
            match state.get_project(project) {
                Some(p) => {
                    let mut items: Vec<WorkspaceInfo> = p
                        .workspaces
                        .values()
                        .map(|w| WorkspaceInfo {
                            name: w.name.clone(),
                            root: w.worktree_path.to_string_lossy().to_string(),
                            branch: w.branch.clone(),
                            status: ws_status_str(&w.status),
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
                            message: format!("Project '{}' not found", project),
                        },
                    )
                    .await?;
                }
            }
            Ok(true)
        }

        // v1.2: Select workspace and spawn terminal
        ClientMessage::SelectWorkspace { project, workspace } => {
            match resolve_workspace(&ctx.app_state, project, workspace).await {
                Ok(ws_ctx) => {
                    let (session_id, shell_name) = {
                        let mut reg = ctx.terminal_registry.lock().await;
                        reg.spawn(
                            Some(ws_ctx.root_path.clone()),
                            Some(project.clone()),
                            Some(workspace.clone()),
                            ctx.scrollback_tx.clone(),
                        )
                        .map_err(|e| format!("Spawn error: {}", e))?
                    };

                    // 自动订阅新创建的终端
                    subscribe_terminal(
                        &session_id,
                        &ctx.terminal_registry,
                        &ctx.subscribed_terms,
                        &ctx.agg_tx,
                    )
                    .await;

                    info!(
                        project = %project,
                        workspace = %workspace,
                        root = %ws_ctx.root_path.display(),
                        term_id = %session_id,
                        "Terminal spawned in workspace"
                    );

                    send_message(
                        socket,
                        &ServerMessage::SelectedWorkspace {
                            project: project.clone(),
                            workspace: workspace.clone(),
                            root: ws_ctx.root_path.to_string_lossy().to_string(),
                            session_id,
                            shell: shell_name,
                        },
                    )
                    .await?;
                }
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                }
            }
            Ok(true)
        }

        // v1.16: Import project
        ClientMessage::ImportProject { name, path } => {
            info!("ImportProject request: name={}, path={}", name, path);
            let path_buf = PathBuf::from(&path);
            let mut state = ctx.app_state.write().await;

            match ProjectManager::import_local(&mut state, name, &path_buf) {
                Ok(project) => {
                    info!("Project imported successfully: {}", project.name);
                    let default_branch = project.default_branch.clone();
                    let root = project.root_path.to_string_lossy().to_string();

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
                    send_message(socket, &ServerMessage::Error { code, message }).await?;
                }
            }
            Ok(true)
        }

        // v1.16: Create workspace
        ClientMessage::CreateWorkspace {
            project,
            from_branch,
        } => {
            let mut state = ctx.app_state.write().await;

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
                                root: ws.worktree_path.to_string_lossy().to_string(),
                                branch: ws.branch,
                                status: ws_status_str(&ws.status),
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
                        _ => ("workspace_error".to_string(), e.to_string()),
                    };
                    send_message(socket, &ServerMessage::Error { code, message }).await?;
                }
            }
            Ok(true)
        }

        // v1.17: Remove project
        ClientMessage::RemoveProject { name } => {
            info!("RemoveProject request: name={}", name);
            let mut state = ctx.app_state.write().await;

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
                    warn!("Failed to remove project: {}, error: {}", name, e);
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
                let mut reg = ctx.terminal_registry.lock().await;
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

            let mut state = ctx.app_state.write().await;

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

        // v1.29: 保存项目命令配置
        ClientMessage::SaveProjectCommands { project, commands } => {
            info!("SaveProjectCommands request: project={}", project);
            {
                let mut state = ctx.app_state.write().await;
                match state.get_project_mut(project) {
                    Some(p) => {
                        p.commands = commands.iter().map(|c| {
                            crate::workspace::state::ProjectCommand {
                                id: c.id.clone(),
                                name: c.name.clone(),
                                icon: c.icon.clone(),
                                command: c.command.clone(),
                                blocking: c.blocking,
                            }
                        }).collect();
                    }
                    None => {
                        send_message(
                            socket,
                            &ServerMessage::ProjectCommandsSaved {
                                project: project.clone(),
                                ok: false,
                                message: Some(format!("Project '{}' not found", project)),
                            },
                        ).await?;
                        return Ok(true);
                    }
                }
            }

            // 触发防抖保存
            let _ = ctx.save_tx.send(()).await;

            send_message(
                socket,
                &ServerMessage::ProjectCommandsSaved {
                    project: project.clone(),
                    ok: true,
                    message: None,
                },
            ).await?;
            Ok(true)
        }

        // v1.29: 执行项目命令
        ClientMessage::RunProjectCommand { project, workspace, command_id } => {
            info!("RunProjectCommand request: project={}, workspace={}, command_id={}", project, workspace, command_id);

            // 查找命令和工作目录
            let (command_text, cwd) = {
                let state = ctx.app_state.read().await;
                match state.get_project(project) {
                    Some(p) => {
                        let ws_root = if workspace == "default" {
                            Some(p.root_path.clone())
                        } else {
                            p.get_workspace(workspace).map(|w| w.worktree_path.clone())
                        };

                        match (p.commands.iter().find(|c| c.id == *command_id), ws_root) {
                            (Some(cmd), Some(cwd)) => (cmd.command.clone(), cwd),
                            _ => {
                                drop(state);
                                send_message(
                                    socket,
                                    &ServerMessage::Error {
                                        code: "command_not_found".to_string(),
                                        message: format!("Command '{}' not found or workspace '{}' not found", command_id, workspace),
                                    },
                                ).await?;
                                return Ok(true);
                            }
                        }
                    }
                    None => {
                        send_message(
                            socket,
                            &ServerMessage::Error {
                                code: "project_not_found".to_string(),
                                message: format!("Project '{}' not found", project),
                            },
                        ).await?;
                        return Ok(true);
                    }
                }
            };

            let task_id = uuid::Uuid::new_v4().to_string();

            // 发送开始通知
            send_message(
                socket,
                &ServerMessage::ProjectCommandStarted {
                    project: project.clone(),
                    workspace: workspace.clone(),
                    command_id: command_id.clone(),
                    task_id: task_id.clone(),
                },
            ).await?;

            // 启动子进程并注册到 running_commands
            let mut child = match tokio::process::Command::new("sh")
                .arg("-c")
                .arg(&command_text)
                .current_dir(&cwd)
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::piped())
                .spawn()
            {
                Ok(child) => child,
                Err(e) => {
                    let _ = ctx.cmd_output_tx.send(ServerMessage::ProjectCommandCompleted {
                        project: project.clone(),
                        workspace: workspace.clone(),
                        command_id: command_id.clone(),
                        task_id,
                        ok: false,
                        message: Some(format!("执行失败: {}", e)),
                    }).await;
                    return Ok(true);
                }
            };

            let stdout_pipe = child.stdout.take();
            let stderr_pipe = child.stderr.take();

            ctx.running_commands.lock().await.insert(task_id.clone(), child);

            let tx = ctx.cmd_output_tx.clone();
            let rc = ctx.running_commands.clone();
            let p = project.clone();
            let w = workspace.clone();
            let c = command_id.clone();
            let tid = task_id.clone();

            tokio::spawn(async move {
                let collected = Arc::new(Mutex::new(Vec::<String>::new()));

                let stdout_collected = collected.clone();
                let stdout_tx = tx.clone();
                let stdout_tid = tid.clone();
                let stdout_handle = tokio::spawn(async move {
                    if let Some(pipe) = stdout_pipe {
                        let reader = tokio::io::BufReader::new(pipe);
                        let mut lines = reader.lines();
                        while let Ok(Some(line)) = lines.next_line().await {
                            stdout_collected.lock().await.push(line.clone());
                            let _ = stdout_tx.send(ServerMessage::ProjectCommandOutput {
                                task_id: stdout_tid.clone(),
                                line,
                            }).await;
                        }
                    }
                });

                let stderr_collected = collected.clone();
                let stderr_tx = tx.clone();
                let stderr_tid = tid.clone();
                let stderr_handle = tokio::spawn(async move {
                    if let Some(pipe) = stderr_pipe {
                        let reader = tokio::io::BufReader::new(pipe);
                        let mut lines = reader.lines();
                        while let Ok(Some(line)) = lines.next_line().await {
                            stderr_collected.lock().await.push(line.clone());
                            let _ = stderr_tx.send(ServerMessage::ProjectCommandOutput {
                                task_id: stderr_tid.clone(),
                                line,
                            }).await;
                        }
                    }
                });

                let _ = stdout_handle.await;
                let _ = stderr_handle.await;

                let wait_result = {
                    let mut cmds = rc.lock().await;
                    if let Some(child) = cmds.get_mut(&tid) {
                        Some(child.wait().await)
                    } else {
                        None
                    }
                };

                rc.lock().await.remove(&tid);

                let exit_status = match wait_result {
                    Some(Ok(status)) => status,
                    Some(Err(e)) => {
                        let _ = tx.send(ServerMessage::ProjectCommandCompleted {
                            project: p,
                            workspace: w,
                            command_id: c,
                            task_id: tid,
                            ok: false,
                            message: Some(format!("执行失败: {}", e)),
                        }).await;
                        return;
                    }
                    None => return,
                };

                let all_lines = collected.lock().await;
                let combined = all_lines.join("\n");
                let message = if combined.len() > 4096 {
                    format!("{}...(truncated)", &combined[..4096])
                } else {
                    combined
                };
                let ok = exit_status.success();

                info!(
                    "ProjectCommand completed: project={}, command_id={}, ok={}",
                    p, c, ok
                );

                let _ = tx.send(ServerMessage::ProjectCommandCompleted {
                    project: p,
                    workspace: w,
                    command_id: c,
                    task_id: tid,
                    ok,
                    message: Some(message),
                }).await;
            });

            Ok(true)
        }

        // 取消正在运行的项目命令
        ClientMessage::CancelProjectCommand { project, workspace, command_id } => {
            info!("CancelProjectCommand request: project={}, workspace={}, command_id={}", project, workspace, command_id);

            let mut cmds = ctx.running_commands.lock().await;
            let mut cancelled_task_id = None;
            for (task_id, child) in cmds.iter_mut() {
                if let Err(e) = child.kill().await {
                    warn!("Failed to kill command process {}: {}", task_id, e);
                } else {
                    cancelled_task_id = Some(task_id.clone());
                    break;
                }
            }

            if let Some(task_id) = cancelled_task_id {
                cmds.remove(&task_id);
                drop(cmds);

                info!("ProjectCommand cancelled: project={}, command_id={}, task_id={}", project, command_id, task_id);

                send_message(
                    socket,
                    &ServerMessage::ProjectCommandCancelled {
                        project: project.clone(),
                        workspace: workspace.clone(),
                        command_id: command_id.clone(),
                        task_id,
                    },
                ).await?;
            }

            Ok(true)
        }

        _ => Ok(false),
    }
}
