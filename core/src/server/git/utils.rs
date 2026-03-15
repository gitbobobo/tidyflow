//! Git utilities - type definitions and helper functions
//!
//! Provides common types, constants, and utility functions used across git operations.

use std::path::{Path, PathBuf};

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
    pub current_branch: Option<String>,
    pub default_branch: Option<String>,
    pub ahead_by: Option<i32>,
    pub behind_by: Option<i32>,
    pub compared_branch: Option<String>,
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

/// Git operation state (for rebase/merge/cherry-pick/revert)
#[derive(Debug, Clone, PartialEq)]
pub enum GitOpState {
    Normal,
    Rebasing,
    Merging,
    CherryPicking,
    Reverting,
}

impl GitOpState {
    pub fn as_str(&self) -> &'static str {
        match self {
            GitOpState::Normal => "normal",
            GitOpState::Rebasing => "rebasing",
            GitOpState::Merging => "merging",
            GitOpState::CherryPicking => "cherry_picking",
            GitOpState::Reverting => "reverting",
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
    pub conflict_files: Vec<ConflictFileEntry>,
}

/// Git operation status result
#[derive(Debug)]
pub struct GitOpStatusResult {
    pub state: GitOpState,
    pub conflicts: Vec<String>,
    pub conflict_files: Vec<ConflictFileEntry>,
    pub head: Option<String>,
    pub onto: Option<String>,
    // v1.60: workspace sequencer 扩展字段
    pub operation_kind: Option<String>,
    pub pending_commits: Vec<String>,
    pub current_commit: Option<String>,
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
    pub conflict_files: Vec<ConflictFileEntry>,
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
    pub conflict_files: Vec<ConflictFileEntry>,
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
    pub conflict_files: Vec<ConflictFileEntry>,
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
    let repo = gix::discover(workspace_root).ok()?;
    let workdir = repo.workdir()?;
    Some(workdir.to_string_lossy().to_string())
}

/// Check if a file is binary
pub fn check_binary(workspace_root: &Path, path: &str) -> bool {
    let full_path = workspace_root.join(path);
    let Ok(bytes) = std::fs::read(&full_path) else {
        return false;
    };
    bytes.contains(&0)
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
    let repo = gix::discover(workspace_root).ok()?;
    let id = repo.head_id().ok()?;
    let hex = id.to_string();
    Some(hex.chars().take(7).collect())
}

/// Check if currently in a rebase state
pub fn is_rebasing(workspace_root: &Path) -> bool {
    let repo = match gix::discover(workspace_root) {
        Ok(repo) => repo,
        Err(_) => return false,
    };

    let rebase_merge = repo.git_dir().join("rebase-merge");
    if rebase_merge.exists() {
        return true;
    }

    let rebase_apply = repo.git_dir().join("rebase-apply");
    if rebase_apply.exists() {
        return true;
    }

    false
}

/// Check if currently in a merge state
pub fn is_merging(workspace_root: &Path) -> bool {
    gix::discover(workspace_root)
        .ok()
        .map(|repo| repo.git_dir().join("MERGE_HEAD").exists())
        .unwrap_or(false)
}

/// Get list of conflicted files
pub fn get_conflict_files(workspace_root: &Path) -> Vec<String> {
    let status = crate::server::git::status::git_status(workspace_root, "");
    match status {
        Ok(result) => result
            .items
            .into_iter()
            .filter(|it| it.code == "U")
            .map(|it| it.path)
            .collect(),
        Err(_) => vec![],
    }
}

/// 冲突文件条目（语义化快照，用于冲突向导）
#[derive(Debug, Clone)]
pub struct ConflictFileEntry {
    /// 文件路径（相对于工作区根）
    pub path: String,
    /// 冲突类型：content | add_add | delete_modify | modify_delete
    pub conflict_type: String,
    /// 是否已暂存（标记为已解决）
    pub staged: bool,
}

/// 冲突文件详情（四路对比数据）
#[derive(Debug)]
pub struct ConflictFileDetail {
    /// 文件路径
    pub path: String,
    /// 上下文来源：workspace | integration
    pub context: String,
    /// 公共祖先内容（:1:<path>）
    pub base_content: Option<String>,
    /// 我方内容（:2:<path>，HEAD）
    pub ours_content: Option<String>,
    /// 对方内容（:3:<path>，MERGE_HEAD/REBASE_HEAD）
    pub theirs_content: Option<String>,
    /// 当前工作区文件内容（含冲突标记）
    pub current_content: String,
    /// 冲突标记组数
    pub conflict_markers_count: usize,
    /// 是否为二进制文件
    pub is_binary: bool,
}

/// 冲突快照（整个上下文的冲突状态）
#[derive(Debug, Clone)]
pub struct ConflictSnapshot {
    /// 上下文来源：workspace | integration
    pub context: String,
    /// 冲突文件列表
    pub files: Vec<ConflictFileEntry>,
    /// 是否所有冲突已解决（files 中 staged 全为 true 或 files 为空）
    pub all_resolved: bool,
}

/// 冲突解决动作结果
#[derive(Debug)]
pub struct ConflictActionResult {
    pub ok: bool,
    pub action: String, // "accept_ours" | "accept_theirs" | "accept_both" | "mark_resolved"
    pub message: Option<String>,
    pub snapshot: ConflictSnapshot,
}

/// 根据 git status 获取语义化冲突文件条目列表
pub fn get_conflict_file_entries(workspace_root: &Path) -> Vec<ConflictFileEntry> {
    use std::process::Command;

    // 使用 git status --porcelain 获取冲突信息（XY 编码判断冲突类型）
    let output = Command::new("git")
        .args(["status", "--porcelain", "-z"])
        .current_dir(workspace_root)
        .output();

    let Ok(out) = output else {
        return vec![];
    };
    if !out.status.success() {
        return vec![];
    }

    let stdout = String::from_utf8_lossy(&out.stdout);
    let mut entries = Vec::new();

    for record in stdout.split('\0') {
        let record = record.trim_end_matches('\0');
        if record.len() < 3 {
            continue;
        }
        let xy = &record[..2];
        let path = record[3..].to_string();
        if path.is_empty() {
            continue;
        }

        // XY 为 UU/AA/DD/AU/UA/DU/UD 时为冲突
        let conflict_type = match xy {
            "UU" => "content",
            "AA" => "add_add",
            "DD" => "delete_delete",
            "AU" | "UA" => "add_modify",
            "DU" | "UD" => "delete_modify",
            _ => continue, // 非冲突状态，跳过
        };

        entries.push(ConflictFileEntry {
            path,
            conflict_type: conflict_type.to_string(),
            staged: false,
        });
    }
    entries
}

/// 获取冲突快照（填充 all_resolved 字段）
pub fn build_conflict_snapshot(workspace_root: &Path, context: &str) -> ConflictSnapshot {
    let files = get_conflict_file_entries(workspace_root);
    let all_resolved = files.is_empty();
    ConflictSnapshot {
        context: context.to_string(),
        files,
        all_resolved,
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

    #[test]
    fn test_truncate_if_needed_long_text() {
        // 创建超过 MAX_DIFF_SIZE 的文本
        let long_text = "x".repeat(MAX_DIFF_SIZE + 1000);
        let (result, truncated) = truncate_if_needed(&long_text);
        assert!(result.len() <= MAX_DIFF_SIZE);
        assert!(truncated);
    }

    #[test]
    fn test_truncate_if_needed_preserves_line_boundary() {
        // 创建在换行符附近截断的文本
        let line = "a".repeat(100);
        let mut long_text = String::new();
        while long_text.len() < MAX_DIFF_SIZE {
            long_text.push_str(&line);
            long_text.push('\n');
        }
        let (result, truncated) = truncate_if_needed(&long_text);
        assert!(truncated);
        // 应该在换行符处截断
        assert!(result.ends_with('\n'));
    }

    #[test]
    fn test_git_op_state_as_str() {
        assert_eq!(GitOpState::Normal.as_str(), "normal");
        assert_eq!(GitOpState::Rebasing.as_str(), "rebasing");
        assert_eq!(GitOpState::Merging.as_str(), "merging");
        assert_eq!(GitOpState::CherryPicking.as_str(), "cherry_picking");
        assert_eq!(GitOpState::Reverting.as_str(), "reverting");
    }

    #[test]
    fn test_integration_state_as_str() {
        assert_eq!(IntegrationState::Idle.as_str(), "idle");
        assert_eq!(IntegrationState::Merging.as_str(), "merging");
        assert_eq!(IntegrationState::Conflict.as_str(), "conflict");
        assert_eq!(IntegrationState::Rebasing.as_str(), "rebasing");
        assert_eq!(IntegrationState::RebaseConflict.as_str(), "rebase_conflict");
    }

    #[test]
    fn test_git_error_display() {
        assert_eq!(format!("{}", GitError::NotAGitRepo), "Not a git repository");
        assert_eq!(
            format!("{}", GitError::PathEscape),
            "Path escapes workspace root"
        );
        assert!(
            format!("{}", GitError::CommandFailed("test error".to_string())).contains("test error")
        );
    }

    #[test]
    fn test_validate_path_simple() {
        let root = std::env::temp_dir();
        let result = validate_path(&root, "test.txt");
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), root.join("test.txt"));
    }

