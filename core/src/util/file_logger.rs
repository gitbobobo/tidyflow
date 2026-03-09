use chrono::{Local, NaiveDate};
use serde::Serialize;
use std::fs::{self, File, OpenOptions};
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::sync::Mutex;

/// 日志文件保留天数
const LOG_RETENTION_DAYS: i64 = 7;

/// 全局日志写入器单例
static FILE_LOGGER: std::sync::OnceLock<FileLogger> = std::sync::OnceLock::new();

/// JSON 日志条目
#[derive(Debug, Serialize)]
struct LogRecord {
    ts: String,
    level: String,
    source: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    target: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    category: Option<String>,
    msg: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    detail: Option<String>,
    /// 结构化错误码（与 Apple 端共享）
    #[serde(skip_serializing_if = "Option::is_none")]
    error_code: Option<String>,
    /// 错误归属上下文（多工作区场景）
    #[serde(skip_serializing_if = "Option::is_none")]
    project: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    workspace: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cycle_id: Option<String>,
}

/// 内部状态，由 Mutex 保护
struct LogFileState {
    writer: Option<BufWriter<File>>,
    current_date: Option<NaiveDate>,
}

/// 线程安全的日志文件写入器
///
/// 按日期创建 `~/.tidyflow/logs/YYYY-MM-DD[-suffix].log`，
/// 每行写入一条 JSON 结构化日志。
pub struct FileLogger {
    log_dir: PathBuf,
    state: Mutex<LogFileState>,
}

impl FileLogger {
    /// 获取全局单例
    pub fn global() -> &'static FileLogger {
        FILE_LOGGER.get_or_init(|| {
            let log_dir = dirs::home_dir()
                .expect("无法获取 home 目录")
                .join(".tidyflow")
                .join("logs");
            FileLogger::new(log_dir)
        })
    }

    fn new(log_dir: PathBuf) -> Self {
        // 确保日志目录存在
        let _ = fs::create_dir_all(&log_dir);
        Self {
            log_dir,
            state: Mutex::new(LogFileState {
                writer: None,
                current_date: None,
            }),
        }
    }

    /// 写入来自 Rust Core 自身的日志（source = "core"）
    pub fn write_core_log(&self, level: &str, target: &str, message: &str) {
        let record = LogRecord {
            ts: Local::now().format("%Y-%m-%dT%H:%M:%S%.3f%:z").to_string(),
            level: level.to_string(),
            source: "core".to_string(),
            target: Some(target.to_string()),
            category: None,
            msg: message.to_string(),
            detail: None,
            error_code: None,
            project: None,
            workspace: None,
            session_id: None,
            cycle_id: None,
        };
        self.write_record(&record);

        // error/critical 级别日志同步写入健康注册表，供 incident 聚合
        if matches!(level, "error" | "critical") {
            let registry = crate::server::health::global();
            if let Ok(mut reg) = registry.try_write() {
                reg.record_log_error(
                    format!("core_log:{}", target),
                    message.chars().take(120).collect::<String>(),
                    crate::server::protocol::health::HealthContext::system(),
                );
            };
        }
    }

    /// 写入来自客户端（Web/Swift）的日志（含结构化错误码与上下文）
    #[allow(clippy::too_many_arguments)]
    pub fn write_client_log(
        &self,
        level: &str,
        source: &str,
        category: Option<&str>,
        msg: &str,
        detail: Option<&str>,
        error_code: Option<&str>,
        project: Option<&str>,
        workspace: Option<&str>,
        session_id: Option<&str>,
        cycle_id: Option<&str>,
    ) {
        let record = LogRecord {
            ts: Local::now().format("%Y-%m-%dT%H:%M:%S%.3f%:z").to_string(),
            level: level.to_string(),
            source: source.to_string(),
            target: None,
            category: category.map(|s| s.to_string()),
            msg: msg.to_string(),
            detail: detail.map(|s| s.to_string()),
            error_code: error_code.map(|s| s.to_string()),
            project: project.map(|s| s.to_string()),
            workspace: workspace.map(|s| s.to_string()),
            session_id: session_id.map(|s| s.to_string()),
            cycle_id: cycle_id.map(|s| s.to_string()),
        };
        self.write_record(&record);
    }

    /// 清理超过保留天数的日志文件
    pub fn cleanup_old_logs(&self) {
        let cutoff = Local::now().date_naive() - chrono::Duration::days(LOG_RETENTION_DAYS);
        let entries = match fs::read_dir(&self.log_dir) {
            Ok(entries) => entries,
            Err(_) => return,
        };

        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("log") {
                continue;
            }
            // 从文件名解析日期：YYYY-MM-DD.log 或 YYYY-MM-DD-*.log
            if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                if let Some(date) = Self::parse_log_date(stem) {
                    if date < cutoff {
                        let _ = fs::remove_file(&path);
                    }
                }
            }
        }
    }

    // ---- 内部方法 ----

    fn write_record(&self, record: &LogRecord) {
        let today = Local::now().date_naive();
        let mut state = match self.state.lock() {
            Ok(s) => s,
            Err(_) => return,
        };

        // 日期切换时重新打开文件
        if state.current_date != Some(today) {
            state.writer = None;
            state.current_date = None;
            if let Some(w) = self.open_log_file(today) {
                state.writer = Some(w);
                state.current_date = Some(today);
            }
        }

        if let Some(ref mut writer) = state.writer {
            if let Ok(json) = serde_json::to_string(record) {
                let _ = writeln!(writer, "{}", json);
                let _ = writer.flush();
            }
        }
    }

    fn open_log_file(&self, date: NaiveDate) -> Option<BufWriter<File>> {
        let filename = Self::build_log_filename(date);
        let path = self.log_dir.join(filename);
        OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .ok()
            .map(BufWriter::new)
    }

    fn build_log_filename(date: NaiveDate) -> String {
        let date_prefix = date.format("%Y-%m-%d").to_string();
        let suffix = std::env::var("TIDYFLOW_LOG_SUFFIX")
            .ok()
            .and_then(|raw| Self::sanitize_log_suffix(&raw));
        match suffix {
            Some(suffix) => format!("{date_prefix}-{suffix}.log"),
            None => format!("{date_prefix}.log"),
        }
    }

    fn sanitize_log_suffix(raw: &str) -> Option<String> {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return None;
        }

        let normalized: String = trimmed
            .chars()
            .map(|ch| {
                if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                    ch
                } else {
                    '-'
                }
            })
            .collect();
        let is_empty_after_normalize = normalized.chars().all(|ch| ch == '-');
        if is_empty_after_normalize {
            None
        } else {
            Some(normalized)
        }
    }

    fn parse_log_date(stem: &str) -> Option<NaiveDate> {
        let date_part = stem.get(0..10)?;
        let rest = stem.get(10..)?;
        if !rest.is_empty() && !rest.starts_with('-') {
            return None;
        }
        NaiveDate::parse_from_str(date_part, "%Y-%m-%d").ok()
    }
}
