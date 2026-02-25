use axum::extract::ws::WebSocket;
use chrono::Utc;
use tracing::info;

use crate::server::context::HandlerContext;
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
        ClientMessage::EvoGetEvidenceSnapshot { project, workspace } => {
            let payload = manager.get_evidence_snapshot(project, workspace, ctx).await?;
            send_message(
                socket,
                &ServerMessage::EvoEvidenceSnapshot {
                    project: project.clone(),
                    workspace: workspace.clone(),
                    evidence_root: payload.evidence_root,
                    index_file: payload.index_file,
                    index_exists: payload.index_exists,
                    detected_subsystems: payload.detected_subsystems,
                    detected_platforms: payload.detected_platforms,
                    items: payload.items,
                    issues: payload.issues,
                    updated_at: payload.updated_at,
                },
            )
            .await?;
            Ok(true)
        }
        ClientMessage::EvoGetEvidenceRebuildPrompt { project, workspace } => {
            let payload = manager
                .get_evidence_rebuild_prompt(project, workspace, ctx)
                .await?;
            send_message(
                socket,
                &ServerMessage::EvoEvidenceRebuildPrompt {
                    project: project.clone(),
                    workspace: workspace.clone(),
                    prompt: payload.prompt,
                    evidence_root: payload.evidence_root,
                    index_file: payload.index_file,
                    detected_subsystems: payload.detected_subsystems,
                    detected_platforms: payload.detected_platforms,
                    generated_at: payload.generated_at,
                },
            )
            .await?;
            Ok(true)
        }
        ClientMessage::EvoReadEvidenceItem {
            project,
            workspace,
            item_id,
            offset,
            limit,
        } => {
            let payload = manager
                .read_evidence_item_chunk(
                    project,
                    workspace,
                    item_id,
                    *offset,
                    *limit,
                    ctx,
                )
                .await?;
            send_message(
                socket,
                &ServerMessage::EvoEvidenceItemChunk {
                    project: project.clone(),
                    workspace: workspace.clone(),
                    item_id: payload.item_id,
                    offset: payload.offset,
                    next_offset: payload.next_offset,
                    eof: payload.eof,
                    total_size_bytes: payload.total_size_bytes,
                    mime_type: payload.mime_type,
                    content: payload.content,
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