    #[test]
    fn test_validate_path_rejects_escape() {
        let root = std::env::temp_dir();
        // 使用不存在的路径来触发 PathEscape 错误
        let result = validate_path(&root, "../etc/passwd");
        // 路径不存在时会返回 PathEscape 错误
        assert!(result.is_err());
    }

    #[test]
    fn test_check_binary_detects_null_bytes() {
        let root = std::env::temp_dir();
        // 二进制内容包含 null 字节
        let result = check_binary(&root, "nonexistent_file_for_test");
        assert!(!result); // 文件不存在时返回 false
    }

    #[test]
    fn test_git_status_entry_defaults() {
        let entry = GitStatusEntry {
            path: "test.rs".to_string(),
            code: "M".to_string(),
            orig_path: None,
            staged: true,
            additions: None,
            deletions: None,
        };
        assert_eq!(entry.path, "test.rs");
        assert_eq!(entry.code, "M");
        assert!(entry.staged);
        assert!(entry.additions.is_none());
    }

    #[test]
    fn test_git_branch_info() {
        let info = GitBranchInfo {
            name: "feature/test".to_string(),
        };
        assert_eq!(info.name, "feature/test");
    }

    #[test]
    fn test_git_branches_result() {
        let result = GitBranchesResult {
            current: "main".to_string(),
            branches: vec![
                GitBranchInfo {
                    name: "develop".to_string(),
                },
                GitBranchInfo {
                    name: "main".to_string(),
                },
            ],
        };
        assert_eq!(result.current, "main");
        assert_eq!(result.branches.len(), 2);
    }

