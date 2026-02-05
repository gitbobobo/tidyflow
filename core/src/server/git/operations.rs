//! Git file operations
//!
//! Provides functions for staging, unstaging, and discarding file changes.

use std::path::Path;
use std::process::Command;

use super::status::git_status;
use super::utils::*;

/// Get git diff for a specific file
///
/// For tracked files: `git diff -- <path>` (working) or `git diff --cached -- <path>` (staged)
/// For untracked files: `git diff --no-index /dev/null -- <path>`
pub fn git_diff(
    workspace_root: &Path,
    path: &str,
    _base: Option<&str>,
    mode: &str, // "working" or "staged"
) -> Result<GitDiffResult, GitError> {
    // Validate path
    let _full_path = validate_path(workspace_root, path)?;

    // Check if it's a git repo
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    // Get status for this file to determine how to diff
    let status_result = git_status(workspace_root)?;
    let file_status = status_result.items.iter().find(|item| item.path == path);

    let code = file_status
        .map(|s| s.code.clone())
        .unwrap_or_else(|| "M".to_string());

    // Check if file is binary
    let is_binary = check_binary(workspace_root, path);
    if is_binary {
        return Ok(GitDiffResult {
            path: path.to_string(),
            code,
            format: "unified".to_string(),
            text: String::new(),
            is_binary: true,
            truncated: false,
            mode: mode.to_string(),
        });
    }

    // Get diff based on status
    let (text, truncated) = if code == "??" {
        // Untracked file - diff against /dev/null (no staged changes for untracked)
        if mode == "staged" {
            (String::new(), false)
        } else {
            get_untracked_diff(workspace_root, path)?
        }
    } else {
        // Tracked file - normal diff
        get_tracked_diff(workspace_root, path, mode)?
    };

    Ok(GitDiffResult {
        path: path.to_string(),
        code,
        format: "unified".to_string(),
        text,
        is_binary: false,
        truncated,
        mode: mode.to_string(),
    })
}

/// Get diff for tracked file
fn get_tracked_diff(
    workspace_root: &Path,
    path: &str,
    mode: &str,
) -> Result<(String, bool), GitError> {
    let args = if mode == "staged" {
        vec!["diff", "--cached", "--", path]
    } else {
        vec!["diff", "--", path]
    };

    let output = Command::new("git")
        .args(&args)
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    let text = String::from_utf8_lossy(&output.stdout);
    let (text, truncated) = truncate_if_needed(&text);

    Ok((text, truncated))
}

/// Get diff for untracked file (diff against /dev/null)
fn get_untracked_diff(workspace_root: &Path, path: &str) -> Result<(String, bool), GitError> {
    let output = Command::new("git")
        .args(["diff", "--no-index", "/dev/null", path])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    // Note: --no-index returns exit code 1 when files differ, which is expected
    let text = String::from_utf8_lossy(&output.stdout);
    let (text, truncated) = truncate_if_needed(&text);

    Ok((text, truncated))
}

/// Stage a file or all files
///
/// - scope "file": git add -- <path>
/// - scope "all": git add -A
pub fn git_stage(
    workspace_root: &Path,
    path: Option<&str>,
    scope: &str,
) -> Result<GitOpResult, GitError> {
    // Check if it's a git repo
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    let (args, path_str): (Vec<&str>, Option<String>) = if scope == "all" {
        (vec!["add", "-A"], None)
    } else {
        let p = path
            .ok_or_else(|| GitError::CommandFailed("Path required for file scope".to_string()))?;
        // Validate path
        validate_path(workspace_root, p)?;
        (vec!["add", "--", p], Some(p.to_string()))
    };

    let output = Command::new("git")
        .args(&args)
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if output.status.success() {
        Ok(GitOpResult {
            op: "stage".to_string(),
            ok: true,
            message: None,
            path: path_str,
            scope: scope.to_string(),
        })
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Ok(GitOpResult {
            op: "stage".to_string(),
            ok: false,
            message: Some(if stderr.is_empty() {
                "Stage failed".to_string()
            } else {
                stderr
            }),
            path: path_str,
            scope: scope.to_string(),
        })
    }
}

