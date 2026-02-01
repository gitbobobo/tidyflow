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
pub fn git_status(workspace_root: &Path) -> Result<GitStatusResult, GitError> {
    // Check if it's a git repo
    let repo_root = match get_git_repo_root(workspace_root) {
        Some(root) => root,
        None => {
            return Ok(GitStatusResult {
                repo_root: String::new(),
                items: vec![],
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

    Ok(GitStatusResult { repo_root, items })
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
