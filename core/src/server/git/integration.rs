//! Integration worktree for safe merge/rebase operations
//!
//! Provides functions to manage integration worktrees for testing merges and rebases
//! without affecting the user's working directory.

use std::path::{Path, PathBuf};
use std::process::Command;

use super::utils::*;

/// Get the integration worktree path for a project
fn get_integration_worktree_path(project_name: &str) -> PathBuf {
    // Sanitize project name (alphanumeric + hyphen only)
    let sanitized: String = project_name
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '-' {
                c
            } else {
                '-'
            }
        })
        .collect();

    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home)
        .join(".tidyflow")
        .join("worktrees")
        .join(sanitized)
        .join("__integration")
}

/// Check if integration worktree exists
fn integration_worktree_exists(path: &Path) -> bool {
    path.exists() && path.join(".git").exists()
}

/// Check if integration worktree is clean (no uncommitted changes, no merge/rebase in progress)
fn is_integration_clean(path: &Path) -> bool {
    // Check for uncommitted changes
    let status_output = Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(path)
        .output();

    let has_changes = match status_output {
        Ok(out) => !String::from_utf8_lossy(&out.stdout).trim().is_empty(),
        Err(_) => true,
    };

    if has_changes {
        return false;
    }

    // Check for merge in progress
    if is_merging(path) {
        return false;
    }

    // UX-4: Check for rebase in progress
    if is_rebasing_in_worktree(path) {
        return false;
    }

    true
}

/// UX-4: Check if currently in a rebase state (for integration worktree)
fn is_rebasing_in_worktree(worktree_path: &Path) -> bool {
    // Check via git command for worktrees (handles both .git file and .git dir)
    let output = Command::new("git")
        .args(["rev-parse", "--git-path", "rebase-merge"])
        .current_dir(worktree_path)
        .output();

    if let Ok(out) = output {
        let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !path.is_empty() && std::path::Path::new(&path).exists() {
            return true;
        }
    }

    // Also check rebase-apply (for git am / git rebase --apply)
    let output = Command::new("git")
        .args(["rev-parse", "--git-path", "rebase-apply"])
        .current_dir(worktree_path)
        .output();

    if let Ok(out) = output {
        let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !path.is_empty() && std::path::Path::new(&path).exists() {
            return true;
        }
    }

    false
}

/// Ensure integration worktree exists and is ready
///
/// Creates the worktree if it doesn't exist, or validates it's clean if it does.
pub fn ensure_integration_worktree(
    repo_root: &Path,
    project_name: &str,
    default_branch: &str,
) -> Result<String, GitError> {
    let integration_path = get_integration_worktree_path(project_name);

    if integration_worktree_exists(&integration_path) {
        // Worktree exists, check if clean
        if !is_integration_clean(&integration_path) {
            return Err(GitError::CommandFailed(
                "Integration worktree is not clean. Abort or clean up first.".to_string(),
            ));
        }

        // Ensure we're on the default branch
        let checkout_output = Command::new("git")
            .args(["checkout", default_branch])
            .current_dir(&integration_path)
            .output()
            .map_err(GitError::IoError)?;

        if !checkout_output.status.success() {
            let stderr = String::from_utf8_lossy(&checkout_output.stderr);
            return Err(GitError::CommandFailed(format!(
                "Failed to checkout {}: {}",
                default_branch, stderr
            )));
        }

        return Ok(integration_path.to_string_lossy().to_string());
    }

    // Create parent directories
    if let Some(parent) = integration_path.parent() {
        std::fs::create_dir_all(parent).map_err(GitError::IoError)?;
    }

    // Create the worktree
    let output = Command::new("git")
        .args([
            "worktree",
            "add",
            integration_path.to_string_lossy().as_ref(),
            default_branch,
        ])
        .current_dir(repo_root)
        .output()
        .map_err(GitError::IoError)?;

    if output.status.success() {
        Ok(integration_path.to_string_lossy().to_string())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Err(GitError::CommandFailed(format!(
            "Failed to create integration worktree: {}",
            if stderr.is_empty() {
                "Unknown error"
            } else {
                &stderr
            }
        )))
    }
}

