use tokio::sync::mpsc;
use tracing::{info, warn};

use crate::ai::session_status::{AiSessionStatus, AiSessionStatusMeta};
use crate::server::context::{SharedAppState, TaskBroadcastTx};
use crate::server::protocol::{ClientMessage, ServerMessage};

use super::super::utils::*;
use super::super::SharedAIState;

pub(crate) async fn handle_ai_chat_abort(
    msg: &ClientMessage,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    output_tx: &mpsc::Sender<ServerMessage>,
    task_broadcast_tx: &TaskBroadcastTx,
    origin_conn_id: &str,
) -> Result<bool, String> {
    let (project_name, workspace_name, session_id, ai_tool) = match msg {
        ClientMessage::AIChatAbort {
            project_name,
            workspace_name,
            ai_tool,
            session_id,
        } => (
            project_name.clone(),
            workspace_name.clone(),
            session_id.clone(),
            ai_tool.clone(),
        ),
        _ => return Ok(false),
    };
    let ai_tool = normalize_ai_tool(&ai_tool)?;

    let directory = resolve_directory(app_state, &project_name, &workspace_name).await?;
    let key = stream_key(&ai_tool, &directory, &session_id);
    info!(
        "AIChatAbort: project={}, workspace={}, session_id={}, key={}",
        project_name, workspace_name, session_id, key
    );

    {
        let mut ai = ai_state.lock().await;
        let dir_key = tool_directory_key(&ai_tool, &directory);
        ai.directory_last_used_ms.insert(dir_key, now_ms());
    }

    // best-effort：abort 代表前端应进入 idle（即使后端 abort 失败，也不应一直显示 busy）。
    {
        let store = {
            let guard = ai_state.lock().await;
            guard.session_statuses.clone()
        };
        store.set_status_with_meta(
            AiSessionStatusMeta {
                project_name: project_name.clone(),
                workspace_name: workspace_name.clone(),
                ai_tool: ai_tool.clone(),
                directory: directory.clone(),
                session_id: session_id.clone(),
            },
            AiSessionStatus::Idle,
        );
    }

    let abort_tx = {
        let ai = ai_state.lock().await;
        ai.active_streams.get(&key).cloned()
    };
    let mut should_emit_done_now = false;
    if let Some(tx) = abort_tx {
        info!("AIChatAbort: found active stream sender, sending abort signal");
        if tx.send(()).await.is_err() {
            should_emit_done_now = true;
        }
    } else {
        info!("AIChatAbort: no active stream sender found for key");
        should_emit_done_now = true;
    }

    // best-effort：并发触发后端 abort，避免阻塞 WS 主循环。
    let ai_state_cloned = ai_state.clone();
    let directory_cloned = directory.clone();
    let session_id_cloned = session_id.clone();
    let project_name_cloned = project_name.clone();
    let workspace_name_cloned = workspace_name.clone();
    let ai_tool_cloned = ai_tool.clone();
    tokio::spawn(async move {
        if let Ok(agent) = ensure_agent(&ai_state_cloned, &ai_tool_cloned).await {
            info!("AIChatAbort: calling agent.abort_session");
            if let Err(e) = agent
                .abort_session(&directory_cloned, &session_id_cloned)
                .await
            {
                warn!(
                    "AIChatAbort: abort_session failed, project={}, workspace={}, session_id={}, error={}",
                    project_name_cloned, workspace_name_cloned, session_id_cloned, e
                );
            }
        }
    });

    // 若没有可用流任务接收 abort 信号，主动下发 done 收敛前端状态。
    if should_emit_done_now {
        let target_conn_ids = ai_session_subscriber_conn_ids(ai_state, &key, origin_conn_id).await;
        let _ = emit_server_message_with_targets(
            output_tx,
            task_broadcast_tx,
            origin_conn_id,
            target_conn_ids,
            ServerMessage::AIChatDone {
                project_name,
                workspace_name,
                ai_tool,
                session_id,
                selection_hint: None,
                stop_reason: None,
            },
        )
        .await;
    }

    Ok(true)
}

