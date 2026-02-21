use axum::extract::ws::WebSocket;
use chrono::Utc;
use tracing::info;

use crate::server::context::HandlerContext;
use crate::server::protocol::{ClientMessage, ServerMessage};
use crate::server::ws::send_message;

use super::{maybe_manager, StartWorkspaceReq, DEFAULT_VERIFY_LIMIT};

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
            max_verify_iterations,
            auto_loop_enabled,
            stage_profiles,
        } => {
            let req = StartWorkspaceReq {
                project: project.clone(),
                workspace: workspace.clone(),
                priority: *priority,
                max_verify_iterations: max_verify_iterations.unwrap_or(DEFAULT_VERIFY_LIMIT),
                auto_loop_enabled: *auto_loop_enabled,
                stage_profiles: stage_profiles.clone(),
            };
            manager.start_workspace(req, ctx).await?;
            send_snapshot(socket, &manager).await?;
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
            send_snapshot(socket, &manager).await?;
            Ok(true)
        }
        ClientMessage::EvoStopAll { reason } => {
            manager.stop_all(reason.clone(), ctx).await;
            send_snapshot(socket, &manager).await?;
            Ok(true)
        }
        ClientMessage::EvoResumeWorkspace { project, workspace } => {
            manager.resume_workspace(project, workspace, ctx).await?;
            send_snapshot(socket, &manager).await?;
            Ok(true)
        }
        ClientMessage::EvoGetSnapshot { .. } => {
            send_snapshot(socket, &manager).await?;
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
            let inbound_direction_model = stage_profiles
                .iter()
                .find(|item| item.stage == "direction")
                .and_then(|item| item.model.as_ref())
                .map(|m| format!("{}/{}", m.provider_id, m.model_id))
                .unwrap_or_else(|| "default".to_string());
            info!(
                "Inbound EvoUpdateAgentProfile: conn_id={}, remote={}, project={}, workspace={}, stages={}, direction_model={}",
                ctx.conn_meta.conn_id,
                ctx.conn_meta.is_remote,
                project,
                workspace,
                stage_profiles.len(),
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
        _ => Ok(false),
    }
}

async fn send_snapshot(
    socket: &mut WebSocket,
    manager: &super::EvolutionManager,
) -> Result<(), String> {
    let snapshot = manager.build_snapshot().await;
    send_message(
        socket,
        &ServerMessage::EvoSnapshot {
            scheduler: snapshot.scheduler,
            workspace_items: snapshot.workspace_items,
        },
    )
    .await
}
