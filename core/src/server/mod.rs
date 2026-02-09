pub mod context;
pub mod file_api;
pub mod file_index;
pub mod git;
pub mod handlers;
pub mod protocol;
pub mod terminal_registry;
pub mod watcher;
pub mod ws;

pub use context::{
    resolve_project, resolve_workspace, resolve_workspace_branch,
    AppError, HandlerContext, ProjectContext, SharedAppState, WorkspaceContext,
};
pub use file_api::{list_files, read_file, resolve_safe_path, write_file, FileApiError, FileEntry};
pub use file_index::{index_files, FileIndexResult, DEFAULT_IGNORE_DIRS, MAX_FILE_COUNT};
pub use git::{git_diff, git_status, GitDiffResult, GitError, GitStatusResult, MAX_DIFF_SIZE};
pub use protocol::{
    ClientMessage, GitStatusEntry, ProjectInfo, ServerMessage, WorkspaceInfo, PROTOCOL_VERSION,
};
pub use watcher::{WatchEvent, WorkspaceWatcher};
pub use ws::run_server;
