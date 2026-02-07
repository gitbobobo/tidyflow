use axum::extract::ws::WebSocket;
use serde_json::Value;
use std::path::Path;
use std::process::Command;

use crate::server::git;
use crate::server::protocol::{AIGitCommit, ClientMessage, GitBranchInfo, ServerMessage};
use crate::server::ws::{send_message, SharedAppState};

use super::get_workspace_root;

pub async fn try_handle_git_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    match client_msg {
        // v1.8: Git branches
        ClientMessage::GitBranches { project, workspace } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => match get_workspace_root(p, workspace) {
                    Some(root) => {
                        drop(state);

                        let result =
                            tokio::task::spawn_blocking(move || git::git_branches(&root)).await;

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
                    }
                    None => {
                        send_message(
                            socket,
                            &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            },
                        )
                        .await?;
                    }
                },
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

        // v1.8: Git switch branch
        ClientMessage::GitSwitchBranch {
            project,
            workspace,
            branch,
        } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => match get_workspace_root(p, workspace) {
                    Some(root) => {
                        drop(state);

                        let branch_clone = branch.clone();
                        let result = tokio::task::spawn_blocking(move || {
                            git::git_switch_branch(&root, &branch_clone)
                        })
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
                    }
                    None => {
                        send_message(
                            socket,
                            &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            },
                        )
                        .await?;
                    }
                },
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

        // v1.9: Git create branch
        ClientMessage::GitCreateBranch {
            project,
            workspace,
            branch,
        } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => match get_workspace_root(p, workspace) {
                    Some(root) => {
                        drop(state);

                        let branch_clone = branch.clone();
                        let result = tokio::task::spawn_blocking(move || {
                            git::git_create_branch(&root, &branch_clone)
                        })
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
                    }
                    None => {
                        send_message(
                            socket,
                            &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            },
                        )
                        .await?;
                    }
                },
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

        // v1.10: Git commit
        ClientMessage::GitCommit {
            project,
            workspace,
            message,
        } => {
            let state = app_state.lock().await;
            match state.get_project(project) {
                Some(p) => match get_workspace_root(p, workspace) {
                    Some(root) => {
                        drop(state);

                        let message_clone = message.clone();
                        let result = tokio::task::spawn_blocking(move || {
                            git::git_commit(&root, &message_clone)
                        })
                        .await;

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
                    }
                    None => {
                        send_message(
                            socket,
                            &ServerMessage::Error {
                                code: "workspace_not_found".to_string(),
                                message: format!("Workspace '{}' not found", workspace),
                            },
                        )
                        .await?;
                    }
                },
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

        // v1.26: AI Git commit
        ClientMessage::GitAICommit {
            project,
            workspace,
            ai_agent,
        } => {
            try_handle_git_ai_commit(project.clone(), workspace.clone(), ai_agent.clone(), socket, app_state).await
        }

        _ => Ok(false),
    }
}

