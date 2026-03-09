//! 系统健康诊断与自修复协议类型
//!
//! 定义 Core 与客户端之间关于健康状态、异常列表与修复动作的标准契约。
//! 所有类型与 `app/TidyFlowShared/Protocol/SystemHealthModels.swift` 保持语义一致。
//!
//! ## 多项目隔离原则
//! - 每个 incident 必须携带上下文字段（project / workspace / session_id / cycle_id），
//!   系统级 incident 可以留空但不可以省略字段。
//! - repair action 必须按 system / project / workspace 边界执行，
//!   不能把一个工作区的修复动作误施加到另一个工作区。

use serde::{Deserialize, Serialize};

// ============================================================================
// 公共上下文字段（兼容多项目 / 多工作区 / 多会话并行场景）
// ============================================================================

/// 健康事件归属上下文
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub struct HealthContext {
    /// 项目名（系统级事件留空）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    /// 工作区名（系统级事件留空）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
    /// AI / Evolution 会话 ID
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// Evolution 循环 ID
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cycle_id: Option<String>,
}

impl HealthContext {
    pub fn system() -> Self {
        Self::default()
    }

    pub fn for_workspace(project: impl Into<String>, workspace: impl Into<String>) -> Self {
        Self {
            project: Some(project.into()),
            workspace: Some(workspace.into()),
            session_id: None,
            cycle_id: None,
        }
    }
}

// ============================================================================
// Incident（健康异常条目）
// ============================================================================

/// 异常严重级别
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[serde(rename_all = "snake_case")]
pub enum IncidentSeverity {
    /// 信息性提示，不影响功能
    Info,
    /// 降级警告，部分功能受限
    Warning,
    /// 关键故障，核心功能不可用
    Critical,
}

/// 异常可恢复性
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum IncidentRecoverability {
    /// 可由系统自动修复
    Recoverable,
    /// 需要人工干预
    Manual,
    /// 永久性故障（进程重启方可恢复）
    Permanent,
}

/// 异常来源
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum IncidentSource {
    /// Core 进程 / 连接层
    CoreProcess,
    /// 工作区缓存
    CoreWorkspaceCache,
    /// Evolution 任务
    CoreEvolution,
    /// Core 结构化日志（来自 error/critical 级别）
    CoreLog,
    /// 客户端连接状态
    ClientConnectivity,
    /// 客户端运行时状态
    ClientState,
}

/// 标准化健康异常条目
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthIncident {
    /// 稳定 ID，用于去重和幂等修复（建议用 `source::root_cause::context` 拼接后哈希）
    pub incident_id: String,
    pub severity: IncidentSeverity,
    pub recoverability: IncidentRecoverability,
    pub source: IncidentSource,
    /// 机器可读根因标识（例如 `workspace_cache_stale`）
    pub root_cause: String,
    /// 可选人类可读摘要
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    /// 首次发现时间（Unix ms）
    pub first_seen_at: u64,
    /// 最后一次确认时间（Unix ms）
    pub last_seen_at: u64,
    /// 归属上下文（多项目场景必须填入）
    pub context: HealthContext,
}

// ============================================================================
// Health Snapshot（系统健康快照）
// ============================================================================

/// 系统整体健康状态
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SystemHealthStatus {
    /// 一切正常
    Healthy,
    /// 存在 warning 级别异常
    Degraded,
    /// 存在 critical 级别异常
    Unhealthy,
}

/// 系统健康快照（权威真源，由 Core 聚合并向客户端推送）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SystemHealthSnapshot {
    /// 快照时间（Unix ms）
    pub snapshot_at: u64,
    pub overall_status: SystemHealthStatus,
    /// 未解决的 incident 列表（按 severity 降序）
    pub incidents: Vec<HealthIncident>,
    /// 最近修复审计摘要（最多 20 条）
    pub recent_repairs: Vec<RepairAuditEntry>,
}

// ============================================================================
// Repair Action（修复动作）
// ============================================================================

/// 可执行的修复动作类型
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RepairActionKind {
    /// 刷新健康快照（无副作用，始终安全）
    RefreshHealthSnapshot,
    /// 失效指定工作区缓存
    InvalidateWorkspaceCache,
    /// 重建指定工作区缓存
    RebuildWorkspaceCache,
    /// 恢复运行时订阅（remote_sub_registry 丢失连接后）
    RestoreSubscriptions,
}

/// 修复动作请求（由客户端或 Core 内部触发）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepairActionRequest {
    /// 请求幂等键（去重用）
    pub request_id: String,
    pub action: RepairActionKind,
    /// 修复范围上下文（必须携带，不得为系统级时省略工作区边界）
    pub context: HealthContext,
    /// 关联的 incident_id（可选，用于审计关联）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub incident_id: Option<String>,
}

/// 修复执行结果
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RepairOutcome {
    Success,
    AlreadyHealthy,
    Failed,
    PartialSuccess,
}

/// 修复执行审计记录
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepairAuditEntry {
    pub request_id: String,
    pub action: RepairActionKind,
    pub context: HealthContext,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub incident_id: Option<String>,
    pub outcome: RepairOutcome,
    /// 触发原因（`client_request` | `auto_heal` | `system_init`）
    pub trigger: String,
    /// 执行开始时间（Unix ms）
    pub started_at: u64,
    /// 执行耗时（ms）
    pub duration_ms: u64,
    /// 可选人类可读结果摘要
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result_summary: Option<String>,
    /// 修复后 incident 是否消除
    pub incident_resolved: bool,
}

// ============================================================================
// WS 消息扩展（ClientMessage / ServerMessage 的健康域载荷）
// ============================================================================

/// 客户端健康上报载荷（`health_report` action）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClientHealthReport {
    /// 客户端会话标识（用于多端并行归属）
    pub client_session_id: String,
    /// 客户端报告的连接质量（`good` | `degraded` | `lost`）
    pub connectivity: String,
    /// 客户端遇到的 incident 列表（由客户端本地检测产生）
    #[serde(default)]
    pub incidents: Vec<HealthIncident>,
    /// 归属上下文
    pub context: HealthContext,
    /// 上报时间（Unix ms）
    pub reported_at: u64,
}

/// 客户端修复命令回执载荷（`health_repair` action）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClientRepairRequest {
    pub request: RepairActionRequest,
}
