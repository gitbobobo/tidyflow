use std::path::PathBuf;

/// 返回 TidyFlow 全局数据目录。
///
/// 优先级：
/// 1. `TIDYFLOW_HOME`
/// 2. 开发模式默认 `~/.tidyflow-dev`
/// 3. 生产模式默认 `~/.tidyflow`
pub fn tidyflow_home_dir() -> PathBuf {
    if let Ok(raw) = std::env::var("TIDYFLOW_HOME") {
        let trimmed = raw.trim();
        if !trimmed.is_empty() {
            return PathBuf::from(trimmed);
        }
    }

    let home = dirs::home_dir().expect("Cannot find home directory");
    if std::env::var("TIDYFLOW_DEV").is_ok() {
        home.join(".tidyflow-dev")
    } else {
        home.join(".tidyflow")
    }
}

/// 返回正式版默认使用的全局数据目录，不受运行时环境变量影响。
pub fn production_tidyflow_home_dir() -> PathBuf {
    let home = dirs::home_dir().expect("Cannot find home directory");
    home.join(".tidyflow")
}
