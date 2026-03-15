//! Git stash 操作
//!
//! 提供 stash 的列表查询、详情查看、创建、应用、弹出、删除和文件恢复功能。

use std::path::Path;
use std::process::Command;

use super::status::invalidate_git_status_cache;
use super::utils::*;

// ── 领域类型 ──

/// Stash 条目信息
#[derive(Debug, Clone)]
pub struct StashEntry {
    /// e.g. "stash@{0}"
    pub stash_id: String,
    /// 完整的 git stash 行
    pub title: String,
    /// 用户消息或自动生成的描述
    pub message: String,
    /// 创建 stash 时所在的分支
    pub branch_name: String,
    /// ISO 日期字符串
    pub created_at: String,
    /// 涉及的文件数
    pub file_count: usize,
    /// 是否包含未跟踪文件
    pub includes_untracked: bool,
    /// 是否保留了暂存区
    pub includes_index: bool,
}

/// Stash 文件条目信息
#[derive(Debug, Clone)]
pub struct StashFileEntry {
    /// 文件路径
    pub path: String,
    /// 文件状态码："M", "A", "D" 等
    pub status: String,
    /// 新增行数
    pub additions: i32,
    /// 删除行数
    pub deletions: i32,
    /// 来源类型："tracked" | "untracked" | "index"
    pub source_kind: String,
}

/// Stash 列表结果
#[derive(Debug)]
pub struct StashListResult {
    pub entries: Vec<StashEntry>,
}

/// Stash 详情结果
#[derive(Debug)]
pub struct StashShowResult {
    pub entry: StashEntry,
    pub files: Vec<StashFileEntry>,
    pub diff_text: String,
    pub is_binary_summary_truncated: bool,
}

/// Stash 操作状态
#[derive(Debug, Clone, PartialEq)]
pub enum StashOpState {
    Completed,
    Conflict,
    Noop,
    Failed,
}

impl StashOpState {
    pub fn as_str(&self) -> &'static str {
        match self {
            StashOpState::Completed => "completed",
            StashOpState::Conflict => "conflict",
            StashOpState::Noop => "noop",
            StashOpState::Failed => "failed",
        }
    }
}

/// Stash 操作结果
#[derive(Debug)]
pub struct StashOpResult {
    pub op: String,
    pub stash_id: String,
    pub ok: bool,
    pub state: StashOpState,
    pub message: Option<String>,
    pub affected_paths: Vec<String>,
    pub conflict_files: Vec<ConflictFileEntry>,
}

// ── 辅助函数 ──

/// 校验 stash_id 格式，防止注入
fn validate_stash_id(stash_id: &str) -> Result<(), GitError> {
    // 允许 stash@{N} 或纯数字
    if stash_id.starts_with("stash@{") && stash_id.ends_with('}') {
        let inner = &stash_id[7..stash_id.len() - 1];
        if inner.chars().all(|c| c.is_ascii_digit()) {
            return Ok(());
        }
    }
    if stash_id.chars().all(|c| c.is_ascii_digit()) {
        return Ok(());
    }
    Err(GitError::CommandFailed(format!(
        "Invalid stash id: {}",
        stash_id
    )))
}

/// 标准化 stash_id 为 stash@{{N}} 格式
fn normalize_stash_id(stash_id: &str) -> String {
    if stash_id.starts_with("stash@{") {
        stash_id.to_string()
    } else {
        format!("stash@{{{}}}", stash_id)
    }
}

