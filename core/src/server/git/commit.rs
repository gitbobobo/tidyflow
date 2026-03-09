//! Git commit and rebase operations
//!
//! Provides functions for committing, fetching, and rebasing.

use std::path::Path;
use std::process::Command;

use super::status::invalidate_git_status_cache;
use super::utils::*;

/// Commit staged changes
///
/// Uses `git commit -m <message>` to create a commit.
/// Returns the short SHA of the new commit on success.
pub fn git_commit(workspace_root: &Path, message: &str) -> Result<GitCommitResult, GitError> {
    // Check if it's a git repo
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    // Validate message is not empty
    let trimmed_message = message.trim();
    if trimmed_message.is_empty() {
        return Ok(GitCommitResult {
            ok: false,
            message: Some("Commit message cannot be empty".to_string()),
            sha: None,
        });
    }

    // Check if there are staged changes
    let (has_staged, _) = check_staged_changes(workspace_root);
    if !has_staged {
        return Ok(GitCommitResult {
            ok: false,
            message: Some("No staged changes to commit".to_string()),
            sha: None,
        });
    }

    // Run git commit
    let output = Command::new("git")
        .args(["commit", "-m", trimmed_message])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if output.status.success() {
        invalidate_git_status_cache(workspace_root);
        // Get the short SHA of the new commit
        let sha = get_short_head_sha(workspace_root);
        Ok(GitCommitResult {
            ok: true,
            message: Some(format!(
                "Committed: {}",
                sha.as_deref().unwrap_or("unknown")
            )),
            sha,
        })
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        // Check for common errors and provide helpful messages
        let error_msg = if stderr.contains("user.name") || stderr.contains("user.email") {
            "Git identity not configured. Run: git config user.name \"Your Name\" && git config user.email \"you@example.com\"".to_string()
        } else if stderr.contains("pre-commit") || stderr.contains("hook") {
            format!("Pre-commit hook failed: {}", stderr)
        } else if stderr.is_empty() {
            "Commit failed".to_string()
        } else {
            stderr
        };

        Ok(GitCommitResult {
            ok: false,
            message: Some(error_msg),
            sha: None,
        })
    }
}

/// Check if there are staged changes
///
/// Uses `git diff --cached --name-only` to list staged files.
fn check_staged_changes(workspace_root: &Path) -> (bool, usize) {
    let output = Command::new("git")
        .args(["diff", "--cached", "--name-only"])
        .current_dir(workspace_root)
        .output();

    match output {
        Ok(out) if out.status.success() => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let count = stdout.lines().filter(|l| !l.is_empty()).count();
            (count > 0, count)
        }
        _ => (false, 0),
    }
}

/// Fetch from remote
///
/// Uses `git fetch` to update remote tracking branches.
pub fn git_fetch(workspace_root: &Path) -> Result<GitOpResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    let output = Command::new("git")
        .args(["fetch"])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if output.status.success() {
        Ok(GitOpResult {
            op: "fetch".to_string(),
            ok: true,
            message: Some("Fetched from remote".to_string()),
            path: None,
            scope: "all".to_string(),
        })
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Ok(GitOpResult {
            op: "fetch".to_string(),
            ok: false,
            message: Some(if stderr.is_empty() {
                "Fetch failed".to_string()
            } else {
                stderr
            }),
            path: None,
            scope: "all".to_string(),
        })
    }
}

/// Get current git operation state
pub fn git_op_status(workspace_root: &Path) -> Result<GitOpStatusResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    let state = if is_rebasing(workspace_root) {
        GitOpState::Rebasing
    } else if is_merging(workspace_root) {
        GitOpState::Merging
    } else {
        GitOpState::Normal
    };

    let conflicts = if state != GitOpState::Normal {
        get_conflict_files(workspace_root)
    } else {
        vec![]
    };

    let conflict_files = if state != GitOpState::Normal {
        get_conflict_file_entries(workspace_root)
    } else {
        vec![]
    };

    let head = get_short_head_sha(workspace_root);

    // Get onto branch for rebase
    let onto = if state == GitOpState::Rebasing {
        // Try to read the onto ref
        let output = Command::new("git")
            .args(["rev-parse", "--git-path", "rebase-merge/onto"])
            .current_dir(workspace_root)
            .output();

        if let Ok(out) = output {
            let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !path.is_empty() {
                std::fs::read_to_string(&path)
                    .ok()
                    .map(|s| s.trim().to_string())
            } else {
                None
            }
        } else {
            None
        }
    } else {
        None
    };

    Ok(GitOpStatusResult {
        state,
        conflicts,
        conflict_files,
        head,
        onto,
    })
}

