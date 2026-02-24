//! Git branch management
//!
//! Provides functions for listing, switching, and creating branches.

use std::path::Path;
use std::process::Command;

use super::utils::*;

/// List local branches and get current branch
///
/// Uses:
/// - `git rev-parse --abbrev-ref HEAD` for current branch
/// - `git for-each-ref refs/heads --format="%(refname:short)"` for branch list
pub fn git_branches(workspace_root: &Path) -> Result<GitBranchesResult, GitError> {
    let repo = gix::discover(workspace_root).map_err(|_| GitError::NotAGitRepo)?;
    let current = match repo.head_name() {
        Ok(Some(name)) => name.shorten().to_string(),
        Ok(None) => "HEAD".to_string(),
        Err(_) => "HEAD".to_string(),
    };

    let refs = repo
        .references()
        .map_err(|e| GitError::CommandFailed(format!("Failed to list references: {}", e)))?;
    let mut branches = Vec::new();
    let iter = refs
        .local_branches()
        .map_err(|e| GitError::CommandFailed(format!("Failed to list local branches: {}", e)))?;
    for item in iter {
        let reference = item
            .map_err(|e| GitError::CommandFailed(format!("Failed to iterate branch refs: {}", e)))?;
        let name = reference.name().shorten().to_string();
        if !name.is_empty() {
            branches.push(GitBranchInfo { name });
        }
    }
    branches.sort_by(|a, b| a.name.cmp(&b.name));

    Ok(GitBranchesResult { current, branches })
}

/// Switch to a different branch
///
/// Uses `git switch <branch>` (Git 2.23+), falls back to `git checkout <branch>`
pub fn git_switch_branch(workspace_root: &Path, branch: &str) -> Result<GitOpResult, GitError> {
    // Check if it's a git repo
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    // Try git switch first (Git 2.23+)
    let switch_output = Command::new("git")
        .args(["switch", branch])
        .current_dir(workspace_root)
        .output();

    match switch_output {
        Ok(output) if output.status.success() => {
            return Ok(GitOpResult {
                op: "switch_branch".to_string(),
                ok: true,
                message: Some(format!("Switched to branch '{}'", branch)),
                path: Some(branch.to_string()),
                scope: "branch".to_string(),
            });
        }
        Ok(output) => {
            // Check if it's a "switch not found" error (old git) or actual error
            let stderr = String::from_utf8_lossy(&output.stderr);
            if !stderr.contains("is not a git command") {
                // Real error from git switch
                return Ok(GitOpResult {
                    op: "switch_branch".to_string(),
                    ok: false,
                    message: Some(stderr.trim().to_string()),
                    path: Some(branch.to_string()),
                    scope: "branch".to_string(),
                });
            }
            // Fall through to checkout
        }
        Err(_) => {
            // Fall through to checkout
        }
    }

    // Fallback to git checkout
    let checkout_output = Command::new("git")
        .args(["checkout", branch])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if checkout_output.status.success() {
        Ok(GitOpResult {
            op: "switch_branch".to_string(),
            ok: true,
            message: Some(format!("Switched to branch '{}'", branch)),
            path: Some(branch.to_string()),
            scope: "branch".to_string(),
        })
    } else {
        let stderr = String::from_utf8_lossy(&checkout_output.stderr)
            .trim()
            .to_string();
        Ok(GitOpResult {
            op: "switch_branch".to_string(),
            ok: false,
            message: Some(if stderr.is_empty() {
                "Switch failed".to_string()
            } else {
                stderr
            }),
            path: Some(branch.to_string()),
            scope: "branch".to_string(),
        })
    }
}

/// Create and switch to a new branch
///
/// Uses `git switch -c <branch>` (Git 2.23+), falls back to `git checkout -b <branch>`
pub fn git_create_branch(workspace_root: &Path, branch: &str) -> Result<GitOpResult, GitError> {
    // Check if it's a git repo
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    // Try git switch -c first (Git 2.23+)
    let switch_output = Command::new("git")
        .args(["switch", "-c", branch])
        .current_dir(workspace_root)
        .output();

    match switch_output {
        Ok(output) if output.status.success() => {
            return Ok(GitOpResult {
                op: "create_branch".to_string(),
                ok: true,
                message: Some(format!("Created and switched to '{}'", branch)),
                path: Some(branch.to_string()),
                scope: "branch".to_string(),
            });
        }
        Ok(output) => {
            // Check if it's a "switch not found" error (old git) or actual error
            let stderr = String::from_utf8_lossy(&output.stderr);
            if !stderr.contains("is not a git command") {
                // Real error from git switch -c (e.g., branch already exists)
                return Ok(GitOpResult {
                    op: "create_branch".to_string(),
                    ok: false,
                    message: Some(stderr.trim().to_string()),
                    path: Some(branch.to_string()),
                    scope: "branch".to_string(),
                });
            }
            // Fall through to checkout -b
        }
        Err(_) => {
            // Fall through to checkout -b
        }
    }

    // Fallback to git checkout -b
    let checkout_output = Command::new("git")
        .args(["checkout", "-b", branch])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if checkout_output.status.success() {
        Ok(GitOpResult {
            op: "create_branch".to_string(),
            ok: true,
            message: Some(format!("Created and switched to '{}'", branch)),
            path: Some(branch.to_string()),
            scope: "branch".to_string(),
        })
    } else {
        let stderr = String::from_utf8_lossy(&checkout_output.stderr)
            .trim()
            .to_string();
        Ok(GitOpResult {
            op: "create_branch".to_string(),
            ok: false,
            message: Some(if stderr.is_empty() {
                "Create branch failed".to_string()
            } else {
                stderr
            }),
            path: Some(branch.to_string()),
            scope: "branch".to_string(),
        })
    }
}
