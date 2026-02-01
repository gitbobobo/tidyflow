pub mod protocol;
pub mod ws;
pub mod file_api;
pub mod file_index;

pub use protocol::{ClientMessage, ServerMessage, ProjectInfo, WorkspaceInfo, PROTOCOL_VERSION};
pub use ws::run_server;
pub use file_api::{FileEntry, FileApiError, list_files, read_file, write_file, resolve_safe_path};
pub use file_index::{index_files, FileIndexResult, MAX_FILE_COUNT, DEFAULT_IGNORE_DIRS};
