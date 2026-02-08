use serde::{Deserialize, Serialize};

/// Protocol version: 2 (MessagePack binary encoding)
/// v2: Switch from JSON+base64 to MessagePack binary encoding
pub const PROTOCOL_VERSION: u32 = 2;

// ============================================================================
// v0 Messages (Terminal Data Plane) - Backward Compatible
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    // v0: Terminal data plane (term_id optional for backward compat)
    Input {
        #[serde(with = "serde_bytes")]
        data: Vec<u8>,
        #[serde(skip_serializing_if = "Option::is_none")]
        term_id: Option<String>,
    },
    Resize {
        cols: u16,
        rows: u16,
        #[serde(skip_serializing_if = "Option::is_none")]
        term_id: Option<String>,
    },
    Ping,

    // v1: Control plane - Workspace management
    ListProjects,
    ListWorkspaces {
        project: String,
    },
    SelectWorkspace {
        project: String,
        workspace: String,
    },
    SpawnTerminal {
        cwd: String,
    },

    // v1: Session management
    KillTerminal,

    // v1.1: Multi-terminal extension
    TermCreate {
        project: String,
        workspace: String,
    },
    TermList,
    TermClose {
        term_id: String,
    },
    TermFocus {
        term_id: String,
    },

    // v1.3: File operations
    FileList {
        project: String,
        workspace: String,
        #[serde(default)]
        path: String,
    },
    FileRead {
        project: String,
        workspace: String,
        path: String,
    },
    FileWrite {
        project: String,
        workspace: String,
        path: String,
        #[serde(with = "serde_bytes")]
        content: Vec<u8>,
    },

    // v1.4: File index for Quick Open
    FileIndex {
        project: String,
        workspace: String,
    },

    // v1.5: Git tools
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
        mode: String, // "working" or "staged"
    },

    // v1.6: Git stage/unstage operations
    GitStage {
        project: String,
        workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>, // None = stage all
        #[serde(default = "default_git_scope")]
        scope: String, // "file" or "all"
    },
    GitUnstage {
        project: String,
        workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>, // None = unstage all
        #[serde(default = "default_git_scope")]
        scope: String, // "file" or "all"
    },

    // v1.7: Git discard (working tree changes)
    GitDiscard {
        project: String,
        workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>, // None = discard all
        #[serde(default = "default_git_scope")]
        scope: String, // "file" or "all"
        #[serde(default)]
        include_untracked: bool, // scope="all" 时是否同时删除未跟踪文件
    },

    // v1.8: Git branch operations
    GitBranches {
        project: String,
        workspace: String,
    },
    GitSwitchBranch {
        project: String,
        workspace: String,
        branch: String,
    },
    // v1.9: Git create branch
    GitCreateBranch {
        project: String,
        workspace: String,
        branch: String,
    },
    // v1.10: Git commit
    GitCommit {
        project: String,
        workspace: String,
        message: String,
    },

    // v1.11: Git rebase/fetch operations (UX-3a)
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

    // v1.12: Git merge to default via integration worktree (UX-3b)
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

    // v1.13: Git rebase onto default via integration worktree (UX-4)
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

    // v1.14: Git reset integration worktree (UX-5)
    GitResetIntegrationWorktree {
        project: String,
    },

    // v1.15: Git check branch up to date (UX-6)
    GitCheckBranchUpToDate {
        project: String,
        workspace: String,
    },

    // v1.16: Project/Workspace import
    ImportProject {
        name: String,
        path: String,
    },
    CreateWorkspace {
        project: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        from_branch: Option<String>,
    },

    // v1.17: Remove project
    RemoveProject {
        name: String,
    },

    // v1.18: Remove workspace
    RemoveWorkspace {
        project: String,
        workspace: String,
    },

    // v1.19: Git log (commit history)
    GitLog {
        project: String,
        workspace: String,
        #[serde(default = "default_git_log_limit")]
        limit: usize,
    },

    // v1.20: Git show (single commit details)
    GitShow {
        project: String,
        workspace: String,
        sha: String,
    },

    // v1.21: Client settings
    GetClientSettings,
    SaveClientSettings {
        custom_commands: Vec<CustomCommandInfo>,
        #[serde(default)]
        workspace_shortcuts: std::collections::HashMap<String, String>,
        /// 用于提交操作的 AI Agent
        #[serde(default)]
        commit_ai_agent: Option<String>,
        /// 用于合并操作的 AI Agent
        #[serde(default)]
        merge_ai_agent: Option<String>,
        /// 旧字段，兼容旧客户端
        #[serde(default)]
        selected_ai_agent: Option<String>,
    },

    // v1.22: File watcher
    WatchSubscribe {
        project: String,
        workspace: String,
    },
    WatchUnsubscribe,

    // v1.23: File rename/delete
    FileRename {
        project: String,
        workspace: String,
        old_path: String,
        new_name: String,
    },
    FileDelete {
        project: String,
        workspace: String,
        path: String,
    },

    // v1.24: File copy (使用绝对路径支持跨项目/外部文件复制)
    FileCopy {
        dest_project: String,
        dest_workspace: String,
        source_absolute_path: String, // 源文件绝对路径
        dest_dir: String,             // 目标目录（相对路径）
    },

    // v1.25: File move (拖拽移动)
    FileMove {
        project: String,
        workspace: String,
        old_path: String, // 源文件相对路径
        new_dir: String,  // 目标目录相对路径
    },

    // v1.26: AI Git commit
    GitAICommit {
        project: String,
        workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        ai_agent: Option<String>,
    },

    // v1.27: Terminal persistence — 重连附着
    TermAttach {
        term_id: String,
    },

    // v1.28: Terminal output flow control — 背压 ACK
    TermOutputAck {
        term_id: String,
        bytes: u64,
    },
}