/// Get integration worktree status
pub fn integration_status(
    project_name: &str,
    default_branch: &str,
) -> Result<IntegrationStatusResult, GitError> {
    let integration_path = get_integration_worktree_path(project_name);

    if !integration_worktree_exists(&integration_path) {
        return Ok(IntegrationStatusResult {
            state: IntegrationState::Idle,
            conflicts: vec![],
            head: None,
            default_branch: default_branch.to_string(),
            path: integration_path.to_string_lossy().to_string(),
            is_clean: true,
            branch_ahead_by: None,
            branch_behind_by: None,
            compared_branch: None,
        });
    }

    // UX-4: Check for rebase state first (takes precedence)
    let state = if is_rebasing_in_worktree(&integration_path) {
        let conflicts = get_conflict_files(&integration_path);
        if conflicts.is_empty() {
            IntegrationState::Rebasing
        } else {
            IntegrationState::RebaseConflict
        }
    } else if is_merging(&integration_path) {
        let conflicts = get_conflict_files(&integration_path);
        if conflicts.is_empty() {
            IntegrationState::Merging
        } else {
            IntegrationState::Conflict
        }
    } else {
        IntegrationState::Idle
    };

    let conflicts = if state != IntegrationState::Idle {
        get_conflict_files(&integration_path)
    } else {
        vec![]
    };

    let head = get_short_head_sha(&integration_path);
    let is_clean = is_integration_clean(&integration_path);

    Ok(IntegrationStatusResult {
        state,
        conflicts,
        head,
        default_branch: default_branch.to_string(),
        path: integration_path.to_string_lossy().to_string(),
        is_clean,
        branch_ahead_by: None,
        branch_behind_by: None,
        compared_branch: None,
    })
}

/// Merge a source branch into the default branch via integration worktree
///
/// This performs the merge in the integration worktree, not the user's workspace.
pub fn merge_to_default(
    repo_root: &Path,
    project_name: &str,
    source_branch: &str,
    default_branch: &str,
) -> Result<MergeToDefaultResult, GitError> {
    // Ensure integration worktree exists and is clean
    let integration_path_str =
        ensure_integration_worktree(repo_root, project_name, default_branch)?;
    let integration_path = PathBuf::from(&integration_path_str);

    // Verify source branch exists
    let show_ref_output = Command::new("git")
        .args([
            "show-ref",
            "--verify",
            &format!("refs/heads/{}", source_branch),
        ])
        .current_dir(repo_root)
        .output()
        .map_err(GitError::IoError)?;

    if !show_ref_output.status.success() {
        return Ok(MergeToDefaultResult {
            ok: false,
            state: "failed".to_string(),
            message: Some(format!("Branch '{}' not found", source_branch)),
            conflicts: vec![],
            head_sha: None,
            integration_path: Some(integration_path_str),
        });
    }

    // Perform the merge
    let merge_output = Command::new("git")
        .args(["merge", source_branch, "--no-edit"])
        .current_dir(&integration_path)
        .output()
        .map_err(GitError::IoError)?;

    if merge_output.status.success() {
        // Merge completed successfully
        let head_sha = get_short_head_sha(&integration_path);
        Ok(MergeToDefaultResult {
            ok: true,
            state: "completed".to_string(),
            message: Some(format!("Merged {} into {}", source_branch, default_branch)),
            conflicts: vec![],
            head_sha,
            integration_path: Some(integration_path_str),
        })
    } else {
        // Check if we're in a conflict state
        if is_merging(&integration_path) {
            let conflicts = get_conflict_files(&integration_path);
            Ok(MergeToDefaultResult {
                ok: false,
                state: "conflict".to_string(),
                message: Some("Merge has conflicts".to_string()),
                conflicts,
                head_sha: None,
                integration_path: Some(integration_path_str),
            })
        } else {
            let stderr = String::from_utf8_lossy(&merge_output.stderr)
                .trim()
                .to_string();
            Ok(MergeToDefaultResult {
                ok: false,
                state: "failed".to_string(),
                message: Some(if stderr.is_empty() {
                    "Merge failed".to_string()
                } else {
                    stderr
                }),
                conflicts: vec![],
                head_sha: None,
                integration_path: Some(integration_path_str),
            })
        }
    }
}

