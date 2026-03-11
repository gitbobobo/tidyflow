use std::collections::HashMap;
use std::path::Path;
use std::sync::{LazyLock, Mutex};
use std::time::Instant;
use tracing::debug;

use crate::server::file_api::{self, FileApiError};
use crate::server::file_index;
use crate::server::protocol::file::FileWorkspacePhase;
use crate::server::protocol::{FileEntryInfo, ServerMessage};
use crate::workspace::cache_metrics;

// ── 文件工作区相位追踪器 ──

/// 工作区文件系统相位键：`"project:workspace"`。
fn phase_key(project: &str, workspace: &str) -> String {
    format!("{}:{}", project, workspace)
}

/// 全局文件工作区相位表。
/// 按 `(project, workspace)` 隔离，运行时维护，不持久化。
static FILE_WORKSPACE_PHASES: LazyLock<Mutex<HashMap<String, FileWorkspacePhase>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// 文件工作区相位追踪器——统一的相位查询与迁移入口。
///
/// 所有相位迁移必须通过此模块的公开函数完成，不允许在 handler 或 watcher 中直接修改状态。
pub struct FileWorkspacePhaseTracker;

impl FileWorkspacePhaseTracker {
    /// 查询指定工作区当前相位。不存在时返回 `Idle`。
    pub fn current(project: &str, workspace: &str) -> FileWorkspacePhase {
        let key = phase_key(project, workspace);
        FILE_WORKSPACE_PHASES
            .lock()
            .ok()
            .and_then(|m| m.get(&key).copied())
            .unwrap_or_default()
    }

    /// 在持有锁的情况下原子地完成「读取当前相位 → 守卫判断 → 写入新相位」。
    /// 避免 check-then-set 之间被 `on_disconnect` 等全局操作插入导致状态丢失。
    fn transition(
        project: &str,
        workspace: &str,
        guard: impl FnOnce(FileWorkspacePhase) -> bool,
        next: FileWorkspacePhase,
    ) {
        let key = phase_key(project, workspace);
        if let Ok(mut map) = FILE_WORKSPACE_PHASES.lock() {
            let current = map.get(&key).copied().unwrap_or_default();
            if guard(current) {
                map.insert(key.clone(), next);
                if current != next {
                    debug!(
                        "FileWorkspacePhase transition: key={} {} -> {}",
                        key, current, next
                    );
                }
            }
        }
    }

    /// 无条件设置相位并记录迁移日志。
    fn set_unconditional(project: &str, workspace: &str, phase: FileWorkspacePhase) {
        let key = phase_key(project, workspace);
        if let Ok(mut map) = FILE_WORKSPACE_PHASES.lock() {
            let prev = map.insert(key.clone(), phase).unwrap_or_default();
            if prev != phase {
                debug!(
                    "FileWorkspacePhase transition: key={} {} -> {}",
                    key, prev, phase
                );
            }
        }
    }

    /// watcher 订阅成功时调用。
    pub fn on_watch_subscribed(project: &str, workspace: &str) {
        Self::set_unconditional(project, workspace, FileWorkspacePhase::Watching);
    }

    /// watcher 退订时调用。
    pub fn on_watch_unsubscribed(project: &str, workspace: &str) {
        Self::set_unconditional(project, workspace, FileWorkspacePhase::Idle);
    }

    /// 文件索引开始扫描时调用。
    pub fn on_indexing_started(project: &str, workspace: &str) {
        // 仅在 Idle 状态下迁移到 Indexing；Watching 状态下索引由缓存增量维护，不改变相位。
        Self::transition(
            project,
            workspace,
            |c| c == FileWorkspacePhase::Idle,
            FileWorkspacePhase::Indexing,
        );
    }

    /// 文件索引完成时调用。
    pub fn on_indexing_completed(project: &str, workspace: &str) {
        // 索引完成后若无 watcher，回到 Idle。
        Self::transition(
            project,
            workspace,
            |c| c == FileWorkspacePhase::Indexing,
            FileWorkspacePhase::Idle,
        );
    }