fn default_diff_mode() -> String {
    "working".to_string()
}

fn default_git_scope() -> String {
    "file".to_string()
}

fn default_git_log_limit() -> usize {
    50
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    // v0: Terminal data plane (term_id optional for backward compat)
    Hello {
        version: u32,
        session_id: String,
        shell: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        capabilities: Option<Vec<String>>,
    },
    Output {
        #[serde(with = "serde_bytes")]
        data: Vec<u8>,
        #[serde(skip_serializing_if = "Option::is_none")]
        term_id: Option<String>,
    },
    Exit {
        code: i32,
        #[serde(skip_serializing_if = "Option::is_none")]
        term_id: Option<String>,
    },
    Pong,

    // v1: Control plane responses
    Projects {
        items: Vec<ProjectInfo>,
    },
    Workspaces {
        project: String,
        items: Vec<WorkspaceInfo>,
    },
    SelectedWorkspace {
        project: String,
        workspace: String,
        root: String,
        session_id: String,
        shell: String,
    },
    TerminalSpawned {
        session_id: String,
        shell: String,
        cwd: String,
    },
    TerminalKilled {
        session_id: String,
    },

    // v1.2: Multi-workspace extension (enhanced term_created/term_list)
    TermCreated {
        term_id: String,
        project: String,
        workspace: String,
        cwd: String,
        shell: String,
    },
    TermList {
        items: Vec<TerminalInfo>,
    },
    TermClosed {
        term_id: String,
    },

    // v1.3: File operation responses
    FileListResult {
        project: String,
        workspace: String,
        path: String,
        items: Vec<FileEntryInfo>,
    },
    FileReadResult {
        project: String,
        workspace: String,
        path: String,
        #[serde(with = "serde_bytes")]
        content: Vec<u8>,
        size: u64,
    },
    FileWriteResult {
        project: String,
        workspace: String,
        path: String,
        success: bool,
        size: u64,
    },

    // v1.4: File index result for Quick Open
    FileIndexResult {
        project: String,
        workspace: String,
        items: Vec<String>,
        truncated: bool,
    },

    // v1.5: Git tools results
    GitStatusResult {
        project: String,
        workspace: String,
        repo_root: String,
        items: Vec<GitStatusEntry>,
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
        mode: String, // Echo back the mode
    },

    // v1.6: Git operation result
    GitOpResult {
        project: String,
        workspace: String,
        op: String, // "stage", "unstage", "discard", "switch_branch", or "create_branch"
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>,
        scope: String, // "file" or "all"
    },

    // v1.8: Git branches result
    GitBranchesResult {
        project: String,
        workspace: String,
        current: String,
        branches: Vec<GitBranchInfo>,
    },

    // v1.10: Git commit result
    GitCommitResult {
        project: String,
        workspace: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        sha: Option<String>,
    },

    // v1.11: Git rebase result (UX-3a)
    GitRebaseResult {
        project: String,
        workspace: String,
        ok: bool,
        state: String, // "completed", "conflict", "aborted", "error"
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(default)]
        conflicts: Vec<String>,
    },

    // v1.11: Git operation status result (UX-3a)
    GitOpStatusResult {
        project: String,
        workspace: String,
        state: String, // "normal", "rebasing", "merging"
        #[serde(default)]
        conflicts: Vec<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        head: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        onto: Option<String>,
    },

    // v1.12: Git merge to default result (UX-3b)
    GitMergeToDefaultResult {
        project: String,
        ok: bool,
        state: String, // "idle", "merging", "conflict", "completed", "failed"
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(default)]
        conflicts: Vec<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        head_sha: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        integration_path: Option<String>,
    },

    // v1.12: Git integration worktree status result (UX-3b)
    GitIntegrationStatusResult {
        project: String,
        state: String, // "idle", "merging", "conflict", "rebasing", "rebase_conflict"
        #[serde(default)]
        conflicts: Vec<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        head: Option<String>,
        default_branch: String,
        path: String,
        is_clean: bool,
        // v1.15: Branch divergence info (UX-6)
        #[serde(skip_serializing_if = "Option::is_none")]
        branch_ahead_by: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        branch_behind_by: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        compared_branch: Option<String>,
    },

    // v1.13: Git rebase onto default result (UX-4)
    GitRebaseOntoDefaultResult {
        project: String,
        ok: bool,
        state: String, // "idle", "rebasing", "rebase_conflict", "completed", "failed"
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(default)]
        conflicts: Vec<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        head_sha: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        integration_path: Option<String>,
    },

    // v1.14: Git reset integration worktree result (UX-5)
    GitResetIntegrationWorktreeResult {
        project: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>,
    },

    // v1: Error handling
    Error {
        code: String,
        message: String,
    },

    // v1.16: Project/Workspace import results
    ProjectImported {
        name: String,
        root: String,
        default_branch: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        workspace: Option<WorkspaceInfo>,
    },
    WorkspaceCreated {
        project: String,
        workspace: WorkspaceInfo,
    },

    // v1.17: Remove project result
    ProjectRemoved {
        name: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },

    // v1.18: Remove workspace result
    WorkspaceRemoved {
        project: String,
        workspace: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },

    // v1.19: Git log result
    GitLogResult {
        project: String,
        workspace: String,
        entries: Vec<GitLogEntryInfo>,
    },

    // v1.20: Git show result (single commit details)
    GitShowResult {
        project: String,
        workspace: String,
        sha: String,
        full_sha: String,
        message: String,
        author: String,
        author_email: String,
        date: String,
        files: Vec<GitShowFileInfo>,
    },

    // v1.21: Client settings result
    ClientSettingsResult {
        custom_commands: Vec<CustomCommandInfo>,
        workspace_shortcuts: std::collections::HashMap<String, String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        commit_ai_agent: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        merge_ai_agent: Option<String>,
    },
    ClientSettingsSaved {
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },

    // v1.22: File watcher notifications
    WatchSubscribed {
        project: String,
        workspace: String,
    },
    WatchUnsubscribed,
    FileChanged {
        project: String,
        workspace: String,
        paths: Vec<String>,
        kind: String,
    },
    GitStatusChanged {
        project: String,
        workspace: String,
    },

    // v1.23: File rename/delete results
    FileRenameResult {
        project: String,
        workspace: String,
        old_path: String,
        new_path: String,
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    FileDeleteResult {
        project: String,
        workspace: String,
        path: String,
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },

    // v1.24: File copy result
    FileCopyResult {
        project: String,
        workspace: String,
        source_absolute_path: String,
        dest_path: String,
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },

    // v1.25: File move result
    FileMoveResult {
        project: String,
        workspace: String,
        old_path: String,
        new_path: String,
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },

    // v1.26: AI Git commit result
    GitAICommitResult {
        success: bool,
        message: String,
        commits: Vec<AIGitCommit>,
    },

    // v1.27: Terminal persistence — 附着响应
    TermAttached {
        term_id: String,
        project: String,
        workspace: String,
        cwd: String,
        shell: String,
        #[serde(with = "serde_bytes")]
        scrollback: Vec<u8>,
    },
}

