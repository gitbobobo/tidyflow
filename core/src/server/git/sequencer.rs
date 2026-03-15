//! Workspace 级 sequencer 操作：cherry-pick、revert、回滚
//!
//! 所有操作均面向 workspace 级工作区，不涉及 integration worktree。

use std::collections::HashMap;
use std::path::Path;
use std::process::Command;
use std::sync::Mutex;

use super::status::invalidate_git_status_cache;
use super::utils::*;

// ============================================================================
// 类型定义
// ============================================================================

/// Workspace 操作类型
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum WorkspaceOperationKind {
    CherryPick,
    Revert,
}

impl WorkspaceOperationKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            WorkspaceOperationKind::CherryPick => "cherry_pick",
            WorkspaceOperationKind::Revert => "revert",
        }
    }
}

/// Sequencer 操作结果
#[derive(Debug)]
pub struct SequencerResult {
    pub operation_kind: WorkspaceOperationKind,
    pub ok: bool,
    /// completed | conflict | aborted | error
    pub state: String,
    pub message: Option<String>,
    pub conflicts: Vec<String>,
    pub conflict_files: Vec<ConflictFileEntry>,
    pub completed_count: usize,
    pub pending_count: usize,
    pub current_commit: Option<String>,
}

/// 回滚收据（workspace 级）
#[derive(Debug, Clone)]
pub struct RollbackReceipt {
    pub operation_kind: WorkspaceOperationKind,
    pub original_head: String,
    pub result_head: String,
    pub commit_shas: Vec<String>,
    pub created_at: String,
}

/// 回滚操作结果
#[derive(Debug)]
pub struct RollbackResult {
    pub ok: bool,
    pub message: Option<String>,
}

// ============================================================================
// 回滚收据存储（workspace 级，内存缓存）
// ============================================================================

static ROLLBACK_RECEIPTS: Mutex<Option<HashMap<(String, String), RollbackReceipt>>> =
    Mutex::new(None);

fn with_receipts<F, R>(f: F) -> R
where
    F: FnOnce(&mut HashMap<(String, String), RollbackReceipt>) -> R,
{
    let mut guard = ROLLBACK_RECEIPTS.lock().expect("lock rollback receipts");
    let map = guard.get_or_insert_with(HashMap::new);
    f(map)
}

/// 保存回滚收据
pub fn save_rollback_receipt(project: &str, workspace: &str, receipt: RollbackReceipt) {
    with_receipts(|map| {
        map.insert((project.to_string(), workspace.to_string()), receipt);
    });
}

/// 读取回滚收据（不消耗）
pub fn get_rollback_receipt(project: &str, workspace: &str) -> Option<RollbackReceipt> {
    with_receipts(|map| {
        map.get(&(project.to_string(), workspace.to_string())).cloned()
    })
}

/// 清除回滚收据
pub fn clear_rollback_receipt(project: &str, workspace: &str) {
    with_receipts(|map| {
        map.remove(&(project.to_string(), workspace.to_string()));
    });
}

// ============================================================================
// Cherry-pick
// ============================================================================

/// 启动 cherry-pick（支持多提交，按 commit_shas 给定顺序执行）
pub fn git_cherry_pick(
    workspace_root: &Path,
    commit_shas: &[String],
) -> Result<SequencerResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    if commit_shas.is_empty() {
        return Ok(SequencerResult {
            operation_kind: WorkspaceOperationKind::CherryPick,
            ok: false,
            state: "error".to_string(),
            message: Some("No commits specified".to_string()),
            conflicts: vec![],
            conflict_files: vec![],
            completed_count: 0,
            pending_count: 0,
            current_commit: None,
        });
    }

    // 拒绝与现有 sequencer 操作并发
    if is_rebasing(workspace_root)
        || is_merging(workspace_root)
        || is_cherry_picking(workspace_root)
        || is_reverting(workspace_root)
    {
        return Ok(SequencerResult {
            operation_kind: WorkspaceOperationKind::CherryPick,
            ok: false,
            state: "error".to_string(),
            message: Some(
                "Another git operation is in progress. Abort or complete it first.".to_string(),
            ),
            conflicts: vec![],
            conflict_files: vec![],
            completed_count: 0,
            pending_count: commit_shas.len(),
            current_commit: None,
        });
    }

    let mut args = vec!["cherry-pick".to_string()];
    args.extend(commit_shas.iter().cloned());

    let output = Command::new("git")
        .args(&args)
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    invalidate_git_status_cache(workspace_root);

    if output.status.success() {
        Ok(SequencerResult {
            operation_kind: WorkspaceOperationKind::CherryPick,
            ok: true,
            state: "completed".to_string(),
            message: Some(format!("Cherry-picked {} commit(s)", commit_shas.len())),
            conflicts: vec![],
            conflict_files: vec![],
            completed_count: commit_shas.len(),
            pending_count: 0,
            current_commit: None,
        })
    } else if is_cherry_picking(workspace_root) {
        let conflicts = get_conflict_files(workspace_root);
        let conflict_files = get_conflict_file_entries(workspace_root);
        let (completed, pending, current) =
            read_sequencer_progress(workspace_root, commit_shas.len());
        Ok(SequencerResult {
            operation_kind: WorkspaceOperationKind::CherryPick,
            ok: false,
            state: "conflict".to_string(),
            message: Some("Cherry-pick paused due to conflicts".to_string()),
            conflicts,
            conflict_files,
            completed_count: completed,
            pending_count: pending,
            current_commit: current,
        })
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Ok(SequencerResult {
            operation_kind: WorkspaceOperationKind::CherryPick,
            ok: false,
            state: "error".to_string(),
            message: Some(if stderr.is_empty() {
                "Cherry-pick failed".to_string()
            } else {
                stderr
            }),
            conflicts: vec![],
            conflict_files: vec![],
            completed_count: 0,
            pending_count: commit_shas.len(),
            current_commit: None,
        })
    }
}

