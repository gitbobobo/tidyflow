use axum::extract::ws::WebSocket;
use serde_json::Value;
use std::path::Path;
use std::process::Command;
use std::time::Duration;
use tokio::sync::oneshot;
use tracing::{error, info, warn};

use crate::server::context::{
    push_task_history, resolve_workspace, update_task_history, HandlerContext, RunningAITaskEntry,
    SharedAppState, TaskHistoryEntry,
};
use crate::server::git;
use crate::server::protocol::{AIGitCommit, ClientMessage, GitBranchInfo, ServerMessage};
use crate::server::ws::send_message;
use crate::util::shell_launch::{wrap_command_for_login_zsh, LOGIN_ZSH_PATH};

/// AI 代理执行超时（10 分钟）
const AI_AGENT_TIMEOUT: Duration = Duration::from_secs(600);

pub async fn handle_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ctx: &HandlerContext,
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

        // v1.26: AI Git commit
        ClientMessage::GitAICommit {
            project,
            workspace,
            ai_agent,
        } => {
            handle_git_ai_commit(
                project.clone(),
                workspace.clone(),
                ai_agent.clone(),
                socket,
                app_state,
                ctx,
            )
            .await
        }

        _ => Ok(false),
    }
}

/// 处理 AI 智能提交（后台执行，不阻塞 WebSocket 主循环）
pub async fn handle_git_ai_commit(
    project: String,
    workspace: String,
    ai_agent: Option<String>,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    let ws_ctx = match resolve_workspace(app_state, &project, &workspace).await {
        Ok(ctx) => ctx,
        Err(e) => {
            send_message(socket, &e.to_server_error()).await?;
            return Ok(true);
        }
    };

    let _ = spawn_git_ai_commit_task(
        project,
        workspace,
        ws_ctx.root_path,
        ai_agent,
        "AI 提交",
        ctx,
    )
    .await;
    Ok(true)
}

async fn run_git_ai_commit_once(
    project: String,
    workspace: String,
    workspace_root: std::path::PathBuf,
    ai_agent: String,
    pid_holder: std::sync::Arc<std::sync::Mutex<Option<u32>>>,
) -> ServerMessage {
    let root_clone = workspace_root;
    let agent_clone = ai_agent;
    let pid_for_blocking = pid_holder;

    let result = tokio::time::timeout(
        AI_AGENT_TIMEOUT,
        tokio::task::spawn_blocking(move || {
            run_ai_commit_internal(&root_clone, &agent_clone, Some(&pid_for_blocking))
        }),
    )
    .await;

    match result {
        Ok(Ok(Ok(ai_commit_result))) => {
            info!(
                "AI commit succeeded: project={}, workspace={}, commits={}",
                project,
                workspace,
                ai_commit_result.commits.len()
            );
            ServerMessage::GitAICommitResult {
                project,
                workspace,
                success: true,
                message: ai_commit_result.message,
                commits: ai_commit_result.commits,
            }
        }
        Ok(Ok(Err(e))) => {
            warn!(
                "AI commit failed: project={}, workspace={}, error={}",
                project, workspace, e
            );
            ServerMessage::GitAICommitResult {
                project,
                workspace,
                success: false,
                message: e,
                commits: vec![],
            }
        }
        Ok(Err(e)) => {
            error!("AI commit task panicked: {}", e);
            ServerMessage::GitAICommitResult {
                project,
                workspace,
                success: false,
                message: format!("AI commit task failed: {}", e),
                commits: vec![],
            }
        }
        Err(_) => {
            error!(
                "AI commit timed out after {}s: project={}, workspace={}",
                AI_AGENT_TIMEOUT.as_secs(),
                project,
                workspace
            );
            ServerMessage::GitAICommitResult {
                project,
                workspace,
                success: false,
                message: format!(
                    "AI agent timed out after {} seconds",
                    AI_AGENT_TIMEOUT.as_secs()
                ),
                commits: vec![],
            }
        }
    }
}