// ============================================================================
// v1 Data Types
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectInfo {
    pub name: String,
    pub root: String,
    pub workspace_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceInfo {
    pub name: String,
    pub root: String,
    pub branch: String,
    pub status: String,
}

/// AI Git commit information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AIGitCommit {
    pub sha: String,
    pub message: String,
    pub files: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalInfo {
    pub term_id: String,
    pub project: String,
    pub workspace: String,
    pub cwd: String,
    pub status: String, // "running" or "exited"
    #[serde(default)]
    pub shell: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileEntryInfo {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    /// 是否被 .gitignore 忽略
    #[serde(default)]
    pub is_ignored: bool,
    /// 是否为符号链接
    #[serde(default)]
    pub is_symlink: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitStatusEntry {
    pub path: String,
    /// 序列化为 "status" 以匹配 Swift 端 GitStatusItem 的字段名
    #[serde(rename = "status")]
    pub code: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "rename_from")]
    pub orig_path: Option<String>,
    /// 是否有暂存区变更，用于 UI 区分「暂存的更改」与「未暂存的更改」
    pub staged: bool,
    /// 新增行数（None = 二进制文件或新文件）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub additions: Option<i32>,
    /// 删除行数（None = 二进制文件或新文件）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deletions: Option<i32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitBranchInfo {
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitLogEntryInfo {
    pub sha: String,
    pub message: String,
    pub author: String,
    pub date: String,
    #[serde(default)]
    pub refs: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitShowFileInfo {
    pub status: String,
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub old_path: Option<String>,
}

/// 自定义命令信息（用于协议传输）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CustomCommandInfo {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub command: String,
}

// ============================================================================
// v1 Capabilities
// ============================================================================

pub fn v1_capabilities() -> Vec<String> {
    vec![
        "workspace_management".to_string(),
        "multi_terminal".to_string(),
        "multi_workspace".to_string(),
        "cwd_spawn".to_string(),
        "file_operations".to_string(),
        "file_index".to_string(),
        "git_tools".to_string(),
        "git_stage_unstage".to_string(),
        "git_discard".to_string(),
        "git_branches".to_string(),
        "git_create_branch".to_string(),
        "git_commit".to_string(),
        "git_rebase".to_string(),
        "git_merge_integration".to_string(),
        "git_branch_divergence".to_string(),
        "project_import".to_string(),
        "file_watch".to_string(),
        "file_rename_delete".to_string(),
        "file_copy".to_string(),
        "file_move".to_string(),
        "terminal_persistence".to_string(),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_import_project() {
        let json = r#"{"type":"import_project","name":"ly_tech","path":"/Users/godbobo/work/projects/ly_tech"}"#;

        let result: Result<ClientMessage, _> = serde_json::from_str(json);
        match result {
            Ok(ClientMessage::ImportProject { name, path }) => {
                assert_eq!(name, "ly_tech");
                assert_eq!(path, "/Users/godbobo/work/projects/ly_tech");
            }
            Ok(other) => panic!("Unexpected message type: {:?}", other),
            Err(e) => panic!("Parse error: {}", e),
        }
    }
}
