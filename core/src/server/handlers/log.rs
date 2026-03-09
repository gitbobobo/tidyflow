use crate::server::protocol::health::HealthContext;
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
            error_code,
            project,
            workspace,
            session_id,
            cycle_id,
        } => {
            FileLogger::global().write_client_log(
                level,
                source,
                category.as_deref(),
                msg,
                detail.as_deref(),
                error_code.as_deref(),
                project.as_deref(),
                workspace.as_deref(),
                session_id.as_deref(),
                cycle_id.as_deref(),
            );

            // error/critical 级别客户端日志同步写入健康注册表（来源为 client_state）
            if matches!(level.as_str(), "error" | "critical") {
                let root_cause = error_code.as_deref().unwrap_or("client_error").to_string();
                let context = HealthContext {
                    project: project.clone(),
                    workspace: workspace.clone(),
                    session_id: session_id.clone(),
                    cycle_id: cycle_id.clone(),
                };
                let registry = crate::server::health::global();
                if let Ok(mut reg) = registry.try_write() {
                    reg.record_log_error(
                        root_cause,
                        msg.chars().take(120).collect::<String>(),
                        context,
                    );
                };
            }

            Ok(true)
        }
        _ => Ok(false),
    }
}
