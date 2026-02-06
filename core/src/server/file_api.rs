//! File API for workspace file operations
//!
//! Provides secure file list/read/write within workspace boundaries.

use std::collections::HashSet;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use tracing::{debug, warn};

/// Maximum file size: 1MB
pub const MAX_FILE_SIZE: u64 = 1_048_576;

/// Maximum path length
pub const MAX_PATH_LENGTH: usize = 4096;

/// File entry for directory listing
#[derive(Debug, Clone)]
pub struct FileEntry {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    /// 是否被 .gitignore 忽略
    pub is_ignored: bool,
    /// 是否为符号链接
    pub is_symlink: bool,
}

/// File API error types
#[derive(Debug)]
pub enum FileApiError {
    PathEscape,
    PathTooLong,
    FileNotFound,
    FileTooLarge,
    InvalidUtf8,
    IoError(std::io::Error),
    /// v1.23: 目标文件已存在
    TargetExists,
    /// v1.23: 无效的文件名
    InvalidName(String),
    /// v1.23: 回收站操作失败
    TrashError(String),
    /// v1.25: 不能将目录移入自身
    MoveIntoSelf,
}

impl std::fmt::Display for FileApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FileApiError::PathEscape => write!(f, "Path escapes workspace root"),
            FileApiError::PathTooLong => write!(f, "Path exceeds maximum length"),
            FileApiError::FileNotFound => write!(f, "File not found"),
            FileApiError::FileTooLarge => write!(f, "File exceeds 1MB limit"),
            FileApiError::InvalidUtf8 => write!(f, "File is not valid UTF-8"),
            FileApiError::IoError(e) => write!(f, "I/O error: {}", e),
            FileApiError::TargetExists => write!(f, "Target file already exists"),
            FileApiError::InvalidName(reason) => write!(f, "Invalid file name: {}", reason),
            FileApiError::TrashError(msg) => write!(f, "Trash error: {}", msg),
            FileApiError::MoveIntoSelf => write!(f, "Cannot move directory into itself"),
        }
    }
}

impl From<std::io::Error> for FileApiError {
    fn from(e: std::io::Error) -> Self {
        if e.kind() == std::io::ErrorKind::NotFound {
            FileApiError::FileNotFound
        } else {
            FileApiError::IoError(e)
        }
    }
}

/// Validate and resolve path within workspace root
/// Returns canonical path if valid, error if path escapes root
pub fn resolve_safe_path(
    workspace_root: &Path,
    relative_path: &str,
) -> Result<PathBuf, FileApiError> {
    // Check path length
    if relative_path.len() > MAX_PATH_LENGTH {
        return Err(FileApiError::PathTooLong);
    }

    // Normalize the relative path (handle . and ..)
    let mut components = Vec::new();
    for component in relative_path.split(['/', '\\']) {
        match component {
            "" | "." => continue,
            ".." => {
                if components.is_empty() {
                    // Trying to go above root
                    return Err(FileApiError::PathEscape);
                }
                components.pop();
            }
            c => components.push(c),
        }
    }

    // Build the full path
    let mut full_path = workspace_root.to_path_buf();
    for component in components {
        full_path.push(component);
    }

    // Verify the path is still under workspace root
    // Use canonicalize if path exists, otherwise check prefix
    if full_path.exists() {
        let canonical = full_path.canonicalize()?;
        let root_canonical = workspace_root.canonicalize()?;
        if !canonical.starts_with(&root_canonical) {
            warn!(
                "Path escape attempt: {:?} not under {:?}",
                canonical, root_canonical
            );
            return Err(FileApiError::PathEscape);
        }
        Ok(canonical)
    } else {
        // For non-existent paths (write), verify parent exists and is under root
        if let Some(parent) = full_path.parent() {
            if parent.exists() {
                let parent_canonical = parent.canonicalize()?;
                let root_canonical = workspace_root.canonicalize()?;
                if !parent_canonical.starts_with(&root_canonical) {
                    return Err(FileApiError::PathEscape);
                }
            }
        }
        Ok(full_path)
    }
}

