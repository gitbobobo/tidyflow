//! Git Tools API - git status and diff functionality
//!
//! Provides workspace-scoped git operations using system git.

use std::path::{Path, PathBuf};
use std::process::Command;

/// Maximum diff size in bytes (1MB)
pub const MAX_DIFF_SIZE: usize = 1_048_576;

/// Git status entry
#[derive(Debug, Clone)]
pub struct GitStatusEntry {
    pub path: String,
    pub code: String,
    pub orig_path: Option<String>,
}

/// Git status result
#[derive(Debug)]
pub struct GitStatusResult {
    pub repo_root: String,
    pub items: Vec<GitStatusEntry>,
    pub has_staged_changes: bool,
    pub staged_count: usize,
}

/// Git diff result
#[derive(Debug)]
pub struct GitDiffResult {
    pub path: String,
    pub code: String,
    pub format: String,
    pub text: String,
    pub is_binary: bool,
    pub truncated: bool,
    pub mode: String,
}

/// Git operation result (stage/unstage)
#[derive(Debug)]
pub struct GitOpResult {
    pub op: String,
    pub ok: bool,
    pub message: Option<String>,
    pub path: Option<String>,
    pub scope: String,
}

/// Git branch info
#[derive(Debug)]
pub struct GitBranchInfo {
    pub name: String,
}

/// Git branches result
#[derive(Debug)]
pub struct GitBranchesResult {
    pub current: String,
    pub branches: Vec<GitBranchInfo>,
}

/// Git commit result
#[derive(Debug)]
pub struct GitCommitResult {
    pub ok: bool,
    pub message: Option<String>,
    pub sha: Option<String>,
}

/// Git operation state (for rebase/merge)
#[derive(Debug, Clone, PartialEq)]
pub enum GitOpState {
    Normal,
    Rebasing,
    Merging,
}

impl GitOpState {
    pub fn as_str(&self) -> &'static str {
        match self {
            GitOpState::Normal => "normal",
            GitOpState::Rebasing => "rebasing",
            GitOpState::Merging => "merging",
        }
    }
}

/// Git rebase result
#[derive(Debug)]
pub struct GitRebaseResult {
    pub ok: bool,
    pub state: String,  // "completed", "conflict", "aborted", "error"
    pub message: Option<String>,
    pub conflicts: Vec<String>,
}

/// Git operation status result
#[derive(Debug)]
pub struct GitOpStatusResult {
    pub state: GitOpState,
    pub conflicts: Vec<String>,
    pub head: Option<String>,
    pub onto: Option<String>,
}

/// Error type for git operations
#[derive(Debug)]
pub enum GitError {
    NotAGitRepo,
    PathEscape,
    IoError(std::io::Error),
    CommandFailed(String),
}

impl std::fmt::Display for GitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GitError::NotAGitRepo => write!(f, "Not a git repository"),
            GitError::PathEscape => write!(f, "Path escapes workspace root"),
            GitError::IoError(e) => write!(f, "IO error: {}", e),
            GitError::CommandFailed(msg) => write!(f, "Git command failed: {}", msg),
        }
    }
}

impl std::error::Error for GitError {}

/// Validate that a path is within the workspace root
fn validate_path(workspace_root: &Path, path: &str) -> Result<PathBuf, GitError> {
    // Reject obvious escape attempts
    if path.contains("..") {
        // Check if it actually escapes
        let full_path = workspace_root.join(path);
        let canonical = full_path.canonicalize().map_err(|_| GitError::PathEscape)?;
        let root_canonical = workspace_root.canonicalize().map_err(GitError::IoError)?;

        if !canonical.starts_with(&root_canonical) {
            return Err(GitError::PathEscape);
        }
        Ok(canonical)
    } else {
        Ok(workspace_root.join(path))
    }
}

/// Check if workspace is in a git repository and get repo root
fn get_git_repo_root(workspace_root: &Path) -> Option<String> {
    let output = Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .current_dir(workspace_root)
        .output()
        .ok()?;

    if output.status.success() {
        let root = String::from_utf8_lossy(&output.stdout).trim().to_string();
        Some(root)
    } else {
        None
    }
}

