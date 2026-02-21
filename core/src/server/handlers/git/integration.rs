use axum::extract::ws::WebSocket;

use crate::server::context::{HandlerContext, SharedAppState};
use crate::server::protocol::ClientMessage;

mod handlers;
mod integration_ai_merge;

pub async fn handle_message(
    client_msg: &ClientMessage,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::GitFetch { project, workspace } => {
            handlers::handle_git_fetch(project, workspace, socket, app_state).await
        }

        ClientMessage::GitRebase {
            project,
            workspace,
            onto_branch,
        } => handlers::handle_git_rebase(project, workspace, onto_branch, socket, app_state).await,

        ClientMessage::GitRebaseContinue { project, workspace } => {
            handlers::handle_git_rebase_continue(project, workspace, socket, app_state).await
        }

        ClientMessage::GitRebaseAbort { project, workspace } => {
            handlers::handle_git_rebase_abort(project, workspace, socket, app_state).await
        }

        ClientMessage::GitOpStatus { project, workspace } => {
            handlers::handle_git_op_status(project, workspace, socket, app_state).await
        }

        ClientMessage::GitEnsureIntegrationWorktree { project } => {
            handlers::handle_git_ensure_integration_worktree(project, socket, app_state).await
        }

        ClientMessage::GitMergeToDefault {
            project,
            workspace,
            default_branch,
        } => {
            handlers::handle_git_merge_to_default(
                project,
                workspace,
                default_branch,
                socket,
                app_state,
            )
            .await
        }

        ClientMessage::GitMergeContinue { project } => {
            handlers::handle_git_merge_continue(project, socket, app_state).await
        }

        ClientMessage::GitMergeAbort { project } => {
            handlers::handle_git_merge_abort(project, socket, app_state).await
        }

        ClientMessage::GitIntegrationStatus { project } => {
            handlers::handle_git_integration_status(project, socket, app_state).await
        }

        ClientMessage::GitRebaseOntoDefault {
            project,
            workspace,
            default_branch,
        } => {
            handlers::handle_git_rebase_onto_default(
                project,
                workspace,
                default_branch,
                socket,
                app_state,
            )
            .await
        }

        ClientMessage::GitRebaseOntoDefaultContinue { project } => {
            handlers::handle_git_rebase_onto_default_continue(project, socket, app_state).await
        }

        ClientMessage::GitRebaseOntoDefaultAbort { project } => {
            handlers::handle_git_rebase_onto_default_abort(project, socket, app_state).await
        }

        ClientMessage::GitResetIntegrationWorktree { project } => {
            handlers::handle_git_reset_integration_worktree(project, socket, app_state).await
        }

        ClientMessage::GitCheckBranchUpToDate { project, workspace } => {
            handlers::handle_git_check_branch_up_to_date(project, workspace, socket, app_state)
                .await
        }

        ClientMessage::GitAIMerge {
            project,
            workspace,
            ai_agent,
            default_branch,
        } => {
            integration_ai_merge::handle_git_ai_merge(
                project.clone(),
                workspace.clone(),
                ai_agent.clone(),
                default_branch.clone(),
                socket,
                app_state,
                ctx,
            )
            .await
        }

        _ => Ok(false),
    }
}