/// 批量检查文件是否被 git 忽略
/// 返回被忽略的文件名集合
fn get_ignored_files(dir_path: &Path, file_names: &[String]) -> HashSet<String> {
    if file_names.is_empty() {
        return HashSet::new();
    }

    // 构建相对路径列表（相对于 dir_path）
    let input = file_names.join("\n");

    let output = match Command::new("git")
        .args(["check-ignore", "--stdin"])
        .current_dir(dir_path)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
    {
        Ok(mut child) => {
            if let Some(stdin) = child.stdin.as_mut() {
                let _ = stdin.write_all(input.as_bytes());
            }
            match child.wait_with_output() {
                Ok(o) => o,
                Err(_) => return HashSet::new(),
            }
        }
        Err(_) => return HashSet::new(),
    };

    // git check-ignore 返回被忽略的文件，每行一个
    let stdout = String::from_utf8_lossy(&output.stdout);
    stdout
        .lines()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// List files in a directory within workspace
pub fn list_files(
    workspace_root: &Path,
    relative_path: &str,
) -> Result<Vec<FileEntry>, FileApiError> {
    let dir_path = if relative_path.is_empty() || relative_path == "." {
        workspace_root.to_path_buf()
    } else {
        resolve_safe_path(workspace_root, relative_path)?
    };

    debug!("Listing files in: {:?}", dir_path);

    // 先收集所有文件名
    let mut raw_entries = Vec::new();
    for entry in fs::read_dir(&dir_path)? {
        let entry = entry?;
        // file_type() 不跟随符号链接，可正确检测 symlink
        let is_symlink = entry.file_type()?.is_symlink();
        // metadata() 跟随符号链接，is_dir/size 反映目标文件属性
        let metadata = entry.metadata()?;
        let name = entry.file_name().to_string_lossy().to_string();

        // 跳过 .git 目录和 .DS_Store 文件
        if name == ".git" || name == ".DS_Store" {
            continue;
        }

        raw_entries.push((name, metadata.is_dir(), metadata.len(), is_symlink));
    }

    // 批量检查 git 忽略状态
    let file_names: Vec<String> = raw_entries.iter().map(|(n, _, _, _)| n.clone()).collect();
    let ignored_set = get_ignored_files(&dir_path, &file_names);

    // 构建最终结果
    let mut entries: Vec<FileEntry> = raw_entries
        .into_iter()
        .map(|(name, is_dir, len, is_symlink)| {
            let is_ignored = ignored_set.contains(&name);
            FileEntry {
                name,
                is_dir,
                size: if !is_dir { len } else { 0 },
                is_ignored,
                is_symlink,
            }
        })
        .collect();

    // Sort: directories first, then alphabetically
    entries.sort_by(|a, b| match (a.is_dir, b.is_dir) {
        (true, false) => std::cmp::Ordering::Less,
        (false, true) => std::cmp::Ordering::Greater,
        _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
    });

    Ok(entries)
}

/// Read file content as UTF-8 string
pub fn read_file(
    workspace_root: &Path,
    relative_path: &str,
) -> Result<(String, u64), FileApiError> {
    let file_path = resolve_safe_path(workspace_root, relative_path)?;

    debug!("Reading file: {:?}", file_path);

    // Check file size
    let metadata = fs::metadata(&file_path)?;
    if metadata.len() > MAX_FILE_SIZE {
        return Err(FileApiError::FileTooLarge);
    }

    // Read content
    let mut file = fs::File::open(&file_path)?;
    let mut content = Vec::new();
    file.read_to_end(&mut content)?;

    // Validate UTF-8
    let text = String::from_utf8(content).map_err(|_| FileApiError::InvalidUtf8)?;
    let size = text.len() as u64;

    Ok((text, size))
}

/// Write file content atomically
pub fn write_file(
    workspace_root: &Path,
    relative_path: &str,
    content: &str,
) -> Result<u64, FileApiError> {
    let file_path = resolve_safe_path(workspace_root, relative_path)?;

    debug!("Writing file: {:?}", file_path);

    // Check content size
    let size = content.len() as u64;
    if size > MAX_FILE_SIZE {
        return Err(FileApiError::FileTooLarge);
    }

    // Create parent directories if needed
    if let Some(parent) = file_path.parent() {
        fs::create_dir_all(parent)?;
    }

    // Write to temp file first (atomic write)
    let temp_path = file_path.with_extension("tmp");
    {
        let mut temp_file = fs::File::create(&temp_path)?;
        temp_file.write_all(content.as_bytes())?;
        temp_file.sync_all()?;
    }

    // Rename temp to target (atomic on most filesystems)
    fs::rename(&temp_path, &file_path)?;

    Ok(size)
}

/// v1.23: 验证文件名是否有效
fn validate_filename(name: &str) -> Result<(), FileApiError> {
    // 不能为空
    if name.is_empty() {
        return Err(FileApiError::InvalidName("文件名不能为空".to_string()));
    }
    // 不能包含路径分隔符
    if name.contains('/') || name.contains('\\') {
        return Err(FileApiError::InvalidName(
            "文件名不能包含路径分隔符".to_string(),
        ));
    }
    // 不能是 . 或 ..
    if name == "." || name == ".." {
        return Err(FileApiError::InvalidName(
            "文件名不能是 . 或 ..".to_string(),
        ));
    }
    // 不能包含空字符
    if name.contains('\0') {
        return Err(FileApiError::InvalidName(
            "文件名不能包含空字符".to_string(),
        ));
    }
    Ok(())
}

/// v1.23: 重命名文件或目录
/// 返回新的相对路径
pub fn rename_file(
    workspace_root: &Path,
    old_path: &str,
    new_name: &str,
) -> Result<String, FileApiError> {
    // 验证新文件名
    validate_filename(new_name)?;

    // 解析旧路径
    let old_full_path = resolve_safe_path(workspace_root, old_path)?;
    if !old_full_path.exists() {
        return Err(FileApiError::FileNotFound);
    }

    // 计算新路径（同目录下）
    let parent = old_full_path.parent().ok_or(FileApiError::PathEscape)?;
    let new_full_path = parent.join(new_name);

    // 检查目标是否已存在
    if new_full_path.exists() {
        return Err(FileApiError::TargetExists);
    }

    // 验证新路径仍在工作空间内
    let root_canonical = workspace_root.canonicalize()?;
    let parent_canonical = parent.canonicalize()?;
    if !parent_canonical.starts_with(&root_canonical) {
        return Err(FileApiError::PathEscape);
    }

    debug!("Renaming {:?} to {:?}", old_full_path, new_full_path);

    // 执行重命名
    fs::rename(&old_full_path, &new_full_path)?;

    // 计算新的相对路径
    let new_relative = if let Some(parent_path) = Path::new(old_path).parent() {
        if parent_path.as_os_str().is_empty() || parent_path == Path::new(".") {
            new_name.to_string()
        } else {
            format!("{}/{}", parent_path.display(), new_name)
        }
    } else {
        new_name.to_string()
    };

    Ok(new_relative)
}

/// v1.23: 删除文件或目录（移到回收站）
pub fn delete_file(workspace_root: &Path, path: &str) -> Result<(), FileApiError> {
    let full_path = resolve_safe_path(workspace_root, path)?;
    if !full_path.exists() {
        return Err(FileApiError::FileNotFound);
    }

    debug!("Moving to trash: {:?}", full_path);

    // 使用 trash crate 移到回收站
    trash::delete(&full_path).map_err(|e| FileApiError::TrashError(e.to_string()))?;

    Ok(())
}

/// v1.24: 生成不冲突的文件名
/// 如果目标路径已存在，添加 (1), (2) 等后缀
fn generate_unique_path(dest_dir: &Path, name: &str) -> PathBuf {
    let dest_path = dest_dir.join(name);
    if !dest_path.exists() {
        return dest_path;
    }

    // 分离文件名和扩展名
    let (base_name, extension) = if let Some(dot_pos) = name.rfind('.') {
        // 检查是否是隐藏文件（以 . 开头且只有一个 .）
        if dot_pos == 0 {
            (name, "")
        } else {
            (&name[..dot_pos], &name[dot_pos..])
        }
    } else {
        (name, "")
    };

    // 尝试添加数字后缀
    for i in 1..1000 {
        let new_name = format!("{} ({}){}", base_name, i, extension);
        let new_path = dest_dir.join(&new_name);
        if !new_path.exists() {
            return new_path;
        }
    }

    // 极端情况：使用时间戳
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    dest_dir.join(format!("{}_{}{}", base_name, timestamp, extension))
}

/// v1.24: 递归复制目录
fn copy_dir_recursive(src: &Path, dest: &Path) -> Result<(), FileApiError> {
    fs::create_dir_all(dest)?;

    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let src_path = entry.path();
        let dest_path = dest.join(entry.file_name());

        if src_path.is_dir() {
            copy_dir_recursive(&src_path, &dest_path)?;
        } else {
            fs::copy(&src_path, &dest_path)?;
        }
    }

    Ok(())
}