pub(crate) async fn handle_ai_question_reply(
    msg: &ClientMessage,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    output_tx: &mpsc::Sender<ServerMessage>,
    task_broadcast_tx: &TaskBroadcastTx,
    origin_conn_id: &str,
) -> Result<bool, String> {
    let (project_name, workspace_name, session_id, request_id, answers, ai_tool) = match msg {
        ClientMessage::AIQuestionReply {
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            request_id,
            answers,
        } => (
            project_name.clone(),
            workspace_name.clone(),
            session_id.clone(),
            request_id.clone(),
            answers.clone(),
            ai_tool.clone(),
        ),
        _ => return Ok(false),
    };
    let ai_tool = normalize_ai_tool(&ai_tool)?;

    let directory = resolve_directory(app_state, &project_name, &workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;

    {
        let mut ai = ai_state.lock().await;
        let dir_key = tool_directory_key(&ai_tool, &directory);
        ai.directory_last_used_ms.insert(dir_key, now_ms());
    }

    info!(
        "AIQuestionReply: project={}, workspace={}, session_id={}, request_id={}, answers_count={}",
        project_name,
        workspace_name,
        session_id,
        request_id,
        answers.len()
    );

    agent
        .reply_question(&directory, &request_id, answers)
        .await
        .map_err(|e| {
            format!(
                "AIQuestionReply failed: project={}, workspace={}, session_id={}, request_id={}, error={}",
                project_name, workspace_name, session_id, request_id, e
            )
        })?;

    let session_key = stream_key(&ai_tool, &directory, &session_id);
    let target_conn_ids =
        ai_session_subscriber_conn_ids(ai_state, &session_key, origin_conn_id).await;
    let _ = emit_server_message_with_targets(
        output_tx,
        task_broadcast_tx,
        origin_conn_id,
        target_conn_ids,
        ServerMessage::AIQuestionCleared {
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            request_id,
        },
    )
    .await;

    Ok(true)
}

pub(crate) async fn handle_ai_question_reject(
    msg: &ClientMessage,
    app_state: &SharedAppState,
    ai_state: &SharedAIState,
    output_tx: &mpsc::Sender<ServerMessage>,
    task_broadcast_tx: &TaskBroadcastTx,
    origin_conn_id: &str,
) -> Result<bool, String> {
    let (project_name, workspace_name, session_id, request_id, ai_tool) = match msg {
        ClientMessage::AIQuestionReject {
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            request_id,
        } => (
            project_name.clone(),
            workspace_name.clone(),
            session_id.clone(),
            request_id.clone(),
            ai_tool.clone(),
        ),
        _ => return Ok(false),
    };
    let ai_tool = normalize_ai_tool(&ai_tool)?;

    let directory = resolve_directory(app_state, &project_name, &workspace_name).await?;
    let agent = ensure_agent(ai_state, &ai_tool).await?;
    ensure_maintenance(ai_state).await;

    {
        let mut ai = ai_state.lock().await;
        let dir_key = tool_directory_key(&ai_tool, &directory);
        ai.directory_last_used_ms.insert(dir_key, now_ms());
    }

    info!(
        "AIQuestionReject: project={}, workspace={}, session_id={}, request_id={}",
        project_name, workspace_name, session_id, request_id
    );

    agent
        .reject_question(&directory, &request_id)
        .await
        .map_err(|e| {
            format!(
                "AIQuestionReject failed: project={}, workspace={}, session_id={}, request_id={}, error={}",
                project_name, workspace_name, session_id, request_id, e
            )
        })?;

    let session_key = stream_key(&ai_tool, &directory, &session_id);
    let target_conn_ids =
        ai_session_subscriber_conn_ids(ai_state, &session_key, origin_conn_id).await;
    let _ = emit_server_message_with_targets(
        output_tx,
        task_broadcast_tx,
        origin_conn_id,
        target_conn_ids,
        ServerMessage::AIQuestionCleared {
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            request_id,
        },
    )
    .await;

    Ok(true)
}