/// 检查 stash 是否包含未跟踪文件（第三个 parent）
fn has_untracked_parent(workspace_root: &Path, stash_ref: &str) -> bool {
    Command::new("git")
        .args(["rev-parse", "--verify", &format!("{}^3", stash_ref)])
        .current_dir(workspace_root)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// 从 stash show 获取文件数
fn get_stash_file_count(workspace_root: &Path, stash_ref: &str) -> usize {
    let output = Command::new("git")
        .args(["stash", "show", "--name-only", stash_ref])
        .current_dir(workspace_root)
        .output();

    let base_count = match &output {
        Ok(o) if o.status.success() => {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .filter(|l| !l.is_empty())
                .count()
        }
        _ => 0,
    };

    // 加上未跟踪文件数
    let untracked_count = if has_untracked_parent(workspace_root, stash_ref) {
        let ut_output = Command::new("git")
            .args([
                "diff-tree",
                "--no-commit-id",
                "--name-only",
                "-r",
                &format!("{}^3", stash_ref),
            ])
            .current_dir(workspace_root)
            .output();
        match ut_output {
            Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
                .lines()
                .filter(|l| !l.is_empty())
                .count(),
            _ => 0,
        }
    } else {
        0
    };

    base_count + untracked_count
}

/// 从 git stash message 中解析分支名
/// 格式通常为: "WIP on branch-name: sha message" 或 "On branch-name: user message"
fn parse_branch_from_message(message: &str) -> String {
    // 尝试匹配 "WIP on <branch>:" 或 "On <branch>:"
    let prefixes = ["WIP on ", "On "];
    for prefix in &prefixes {
        if let Some(rest) = message.strip_prefix(prefix) {
            if let Some(colon_pos) = rest.find(':') {
                return rest[..colon_pos].to_string();
            }
        }
    }
    String::new()
}

/// 从 stash message 中提取用户消息
fn parse_user_message(message: &str) -> String {
    // 格式: "WIP on branch: sha msg" 或 "On branch: user-message"
    if let Some(colon_pos) = message.find(':') {
        let after_colon = message[colon_pos + 1..].trim();
        // 如果 "WIP on" 开头, 消息格式为 "sha msg", 取第一个空格后的内容
        if message.starts_with("WIP on ") {
            if let Some(space_pos) = after_colon.find(' ') {
                return after_colon[space_pos + 1..].to_string();
            }
        }
        return after_colon.to_string();
    }
    message.to_string()
}

/// 获取 stash 中的未跟踪文件列表
fn get_untracked_files_in_stash(workspace_root: &Path, stash_ref: &str) -> Vec<String> {
    if !has_untracked_parent(workspace_root, stash_ref) {
        return vec![];
    }
    let output = Command::new("git")
        .args([
            "diff-tree",
            "--no-commit-id",
            "--name-only",
            "-r",
            &format!("{}^3", stash_ref),
        ])
        .current_dir(workspace_root)
        .output();
    match output {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
            .lines()
            .filter(|l| !l.is_empty())
            .map(|l| l.to_string())
            .collect(),
        _ => vec![],
    }
}

/// 从 apply/pop 的 stderr 中提取受影响的文件路径
fn parse_affected_paths(output_text: &str) -> Vec<String> {
    output_text
        .lines()
        .filter_map(|line| {
            // 典型输出格式: "M\tpath/to/file" 或 "  path/to/file"
            let trimmed = line.trim();
            if trimmed.is_empty() {
                return None;
            }
            // 跳过 "On branch ..." 等非文件行
            if trimmed.starts_with("On branch")
                || trimmed.starts_with("Changes ")
                || trimmed.starts_with("Untracked")
                || trimmed.starts_with("no changes")
                || trimmed.starts_with("Dropped")
                || trimmed.contains("CONFLICT")
            {
                return None;
            }
            // 尝试从 "modified:   path" 格式提取
            for prefix in &["modified:", "new file:", "deleted:", "renamed:"] {
                if let Some(rest) = trimmed.strip_prefix(prefix) {
                    return Some(rest.trim().to_string());
                }
            }
            None
        })
        .collect()
}

// ── 公开 API ──

/// 列出所有 stash 条目
pub fn git_stash_list(workspace_root: &Path) -> Result<StashListResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    // 使用可靠的 format 字符串：stash_id | ISO日期 | 消息
    let output = Command::new("git")
        .args(["stash", "list", "--format=%gd|%ai|%gs"])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(GitError::CommandFailed(if stderr.is_empty() {
            "git stash list failed".to_string()
        } else {
            stderr
        }));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut entries = Vec::new();

    for line in stdout.lines() {
        if line.is_empty() {
            continue;
        }

        // 解析 "stash@{0}|2024-01-01 12:00:00 +0800|WIP on main: abc1234 some message"
        let parts: Vec<&str> = line.splitn(3, '|').collect();
        if parts.len() < 3 {
            continue;
        }

        let stash_id = parts[0].to_string();
        let created_at = parts[1].trim().to_string();
        let full_message = parts[2].to_string();

        let branch_name = parse_branch_from_message(&full_message);
        let message = parse_user_message(&full_message);
        let file_count = get_stash_file_count(workspace_root, &stash_id);
        let includes_untracked = has_untracked_parent(workspace_root, &stash_id);

        // 获取完整的 stash title
        let title = format!("{}: {}", stash_id, full_message);

        entries.push(StashEntry {
            stash_id,
            title,
            message,
            branch_name,
            created_at,
            file_count,
            includes_untracked,
            includes_index: false, // 无法从消息中可靠检测
        });
    }

    Ok(StashListResult { entries })
}

