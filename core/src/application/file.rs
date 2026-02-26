use std::path::Path;
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};
use std::time::Instant;
use tracing::debug;

use crate::server::file_api::{self, FileApiError};
use crate::server::file_index;
use crate::server::protocol::{FileEntryInfo, ServerMessage};

const FILE_INDEX_CACHE_TTL_SECS: u64 = 15;

struct FileIndexCacheEntry {
    items: Vec<String>,
    item_search_keys: Vec<String>,
    truncated: bool,
    created_at: Instant,
}

static FILE_INDEX_CACHE: LazyLock<Mutex<HashMap<String, FileIndexCacheEntry>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn file_index_cache_key(root: &Path) -> String {
    root.to_string_lossy().to_string()
}

pub fn invalidate_file_index_cache(root: &Path) {
    let key = file_index_cache_key(root);
    if let Ok(mut cache) = FILE_INDEX_CACHE.lock() {
        cache.remove(&key);
    }
}

fn read_file_index_cache(root: &Path) -> Option<(Vec<String>, Vec<String>, bool)> {
    let key = file_index_cache_key(root);
    let mut cache = FILE_INDEX_CACHE.lock().ok()?;
    let entry = cache.get(&key)?;
    if entry.created_at.elapsed().as_secs() >= FILE_INDEX_CACHE_TTL_SECS {
        cache.remove(&key);
        return None;
    }
    Some((
        entry.items.clone(),
        entry.item_search_keys.clone(),
        entry.truncated,
    ))
}

fn write_file_index_cache(root: &Path, items: &[String], truncated: bool) {
    let key = file_index_cache_key(root);
    let entry = FileIndexCacheEntry {
        items: items.to_vec(),
        item_search_keys: items.iter().map(|item| item.to_lowercase()).collect(),
        truncated,
        created_at: Instant::now(),
    };
    if let Ok(mut cache) = FILE_INDEX_CACHE.lock() {
        cache.insert(key, entry);
    }
}

/// 将 FileApiError 映射为协议错误码与消息。
pub fn file_error_to_response(e: &FileApiError) -> (String, String) {
    match e {
        FileApiError::PathEscape => ("path_escape".to_string(), e.to_string()),
        FileApiError::PathTooLong => ("path_too_long".to_string(), e.to_string()),
        FileApiError::FileNotFound => ("file_not_found".to_string(), e.to_string()),
        FileApiError::FileTooLarge => ("file_too_large".to_string(), e.to_string()),
        FileApiError::InvalidUtf8 => ("invalid_utf8".to_string(), e.to_string()),
        FileApiError::IoError(_) => ("io_error".to_string(), e.to_string()),
        FileApiError::TargetExists => ("target_exists".to_string(), e.to_string()),
        FileApiError::InvalidName(_) => ("invalid_name".to_string(), e.to_string()),
        FileApiError::TrashError(_) => ("trash_error".to_string(), e.to_string()),
        FileApiError::MoveIntoSelf => ("move_into_self".to_string(), e.to_string()),
    }
}

fn file_error_message(e: &FileApiError) -> ServerMessage {
    let (code, message) = file_error_to_response(e);
    ServerMessage::Error { code, message }
}

pub fn file_list_message(root: &Path, project: &str, workspace: &str, path: &str) -> ServerMessage {
    let path_str = if path.is_empty() {
        ".".to_string()
    } else {
        path.to_string()
    };

    match file_api::list_files(root, &path_str) {
        Ok(entries) => {
            let items: Vec<FileEntryInfo> = entries
                .into_iter()
                .map(|e| FileEntryInfo {
                    name: e.name,
                    is_dir: e.is_dir,
                    size: e.size,
                    is_ignored: e.is_ignored,
                    is_symlink: e.is_symlink,
                })
                .collect();

            ServerMessage::FileListResult {
                project: project.to_string(),
                workspace: workspace.to_string(),
                path: path_str,
                items,
            }
        }
        Err(e) => file_error_message(&e),
    }
}

pub fn file_read_message(root: &Path, project: &str, workspace: &str, path: &str) -> ServerMessage {
    match file_api::read_file(root, path) {
        Ok((content, size)) => ServerMessage::FileReadResult {
            project: project.to_string(),
            workspace: workspace.to_string(),
            path: path.to_string(),
            content: content.into_bytes(),
            size,
        },
        Err(FileApiError::InvalidUtf8) => {
            // 非 UTF-8 文件回退为二进制读取。
            match file_api::read_file_binary(root, path) {
                Ok((content, size)) => ServerMessage::FileReadResult {
                    project: project.to_string(),
                    workspace: workspace.to_string(),
                    path: path.to_string(),
                    content,
                    size,
                },
                Err(e) => file_error_message(&e),
            }
        }
        Err(e) => file_error_message(&e),
    }
}

pub fn file_write_message(
    root: &Path,
    project: &str,
    workspace: &str,
    path: &str,
    content: &[u8],
) -> ServerMessage {
    match String::from_utf8(content.to_vec()) {
        Ok(content_str) => match file_api::write_file(root, path, &content_str) {
            Ok(size) => {
                invalidate_file_index_cache(root);
                ServerMessage::FileWriteResult {
                    project: project.to_string(),
                    workspace: workspace.to_string(),
                    path: path.to_string(),
                    success: true,
                    size,
                }
            }
            Err(e) => file_error_message(&e),
        },
        Err(_) => ServerMessage::Error {
            code: "invalid_utf8".to_string(),
            message: "Content is not valid UTF-8".to_string(),
        },
    }
}

