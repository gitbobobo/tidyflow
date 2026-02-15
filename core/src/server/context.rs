//! 共享上下文与错误类型
//!
//! 提供统一的工作空间路径解析、错误处理和 handler 上下文，
//! 消除各 handler 中重复的 `get_workspace_root` 和样板错误处理代码。

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use thiserror::Error;
use tokio::sync::{broadcast, mpsc, Mutex, RwLock};

use crate::server::lsp::LspSupervisor;
use crate::server::protocol::ServerMessage;
use crate::server::remote_sub_registry::SharedRemoteSubRegistry;
use crate::server::terminal_registry::{PtyFlowGate, SharedTerminalRegistry};
use crate::workspace::state::AppState;

/// 共享应用状态
pub type SharedAppState = Arc<RwLock<AppState>>;

/// 终端输出流控：per-terminal per-WS-connection 的背压状态
pub struct FlowControl {
    pub unacked: std::sync::atomic::AtomicU64,
    pub notify: tokio::sync::Notify,
}

/// subscribed_terms 的 value 类型：(转发任务句柄, 流控状态, PTY 背压门控)
pub type TermSubscription = (tokio::task::JoinHandle<()>, Arc<FlowControl>, Arc<PtyFlowGate>);

/// 正在运行的项目命令条目
pub struct RunningCommandEntry {
    pub task_id: String,
    pub project: String,
    pub workspace: String,
    pub command_id: String,
    pub child: tokio::process::Child,
}

/// 正在运行的项目命令注册表（task_id → 命令条目）
pub type SharedRunningCommands = Arc<Mutex<HashMap<String, RunningCommandEntry>>>;

/// 正在运行的 AI 任务条目
pub struct RunningAITaskEntry {
    pub task_id: String,
    pub project: String,
    pub workspace: String,
    pub operation_type: String, // "ai_commit" | "ai_merge"
    pub child_pid: Arc<std::sync::Mutex<Option<u32>>>,
    pub join_handle: tokio::task::JoinHandle<()>,
}

/// AI 任务注册表（task_id → 条目）
pub type SharedRunningAITasks = Arc<Mutex<HashMap<String, RunningAITaskEntry>>>;

/// 任务广播事件 — 用于跨连接同步后台任务状态
#[derive(Clone, Debug)]
pub struct TaskBroadcastEvent {
    /// 发起请求的连接 ID（广播时跳过自身）
    pub origin_conn_id: String,
    /// 要广播的消息
    pub message: ServerMessage,
}

/// 任务广播发送端
pub type TaskBroadcastTx = broadcast::Sender<TaskBroadcastEvent>;

/// WebSocket 连接元数据 — 在握手时构建
#[derive(Debug, Clone)]
pub struct ConnectionMeta {
    /// 连接唯一标识
    pub conn_id: String,
    /// 设备稳定标识（配对 token_id）；仅配对远程连接可用
    pub token_id: Option<String>,
    /// 是否为远程连接（非 loopback）
    pub is_remote: bool,
    /// 设备名称（从 pairing token 解析）
    pub device_name: Option<String>,
}

impl ConnectionMeta {
    /// 远程订阅身份：优先使用稳定 token_id，未配对时退回 conn_id
    pub fn remote_subscriber_id(&self) -> &str {
        self.token_id.as_deref().unwrap_or(&self.conn_id)
    }
}

/// Handler 上下文 — 收拢所有 handler 共享依赖，替代传递 11 个参数
#[derive(Clone)]
pub struct HandlerContext {
    pub app_state: SharedAppState,
    pub terminal_registry: SharedTerminalRegistry,
    pub save_tx: mpsc::Sender<()>,
    pub scrollback_tx: mpsc::Sender<(String, Vec<u8>)>,
    pub subscribed_terms: Arc<Mutex<HashMap<String, TermSubscription>>>,
    pub agg_tx: mpsc::Sender<(String, Vec<u8>)>,
    pub running_commands: SharedRunningCommands,
    pub running_ai_tasks: SharedRunningAITasks,
    pub cmd_output_tx: mpsc::Sender<ServerMessage>,
    pub task_broadcast_tx: TaskBroadcastTx,
    pub lsp_supervisor: LspSupervisor,
    pub conn_meta: ConnectionMeta,
    pub remote_sub_registry: SharedRemoteSubRegistry,
}

