use axum::extract::ws::WebSocket;
use serde_json::Value;
use std::path::Path;
use tracing::{info, warn};

use crate::application::task::list_tasks_snapshot_message;
use crate::server::context::{
    resolve_workspace, update_task_history, HandlerContext, SharedAppState,
};
use crate::server::git;
use crate::server::protocol::{ClientMessage, GitBranchInfo, ServerMessage};
use crate::server::ws::send_message;
use crate::util::shell_launch::{wrap_command_for_login_zsh, LOGIN_ZSH_PATH};

pub async fn handle_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    _ctx: &HandlerContext,
) -> Result<bool, String> {
    match client_msg {
        // v1.8: Git branches
        ClientMessage::GitBranches { project, workspace } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let root = ws_ctx.root_path;
            let result = tokio::task::spawn_blocking(move || git::git_branches(&root)).await;

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
            Ok(true)
        }

        // v1.8: Git switch branch
        ClientMessage::GitSwitchBranch {
            project,
            workspace,
            branch,
        } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let root = ws_ctx.root_path;
            let branch_clone = branch.clone();
            let result =
                tokio::task::spawn_blocking(move || git::git_switch_branch(&root, &branch_clone))
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
            Ok(true)
        }

        // v1.9: Git create branch
        ClientMessage::GitCreateBranch {
            project,
            workspace,
            branch,
        } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let root = ws_ctx.root_path;
            let branch_clone = branch.clone();
            let result =
                tokio::task::spawn_blocking(move || git::git_create_branch(&root, &branch_clone))
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
            Ok(true)
        }

        // v1.10: Git commit
        ClientMessage::GitCommit {
            project,
            workspace,
            message,
        } => {
            let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
                Ok(ctx) => ctx,
                Err(e) => {
                    send_message(socket, &e.to_server_error()).await?;
                    return Ok(true);
                }
            };

            let root = ws_ctx.root_path;
            let message_clone = message.clone();
            let result =
                tokio::task::spawn_blocking(move || git::git_commit(&root, &message_clone)).await;

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
            Ok(true)
        }

        _ => Ok(false),
    }
}

/// 构建 AI 代理命令
pub fn build_ai_agent_command(agent: &str, prompt: &str) -> Result<Vec<String>, String> {
    match agent {
        "claude" => Ok(vec![
            "claude".to_string(),
            "--dangerously-skip-permissions".to_string(),
            "-p".to_string(),
            prompt.to_string(),
            "--output-format".to_string(),
            "json".to_string(),
        ]),
        "codex" => Ok(vec![
            "codex".to_string(),
            "--dangerously-bypass-approvals-and-sandbox".to_string(),
            "exec".to_string(),
            prompt.to_string(),
        ]),
        "gemini" => Ok(vec![
            "gemini".to_string(),
            "--approval-mode".to_string(),
            "yolo".to_string(),
            "--no-sandbox".to_string(),
            "-p".to_string(),
            prompt.to_string(),
            "-o".to_string(),
            "json".to_string(),
        ]),
        "opencode" => Ok(vec![
            "opencode".to_string(),
            "run".to_string(),
            prompt.to_string(),
            "--format".to_string(),
            "json".to_string(),
        ]),
        "cursor" => Ok(vec![
            "cursor-agent".to_string(),
            "-p".to_string(),
            "--sandbox".to_string(),
            "disabled".to_string(),
            "-f".to_string(),
            prompt.to_string(),
            "--output-format".to_string(),
            "json".to_string(),
        ]),
        "copilot" => Ok(vec![
            "copilot".to_string(),
            "--allow-all".to_string(),
            "-p".to_string(),
            prompt.to_string(),
        ]),
        _ => Err(format!("Unknown AI agent: {}", agent)),
    }
}