/// Continue a merge after conflict resolution
pub fn merge_continue(project_name: &str) -> Result<MergeToDefaultResult, GitError> {
    let integration_path = get_integration_worktree_path(project_name);

    if !integration_worktree_exists(&integration_path) {
        return Ok(MergeToDefaultResult {
            ok: false,
            state: "failed".to_string(),
            message: Some("Integration worktree does not exist".to_string()),
            conflicts: vec![],
            head_sha: None,
            integration_path: None,
        });
    }

    if !is_merging(&integration_path) {
        return Ok(MergeToDefaultResult {
            ok: false,
            state: "idle".to_string(),
            message: Some("No merge in progress".to_string()),
            conflicts: vec![],
            head_sha: None,
            integration_path: Some(integration_path.to_string_lossy().to_string()),
        });
    }

    // Check if there are still conflicts
    let conflicts = get_conflict_files(&integration_path);
    if !conflicts.is_empty() {
        return Ok(MergeToDefaultResult {
            ok: false,
            state: "conflict".to_string(),
            message: Some(
                "Conflicts remain. Resolve and stage files before continuing.".to_string(),
            ),
            conflicts,
            head_sha: None,
            integration_path: Some(integration_path.to_string_lossy().to_string()),
        });
    }

    // Stage all changes
    let add_output = Command::new("git")
        .args(["add", "-A"])
        .current_dir(&integration_path)
        .output()
        .map_err(GitError::IoError)?;

    if !add_output.status.success() {
        let stderr = String::from_utf8_lossy(&add_output.stderr)
            .trim()
            .to_string();
        return Ok(MergeToDefaultResult {
            ok: false,
            state: "failed".to_string(),
            message: Some(format!("Failed to stage changes: {}", stderr)),
            conflicts: vec![],
            head_sha: None,
            integration_path: Some(integration_path.to_string_lossy().to_string()),
        });
    }

    // Complete the merge with commit
    let commit_output = Command::new("git")
        .args(["commit", "--no-edit"])
        .current_dir(&integration_path)
        .output()
        .map_err(GitError::IoError)?;

    if commit_output.status.success() {
        let head_sha = get_short_head_sha(&integration_path);
        Ok(MergeToDefaultResult {
            ok: true,
            state: "completed".to_string(),
            message: Some("Merge completed".to_string()),
            conflicts: vec![],
            head_sha,
            integration_path: Some(integration_path.to_string_lossy().to_string()),
        })
    } else {
        let stderr = String::from_utf8_lossy(&commit_output.stderr)
            .trim()
            .to_string();
        // Check if still in merge state (might have more conflicts)
        if is_merging(&integration_path) {
            let conflicts = get_conflict_files(&integration_path);
            Ok(MergeToDefaultResult {
                ok: false,
                state: "conflict".to_string(),
                message: Some(if stderr.is_empty() {
                    "More conflicts to resolve".to_string()
                } else {
                    stderr
                }),
                conflicts,
                head_sha: None,
                integration_path: Some(integration_path.to_string_lossy().to_string()),
            })
        } else {
            Ok(MergeToDefaultResult {
                ok: false,
                state: "failed".to_string(),
                message: Some(if stderr.is_empty() {
                    "Commit failed".to_string()
                } else {
                    stderr
                }),
                conflicts: vec![],
                head_sha: None,
                integration_path: Some(integration_path.to_string_lossy().to_string()),
            })
        }
    }
}

/// Abort a merge in progress
pub fn merge_abort(project_name: &str) -> Result<MergeToDefaultResult, GitError> {
    let integration_path = get_integration_worktree_path(project_name);

    if !integration_worktree_exists(&integration_path) {
        return Ok(MergeToDefaultResult {
            ok: false,
            state: "failed".to_string(),
            message: Some("Integration worktree does not exist".to_string()),
            conflicts: vec![],
            head_sha: None,
            integration_path: None,
        });
    }

    if !is_merging(&integration_path) {
        return Ok(MergeToDefaultResult {
            ok: true,
            state: "idle".to_string(),
            message: Some("No merge in progress".to_string()),
            conflicts: vec![],
            head_sha: None,
            integration_path: Some(integration_path.to_string_lossy().to_string()),
        });
    }

    let output = Command::new("git")
        .args(["merge", "--abort"])
        .current_dir(&integration_path)
        .output()
        .map_err(GitError::IoError)?;

    if output.status.success() {
        Ok(MergeToDefaultResult {
            ok: true,
            state: "idle".to_string(),
            message: Some("Merge aborted".to_string()),
            conflicts: vec![],
            head_sha: None,
            integration_path: Some(integration_path.to_string_lossy().to_string()),
        })
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Ok(MergeToDefaultResult {
            ok: false,
            state: "failed".to_string(),
            message: Some(if stderr.is_empty() {
                "Abort failed".to_string()
            } else {
                stderr
            }),
            conflicts: vec![],
            head_sha: None,
            integration_path: Some(integration_path.to_string_lossy().to_string()),
        })
    }
}