/// 继续 cherry-pick
pub fn git_cherry_pick_continue(workspace_root: &Path) -> Result<SequencerResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    if !is_cherry_picking(workspace_root) {
        return Ok(SequencerResult {
            operation_kind: WorkspaceOperationKind::CherryPick,
            ok: false,
            state: "error".to_string(),
            message: Some("No cherry-pick in progress".to_string()),
            conflicts: vec![],
            conflict_files: vec![],
            completed_count: 0,
            pending_count: 0,
            current_commit: None,
        });
    }

    let output = Command::new("git")
        .args(["cherry-pick", "--continue"])
        .current_dir(workspace_root)
        .env("GIT_EDITOR", "true")
        .output()
        .map_err(GitError::IoError)?;

    invalidate_git_status_cache(workspace_root);

    if output.status.success() {
        if is_cherry_picking(workspace_root) {
            // sequencer 还有后续提交需处理
            let conflicts = get_conflict_files(workspace_root);
            if conflicts.is_empty() {
                Ok(SequencerResult {
                    operation_kind: WorkspaceOperationKind::CherryPick,
                    ok: true,
                    state: "completed".to_string(),
                    message: Some("Cherry-pick completed".to_string()),
                    conflicts: vec![],
                    conflict_files: vec![],
                    completed_count: 0,
                    pending_count: 0,
                    current_commit: None,
                })
            } else {
                let conflict_files = get_conflict_file_entries(workspace_root);
                Ok(SequencerResult {
                    operation_kind: WorkspaceOperationKind::CherryPick,
                    ok: false,
                    state: "conflict".to_string(),
                    message: Some("More conflicts to resolve".to_string()),
                    conflicts,
                    conflict_files,
                    completed_count: 0,
                    pending_count: 0,
                    current_commit: None,
                })
            }
        } else {
            Ok(SequencerResult {
                operation_kind: WorkspaceOperationKind::CherryPick,
                ok: true,
                state: "completed".to_string(),
                message: Some("Cherry-pick completed".to_string()),
                conflicts: vec![],
                conflict_files: vec![],
                completed_count: 0,
                pending_count: 0,
                current_commit: None,
            })
        }
    } else {
        let conflicts = get_conflict_files(workspace_root);
        if !conflicts.is_empty() {
            let conflict_files = get_conflict_file_entries(workspace_root);
            Ok(SequencerResult {
                operation_kind: WorkspaceOperationKind::CherryPick,
                ok: false,
                state: "conflict".to_string(),
                message: Some(
                    "Conflicts remain. Resolve and stage files before continuing.".to_string(),
                ),
                conflicts,
                conflict_files,
                completed_count: 0,
                pending_count: 0,
                current_commit: None,
            })
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            Ok(SequencerResult {
                operation_kind: WorkspaceOperationKind::CherryPick,
                ok: false,
                state: "error".to_string(),
                message: Some(if stderr.is_empty() {
                    "Continue failed".to_string()
                } else {
                    stderr
                }),
                conflicts: vec![],
                conflict_files: vec![],
                completed_count: 0,
                pending_count: 0,
                current_commit: None,
            })
        }
    }
}

