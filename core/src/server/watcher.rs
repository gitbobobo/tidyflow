//! 文件监控模块
//!
//! 使用 notify crate 监控工作空间文件变化，支持：
//! - 单工作空间监控（每个连接只监控一个工作空间）
//! - 500ms 防抖聚合事件
//! - 自动忽略 node_modules、.git/objects 等大目录

use notify::{RecommendedWatcher, RecursiveMode};
use notify_debouncer_mini::{new_debouncer, DebouncedEvent, Debouncer};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

/// 文件变化事件类型
#[derive(Debug, Clone)]
pub enum WatchEvent {
    /// 文件变化（创建、修改、删除）
    FileChanged {
        project: String,
        workspace: String,
        paths: Vec<String>,
        kind: String,
    },
    /// Git 状态变化（.git/index 或 .git/HEAD 变化）
    GitStatusChanged {
        project: String,
        workspace: String,
    },
}

/// 需要忽略的目录列表
const IGNORE_DIRS: &[&str] = &[
    "node_modules",
    ".git/objects",
    ".git/logs",
    "target",
    "build",
    "dist",
    ".next",
    ".nuxt",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    "venv",
    ".venv",
    "vendor",
    ".cargo",
];

/// 工作空间文件监控器
pub struct WorkspaceWatcher {
    /// 当前监控的项目名
    project: Option<String>,
    /// 当前监控的工作空间名
    workspace: Option<String>,
    /// 当前监控的路径
    watch_path: Option<PathBuf>,
    /// 防抖监控器
    debouncer: Option<Debouncer<RecommendedWatcher>>,
    /// 事件发送通道
    event_tx: mpsc::Sender<WatchEvent>,
}

impl WorkspaceWatcher {
    /// 创建新的监控器
    pub fn new(event_tx: mpsc::Sender<WatchEvent>) -> Self {
        Self {
            project: None,
            workspace: None,
            watch_path: None,
            debouncer: None,
            event_tx,
        }
    }

    /// 订阅工作空间监控
    /// 如果已有订阅，会先取消之前的订阅
    pub fn subscribe(
        &mut self,
        project: String,
        workspace: String,
        path: PathBuf,
    ) -> Result<(), String> {
        // 先取消之前的订阅
        self.unsubscribe();

        info!(
            "Subscribing to workspace: project={}, workspace={}, path={}",
            project,
            workspace,
            path.display()
        );

        // 验证路径存在
        if !path.exists() {
            return Err(format!("Path does not exist: {}", path.display()));
        }

        // 创建事件处理通道
        let (tx, rx) = std::sync::mpsc::channel();

        // 创建防抖监控器（500ms 防抖）
        let mut debouncer = new_debouncer(Duration::from_millis(500), tx)
            .map_err(|e| format!("Failed to create debouncer: {}", e))?;

        // 添加监控路径
        debouncer
            .watcher()
            .watch(&path, RecursiveMode::Recursive)
            .map_err(|e| format!("Failed to watch path: {}", e))?;

        // 启动事件处理线程
        let event_tx = self.event_tx.clone();
        let project_clone = project.clone();
        let workspace_clone = workspace.clone();
        let path_clone = path.clone();

        std::thread::spawn(move || {
            Self::event_loop(rx, event_tx, project_clone, workspace_clone, path_clone);
        });

        self.project = Some(project);
        self.workspace = Some(workspace);
        self.watch_path = Some(path);
        self.debouncer = Some(debouncer);

        Ok(())
    }

    /// 取消订阅
    pub fn unsubscribe(&mut self) {
        if let Some(ref project) = self.project {
            info!(
                "Unsubscribing from workspace: project={}, workspace={:?}",
                project, self.workspace
            );
        }

        // 丢弃 debouncer 会自动停止监控
        self.debouncer = None;
        self.project = None;
        self.workspace = None;
        self.watch_path = None;
    }

    /// 检查是否已订阅
    pub fn is_subscribed(&self) -> bool {
        self.debouncer.is_some()
    }

    /// 获取当前订阅信息
    pub fn current_subscription(&self) -> Option<(&str, &str)> {
        match (&self.project, &self.workspace) {
            (Some(p), Some(w)) => Some((p.as_str(), w.as_str())),
            _ => None,
        }
    }

    /// 事件处理循环
    fn event_loop(
        rx: std::sync::mpsc::Receiver<Result<Vec<DebouncedEvent>, notify::Error>>,
        event_tx: mpsc::Sender<WatchEvent>,
        project: String,
        workspace: String,
        root_path: PathBuf,
    ) {
        loop {
            match rx.recv() {
                Ok(Ok(events)) => {
                    Self::process_events(
                        events,
                        &event_tx,
                        &project,
                        &workspace,
                        &root_path,
                    );
                }
                Ok(Err(e)) => {
                    warn!("Watch error: {}", e);
                }
                Err(_) => {
                    // 通道关闭，退出循环
                    debug!("Watch channel closed, exiting event loop");
                    break;
                }
            }
        }
    }

