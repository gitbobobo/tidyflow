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
    /// 调度优化建议列表（v1.44，Core 权威输出）
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub scheduling_recommendations: Vec<SchedulingRecommendation>,
    /// 预测异常摘要列表（v1.44，Core 权威输出）
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub predictive_anomalies: Vec<PredictiveAnomaly>,
    /// 按 (project, workspace) 隔离的观测历史聚合（v1.44）
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub observation_aggregates: Vec<ObservationAggregate>,
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

// ============================================================================
// 调度优化建议（v1.44: 智能调度与预测性故障检测）
// ============================================================================

/// 调度优化建议类型
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum SchedulingRecommendationKind {
    /// 降低并发上限（资源压力过高）
    ReduceConcurrency,
    /// 提高并发上限（资源充裕）
    IncreaseConcurrency,
    /// 调整工作区优先级
    AdjustPriority,
    /// 启用降级策略（暂停低优先级工作区）
    EnableDegradation,
    /// 延迟排队（避免速率限制堆积）
    DeferQueuing,
}

/// 资源压力级别（Core 权威判定，客户端不重新推导）
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[serde(rename_all = "snake_case")]
pub enum ResourcePressureLevel {
    /// 资源充裕
    Low,
    /// 资源轻度紧张
    Moderate,
    /// 资源高度紧张
    High,
    /// 资源临界（可能触发降级）
    Critical,
}

/// 调度优化建议条目
///
/// 由 Core 根据历史聚合与实时观测生成，客户端只消费展示。
/// `context` 指明建议归属：系统级（全局并发）或工作区级（优先级调整）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SchedulingRecommendation {
    /// 建议唯一 ID（用于去重和客户端幂等消费）
    pub recommendation_id: String,
    pub kind: SchedulingRecommendationKind,
    /// 当前资源压力级别
    pub pressure_level: ResourcePressureLevel,
    /// 机器可读原因标识（例如 `ws_dispatch_latency_high`）
    pub reason: String,
    /// 人类可读建议摘要
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    /// 建议的目标值（如建议并发数、优先级值等，语义由 kind 决定）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub suggested_value: Option<i64>,
    /// 归属上下文（系统级建议 project/workspace 为 None）
    pub context: HealthContext,
    /// 建议生成时间（Unix ms）
    pub generated_at: u64,
    /// 建议有效期截止时间（Unix ms），超过后客户端应忽略
    pub expires_at: u64,
}

// ============================================================================
// 预测性异常摘要（v1.44: 智能调度与预测性故障检测）
// ============================================================================

/// 预测异常类型
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum PredictiveAnomalyKind {
    /// 性能退化趋势（延迟持续上升）
    PerformanceDegradation,
    /// 资源耗尽预警（终端内存、缓存预算等接近上限）
    ResourceExhaustion,
    /// 重复失败模式（同一工作区连续失败）
    RecurringFailure,
    /// 速率限制风险（API 调用频率接近限额）
    RateLimitRisk,
    /// 缓存命中率异常下降
    CacheEfficiencyDrop,
}

/// 预测置信度
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[serde(rename_all = "snake_case")]
pub enum PredictionConfidence {
    /// 低置信度（基于有限样本）
    Low,
    /// 中等置信度
    Medium,
    /// 高置信度（基于充分历史数据）
    High,
}

/// 预测时间窗口
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PredictionTimeWindow {
    /// 窗口开始时间（Unix ms）
    pub start_at: u64,
    /// 窗口结束时间（Unix ms）
    pub end_at: u64,
}

