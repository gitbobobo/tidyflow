use tracing::info;

use crate::server::context::HandlerContext;
use crate::server::protocol::ClientMessage;

pub(super) fn log_ai_control_message(client_msg: &ClientMessage, ctx: &HandlerContext) {
    match client_msg {
        ClientMessage::AIChatAbort {
            project_name,
            workspace_name,
            ai_tool,
            session_id,
        } => {
            info!(
                "Inbound AIChatAbort: conn_id={}, remote={}, project={}, workspace={}, ai_tool={}, session_id={}",
                ctx.conn_meta.conn_id,
                ctx.conn_meta.is_remote,
                project_name,
                workspace_name,
                ai_tool,
                session_id
            );
        }
        ClientMessage::AIQuestionReply {
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            request_id,
            answers,
        } => {
            info!(
                "Inbound AIQuestionReply: conn_id={}, remote={}, project={}, workspace={}, ai_tool={}, session_id={}, request_id={}, answers_count={}",
                ctx.conn_meta.conn_id,
                ctx.conn_meta.is_remote,
                project_name,
                workspace_name,
                ai_tool,
                session_id,
                request_id,
                answers.len()
            );
        }
        ClientMessage::AIQuestionReject {
            project_name,
            workspace_name,
            ai_tool,
            session_id,
            request_id,
        } => {
            info!(
                "Inbound AIQuestionReject: conn_id={}, remote={}, project={}, workspace={}, ai_tool={}, session_id={}, request_id={}",
                ctx.conn_meta.conn_id,
                ctx.conn_meta.is_remote,
                project_name,
                workspace_name,
                ai_tool,
                session_id,
                request_id
            );
        }
        _ => {}
    }
}