    /// 处理防抖后的事件
    fn process_events(
        events: Vec<DebouncedEvent>,
        event_tx: &mpsc::Sender<WatchEvent>,
        project: &str,
        workspace: &str,
        root_path: &Path,
    ) {
        let mut file_paths: HashSet<String> = HashSet::new();
        let mut git_changed = false;

        for event in events {
            let path = &event.path;

            // 检查是否应该忽略
            if Self::should_ignore(path, root_path) {
                continue;
            }

            // 检查是否是 Git 相关文件
            if Self::is_git_status_file(path, root_path) {
                git_changed = true;
                continue;
            }

            // 转换为相对路径
            if let Ok(rel_path) = path.strip_prefix(root_path) {
                file_paths.insert(rel_path.to_string_lossy().to_string());
            }
        }

        // 发送 Git 状态变化事件
        if git_changed {
            let event = WatchEvent::GitStatusChanged {
                project: project.to_string(),
                workspace: workspace.to_string(),
            };
            if let Err(e) = event_tx.blocking_send(event) {
                warn!("Failed to send git status changed event: {}", e);
            }
        }

        // 发送文件变化事件
        if !file_paths.is_empty() {
            let paths: Vec<String> = file_paths.into_iter().collect();
            let event = WatchEvent::FileChanged {
                project: project.to_string(),
                workspace: workspace.to_string(),
                paths,
                kind: "modify".to_string(),
            };
            if let Err(e) = event_tx.blocking_send(event) {
                warn!("Failed to send file changed event: {}", e);
            }
        }
    }

    /// 检查路径是否应该被忽略
    fn should_ignore(path: &Path, root_path: &Path) -> bool {
        // 获取相对路径
        let rel_path = match path.strip_prefix(root_path) {
            Ok(p) => p,
            Err(_) => return false,
        };

        // 检查路径中是否包含需要忽略的目录
        for component in rel_path.components() {
            if let std::path::Component::Normal(name) = component {
                let name_str = name.to_string_lossy();
                for ignore_dir in IGNORE_DIRS {
                    if name_str == *ignore_dir {
                        return true;
                    }
                }
            }
        }

        // 检查完整路径是否匹配忽略模式（如 .git/objects）
        let rel_str = rel_path.to_string_lossy();
        for ignore_dir in IGNORE_DIRS {
            if rel_str.starts_with(ignore_dir) {
                return true;
            }
        }

        false
    }

    /// 检查是否是 Git 状态相关文件
    fn is_git_status_file(path: &Path, root_path: &Path) -> bool {
        let rel_path = match path.strip_prefix(root_path) {
            Ok(p) => p,
            Err(_) => return false,
        };

        let rel_str = rel_path.to_string_lossy();

        // 检查 .git/index（暂存区变化）
        if rel_str == ".git/index" {
            return true;
        }

        // 检查 .git/HEAD（分支切换）
        if rel_str == ".git/HEAD" {
            return true;
        }

        // 检查 .git/refs/heads/（分支创建/删除）
        if rel_str.starts_with(".git/refs/heads/") {
            return true;
        }

        // 检查 .git/COMMIT_EDITMSG（提交）
        if rel_str == ".git/COMMIT_EDITMSG" {
            return true;
        }

        false
    }
}

impl Drop for WorkspaceWatcher {
    fn drop(&mut self) {
        self.unsubscribe();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn test_should_ignore() {
        let root = PathBuf::from("/project");

        // 应该忽略的路径
        assert!(WorkspaceWatcher::should_ignore(
            &PathBuf::from("/project/node_modules/foo.js"),
            &root
        ));
        assert!(WorkspaceWatcher::should_ignore(
            &PathBuf::from("/project/.git/objects/ab/cd1234"),
            &root
        ));
        assert!(WorkspaceWatcher::should_ignore(
            &PathBuf::from("/project/target/debug/main"),
            &root
        ));

        // 不应该忽略的路径
        assert!(!WorkspaceWatcher::should_ignore(
            &PathBuf::from("/project/src/main.rs"),
            &root
        ));
        assert!(!WorkspaceWatcher::should_ignore(
            &PathBuf::from("/project/.git/index"),
            &root
        ));
    }

    #[test]
    fn test_is_git_status_file() {
        let root = PathBuf::from("/project");

        // Git 状态文件
        assert!(WorkspaceWatcher::is_git_status_file(
            &PathBuf::from("/project/.git/index"),
            &root
        ));
        assert!(WorkspaceWatcher::is_git_status_file(
            &PathBuf::from("/project/.git/HEAD"),
            &root
        ));
        assert!(WorkspaceWatcher::is_git_status_file(
            &PathBuf::from("/project/.git/refs/heads/main"),
            &root
        ));

        // 非 Git 状态文件
        assert!(!WorkspaceWatcher::is_git_status_file(
            &PathBuf::from("/project/src/main.rs"),
            &root
        ));
        assert!(!WorkspaceWatcher::is_git_status_file(
            &PathBuf::from("/project/.git/objects/ab/cd"),
            &root
        ));
    }
}