    /// watcher 遇到非致命错误时调用。
    pub fn on_watcher_degraded(project: &str, workspace: &str) {
        Self::transition(
            project,
            workspace,
            |c| c == FileWorkspacePhase::Watching,
            FileWorkspacePhase::Degraded,
        );
    }

    /// 开始恢复时调用。
    pub fn on_recovery_started(project: &str, workspace: &str) {
        Self::transition(
            project,
            workspace,
            |c| matches!(c, FileWorkspacePhase::Degraded | FileWorkspacePhase::Error),
            FileWorkspacePhase::Recovering,
        );
    }

    /// 恢复成功时调用。
    pub fn on_recovery_succeeded(project: &str, workspace: &str) {
        Self::transition(
            project,
            workspace,
            |c| c == FileWorkspacePhase::Recovering,
            FileWorkspacePhase::Watching,
        );
    }

    /// 恢复失败时调用。
    pub fn on_recovery_failed(project: &str, workspace: &str) {
        Self::transition(
            project,
            workspace,
            |c| c == FileWorkspacePhase::Recovering,
            FileWorkspacePhase::Error,
        );
    }

    /// 连接断开时重置所有工作区相位为 Idle。
    pub fn on_disconnect() {
        if let Ok(mut map) = FILE_WORKSPACE_PHASES.lock() {
            for phase in map.values_mut() {
                *phase = FileWorkspacePhase::Idle;
            }
            debug!("FileWorkspacePhase: all phases reset to idle on disconnect");
        }
    }

    /// 指定项目的所有工作区相位重置为 Idle。
    /// 用于项目级断连或清理场景，不影响其他项目的相位。
    pub fn on_disconnect_project(project: &str) {
        let prefix = format!("{}:", project);
        if let Ok(mut map) = FILE_WORKSPACE_PHASES.lock() {
            let mut count = 0usize;
            for (key, phase) in map.iter_mut() {
                if key.starts_with(&prefix) {
                    *phase = FileWorkspacePhase::Idle;
                    count += 1;
                }
            }
            if count > 0 {
                debug!(
                    "FileWorkspacePhase: reset {} entries for project '{}' on disconnect",
                    count, project
                );
            }
        }
    }

    /// 清除指定工作区的相位记录（工作区被删除时调用）。
    pub fn remove(project: &str, workspace: &str) {
        let key = phase_key(project, workspace);
        if let Ok(mut map) = FILE_WORKSPACE_PHASES.lock() {
            map.remove(&key);
        }
    }
}

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
        if cache.remove(&key).is_some() {
            cache_metrics::record_file_cache_eviction(&key, "invalidated");
        }
    }
}

