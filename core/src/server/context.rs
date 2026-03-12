//! 共享上下文与错误类型
//!
//! 提供统一的工作空间路径解析、错误处理和 handler 上下文，
//! 消除各 handler 中重复的 `get_workspace_root` 和样板错误处理代码。

use chrono::Utc;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use thiserror::Error;
use tokio::sync::{broadcast, mpsc, Mutex, RwLock};

use crate::server::handlers::ai::SharedAIState;
use crate::server::protocol::ServerMessage;
use crate::server::remote_sub_registry::SharedRemoteSubRegistry;
use crate::server::terminal_registry::{PtyFlowGate, SharedTerminalRegistry};
use crate::workspace::state::AppState;
use crate::workspace::state_store::StateStore;

/// 共享应用状态
pub type SharedAppState = Arc<RwLock<AppState>>;

/// 终端输出流控：per-terminal per-WS-connection 的背压状态
pub struct FlowControl {
    pub unacked: std::sync::atomic::AtomicU64,
    pub notify: tokio::sync::Notify,
}

/// subscribed_terms 的 value 类型：(转发任务句柄, 流控状态, PTY 背压门控)
pub type TermSubscription = (
    tokio::task::JoinHandle<()>,
    Arc<FlowControl>,
    Arc<PtyFlowGate>,
);

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

/// 任务历史条目 — 用于统一运行状态面板与 iOS 重连后恢复任务状态
#[derive(Debug, Clone)]
pub struct TaskHistoryEntry {
    pub task_id: String,
    pub project: String,
    pub workspace: String,
    pub task_type: String, // "project_command" | "ai_commit" | "ai_merge"
    pub command_id: Option<String>,
    pub title: String,
    pub status: String, // "running" | "completed" | "failed" | "cancelled"
    pub message: Option<String>,
    pub started_at: i64, // Unix timestamp ms
    pub completed_at: Option<i64>,
    /// 失败诊断码（与 AppError::code() 对齐）
    pub error_code: Option<String>,
    /// 失败诊断详情
    pub error_detail: Option<String>,
}

/// 任务历史注册表（全局共享，上限 200 条）
pub type SharedTaskHistory = Arc<Mutex<Vec<TaskHistoryEntry>>>;

/// 向任务历史注册表追加条目（超过上限时移除最早的已完成条目）
pub async fn push_task_history(history: &SharedTaskHistory, entry: TaskHistoryEntry) {
    let mut h = history.lock().await;
    h.push(entry);
    // 超过 200 条时移除最早的已完成条目
    while h.len() > 200 {
        if let Some(pos) = h.iter().position(|e| e.status != "running") {
            h.remove(pos);
        } else {
            break;
        }
    }
}

/// 更新任务历史条目状态（含失败诊断信息）
pub async fn update_task_history(
    history: &SharedTaskHistory,
    task_id: &str,
    status: &str,
    message: Option<String>,
) {
    update_task_history_with_diagnostics(history, task_id, status, message, None, None).await;
}

/// 更新任务历史条目状态，支持附加失败诊断码与详情
pub async fn update_task_history_with_diagnostics(
    history: &SharedTaskHistory,
    task_id: &str,
    status: &str,
    message: Option<String>,
    error_code: Option<String>,
    error_detail: Option<String>,
) {
    let mut h = history.lock().await;
    if let Some(entry) = h.iter_mut().find(|e| e.task_id == task_id) {
        entry.status = status.to_string();
        entry.message = message;
        if status == "failed" {
            entry.error_code = error_code;
            entry.error_detail = error_detail;
        }
        if status != "running" {
            entry.completed_at = Some(Utc::now().timestamp_millis());
        }
    }
}

/// 任务广播事件 — 用于跨连接同步后台任务状态
#[derive(Clone, Debug)]
pub struct TaskBroadcastEvent {
    /// 发起请求的连接 ID（广播时跳过自身）
    pub origin_conn_id: String,
    /// 要广播的消息
    pub message: ServerMessage,
    /// 可选目标连接集合：`None` 表示广播给全部连接（除 origin_conn_id）
    pub target_conn_ids: Option<Arc<HashSet<String>>>,
    /// 仅在“连接发起的广播”场景启用单接收者优化
    pub skip_when_single_receiver: bool,
}

/// 任务广播发送端
pub type TaskBroadcastTx = broadcast::Sender<TaskBroadcastEvent>;

/// 发送任务广播消息（广播给所有连接，跳过发起者）
pub fn send_task_broadcast_message(
    task_broadcast_tx: &TaskBroadcastTx,
    origin_conn_id: impl Into<String>,
    message: ServerMessage,
) -> bool {
    send_task_broadcast_event(
        task_broadcast_tx,
        TaskBroadcastEvent {
            origin_conn_id: origin_conn_id.into(),
            message,
            target_conn_ids: None,
            skip_when_single_receiver: true,
        },
    )
}

/// 发送任务广播消息（仅广播给目标连接集合，且跳过发起者）
pub fn send_task_broadcast_message_to(
    task_broadcast_tx: &TaskBroadcastTx,
    origin_conn_id: impl Into<String>,
    message: ServerMessage,
    target_conn_ids: HashSet<String>,
) -> bool {
    send_task_broadcast_event(
        task_broadcast_tx,
        TaskBroadcastEvent {
            origin_conn_id: origin_conn_id.into(),
            message,
            target_conn_ids: Some(Arc::new(target_conn_ids)),
            skip_when_single_receiver: true,
        },
    )
}