/// 预测异常摘要条目
///
/// 由 Core 根据历史观测聚合和趋势分析生成。
/// 每个异常携带 `(project, workspace)` 归属上下文，
/// 系统级预测（如全局性能退化）context 中 project/workspace 为 None。
/// 客户端不应根据零散 metrics 再次推理，直接消费 Core 权威输出。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PredictiveAnomaly {
    /// 预测异常唯一 ID
    pub anomaly_id: String,
    pub kind: PredictiveAnomalyKind,
    pub confidence: PredictionConfidence,
    /// 机器可读根因标识
    pub root_cause: String,
    /// 人类可读异常摘要
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    /// 预测有效时间窗口
    pub time_window: PredictionTimeWindow,
    /// 关联的历史 incident_id 列表（用于追溯）
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub related_incident_ids: Vec<String>,
    /// 归属上下文
    pub context: HealthContext,
    /// 预测评分（0.0-1.0，越高表示越可能发生）
    pub score: f64,
    /// 预测生成时间（Unix ms）
    pub predicted_at: u64,
}

// ============================================================================
// 历史观测聚合摘要（v1.44: 按 (project, workspace) 隔离）
// ============================================================================

/// 工作区观测历史聚合摘要
///
/// Core 权威生成，按 `(project, workspace)` 独立存储和恢复。
/// 聚合性能、缓存、终端资源和运行失败历史，供调度器和健康检测共享消费。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ObservationAggregate {
    /// 所属项目
    pub project: String,
    /// 所属工作区
    pub workspace: String,
    /// 聚合窗口开始时间（Unix ms）
    pub window_start: u64,
    /// 聚合窗口结束时间（Unix ms）
    pub window_end: u64,
    /// 历史循环成功次数
    pub cycle_success_count: u32,
    /// 历史循环失败次数
    pub cycle_failure_count: u32,
    /// 历史循环平均耗时（毫秒）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub avg_cycle_duration_ms: Option<u64>,
    /// 最近一次循环耗时（毫秒）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_cycle_duration_ms: Option<u64>,
    /// 连续失败次数（当前连续失败计数，成功后归零）
    pub consecutive_failures: u32,
    /// 缓存命中率（0.0-1.0）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_hit_ratio: Option<f64>,
    /// 最近速率限制事件计数
    pub rate_limit_hit_count: u32,
    /// 资源压力级别（Core 综合判定）
    pub pressure_level: ResourcePressureLevel,
    /// 综合健康评分（0.0-1.0，越高越健康）
    pub health_score: f64,
    /// 聚合时间（Unix ms）
    pub aggregated_at: u64,
}

// ============================================================================
// 质量门禁裁决（WI-002: Evolution 自动门禁）
// ============================================================================

/// 门禁裁决结果
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GateVerdict {
    /// 通过，允许推进到下一阶段
    Pass,
    /// 失败，需要重试或修复
    Fail,
    /// 跳过（健康数据不可用，门禁不阻断）
    Skip,
}

/// 门禁失败原因码（机器可读，客户端和脚本不需要从日志文本推断）
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GateFailureReason {
    /// 系统健康状态为 Unhealthy
    SystemUnhealthy,
    /// 存在阻断性 critical incident
    CriticalIncident,
    /// 证据完整性校验失败
    EvidenceIncomplete,
    /// 协议一致性检查失败
    ProtocolInconsistent,
    /// Core 回归测试失败
    CoreRegressionFailed,
    /// Apple 构建或回归失败
    AppleVerificationFailed,
    /// 自定义原因
    Custom(String),
}

/// 质量门禁裁决记录
///
/// 按 `(project, workspace, cycle_id)` 隔离存储和传播，
/// 不会因同名工作区或重连而串用其他项目状态。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GateDecision {
    /// 裁决结果
    pub verdict: GateVerdict,
    /// 失败原因列表（verdict == Pass 时为空）
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub failure_reasons: Vec<GateFailureReason>,
    /// 所属项目
    pub project: String,
    /// 所属工作区
    pub workspace: String,
    /// Evolution 循环 ID
    pub cycle_id: String,
    /// 裁决时健康快照的整体状态
    pub health_status: SystemHealthStatus,
    /// 裁决时的 verify 重试次数
    pub retry_count: u32,
    /// 是否为 bypass（绕过审计标记）
    #[serde(default)]
    pub bypassed: bool,
    /// bypass 原因（bypassed == true 时必须填入）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bypass_reason: Option<String>,
    /// 裁决时间（Unix ms）
    pub decided_at: u64,
}

