//! File Index API for workspace file indexing
//!
//! Provides recursive file listing for Quick Open (Cmd+P) functionality.
//! Filters out common build artifacts and version control directories.

use std::path::{Path, PathBuf};
use tracing::{debug, warn};

/// Maximum number of files to return (prevents memory issues on large repos)
pub const MAX_FILE_COUNT: usize = 50000;

/// Default directories to ignore during indexing
pub const DEFAULT_IGNORE_DIRS: &[&str] = &[
    ".git",
    ".build",
    ".swiftpm",
    ".worktree",
    "node_modules",
    ".DS_Store",
    "dist",
    "target",
    "build",
    ".next",
    ".nuxt",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    "venv",
    ".venv",
    "Pods",
    "DerivedData",
];

/// Result of file indexing operation
#[derive(Debug, Clone)]
pub struct FileIndexResult {
    pub items: Vec<String>,
    pub truncated: bool,
}

/// Index all files in a workspace directory recursively
///
/// Returns relative paths from workspace_root, filtering out ignored directories.
/// Stops at MAX_FILE_COUNT to prevent memory issues.
pub fn index_files(workspace_root: &Path) -> Result<FileIndexResult, std::io::Error> {
    let mut items = Vec::new();
    let mut truncated = false;

    // Canonicalize root for safety checks
    let root_canonical = workspace_root.canonicalize()?;

    // Stack-based traversal to avoid deep recursion
    let mut stack: Vec<PathBuf> = vec![root_canonical.clone()];

    while let Some(current_dir) = stack.pop() {
        if items.len() >= MAX_FILE_COUNT {
            truncated = true;
            break;
        }

        let entries = match std::fs::read_dir(&current_dir) {
            Ok(e) => e,
            Err(e) => {
                debug!("Failed to read directory {:?}: {}", current_dir, e);
                continue;
            }
        };

        for entry in entries {
            if items.len() >= MAX_FILE_COUNT {
                truncated = true;
                break;
            }

            let entry = match entry {
                Ok(e) => e,
                Err(_) => continue,
            };

            let path = entry.path();
            let file_name = match entry.file_name().to_str() {
                Some(n) => n.to_string(),
                None => continue,
            };

            // 跳过隐藏文件（以 . 开头）
            if file_name.starts_with('.') {
                continue;
            }

            // 优先使用 file_type()（不发起额外 syscall），仅对符号链接再 canonicalize
            let file_type = match entry.file_type() {
                Ok(ft) => ft,
                Err(_) => continue,
            };

            if file_type.is_symlink() {
                // 解析符号链接目标，检查是否越界，然后按目标类型分流
                if let Ok(canonical) = path.canonicalize() {
                    if !canonical.starts_with(&root_canonical) {
                        warn!("Skipping symlink escaping root: {:?}", path);
                        continue;
                    }
                    // 读取链接目标的 metadata（一次 stat）
                    match std::fs::metadata(&canonical) {
                        Ok(m) if m.is_dir() => {
                            let target_name =
                                canonical.file_name().and_then(|n| n.to_str()).unwrap_or("");
                            if !should_ignore_dir(target_name) {
                                stack.push(canonical);
                            }
                        }
                        Ok(m) if m.is_file() => {
                            if let Ok(relative) = canonical.strip_prefix(&root_canonical) {
                                items.push(relative.to_string_lossy().to_string());
                            }
                        }
                        _ => {}
                    }
                }
            } else if file_type.is_dir() {
                if should_ignore_dir(&file_name) {
                    continue;
                }
                stack.push(path);
            } else if file_type.is_file() {
                // Get relative path from root
                if let Ok(relative) = path.strip_prefix(&root_canonical) {
                    items.push(relative.to_string_lossy().to_string());
                }
            }
        }
    }

    // 预先构建搜索 key，避免排序比较器中重复分配 lowercase 字符串。
    let mut keyed_items: Vec<(String, String)> = items
        .into_iter()
        .map(|item| (item.to_lowercase(), item))
        .collect();
    keyed_items.sort_unstable_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
    let items: Vec<String> = keyed_items.into_iter().map(|(_, item)| item).collect();

    debug!(
        "Indexed {} files from {:?} (truncated: {})",
        items.len(),
        workspace_root,
        truncated
    );

    Ok(FileIndexResult { items, truncated })
}

// ── 文件内容搜索 ──

/// 搜索结果最大条目数
pub const MAX_SEARCH_RESULTS: usize = 1000;
/// 搜索扫描文件数上限
pub const MAX_SEARCH_FILES: usize = 5000;
/// 上下文行数（前后各 N 行）
const CONTEXT_LINES: usize = 2;
/// 二进制检测采样大小
const BINARY_CHECK_SIZE: usize = 8192;

