//! 编辑器格式化处理器

use crate::server::context::SharedAppState;
use crate::server::protocol::{formatting, ClientMessage, ServerMessage};
use crate::server::ws::{send_message, OutboundTx as WebSocket};

pub async fn handle_formatting_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
    app_state: &SharedAppState,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::FileFormatCapabilitiesQuery {
            project,
            workspace,
            path,
        } => {
            handle_capabilities_query(project, workspace, path, socket, app_state).await?;
            Ok(true)
        }
        ClientMessage::FileFormatExecute {
            project,
            workspace,
            path,
            scope,
            text,
            selection_start,
            selection_end,
        } => {
            handle_format_execute(
                project,
                workspace,
                path,
                *scope,
                text,
                *selection_start,
                *selection_end,
                socket,
                app_state,
            )
            .await?;
            Ok(true)
        }
        _ => Ok(false),
    }
}

async fn handle_capabilities_query(
    project: &str,
    workspace: &str,
    path: &str,
    socket: &WebSocket,
    app_state: &SharedAppState,
) -> Result<(), String> {
    match crate::server::context::resolve_workspace(app_state, project, workspace).await {
        Ok(ws_ctx) => {
            let (language, capabilities) =
                crate::application::formatting::query_capabilities(path, &ws_ctx.root_path);
            send_message(
                socket,
                &ServerMessage::FileFormatCapabilitiesResult {
                    project: project.to_string(),
                    workspace: workspace.to_string(),
                    path: path.to_string(),
                    language,
                    capabilities,
                },
            )
            .await
        }
        Err(e) => {
            send_message(
                socket,
                &ServerMessage::FileFormatError {
                    project: project.to_string(),
                    workspace: workspace.to_string(),
                    path: path.to_string(),
                    error_code: formatting::EditorFormattingErrorCode::WorkspaceUnavailable,
                    message: Some(e.to_string()),
                },
            )
            .await
        }
    }
}

async fn handle_format_execute(
    project: &str,
    workspace: &str,
    path: &str,
    scope: formatting::EditorFormatScope,
    text: &str,
    selection_start: Option<u32>,
    selection_end: Option<u32>,
    socket: &WebSocket,
    app_state: &SharedAppState,
) -> Result<(), String> {
    match crate::server::context::resolve_workspace(app_state, project, workspace).await {
        Ok(ws_ctx) => {
            let result = crate::application::formatting::execute_format(
                path,
                &ws_ctx.root_path,
                scope,
                text,
                selection_start,
                selection_end,
            )
            .await;

            match result {
                crate::application::formatting::FormatResult::Success {
                    formatted_text,
                    formatter_id,
                    scope: result_scope,
                    changed,
                } => {
                    send_message(
                        socket,
                        &ServerMessage::FileFormatResult {
                            project: project.to_string(),
                            workspace: workspace.to_string(),
                            path: path.to_string(),
                            formatted_text,
                            formatter_id,
                            scope: result_scope,
                            changed,
                        },
                    )
                    .await
                }
                crate::application::formatting::FormatResult::Error {
                    error_code,
                    message,
                } => {
                    send_message(
                        socket,
                        &ServerMessage::FileFormatError {
                            project: project.to_string(),
                            workspace: workspace.to_string(),
                            path: path.to_string(),
                            error_code,
                            message: Some(message),
                        },
                    )
                    .await
                }
            }
        }
        Err(e) => {
            send_message(
                socket,
                &ServerMessage::FileFormatError {
                    project: project.to_string(),
                    workspace: workspace.to_string(),
                    path: path.to_string(),
                    error_code: formatting::EditorFormattingErrorCode::WorkspaceUnavailable,
                    message: Some(e.to_string()),
                },
            )
            .await
        }
    }
}