// ============================================================================
// 智能演化分析摘要（v1.45: 统一分析契约）
// ============================================================================

/// 瓶颈类型分类（Core 权威判定，客户端不得重新推导）
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum BottleneckKind {
    /// 资源瓶颈（CPU / 内存 / 终端预算等）
    Resource,
    /// 速率限制瓶颈（API 调用频率受限）
    RateLimit,
    /// 重复失败瓶颈（同一工作区多次连续失败）
    RecurringFailure,
    /// 性能退化瓶颈（延迟持续上升）
    PerformanceDegradation,
    /// 配置瓶颈（Profile / 参数选择不当）
    Configuration,
    /// 协议一致性瓶颈（Schema / 版本不匹配）
    ProtocolInconsistency,
}

/// 分析建议的归属范围
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum AnalysisScopeLevel {
    /// 系统级建议（影响全局调度或资源分配）
    System,
    /// 工作区级建议（仅影响特定 project/workspace）
    Workspace,
}

/// 优化建议条目
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OptimizationSuggestion {
    /// 建议唯一 ID
    pub suggestion_id: String,
    /// 归属范围
    pub scope: AnalysisScopeLevel,
    /// 机器可读动作标识（例如 `reduce_concurrency`、`switch_ai_tool`、`defer_workspace`）
    pub action: String,
    /// 人类可读建议摘要
    pub summary: String,
    /// 建议优先级（1 = 最高）
    pub priority: u32,
    /// 预期改善描述（可选）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expected_impact: Option<String>,
    /// 归属上下文
    pub context: HealthContext,
}

/// 瓶颈分析条目
///
/// Core 根据门禁裁决、观测聚合、预测异常和调度建议综合判定，
/// 输出按 `(project, workspace, cycle_id)` 隔离的瓶颈识别结果。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BottleneckEntry {
    /// 瓶颈唯一 ID
    pub bottleneck_id: String,
    /// 瓶颈类型
    pub kind: BottleneckKind,
    /// 机器可读原因编码
    pub reason_code: String,
    /// 风险等级（0.0-1.0，越高风险越大）
    pub risk_score: f64,
    /// 人类可读证据摘要
    pub evidence_summary: String,
    /// 归属上下文
    pub context: HealthContext,
    /// 关联的 incident / anomaly / recommendation ID
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub related_ids: Vec<String>,
    /// 识别时间（Unix ms）
    pub detected_at: u64,
}

/// 智能演化分析摘要
///
/// 统一的可机读结构，聚合质量门禁结论、瓶颈识别、风险评分、
/// 证据摘要和优化建议。所有字段语义同时适用于 Core 协议模型、
/// HTTP/WS 输出和 Apple 共享模型。
///
/// 数据默认按 `(project, workspace, cycle_id)` 隔离；
/// 系统级建议和工作区级建议通过 `scope` 字段区分归属。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvolutionAnalysisSummary {
    /// 所属项目
    pub project: String,
    /// 所属工作区
    pub workspace: String,
    /// Evolution 循环 ID
    pub cycle_id: String,
    /// 质量门禁裁决（可选，门禁未执行时为 None）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gate_decision: Option<GateDecision>,
    /// 识别的瓶颈列表
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub bottlenecks: Vec<BottleneckEntry>,
    /// 综合风险评分（0.0-1.0，Core 权威判定）
    pub overall_risk_score: f64,
    /// 综合健康评分（0.0-1.0，来自 ObservationAggregate）
    pub health_score: f64,
    /// 资源压力级别
    pub pressure_level: ResourcePressureLevel,
    /// 关联的预测异常 ID 列表（详情通过 SystemHealthSnapshot 查询）
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub predictive_anomaly_ids: Vec<String>,
    /// 优化建议列表（系统级和工作区级混合，通过 scope 区分）
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub suggestions: Vec<OptimizationSuggestion>,
    /// 分析生成时间（Unix ms）
    pub analyzed_at: u64,
    /// 分析有效期截止时间（Unix ms）
    pub expires_at: u64,
}