pub async fn file_index_message(
    root: &Path,
    project: &str,
    workspace: &str,
    query: Option<&str>,
) -> ServerMessage {
    let root = root.to_path_buf();
    let normalized_query = query
        .map(str::trim)
        .filter(|q| !q.is_empty())
        .map(|q| q.to_lowercase());

    if let Some((mut items, search_keys, truncated)) = read_file_index_cache(&root) {
        let filter_started = Instant::now();
        if let Some(q) = normalized_query.as_ref() {
            items = items
                .into_iter()
                .zip(search_keys.into_iter())
                .filter_map(|(item, key)| if key.contains(q) { Some(item) } else { None })
                .collect();
        }
        debug!(
            "file_index cache_hit=true items={} filter_ms={}",
            items.len(),
            filter_started.elapsed().as_millis()
        );
        return ServerMessage::FileIndexResult {
            project: project.to_string(),
            workspace: workspace.to_string(),
            items,
            truncated,
        };
    }

    let root_for_index = root.clone();
    let walk_started = Instant::now();
    let result =
        tokio::task::spawn_blocking(move || file_index::index_files(&root_for_index)).await;

    match result {
        Ok(Ok(mut index_result)) => {
            let walk_ms = walk_started.elapsed().as_millis();
            write_file_index_cache(root.as_path(), &index_result.items, index_result.truncated);
            let filter_started = Instant::now();
            if let Some(q) = normalized_query.as_ref() {
                index_result
                    .items
                    .retain(|item| item.to_lowercase().contains(q));
            }
            debug!(
                "file_index cache_hit=false items={} truncated={} walk_ms={} filter_ms={}",
                index_result.items.len(),
                index_result.truncated,
                walk_ms,
                filter_started.elapsed().as_millis()
            );

            ServerMessage::FileIndexResult {
                project: project.to_string(),
                workspace: workspace.to_string(),
                items: index_result.items,
                truncated: index_result.truncated,
            }
        }
        Ok(Err(e)) => ServerMessage::Error {
            code: "io_error".to_string(),
            message: format!("Failed to index files: {}", e),
        },
        Err(e) => ServerMessage::Error {
            code: "internal_error".to_string(),
            message: format!("Index task failed: {}", e),
        },
    }
}

pub fn file_rename_message(
    root: &Path,
    project: &str,
    workspace: &str,
    old_path: &str,
    new_name: &str,
) -> ServerMessage {
    match file_api::rename_file(root, old_path, new_name) {
        Ok(new_path) => {
            invalidate_file_index_cache(root);
            ServerMessage::FileRenameResult {
                project: project.to_string(),
                workspace: workspace.to_string(),
                old_path: old_path.to_string(),
                new_path,
                success: true,
                message: None,
            }
        }
        Err(e) => {
            let (_, message) = file_error_to_response(&e);
            ServerMessage::FileRenameResult {
                project: project.to_string(),
                workspace: workspace.to_string(),
                old_path: old_path.to_string(),
                new_path: String::new(),
                success: false,
                message: Some(message),
            }
        }
    }
}

pub fn file_delete_message(
    root: &Path,
    project: &str,
    workspace: &str,
    path: &str,
) -> ServerMessage {
    match file_api::delete_file(root, path) {
        Ok(()) => {
            invalidate_file_index_cache(root);
            ServerMessage::FileDeleteResult {
                project: project.to_string(),
                workspace: workspace.to_string(),
                path: path.to_string(),
                success: true,
                message: None,
            }
        }
        Err(e) => {
            let (_, message) = file_error_to_response(&e);
            ServerMessage::FileDeleteResult {
                project: project.to_string(),
                workspace: workspace.to_string(),
                path: path.to_string(),
                success: false,
                message: Some(message),
            }
        }
    }
}

pub fn file_copy_message(
    root: &Path,
    project: &str,
    workspace: &str,
    source_absolute_path: &str,
    dest_dir: &str,
) -> ServerMessage {
    match file_api::copy_file_from_absolute(root, source_absolute_path, dest_dir) {
        Ok(dest_path) => {
            invalidate_file_index_cache(root);
            ServerMessage::FileCopyResult {
                project: project.to_string(),
                workspace: workspace.to_string(),
                source_absolute_path: source_absolute_path.to_string(),
                dest_path,
                success: true,
                message: None,
            }
        }
        Err(e) => {
            let (_, message) = file_error_to_response(&e);
            ServerMessage::FileCopyResult {
                project: project.to_string(),
                workspace: workspace.to_string(),
                source_absolute_path: source_absolute_path.to_string(),
                dest_path: String::new(),
                success: false,
                message: Some(message),
            }
        }
    }
}

pub fn file_move_message(
    root: &Path,
    project: &str,
    workspace: &str,
    old_path: &str,
    new_dir: &str,
) -> ServerMessage {
    match file_api::move_file(root, old_path, new_dir) {
        Ok(new_path) => {
            invalidate_file_index_cache(root);
            ServerMessage::FileMoveResult {
                project: project.to_string(),
                workspace: workspace.to_string(),
                old_path: old_path.to_string(),
                new_path,
                success: true,
                message: None,
            }
        }
        Err(e) => {
            let (_, message) = file_error_to_response(&e);
            ServerMessage::FileMoveResult {
                project: project.to_string(),
                workspace: workspace.to_string(),
                old_path: old_path.to_string(),
                new_path: String::new(),
                success: false,
                message: Some(message),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn file_write_rejects_invalid_utf8_content() {
        let temp = TempDir::new().expect("create tempdir");
        let msg = file_write_message(temp.path(), "p", "w", "a.txt", &[0xff, 0xfe]);
        let ServerMessage::Error { code, .. } = msg else {
            panic!("expected error message");
        };
        assert_eq!(code, "invalid_utf8");
    }
}