// ============================================================================
// v1.13: Integration Worktree Rebase onto Default (UX-4)
// ============================================================================

/// UX-4: Rebase the source branch onto the default branch via integration worktree
///
/// This performs the rebase in the integration worktree, not the user's workspace.
/// Steps:
/// 1. Ensure integration worktree exists and is clean
/// 2. Checkout the source branch in integration worktree
/// 3. Fetch latest from remote
/// 4. Rebase onto default branch
pub fn rebase_onto_default(
    repo_root: &Path,
    project_name: &str,
    source_branch: &str,
    default_branch: &str,
) -> Result<RebaseOntoDefaultResult, GitError> {
    // Ensure integration worktree exists and is clean
    let integration_path_str =
        ensure_integration_worktree(repo_root, project_name, default_branch)?;
    let integration_path = PathBuf::from(&integration_path_str);

    // Verify source branch exists
    let show_ref_output = Command::new("git")
        .args([
            "show-ref",
            "--verify",
            &format!("refs/heads/{}", source_branch),
        ])
        .current_dir(repo_root)
        .output()
        .map_err(GitError::IoError)?;

    if !show_ref_output.status.success() {
        return Ok(RebaseOntoDefaultResult {
            ok: false,
            state: "failed".to_string(),
            message: Some(format!("Branch '{}' not found", source_branch)),
            conflicts: vec![],
            head_sha: None,
            integration_path: Some(integration_path_str),
        });
    }

    // Checkout the source branch in integration worktree
    let checkout_output = Command::new("git")
        .args(["checkout", source_branch])
        .current_dir(&integration_path)
        .output()
        .map_err(GitError::IoError)?;

    if !checkout_output.status.success() {
        let stderr = String::from_utf8_lossy(&checkout_output.stderr)
            .trim()
            .to_string();
        return Ok(RebaseOntoDefaultResult {
            ok: false,
            state: "failed".to_string(),
            message: Some(format!("Failed to checkout {}: {}", source_branch, stderr)),
            conflicts: vec![],
            head_sha: None,
            integration_path: Some(integration_path_str),
        });
    }

    // Fetch latest from remote
    let fetch_output = Command::new("git")
        .args(["fetch", "origin"])
        .current_dir(&integration_path)
        .output()
        .map_err(GitError::IoError)?;

    if !fetch_output.status.success() {
        let stderr = String::from_utf8_lossy(&fetch_output.stderr)
            .trim()
            .to_string();
        return Ok(RebaseOntoDefaultResult {
            ok: false,
            state: "failed".to_string(),
            message: Some(format!("Failed to fetch: {}", stderr)),
            conflicts: vec![],
            head_sha: None,
            integration_path: Some(integration_path_str),
        });
    }

    // Perform the rebase onto default branch (use origin/<default_branch> for remote tracking)
    let rebase_target = format!("origin/{}", default_branch);
    let rebase_output = Command::new("git")
        .args(["rebase", &rebase_target])
        .current_dir(&integration_path)
        .output()
        .map_err(GitError::IoError)?;

    if rebase_output.status.success() {
        // Rebase completed successfully
        let head_sha = get_short_head_sha(&integration_path);
        Ok(RebaseOntoDefaultResult {
            ok: true,
            state: "completed".to_string(),
            message: Some(format!("Rebased {} onto {}", source_branch, rebase_target)),
            conflicts: vec![],
            head_sha,
            integration_path: Some(integration_path_str),
        })
    } else {
        // Check if we're in a rebase conflict state
        if is_rebasing_in_worktree(&integration_path) {
            let conflicts = get_conflict_files(&integration_path);
            Ok(RebaseOntoDefaultResult {
                ok: false,
                state: "rebase_conflict".to_string(),
                message: Some("Rebase has conflicts".to_string()),
                conflicts,
                head_sha: None,
                integration_path: Some(integration_path_str),
            })
        } else {
            let stderr = String::from_utf8_lossy(&rebase_output.stderr)
                .trim()
                .to_string();
            Ok(RebaseOntoDefaultResult {
                ok: false,
                state: "failed".to_string(),
                message: Some(if stderr.is_empty() {
                    "Rebase failed".to_string()
                } else {
                    stderr
                }),
                conflicts: vec![],
                head_sha: None,
                integration_path: Some(integration_path_str),
            })
        }
    }
}