/// Get git status for a workspace
///
/// Uses `git status --porcelain=v1 -z` for stable parsing.
/// Also checks for staged changes using `git diff --cached --name-only`.
pub fn git_status(workspace_root: &Path) -> Result<GitStatusResult, GitError> {
    // Check if it's a git repo
    let repo_root = match get_git_repo_root(workspace_root) {
        Some(root) => root,
        None => {
            return Ok(GitStatusResult {
                repo_root: String::new(),
                items: vec![],
                has_staged_changes: false,
                staged_count: 0,
            });
        }
    };

    // Run git status
    let output = Command::new("git")
        .args(["status", "--porcelain=v1", "-z"])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(GitError::CommandFailed(stderr.to_string()));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let items = parse_porcelain_status(&stdout);

    // Check for staged changes
    let (has_staged_changes, staged_count) = check_staged_changes(workspace_root);

    Ok(GitStatusResult { repo_root, items, has_staged_changes, staged_count })
}

/// Parse git status --porcelain=v1 -z output
///
/// Format: XY PATH\0 or XY ORIG_PATH\0PATH\0 for renames
fn parse_porcelain_status(output: &str) -> Vec<GitStatusEntry> {
    let mut items = Vec::new();
    let parts: Vec<&str> = output.split('\0').collect();

    let mut i = 0;
    while i < parts.len() {
        let part = parts[i];
        if part.is_empty() {
            i += 1;
            continue;
        }

        if part.len() < 3 {
            i += 1;
            continue;
        }

        let xy = &part[0..2];
        let path = &part[3..];

        // Determine the status code
        let code = parse_status_code(xy);

        // Check for rename/copy (has original path in next entry)
        if (code == "R" || code == "C") && i + 1 < parts.len() && !parts[i + 1].is_empty() {
            // For renames: XY ORIG_PATH\0NEW_PATH\0
            // The path after XY is the original, next part is the new path
            let orig_path = path.to_string();
            let new_path = parts[i + 1].to_string();
            items.push(GitStatusEntry {
                path: new_path,
                code,
                orig_path: Some(orig_path),
            });
            i += 2;
        } else {
            items.push(GitStatusEntry {
                path: path.to_string(),
                code,
                orig_path: None,
            });
            i += 1;
        }
    }

    items
}

/// Parse XY status code to simplified code
fn parse_status_code(xy: &str) -> String {
    let x = xy.chars().next().unwrap_or(' ');
    let y = xy.chars().nth(1).unwrap_or(' ');

    // Prioritize index status, then worktree status
    match (x, y) {
        ('?', '?') => "??".to_string(),
        ('!', '!') => "!!".to_string(),
        ('R', _) | (_, 'R') => "R".to_string(),
        ('C', _) | (_, 'C') => "C".to_string(),
        ('A', _) | (_, 'A') => "A".to_string(),
        ('D', _) | (_, 'D') => "D".to_string(),
        ('M', _) | (_, 'M') => "M".to_string(),
        ('U', _) | (_, 'U') => "U".to_string(),
        _ => {
            // Return non-space character or M as fallback
            if x != ' ' { x.to_string() }
            else if y != ' ' { y.to_string() }
            else { "M".to_string() }
        }
    }
}

/// Get git diff for a specific file
///
/// For tracked files: `git diff -- <path>` (working) or `git diff --cached -- <path>` (staged)
/// For untracked files: `git diff --no-index /dev/null -- <path>`
pub fn git_diff(
    workspace_root: &Path,
    path: &str,
    _base: Option<&str>,
    mode: &str,  // "working" or "staged"
) -> Result<GitDiffResult, GitError> {
    // Validate path
    let _full_path = validate_path(workspace_root, path)?;

    // Check if it's a git repo
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    // Get status for this file to determine how to diff
    let status_result = git_status(workspace_root)?;
    let file_status = status_result
        .items
        .iter()
        .find(|item| item.path == path);

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

/// Check if a file is binary
fn check_binary(workspace_root: &Path, path: &str) -> bool {
    let output = Command::new("git")
        .args(["diff", "--numstat", "--", path])
        .current_dir(workspace_root)
        .output();

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            // Binary files show as "-\t-\t" in numstat
            stdout.starts_with("-\t-\t")
        }
        Err(_) => false,
    }
}