/// 执行 AI 代理（支持可选 PID 捕获，用于取消任务）
pub fn execute_ai_agent(
    workspace_root: &Path,
    args: &[String],
    pid_holder: Option<&std::sync::Arc<std::sync::Mutex<Option<u32>>>>,
) -> Result<String, String> {
    use std::process::Command;
    let program = args
        .first()
        .ok_or_else(|| "AI agent command is empty".to_string())?;
    if !Path::new(LOGIN_ZSH_PATH).exists() {
        return Err(format!("zsh not found at {}", LOGIN_ZSH_PATH));
    }
    let launch_args = wrap_command_for_login_zsh(args)
        .map_err(|e| format!("Failed to build AI agent launch args: {}", e))?;

    info!(
        "Executing AI agent: {} (cwd: {})",
        program,
        workspace_root.display()
    );

    let child = Command::new(LOGIN_ZSH_PATH)
        .args(&launch_args)
        .current_dir(workspace_root)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("Failed to execute AI agent '{}': {}", program, e))?;

    // 捕获 PID 供取消使用
    if let Some(holder) = pid_holder {
        if let Ok(mut guard) = holder.lock() {
            *guard = Some(child.id());
        }
    }

    let output = child
        .wait_with_output()
        .map_err(|e| format!("Failed to wait for AI agent '{}': {}", program, e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        warn!("AI agent '{}' exited with error: {}", program, stderr);
        return Err(format!("AI agent failed: {}", stderr));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    info!(
        "AI agent '{}' completed, output length: {} bytes",
        program,
        stdout.len()
    );
    Ok(stdout.to_string())
}

/// 从 envelope 格式中提取内层 JSON（兼容 { "response": "..." } 等包装）
pub fn extract_inner_json(value: &Value) -> Value {
    // 尝试常见 envelope 字段
    for key in &["response", "result", "output", "data"] {
        if let Some(inner_str) = value.get(*key).and_then(|v| v.as_str()) {
            // 尝试解析内层字符串为 JSON
            if let Ok(inner) = serde_json::from_str::<Value>(inner_str) {
                if inner.is_object() {
                    return inner;
                }
            }
        }
        // 如果 envelope 字段本身就是对象
        if let Some(inner) = value.get(*key) {
            if inner.is_object() && inner.get("commits").is_some() {
                return inner.clone();
            }
        }
    }
    value.clone()
}

/// 从 AI 输出中提取 JSON（改进版：支持 markdown 代码块、裸 JSON、事件流）
pub fn extract_json_from_output(output: &str) -> Result<String, String> {
    // 策略 1: 从 markdown 代码块提取
    if let Some(json) = extract_json_from_code_block(output) {
        return Ok(json);
    }

    // 策略 2: 从事件流中提取最后一个 type=text 事件（OpenCode --format json）
    if let Some(json) = extract_json_from_event_stream(output) {
        return Ok(json);
    }

    // 策略 3: 使用平衡括号提取裸 JSON 对象
    if let Some(json) = extract_balanced_json(output) {
        return Ok(json);
    }

    Err("Could not find JSON in AI output".to_string())
}

/// 从 markdown 代码块中提取 JSON
fn extract_json_from_code_block(output: &str) -> Option<String> {
    let lines: Vec<&str> = output.lines().collect();
    let mut json_start = None;
    let mut json_end = None;
    let mut in_json = false;

    for (i, line) in lines.iter().enumerate() {
        let trimmed = line.trim();
        if trimmed.starts_with("```json") || trimmed == "```" && in_json {
            if in_json {
                json_end = Some(i);
                break;
            } else {
                in_json = true;
                continue;
            }
        }
        if in_json && json_start.is_none() && !trimmed.is_empty() {
            json_start = Some(i);
        }
    }

    if let (Some(start), Some(end)) = (json_start, json_end) {
        let json_str = lines[start..end].join("\n");
        // 验证是否为有效 JSON
        if serde_json::from_str::<Value>(&json_str).is_ok() {
            return Some(json_str);
        }
    }
    None
}

/// 从事件流中提取 JSON（OpenCode --format json 输出格式）
fn extract_json_from_event_stream(output: &str) -> Option<String> {
    // 逆序查找最后一个包含 "type":"text" 或 type=text 的事件
    let mut last_text_content = None;
    for line in output.lines().rev() {
        let trimmed = line.trim();
        if let Ok(event) = serde_json::from_str::<Value>(trimmed) {
            if event.get("type").and_then(|v| v.as_str()) == Some("text") {
                if let Some(part) = event.get("part") {
                    if let Some(text) = part.get("text").and_then(|v| v.as_str()) {
                        last_text_content = Some(text.to_string());
                        break;
                    }
                }
            }
        }
    }

    if let Some(text) = last_text_content {
        // 从 text 内容中提取 JSON
        if let Some(json) = extract_balanced_json(&text) {
            return Some(json);
        }
    }
    None
}

/// 使用平衡括号提取第一个完整 JSON 对象
fn extract_balanced_json(text: &str) -> Option<String> {
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '{' {
            let start = i;
            let mut depth = 0;
            let mut in_string = false;
            let mut escape = false;
            while i < chars.len() {
                let c = chars[i];
                if escape {
                    escape = false;
                } else if c == '\\' && in_string {
                    escape = true;
                } else if c == '"' {
                    in_string = !in_string;
                } else if !in_string {
                    if c == '{' {
                        depth += 1;
                    } else if c == '}' {
                        depth -= 1;
                        if depth == 0 {
                            let candidate: String = chars[start..=i].iter().collect();
                            if let Ok(val) = serde_json::from_str::<Value>(&candidate) {
                                // 确保包含 commits 或 success 字段
                                if val.get("commits").is_some() || val.get("success").is_some() {
                                    return Some(candidate);
                                }
                            }
                            break;
                        }
                    }
                }
                i += 1;
            }
        }
        i += 1;
    }
    None
}