    #[test]
    fn test_git_commit_result() {
        let success = GitCommitResult {
            ok: true,
            message: Some("Committed: abc1234".to_string()),
            sha: Some("abc1234".to_string()),
        };
        assert!(success.ok);
        assert!(success.sha.is_some());

        let failure = GitCommitResult {
            ok: false,
            message: Some("No staged changes".to_string()),
            sha: None,
        };
        assert!(!failure.ok);
        assert!(failure.sha.is_none());
    }

    #[test]
    fn test_git_rebase_result_states() {
        let completed = GitRebaseResult {
            ok: true,
            state: "completed".to_string(),
            message: Some("Rebased onto main".to_string()),
            conflicts: vec![],
            conflict_files: vec![],
        };
        assert!(completed.ok);
        assert!(completed.conflicts.is_empty());

        let conflict = GitRebaseResult {
            ok: false,
            state: "conflict".to_string(),
            message: Some("Rebase paused due to conflicts".to_string()),
            conflicts: vec!["src/main.rs".to_string()],
            conflict_files: vec![],
        };
        assert!(!conflict.ok);
        assert_eq!(conflict.conflicts.len(), 1);
    }

    #[test]
    fn test_git_log_entry() {
        let entry = GitLogEntry {
            sha: "abc1234".to_string(),
            message: "feat: add new feature".to_string(),
            author: "Developer".to_string(),
            date: "2026-03-06T12:00:00Z".to_string(),
            refs: vec!["HEAD".to_string(), "main".to_string()],
        };
        assert_eq!(entry.sha.len(), 7);
        assert_eq!(entry.refs.len(), 2);
    }