/// v1.24: 复制文件或目录（支持绝对路径源）
/// 返回实际的目标相对路径（可能因重名而与预期不同）
pub fn copy_file_from_absolute(
    workspace_root: &Path,
    source_absolute_path: &str,
    dest_dir: &str,
) -> Result<String, FileApiError> {
    // 解析源路径（绝对路径）
    let source_full_path = Path::new(source_absolute_path);
    if !source_full_path.exists() {
        return Err(FileApiError::FileNotFound);
    }

    // 验证源路径是绝对路径
    if !source_full_path.is_absolute() {
        return Err(FileApiError::IoError(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "源路径必须是绝对路径",
        )));
    }

    // 解析目标目录
    let dest_dir_full = if dest_dir.is_empty() || dest_dir == "." {
        workspace_root.to_path_buf()
    } else {
        resolve_safe_path(workspace_root, dest_dir)?
    };

    if !dest_dir_full.exists() || !dest_dir_full.is_dir() {
        return Err(FileApiError::IoError(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "目标目录不存在",
        )));
    }

    // 获取源文件名
    let source_name = source_full_path
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| FileApiError::InvalidName("无法获取源文件名".to_string()))?;

    // 生成不冲突的目标路径
    let dest_full_path = generate_unique_path(&dest_dir_full, source_name);

    debug!(
        "Copying {:?} to {:?}",
        source_full_path, dest_full_path
    );

    // 执行复制
    if source_full_path.is_dir() {
        copy_dir_recursive(source_full_path, &dest_full_path)?;
    } else {
        fs::copy(source_full_path, &dest_full_path)?;
    }

    // 计算相对路径
    let root_canonical = workspace_root.canonicalize()?;
    let dest_canonical = dest_full_path.canonicalize()?;
    let relative_path = dest_canonical
        .strip_prefix(&root_canonical)
        .map_err(|_| FileApiError::PathEscape)?
        .to_string_lossy()
        .to_string();

    Ok(relative_path)
}

