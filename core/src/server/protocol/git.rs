//! Git 领域协议类型

use serde::{Deserialize, Serialize};

fn default_diff_mode() -> String { "working".to_string() }
fn default_git_scope() -> String { "file".to_string() }
fn default_git_log_limit() -> usize { 50 }

/// Git 相关的客户端消息
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum GitRequest {
    GitStatus { project: String, workspace: String },
    GitDiff {
        project: String, workspace: String, path: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        base: Option<String>,
        #[serde(default = "default_diff_mode")]
        mode: String,
    },
    GitStage {
        project: String, workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>,
        #[serde(default = "default_git_scope")]
        scope: String,
    },
    GitUnstage {
        project: String, workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>,
        #[serde(default = "default_git_scope")]
        scope: String,
    },
    GitDiscard {
        project: String, workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>,
        #[serde(default = "default_git_scope")]
        scope: String,
        #[serde(default)]
        include_untracked: bool,
    },
    GitBranches { project: String, workspace: String },
    GitSwitchBranch { project: String, workspace: String, branch: String },
    GitCreateBranch { project: String, workspace: String, branch: String },
    GitCommit { project: String, workspace: String, message: String },
    GitFetch { project: String, workspace: String },
    GitRebase { project: String, workspace: String, onto_branch: String },
    GitRebaseContinue { project: String, workspace: String },
    GitRebaseAbort { project: String, workspace: String },
    GitOpStatus { project: String, workspace: String },
    GitEnsureIntegrationWorktree { project: String },
    GitMergeToDefault { project: String, workspace: String, default_branch: String },
    GitMergeContinue { project: String },
    GitMergeAbort { project: String },
    GitIntegrationStatus { project: String },
    GitRebaseOntoDefault { project: String, workspace: String, default_branch: String },
    GitRebaseOntoDefaultContinue { project: String },
    GitRebaseOntoDefaultAbort { project: String },
    GitResetIntegrationWorktree { project: String },
    GitCheckBranchUpToDate { project: String, workspace: String },
    GitLog {
        project: String, workspace: String,
        #[serde(default = "default_git_log_limit")]
        limit: usize,
    },
    GitShow { project: String, workspace: String, sha: String },
    GitAICommit {
        project: String, workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        ai_agent: Option<String>,
    },
}

/// Git 相关的服务端消息
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum GitResponse {
    GitStatusResult {
        project: String, workspace: String, repo_root: String,
        items: Vec<super::GitStatusEntry>,
        #[serde(default)] has_staged_changes: bool,
        #[serde(default)] staged_count: usize,
        #[serde(skip_serializing_if = "Option::is_none")] current_branch: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")] default_branch: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")] ahead_by: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")] behind_by: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")] compared_branch: Option<String>,
    },
    GitDiffResult {
        project: String, workspace: String, path: String,
        code: String, format: String, text: String,
        is_binary: bool, truncated: bool, mode: String,
        #[serde(skip_serializing_if = "Option::is_none")] base: Option<String>,
    },
    GitOpResult {
        project: String, workspace: String,
        op: String, ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")] message: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")] path: Option<String>,
        scope: String,
    },
    GitBranchesResult {
        project: String, workspace: String,
        current: String, branches: Vec<super::GitBranchInfo>,
    },
    GitCommitResult {
        project: String, workspace: String, ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")] message: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")] sha: Option<String>,
    },
    GitRebaseResult {
        project: String, workspace: String, ok: bool, state: String,
        #[serde(skip_serializing_if = "Option::is_none")] message: Option<String>,
        #[serde(default)] conflicts: Vec<String>,
    },
    GitOpStatusResult {
        project: String, workspace: String, state: String,
        #[serde(default)] conflicts: Vec<String>,
        #[serde(skip_serializing_if = "Option::is_none")] head: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")] onto: Option<String>,
    },
    GitMergeToDefaultResult {
        project: String, ok: bool, state: String,
        #[serde(skip_serializing_if = "Option::is_none")] message: Option<String>,
        #[serde(default)] conflicts: Vec<String>,
        #[serde(skip_serializing_if = "Option::is_none")] head_sha: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")] integration_path: Option<String>,
    },
    GitIntegrationStatusResult {
        project: String, state: String,
        #[serde(default)] conflicts: Vec<String>,
        #[serde(skip_serializing_if = "Option::is_none")] head: Option<String>,
        default_branch: String, path: String, is_clean: bool,
        #[serde(skip_serializing_if = "Option::is_none")] branch_ahead_by: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")] branch_behind_by: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")] compared_branch: Option<String>,
    },
    GitRebaseOntoDefaultResult {
        project: String, ok: bool, state: String,
        #[serde(skip_serializing_if = "Option::is_none")] message: Option<String>,
        #[serde(default)] conflicts: Vec<String>,
        #[serde(skip_serializing_if = "Option::is_none")] head_sha: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")] integration_path: Option<String>,
    },
    GitResetIntegrationWorktreeResult {
        project: String, ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")] message: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")] path: Option<String>,
    },
    GitLogResult {
        project: String, workspace: String,
        entries: Vec<super::GitLogEntryInfo>,
    },
    GitShowResult {
        project: String, workspace: String,
        sha: String, full_sha: String, message: String,
        author: String, author_email: String, date: String,
        files: Vec<super::GitShowFileInfo>,
    },
    GitStatusChanged { project: String, workspace: String },
    GitAICommitResult {
        success: bool, message: String,
        commits: Vec<super::AIGitCommit>,
    },
}
