use axum::extract::ws::WebSocket;
use chrono::Utc;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;
use tracing::{error, info, warn};
use uuid::Uuid;

use crate::application::task::list_tasks_snapshot_message;
use crate::server::context::{
    push_task_history, resolve_workspace_branch, update_task_history, HandlerContext,
    RunningAITaskEntry, SharedAppState, TaskHistoryEntry,
};
use crate::server::git;
use crate::server::handlers::git::branch_commit;
use crate::server::protocol::ServerMessage;
use crate::server::ws::send_message;

/// AI 代理执行超时（5 分钟）
const AI_AGENT_TIMEOUT: Duration = Duration::from_secs(600);

/// 处理 AI 智能合并（后台执行，不阻塞 WebSocket 主循环）
pub async fn handle_git_ai_merge(
    project: String,
    workspace: String,
    ai_agent: Option<String>,
    default_branch: String,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    let (proj_ctx, source_branch) =
        match resolve_workspace_branch(app_state, &project, &workspace).await {
            Ok(r) => r,
            Err(e) => {
                send_message(socket, &e.to_server_error()).await?;
                return Ok(true);
            }
        };

    if source_branch == "HEAD" || source_branch.is_empty() {
        let msg = ServerMessage::GitAIMergeResult {
            project: project.clone(),
            workspace: workspace.clone(),
            success: false,
            message: "Workspace is in detached HEAD state. Create/switch to a branch first."
                .to_string(),
            conflicts: vec![],
        };
        send_message(socket, &msg).await?;
        let _ = crate::server::context::send_task_broadcast_message(
            &ctx.task_broadcast_tx,
            &ctx.conn_meta.conn_id,
            msg,
        );
        return Ok(true);
    }

    let root = proj_ctx.root_path;
    let project_name = proj_ctx.project_name;
    let ai_agent_type = ai_agent.unwrap_or_else(|| "cursor".to_string());
    let project_for_task = project.clone();
    let workspace_for_task = workspace.clone();

    // 通过 cmd_output_tx 异步回传结果，不阻塞 WS 主循环
    let cmd_output_tx = ctx.cmd_output_tx.clone();
    let task_broadcast_tx = ctx.task_broadcast_tx.clone();
    let origin_conn_id = ctx.conn_meta.conn_id.clone();

    info!(
        "AI merge started: project={}, workspace={}, agent={}, {} -> {}",
        project, workspace, ai_agent_type, source_branch, default_branch
    );

    let running_ai_tasks = ctx.running_ai_tasks.clone();
    let task_id = Uuid::new_v4().to_string();
    let child_pid: Arc<StdMutex<Option<u32>>> = Arc::new(StdMutex::new(None));
    let child_pid_clone = child_pid.clone();
    let task_id_clone = task_id.clone();
    let running_ai_tasks_cleanup = running_ai_tasks.clone();
    let ctx_for_sidebar = ctx.clone();
    let project_for_registry = project.clone();
    let workspace_for_registry = workspace.clone();
    let task_history = ctx.task_history.clone();
    let task_id_for_history = task_id.clone();

    let join_handle = tokio::spawn(async move {
        let pid_for_blocking = child_pid_clone.clone();
        let result = tokio::time::timeout(
            AI_AGENT_TIMEOUT,
            tokio::task::spawn_blocking(move || {
                handle_ai_merge_internal(
                    &root,
                    &project_name,
                    &source_branch,
                    &default_branch,
                    &ai_agent_type,
                    Some(&pid_for_blocking),
                )
            }),
        )
        .await;

        let msg = match result {
            Ok(Ok(Ok(merge_result))) => {
                info!(
                    "AI merge succeeded: project={}, workspace={}",
                    project_for_task, workspace_for_task
                );
                ServerMessage::GitAIMergeResult {
                    project: project_for_task.clone(),
                    workspace: workspace_for_task.clone(),
                    success: merge_result.success,
                    message: merge_result.message,
                    conflicts: merge_result.conflicts,
                }
            }
            Ok(Ok(Err(e))) => {
                warn!(
                    "AI merge failed: project={}, workspace={}, error={}",
                    project_for_task, workspace_for_task, e
                );
                ServerMessage::GitAIMergeResult {
                    project: project_for_task.clone(),
                    workspace: workspace_for_task.clone(),
                    success: false,
                    message: e,
                    conflicts: vec![],
                }
            }
            Ok(Err(e)) => {
                error!("AI merge task panicked: {}", e);
                ServerMessage::GitAIMergeResult {
                    project: project_for_task.clone(),
                    workspace: workspace_for_task.clone(),
                    success: false,
                    message: format!("AI merge task failed: {}", e),
                    conflicts: vec![],
                }
            }
            Err(_) => {
                error!(
                    "AI merge timed out after {}s: project={}, workspace={}",
                    AI_AGENT_TIMEOUT.as_secs(),
                    project_for_task,
                    workspace_for_task
                );
                ServerMessage::GitAIMergeResult {
                    project: project_for_task.clone(),
                    workspace: workspace_for_task.clone(),
                    success: false,
                    message: format!(
                        "AI agent timed out after {} seconds",
                        AI_AGENT_TIMEOUT.as_secs()
                    ),
                    conflicts: vec![],
                }
            }
        };

        // 发送给发起者
        if let Err(e) = cmd_output_tx.send(msg.clone()).await {
            error!("Failed to send AI merge result to WS: {}", e);
        }
        // 广播给其他连接
        let _ = crate::server::context::send_task_broadcast_message(
            &task_broadcast_tx,
            &origin_conn_id,
            msg.clone(),
        );
        // 更新任务历史
        if let ServerMessage::GitAIMergeResult {
            success,
            ref message,
            ..
        } = msg
        {
            let status = if success { "completed" } else { "failed" };
            update_task_history(&task_history, &task_id_clone, status, Some(message.clone())).await;
            let snapshot = list_tasks_snapshot_message(&task_history).await;
            let _ = crate::server::context::send_task_broadcast_message(
                &task_broadcast_tx,
                &origin_conn_id,
                snapshot,
            );
        }
        // 从注册表移除
        running_ai_tasks_cleanup.lock().await.remove(&task_id_clone);
        crate::application::sidebar_status::notify_workspace_sidebar_changed(
            &ctx_for_sidebar,
            &project_for_task,
            &workspace_for_task,
        )
        .await;
    });

    // 注册到 AI 任务注册表
    running_ai_tasks.lock().await.insert(
        task_id.clone(),
        RunningAITaskEntry {
            task_id: task_id.clone(),
            project: project_for_registry.clone(),
            workspace: workspace_for_registry.clone(),
            operation_type: "ai_merge".to_string(),
            child_pid,
            join_handle,
        },
    );
    crate::application::sidebar_status::notify_workspace_sidebar_changed(ctx, &project, &workspace)
        .await;

    // 写入任务历史
    push_task_history(
        &ctx.task_history,
        TaskHistoryEntry {
            task_id: task_id_for_history,
            project: project_for_registry,
            workspace: workspace_for_registry,
            task_type: "ai_merge".to_string(),
            command_id: None,
            title: "AI 合并".to_string(),
            status: "running".to_string(),
            message: None,
            started_at: Utc::now().timestamp_millis(),
            completed_at: None,
        },
    )
    .await;
    let snapshot = list_tasks_snapshot_message(&ctx.task_history).await;
    let _ = crate::server::context::send_task_broadcast_message(
        &ctx.task_broadcast_tx,
        &ctx.conn_meta.conn_id,
        snapshot,
    );

    Ok(true)
}

