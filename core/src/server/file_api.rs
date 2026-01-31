//! File API for workspace file operations
//!
//! Provides secure file list/read/write within workspace boundaries.

use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
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
pub fn resolve_safe_path(workspace_root: &Path, relative_path: &str) -> Result<PathBuf, FileApiError> {
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
            warn!("Path escape attempt: {:?} not under {:?}", canonical, root_canonical);
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

/// List files in a directory within workspace
pub fn list_files(workspace_root: &Path, relative_path: &str) -> Result<Vec<FileEntry>, FileApiError> {
    let dir_path = if relative_path.is_empty() || relative_path == "." {
        workspace_root.to_path_buf()
    } else {
        resolve_safe_path(workspace_root, relative_path)?
    };

    debug!("Listing files in: {:?}", dir_path);

    let mut entries = Vec::new();
    for entry in fs::read_dir(&dir_path)? {
        let entry = entry?;
        let metadata = entry.metadata()?;
        let name = entry.file_name().to_string_lossy().to_string();

        // Skip hidden files (starting with .)
        if name.starts_with('.') {
            continue;
        }

        entries.push(FileEntry {
            name,
            is_dir: metadata.is_dir(),
            size: if metadata.is_file() { metadata.len() } else { 0 },
        });
    }

    // Sort: directories first, then alphabetically
    entries.sort_by(|a, b| {
        match (a.is_dir, b.is_dir) {
            (true, false) => std::cmp::Ordering::Less,
            (false, true) => std::cmp::Ordering::Greater,
            _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
        }
    });

    Ok(entries)
}

/// Read file content as UTF-8 string
pub fn read_file(workspace_root: &Path, relative_path: &str) -> Result<(String, u64), FileApiError> {
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
pub fn write_file(workspace_root: &Path, relative_path: &str, content: &str) -> Result<u64, FileApiError> {
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