/// 中止 cherry-pick
pub fn git_cherry_pick_abort(workspace_root: &Path) -> Result<SequencerResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    if !is_cherry_picking(workspace_root) {
        return Ok(SequencerResult {
            operation_kind: WorkspaceOperationKind::CherryPick,
            ok: false,
            state: "error".to_string(),
            message: Some("No cherry-pick in progress".to_string()),
            conflicts: vec![],
            conflict_files: vec![],
            completed_count: 0,
            pending_count: 0,
            current_commit: None,
        });
    }

    let output = Command::new("git")
        .args(["cherry-pick", "--abort"])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    invalidate_git_status_cache(workspace_root);

    if output.status.success() {
        Ok(SequencerResult {
            operation_kind: WorkspaceOperationKind::CherryPick,
            ok: true,
            state: "aborted".to_string(),
            message: Some("Cherry-pick aborted".to_string()),
            conflicts: vec![],
            conflict_files: vec![],
            completed_count: 0,
            pending_count: 0,
            current_commit: None,
        })
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Ok(SequencerResult {
            operation_kind: WorkspaceOperationKind::CherryPick,
            ok: false,
            state: "error".to_string(),
            message: Some(if stderr.is_empty() {
                "Abort failed".to_string()
            } else {
                stderr
            }),
            conflicts: vec![],
            conflict_files: vec![],
            completed_count: 0,
            pending_count: 0,
            current_commit: None,
        })
    }
}

// ============================================================================
// Revert
// ============================================================================

/// 启动 revert（支持多提交，按 commit_shas 给定顺序执行）
pub fn git_revert(
    workspace_root: &Path,
    commit_shas: &[String],
) -> Result<SequencerResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    if commit_shas.is_empty() {
        return Ok(SequencerResult {
            operation_kind: WorkspaceOperationKind::Revert,
            ok: false,
            state: "error".to_string(),
            message: Some("No commits specified".to_string()),
            conflicts: vec![],
            conflict_files: vec![],
            completed_count: 0,
            pending_count: 0,
            current_commit: None,
        });
    }

    if is_rebasing(workspace_root)
        || is_merging(workspace_root)
        || is_cherry_picking(workspace_root)
        || is_reverting(workspace_root)
    {
        return Ok(SequencerResult {
            operation_kind: WorkspaceOperationKind::Revert,
            ok: false,
            state: "error".to_string(),
            message: Some(
                "Another git operation is in progress. Abort or complete it first.".to_string(),
            ),
            conflicts: vec![],
            conflict_files: vec![],
            completed_count: 0,
            pending_count: commit_shas.len(),
            current_commit: None,
        });
    }

    let mut args = vec!["revert".to_string(), "--no-edit".to_string()];
    args.extend(commit_shas.iter().cloned());

    let output = Command::new("git")
        .args(&args)
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    invalidate_git_status_cache(workspace_root);

    if output.status.success() {
        Ok(SequencerResult {
            operation_kind: WorkspaceOperationKind::Revert,
            ok: true,
            state: "completed".to_string(),
            message: Some(format!("Reverted {} commit(s)", commit_shas.len())),
            conflicts: vec![],
            conflict_files: vec![],
            completed_count: commit_shas.len(),
            pending_count: 0,
            current_commit: None,
        })
    } else if is_reverting(workspace_root) {
        let conflicts = get_conflict_files(workspace_root);
        let conflict_files = get_conflict_file_entries(workspace_root);
        let (completed, pending, current) =
            read_sequencer_progress(workspace_root, commit_shas.len());
        Ok(SequencerResult {
            operation_kind: WorkspaceOperationKind::Revert,
            ok: false,
            state: "conflict".to_string(),
            message: Some("Revert paused due to conflicts".to_string()),
            conflicts,
            conflict_files,
            completed_count: completed,
            pending_count: pending,
            current_commit: current,
        })
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Ok(SequencerResult {
            operation_kind: WorkspaceOperationKind::Revert,
            ok: false,
            state: "error".to_string(),
            message: Some(if stderr.is_empty() {
                "Revert failed".to_string()
            } else {
                stderr
            }),
            conflicts: vec![],
            conflict_files: vec![],
            completed_count: 0,
            pending_count: commit_shas.len(),
            current_commit: None,
        })
    }
}