/// Unstage a file or all files
///
/// - scope "file": git restore --staged -- <path> (fallback: git reset -- <path>)
/// - scope "all": git restore --staged . (fallback: git reset)
pub fn git_unstage(
    workspace_root: &Path,
    path: Option<&str>,
    scope: &str,
) -> Result<GitOpResult, GitError> {
    // Check if it's a git repo
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    let path_str: Option<String> = if scope == "all" {
        None
    } else {
        let p = path
            .ok_or_else(|| GitError::CommandFailed("Path required for file scope".to_string()))?;
        // Validate path
        validate_path(workspace_root, p)?;
        Some(p.to_string())
    };

    // Try git restore --staged first (Git 2.23+)
    let restore_result = if scope == "all" {
        Command::new("git")
            .args(["restore", "--staged", "."])
            .current_dir(workspace_root)
            .output()
    } else {
        Command::new("git")
            .args(["restore", "--staged", "--", path.unwrap()])
            .current_dir(workspace_root)
            .output()
    };

    match restore_result {
        Ok(output) if output.status.success() => Ok(GitOpResult {
            op: "unstage".to_string(),
            ok: true,
            message: None,
            path: path_str,
            scope: scope.to_string(),
        }),
        _ => {
            // Fallback to git reset
            let reset_output = if scope == "all" {
                Command::new("git")
                    .args(["reset"])
                    .current_dir(workspace_root)
                    .output()
            } else {
                Command::new("git")
                    .args(["reset", "--", path.unwrap()])
                    .current_dir(workspace_root)
                    .output()
            };

            match reset_output {
                Ok(output) if output.status.success() => Ok(GitOpResult {
                    op: "unstage".to_string(),
                    ok: true,
                    message: None,
                    path: path_str,
                    scope: scope.to_string(),
                }),
                Ok(output) => {
                    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
                    Ok(GitOpResult {
                        op: "unstage".to_string(),
                        ok: false,
                        message: Some(if stderr.is_empty() {
                            "Unstage failed".to_string()
                        } else {
                            stderr
                        }),
                        path: path_str,
                        scope: scope.to_string(),
                    })
                }
                Err(e) => Err(GitError::IoError(e)),
            }
        }
    }
}

/// Discard working tree changes for a file or all files
///
/// - For tracked files: git restore -- <path>
/// - For untracked files: git clean -f -- <path> (deletes the file)
/// - scope "all": git restore . (only tracked files, does NOT clean untracked)
///
/// SAFETY: This operation is destructive and cannot be undone.
/// The UI must show a confirmation dialog before calling this.
pub fn git_discard(
    workspace_root: &Path,
    path: Option<&str>,
    scope: &str,
) -> Result<GitOpResult, GitError> {
    // Check if it's a git repo
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    if scope == "all" {
        // Discard all tracked changes (does NOT delete untracked files for safety)
        let output = Command::new("git")
            .args(["restore", "."])
            .current_dir(workspace_root)
            .output()
            .map_err(GitError::IoError)?;

        if output.status.success() {
            Ok(GitOpResult {
                op: "discard".to_string(),
                ok: true,
                message: None,
                path: None,
                scope: scope.to_string(),
            })
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            Ok(GitOpResult {
                op: "discard".to_string(),
                ok: false,
                message: Some(if stderr.is_empty() {
                    "Discard failed".to_string()
                } else {
                    stderr
                }),
                path: None,
                scope: scope.to_string(),
            })
        }
    } else {
        // Single file discard
        let p = path
            .ok_or_else(|| GitError::CommandFailed("Path required for file scope".to_string()))?;
        validate_path(workspace_root, p)?;

        // Check if file is untracked
        let status_result = git_status(workspace_root)?;
        let file_status = status_result.items.iter().find(|item| item.path == p);

        let is_untracked = file_status.map(|s| s.code == "??").unwrap_or(false);

        if is_untracked {
            // Untracked file: use git clean -f to delete
            let output = Command::new("git")
                .args(["clean", "-f", "--", p])
                .current_dir(workspace_root)
                .output()
                .map_err(GitError::IoError)?;

            if output.status.success() {
                Ok(GitOpResult {
                    op: "discard".to_string(),
                    ok: true,
                    message: Some("File deleted".to_string()),
                    path: Some(p.to_string()),
                    scope: scope.to_string(),
                })
            } else {
                let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
                Ok(GitOpResult {
                    op: "discard".to_string(),
                    ok: false,
                    message: Some(if stderr.is_empty() {
                        "Failed to delete file".to_string()
                    } else {
                        stderr
                    }),
                    path: Some(p.to_string()),
                    scope: scope.to_string(),
                })
            }
        } else {
            // Tracked file: use git restore
            let output = Command::new("git")
                .args(["restore", "--", p])
                .current_dir(workspace_root)
                .output()
                .map_err(GitError::IoError)?;

            if output.status.success() {
                Ok(GitOpResult {
                    op: "discard".to_string(),
                    ok: true,
                    message: None,
                    path: Some(p.to_string()),
                    scope: scope.to_string(),
                })
            } else {
                let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
                Ok(GitOpResult {
                    op: "discard".to_string(),
                    ok: false,
                    message: Some(if stderr.is_empty() {
                        "Discard failed".to_string()
                    } else {
                        stderr
                    }),
                    path: Some(p.to_string()),
                    scope: scope.to_string(),
                })
            }
        }
    }
}
