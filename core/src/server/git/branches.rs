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
    // Check if it's a git repo
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    // Get current branch
    let current_output = Command::new("git")
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    let current = if current_output.status.success() {
        String::from_utf8_lossy(&current_output.stdout)
            .trim()
            .to_string()
    } else {
        "HEAD".to_string() // Detached HEAD state
    };

    // Get all local branches
    let branches_output = Command::new("git")
        .args(["for-each-ref", "refs/heads", "--format=%(refname:short)"])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    let mut branches = Vec::new();
    if branches_output.status.success() {
        let stdout = String::from_utf8_lossy(&branches_output.stdout);
        for line in stdout.lines() {
            let name = line.trim();
            if !name.is_empty() {
                branches.push(GitBranchInfo {
                    name: name.to_string(),
                });
            }
        }
    }

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