/// 继续 revert
pub fn git_revert_continue(workspace_root: &Path) -> Result<SequencerResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    if !is_reverting(workspace_root) {
        return Ok(SequencerResult {
            operation_kind: WorkspaceOperationKind::Revert,
            ok: false,
            state: "error".to_string(),
            message: Some("No revert in progress".to_string()),
            conflicts: vec![],
            conflict_files: vec![],
            completed_count: 0,
            pending_count: 0,
            current_commit: None,
        });
    }

    let output = Command::new("git")
        .args(["revert", "--continue"])
        .current_dir(workspace_root)
        .env("GIT_EDITOR", "true")
        .output()
        .map_err(GitError::IoError)?;

    invalidate_git_status_cache(workspace_root);

    if output.status.success() {
        if is_reverting(workspace_root) {
            let conflicts = get_conflict_files(workspace_root);
            if conflicts.is_empty() {
                Ok(SequencerResult {
                    operation_kind: WorkspaceOperationKind::Revert,
                    ok: true,
                    state: "completed".to_string(),
                    message: Some("Revert completed".to_string()),
                    conflicts: vec![],
                    conflict_files: vec![],
                    completed_count: 0,
                    pending_count: 0,
                    current_commit: None,
                })
            } else {
                let conflict_files = get_conflict_file_entries(workspace_root);
                Ok(SequencerResult {
                    operation_kind: WorkspaceOperationKind::Revert,
                    ok: false,
                    state: "conflict".to_string(),
                    message: Some("More conflicts to resolve".to_string()),
                    conflicts,
                    conflict_files,
                    completed_count: 0,
                    pending_count: 0,
                    current_commit: None,
                })
            }
        } else {
            Ok(SequencerResult {
                operation_kind: WorkspaceOperationKind::Revert,
                ok: true,
                state: "completed".to_string(),
                message: Some("Revert completed".to_string()),
                conflicts: vec![],
                conflict_files: vec![],
                completed_count: 0,
                pending_count: 0,
                current_commit: None,
            })
        }
    } else {
        let conflicts = get_conflict_files(workspace_root);
        if !conflicts.is_empty() {
            let conflict_files = get_conflict_file_entries(workspace_root);
            Ok(SequencerResult {
                operation_kind: WorkspaceOperationKind::Revert,
                ok: false,
                state: "conflict".to_string(),
                message: Some(
                    "Conflicts remain. Resolve and stage files before continuing.".to_string(),
                ),
                conflicts,
                conflict_files,
                completed_count: 0,
                pending_count: 0,
                current_commit: None,
            })
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            Ok(SequencerResult {
                operation_kind: WorkspaceOperationKind::Revert,
                ok: false,
                state: "error".to_string(),
                message: Some(if stderr.is_empty() {
                    "Continue failed".to_string()
                } else {
                    stderr
                }),
                conflicts: vec![],
                conflict_files: vec![],
                completed_count: 0,
                pending_count: 0,
                current_commit: None,
            })
        }
    }
}

/// 中止 revert
pub fn git_revert_abort(workspace_root: &Path) -> Result<SequencerResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    if !is_reverting(workspace_root) {
        return Ok(SequencerResult {
            operation_kind: WorkspaceOperationKind::Revert,
            ok: false,
            state: "error".to_string(),
            message: Some("No revert in progress".to_string()),
            conflicts: vec![],
            conflict_files: vec![],
            completed_count: 0,
            pending_count: 0,
            current_commit: None,
        });
    }

    let output = Command::new("git")
        .args(["revert", "--abort"])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    invalidate_git_status_cache(workspace_root);

    if output.status.success() {
        Ok(SequencerResult {
            operation_kind: WorkspaceOperationKind::Revert,
            ok: true,
            state: "aborted".to_string(),
            message: Some("Revert aborted".to_string()),
            conflicts: vec![],
            conflict_files: vec![],
            completed_count: 0,
            pending_count: 0,
            current_commit: None,
        })
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Ok(SequencerResult {
            operation_kind: WorkspaceOperationKind::Revert,
            ok: false,
            state: "error".to_string(),
            message: Some(if stderr.is_empty() {
                "Abort failed".to_string()
            } else {
                stderr
            }),
            conflicts: vec![],
            conflict_files: vec![],
            completed_count: 0,
            pending_count: 0,
            current_commit: None,
        })
    }
}

// ============================================================================
// 回滚
// ============================================================================