/// 内部搜索结果（不含协议序列化标注）
#[derive(Debug, Clone)]
pub struct FileContentSearchResultInternal {
    pub items: Vec<FileContentSearchItemInternal>,
    pub total_matches: u32,
    pub truncated: bool,
    pub search_duration_ms: u64,
}

/// 内部单条匹配结果
#[derive(Debug, Clone)]
pub struct FileContentSearchItemInternal {
    pub path: String,
    pub line: u32,
    pub column: u32,
    pub preview: String,
    pub match_ranges: Vec<(u32, u32)>,
    pub before_context: Vec<String>,
    pub after_context: Vec<String>,
}

/// 在工作区目录中递归搜索文件内容
///
/// 复用 `index_files` 相同的目录遍历和忽略逻辑，额外跳过二进制文件。
/// 返回匹配项列表，按 path ASC → line ASC → column ASC 排序。
pub fn search_file_contents(
    workspace_root: &Path,
    query: &str,
    case_sensitive: bool,
) -> Result<FileContentSearchResultInternal, std::io::Error> {
    let started = std::time::Instant::now();

    // 空查询直接返回空结果
    if query.is_empty() {
        return Ok(FileContentSearchResultInternal {
            items: Vec::new(),
            total_matches: 0,
            truncated: false,
            search_duration_ms: 0,
        });
    }

    let root_canonical = workspace_root.canonicalize()?;
    let search_query = if case_sensitive {
        query.to_string()
    } else {
        query.to_lowercase()
    };

    let mut items: Vec<FileContentSearchItemInternal> = Vec::new();
    let mut truncated = false;
    let mut files_scanned: usize = 0;

    // 收集所有需要搜索的文件路径（复用 index_files 的遍历逻辑）
    let mut file_paths: Vec<(PathBuf, String)> = Vec::new();
    let mut stack: Vec<PathBuf> = vec![root_canonical.clone()];

    while let Some(current_dir) = stack.pop() {
        if files_scanned + file_paths.len() >= MAX_SEARCH_FILES {
            truncated = true;
            break;
        }

        let entries = match std::fs::read_dir(&current_dir) {
            Ok(e) => e,
            Err(e) => {
                debug!("搜索时无法读取目录 {:?}: {}", current_dir, e);
                continue;
            }
        };

        for entry in entries {
            let entry = match entry {
                Ok(e) => e,
                Err(_) => continue,
            };

            let path = entry.path();
            let file_name = match entry.file_name().to_str() {
                Some(n) => n.to_string(),
                None => continue,
            };

            // 跳过隐藏文件（以 . 开头）
            if file_name.starts_with('.') {
                continue;
            }

            let file_type = match entry.file_type() {
                Ok(ft) => ft,
                Err(_) => continue,
            };

            if file_type.is_symlink() {
                if let Ok(canonical) = path.canonicalize() {
                    if !canonical.starts_with(&root_canonical) {
                        continue;
                    }
                    match std::fs::metadata(&canonical) {
                        Ok(m) if m.is_dir() => {
                            let target_name =
                                canonical.file_name().and_then(|n| n.to_str()).unwrap_or("");
                            if !should_ignore_dir(target_name) {
                                stack.push(canonical);
                            }
                        }
                        Ok(m) if m.is_file() => {
                            if let Ok(relative) = canonical.strip_prefix(&root_canonical) {
                                let rel_str = relative.to_string_lossy().to_string();
                                file_paths.push((canonical, rel_str));
                            }
                        }
                        _ => {}
                    }
                }
            } else if file_type.is_dir() {
                if should_ignore_dir(&file_name) {
                    continue;
                }
                stack.push(path);
            } else if file_type.is_file() {
                if let Ok(relative) = path.strip_prefix(&root_canonical) {
                    let rel_str = relative.to_string_lossy().to_string();
                    file_paths.push((path, rel_str));
                }
            }
        }
    }

    // 按路径排序，保证结果顺序确定
    file_paths.sort_by(|a, b| a.1.cmp(&b.1));

    // 逐文件搜索
    'outer: for (abs_path, rel_path) in &file_paths {
        if files_scanned >= MAX_SEARCH_FILES {
            truncated = true;
            break;
        }
        files_scanned += 1;

        // 读取文件内容，跳过无法读取的文件
        let content = match std::fs::read(abs_path) {
            Ok(c) => c,
            Err(_) => continue,
        };

        // 二进制检测：前 8KB 包含 null 字节则跳过
        let check_len = content.len().min(BINARY_CHECK_SIZE);
        if content[..check_len].contains(&0u8) {
            continue;
        }

        // 尝试转为 UTF-8，失败则跳过
        let text = match std::str::from_utf8(&content) {
            Ok(t) => t,
            Err(_) => continue,
        };

        let lines: Vec<&str> = text.lines().collect();

        for (line_idx, line) in lines.iter().enumerate() {
            let search_line = if case_sensitive {
                line.to_string()
            } else {
                line.to_lowercase()
            };

            // 查找本行所有匹配位置
            let mut match_ranges: Vec<(u32, u32)> = Vec::new();
            let mut search_start = 0;
            while let Some(pos) = search_line[search_start..].find(&search_query) {
                let abs_pos = search_start + pos;
                match_ranges.push((abs_pos as u32, (abs_pos + search_query.len()) as u32));
                search_start = abs_pos + 1;
                if search_start >= search_line.len() {
                    break;
                }
            }

            if match_ranges.is_empty() {
                continue;
            }

            // 收集上下文行
            let before_start = if line_idx >= CONTEXT_LINES {
                line_idx - CONTEXT_LINES
            } else {
                0
            };
            let before_context: Vec<String> = lines[before_start..line_idx]
                .iter()
                .map(|s| s.to_string())
                .collect();

            let after_end = (line_idx + 1 + CONTEXT_LINES).min(lines.len());
            let after_context: Vec<String> = lines[line_idx + 1..after_end]
                .iter()
                .map(|s| s.to_string())
                .collect();

            // 每个匹配范围作为第一列（首个 match_range 的起始），但一行合并为一条
            let column = match_ranges[0].0;
            items.push(FileContentSearchItemInternal {
                path: rel_path.clone(),
                line: (line_idx + 1) as u32,
                column,
                preview: line.to_string(),
                match_ranges,
                before_context,
                after_context,
            });

            if items.len() >= MAX_SEARCH_RESULTS {
                truncated = true;
                break 'outer;
            }
        }
    }

    let search_duration_ms = started.elapsed().as_millis() as u64;
    let total_matches = items.len() as u32;

    // 结果已按 path ASC 排序（因为 file_paths 已排序），行内按出现顺序自然 ASC
    // 如需严格保证，可再排序一次
    items.sort_by(|a, b| {
        a.path
            .cmp(&b.path)
            .then_with(|| a.line.cmp(&b.line))
            .then_with(|| a.column.cmp(&b.column))
    });

    debug!(
        "search_file_contents query={:?} matches={} files_scanned={} truncated={} duration_ms={}",
        query, total_matches, files_scanned, truncated, search_duration_ms
    );

    Ok(FileContentSearchResultInternal {
        items,
        total_matches,
        truncated,
        search_duration_ms,
    })
}

