//! 文件领域协议类型
//!
//! ## 文件系统统一状态机
//!
//! 每个 `(project, workspace)` 维护一个独立的文件系统相位（`FileWorkspacePhase`），
//! 描述该工作区文件子系统的聚合就绪状态。相位由 Core 权威管理，
//! 客户端只消费、不推导。
//!
//! ### 相位定义与状态迁移
//!
//! ```text
//! Idle ──(watch_subscribe)──► Watching
//! Idle ──(index_request)───► Indexing
//! Indexing ──(complete)─────► Idle（若无 watcher）
//! Indexing ──(complete)─────► Watching（若 watcher 已就绪）
//! Watching ──(watcher_error)► Degraded
//! Watching ──(unsubscribe)──► Idle
//! Degraded ──(recover)──────► Recovering
//! Recovering ──(success)────► Watching
//! Recovering ──(fail)───────► Error
//! Error ──(retry)───────────► Recovering
//! (任意) ──(disconnect)─────► Idle
//! (任意) ──(workspace_switch)► Idle
//! ```
//!
//! ### 文件变更事件类型（`FileChangeKind`）
//!
//! 统一的文件变更事件类型，替代原先的字符串字面量 `"modify"` / `"create"` 等，
//! 确保 Core、协议层和客户端引用同一组枚举值。

use serde::{Deserialize, Serialize};

/// 文件工作区相位：描述某个 `(project, workspace)` 的文件子系统聚合就绪状态。
///
/// Core 运行时按 `(project, workspace)` 键维护实例，
/// 客户端通过 `system_snapshot` 或连接事件间接获取当前相位。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FileWorkspacePhase {
    /// 文件子系统未激活：无 watcher、无正在进行的索引。
    /// 新连接、断线重连、工作区切换后的初始状态。
    Idle,
    /// 文件索引扫描进行中（首次或全量重建）。
    Indexing,
    /// watcher 已就绪，增量事件正常投递。
    Watching,
    /// watcher 遇到非致命错误，缓存可能过时但仍可读。
    /// 客户端应提示"文件监控已降级"。
    Degraded,
    /// 致命错误，文件操作不可用。
    Error,
    /// 正在从 Error/Degraded 恢复（重建 watcher 或索引）。
    Recovering,
}

impl FileWorkspacePhase {
    /// 相位是否允许执行文件读写操作。
    /// `Idle`、`Indexing`、`Watching`、`Degraded`、`Recovering` 均允许；
    /// 仅 `Error` 阶段阻塞写操作（读操作由缓存兜底，不阻塞）。
    pub fn allows_write(&self) -> bool {
        !matches!(self, FileWorkspacePhase::Error)
    }

    /// 相位是否表示正常就绪（`Watching`）。
    pub fn is_ready(&self) -> bool {
        matches!(self, FileWorkspacePhase::Watching)
    }

    /// 相位是否需要恢复关注（`Degraded` | `Error` | `Recovering`）。
    pub fn needs_attention(&self) -> bool {
        matches!(
            self,
            FileWorkspacePhase::Degraded
                | FileWorkspacePhase::Error
                | FileWorkspacePhase::Recovering
        )
    }
}

impl Default for FileWorkspacePhase {
    fn default() -> Self {
        FileWorkspacePhase::Idle
    }
}

impl std::fmt::Display for FileWorkspacePhase {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FileWorkspacePhase::Idle => write!(f, "idle"),
            FileWorkspacePhase::Indexing => write!(f, "indexing"),
            FileWorkspacePhase::Watching => write!(f, "watching"),
            FileWorkspacePhase::Degraded => write!(f, "degraded"),
            FileWorkspacePhase::Error => write!(f, "error"),
            FileWorkspacePhase::Recovering => write!(f, "recovering"),
        }
    }
}

/// 文件变更事件类型。
///
/// 替代原先在 `WatchEvent::FileChanged.kind` 和 `FileChangedNotification.kind` 中
/// 使用的字符串字面量，确保 Core、协议和客户端引用同一组语义。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FileChangeKind {
    /// 文件或目录被创建。
    Created,
    /// 文件内容被修改。
    Modified,
    /// 文件或目录被删除。
    Removed,
    /// 文件或目录被重命名。
    Renamed,
}

impl FileChangeKind {
    /// 从 watcher 产生的字符串 kind 解析，不可识别的 kind 统一回退为 `Modified`。
    pub fn from_watcher_str(s: &str) -> Self {
        match s {
            "created" | "create" => FileChangeKind::Created,
            "removed" | "deleted" | "delete" | "remove" => FileChangeKind::Removed,
            "renamed" | "rename" => FileChangeKind::Renamed,
            _ => FileChangeKind::Modified,
        }
    }

    /// 转为协议传输用的字符串值（与 serde 序列化值一致）。
    pub fn as_str(&self) -> &'static str {
        match self {
            FileChangeKind::Created => "created",
            FileChangeKind::Modified => "modified",
            FileChangeKind::Removed => "removed",
            FileChangeKind::Renamed => "renamed",
        }
    }
}

impl std::fmt::Display for FileChangeKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// 文件相关的客户端消息
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum FileRequest {
    FileList {
        project: String,
        workspace: String,
        #[serde(default)]
        path: String,
    },
    FileRead {
        project: String,
        workspace: String,
        path: String,
    },
    FileWrite {
        project: String,
        workspace: String,
        path: String,
        #[serde(with = "serde_bytes")]
        content: Vec<u8>,
    },
    FileIndex {
        project: String,
        workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        query: Option<String>,
    },
    FileRename {
        project: String,
        workspace: String,
        old_path: String,
        new_name: String,
    },
    FileDelete {
        project: String,
        workspace: String,
        path: String,
    },
    FileCopy {
        dest_project: String,
        dest_workspace: String,
        source_absolute_path: String,
        dest_dir: String,
    },
    FileMove {
        project: String,
        workspace: String,
        old_path: String,
        new_dir: String,
    },
    WatchSubscribe {
        project: String,
        workspace: String,
    },
    WatchUnsubscribe,
}

/// 文件相关的服务端消息
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum FileResponse {
    FileListResult {
        project: String,
        workspace: String,
        path: String,
        items: Vec<super::FileEntryInfo>,
    },
    FileReadResult {
        project: String,
        workspace: String,
        path: String,
        #[serde(with = "serde_bytes")]
        content: Vec<u8>,
        size: u64,
    },
    FileWriteResult {
        project: String,
        workspace: String,
        path: String,
        success: bool,
        size: u64,
    },
    FileIndexResult {
        project: String,
        workspace: String,
        items: Vec<String>,
        truncated: bool,
    },
    FileRenameResult {
        project: String,
        workspace: String,
        old_path: String,
        new_path: String,
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    FileDeleteResult {
        project: String,
        workspace: String,
        path: String,
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    FileCopyResult {
        project: String,
        workspace: String,
        source_absolute_path: String,
        dest_path: String,
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    FileMoveResult {
        project: String,
        workspace: String,
        old_path: String,
        new_path: String,
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    WatchSubscribed {
        project: String,
        workspace: String,
    },
    WatchUnsubscribed,
    FileChanged {
        project: String,
        workspace: String,
        paths: Vec<String>,
        kind: String,
    },
}