/// UX-4: Continue a rebase after conflict resolution
pub fn rebase_onto_default_continue(
    project_name: &str,
) -> Result<RebaseOntoDefaultResult, GitError> {
    let integration_path = get_integration_worktree_path(project_name);

    if !integration_worktree_exists(&integration_path) {
        return Ok(RebaseOntoDefaultResult {
            ok: false,
            state: "failed".to_string(),
            message: Some("Integration worktree does not exist".to_string()),
            conflicts: vec![],
            head_sha: None,
            integration_path: None,
        });
    }

    if !is_rebasing_in_worktree(&integration_path) {
        return Ok(RebaseOntoDefaultResult {
            ok: false,
            state: "idle".to_string(),
            message: Some("No rebase in progress".to_string()),
            conflicts: vec![],
            head_sha: None,
            integration_path: Some(integration_path.to_string_lossy().to_string()),
        });
    }

    // Check if there are still conflicts
    let conflicts = get_conflict_files(&integration_path);
    if !conflicts.is_empty() {
        return Ok(RebaseOntoDefaultResult {
            ok: false,
            state: "rebase_conflict".to_string(),
            message: Some(
                "Conflicts remain. Resolve and stage files before continuing.".to_string(),
            ),
            conflicts,
            head_sha: None,
            integration_path: Some(integration_path.to_string_lossy().to_string()),
        });
    }

    // Stage all changes (required before rebase --continue)
    let add_output = Command::new("git")
        .args(["add", "-A"])
        .current_dir(&integration_path)
        .output()
        .map_err(GitError::IoError)?;

    if !add_output.status.success() {
        let stderr = String::from_utf8_lossy(&add_output.stderr)
            .trim()
            .to_string();
        return Ok(RebaseOntoDefaultResult {
            ok: false,
            state: "failed".to_string(),
            message: Some(format!("Failed to stage changes: {}", stderr)),
            conflicts: vec![],
            head_sha: None,
            integration_path: Some(integration_path.to_string_lossy().to_string()),
        });
    }

    // Continue the rebase
    let continue_output = Command::new("git")
        .args(["rebase", "--continue"])
        .current_dir(&integration_path)
        .env("GIT_EDITOR", "true") // Skip editor for commit message
        .output()
        .map_err(GitError::IoError)?;

    if continue_output.status.success() {
        // Check if rebase is fully complete
        if is_rebasing_in_worktree(&integration_path) {
            // More commits to replay, still in rebase
            let conflicts = get_conflict_files(&integration_path);
            if conflicts.is_empty() {
                Ok(RebaseOntoDefaultResult {
                    ok: false,
                    state: "rebasing".to_string(),
                    message: Some("Rebase continuing...".to_string()),
                    conflicts: vec![],
                    head_sha: None,
                    integration_path: Some(integration_path.to_string_lossy().to_string()),
                })
            } else {
                Ok(RebaseOntoDefaultResult {
                    ok: false,
                    state: "rebase_conflict".to_string(),
                    message: Some("More conflicts to resolve".to_string()),
                    conflicts,
                    head_sha: None,
                    integration_path: Some(integration_path.to_string_lossy().to_string()),
                })
            }
        } else {
            let head_sha = get_short_head_sha(&integration_path);
            Ok(RebaseOntoDefaultResult {
                ok: true,
                state: "completed".to_string(),
                message: Some("Rebase completed".to_string()),
                conflicts: vec![],
                head_sha,
                integration_path: Some(integration_path.to_string_lossy().to_string()),
            })
        }
    } else {
        let stderr = String::from_utf8_lossy(&continue_output.stderr)
            .trim()
            .to_string();
        // Check if still in rebase state (might have more conflicts)
        if is_rebasing_in_worktree(&integration_path) {
            let conflicts = get_conflict_files(&integration_path);
            Ok(RebaseOntoDefaultResult {
                ok: false,
                state: "rebase_conflict".to_string(),
                message: Some(if stderr.is_empty() {
                    "More conflicts to resolve".to_string()
                } else {
                    stderr
                }),
                conflicts,
                head_sha: None,
                integration_path: Some(integration_path.to_string_lossy().to_string()),
            })
        } else {
            Ok(RebaseOntoDefaultResult {
                ok: false,
                state: "failed".to_string(),
                message: Some(if stderr.is_empty() {
                    "Continue failed".to_string()
                } else {
                    stderr
                }),
                conflicts: vec![],
                head_sha: None,
                integration_path: Some(integration_path.to_string_lossy().to_string()),
            })
        }
    }
}

