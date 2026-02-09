use std::io::Write;
use tracing_subscriber::{fmt, prelude::*, EnvFilter};

use super::file_logger::FileLogger;

/// 将 tracing 事件同步写入日志文件的 Layer
struct FileLogLayer;

impl<S> tracing_subscriber::Layer<S> for FileLogLayer
where
    S: tracing::Subscriber,
{
    fn on_event(
        &self,
        event: &tracing::Event<'_>,
        _ctx: tracing_subscriber::layer::Context<'_, S>,
    ) {
        let metadata = event.metadata();
        let level = metadata.level().as_str();
        let target = metadata.target();

        // 收集 message 字段
        let mut visitor = MessageVisitor(String::new());
        event.record(&mut visitor);

        FileLogger::global().write_core_log(level, target, &visitor.0);
    }
}

/// 用于从 tracing Event 中提取 message 字段的访问器
struct MessageVisitor(String);

impl tracing::field::Visit for MessageVisitor {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            self.0 = format!("{:?}", value);
        } else if self.0.is_empty() {
            self.0 = format!("{}={:?}", field.name(), value);
        } else {
            self.0.push_str(&format!(" {}={:?}", field.name(), value));
        }
    }

    fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
        if field.name() == "message" {
            self.0 = value.to_string();
        } else if self.0.is_empty() {
            self.0 = format!("{}={}", field.name(), value);
        } else {
            self.0.push_str(&format!(" {}={}", field.name(), value));
        }
    }
}

/// Initialize structured logging with tracing.
///
/// Log level can be controlled via RUST_LOG env var.
/// Default level is "info".
///
/// 同时输出到 stdout（开发调试）和 `~/.tidyflow/logs/YYYY-MM-DD.log`（持久化）。
/// 启动时自动清理超过 7 天的日志文件。
pub fn init_logging() {
    // 初始化文件日志并清理旧日志
    let file_logger = FileLogger::global();
    file_logger.cleanup_old_logs();

    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));

    tracing_subscriber::registry()
        .with(
            fmt::layer()
                .with_target(true)
                .with_thread_ids(false)
                .with_ansi(false),
        )
        .with(FileLogLayer)
        .with(filter)
        .init();
}

/// Flush stdout to ensure logs are written immediately
pub fn flush_logs() {
    let _ = std::io::stdout().flush();
    let _ = std::io::stderr().flush();
}