/// Rebase current branch onto another branch
///
/// Uses `git rebase <onto_branch>`. Returns conflict info if rebase pauses.
pub fn git_rebase(workspace_root: &Path, onto_branch: &str) -> Result<GitRebaseResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    // Check if already in a rebase
    if is_rebasing(workspace_root) {
        let conflicts = get_conflict_files(workspace_root);
        let conflict_files = get_conflict_file_entries(workspace_root);
        return Ok(GitRebaseResult {
            ok: false,
            state: "error".to_string(),
            message: Some("Already in a rebase. Use continue or abort.".to_string()),
            conflicts,
            conflict_files,
        });
    }

    let output = Command::new("git")
        .args(["rebase", onto_branch])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if output.status.success() {
        Ok(GitRebaseResult {
            ok: true,
            state: "completed".to_string(),
            message: Some(format!("Rebased onto {}", onto_branch)),
            conflicts: vec![],
            conflict_files: vec![],
        })
    } else {
        // Check if we're now in a conflict state
        if is_rebasing(workspace_root) {
            let conflicts = get_conflict_files(workspace_root);
            let conflict_files = get_conflict_file_entries(workspace_root);
            Ok(GitRebaseResult {
                ok: false,
                state: "conflict".to_string(),
                message: Some("Rebase paused due to conflicts".to_string()),
                conflicts,
                conflict_files,
            })
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            Ok(GitRebaseResult {
                ok: false,
                state: "error".to_string(),
                message: Some(if stderr.is_empty() {
                    "Rebase failed".to_string()
                } else {
                    stderr
                }),
                conflicts: vec![],
                conflict_files: vec![],
            })
        }
    }
}

/// Continue a paused rebase
pub fn git_rebase_continue(workspace_root: &Path) -> Result<GitRebaseResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    if !is_rebasing(workspace_root) {
        return Ok(GitRebaseResult {
            ok: false,
            state: "error".to_string(),
            message: Some("No rebase in progress".to_string()),
            conflicts: vec![],
            conflict_files: vec![],
        });
    }

    let output = Command::new("git")
        .args(["rebase", "--continue"])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if output.status.success() {
        // Check if rebase is complete
        if is_rebasing(workspace_root) {
            // Still rebasing, might have more conflicts
            let conflicts = get_conflict_files(workspace_root);
            if conflicts.is_empty() {
                Ok(GitRebaseResult {
                    ok: true,
                    state: "completed".to_string(),
                    message: Some("Rebase completed".to_string()),
                    conflicts: vec![],
                    conflict_files: vec![],
                })
            } else {
                let conflict_files = get_conflict_file_entries(workspace_root);
                Ok(GitRebaseResult {
                    ok: false,
                    state: "conflict".to_string(),
                    message: Some("More conflicts to resolve".to_string()),
                    conflicts,
                    conflict_files,
                })
            }
        } else {
            Ok(GitRebaseResult {
                ok: true,
                state: "completed".to_string(),
                message: Some("Rebase completed".to_string()),
                conflicts: vec![],
                conflict_files: vec![],
            })
        }
    } else {
        // Check if still in conflict
        let conflicts = get_conflict_files(workspace_root);
        if !conflicts.is_empty() {
            let conflict_files = get_conflict_file_entries(workspace_root);
            Ok(GitRebaseResult {
                ok: false,
                state: "conflict".to_string(),
                message: Some(
                    "Conflicts remain. Resolve and stage files before continuing.".to_string(),
                ),
                conflicts,
                conflict_files,
            })
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            Ok(GitRebaseResult {
                ok: false,
                state: "error".to_string(),
                message: Some(if stderr.is_empty() {
                    "Continue failed".to_string()
                } else {
                    stderr
                }),
                conflicts: vec![],
                conflict_files: vec![],
            })
        }
    }
}

/// Git rebase abort
pub fn git_rebase_abort(workspace_root: &Path) -> Result<GitRebaseResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    if !is_rebasing(workspace_root) {
        return Ok(GitRebaseResult {
            ok: false,
            state: "error".to_string(),
            message: Some("No rebase in progress".to_string()),
            conflicts: vec![],
            conflict_files: vec![],
        });
    }

    let output = Command::new("git")
        .args(["rebase", "--abort"])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if output.status.success() {
        Ok(GitRebaseResult {
            ok: true,
            state: "aborted".to_string(),
            message: Some("Rebase aborted".to_string()),
            conflicts: vec![],
            conflict_files: vec![],
        })
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Ok(GitRebaseResult {
            ok: false,
            state: "error".to_string(),
            message: Some(if stderr.is_empty() {
                "Abort failed".to_string()
            } else {
                stderr
            }),
            conflicts: vec![],
            conflict_files: vec![],
        })
    }
}

// ============================================================================
// 冲突向导操作
// ============================================================================

/// 读取冲突文件的四路对比内容（base/ours/theirs/current）
pub fn git_conflict_detail(
    workspace_root: &Path,
    path: &str,
    context: &str,
) -> Result<ConflictFileDetail, GitError> {
    let full_path = validate_path(workspace_root, path)?;

    // 检查是否为二进制文件
    let is_binary = check_binary(workspace_root, path);

    let current_content = if full_path.exists() {
        std::fs::read_to_string(&full_path).unwrap_or_default()
    } else {
        String::new()
    };

    let conflict_markers_count = if !is_binary {
        current_content
            .lines()
            .filter(|l| l.starts_with("<<<<<<<"))
            .count()
    } else {
        0
    };

    // 读取 git object store 中的三个版本
    let base_content = read_git_blob_stage(workspace_root, path, 1);
    let ours_content = read_git_blob_stage(workspace_root, path, 2);
    let theirs_content = read_git_blob_stage(workspace_root, path, 3);

    Ok(ConflictFileDetail {
        path: path.to_string(),
        context: context.to_string(),
        base_content,
        ours_content,
        theirs_content,
        current_content,
        conflict_markers_count,
        is_binary,
    })
}