/// Check if a directory name should be ignored
fn should_ignore_dir(name: &str) -> bool {
    DEFAULT_IGNORE_DIRS.contains(&name)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn test_index_files_basic() {
        let temp = TempDir::new().unwrap();
        let root = temp.path();

        // Create test structure
        fs::create_dir_all(root.join("src")).unwrap();
        fs::write(root.join("src/main.rs"), "fn main() {}").unwrap();
        fs::write(root.join("README.md"), "# Test").unwrap();

        let result = index_files(root).unwrap();
        assert!(!result.truncated);
        assert!(result.items.contains(&"src/main.rs".to_string()));
        assert!(result.items.contains(&"README.md".to_string()));
    }

    #[test]
    fn test_index_files_ignores_dirs() {
        let temp = TempDir::new().unwrap();
        let root = temp.path();

        // Create test structure with ignored dirs
        fs::create_dir_all(root.join("src")).unwrap();
        fs::create_dir_all(root.join("target/debug")).unwrap();
        fs::create_dir_all(root.join("node_modules/pkg")).unwrap();

        fs::write(root.join("src/lib.rs"), "").unwrap();
        fs::write(root.join("target/debug/app"), "").unwrap();
        fs::write(root.join("node_modules/pkg/index.js"), "").unwrap();

        let result = index_files(root).unwrap();

        assert!(result.items.contains(&"src/lib.rs".to_string()));
        assert!(!result.items.iter().any(|p| p.contains("target")));
        assert!(!result.items.iter().any(|p| p.contains("node_modules")));
    }

    #[test]
    fn test_index_files_ignores_hidden() {
        let temp = TempDir::new().unwrap();
        let root = temp.path();

        fs::write(root.join("visible.txt"), "").unwrap();
        fs::write(root.join(".hidden"), "").unwrap();

        let result = index_files(root).unwrap();

        assert!(result.items.contains(&"visible.txt".to_string()));
        assert!(!result.items.contains(&".hidden".to_string()));
    }
}