/// 增量更新文件索引缓存：按事件类型精确增删缓存条目，避免全量重扫。
///
/// - `kind="removed"` 或 `kind="deleted"`：从缓存中删除指定路径。
/// - `kind="created"` 或 `kind="renamed"`：检查文件是否存在，若存在则插入缓存。
/// - `kind="modified"` 或其他类型：文件名未变，缓存条目无需调整。
///
/// 仅在缓存命中时生效；缓存未命中时退化为下次请求时的全量重建（正常兜底路径）。
/// TTL 不重置，保持原有 15s 过期逻辑。
pub fn update_file_index_incrementally(root: &Path, abs_paths: &[String], kind: &str) {
    let key = file_index_cache_key(root);
    let Ok(mut cache) = FILE_INDEX_CACHE.lock() else {
        return;
    };
    let Some(entry) = cache.get_mut(&key) else {
        // 缓存不存在，下次请求时全量重建，无需操作
        return;
    };

    // 将绝对路径转为相对路径（相对于 root）
    let rel_paths: Vec<String> = abs_paths
        .iter()
        .filter_map(|p| {
            let abs = Path::new(p);
            abs.strip_prefix(root)
                .ok()
                .map(|rel| rel.to_string_lossy().to_string())
        })
        .filter(|p| !p.is_empty())
        .collect();

    if rel_paths.is_empty() {
        return;
    }

    match kind {
        "removed" | "deleted" => {
            // 批量删除：构建待删除集合后过滤，O(n) 而非 O(n*m)
            let to_remove: std::collections::HashSet<&str> =
                rel_paths.iter().map(|p| p.as_str()).collect();
            let mut new_items = Vec::with_capacity(entry.items.len());
            let mut new_keys = Vec::with_capacity(entry.items.len());
            for (item, key_str) in entry.items.iter().zip(entry.item_search_keys.iter()) {
                if !to_remove.contains(item.as_str()) {
                    new_items.push(item.clone());
                    new_keys.push(key_str.clone());
                }
            }
            entry.items = new_items;
            entry.item_search_keys = new_keys;
        }
        "created" | "renamed" => {
            // 新增文件：先收集不重复的待插入项，再批量插入
            let to_insert: Vec<String> = {
                let existing: std::collections::HashSet<&str> =
                    entry.items.iter().map(|s| s.as_str()).collect();
                rel_paths
                    .iter()
                    .filter(|rel| {
                        !existing.contains(rel.as_str()) && root.join(rel.as_str()).is_file()
                    })
                    .cloned()
                    .collect()
            };
            // 此时 `existing` 已释放，可以安全地修改 entry
            for rel in to_insert {
                let lower = rel.to_lowercase();
                let pos = entry
                    .item_search_keys
                    .binary_search_by(|k| k.as_str().cmp(lower.as_str()))
                    .unwrap_or_else(|i| i);
                entry.items.insert(pos, rel);
                entry.item_search_keys.insert(pos, lower);
            }
        }
        // "modified" 及其他类型：路径未变，无需调整索引
        _ => {}
    }

    debug!(
        "Incremental file index update: root={:?}, kind={}, paths={:?}, cached_count={}",
        root,
        kind,
        rel_paths,
        entry.items.len()
    );
    cache_metrics::record_file_cache_incremental_update(
        &file_index_cache_key(root),
        entry.items.len(),
    );
}

fn read_file_index_cache(root: &Path) -> Option<(Vec<String>, Vec<String>, bool)> {
    let key = file_index_cache_key(root);
    let mut cache = FILE_INDEX_CACHE.lock().ok()?;
    let entry = cache.get(&key)?;
    if entry.created_at.elapsed().as_secs() >= FILE_INDEX_CACHE_TTL_SECS {
        cache.remove(&key);
        cache_metrics::record_file_cache_eviction(&key, "ttl_expired");
        return None;
    }
    cache_metrics::record_file_cache_hit(&key);
    Some((
        entry.items.clone(),
        entry.item_search_keys.clone(),
        entry.truncated,
    ))
}