/// 回滚最近一次成功的 cherry-pick/revert 批次
pub fn git_workspace_op_rollback(
    workspace_root: &Path,
    project: &str,
    workspace: &str,
) -> Result<RollbackResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    let receipt = match get_rollback_receipt(project, workspace) {
        Some(r) => r,
        None => {
            return Ok(RollbackResult {
                ok: false,
                message: Some("No rollback receipt available".to_string()),
            })
        }
    };

    // 门禁 1: 工作区必须 clean
    if !is_workspace_clean(workspace_root) {
        return Ok(RollbackResult {
            ok: false,
            message: Some("Cannot rollback: workspace has uncommitted changes".to_string()),
        });
    }

    // 门禁 2: HEAD 必须等于 result_head
    let current_head = get_full_head_sha(workspace_root).unwrap_or_default();
    if current_head != receipt.result_head {
        return Ok(RollbackResult {
            ok: false,
            message: Some("Cannot rollback: HEAD has moved since the operation".to_string()),
        });
    }

    // 执行回滚：git reset --hard <original_head>
    let output = Command::new("git")
        .args(["reset", "--hard", &receipt.original_head])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    invalidate_git_status_cache(workspace_root);

    if output.status.success() {
        clear_rollback_receipt(project, workspace);
        Ok(RollbackResult {
            ok: true,
            message: Some(format!(
                "Rolled back {} of {} commit(s)",
                receipt.operation_kind.as_str(),
                receipt.commit_shas.len()
            )),
        })
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Ok(RollbackResult {
            ok: false,
            message: Some(if stderr.is_empty() {
                "Rollback failed".to_string()
            } else {
                stderr
            }),
        })
    }
}

// ============================================================================
// 状态检测辅助
// ============================================================================

/// 检测是否处于 cherry-pick 状态
pub fn is_cherry_picking(workspace_root: &Path) -> bool {
    gix::discover(workspace_root)
        .ok()
        .map(|repo| repo.git_dir().join("CHERRY_PICK_HEAD").exists())
        .unwrap_or(false)
}

/// 检测是否处于 revert 状态
pub fn is_reverting(workspace_root: &Path) -> bool {
    gix::discover(workspace_root)
        .ok()
        .map(|repo| repo.git_dir().join("REVERT_HEAD").exists())
        .unwrap_or(false)
}

/// 获取完整 HEAD SHA
pub fn get_full_head_sha(workspace_root: &Path) -> Option<String> {
    let repo = gix::discover(workspace_root).ok()?;
    let id = repo.head_id().ok()?;
    Some(id.to_string())
}

/// 检测工作区是否 clean（没有未提交变更）
fn is_workspace_clean(workspace_root: &Path) -> bool {
    let output = Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(workspace_root)
        .output();
    match output {
        Ok(out) => out.status.success() && out.stdout.is_empty(),
        Err(_) => false,
    }
}

/// 读取 sequencer 进度（从 .git/sequencer/todo 文件）
fn read_sequencer_progress(
    workspace_root: &Path,
    total: usize,
) -> (usize, usize, Option<String>) {
    let repo = match gix::discover(workspace_root) {
        Ok(r) => r,
        Err(_) => return (0, total, None),
    };

    let todo_path = repo.git_dir().join("sequencer").join("todo");
    if let Ok(content) = std::fs::read_to_string(&todo_path) {
        let remaining: Vec<&str> = content
            .lines()
            .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
            .collect();
        let pending = remaining.len();
        let completed = total.saturating_sub(pending);
        let current = remaining
            .first()
            .and_then(|line| line.split_whitespace().nth(1))
            .map(|s| s.to_string());
        (completed, pending, current)
    } else {
        // 单提交操作或 sequencer 文件不存在
        (0, 0, None)
    }
}

/// 读取 sequencer 待处理提交列表（供 op-status 使用）
pub fn read_sequencer_pending_commits(workspace_root: &Path) -> Vec<String> {
    let repo = match gix::discover(workspace_root) {
        Ok(r) => r,
        Err(_) => return vec![],
    };

    let todo_path = repo.git_dir().join("sequencer").join("todo");
    if let Ok(content) = std::fs::read_to_string(&todo_path) {
        content
            .lines()
            .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
            .filter_map(|line| line.split_whitespace().nth(1).map(|s| s.to_string()))
            .collect()
    } else {
        vec![]
    }
}

/// 读取当前正在处理的提交 SHA（CHERRY_PICK_HEAD 或 REVERT_HEAD）
pub fn read_current_sequencer_commit(workspace_root: &Path) -> Option<String> {
    let repo = gix::discover(workspace_root).ok()?;
    let git_dir = repo.git_dir();

    for head_file in &["CHERRY_PICK_HEAD", "REVERT_HEAD"] {
        let path = git_dir.join(head_file);
        if let Ok(content) = std::fs::read_to_string(&path) {
            let sha = content.trim().to_string();
            if !sha.is_empty() {
                return Some(sha);
            }
        }
    }
    None
}