/// v1.25: 移动文件或目录到新目录
/// 返回新的相对路径
pub fn move_file(
    workspace_root: &Path,
    old_path: &str,
    new_dir: &str,
) -> Result<String, FileApiError> {
    // 解析源路径
    let old_full_path = resolve_safe_path(workspace_root, old_path)?;
    if !old_full_path.exists() {
        return Err(FileApiError::FileNotFound);
    }

    // 解析目标目录
    let new_dir_full = if new_dir.is_empty() || new_dir == "." {
        workspace_root.to_path_buf()
    } else {
        resolve_safe_path(workspace_root, new_dir)?
    };

    if !new_dir_full.exists() || !new_dir_full.is_dir() {
        return Err(FileApiError::FileNotFound);
    }

    // 防止将目录移入自身子目录
    if old_full_path.is_dir() {
        let old_canonical = old_full_path.canonicalize()?;
        let new_dir_canonical = new_dir_full.canonicalize()?;
        if new_dir_canonical.starts_with(&old_canonical) {
            return Err(FileApiError::MoveIntoSelf);
        }
    }

    // 获取源文件名
    let source_name = old_full_path
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| FileApiError::InvalidName("无法获取源文件名".to_string()))?;

    // 生成不冲突的目标路径
    let dest_full_path = generate_unique_path(&new_dir_full, source_name);

    debug!("Moving {:?} to {:?}", old_full_path, dest_full_path);

    // 执行移动（同文件系统下为原子操作）
    fs::rename(&old_full_path, &dest_full_path)?;

    // 计算相对路径
    let root_canonical = workspace_root.canonicalize()?;
    let dest_canonical = dest_full_path.canonicalize()?;
    let relative_path = dest_canonical
        .strip_prefix(&root_canonical)
        .map_err(|_| FileApiError::PathEscape)?
        .to_string_lossy()
        .to_string();

    Ok(relative_path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_path_escape_prevention() {
        let temp = TempDir::new().unwrap();
        let root = temp.path();

        // Valid paths
        assert!(resolve_safe_path(root, "file.txt").is_ok());
        assert!(resolve_safe_path(root, "dir/file.txt").is_ok());
        assert!(resolve_safe_path(root, "./file.txt").is_ok());
        assert!(resolve_safe_path(root, "dir/../file.txt").is_ok());

        // Invalid paths (escape attempts)
        assert!(matches!(
            resolve_safe_path(root, "../file.txt"),
            Err(FileApiError::PathEscape)
        ));
        assert!(matches!(
            resolve_safe_path(root, "dir/../../file.txt"),
            Err(FileApiError::PathEscape)
        ));
    }

    #[test]
    fn test_file_operations() {
        let temp = TempDir::new().unwrap();
        let root = temp.path();

        // Write file
        let content = "Hello, World!";
        let size = write_file(root, "test.txt", content).unwrap();
        assert_eq!(size, content.len() as u64);

        // Read file
        let (read_content, read_size) = read_file(root, "test.txt").unwrap();
        assert_eq!(read_content, content);
        assert_eq!(read_size, size);

        // List files
        let entries = list_files(root, ".").unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name, "test.txt");
        assert!(!entries[0].is_dir);
    }
}
