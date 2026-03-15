//! Git 领域协议类型

use serde::{Deserialize, Serialize};

fn default_diff_mode() -> String {
    "working".to_string()
}
fn default_git_scope() -> String {
    "file".to_string()
}
fn default_git_log_limit() -> usize {
    50
}

/// Git 相关的客户端消息
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum GitRequest {
    GitStatus {
        project: String,
        workspace: String,
    },
    GitDiff {
        project: String,
        workspace: String,
        path: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        base: Option<String>,
        #[serde(default = "default_diff_mode")]
        mode: String,
    },
    GitStage {
        project: String,
        workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>,
        #[serde(default = "default_git_scope")]
        scope: String,
    },
    GitUnstage {
        project: String,
        workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>,
        #[serde(default = "default_git_scope")]
        scope: String,
    },
    GitDiscard {
        project: String,
        workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>,
        #[serde(default = "default_git_scope")]
        scope: String,
        #[serde(default)]
        include_untracked: bool,
    },
    GitBranches {
        project: String,
        workspace: String,
    },
    GitSwitchBranch {
        project: String,
        workspace: String,
        branch: String,
    },
    GitCreateBranch {
        project: String,
        workspace: String,
        branch: String,
    },
    GitCommit {
        project: String,
        workspace: String,
        message: String,
    },
    GitFetch {
        project: String,
        workspace: String,
    },
    GitRebase {
        project: String,
        workspace: String,
        onto_branch: String,
    },
    GitRebaseContinue {
        project: String,
        workspace: String,
    },
    GitRebaseAbort {
        project: String,
        workspace: String,
    },
    GitOpStatus {
        project: String,
        workspace: String,
    },
    GitEnsureIntegrationWorktree {
        project: String,
    },
    GitMergeToDefault {
        project: String,
        workspace: String,
        default_branch: String,
    },
    GitMergeContinue {
        project: String,
    },
    GitMergeAbort {
        project: String,
    },
    GitIntegrationStatus {
        project: String,
    },
    GitRebaseOntoDefault {
        project: String,
        workspace: String,
        default_branch: String,
    },
    GitRebaseOntoDefaultContinue {
        project: String,
    },
    GitRebaseOntoDefaultAbort {
        project: String,
    },
    GitResetIntegrationWorktree {
        project: String,
    },
    GitCheckBranchUpToDate {
        project: String,
        workspace: String,
    },
    GitLog {
        project: String,
        workspace: String,
        #[serde(default = "default_git_log_limit")]
        limit: usize,
    },
    GitShow {
        project: String,
        workspace: String,
        sha: String,
    },
    // v1.40: 冲突向导
    /// 读取单个冲突文件的四路对比内容
    GitConflictDetail {
        project: String,
        workspace: String,
        path: String,
        /// 上下文来源：workspace | integration
        context: String,
    },
    /// 接受我方版本并暂存
    GitConflictAcceptOurs {
        project: String,
        workspace: String,
        path: String,
        context: String,
    },
    /// 接受对方版本并暂存
    GitConflictAcceptTheirs {
        project: String,
        workspace: String,
        path: String,
        context: String,
    },
    /// 合并双方版本（ours 在前，theirs 在后）并暂存
    GitConflictAcceptBoth {
        project: String,
        workspace: String,
        path: String,
        context: String,
    },
    /// 手工编辑后标记已解决（git add）
    GitConflictMarkResolved {
        project: String,
        workspace: String,
        path: String,
        context: String,
    },

    // v1.50: Git stash 操作
    GitStashList {
        project: String,
        workspace: String,
    },
    GitStashShow {
        project: String,
        workspace: String,
        stash_id: String,
    },
    GitStashSave {
        project: String,
        workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(default)]
        include_untracked: bool,
        #[serde(default)]
        keep_index: bool,
        #[serde(default)]
        paths: Vec<String>,
    },
    GitStashApply {
        project: String,
        workspace: String,
        stash_id: String,
    },
    GitStashPop {
        project: String,
        workspace: String,
        stash_id: String,
    },
    GitStashDrop {
        project: String,
        workspace: String,
        stash_id: String,
    },
    GitStashRestorePaths {
        project: String,
        workspace: String,
        stash_id: String,
        paths: Vec<String>,
    },
}