/// 读取 git 暂存区指定 stage 的 blob 内容
fn read_git_blob_stage(workspace_root: &Path, path: &str, stage: u8) -> Option<String> {
    let blob_ref = format!(":{stage}:{path}");
    let output = Command::new("git")
        .args(["show", &blob_ref])
        .current_dir(workspace_root)
        .output()
        .ok()?;
    if output.status.success() {
        String::from_utf8(output.stdout).ok()
    } else {
        None
    }
}

/// 接受我方版本（accept ours）：checkout --ours 然后 git add
pub fn git_conflict_accept_ours(
    workspace_root: &Path,
    path: &str,
    context: &str,
) -> Result<ConflictActionResult, GitError> {
    let _full_path = validate_path(workspace_root, path)?;

    let output = Command::new("git")
        .args(["checkout", "--ours", "--", path])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Ok(ConflictActionResult {
            ok: false,
            action: "accept_ours".to_string(),
            message: Some(if stderr.is_empty() {
                "Failed to accept ours".to_string()
            } else {
                stderr
            }),
            snapshot: build_conflict_snapshot(workspace_root, context),
        });
    }

    // 暂存已解决文件
    git_stage_file(workspace_root, path)?;
    invalidate_git_status_cache(workspace_root);

    Ok(ConflictActionResult {
        ok: true,
        action: "accept_ours".to_string(),
        message: None,
        snapshot: build_conflict_snapshot(workspace_root, context),
    })
}

/// 接受对方版本（accept theirs）：checkout --theirs 然后 git add
pub fn git_conflict_accept_theirs(
    workspace_root: &Path,
    path: &str,
    context: &str,
) -> Result<ConflictActionResult, GitError> {
    let _full_path = validate_path(workspace_root, path)?;

    let output = Command::new("git")
        .args(["checkout", "--theirs", "--", path])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Ok(ConflictActionResult {
            ok: false,
            action: "accept_theirs".to_string(),
            message: Some(if stderr.is_empty() {
                "Failed to accept theirs".to_string()
            } else {
                stderr
            }),
            snapshot: build_conflict_snapshot(workspace_root, context),
        });
    }

    git_stage_file(workspace_root, path)?;
    invalidate_git_status_cache(workspace_root);

    Ok(ConflictActionResult {
        ok: true,
        action: "accept_theirs".to_string(),
        message: None,
        snapshot: build_conflict_snapshot(workspace_root, context),
    })
}

/// 接受双方版本（accept both）：合并 ours 和 theirs 内容后写入，然后 git add
pub fn git_conflict_accept_both(
    workspace_root: &Path,
    path: &str,
    context: &str,
) -> Result<ConflictActionResult, GitError> {
    let full_path = validate_path(workspace_root, path)?;

    let ours = read_git_blob_stage(workspace_root, path, 2).unwrap_or_default();
    let theirs = read_git_blob_stage(workspace_root, path, 3).unwrap_or_default();

    // 合并：ours 在前，theirs 在后（以换行分隔）
    let merged = if ours.ends_with('\n') {
        format!("{}{}", ours, theirs)
    } else {
        format!("{}\n{}", ours, theirs)
    };

    std::fs::write(&full_path, merged.as_bytes()).map_err(GitError::IoError)?;

    git_stage_file(workspace_root, path)?;
    invalidate_git_status_cache(workspace_root);

    Ok(ConflictActionResult {
        ok: true,
        action: "accept_both".to_string(),
        message: None,
        snapshot: build_conflict_snapshot(workspace_root, context),
    })
}

/// 标记已解决（用户手工编辑完后调用）：git add <path>
pub fn git_conflict_mark_resolved(
    workspace_root: &Path,
    path: &str,
    context: &str,
) -> Result<ConflictActionResult, GitError> {
    let _full_path = validate_path(workspace_root, path)?;
    git_stage_file(workspace_root, path)?;
    invalidate_git_status_cache(workspace_root);

    Ok(ConflictActionResult {
        ok: true,
        action: "mark_resolved".to_string(),
        message: None,
        snapshot: build_conflict_snapshot(workspace_root, context),
    })
}

/// 内部辅助：暂存单个文件
fn git_stage_file(workspace_root: &Path, path: &str) -> Result<(), GitError> {
    let output = Command::new("git")
        .args(["add", "--", path])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Err(GitError::CommandFailed(if stderr.is_empty() {
            format!("git add failed for {path}")
        } else {
            stderr
        }))
    }
}
