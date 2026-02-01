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

            // Skip hidden files (starting with .)
            if file_name.starts_with('.') {
                continue;
            }

            let metadata = match entry.metadata() {
                Ok(m) => m,
                Err(_) => continue,
            };

            if metadata.is_dir() {
                // Check if directory should be ignored
                if should_ignore_dir(&file_name) {
                    continue;
                }

                // Verify path is still under root (symlink safety)
                if let Ok(canonical) = path.canonicalize() {
                    if canonical.starts_with(&root_canonical) {
                        stack.push(path);
                    } else {
                        warn!("Skipping symlink escaping root: {:?}", path);
                    }
                }
            } else if metadata.is_file() {
                // Get relative path from root
                if let Ok(relative) = path.strip_prefix(&root_canonical) {
                    items.push(relative.to_string_lossy().to_string());
                }
            }
        }
    }

    // Sort for consistent ordering
    items.sort_by(|a, b| a.to_lowercase().cmp(&b.to_lowercase()));

    debug!(
        "Indexed {} files from {:?} (truncated: {})",
        items.len(),
        workspace_root,
        truncated
    );

    Ok(FileIndexResult { items, truncated })
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