/// 处理 AI 智能提交
pub async fn try_handle_git_ai_commit(
    project: String,
    workspace: String,
    ai_agent: Option<String>,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    let state = app_state.lock().await;
    match state.get_project(&project) {
        Some(p) => match get_workspace_root(p, &workspace) {
            Some(root) => {
                let ai_agent_type = ai_agent.unwrap_or_else(|| "cursor".to_string());
                drop(state);

                let root_clone = root.clone();
                let result = tokio::task::spawn_blocking(move || {
                    handle_ai_commit_internal(&root_clone, &ai_agent_type)
                })
                .await;

                match result {
                    Ok(Ok(ai_commit_result)) => {
                        send_message(
                            socket,
                            &ServerMessage::GitAICommitResult {
                                success: true,
                                message: ai_commit_result.message,
                                commits: ai_commit_result.commits,
                            },
                        )
                        .await?;
                    }
                    Ok(Err(e)) => {
                        send_message(
                            socket,
                            &ServerMessage::GitAICommitResult {
                                success: false,
                                message: e,
                                commits: vec![],
                            },
                        )
                        .await?;
                    }
                    Err(e) => {
                        send_message(
                            socket,
                            &ServerMessage::Error {
                                code: "internal_error".to_string(),
                                message: format!("AI commit task failed: {}", e),
                            },
                        )
                        .await?;
                    }
                }
            }
            None => {
                send_message(
                    socket,
                    &ServerMessage::Error {
                        code: "workspace_not_found".to_string(),
                        message: format!("Workspace '{}' not found", workspace),
                    },
                )
                .await?;
            }
        },
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

/// 内部函数：执行 AI 智能提交逻辑
fn handle_ai_commit_internal(workspace_root: &Path, ai_agent: &str) -> Result<AIGitCommitOutput, String> {
    use std::process::Command;

    // 检查是否为 git 仓库
    if git::utils::get_git_repo_root(workspace_root).is_none() {
        return Err("Not a git repository".to_string());
    }

    // 步骤 1: 分析现有提交风格
    let commit_style = analyze_commit_style(workspace_root)?;

    // 步骤 2: 分析变更
    let changes = analyze_changes(workspace_root)?;

    if changes.is_empty() {
        return Ok(AIGitCommitOutput {
            message: "No changes to commit".to_string(),
            commits: vec![],
        });
    }

    // 步骤 3: 构建并执行 AI 命令
    let ai_command = build_ai_commit_prompt(&commit_style, &changes);

    let agent_args = build_ai_agent_command(ai_agent, &ai_command)?;
    let ai_output = execute_ai_agent(workspace_root, &agent_args)?;

    // 步骤 4: 解析 AI 输出并执行提交
    let commit_plan = parse_ai_output(&ai_output)?;

    // 步骤 5: 执行原子提交
    let commits = execute_commits(workspace_root, &commit_plan)?;

    // 步骤 6: 验证结果
    let final_status = Command::new("git")
        .args(["status", "--short"])
        .current_dir(workspace_root)
        .output()
        .map_err(|e| format!("Failed to verify git status: {}", e))?;

    if final_status.status.success() {
        let stdout = String::from_utf8_lossy(&final_status.stdout);
        if stdout.trim().is_empty() {
            Ok(AIGitCommitOutput {
                message: format!(
                    "AI commit completed successfully. Created {} commit(s).",
                    commits.len()
                ),
                commits,
            })
        } else {
            Ok(AIGitCommitOutput {
                message: format!(
                    "AI commit completed with {} commit(s). Some changes remain uncommitted: {}",
                    commits.len(),
                    stdout.lines().count()
                ),
                commits,
            })
        }
    } else {
        Err(format!(
            "Failed to verify final status: {}",
            String::from_utf8_lossy(&final_status.stderr)
        ))
    }
}

/// 分析提交风格
fn analyze_commit_style(workspace_root: &Path) -> Result<CommitStyle, String> {
    let output = Command::new("git")
        .args(["log", "--oneline", "-30"])
        .current_dir(workspace_root)
        .output()
        .map_err(|e| format!("Failed to analyze commit style: {}", e))?;

    if !output.status.success() {
        // 新仓库无历史，使用默认风格
        return Ok(CommitStyle::default());
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let lines: Vec<&str> = stdout.lines().collect();

    if lines.is_empty() {
        return Ok(CommitStyle::default());
    }

    // 检测风格
    let mut conventional_count = 0;
    let mut chinese_count = 0;

    for line in lines.iter().take(10) {
        let parts: Vec<&str> = line.splitn(2, ' ').collect();
        if parts.len() >= 2 {
            let msg = parts[1];
            if msg.contains('(') && msg.contains(')') && msg.contains(':') {
                conventional_count += 1;
            }
        }
        if line.chars().any(|c| {
            let c = c as u32;
            (0x4E00..=0x9FFF).contains(&c) || (0x3400..=0x4DBF).contains(&c)
        }) {
            chinese_count += 1;
        }
    }

    Ok(CommitStyle {
        is_conventional: conventional_count > 5,
        is_chinese: chinese_count > 5,
    })
}

/// 分析变更
fn analyze_changes(workspace_root: &Path) -> Result<Vec<ChangeGroup>, String> {
    use std::process::Command;
    use std::collections::HashMap;

    let mut groups: HashMap<String, ChangeGroup> = HashMap::new();

    // 分析暂存变更
    let staged = Command::new("git")
        .args(["diff", "--staged", "--name-only"])
        .current_dir(workspace_root)
        .output()
        .map_err(|e| format!("Failed to list staged changes: {}", e))?;

    if staged.status.success() {
        let stdout = String::from_utf8_lossy(&staged.stdout);
        for path in stdout.lines() {
            if !path.is_empty() {
                let group_key = get_change_group_key(path);
                let key_clone = group_key.clone();
                groups
                    .entry(group_key)
                    .or_insert_with(|| ChangeGroup::new(key_clone))
                    .add_file(path.to_string(), true);
            }
        }
    }

    // 分析未暂存变更
    let unstaged = Command::new("git")
        .args(["diff", "--name-only"])
        .current_dir(workspace_root)
        .output()
        .map_err(|e| format!("Failed to list unstaged changes: {}", e))?;

    if unstaged.status.success() {
        let stdout = String::from_utf8_lossy(&unstaged.stdout);
        for path in stdout.lines() {
            if !path.is_empty() {
                let group_key = get_change_group_key(path);
                let key_clone = group_key.clone();
                groups
                    .entry(group_key)
                    .or_insert_with(|| ChangeGroup::new(key_clone))
                    .add_file(path.to_string(), false);
            }
        }
    }

    let mut groups_vec: Vec<ChangeGroup> = groups.into_values().collect();
    groups_vec.sort_by(|a, b| a.key.cmp(&b.key));
    Ok(groups_vec)
}

/// 根据文件路径获取分组键
fn get_change_group_key(path: &str) -> String {
    let parts: Vec<&str> = path.split('/').collect();
    if parts.len() >= 2 {
        // 按第一层目录分组
        parts[0].to_string()
    } else {
        // 根目录文件
        "root".to_string()
    }
}

/// 构建 AI 提交提示词
fn build_ai_commit_prompt(style: &CommitStyle, changes: &[ChangeGroup]) -> String {
    let mut prompt = String::from(
        "你是一个 Git 提交助手。请在当前目录分析变更并执行智能提交。这是纯本地操作，禁止任何网络请求。\n\n",
    );

    prompt.push_str(&format!("**提交风格要求**：\n"));
    if style.is_conventional {
        prompt.push_str("- 格式：`type(scope): description` (Conventional Commits)\n");
    } else {
        prompt.push_str("- 格式：简洁明了的描述性消息\n");
    }
    if style.is_chinese {
        prompt.push_str("- 语言：中文为主，技术术语保持英文\n");
    } else {
        prompt.push_str("- 语言：英文\n");
    }
    prompt.push_str("\n");

    prompt.push_str("**变更文件列表**：\n");
    for (i, group) in changes.iter().enumerate() {
        prompt.push_str(&format!("\n### 分组 {} ({})\n", i + 1, group.key));
        for file in &group.files {
            let status = if file.staged { "已暂存" } else { "未暂存" };
            prompt.push_str(&format!("- {} [{}]\n", file.path, status));
        }
    }

    prompt.push_str("\n**请按以下步骤执行**：\n");
    prompt.push_str("1. 使用 `git diff --staged` 和 `git diff` 理解每个文件的修改意图\n");
    prompt.push_str("2. 将变更按逻辑分组为原子提交（按目录/模块/关注点）\n");
    prompt.push_str("3. 对每组文件执行 `git add <files>` 然后 `git commit -m \"<message>\"`\n");
    prompt.push_str("4. 以严格 JSON 格式输出结果：\n");
    prompt.push_str("```json\n");
    prompt.push_str("{\n");
    prompt.push_str("  \"success\": true/false,\n");
    prompt.push_str("  \"message\": \"操作结果描述\",\n");
    prompt.push_str("  \"commits\": [\n");
    prompt.push_str("    {\n");
    prompt.push_str("      \"sha\": \"提交的短 SHA\",\n");
    prompt.push_str("      \"message\": \"提交消息\",\n");
    prompt.push_str("      \"files\": [\"提交包含的文件路径列表\"]\n");
    prompt.push_str("    }\n");
    prompt.push_str("  ]\n");
    prompt.push_str("}\n");
    prompt.push_str("```\n");
    prompt.push_str("只输出 JSON，不要输出其他内容。\n");

    prompt
}

/// 构建 AI 代理命令
fn build_ai_agent_command(agent: &str, prompt: &str) -> Result<Vec<String>, String> {
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
        _ => Err(format!("Unknown AI agent: {}", agent)),
    }
}

/// 执行 AI 代理
fn execute_ai_agent(workspace_root: &Path, args: &[String]) -> Result<String, String> {
    use std::process::Command;

    let output = Command::new(&args[0])
        .args(&args[1..])
        .current_dir(workspace_root)
        .output()
        .map_err(|e| format!("Failed to execute AI agent '{}': {}", args[0], e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("AI agent failed: {}", stderr));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    Ok(stdout.to_string())
}

/// 解析 AI 输出
fn parse_ai_output(output: &str) -> Result<Vec<CommitPlan>, String> {
    let json_str = extract_json_from_output(output)?;
    let value: Value = serde_json::from_str(&json_str)
        .map_err(|e| format!("Failed to parse AI output as JSON: {}", e))?;

    let success = value
        .get("success")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    if !success {
        let message = value
            .get("message")
            .and_then(|v| v.as_str())
            .unwrap_or("Unknown error");
        return Err(format!("AI commit failed: {}", message));
    }

    let commits = value
        .get("commits")
        .and_then(|v| v.as_array())
        .ok_or("Missing 'commits' field in AI output")?;

    let mut plans = Vec::new();
    for commit in commits {
        let _sha = commit
            .get("sha")
            .and_then(|v| v.as_str())
            .ok_or("Missing 'sha' in commit")?;
        let message = commit
            .get("message")
            .and_then(|v| v.as_str())
            .ok_or("Missing 'message' in commit")?;
        let files = commit
            .get("files")
            .and_then(|v| v.as_array())
            .ok_or("Missing 'files' in commit")?;

        let file_list: Vec<String> = files
            .iter()
            .filter_map(|v| v.as_str().map(|s| s.to_string()))
            .collect();

        plans.push(CommitPlan {
            message: message.to_string(),
            files: file_list,
        });
    }

    Ok(plans)
}

/// 从 AI 输出中提取 JSON
fn extract_json_from_output(output: &str) -> Result<String, String> {
    let lines: Vec<&str> = output.lines().collect();

    let mut json_start = None;
    let mut json_end = None;
    let mut brace_count = 0;
    let mut in_json = false;

    for (i, line) in lines.iter().enumerate() {
        let trimmed = line.trim();

        if trimmed.starts_with("```json") {
            in_json = true;
            continue;
        }

        if trimmed == "```" && in_json {
            json_end = Some(i);
            break;
        }

        if in_json {
            if json_start.is_none() {
                json_start = Some(i);
            }
            brace_count += trimmed.matches('{').count() as i32;
            brace_count -= trimmed.matches('}').count() as i32;

            if brace_count == 0 && json_start.is_some() {
                json_end = Some(i + 1);
                break;
            }
        }
    }

    if let (Some(start), Some(end)) = (json_start, json_end) {
        let json_str = lines[start..end].join("\n");
        Ok(json_str)
    } else {
        Err("Could not find JSON in AI output".to_string())
    }
}

/// 执行提交计划
fn execute_commits(workspace_root: &Path, plans: &[CommitPlan]) -> Result<Vec<AIGitCommit>, String> {
    use std::process::Command;

    let mut commits = Vec::new();

    for plan in plans {
        if plan.files.is_empty() {
            continue;
        }

        // 添加文件
        let mut add_args = vec!["add".to_string()];
        add_args.extend(plan.files.iter().cloned());

        let add_output = Command::new("git")
            .args(&add_args)
            .current_dir(workspace_root)
            .output()
            .map_err(|e| format!("Failed to git add files: {}", e))?;

        if !add_output.status.success() {
            return Err(format!(
                "Failed to stage files: {}",
                String::from_utf8_lossy(&add_output.stderr)
            ));
        }

        // 提交
        let commit_output = Command::new("git")
            .args(["commit", "-m", &plan.message])
            .current_dir(workspace_root)
            .output()
            .map_err(|e| format!("Failed to git commit: {}", e))?;

        if !commit_output.status.success() {
            return Err(format!(
                "Failed to commit: {}",
                String::from_utf8_lossy(&commit_output.stderr)
            ));
        }

        // 获取短 SHA
        let sha = git::utils::get_short_head_sha(workspace_root).unwrap_or_else(|| "unknown".to_string());

        commits.push(AIGitCommit {
            sha,
            message: plan.message.clone(),
            files: plan.files.clone(),
        });
    }

    Ok(commits)
}

/// 提交风格
#[derive(Debug, Clone)]
struct CommitStyle {
    is_conventional: bool,
    is_chinese: bool,
}

impl Default for CommitStyle {
    fn default() -> Self {
        Self {
            is_conventional: true,
            is_chinese: true,
        }
    }
}

/// 变更分组
#[derive(Debug, Clone)]
struct ChangeGroup {
    key: String,
    files: Vec<ChangeFile>,
}

impl ChangeGroup {
    fn new(key: String) -> Self {
        Self {
            key,
            files: Vec::new(),
        }
    }

    fn add_file(&mut self, path: String, staged: bool) {
        self.files.push(ChangeFile { path, staged });
    }
}

/// 变更文件
#[derive(Debug, Clone)]
struct ChangeFile {
    path: String,
    staged: bool,
}

/// 提交计划
#[derive(Debug, Clone)]
struct CommitPlan {
    message: String,
    files: Vec<String>,
}

/// AI 提交输出
struct AIGitCommitOutput {
    message: String,
    commits: Vec<AIGitCommit>,
}
