use crate::server::ws::OutboundTx as WebSocket;

use crate::server::context::{HandlerContext, SharedAppState};
use crate::server::handlers::dispatch_handlers;
use crate::server::protocol::ClientMessage;

use super::{branch_commit, history, integration, stage_ops, status_diff};

/// 标准 Git 消息路由（按既有顺序短路匹配）。
pub async fn handle_standard_git_routes(
    client_msg: &ClientMessage,
    socket: &WebSocket,
    app_state: &SharedAppState,
    ctx: &HandlerContext,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::GitStatus { project, workspace } => {
            crate::server::handlers::send_read_via_http_required(
                socket,
                "git_status",
                "/api/v1/projects/:project/workspaces/:workspace/git/status",
                Some(project.clone()),
                Some(workspace.clone()),
            )
            .await?;
            return Ok(true);
        }
        ClientMessage::GitDiff {
            project, workspace, ..
        } => {
            crate::server::handlers::send_read_via_http_required(
                socket,
                "git_diff",
                "/api/v1/projects/:project/workspaces/:workspace/git/diff",
                Some(project.clone()),
                Some(workspace.clone()),
            )
            .await?;
            return Ok(true);
        }
        ClientMessage::GitBranches { project, workspace } => {
            crate::server::handlers::send_read_via_http_required(
                socket,
                "git_branches",
                "/api/v1/projects/:project/workspaces/:workspace/git/branches",
                Some(project.clone()),
                Some(workspace.clone()),
            )
            .await?;
            return Ok(true);
        }
        ClientMessage::GitLog {
            project, workspace, ..
        } => {
            crate::server::handlers::send_read_via_http_required(
                socket,
                "git_log",
                "/api/v1/projects/:project/workspaces/:workspace/git/log",
                Some(project.clone()),
                Some(workspace.clone()),
            )
            .await?;
            return Ok(true);
        }
        ClientMessage::GitShow {
            project, workspace, ..
        } => {
            crate::server::handlers::send_read_via_http_required(
                socket,
                "git_show",
                "/api/v1/projects/:project/workspaces/:workspace/git/commits/:sha",
                Some(project.clone()),
                Some(workspace.clone()),
            )
            .await?;
            return Ok(true);
        }
        ClientMessage::GitOpStatus { project, workspace } => {
            crate::server::handlers::send_read_via_http_required(
                socket,
                "git_op_status",
                "/api/v1/projects/:project/workspaces/:workspace/git/op-status",
                Some(project.clone()),
                Some(workspace.clone()),
            )
            .await?;
            return Ok(true);
        }
        ClientMessage::GitIntegrationStatus { project } => {
            crate::server::handlers::send_read_via_http_required(
                socket,
                "git_integration_status",
                "/api/v1/projects/:project/git/integration-status",
                Some(project.clone()),
                None,
            )
            .await?;
            return Ok(true);
        }
        ClientMessage::GitCheckBranchUpToDate { project, workspace } => {
            crate::server::handlers::send_read_via_http_required(
                socket,
                "git_check_branch_up_to_date",
                "/api/v1/projects/:project/workspaces/:workspace/git/up-to-date",
                Some(project.clone()),
                Some(workspace.clone()),
            )
            .await?;
            return Ok(true);
        }
        ClientMessage::GitConflictDetail {
            project, workspace, ..
        } => {
            crate::server::handlers::send_read_via_http_required(
                socket,
                "git_conflict_detail",
                "/api/v1/projects/:project/workspaces/:workspace/git/conflicts/detail",
                Some(project.clone()),
                Some(workspace.clone()),
            )
            .await?;
            return Ok(true);
        }
        _ => {}
    }

    dispatch_handlers!(
        status_diff::handle_message(client_msg, socket, app_state),
        stage_ops::handle_message(client_msg, socket, app_state),
        branch_commit::handle_message(client_msg, socket, app_state, ctx),
        integration::handle_message(client_msg, socket, app_state, ctx),
        history::handle_message(client_msg, socket, app_state),
    );

    Ok(false)
}

#[cfg(test)]
mod tests {
    use crate::server::handlers::dispatch_handlers;
    use std::sync::{Arc, Mutex};

    async fn push_and_return(
        trace: Arc<Mutex<Vec<&'static str>>>,
        label: &'static str,
        value: bool,
    ) -> Result<bool, String> {
        trace.lock().expect("lock trace").push(label);
        Ok(value)
    }

    async fn dispatch_like_git(trace: Arc<Mutex<Vec<&'static str>>>) -> Result<bool, String> {
        dispatch_handlers!(
            push_and_return(trace.clone(), "status_diff", false),
            push_and_return(trace.clone(), "stage_ops", false),
            push_and_return(trace.clone(), "branch_commit", true),
            push_and_return(trace.clone(), "integration", true),
            push_and_return(trace.clone(), "history", true),
        );
        Ok(false)
    }

    #[tokio::test]
    async fn git_dispatch_order_short_circuit() {
        let trace = Arc::new(Mutex::new(Vec::new()));
        let handled = dispatch_like_git(trace.clone())
            .await
            .expect("dispatch should succeed");

        assert!(handled);
        assert_eq!(
            *trace.lock().expect("lock trace"),
            vec!["status_diff", "stage_ops", "branch_commit"]
        );
    }
}