/// Get diff for tracked file
fn get_tracked_diff(workspace_root: &Path, path: &str, mode: &str) -> Result<(String, bool), GitError> {
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

/// Truncate text if it exceeds MAX_DIFF_SIZE
fn truncate_if_needed(text: &str) -> (String, bool) {
    if text.len() > MAX_DIFF_SIZE {
        // Find a good break point (end of line)
        let truncated_text = &text[..MAX_DIFF_SIZE];
        if let Some(last_newline) = truncated_text.rfind('\n') {
            (truncated_text[..=last_newline].to_string(), true)
        } else {
            (truncated_text.to_string(), true)
        }
    } else {
        (text.to_string(), false)
    }
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
        let p = path.ok_or_else(|| GitError::CommandFailed("Path required for file scope".to_string()))?;
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
            message: Some(if stderr.is_empty() { "Stage failed".to_string() } else { stderr }),
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
        let p = path.ok_or_else(|| GitError::CommandFailed("Path required for file scope".to_string()))?;
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
        Ok(output) if output.status.success() => {
            return Ok(GitOpResult {
                op: "unstage".to_string(),
                ok: true,
                message: None,
                path: path_str,
                scope: scope.to_string(),
            });
        }
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
                Ok(output) if output.status.success() => {
                    Ok(GitOpResult {
                        op: "unstage".to_string(),
                        ok: true,
                        message: None,
                        path: path_str,
                        scope: scope.to_string(),
                    })
                }
                Ok(output) => {
                    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
                    Ok(GitOpResult {
                        op: "unstage".to_string(),
                        ok: false,
                        message: Some(if stderr.is_empty() { "Unstage failed".to_string() } else { stderr }),
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
                message: Some(if stderr.is_empty() { "Discard failed".to_string() } else { stderr }),
                path: None,
                scope: scope.to_string(),
            })
        }
    } else {
        // Single file discard
        let p = path.ok_or_else(|| GitError::CommandFailed("Path required for file scope".to_string()))?;
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
                    message: Some(if stderr.is_empty() { "Failed to delete file".to_string() } else { stderr }),
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
                    message: Some(if stderr.is_empty() { "Discard failed".to_string() } else { stderr }),
                    path: Some(p.to_string()),
                    scope: scope.to_string(),
                })
            }
        }
    }
}

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
        String::from_utf8_lossy(&current_output.stdout).trim().to_string()
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
        let stderr = String::from_utf8_lossy(&checkout_output.stderr).trim().to_string();
        Ok(GitOpResult {
            op: "switch_branch".to_string(),
            ok: false,
            message: Some(if stderr.is_empty() { "Switch failed".to_string() } else { stderr }),
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
        let stderr = String::from_utf8_lossy(&checkout_output.stderr).trim().to_string();
        Ok(GitOpResult {
            op: "create_branch".to_string(),
            ok: false,
            message: Some(if stderr.is_empty() { "Create branch failed".to_string() } else { stderr }),
            path: Some(branch.to_string()),
            scope: "branch".to_string(),
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
        // Get the short SHA of the new commit
        let sha = get_short_head_sha(workspace_root);
        Ok(GitCommitResult {
            ok: true,
            message: Some(format!("Committed: {}", sha.as_deref().unwrap_or("unknown"))),
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

/// Get the short SHA of HEAD
fn get_short_head_sha(workspace_root: &Path) -> Option<String> {
    let output = Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .current_dir(workspace_root)
        .output()
        .ok()?;

    if output.status.success() {
        Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
    } else {
        None
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
            message: Some(if stderr.is_empty() { "Fetch failed".to_string() } else { stderr }),
            path: None,
            scope: "all".to_string(),
        })
    }
}

/// Check if currently in a rebase state
fn is_rebasing(workspace_root: &Path) -> bool {
    // Check for rebase-merge directory (interactive rebase)
    let rebase_merge = workspace_root.join(".git/rebase-merge");
    if rebase_merge.exists() {
        return true;
    }

    // Check for rebase-apply directory (am-style rebase)
    let rebase_apply = workspace_root.join(".git/rebase-apply");
    if rebase_apply.exists() {
        return true;
    }

    // Also check via git command for worktrees
    let output = Command::new("git")
        .args(["rev-parse", "--git-path", "rebase-merge"])
        .current_dir(workspace_root)
        .output();

    if let Ok(out) = output {
        let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !path.is_empty() && std::path::Path::new(&path).exists() {
            return true;
        }
    }

    false
}

/// Check if currently in a merge state
fn is_merging(workspace_root: &Path) -> bool {
    let merge_head = workspace_root.join(".git/MERGE_HEAD");
    if merge_head.exists() {
        return true;
    }

    // Check via git command for worktrees
    let output = Command::new("git")
        .args(["rev-parse", "--git-path", "MERGE_HEAD"])
        .current_dir(workspace_root)
        .output();

    if let Ok(out) = output {
        let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !path.is_empty() && std::path::Path::new(&path).exists() {
            return true;
        }
    }

    false
}

/// Get list of conflicted files
fn get_conflict_files(workspace_root: &Path) -> Vec<String> {
    let output = Command::new("git")
        .args(["diff", "--name-only", "--diff-filter=U"])
        .current_dir(workspace_root)
        .output();

    match output {
        Ok(out) if out.status.success() => {
            String::from_utf8_lossy(&out.stdout)
                .lines()
                .filter(|l| !l.is_empty())
                .map(|l| l.to_string())
                .collect()
        }
        _ => vec![],
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
        return Ok(GitRebaseResult {
            ok: false,
            state: "error".to_string(),
            message: Some("Already in a rebase. Use continue or abort.".to_string()),
            conflicts: get_conflict_files(workspace_root),
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
        })
    } else {
        // Check if we're now in a conflict state
        if is_rebasing(workspace_root) {
            let conflicts = get_conflict_files(workspace_root);
            Ok(GitRebaseResult {
                ok: false,
                state: "conflict".to_string(),
                message: Some("Rebase paused due to conflicts".to_string()),
                conflicts,
            })
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            Ok(GitRebaseResult {
                ok: false,
                state: "error".to_string(),
                message: Some(if stderr.is_empty() { "Rebase failed".to_string() } else { stderr }),
                conflicts: vec![],
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
                })
            } else {
                Ok(GitRebaseResult {
                    ok: false,
                    state: "conflict".to_string(),
                    message: Some("More conflicts to resolve".to_string()),
                    conflicts,
                })
            }
        } else {
            Ok(GitRebaseResult {
                ok: true,
                state: "completed".to_string(),
                message: Some("Rebase completed".to_string()),
                conflicts: vec![],
            })
        }
    } else {
        // Check if still in conflict
        let conflicts = get_conflict_files(workspace_root);
        if !conflicts.is_empty() {
            Ok(GitRebaseResult {
                ok: false,
                state: "conflict".to_string(),
                message: Some("Conflicts remain. Resolve and stage files before continuing.".to_string()),
                conflicts,
            })
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            Ok(GitRebaseResult {
                ok: false,
                state: "error".to_string(),
                message: Some(if stderr.is_empty() { "Continue failed".to_string() } else { stderr }),
                conflicts: vec![],
            })
        }
    }
}

/// Git rebase abort (workspace_root: &Path) -> Result<GitRebaseResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    if !is_rebasing(workspace_root) {
        return Ok(GitRebaseResult {
            ok: false,
            state: "error".to_string(),
            message: Some("No rebase in progress".to_string()),
            conflicts: vec![],
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
        })
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Ok(GitRebaseResult {
            ok: false,
            state: "error".to_string(),
            message: Some(if stderr.is_empty() { "Abort failed".to_string() } else { stderr }),
            conflicts: vec![],
        })
    }
}

// ============================================================================
// v1.12: Integration Worktree for Safe Merge to Default (UX-3b)
// ============================================================================

/// Integration worktree state
#[derive(Debug, Clone, PartialEq)]
pub enum IntegrationState {
    Idle,
    Merging,
    Conflict,
}

impl IntegrationState {
    pub fn as_str(&self) -> &'static str {
        match self {
            IntegrationState::Idle => "idle",
            IntegrationState::Merging => "merging",
            IntegrationState::Conflict => "conflict",
        }
    }
}