/// UX-4: Abort a rebase in progress
pub fn rebase_onto_default_abort(project_name: &str) -> Result<RebaseOntoDefaultResult, GitError> {
    let integration_path = get_integration_worktree_path(project_name);

    if !integration_worktree_exists(&integration_path) {
        return Ok(RebaseOntoDefaultResult {
            ok: false,
            state: "failed".to_string(),
            message: Some("Integration worktree does not exist".to_string()),
            conflicts: vec![],
            head_sha: None,
            integration_path: None,
        });
    }

    if !is_rebasing_in_worktree(&integration_path) {
        return Ok(RebaseOntoDefaultResult {
            ok: true,
            state: "idle".to_string(),
            message: Some("No rebase in progress".to_string()),
            conflicts: vec![],
            head_sha: None,
            integration_path: Some(integration_path.to_string_lossy().to_string()),
        });
    }

    let output = Command::new("git")
        .args(["rebase", "--abort"])
        .current_dir(&integration_path)
        .output()
        .map_err(GitError::IoError)?;

    if output.status.success() {
        Ok(RebaseOntoDefaultResult {
            ok: true,
            state: "idle".to_string(),
            message: Some("Rebase aborted".to_string()),
            conflicts: vec![],
            head_sha: None,
            integration_path: Some(integration_path.to_string_lossy().to_string()),
        })
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Ok(RebaseOntoDefaultResult {
            ok: false,
            state: "failed".to_string(),
            message: Some(if stderr.is_empty() {
                "Abort failed".to_string()
            } else {
                stderr
            }),
            conflicts: vec![],
            head_sha: None,
            integration_path: Some(integration_path.to_string_lossy().to_string()),
        })
    }
}

// ============================================================================
// v1.14: Integration Worktree Reset (UX-5)
// ============================================================================

/// UX-5: Reset integration worktree to clean state
///
/// This function:
/// 1. Aborts any in-progress merge or rebase
/// 2. Removes the integration worktree
/// 3. Recreates a fresh integration worktree
///
/// SAFETY: This only affects the integration worktree, not user's workspace
pub fn reset_integration_worktree(
    repo_root: &Path,
    project_name: &str,
    default_branch: &str,
) -> Result<ResetIntegrationWorktreeResult, GitError> {
    let integration_path = get_integration_worktree_path(project_name);
    let integration_path_str = integration_path.to_string_lossy().to_string();

    // Safety check: Validate path is under ~/.tidyflow/worktrees/
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let safe_prefix = PathBuf::from(&home).join(".tidyflow").join("worktrees");
    if !integration_path.starts_with(&safe_prefix) {
        return Err(GitError::CommandFailed(format!(
            "Safety check failed: path {} is not under {}",
            integration_path_str,
            safe_prefix.display()
        )));
    }

    // If worktree exists, clean it up
    if integration_worktree_exists(&integration_path) {
        // Abort any in-progress rebase
        if is_rebasing_in_worktree(&integration_path) {
            let _ = Command::new("git")
                .args(["rebase", "--abort"])
                .current_dir(&integration_path)
                .output();
        }

        // Abort any in-progress merge
        if is_merging(&integration_path) {
            let _ = Command::new("git")
                .args(["merge", "--abort"])
                .current_dir(&integration_path)
                .output();
        }

        // Remove the worktree forcefully
        let remove_output = Command::new("git")
            .args(["worktree", "remove", &integration_path_str, "--force"])
            .current_dir(repo_root)
            .output()
            .map_err(GitError::IoError)?;

        if !remove_output.status.success() {
            // If git worktree remove fails, try to remove the directory manually
            // This can happen if the worktree is in a corrupted state
            if integration_path.exists() {
                std::fs::remove_dir_all(&integration_path).map_err(GitError::IoError)?;
            }

            // Also prune stale worktree entries
            let _ = Command::new("git")
                .args(["worktree", "prune"])
                .current_dir(repo_root)
                .output();
        }
    }

    // Create parent directories if needed
    if let Some(parent) = integration_path.parent() {
        std::fs::create_dir_all(parent).map_err(GitError::IoError)?;
    }

    // Recreate the worktree
    let create_output = Command::new("git")
        .args(["worktree", "add", &integration_path_str, default_branch])
        .current_dir(repo_root)
        .output()
        .map_err(GitError::IoError)?;

    if create_output.status.success() {
        Ok(ResetIntegrationWorktreeResult {
            ok: true,
            message: Some("Integration worktree reset successfully".to_string()),
            path: Some(integration_path_str),
        })
    } else {
        let stderr = String::from_utf8_lossy(&create_output.stderr)
            .trim()
            .to_string();
        Ok(ResetIntegrationWorktreeResult {
            ok: false,
            message: Some(format!(
                "Failed to recreate integration worktree: {}",
                if stderr.is_empty() {
                    "Unknown error"
                } else {
                    &stderr
                }
            )),
            path: None,
        })
    }
}