/// 统一应用错误类型 — 由调度层自动转换为 `ServerMessage::Error`
#[derive(Error, Debug)]
pub enum AppError {
    #[error("Project '{0}' not found")]
    ProjectNotFound(String),

    #[error("Workspace '{0}' not found")]
    WorkspaceNotFound(String),

    #[error("Git error: {0}")]
    Git(String),

    #[error("File error: {0}")]
    File(String),

    #[error("Internal error: {0}")]
    Internal(String),

    #[error("{0}")]
    Custom(String),
}

impl AppError {
    /// 转换为协议 error code
    pub fn code(&self) -> &str {
        match self {
            AppError::ProjectNotFound(_) => "project_not_found",
            AppError::WorkspaceNotFound(_) => "workspace_not_found",
            AppError::Git(_) => "git_error",
            AppError::File(_) => "file_error",
            AppError::Internal(_) => "internal_error",
            AppError::Custom(_) => "error",
        }
    }

    /// 转换为 ServerMessage::Error
    pub fn to_server_error(&self) -> ServerMessage {
        ServerMessage::Error {
            code: self.code().to_string(),
            message: self.to_string(),
        }
    }
}

/// 从 tokio JoinError 转换
impl From<tokio::task::JoinError> for AppError {
    fn from(e: tokio::task::JoinError) -> Self {
        AppError::Internal(format!("Task failed: {}", e))
    }
}

/// 已解析的工作空间上下文 — 统一 "查找项目 → 解析工作空间路径" 逻辑
#[derive(Debug, Clone)]
pub struct WorkspaceContext {
    pub project_name: String,
    pub workspace_name: String,
    pub root_path: PathBuf,
    pub default_branch: String,
}

/// 从 AppState 解析工作空间上下文（单一入口，替代 8 处重复的 `get_workspace_root`）
pub async fn resolve_workspace(
    app_state: &SharedAppState,
    project: &str,
    workspace: &str,
) -> Result<WorkspaceContext, AppError> {
    let state = app_state.read().await;
    let proj = state
        .get_project(project)
        .ok_or_else(|| AppError::ProjectNotFound(project.to_string()))?;

    let root_path = if workspace == "default" {
        proj.root_path.clone()
    } else {
        proj.get_workspace(workspace)
            .map(|w| w.worktree_path.clone())
            .ok_or_else(|| AppError::WorkspaceNotFound(workspace.to_string()))?
    };

    Ok(WorkspaceContext {
        project_name: project.to_string(),
        workspace_name: workspace.to_string(),
        root_path,
        default_branch: proj.default_branch.clone(),
    })
}

/// 仅解析项目（不需要工作空间路径的场景，如 integration 操作）
pub async fn resolve_project(
    app_state: &SharedAppState,
    project: &str,
) -> Result<ProjectContext, AppError> {
    let state = app_state.read().await;
    let proj = state
        .get_project(project)
        .ok_or_else(|| AppError::ProjectNotFound(project.to_string()))?;

    Ok(ProjectContext {
        project_name: proj.name.clone(),
        root_path: proj.root_path.clone(),
        default_branch: proj.default_branch.clone(),
    })
}

/// 已解析的项目上下文（不含工作空间）
#[derive(Debug, Clone)]
pub struct ProjectContext {
    pub project_name: String,
    pub root_path: PathBuf,
    pub default_branch: String,
}

/// 获取工作空间的源分支（用于 merge/rebase onto default 场景）
pub async fn resolve_workspace_branch(
    app_state: &SharedAppState,
    project: &str,
    workspace: &str,
) -> Result<(ProjectContext, String), AppError> {
    let state = app_state.read().await;
    let proj = state
        .get_project(project)
        .ok_or_else(|| AppError::ProjectNotFound(project.to_string()))?;

    let source_branch = if workspace == "default" {
        proj.default_branch.clone()
    } else {
        proj.get_workspace(workspace)
            .map(|w| w.branch.clone())
            .ok_or_else(|| AppError::WorkspaceNotFound(workspace.to_string()))?
    };

    let ctx = ProjectContext {
        project_name: proj.name.clone(),
        root_path: proj.root_path.clone(),
        default_branch: proj.default_branch.clone(),
    };

    Ok((ctx, source_branch))
}
