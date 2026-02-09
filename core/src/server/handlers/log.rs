use crate::server::protocol::ClientMessage;
use crate::util::file_logger::FileLogger;

/// 处理客户端日志上报消息
///
/// 返回 `Ok(true)` 表示消息已处理，`Ok(false)` 表示不属于本处理器。
pub fn handle_log_message(client_msg: &ClientMessage) -> Result<bool, String> {
    match client_msg {
        ClientMessage::LogEntry {
            level,
            source,
            category,
            msg,
            detail,
        } => {
            FileLogger::global().write_client_log(
                level,
                source,
                category.as_deref(),
                msg,
                detail.as_deref(),
            );
            Ok(true)
        }
        _ => Ok(false),
    }
}
