//! 文件领域协议类型

use serde::{Deserialize, Serialize};

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