/// 查看 stash 详情
pub fn git_stash_show(
    workspace_root: &Path,
    stash_id: &str,
) -> Result<StashShowResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }
    validate_stash_id(stash_id)?;
    let stash_ref = normalize_stash_id(stash_id);

    // 获取 stash 条目信息
    let list_output = Command::new("git")
        .args(["stash", "list", "--format=%gd|%ai|%gs"])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    let list_stdout = String::from_utf8_lossy(&list_output.stdout);
    let entry = list_stdout
        .lines()
        .find(|l| l.starts_with(&stash_ref))
        .map(|line| {
            let parts: Vec<&str> = line.splitn(3, '|').collect();
            if parts.len() >= 3 {
                let full_message = parts[2].to_string();
                StashEntry {
                    stash_id: stash_ref.clone(),
                    title: format!("{}: {}", stash_ref, full_message),
                    message: parse_user_message(&full_message),
                    branch_name: parse_branch_from_message(&full_message),
                    created_at: parts[1].trim().to_string(),
                    file_count: 0, // 会在下面更新
                    includes_untracked: has_untracked_parent(workspace_root, &stash_ref),
                    includes_index: false,
                }
            } else {
                StashEntry {
                    stash_id: stash_ref.clone(),
                    title: stash_ref.clone(),
                    message: String::new(),
                    branch_name: String::new(),
                    created_at: String::new(),
                    file_count: 0,
                    includes_untracked: false,
                    includes_index: false,
                }
            }
        })
        .unwrap_or_else(|| StashEntry {
            stash_id: stash_ref.clone(),
            title: stash_ref.clone(),
            message: String::new(),
            branch_name: String::new(),
            created_at: String::new(),
            file_count: 0,
            includes_untracked: false,
            includes_index: false,
        });

    // 获取 numstat 信息（tracked 文件）
    let numstat_output = Command::new("git")
        .args(["stash", "show", "--numstat", &stash_ref])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    let numstat_stdout = String::from_utf8_lossy(&numstat_output.stdout);
    let untracked_files = get_untracked_files_in_stash(workspace_root, &stash_ref);

    let mut files: Vec<StashFileEntry> = Vec::new();

    for line in numstat_stdout.lines() {
        if line.is_empty() {
            continue;
        }
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.len() < 3 {
            continue;
        }
        let additions = parts[0].parse::<i32>().unwrap_or(0);
        let deletions = parts[1].parse::<i32>().unwrap_or(0);
        let path = parts[2].to_string();

        // 推断状态
        let status = if additions > 0 && deletions == 0 {
            "A".to_string()
        } else if additions == 0 && deletions > 0 {
            "D".to_string()
        } else {
            "M".to_string()
        };

        files.push(StashFileEntry {
            path,
            status,
            additions,
            deletions,
            source_kind: "tracked".to_string(),
        });
    }

    // 添加未跟踪文件
    for ut_path in &untracked_files {
        files.push(StashFileEntry {
            path: ut_path.clone(),
            status: "A".to_string(),
            additions: 0,
            deletions: 0,
            source_kind: "untracked".to_string(),
        });
    }

    let file_count = files.len();

    // 获取 diff 文本
    let diff_output = Command::new("git")
        .args(["stash", "show", "-p", &stash_ref])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    let diff_text_raw = String::from_utf8_lossy(&diff_output.stdout);
    let (diff_text, is_binary_summary_truncated) = truncate_if_needed(&diff_text_raw);

    // 更新 entry 的 file_count
    let entry = StashEntry {
        file_count,
        ..entry
    };

    Ok(StashShowResult {
        entry,
        files,
        diff_text,
        is_binary_summary_truncated,
    })
}