/// Git 相关的服务端消息
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum GitResponse {
    GitStatusResult {
        project: String,
        workspace: String,
        repo_root: String,
        items: Vec<super::GitStatusEntry>,
        #[serde(default)]
        has_staged_changes: bool,
        #[serde(default)]
        staged_count: usize,
        #[serde(skip_serializing_if = "Option::is_none")]
        current_branch: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        default_branch: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        ahead_by: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        behind_by: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        compared_branch: Option<String>,
    },
    GitDiffResult {
        project: String,
        workspace: String,
        path: String,
        code: String,
        format: String,
        text: String,
        is_binary: bool,
        truncated: bool,
        mode: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        base: Option<String>,
    },
    GitOpResult {
        project: String,
        workspace: String,
        op: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>,
        scope: String,
    },
    GitBranchesResult {
        project: String,
        workspace: String,
        current: String,
        branches: Vec<super::GitBranchInfo>,
    },
    GitCommitResult {
        project: String,
        workspace: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        sha: Option<String>,
    },
    GitRebaseResult {
        project: String,
        workspace: String,
        ok: bool,
        state: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(default)]
        conflicts: Vec<String>,
        /// 语义化冲突文件列表（v1.40+）
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        conflict_files: Vec<super::ConflictFileEntryInfo>,
    },
    GitOpStatusResult {
        project: String,
        workspace: String,
        state: String,
        #[serde(default)]
        conflicts: Vec<String>,
        /// 语义化冲突文件列表（v1.40+）
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        conflict_files: Vec<super::ConflictFileEntryInfo>,
        #[serde(skip_serializing_if = "Option::is_none")]
        head: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        onto: Option<String>,
    },
    GitMergeToDefaultResult {
        project: String,
        ok: bool,
        state: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(default)]
        conflicts: Vec<String>,
        /// 语义化冲突文件列表（v1.40+）
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        conflict_files: Vec<super::ConflictFileEntryInfo>,
        #[serde(skip_serializing_if = "Option::is_none")]
        head_sha: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        integration_path: Option<String>,
    },
    GitIntegrationStatusResult {
        project: String,
        state: String,
        #[serde(default)]
        conflicts: Vec<String>,
        /// 语义化冲突文件列表（v1.40+）
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        conflict_files: Vec<super::ConflictFileEntryInfo>,
        #[serde(skip_serializing_if = "Option::is_none")]
        head: Option<String>,
        default_branch: String,
        path: String,
        is_clean: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        branch_ahead_by: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        branch_behind_by: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        compared_branch: Option<String>,
    },
    GitRebaseOntoDefaultResult {
        project: String,
        ok: bool,
        state: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(default)]
        conflicts: Vec<String>,
        /// 语义化冲突文件列表（v1.40+）
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        conflict_files: Vec<super::ConflictFileEntryInfo>,
        #[serde(skip_serializing_if = "Option::is_none")]
        head_sha: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        integration_path: Option<String>,
    },
    GitResetIntegrationWorktreeResult {
        project: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>,
    },
    GitLogResult {
        project: String,
        workspace: String,
        entries: Vec<super::GitLogEntryInfo>,
    },
    GitShowResult {
        project: String,
        workspace: String,
        sha: String,
        full_sha: String,
        message: String,
        author: String,
        author_email: String,
        date: String,
        files: Vec<super::GitShowFileInfo>,
    },
    GitStatusChanged {
        project: String,
        workspace: String,
    },
    // v1.40: 冲突向导响应
    /// 单文件冲突详情（四路对比内容）
    GitConflictDetailResult {
        project: String,
        workspace: String,
        /// 上下文来源：workspace | integration
        context: String,
        path: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        base_content: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        ours_content: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        theirs_content: Option<String>,
        current_content: String,
        conflict_markers_count: usize,
        is_binary: bool,
    },
    /// 冲突解决动作结果（含最新快照）
    GitConflictActionResult {
        project: String,
        workspace: String,
        context: String,
        path: String,
        /// 已执行的动作：accept_ours | accept_theirs | accept_both | mark_resolved
        action: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        /// 操作后的冲突快照
        snapshot: super::ConflictSnapshotInfo,
    },

    // v1.50: Git stash 结果
    GitStashListResult {
        project: String,
        workspace: String,
        entries: Vec<super::GitStashEntryInfo>,
    },
    GitStashShowResult {
        project: String,
        workspace: String,
        stash_id: String,
        entry: super::GitStashEntryInfo,
        files: Vec<super::GitStashFileInfo>,
        diff_text: String,
        is_binary_summary_truncated: bool,
    },
    GitStashOpResult {
        project: String,
        workspace: String,
        op: String,
        stash_id: String,
        ok: bool,
        state: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(default)]
        affected_paths: Vec<String>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        conflict_files: Vec<super::ConflictFileEntryInfo>,
    },
}