/// AI 合并结果
struct AIMergeOutput {
    success: bool,
    message: String,
    conflicts: Vec<String>,
}

/// 内部函数：执行 AI 智能合并逻辑
fn handle_ai_merge_internal(
    repo_root: &std::path::Path,
    project_name: &str,
    source_branch: &str,
    default_branch: &str,
    ai_agent: &str,
    pid_holder: Option<&Arc<StdMutex<Option<u32>>>>,
) -> Result<AIMergeOutput, String> {
    // 确保 integration worktree 存在
    let integration_path =
        git::ensure_integration_worktree(repo_root, project_name, default_branch)
            .map_err(|e| format!("Failed to ensure integration worktree: {}", e))?;
    let integration_root = std::path::PathBuf::from(&integration_path);

    // 构建合并 prompt
    let prompt = build_ai_merge_prompt(source_branch, default_branch);

    // 调用 AI agent
    let agent_args = branch_commit::build_ai_agent_command(ai_agent, &prompt)?;
    let ai_output = branch_commit::execute_ai_agent(&integration_root, &agent_args, pid_holder)?;

    // 解析结果
    parse_ai_merge_result(&ai_output)
}

/// 构建 AI 合并提示词
fn build_ai_merge_prompt(source_branch: &str, default_branch: &str) -> String {
    format!(
        r#"你是一个 Git 合并助手。请在当前目录执行合并操作。这是纯本地操作，禁止任何网络请求。

**任务**：将分支 `{source_branch}` 合并到 `{default_branch}`

请确保当前在 `{default_branch}` 分支上，然后执行合并。如果有冲突，尝试解决并提交。
以严格 JSON 格式输出结果（只输出 JSON，不要输出其他内容）：
```json
{{
  "success": true,
  "message": "操作结果描述",
  "conflicts": ["冲突文件路径列表，无冲突则为空数组"]
}}
```"#
    )
}

/// 解析 AI 合并结果
fn parse_ai_merge_result(output: &str) -> Result<AIMergeOutput, String> {
    let json_str = branch_commit::extract_json_from_output(output)?;
    let value: serde_json::Value = serde_json::from_str(&json_str)
        .map_err(|e| format!("Failed to parse AI merge output as JSON: {}", e))?;

    // 兼容 envelope 格式
    let inner: serde_json::Value = branch_commit::extract_inner_json(&value);

    let success = inner
        .get("success")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let message = inner
        .get("message")
        .and_then(|v| v.as_str())
        .unwrap_or("Unknown result")
        .to_string();
    let conflicts = inner
        .get("conflicts")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default();

    Ok(AIMergeOutput {
        success,
        message,
        conflicts,
    })
}