/// 创建新的 stash
pub fn git_stash_save(
    workspace_root: &Path,
    message: Option<&str>,
    include_untracked: bool,
    keep_index: bool,
    paths: &[String],
) -> Result<StashOpResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    let mut args = vec!["stash", "push"];

    if let Some(msg) = message {
        args.push("-m");
        args.push(msg);
    }

    // 仅在无指定路径时应用全局标志
    if paths.is_empty() {
        if include_untracked {
            args.push("--include-untracked");
        }
        if keep_index {
            args.push("--keep-index");
        }
    }

    if !paths.is_empty() {
        args.push("--");
        for p in paths {
            validate_path(workspace_root, p)?;
        }
    }

    // 需要把 paths 转成 &str 切片追加
    let path_strs: Vec<&str> = paths.iter().map(|s| s.as_str()).collect();
    let mut full_args = args;
    full_args.extend(path_strs.iter());

    let output = Command::new("git")
        .args(&full_args)
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();

    if output.status.success() {
        // 检查是否为 noop（没有可 stash 的内容）
        if stderr.contains("No local changes to save") || stdout.contains("No local changes") {
            return Ok(StashOpResult {
                op: "save".to_string(),
                stash_id: String::new(),
                ok: true,
                state: StashOpState::Noop,
                message: Some("No local changes to save".to_string()),
                affected_paths: vec![],
                conflict_files: vec![],
            });
        }

        invalidate_git_status_cache(workspace_root);

        Ok(StashOpResult {
            op: "save".to_string(),
            stash_id: "stash@{0}".to_string(), // 新 stash 总是在位置 0
            ok: true,
            state: StashOpState::Completed,
            message: message.map(|m| m.to_string()),
            affected_paths: vec![],
            conflict_files: vec![],
        })
    } else {
        // "No local changes to save" 在非零退出码时也可能出现
        if stderr.contains("No local changes to save") {
            return Ok(StashOpResult {
                op: "save".to_string(),
                stash_id: String::new(),
                ok: true,
                state: StashOpState::Noop,
                message: Some("No local changes to save".to_string()),
                affected_paths: vec![],
                conflict_files: vec![],
            });
        }

        Ok(StashOpResult {
            op: "save".to_string(),
            stash_id: String::new(),
            ok: false,
            state: StashOpState::Failed,
            message: Some(if stderr.is_empty() {
                "Stash save failed".to_string()
            } else {
                stderr
            }),
            affected_paths: vec![],
            conflict_files: vec![],
        })
    }
}

/// 应用 stash（保留 stash 条目）
pub fn git_stash_apply(
    workspace_root: &Path,
    stash_id: &str,
) -> Result<StashOpResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }
    validate_stash_id(stash_id)?;
    let stash_ref = normalize_stash_id(stash_id);

    let output = Command::new("git")
        .args(["stash", "apply", &stash_ref])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();

    invalidate_git_status_cache(workspace_root);

    if output.status.success() {
        let affected = parse_affected_paths(&stdout);
        Ok(StashOpResult {
            op: "apply".to_string(),
            stash_id: stash_ref,
            ok: true,
            state: StashOpState::Completed,
            message: None,
            affected_paths: affected,
            conflict_files: vec![],
        })
    } else {
        // 检查是否是冲突
        let conflict_files = get_conflict_file_entries(workspace_root);
        if !conflict_files.is_empty() || stderr.contains("CONFLICT") || stderr.contains("conflict")
        {
            Ok(StashOpResult {
                op: "apply".to_string(),
                stash_id: stash_ref,
                ok: false,
                state: StashOpState::Conflict,
                message: Some(stderr),
                affected_paths: vec![],
                conflict_files,
            })
        } else {
            Ok(StashOpResult {
                op: "apply".to_string(),
                stash_id: stash_ref,
                ok: false,
                state: StashOpState::Failed,
                message: Some(if stderr.is_empty() {
                    "Stash apply failed".to_string()
                } else {
                    stderr
                }),
                affected_paths: vec![],
                conflict_files: vec![],
            })
        }
    }
}

/// 弹出 stash（成功时删除条目，冲突时保留）
pub fn git_stash_pop(
    workspace_root: &Path,
    stash_id: &str,
) -> Result<StashOpResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }
    validate_stash_id(stash_id)?;
    let stash_ref = normalize_stash_id(stash_id);

    // 先 apply
    let apply_result = git_stash_apply(workspace_root, stash_id)?;

    if apply_result.state == StashOpState::Completed {
        // apply 成功后再 drop
        let drop_output = Command::new("git")
            .args(["stash", "drop", &stash_ref])
            .current_dir(workspace_root)
            .output()
            .map_err(GitError::IoError)?;

        if drop_output.status.success() {
            Ok(StashOpResult {
                op: "pop".to_string(),
                stash_id: stash_ref,
                ok: true,
                state: StashOpState::Completed,
                message: apply_result.message,
                affected_paths: apply_result.affected_paths,
                conflict_files: vec![],
            })
        } else {
            // drop 失败但 apply 已成功
            let stderr = String::from_utf8_lossy(&drop_output.stderr)
                .trim()
                .to_string();
            Ok(StashOpResult {
                op: "pop".to_string(),
                stash_id: stash_ref,
                ok: true,
                state: StashOpState::Completed,
                message: Some(format!(
                    "Applied successfully but failed to drop stash: {}",
                    stderr
                )),
                affected_paths: apply_result.affected_paths,
                conflict_files: vec![],
            })
        }
    } else {
        // apply 失败（冲突或其他原因），保留 stash
        Ok(StashOpResult {
            op: "pop".to_string(),
            ..apply_result
        })
    }
}

