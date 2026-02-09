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
}

/// 内部状态，由 Mutex 保护
struct LogFileState {
    writer: Option<BufWriter<File>>,
    current_date: Option<NaiveDate>,
}

/// 线程安全的日志文件写入器
///
/// 按日期创建 `~/.tidyflow/logs/YYYY-MM-DD.log`，
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
    pub fn write_core_log(
        &self,
        level: &str,
        target: &str,
        message: &str,
    ) {
        let record = LogRecord {
            ts: Local::now().format("%Y-%m-%dT%H:%M:%S%.3f%:z").to_string(),
            level: level.to_string(),
            source: "core".to_string(),
            target: Some(target.to_string()),
            category: None,
            msg: message.to_string(),
            detail: None,
        };
        self.write_record(&record);
    }

    /// 写入来自客户端（Web/Swift）的日志
    pub fn write_client_log(
        &self,
        level: &str,
        source: &str,
        category: Option<&str>,
        msg: &str,
        detail: Option<&str>,
    ) {
        let record = LogRecord {
            ts: Local::now().format("%Y-%m-%dT%H:%M:%S%.3f%:z").to_string(),
            level: level.to_string(),
            source: source.to_string(),
            target: None,
            category: category.map(|s| s.to_string()),
            msg: msg.to_string(),
            detail: detail.map(|s| s.to_string()),
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
            // 从文件名解析日期：YYYY-MM-DD.log
            if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                if let Ok(date) = NaiveDate::parse_from_str(stem, "%Y-%m-%d") {
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
        let filename = format!("{}.log", date.format("%Y-%m-%d"));
        let path = self.log_dir.join(filename);
        OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .ok()
            .map(BufWriter::new)
    }
}
