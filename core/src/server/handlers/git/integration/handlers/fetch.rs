use axum::extract::ws::WebSocket;

use crate::server::context::{resolve_workspace, SharedAppState};
use crate::server::git;
use crate::server::protocol::ServerMessage;
use crate::server::ws::send_message;

pub(crate) async fn handle_git_fetch(
    project: &str,
    workspace: &str,
    socket: &mut WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    let ws_ctx = match resolve_workspace(app_state, project, workspace).await {
        Ok(ctx) => ctx,
        Err(e) => {
            send_message(socket, &e.to_server_error()).await?;
            return Ok(true);
        }
    };
    let root = ws_ctx.root_path;
    let result = tokio::task::spawn_blocking(move || git::git_fetch(&root)).await;
    match result {
        Ok(Ok(op_result)) => {
            send_message(
                socket,
                &ServerMessage::GitOpResult {
                    project: project.to_string(),
                    workspace: workspace.to_string(),
                    op: op_result.op,
                    ok: op_result.ok,
                    message: op_result.message,
                    path: op_result.path,
                    scope: op_result.scope,
                },
            )
            .await?;
        }
        Ok(Err(e)) => {
            send_message(
                socket,
                &ServerMessage::GitOpResult {
                    project: project.to_string(),
                    workspace: workspace.to_string(),
                    op: "fetch".to_string(),
                    ok: false,
                    message: Some(format!("{}", e)),
                    path: None,
                    scope: "all".to_string(),
                },
            )
            .await?;
        }
        Err(e) => {
            send_message(
                socket,
                &ServerMessage::Error {
                    code: "internal_error".to_string(),
                    message: format!("Git fetch task failed: {}", e),
                },
            )
            .await?;
        }
    }
    Ok(true)
}
