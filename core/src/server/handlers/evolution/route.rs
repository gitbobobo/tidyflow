use axum::extract::ws::WebSocket;
use chrono::Utc;
use tracing::info;

use crate::server::context::{resolve_workspace, HandlerContext};
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::send_message;

use super::profile::{direction_model_label, normalize_profiles_lenient};
use super::{maybe_manager, StartWorkspaceReq, DEFAULT_LOOP_ROUND_LIMIT};

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
            send_snapshot(socket, &manager, ctx).await?;
            Ok(true)
        }
        ClientMessage::EvoOpenStageChat {
            project,
            workspace,
            cycle_id,
            stage,
        } => {
            match manager
                .open_stage_chat(project, workspace, cycle_id, stage)
                .await
            {
                Some((ai_tool, session_id)) => {
                    send_message(
                        socket,
                        &ServerMessage::EvoStageChatOpened {
                            project: project.clone(),
                            workspace: workspace.clone(),
                            cycle_id: cycle_id.clone(),
                            stage: stage.clone(),
                            ai_tool,
                            session_id,
                        },
                    )
                    .await?;
                }
                None => {
                    send_message(
                        socket,
                        &ServerMessage::EvoError {
                            event_id: None,
                            event_seq: None,
                            project: Some(project.clone()),
                            workspace: Some(workspace.clone()),
                            cycle_id: Some(cycle_id.clone()),
                            ts: Utc::now().to_rfc3339(),
                            source: "system".to_string(),
                            code: "evo_chat_session_not_found".to_string(),
                            message: format!("stage '{}' session not found", stage),
                            context: None,
                        },
                    )
                    .await?;
                }
            }
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
            let saved = manager.get_agent_profile(project, workspace, ctx).await;
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
        ClientMessage::EvoListCycleHistory { project, workspace } => {
            let cycles = manager.list_cycle_history(project, workspace, ctx).await?;
            send_message(
                socket,
                &ServerMessage::EvoCycleHistory {
                    project: project.clone(),
                    workspace: workspace.clone(),
                    cycles,
                },
            )
            .await?;
            Ok(true)
        }
        ClientMessage::EvoAutoCommit { project, workspace } => {
            let result = match resolve_workspace(&ctx.app_state, project, workspace).await {
                Ok(workspace_ctx) => {
                    manager
                        .run_auto_commit_independent(
                            project,
                            workspace,
                            &workspace_ctx.root_path,
                            ctx,
                        )
                        .await
                }
                Err(err) => Err(err.to_string()),
            };

            let (success, message, commits) = match result {
                Ok((message, commits)) => (true, message, commits),
                Err(err) => (false, err, Vec::new()),
            };

            send_message(
                socket,
                &ServerMessage::EvoAutoCommitResult {
                    project: project.clone(),
                    workspace: workspace.clone(),
                    success,
                    message,
                    commits,
                },
            )
            .await?;
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
