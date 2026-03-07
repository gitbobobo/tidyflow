use axum::extract::ws::WebSocket;
use std::sync::{Arc, Mutex as StdMutex};
use tracing::{info, warn};
use uuid::Uuid;

use crate::server::context::{resolve_workspace, HandlerContext, RunningAITaskEntry};
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::send_message;

use super::profile::{direction_model_label, normalize_profiles_lenient};
use super::{maybe_manager, StartWorkspaceReq, DEFAULT_LOOP_ROUND_LIMIT};

async fn send_read_via_http_required(socket: &mut WebSocket, action: &str) -> Result<(), String> {
    send_message(
        socket,
        &ServerMessage::Error {
            code: "read_via_http_required".to_string(),
            message: format!(
                "{} must be fetched via HTTP API (/api/v1/evolution/...)",
                action
            ),
        },
    )
    .await
}

pub(super) async fn handle_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    let Some(manager) = maybe_manager() else {
        return Err("evolution manager init failed".to_string());
    };

    match client_msg {
        ClientMessage::EvoStartWorkspace {
            project,
            workspace,
            priority,
            loop_round_limit,
            stage_profiles,
        } => {
            let req = StartWorkspaceReq {
                project: project.clone(),
                workspace: workspace.clone(),
                priority: *priority,
                loop_round_limit: loop_round_limit.unwrap_or(DEFAULT_LOOP_ROUND_LIMIT),
                stage_profiles: stage_profiles.clone(),
            };
            manager.start_workspace(req, ctx).await?;
            send_snapshot(socket, &manager, ctx).await?;
            Ok(true)
        }
        ClientMessage::EvoStopWorkspace {
            project,
            workspace,
            reason,
        } => {
            manager
                .stop_workspace(project, workspace, reason.clone(), ctx)
                .await?;
            send_snapshot(socket, &manager, ctx).await?;
            Ok(true)
        }
        ClientMessage::EvoStopAll { reason } => {
            manager.stop_all(reason.clone(), ctx).await;
            send_snapshot(socket, &manager, ctx).await?;
            Ok(true)
        }
        ClientMessage::EvoResumeWorkspace { project, workspace } => {
            manager.resume_workspace(project, workspace, ctx).await?;
            send_snapshot(socket, &manager, ctx).await?;
            Ok(true)
        }
        ClientMessage::EvoGetSnapshot { .. } => {
            send_read_via_http_required(socket, "evo_get_snapshot").await?;
            Ok(true)
        }
        ClientMessage::EvoOpenStageChat { .. } => {
            send_read_via_http_required(socket, "evo_open_stage_chat").await?;
            Ok(true)
        }
        ClientMessage::EvoUpdateAgentProfile {
            project,
            workspace,
            stage_profiles,
        } => {
            let inbound_normalized = normalize_profiles_lenient(stage_profiles.clone());
            let inbound_direction_model = direction_model_label(&inbound_normalized);
            info!(
                "Inbound EvoUpdateAgentProfile: conn_id={}, remote={}, project={}, workspace={}, stages={}, direction_model={}",
                ctx.conn_meta.conn_id,
                ctx.conn_meta.is_remote,
                project,
                workspace,
                inbound_normalized.len(),
                inbound_direction_model
            );
            let saved = manager
                .update_agent_profile(project, workspace, stage_profiles.clone(), ctx)
                .await?;
            send_message(
                socket,
                &ServerMessage::EvoAgentProfile {
                    project: project.clone(),
                    workspace: workspace.clone(),
                    stage_profiles: saved,
                },
            )
            .await?;
            Ok(true)
        }
        ClientMessage::EvoGetAgentProfile { project, workspace } => {
            info!(
                "Inbound EvoGetAgentProfile: conn_id={}, remote={}, project={}, workspace={}",
                ctx.conn_meta.conn_id, ctx.conn_meta.is_remote, project, workspace
            );
            send_read_via_http_required(socket, "evo_get_agent_profile").await?;
            Ok(true)
        }
        ClientMessage::EvoResolveBlockers {
            project,
            workspace,
            resolutions,
        } => {
            manager
                .resolve_blockers(project, workspace, resolutions.clone(), ctx)
                .await?;
            send_snapshot(socket, &manager, ctx).await?;
            Ok(true)
        }
        ClientMessage::EvoListCycleHistory { .. } => {
            send_read_via_http_required(socket, "evo_list_cycle_history").await?;
            Ok(true)
        }
        ClientMessage::EvoAdjustLoopRound {
            project,
            workspace,
            loop_round_limit,
        } => {
            manager
                .adjust_loop_round(project, workspace, *loop_round_limit, ctx)
                .await?;
            send_snapshot(socket, &manager, ctx).await?;
            Ok(true)
        }
        ClientMessage::EvoAutoCommit { project, workspace } => {
            // 后台执行，避免长耗时提交阻塞同连接上的后续查询请求。
            let project = project.clone();
            let workspace = workspace.clone();
            let project_for_task = project.clone();
            let workspace_for_task = workspace.clone();
            let manager = manager.clone();
            let ctx = ctx.clone();
            let ctx_for_task = ctx.clone();
            let origin_conn_id = ctx.conn_meta.conn_id.clone();
            let running_ai_tasks = ctx.running_ai_tasks.clone();
            let running_ai_tasks_cleanup = running_ai_tasks.clone();
            let task_id = Uuid::new_v4().to_string();
            let task_id_clone = task_id.clone();
            let child_pid: Arc<StdMutex<Option<u32>>> = Arc::new(StdMutex::new(None));

            let join_handle = tokio::spawn(async move {
                let result = match resolve_workspace(
                    &ctx_for_task.app_state,
                    &project_for_task,
                    &workspace_for_task,
                )
                .await
                {
                    Ok(workspace_ctx) => {
                        manager
                            .run_auto_commit_independent(
                                &project_for_task,
                                &workspace_for_task,
                                &workspace_ctx.root_path,
                                &ctx_for_task,
                            )
                            .await
                    }
                    Err(err) => Err(err.to_string()),
                };

                let (success, message, commits) = match result {
                    Ok((message, commits)) => (true, message, commits),
                    Err(err) => (false, err, Vec::new()),
                };

                let msg = ServerMessage::EvoAutoCommitResult {
                    project: project_for_task.clone(),
                    workspace: workspace_for_task.clone(),
                    success,
                    message,
                    commits,
                };

                if let Err(err) = ctx_for_task.cmd_output_tx.send(msg.clone()).await {
                    warn!(
                        "Failed to send EvoAutoCommitResult to initiator: conn_id={}, project={}, workspace={}, error={}",
                        origin_conn_id, project_for_task, workspace_for_task, err
                    );
                }

                let _ = crate::server::context::send_task_broadcast_message(
                    &ctx_for_task.task_broadcast_tx,
                    origin_conn_id,
                    msg,
                );

                running_ai_tasks_cleanup.lock().await.remove(&task_id_clone);
                crate::application::sidebar_status::notify_workspace_sidebar_changed(
                    &ctx_for_task,
                    &project_for_task,
                    &workspace_for_task,
                )
                .await;
            });

            running_ai_tasks.lock().await.insert(
                task_id.clone(),
                RunningAITaskEntry {
                    task_id,
                    project: project.clone(),
                    workspace: workspace.clone(),
                    operation_type: "ai_commit".to_string(),
                    child_pid,
                    join_handle,
                },
            );
            crate::application::sidebar_status::notify_workspace_sidebar_changed(
                &ctx, &project, &workspace,
            )
            .await;
            Ok(true)
        }
        _ => Ok(false),
    }
}

async fn send_snapshot(
    socket: &mut WebSocket,
    manager: &super::EvolutionManager,
    ctx: &HandlerContext,
) -> Result<(), String> {
    let snapshot = manager.build_snapshot(ctx).await;
    send_message(
        socket,
        &ServerMessage::EvoSnapshot {
            scheduler: snapshot.scheduler,
            workspace_items: snapshot.workspace_items,
        },
    )
    .await
}
