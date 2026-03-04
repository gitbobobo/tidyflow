//! SQLite 连接共享工具。
//!
//! 统一管理：
//! - 默认数据库路径（`~/.tidyflow/tidyflow.db`）
//! - legacy JSON 路径（`~/.tidyflow/tidyflow.json`）
//! - SQLite URL / 连接参数（`create_if_missing`）
//! - 单连接池构建（`max_connections = 1`）

use std::path::{Path, PathBuf};
use std::str::FromStr;

use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{Pool, Sqlite};

pub fn tidyflow_home_dir() -> PathBuf {
    let home = dirs::home_dir().expect("Cannot find home directory");
    home.join(".tidyflow")
}

pub fn default_db_path() -> PathBuf {
    tidyflow_home_dir().join("tidyflow.db")
}

pub fn legacy_json_path() -> PathBuf {
    tidyflow_home_dir().join("tidyflow.json")
}

pub fn sqlite_url(path: &Path) -> String {
    format!("sqlite://{}", path.display())
}

pub fn connect_options(db_url: &str) -> Result<SqliteConnectOptions, String> {
    SqliteConnectOptions::from_str(db_url)
        .map_err(|e| format!("failed to parse sqlite url: {}", e))
        .map(|opts| opts.create_if_missing(true))
}

pub fn ensure_parent_dir(path: &Path) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    Ok(())
}

pub async fn ensure_parent_dir_async(path: &Path) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

pub async fn open_single_connection_pool(db_url: &str) -> Result<Pool<Sqlite>, String> {
    let options = connect_options(db_url)?;
    SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .map_err(|e| e.to_string())
}