/// 取消 AI 任务（按 project + workspace + operation_type 查找）
pub async fn handle_cancel_ai_task(
    project: &str,
    workspace: &str,
    operation_type: &str,
    socket: &mut WebSocket,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    let mut registry = ctx.running_ai_tasks.lock().await;

    // 按 project + workspace + operation_type 查找
    let task_id = registry
        .iter()
        .find(|(_, entry)| {
            entry.project == project
                && entry.workspace == workspace
                && entry.operation_type == operation_type
        })
        .map(|(id, _)| id.clone());

    let Some(task_id) = task_id else {
        info!(
            "CancelAITask: no matching task found (project={}, workspace={}, op={})",
            project, workspace, operation_type
        );
        return Ok(true);
    };

    if let Some(entry) = registry.remove(&task_id) {
        // 终止子进程
        if let Ok(guard) = entry.child_pid.lock() {
            if let Some(pid) = *guard {
                info!("Killing AI task child process: pid={}", pid);
                unsafe {
                    libc::kill(pid as i32, libc::SIGKILL);
                }
            }
        }
        // 取消 tokio 任务
        entry.join_handle.abort();

        info!(
            "AI task cancelled: project={}, workspace={}, op={}",
            project, workspace, operation_type
        );

        // 发送确认给发起者
        let msg = ServerMessage::AITaskCancelled {
            project: project.to_string(),
            workspace: workspace.to_string(),
            operation_type: operation_type.to_string(),
        };
        send_message(socket, &msg).await?;

        // 广播给其他连接
        let _ = crate::server::context::send_task_broadcast_message(
            &ctx.task_broadcast_tx,
            &ctx.conn_meta.conn_id,
            msg,
        );

        // 更新任务历史
        drop(registry);
        update_task_history(
            &ctx.task_history,
            &task_id,
            "cancelled",
            Some("已取消".to_string()),
        )
        .await;
        let snapshot = list_tasks_snapshot_message(&ctx.task_history).await;
        let _ = crate::server::context::send_task_broadcast_message(
            &ctx.task_broadcast_tx,
            &ctx.conn_meta.conn_id,
            snapshot,
        );
        crate::application::sidebar_status::notify_workspace_sidebar_changed(
            ctx, project, workspace,
        )
        .await;
    }

    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::execute_ai_agent;
    use tempfile::tempdir;

    #[test]
    fn execute_ai_agent_should_reject_empty_args() {
        let temp = tempdir().expect("temp dir");
        let err = execute_ai_agent(temp.path(), &[], None).expect_err("empty args should fail");
        assert!(err.contains("empty"));
    }
}