/// 统一的 AI 提交任务入口（用户 Git 智能提交与 Evolution 自动提交复用）。
pub(crate) async fn spawn_git_ai_commit_task(
    project: String,
    workspace: String,
    workspace_root: std::path::PathBuf,
    ai_agent: Option<String>,
    task_title: &str,
    ctx: &HandlerContext,
) -> oneshot::Receiver<ServerMessage> {
    let ai_agent_type = ai_agent.unwrap_or_else(|| "cursor".to_string());

    info!(
        "AI commit started: project={}, workspace={}, agent={}",
        project, workspace, ai_agent_type
    );

    let cmd_output_tx = ctx.cmd_output_tx.clone();
    let task_broadcast_tx = ctx.task_broadcast_tx.clone();
    let origin_conn_id = ctx.conn_meta.conn_id.clone();
    let task_history = ctx.task_history.clone();

    let running_ai_tasks = ctx.running_ai_tasks.clone();
    let task_id = uuid::Uuid::new_v4().to_string();
    let child_pid: std::sync::Arc<std::sync::Mutex<Option<u32>>> =
        std::sync::Arc::new(std::sync::Mutex::new(None));
    let child_pid_clone = child_pid.clone();
    let task_id_clone = task_id.clone();
    let running_ai_tasks_cleanup = running_ai_tasks.clone();
    let project_for_task = project.clone();
    let workspace_for_task = workspace.clone();
    let ai_agent_for_task = ai_agent_type.clone();

    let (result_tx, result_rx) = oneshot::channel::<ServerMessage>();

    let join_handle = tokio::spawn(async move {
        let msg = run_git_ai_commit_once(
            project_for_task,
            workspace_for_task,
            workspace_root,
            ai_agent_for_task,
            child_pid_clone,
        )
        .await;

        if let Err(e) = cmd_output_tx.send(msg.clone()).await {
            error!("Failed to send AI commit result to WS: {}", e);
        }
        let _ = crate::server::context::send_task_broadcast_message(
            &task_broadcast_tx,
            &origin_conn_id,
            msg.clone(),
        );
        if let ServerMessage::GitAICommitResult {
            success,
            ref message,
            ..
        } = msg
        {
            let status = if success { "completed" } else { "failed" };
            update_task_history(&task_history, &task_id_clone, status, Some(message.clone())).await;
        }
        let _ = result_tx.send(msg.clone());
        running_ai_tasks_cleanup.lock().await.remove(&task_id_clone);
    });

    running_ai_tasks.lock().await.insert(
        task_id.clone(),
        RunningAITaskEntry {
            task_id: task_id.clone(),
            project: project.clone(),
            workspace: workspace.clone(),
            operation_type: "ai_commit".to_string(),
            child_pid,
            join_handle,
        },
    );

    push_task_history(
        &ctx.task_history,
        TaskHistoryEntry {
            task_id,
            project,
            workspace,
            task_type: "ai_commit".to_string(),
            command_id: None,
            title: task_title.to_string(),
            status: "running".to_string(),
            message: None,
            started_at: chrono::Utc::now().timestamp_millis(),
            completed_at: None,
        },
    )
    .await;

    result_rx
}

/// 内部函数：执行 AI 智能提交逻辑（委托式：AI 代理执行 git 操作，我们解析结果）
pub(crate) fn run_ai_commit_internal(
    workspace_root: &Path,
    ai_agent: &str,
    pid_holder: Option<&std::sync::Arc<std::sync::Mutex<Option<u32>>>>,
) -> Result<AIGitCommitOutput, String> {
    // 检查是否为 git 仓库
    if git::utils::get_git_repo_root(workspace_root).is_none() {
        return Err("Not a git repository".to_string());
    }

    // 快速检查：是否有变更
    if !has_changes(workspace_root)? {
        return Ok(AIGitCommitOutput {
            message: "No changes to commit".to_string(),
            commits: vec![],
        });
    }

    // 构建提示词 → 交给 AI 执行 → 解析结果
    let prompt = build_ai_commit_prompt();
    let agent_args = build_ai_agent_command(ai_agent, &prompt)?;
    let ai_output = execute_ai_agent(workspace_root, &agent_args, pid_holder)?;
    let ai_result = parse_ai_commit_result(&ai_output)?;

    Ok(AIGitCommitOutput {
        message: format!(
            "AI commit completed. Created {} commit(s).",
            ai_result.len()
        ),
        commits: ai_result,
    })
}