fn write_file_index_cache(root: &Path, items: &[String], truncated: bool) {
    let key = file_index_cache_key(root);
    let item_count = items.len();
    let entry = FileIndexCacheEntry {
        items: items.to_vec(),
        item_search_keys: items.iter().map(|item| item.to_lowercase()).collect(),
        truncated,
        created_at: Instant::now(),
    };
    if let Ok(mut cache) = FILE_INDEX_CACHE.lock() {
        cache.insert(key.clone(), entry);
    }
    cache_metrics::record_file_cache_rebuild(&key, item_count);
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
    ServerMessage::Error {
        code,
        message,
        project: None,
        workspace: None,
        session_id: None,
        cycle_id: None,
    }
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
            project: None,
            workspace: None,
            session_id: None,
            cycle_id: None,
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

    // 缓存未命中：触发全量索引，通知相位追踪器进入 Indexing
    FileWorkspacePhaseTracker::on_indexing_started(project, workspace);

    let root_for_index = root.clone();
    let root_key = file_index_cache_key(&root);
    cache_metrics::record_file_cache_miss(&root_key);
    let walk_started = Instant::now();
    let result =
        tokio::task::spawn_blocking(move || file_index::index_files(&root_for_index)).await;

    // 索引完成：通知相位追踪器
    FileWorkspacePhaseTracker::on_indexing_completed(project, workspace);

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
            project: None,
            workspace: None,
            session_id: None,
            cycle_id: None,
        },
        Err(e) => ServerMessage::Error {
            code: "internal_error".to_string(),
            message: format!("Index task failed: {}", e),
            project: None,
            workspace: None,
            session_id: None,
            cycle_id: None,
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
    use crate::server::protocol::file::{FileChangeKind, FileWorkspacePhase};
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

    // ── FileWorkspacePhase 基础语义 ──

    #[test]
    fn phase_default_is_idle() {
        assert_eq!(FileWorkspacePhase::default(), FileWorkspacePhase::Idle);
    }

    #[test]
    fn phase_is_ready_only_for_watching() {
        assert!(!FileWorkspacePhase::Idle.is_ready());
        assert!(!FileWorkspacePhase::Indexing.is_ready());
        assert!(FileWorkspacePhase::Watching.is_ready());
        assert!(!FileWorkspacePhase::Degraded.is_ready());
        assert!(!FileWorkspacePhase::Error.is_ready());
        assert!(!FileWorkspacePhase::Recovering.is_ready());
    }

    #[test]
    fn phase_allows_write_except_error() {
        assert!(FileWorkspacePhase::Idle.allows_write());
        assert!(FileWorkspacePhase::Indexing.allows_write());
        assert!(FileWorkspacePhase::Watching.allows_write());
        assert!(FileWorkspacePhase::Degraded.allows_write());
        assert!(!FileWorkspacePhase::Error.allows_write());
        assert!(FileWorkspacePhase::Recovering.allows_write());
    }

    #[test]
    fn phase_needs_attention_for_degraded_error_recovering() {
        assert!(!FileWorkspacePhase::Idle.needs_attention());
        assert!(!FileWorkspacePhase::Indexing.needs_attention());
        assert!(!FileWorkspacePhase::Watching.needs_attention());
        assert!(FileWorkspacePhase::Degraded.needs_attention());
        assert!(FileWorkspacePhase::Error.needs_attention());
        assert!(FileWorkspacePhase::Recovering.needs_attention());
    }

    #[test]
    fn phase_display_matches_serde() {
        assert_eq!(FileWorkspacePhase::Idle.to_string(), "idle");
        assert_eq!(FileWorkspacePhase::Watching.to_string(), "watching");
        assert_eq!(FileWorkspacePhase::Error.to_string(), "error");
    }

    #[test]
    fn phase_serde_roundtrip() {
        let phase = FileWorkspacePhase::Degraded;
        let json = serde_json::to_string(&phase).unwrap();
        assert_eq!(json, "\"degraded\"");
        let parsed: FileWorkspacePhase = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, phase);
    }

    // ── FileChangeKind 基础语义 ──

    #[test]
    fn change_kind_from_watcher_str() {
        assert_eq!(FileChangeKind::from_watcher_str("created"), FileChangeKind::Created);
        assert_eq!(FileChangeKind::from_watcher_str("create"), FileChangeKind::Created);
        assert_eq!(FileChangeKind::from_watcher_str("removed"), FileChangeKind::Removed);
        assert_eq!(FileChangeKind::from_watcher_str("deleted"), FileChangeKind::Removed);
        assert_eq!(FileChangeKind::from_watcher_str("renamed"), FileChangeKind::Renamed);
        assert_eq!(FileChangeKind::from_watcher_str("modify"), FileChangeKind::Modified);
        assert_eq!(FileChangeKind::from_watcher_str("unknown"), FileChangeKind::Modified);
    }

    #[test]
    fn change_kind_as_str_roundtrip() {
        let kinds = [
            FileChangeKind::Created,
            FileChangeKind::Modified,
            FileChangeKind::Removed,
            FileChangeKind::Renamed,
        ];
        for kind in &kinds {
            let s = kind.as_str();
            let parsed = FileChangeKind::from_watcher_str(s);
            assert_eq!(*kind, parsed, "roundtrip failed for {}", s);
        }
    }

    #[test]
    fn change_kind_serde_roundtrip() {
        let kind = FileChangeKind::Renamed;
        let json = serde_json::to_string(&kind).unwrap();
        assert_eq!(json, "\"renamed\"");
        let parsed: FileChangeKind = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, kind);
    }
}