/// 统一任务广播发送入口，包含性能保护与采样计数。
pub fn send_task_broadcast_event(
    task_broadcast_tx: &TaskBroadcastTx,
    event: TaskBroadcastEvent,
) -> bool {
    // 仅有 1 个订阅者时广播没有意义（发送方连接会被 origin 过滤），直接跳过。
    if event.skip_when_single_receiver && task_broadcast_tx.receiver_count() <= 1 {
        crate::server::perf::record_task_broadcast_skipped_single_receiver();
        return false;
    }

    if let Some(targets) = event.target_conn_ids.as_ref() {
        if targets.is_empty() {
            crate::server::perf::record_task_broadcast_skipped_empty_target();
            return false;
        }
    }

    task_broadcast_tx.send(event).is_ok()
}

/// WebSocket 连接元数据 — 在握手时构建
#[derive(Debug, Clone)]
pub struct ConnectionMeta {
    /// 连接唯一标识
    pub conn_id: String,
    /// 远程 API key 标识；仅远程 key 连接可用
    pub api_key_id: Option<String>,
    /// 客户端实例标识；同一个 API key 可被多设备复用，因此必须独立建模
    pub client_id: Option<String>,
    /// 稳定远程订阅标识：`<key_id>:<client_id>`
    pub subscriber_id: Option<String>,
    /// 是否为远程连接（非 loopback）
    pub is_remote: bool,
    /// 设备名称（从客户端元数据解析）
    pub device_name: Option<String>,
}

impl ConnectionMeta {
    /// 远程订阅身份：优先使用稳定 subscriber_id，缺失时退回 conn_id
    pub fn remote_subscriber_id(&self) -> &str {
        self.subscriber_id.as_deref().unwrap_or(&self.conn_id)
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
    pub task_history: SharedTaskHistory,
    pub conn_meta: ConnectionMeta,
    pub remote_sub_registry: SharedRemoteSubRegistry,
    pub ai_state: SharedAIState,
    /// StateStore 引用（终端恢复元数据持久化，WI-002/WI-003）
    pub state_store: Arc<StateStore>,
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

    /// AI 会话操作失败
    #[error("AI session error: {0}")]
    AISession(String),

    /// Evolution 阶段执行失败
    #[error("Evolution error: {0}")]
    Evolution(String),
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
            AppError::AISession(_) => "ai_session_error",
            AppError::Evolution(_) => "evolution_error",
        }
    }

    /// 转换为 ServerMessage::Error（无上下文，向后兼容）
    pub fn to_server_error(&self) -> ServerMessage {
        ServerMessage::Error {
            code: self.code().to_string(),
            message: self.to_string(),
            project: None,
            workspace: None,
            session_id: None,
            cycle_id: None,
        }
    }

    /// 转换为 ServerMessage::Error（带多工作区定位上下文）
    pub fn to_server_error_with_context(
        &self,
        project: Option<String>,
        workspace: Option<String>,
        session_id: Option<String>,
        cycle_id: Option<String>,
    ) -> ServerMessage {
        ServerMessage::Error {
            code: self.code().to_string(),
            message: self.to_string(),
            project,
            workspace,
            session_id,
            cycle_id,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn task_broadcast_skips_when_only_single_receiver() {
        let (tx, mut rx) = broadcast::channel::<TaskBroadcastEvent>(8);
        let sent = send_task_broadcast_message(&tx, "origin", ServerMessage::Pong);
        assert!(!sent);
        assert!(matches!(
            rx.try_recv(),
            Err(broadcast::error::TryRecvError::Empty)
        ));
    }

    #[test]
    fn task_broadcast_skips_when_target_set_is_empty() {
        let (tx, mut rx1) = broadcast::channel::<TaskBroadcastEvent>(8);
        let mut rx2 = tx.subscribe();
        let sent = send_task_broadcast_message_to(
            &tx,
            "origin",
            ServerMessage::Pong,
            HashSet::<String>::new(),
        );
        assert!(!sent);
        assert!(matches!(
            rx1.try_recv(),
            Err(broadcast::error::TryRecvError::Empty)
        ));
        assert!(matches!(
            rx2.try_recv(),
            Err(broadcast::error::TryRecvError::Empty)
        ));
    }

    #[test]
    fn task_broadcast_attaches_target_set() {
        let (tx, mut rx1) = broadcast::channel::<TaskBroadcastEvent>(8);
        let mut rx2 = tx.subscribe();
        let mut targets = HashSet::new();
        targets.insert("conn-2".to_string());

        let sent = send_task_broadcast_message_to(&tx, "origin", ServerMessage::Pong, targets);
        assert!(sent);

        let event1 = rx1.try_recv().expect("first receiver should receive event");
        let event2 = rx2
            .try_recv()
            .expect("second receiver should receive event");
        assert_eq!(event1.origin_conn_id, "origin");
        assert_eq!(event2.origin_conn_id, "origin");
        assert!(event1
            .target_conn_ids
            .as_ref()
            .expect("target set should exist")
            .contains("conn-2"));
        assert!(event2
            .target_conn_ids
            .as_ref()
            .expect("target set should exist")
            .contains("conn-2"));
    }
}