// ============================================================================
// v1.15: Branch Divergence Detection (UX-6)
// ============================================================================

/// v1.15: Check branch divergence against remote default branch (UX-6)
///
/// This function:
/// 1. Fetches from origin (with timeout, non-blocking)
/// 2. Runs `git rev-list --left-right --count <current_branch>...origin/<default_branch>`
/// 3. Parses the output to get ahead/behind counts
///
/// All operations are READ-ONLY (fetch only updates remote tracking refs).
pub fn check_branch_divergence(
    workspace_root: &Path,
    current_branch: &str,
    default_branch: &str,
) -> Result<BranchDivergenceResult, GitError> {
    // Check if it's a git repo
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    // Fetch from origin (safe, read-only operation)
    // Use a timeout to avoid blocking indefinitely on network issues
    let fetch_output = Command::new("git")
        .args(["fetch", "origin", "--no-tags"])
        .current_dir(workspace_root)
        .output();

    // Log fetch result but don't fail if fetch fails (network might be unavailable)
    if let Err(e) = &fetch_output {
        tracing::warn!("Git fetch failed (continuing with local data): {}", e);
    } else if let Ok(output) = &fetch_output {
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            tracing::warn!(
                "Git fetch returned error (continuing with local data): {}",
                stderr
            );
        }
    }

    // Build the comparison ref
    let remote_ref = format!("origin/{}", default_branch);

    // Check if the remote ref exists
    let check_ref_output = Command::new("git")
        .args(["rev-parse", "--verify", &remote_ref])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if !check_ref_output.status.success() {
        return Err(GitError::CommandFailed(format!(
            "Remote branch '{}' not found. Make sure the default branch exists on origin.",
            remote_ref
        )));
    }

    // Run git rev-list to get ahead/behind counts
    // Format: <ahead>\t<behind>
    let rev_list_output = Command::new("git")
        .args([
            "rev-list",
            "--left-right",
            "--count",
            &format!("{}...{}", current_branch, remote_ref),
        ])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if !rev_list_output.status.success() {
        let stderr = String::from_utf8_lossy(&rev_list_output.stderr)
            .trim()
            .to_string();
        return Err(GitError::CommandFailed(format!(
            "Failed to compare branches: {}",
            if stderr.is_empty() {
                "Unknown error"
            } else {
                &stderr
            }
        )));
    }

    // Parse the output: "<ahead>\t<behind>"
    let stdout = String::from_utf8_lossy(&rev_list_output.stdout);
    let parts: Vec<&str> = stdout.trim().split('\t').collect();

    if parts.len() != 2 {
        return Err(GitError::CommandFailed(format!(
            "Unexpected rev-list output format: '{}'",
            stdout.trim()
        )));
    }

    let ahead_by = parts[0]
        .parse::<i32>()
        .map_err(|e| GitError::CommandFailed(format!("Failed to parse ahead count: {}", e)))?;

    let behind_by = parts[1]
        .parse::<i32>()
        .map_err(|e| GitError::CommandFailed(format!("Failed to parse behind count: {}", e)))?;

    Ok(BranchDivergenceResult {
        ahead_by,
        behind_by,
        compared_branch: remote_ref,
    })
}