/// Integration worktree status result
#[derive(Debug)]
pub struct IntegrationStatusResult {
    pub state: IntegrationState,
    pub conflicts: Vec<String>,
    pub head: Option<String>,
    pub default_branch: String,
    pub path: String,
    pub is_clean: bool,
}

/// Merge to default result
#[derive(Debug)]
pub struct MergeToDefaultResult {
    pub ok: bool,
    pub state: String,  // "idle", "merging", "conflict", "completed", "failed"
    pub message: Option<String>,
    pub conflicts: Vec<String>,
    pub head_sha: Option<String>,
    pub integration_path: Option<String>,
}

/// Get the integration worktree path for a project
fn get_integration_worktree_path(project_name: &str) -> PathBuf {
    // Sanitize project name (alphanumeric + hyphen only)
    let sanitized: String = project_name
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '-' { c } else { '-' })
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

/// Check if integration worktree is clean (no uncommitted changes, no merge in progress)
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
    !is_merging(path)
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
                "Integration worktree is not clean. Abort or clean up first.".to_string()
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
            if stderr.is_empty() { "Unknown error" } else { &stderr }
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
        });
    }

    let state = if is_merging(&integration_path) {
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
    let integration_path_str = ensure_integration_worktree(repo_root, project_name, default_branch)?;
    let integration_path = PathBuf::from(&integration_path_str);

    // Verify source branch exists
    let show_ref_output = Command::new("git")
        .args(["show-ref", "--verify", &format!("refs/heads/{}", source_branch)])
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
            let stderr = String::from_utf8_lossy(&merge_output.stderr).trim().to_string();
            Ok(MergeToDefaultResult {
                ok: false,
                state: "failed".to_string(),
                message: Some(if stderr.is_empty() { "Merge failed".to_string() } else { stderr }),
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
            message: Some("Conflicts remain. Resolve and stage files before continuing.".to_string()),
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
        let stderr = String::from_utf8_lossy(&add_output.stderr).trim().to_string();
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
        let stderr = String::from_utf8_lossy(&commit_output.stderr).trim().to_string();
        // Check if still in merge state (might have more conflicts)
        if is_merging(&integration_path) {
            let conflicts = get_conflict_files(&integration_path);
            Ok(MergeToDefaultResult {
                ok: false,
                state: "conflict".to_string(),
                message: Some(if stderr.is_empty() { "More conflicts to resolve".to_string() } else { stderr }),
                conflicts,
                head_sha: None,
                integration_path: Some(integration_path.to_string_lossy().to_string()),
            })
        } else {
            Ok(MergeToDefaultResult {
                ok: false,
                state: "failed".to_string(),
                message: Some(if stderr.is_empty() { "Commit failed".to_string() } else { stderr }),
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
            message: Some(if stderr.is_empty() { "Abort failed".to_string() } else { stderr }),
            conflicts: vec![],
            head_sha: None,
            integration_path: Some(integration_path.to_string_lossy().to_string()),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_status_code() {
        assert_eq!(parse_status_code("??"), "??");
        assert_eq!(parse_status_code(" M"), "M");
        assert_eq!(parse_status_code("M "), "M");
        assert_eq!(parse_status_code("MM"), "M");
        assert_eq!(parse_status_code("A "), "A");
        assert_eq!(parse_status_code(" A"), "A");
        assert_eq!(parse_status_code("D "), "D");
        assert_eq!(parse_status_code("R "), "R");
    }

    #[test]
    fn test_parse_porcelain_status() {
        // Simple modified file
        let output = " M src/main.rs\0";
        let items = parse_porcelain_status(output);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].path, "src/main.rs");
        assert_eq!(items[0].code, "M");

        // Untracked file
        let output = "?? new-file.txt\0";
        let items = parse_porcelain_status(output);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].path, "new-file.txt");
        assert_eq!(items[0].code, "??");
    }

    #[test]
    fn test_truncate_if_needed() {
        let short_text = "short text";
        let (result, truncated) = truncate_if_needed(short_text);
        assert_eq!(result, short_text);
        assert!(!truncated);
    }
}