/// 快速检查是否有变更（暂存或未暂存）
fn has_changes(workspace_root: &Path) -> Result<bool, String> {
    let output = Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(workspace_root)
        .output()
        .map_err(|e| format!("Failed to check git status: {}", e))?;

    Ok(output.status.success() && !String::from_utf8_lossy(&output.stdout).trim().is_empty())
}

/// 构建 AI 提交提示词（所有分析交给 AI 自行完成）
fn build_ai_commit_prompt() -> String {
    r#"你是一个 Git 提交助手。请在当前目录分析变更并执行智能提交。这是纯本地操作，禁止任何网络请求。

请按以下步骤执行：
1. 运行 `git log --oneline -10` 了解现有提交风格（Conventional Commits 与否、中英文），并沿用
2. 运行 `git status` 和 `git diff` 理解所有变更（含未追踪文件）
3. 对未追踪文件进行判断：构建产物、缓存、IDE 配置、依赖目录、敏感文件等不应入库的文件，追加到 `.gitignore`（如已存在则跳过）
4. 将应提交的变更按逻辑分组为原子提交（按模块/关注点）
5. 对每组执行 `git add <files>` 然后 `git commit -m "<message>"`（若修改了 `.gitignore`，将其纳入第一个提交）
6. 以严格 JSON 格式输出结果（只输出 JSON，不要输出其他内容）：
```json
{
  "success": true,
  "message": "操作结果描述",
  "commits": [
    { "sha": "短SHA", "message": "提交消息", "files": ["文件路径"] }
  ]
}
```"#
    .to_string()
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

/// 解析 AI 输出为提交结果（委托式：AI 已执行提交，直接解析结果 JSON）
fn parse_ai_commit_result(output: &str) -> Result<Vec<AIGitCommit>, String> {
    let json_str = extract_json_from_output(output)?;
    let value: Value = serde_json::from_str(&json_str)
        .map_err(|e| format!("Failed to parse AI output as JSON: {}", e))?;

    // 兼容 envelope 格式：某些 agent 输出 { "response": "..." } 或 { "result": "..." }
    let inner = extract_inner_json(&value);

    let success = inner
        .get("success")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    if !success {
        let message = inner
            .get("message")
            .and_then(|v| v.as_str())
            .unwrap_or("Unknown error");
        return Err(format!("AI commit failed: {}", message));
    }

    let commits = inner
        .get("commits")
        .and_then(|v| v.as_array())
        .ok_or("Missing 'commits' field in AI output")?;

    let mut result = Vec::new();
    for commit in commits {
        let sha = commit
            .get("sha")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .to_string();
        let message = commit
            .get("message")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let files = commit
            .get("files")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default();

        result.push(AIGitCommit {
            sha,
            message,
            files,
        });
    }

    Ok(result)
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

/// AI 提交输出
pub(crate) struct AIGitCommitOutput {
    pub(crate) message: String,
    pub(crate) commits: Vec<AIGitCommit>,
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
    }

    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::{build_ai_commit_prompt, execute_ai_agent};
    use tempfile::tempdir;

    #[test]
    fn ai_commit_prompt_should_require_git_add_and_git_commit() {
        let prompt = build_ai_commit_prompt();
        assert!(
            prompt.contains("git add"),
            "AI 提交提示词必须包含 git add 约束"
        );
        assert!(
            prompt.contains("git commit"),
            "AI 提交提示词必须包含 git commit 约束"
        );
    }

    #[test]
    fn execute_ai_agent_should_reject_empty_args() {
        let temp = tempdir().expect("temp dir");
        let err = execute_ai_agent(temp.path(), &[], None).expect_err("empty args should fail");
        assert!(err.contains("empty"));
    }
}