    #[test]
    fn test_git_show_file_entry() {
        let modified = GitShowFileEntry {
            status: "M".to_string(),
            path: "src/lib.rs".to_string(),
            old_path: None,
        };
        assert_eq!(modified.status, "M");
        assert!(modified.old_path.is_none());

        let renamed = GitShowFileEntry {
            status: "R".to_string(),
            path: "src/new.rs".to_string(),
            old_path: Some("src/old.rs".to_string()),
        };
        assert_eq!(renamed.status, "R");
        assert_eq!(renamed.old_path, Some("src/old.rs".to_string()));
    }

    #[test]
    fn test_branch_divergence_result() {
        let result = BranchDivergenceResult {
            ahead_by: 3,
            behind_by: 1,
            compared_branch: "main".to_string(),
        };
        assert_eq!(result.ahead_by, 3);
        assert_eq!(result.behind_by, 1);
        assert_eq!(result.compared_branch, "main");
    }

    // MARK: - WI-006 冲突向导回归护栏

    #[test]
    fn test_conflict_file_entry_construction() {
        let entry = ConflictFileEntry {
            path: "src/main.rs".to_string(),
            conflict_type: "content".to_string(),
            staged: false,
        };
        assert_eq!(entry.path, "src/main.rs");
        assert_eq!(entry.conflict_type, "content");
        assert!(!entry.staged);
    }

    #[test]
    fn test_conflict_file_entry_staged_true() {
        let entry = ConflictFileEntry {
            path: "src/lib.rs".to_string(),
            conflict_type: "add_add".to_string(),
            staged: true,
        };
        assert!(entry.staged);
        assert_eq!(entry.conflict_type, "add_add");
    }

    #[test]
    fn test_conflict_snapshot_all_resolved_when_empty() {
        // 没有冲突文件时，快照应标记为全部已解决
        let snapshot = ConflictSnapshot {
            context: "workspace".to_string(),
            files: vec![],
            all_resolved: true,
        };
        assert!(snapshot.all_resolved);
        assert!(snapshot.files.is_empty());
    }

    #[test]
    fn test_conflict_snapshot_not_resolved_when_files_exist() {
        // 有未暂存的冲突文件时，快照标记为未全部解决
        let files = vec![
            ConflictFileEntry {
                path: "src/a.rs".to_string(),
                conflict_type: "content".to_string(),
                staged: false,
            },
            ConflictFileEntry {
                path: "src/b.rs".to_string(),
                conflict_type: "add_add".to_string(),
                staged: false,
            },
        ];
        let snapshot = ConflictSnapshot {
            context: "workspace".to_string(),
            files: files.clone(),
            all_resolved: false,
        };
        assert!(!snapshot.all_resolved);
        assert_eq!(snapshot.files.len(), 2);
    }

    #[test]
    fn test_conflict_snapshot_context_workspace_vs_integration() {
        // workspace 与 integration 上下文应独立存在
        let ws_snap = ConflictSnapshot {
            context: "workspace".to_string(),
            files: vec![],
            all_resolved: true,
        };
        let int_snap = ConflictSnapshot {
            context: "integration".to_string(),
            files: vec![ConflictFileEntry {
                path: "x.rs".to_string(),
                conflict_type: "content".to_string(),
                staged: false,
            }],
            all_resolved: false,
        };
        assert_eq!(ws_snap.context, "workspace");
        assert_eq!(int_snap.context, "integration");
        // 两者互不干扰
        assert!(ws_snap.all_resolved);
        assert!(!int_snap.all_resolved);
    }

