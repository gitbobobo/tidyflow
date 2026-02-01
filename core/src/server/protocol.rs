use serde::{Deserialize, Serialize};

/// Protocol version: 1 (backward compatible with v0, with multi-workspace extension v1.2)
pub const PROTOCOL_VERSION: u32 = 1;

// ============================================================================
// v0 Messages (Terminal Data Plane) - Backward Compatible
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    // v0: Terminal data plane (term_id optional for backward compat)
    Input {
        data_b64: String,
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
    ListWorkspaces { project: String },
    SelectWorkspace { project: String, workspace: String },
    SpawnTerminal { cwd: String },

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
        content_b64: String,
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
        mode: String,  // "working" or "staged"
    },

    // v1.6: Git stage/unstage operations
    GitStage {
        project: String,
        workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>,  // None = stage all
        #[serde(default = "default_git_scope")]
        scope: String,  // "file" or "all"
    },
    GitUnstage {
        project: String,
        workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>,  // None = unstage all
        #[serde(default = "default_git_scope")]
        scope: String,  // "file" or "all"
    },

    // v1.7: Git discard (working tree changes)
    GitDiscard {
        project: String,
        workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>,  // None = discard all
        #[serde(default = "default_git_scope")]
        scope: String,  // "file" or "all"
    },
}

fn default_diff_mode() -> String {
    "working".to_string()
}

fn default_git_scope() -> String {
    "file".to_string()
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
        data_b64: String,
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
    Projects { items: Vec<ProjectInfo> },
    Workspaces { project: String, items: Vec<WorkspaceInfo> },
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
    TerminalKilled { session_id: String },

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
        content_b64: String,
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
        mode: String,  // Echo back the mode
    },

    // v1.6: Git operation result
    GitOpResult {
        project: String,
        workspace: String,
        op: String,  // "stage", "unstage", or "discard"
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>,
        scope: String,  // "file" or "all"
    },

    // v1: Error handling
    Error { code: String, message: String },
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalInfo {
    pub term_id: String,
    pub project: String,
    pub workspace: String,
    pub cwd: String,
    pub status: String, // "running" or "exited"
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileEntryInfo {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitStatusEntry {
    pub path: String,
    pub code: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub orig_path: Option<String>,
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
    ]
}
