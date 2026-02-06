//! Git utilities - type definitions and helper functions
//!
//! Provides common types, constants, and utility functions used across git operations.

use std::path::{Path, PathBuf};
use std::process::Command;

/// Maximum diff size in bytes (1MB)
pub const MAX_DIFF_SIZE: usize = 1_048_576;

/// Git status entry (porcelain v1: X=index/staged, Y=worktree/unstaged)
#[derive(Debug, Clone)]
pub struct GitStatusEntry {
    pub path: String,
    pub code: String,
    pub orig_path: Option<String>,
    /// 是否有暂存区变更（X != ' '）
    pub staged: bool,
    /// 新增行数（None = 二进制文件或新文件）
    pub additions: Option<i32>,
    /// 删除行数（None = 二进制文件或新文件）
    pub deletions: Option<i32>,
}

/// Git status result
#[derive(Debug, Clone)]
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
    pub state: String, // "completed", "conflict", "aborted", "error"
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

/// Git log entry (single commit)
#[derive(Debug, Clone)]
pub struct GitLogEntry {
    pub sha: String,       // 短 SHA (7字符)
    pub message: String,   // 提交消息（首行）
    pub author: String,    // 作者名
    pub date: String,      // ISO 日期
    pub refs: Vec<String>, // HEAD, branch, tag 等引用
}

/// Git log result
#[derive(Debug)]
pub struct GitLogResult {
    pub entries: Vec<GitLogEntry>,
}

/// Git show 文件变更条目
#[derive(Debug, Clone)]
pub struct GitShowFileEntry {
    pub status: String,           // "M", "A", "D", "R" 等
    pub path: String,             // 文件路径
    pub old_path: Option<String>, // 重命名时的原路径
}

/// Git show 结果（单个 commit 详情）
#[derive(Debug)]
pub struct GitShowResult {
    pub sha: String,
    pub full_sha: String,
    pub message: String, // 完整提交消息（含正文）
    pub author: String,
    pub author_email: String,
    pub date: String,
    pub files: Vec<GitShowFileEntry>,
}

/// Integration worktree state
#[derive(Debug, Clone, PartialEq)]
pub enum IntegrationState {
    Idle,
    Merging,
    Conflict,       // Merge conflict
    Rebasing,       // UX-4: Rebase in progress (no conflicts yet)
    RebaseConflict, // UX-4: Rebase paused due to conflicts
}

impl IntegrationState {
    pub fn as_str(&self) -> &'static str {
        match self {
            IntegrationState::Idle => "idle",
            IntegrationState::Merging => "merging",
            IntegrationState::Conflict => "conflict",
            IntegrationState::Rebasing => "rebasing",
            IntegrationState::RebaseConflict => "rebase_conflict",
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
    // v1.15: Branch divergence info (UX-6)
    pub branch_ahead_by: Option<i32>,
    pub branch_behind_by: Option<i32>,
    pub compared_branch: Option<String>,
}

/// v1.15: Branch divergence result (UX-6)
#[derive(Debug)]
pub struct BranchDivergenceResult {
    pub ahead_by: i32,
    pub behind_by: i32,
    pub compared_branch: String,
}

/// Merge to default result
#[derive(Debug)]
pub struct MergeToDefaultResult {
    pub ok: bool,
    pub state: String, // "idle", "merging", "conflict", "completed", "failed"
    pub message: Option<String>,
    pub conflicts: Vec<String>,
    pub head_sha: Option<String>,
    pub integration_path: Option<String>,
}

/// UX-4: Rebase onto default result
#[derive(Debug)]
pub struct RebaseOntoDefaultResult {
    pub ok: bool,
    pub state: String, // "idle", "rebasing", "rebase_conflict", "completed", "failed"
    pub message: Option<String>,
    pub conflicts: Vec<String>,
    pub head_sha: Option<String>,
    pub integration_path: Option<String>,
}

/// UX-5: Reset integration worktree result
#[derive(Debug)]
pub struct ResetIntegrationWorktreeResult {
    pub ok: bool,
    pub message: Option<String>,
    pub path: Option<String>,
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
pub fn validate_path(workspace_root: &Path, path: &str) -> Result<PathBuf, GitError> {
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
pub fn get_git_repo_root(workspace_root: &Path) -> Option<String> {
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

/// Check if a file is binary
pub fn check_binary(workspace_root: &Path, path: &str) -> bool {
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

/// Truncate text if it exceeds MAX_DIFF_SIZE
pub fn truncate_if_needed(text: &str) -> (String, bool) {
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

/// Get the short SHA of HEAD
pub fn get_short_head_sha(workspace_root: &Path) -> Option<String> {
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

/// Check if currently in a rebase state
pub fn is_rebasing(workspace_root: &Path) -> bool {
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
pub fn is_merging(workspace_root: &Path) -> bool {
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
pub fn get_conflict_files(workspace_root: &Path) -> Vec<String> {
    let output = Command::new("git")
        .args(["diff", "--name-only", "--diff-filter=U"])
        .current_dir(workspace_root)
        .output();

    match output {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter(|l| !l.is_empty())
            .map(|l| l.to_string())
            .collect(),
        _ => vec![],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_truncate_if_needed() {
        let short_text = "short text";
        let (result, truncated) = truncate_if_needed(short_text);
        assert_eq!(result, short_text);
        assert!(!truncated);
    }
}
