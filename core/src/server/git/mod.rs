// Git module - modular structure for git operations
//
// This module is split into logical submodules:
// - utils: Common types, constants, error handling, and helper functions
// - status: Status queries (git_status, git_log, git_show)
// - operations: File operations (diff, stage, unstage, discard)
// - branches: Branch management (list, switch, create)
// - commit: Commit and rebase operations
// - integration: Integration worktree management

pub mod branches;
pub mod commit;
pub mod integration;
pub mod operations;
pub mod status;
pub mod utils;

// Re-export all public items for backward compatibility
pub use branches::*;
pub use commit::*;
pub use integration::*;
pub use operations::*;
pub use status::*;
pub use utils::*;