/// 删除 stash 条目
pub fn git_stash_drop(
    workspace_root: &Path,
    stash_id: &str,
) -> Result<StashOpResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }
    validate_stash_id(stash_id)?;
    let stash_ref = normalize_stash_id(stash_id);

    let output = Command::new("git")
        .args(["stash", "drop", &stash_ref])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    invalidate_git_status_cache(workspace_root);

    if output.status.success() {
        Ok(StashOpResult {
            op: "drop".to_string(),
            stash_id: stash_ref,
            ok: true,
            state: StashOpState::Completed,
            message: None,
            affected_paths: vec![],
            conflict_files: vec![],
        })
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Ok(StashOpResult {
            op: "drop".to_string(),
            stash_id: stash_ref,
            ok: false,
            state: StashOpState::Failed,
            message: Some(if stderr.is_empty() {
                "Stash drop failed".to_string()
            } else {
                stderr
            }),
            affected_paths: vec![],
            conflict_files: vec![],
        })
    }
}

/// 从 stash 恢复特定文件
pub fn git_stash_restore_paths(
    workspace_root: &Path,
    stash_id: &str,
    paths: &[String],
) -> Result<StashOpResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }
    validate_stash_id(stash_id)?;
    let stash_ref = normalize_stash_id(stash_id);

    if paths.is_empty() {
        return Ok(StashOpResult {
            op: "restore_paths".to_string(),
            stash_id: stash_ref,
            ok: true,
            state: StashOpState::Noop,
            message: Some("No paths specified".to_string()),
            affected_paths: vec![],
            conflict_files: vec![],
        });
    }

    // 获取 stash 中的未跟踪文件列表
    let untracked_files = get_untracked_files_in_stash(workspace_root, &stash_ref);
    let mut restored_paths = Vec::new();
    let mut errors = Vec::new();

    for path in paths {
        validate_path(workspace_root, path)?;

        if untracked_files.contains(path) {
            // 未跟踪文件：用 git show 从第三个 parent 提取
            let show_output = Command::new("git")
                .args(["show", &format!("{}^3:{}", stash_ref, path)])
                .current_dir(workspace_root)
                .output()
                .map_err(GitError::IoError)?;

            if show_output.status.success() {
                let full_path = workspace_root.join(path);
                // 确保父目录存在
                if let Some(parent) = full_path.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                if let Err(e) = std::fs::write(&full_path, &show_output.stdout) {
                    errors.push(format!("{}: {}", path, e));
                } else {
                    restored_paths.push(path.clone());
                }
            } else {
                let stderr = String::from_utf8_lossy(&show_output.stderr)
                    .trim()
                    .to_string();
                errors.push(format!("{}: {}", path, stderr));
            }
        } else {
            // tracked 文件：使用 git checkout
            let checkout_output = Command::new("git")
                .args(["checkout", &stash_ref, "--", path])
                .current_dir(workspace_root)
                .output()
                .map_err(GitError::IoError)?;

            if checkout_output.status.success() {
                restored_paths.push(path.clone());
            } else {
                let stderr = String::from_utf8_lossy(&checkout_output.stderr)
                    .trim()
                    .to_string();
                errors.push(format!("{}: {}", path, stderr));
            }
        }
    }

    invalidate_git_status_cache(workspace_root);

    // 检查冲突
    let conflict_files = get_conflict_file_entries(workspace_root);

    let (ok, state) = if !conflict_files.is_empty() {
        (false, StashOpState::Conflict)
    } else if !errors.is_empty() {
        (false, StashOpState::Failed)
    } else {
        (true, StashOpState::Completed)
    };

    let message = if !errors.is_empty() {
        Some(errors.join("; "))
    } else {
        None
    };

    Ok(StashOpResult {
        op: "restore_paths".to_string(),
        stash_id: stash_ref,
        ok,
        state,
        message,
        affected_paths: restored_paths,
        conflict_files,
    })
}