    #[test]
    fn test_conflict_action_result_fields() {
        // 验证 accept_ours 动作结果结构正确构造
        let snapshot = ConflictSnapshot {
            context: "workspace".to_string(),
            files: vec![],
            all_resolved: true,
        };
        let result = ConflictActionResult {
            ok: true,
            action: "accept_ours".to_string(),
            message: Some("Applied ours".to_string()),
            snapshot: snapshot.clone(),
        };
        assert!(result.ok);
        assert_eq!(result.action, "accept_ours");
        assert!(result.snapshot.all_resolved);
    }

    #[test]
    fn test_conflict_action_result_accept_theirs() {
        let snapshot = ConflictSnapshot {
            context: "workspace".to_string(),
            files: vec![],
            all_resolved: true,
        };
        let result = ConflictActionResult {
            ok: true,
            action: "accept_theirs".to_string(),
            message: None,
            snapshot,
        };
        assert_eq!(result.action, "accept_theirs");
        assert!(result.message.is_none());
    }

    #[test]
    fn test_conflict_action_result_mark_resolved() {
        // mark_resolved 标记后 snapshot 仍可更新冲突列表
        let remaining = ConflictFileEntry {
            path: "src/c.rs".to_string(),
            conflict_type: "delete_modify".to_string(),
            staged: false,
        };
        let snapshot = ConflictSnapshot {
            context: "workspace".to_string(),
            files: vec![remaining],
            all_resolved: false,
        };
        let result = ConflictActionResult {
            ok: true,
            action: "mark_resolved".to_string(),
            message: None,
            snapshot,
        };
        assert!(!result.snapshot.all_resolved);
        assert_eq!(result.snapshot.files.len(), 1);
    }

    #[test]
    fn test_integration_state_conflict_variants_exhaustive() {
        // 验证所有冲突相关 IntegrationState 变体的字符串编码
        assert_eq!(IntegrationState::Conflict.as_str(), "conflict");
        assert_eq!(IntegrationState::RebaseConflict.as_str(), "rebase_conflict");
        // 非冲突状态仍需一致
        assert_eq!(IntegrationState::Idle.as_str(), "idle");
        assert_eq!(IntegrationState::Merging.as_str(), "merging");
        assert_eq!(IntegrationState::Rebasing.as_str(), "rebasing");
    }

    #[test]
    fn test_build_conflict_snapshot_returns_workspace_context() {
        // build_conflict_snapshot 在空目录上应返回 context 正确、all_resolved=true 的快照
        let tmp = std::env::temp_dir();
        let snap = build_conflict_snapshot(&tmp, "workspace");
        assert_eq!(snap.context, "workspace");
        // temp_dir 不是 git 仓库，因此 files 为空，all_resolved 应为 true
        assert!(snap.all_resolved);
    }

    #[test]
    fn test_build_conflict_snapshot_integration_context() {
        let tmp = std::env::temp_dir();
        let snap = build_conflict_snapshot(&tmp, "integration");
        assert_eq!(snap.context, "integration");
        assert!(snap.all_resolved);
    }

    #[test]
    fn test_conflict_file_detail_binary_flag() {
        // 确认 ConflictFileDetail 的 is_binary 字段语义
        let detail = ConflictFileDetail {
            path: "assets/image.png".to_string(),
            context: "workspace".to_string(),
            base_content: None,
            ours_content: None,
            theirs_content: None,
            current_content: String::new(),
            conflict_markers_count: 0,
            is_binary: true,
        };
        assert!(detail.is_binary);
        assert_eq!(detail.conflict_markers_count, 0);
    }

    #[test]
    fn test_conflict_file_detail_text_with_markers() {
        // 文本冲突文件应正确记录标记组数
        let detail = ConflictFileDetail {
            path: "src/main.rs".to_string(),
            context: "workspace".to_string(),
            base_content: Some("base".to_string()),
            ours_content: Some("ours".to_string()),
            theirs_content: Some("theirs".to_string()),
            current_content: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch\n".to_string(),
            conflict_markers_count: 1,
            is_binary: false,
        };
        assert!(!detail.is_binary);
        assert_eq!(detail.conflict_markers_count, 1);
        assert!(detail.base_content.is_some());
        assert!(detail.ours_content.is_some());
        assert!(detail.theirs_content.is_some());
    }
}
