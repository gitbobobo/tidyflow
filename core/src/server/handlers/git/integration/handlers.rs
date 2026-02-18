mod fetch;
mod merge;
mod rebase;
mod status;

pub(crate) use fetch::handle_git_fetch;

pub(crate) use merge::{
    handle_git_ensure_integration_worktree, handle_git_merge_abort, handle_git_merge_continue,
    handle_git_merge_to_default, handle_git_reset_integration_worktree,
};

pub(crate) use rebase::{
    handle_git_rebase, handle_git_rebase_abort, handle_git_rebase_continue,
    handle_git_rebase_onto_default, handle_git_rebase_onto_default_abort,
    handle_git_rebase_onto_default_continue,
};

pub(crate) use status::{
    handle_git_check_branch_up_to_date, handle_git_integration_status, handle_git_op_status,
};
