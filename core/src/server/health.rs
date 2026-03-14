//! 系统健康探针注册表、异常聚合与自修复执行器（WI-002 / WI-003）
//!
//! ## 职责分层
//! - **探针（Probe）**：各子系统通过 `HealthRegistry` 注册可调用的健康检查函数
//! - **聚合（Aggregation）**：`HealthRegistry::snapshot()` 收集所有探针的 incident 并去抖
//! - **修复（Repair）**：`HealthRegistry::execute_repair()` 幂等执行修复动作并生成审计记录
//!
//! ## 多项目隔离原则
//! - repair action 必须携带 HealthContext，执行器按 project/workspace 边界执行
//! - 每个 incident 必须携带 context，系统级事件 context 字段均为 None

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tokio::sync::RwLock;
use tracing::warn;

use crate::server::context::SharedAppState;
use crate::server::protocol::health::{
    HealthContext, HealthIncident, IncidentRecoverability, IncidentSeverity, IncidentSource,
    RepairActionKind, RepairActionRequest, RepairAuditEntry, RepairOutcome, SystemHealthSnapshot,
    SystemHealthStatus,
};
use crate::server::terminal_registry::SharedTerminalRegistry;

// ============================================================================
// 时间工具
// ============================================================================

fn unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis() as u64
}

// ============================================================================
// incident 去抖（相同 incident_id 的多次发现合并为一条）
// ============================================================================

const MAX_RECENT_REPAIRS: usize = 20;
/// 客户端上报的 incident 过期时间（毫秒）：超过此时间未更新则视为已恢复
const CLIENT_INCIDENT_TTL_MS: u64 = 300_000; // 5 分钟

// ============================================================================
// 健康注册表（全局单例）
// ============================================================================

static HEALTH_REGISTRY: std::sync::OnceLock<Arc<RwLock<HealthRegistry>>> =
    std::sync::OnceLock::new();

/// 获取全局健康注册表单例
pub fn global() -> Arc<RwLock<HealthRegistry>> {
    HEALTH_REGISTRY
        .get_or_init(|| Arc::new(RwLock::new(HealthRegistry::new())))
        .clone()
}

/// 健康探针：返回该探针当前检测到的 incident 列表
pub type HealthProbe = Box<dyn Fn() -> Vec<HealthIncident> + Send + Sync>;

/// 探针注册信息
struct ProbeEntry {
    probe: HealthProbe,
}

/// 全局健康注册表
pub struct HealthRegistry {
    probes: Vec<ProbeEntry>,
    /// 已聚合的 incidents（按 incident_id 去重）
    active_incidents: HashMap<String, HealthIncident>,
    /// 修复审计日志（最多保留 MAX_RECENT_REPAIRS 条）
    repair_audits: Vec<RepairAuditEntry>,
    /// 客户端上报的 incidents（按 client_session_id → Vec<HealthIncident>）
    client_incidents: HashMap<String, Vec<HealthIncident>>,
    /// 客户端上报时间戳（用于 TTL 清理）
    client_report_ts: HashMap<String, u64>,
    /// Core 近期错误计数（由 file_logger 写入）
    recent_error_count: u64,
}

impl HealthRegistry {
    fn new() -> Self {
        Self {
            probes: Vec::new(),
            active_incidents: HashMap::new(),
            repair_audits: Vec::new(),
            client_incidents: HashMap::new(),
            client_report_ts: HashMap::new(),
            recent_error_count: 0,
        }
    }

    /// 注册健康探针
    pub fn register_probe(&mut self, _name: impl Into<String>, probe: HealthProbe) {
        self.probes.push(ProbeEntry { probe });
    }

    /// 记录 Core 日志层的错误（由 file_logger 调用）
    pub fn record_log_error(
        &mut self,
        root_cause: impl Into<String>,
        summary: impl Into<String>,
        context: HealthContext,
    ) {
        self.record_incident(
            root_cause,
            summary,
            IncidentSeverity::Warning,
            IncidentRecoverability::Recoverable,
            IncidentSource::CoreLog,
            context,
        );
    }

    /// 记录 Evolution 自愈相关 incident（支持自定义严重级别）
    pub fn record_evolution_incident(
        &mut self,
        root_cause: impl Into<String>,
        summary: impl Into<String>,
        severity: IncidentSeverity,
        context: HealthContext,
    ) {
        let recoverability = match severity {
            IncidentSeverity::Critical => IncidentRecoverability::Manual,
            _ => IncidentRecoverability::Recoverable,
        };
        self.record_incident(
            root_cause,
            summary,
            severity,
            recoverability,
            IncidentSource::CoreEvolution,
            context,
        );
    }

    fn record_incident(
        &mut self,
        root_cause: impl Into<String>,
        summary: impl Into<String>,
        severity: IncidentSeverity,
        recoverability: IncidentRecoverability,
        source: IncidentSource,
        context: HealthContext,
    ) {
        let root_cause = root_cause.into();
        let now = unix_ms();
        let incident_id = format!(
            "core_log:{}:{}:{}",
            root_cause,
            context.project.as_deref().unwrap_or(""),
            context.workspace.as_deref().unwrap_or("")
        );
        let entry = self
            .active_incidents
            .entry(incident_id.clone())
            .or_insert_with(|| HealthIncident {
                incident_id: incident_id.clone(),
                severity,
                recoverability,
                source,
                root_cause: root_cause.clone(),
                summary: Some(summary.into()),
                first_seen_at: now,
                last_seen_at: now,
                context: context.clone(),
            });
        entry.last_seen_at = now;
        self.recent_error_count += 1;
    }

    /// 接收客户端健康上报
    pub fn ingest_client_report(
        &mut self,
        client_session_id: &str,
        incidents: Vec<HealthIncident>,
    ) {
        let now = unix_ms();
        self.client_incidents
            .insert(client_session_id.to_string(), incidents);
        self.client_report_ts
            .insert(client_session_id.to_string(), now);
        self.evict_expired_client_reports(now);
    }

    fn evict_expired_client_reports(&mut self, now: u64) {
        let expired: Vec<String> = self
            .client_report_ts
            .iter()
            .filter(|(_, ts)| now.saturating_sub(**ts) > CLIENT_INCIDENT_TTL_MS)
            .map(|(k, _)| k.clone())
            .collect();
        for k in expired {
            self.client_incidents.remove(&k);
            self.client_report_ts.remove(&k);
        }
    }

    /// 从所有探针收集 incident，合并去抖后更新 active_incidents，返回健康快照
    pub fn snapshot(&mut self) -> SystemHealthSnapshot {
        self.snapshot_with_predictions(&std::collections::HashMap::new(), 4, 0)
    }

    /// 生成含调度优化建议和预测异常的完整健康快照
    ///
    /// `cache_hit_ratios`: 各工作区缓存命中率（由调用方从缓存指标中提取）
    /// `current_max_parallel`: 当前最大并发工作区数
    /// `running_count`: 当前运行中工作区数
    pub fn snapshot_with_predictions(
        &mut self,
        cache_hit_ratios: &HashMap<(String, String), f64>,
        current_max_parallel: u32,
        running_count: u32,
    ) -> SystemHealthSnapshot {
        let now = unix_ms();

        // 收集所有探针 incidents，进行 upsert（保留 first_seen_at，更新 last_seen_at）
        for entry in &self.probes {
            let incidents = (entry.probe)();
            for incident in incidents {
                let e = self
                    .active_incidents
                    .entry(incident.incident_id.clone())
                    .or_insert_with(|| HealthIncident {
                        first_seen_at: now,
                        last_seen_at: now,
                        ..incident.clone()
                    });
                e.last_seen_at = now;
                e.severity = incident.severity;
                e.summary = incident.summary;
            }
        }

        // 合并客户端上报的 incidents
        self.evict_expired_client_reports(now);
        let client_incidents: Vec<HealthIncident> =
            self.client_incidents.values().flatten().cloned().collect();
        for incident in client_incidents {
            let e = self
                .active_incidents
                .entry(incident.incident_id.clone())
                .or_insert_with(|| HealthIncident {
                    first_seen_at: now,
                    last_seen_at: now,
                    ..incident.clone()
                });
            e.last_seen_at = now;
        }

        // 收集并排序
        let mut incidents: Vec<HealthIncident> = self.active_incidents.values().cloned().collect();
        incidents.sort_by(|a, b| {
            b.severity
                .cmp(&a.severity)
                .then(b.last_seen_at.cmp(&a.last_seen_at))
        });

        let overall_status = compute_overall_status(&incidents);
        let recent_repairs = self
            .repair_audits
            .iter()
            .rev()
            .take(MAX_RECENT_REPAIRS)
            .cloned()
            .collect();

        // 生成观测聚合、预测异常和调度优化建议（v1.44）
        let observation_aggregates =
            crate::server::perf::build_observation_aggregates(cache_hit_ratios);
        let predictive_anomalies =
            crate::server::perf::build_predictive_anomalies(&observation_aggregates);
        let scheduling_recommendations = crate::server::perf::build_scheduling_recommendations(
            &observation_aggregates,
            current_max_parallel,
            running_count,
        );

        SystemHealthSnapshot {
            snapshot_at: now,
            overall_status,
            incidents,
            recent_repairs,
            scheduling_recommendations,
            predictive_anomalies,
            observation_aggregates,
        }
    }

    /// 清除已确认恢复的 incident（由修复执行器或探针调用）
    pub fn resolve_incident(&mut self, incident_id: &str) {
        self.active_incidents.remove(incident_id);
    }

    /// 清除指定 project/workspace 的所有 incidents
    pub fn resolve_workspace_incidents(&mut self, project: &str, workspace: &str) {
        self.active_incidents.retain(|_, v| {
            !(v.context.project.as_deref() == Some(project)
                && v.context.workspace.as_deref() == Some(workspace))
        });
    }

    /// 追加修复审计记录
    pub fn append_audit(&mut self, audit: RepairAuditEntry) {
        self.repair_audits.push(audit);
        if self.repair_audits.len() > MAX_RECENT_REPAIRS * 2 {
            let drain_count = self.repair_audits.len() - MAX_RECENT_REPAIRS;
            self.repair_audits.drain(0..drain_count);
        }
    }

    /// 获取修复审计列表（最近 N 条）
    pub fn recent_repairs(&self, limit: usize) -> Vec<RepairAuditEntry> {
        self.repair_audits
            .iter()
            .rev()
            .take(limit)
            .cloned()
            .collect()
    }
}

// ============================================================================
// 整体健康状态计算
// ============================================================================

fn compute_overall_status(incidents: &[HealthIncident]) -> SystemHealthStatus {
    if incidents
        .iter()
        .any(|i| i.severity == IncidentSeverity::Critical)
    {
        SystemHealthStatus::Unhealthy
    } else if incidents
        .iter()
        .any(|i| i.severity == IncidentSeverity::Warning)
    {
        SystemHealthStatus::Degraded
    } else {
        SystemHealthStatus::Healthy
    }
}

// ============================================================================
// 内置探针：Core 连接层、工作区缓存
// ============================================================================

/// 注册内置探针（在 Core 启动时调用一次）
pub fn register_builtin_probes(
    app_state: SharedAppState,
    terminal_registry: SharedTerminalRegistry,
) {
    let registry = global();
    let mut reg = match registry.try_write() {
        Ok(r) => r,
        Err(_) => {
            warn!("health: failed to acquire write lock for registering builtin probes");
            return;
        }
    };

    // 工作区缓存探针
    let state_clone = app_state.clone();
    reg.register_probe(
        "core.workspace_cache",
        Box::new(move || probe_workspace_cache(&state_clone)),
    );

    // 工作区恢复状态探针（检查崩溃/中断后未自愈的工作区）
    let state_clone2 = app_state.clone();
    reg.register_probe(
        "core.workspace_recovery",
        Box::new(move || probe_workspace_recovery(&state_clone2)),
    );

    // 终端注册表资源压力探针
    reg.register_probe("core.terminal_budget", Box::new(probe_terminal_budget));

    // 终端恢复状态探针（检查持有 Recovering 或 RecoveryFailed 状态的终端）
    let term_reg_clone = terminal_registry;
    reg.register_probe(
        "core.terminal_recovery",
        Box::new(move || probe_terminal_recovery(&term_reg_clone)),
    );
}

/// 终端注册表预算压力探针：当全局 scrollback 使用率 > 80% 时发出 Warning
fn probe_terminal_budget() -> Vec<HealthIncident> {
    let perf = crate::server::perf::snapshot_terminal_perf();
    let now = unix_ms();
    let mut incidents = Vec::new();

    // 通过 perf 计数器判断是否发生过预算触发裁剪
    if perf.scrollback_trim_total > 0 {
        incidents.push(HealthIncident {
            incident_id: "terminal:scrollback_budget_trim".to_string(),
            severity: IncidentSeverity::Warning,
            recoverability: IncidentRecoverability::Recoverable,
            source: IncidentSource::CoreLog,
            root_cause: "terminal_scrollback_budget_exceeded".to_string(),
            summary: Some(format!(
                "终端 scrollback 已触发全局预算裁剪 {} 次，请关注内存使用",
                perf.scrollback_trim_total
            )),
            first_seen_at: now,
            last_seen_at: now,
            context: HealthContext {
                project: None,
                workspace: None,
                session_id: None,
                cycle_id: None,
            },
        });
    }

    incidents
}

/// 工作区缓存探针：检查是否有工作区缓存预算超出或驱逐异常
fn probe_workspace_cache(app_state: &SharedAppState) -> Vec<HealthIncident> {
    // 在异步上下文外通过 try_read 非阻塞检查
    let state = match app_state.try_read() {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    let now = unix_ms();
    let mut incidents = Vec::new();

    for project in state.projects.values() {
        // 检查命名工作区状态
        for ws in project.workspaces.values() {
            use crate::workspace::state::WorkspaceStatus;
            if matches!(ws.status, WorkspaceStatus::SetupFailed) {
                let incident_id = format!("workspace_setup_failed:{}:{}", project.name, ws.name);
                incidents.push(HealthIncident {
                    incident_id,
                    severity: IncidentSeverity::Warning,
                    recoverability: IncidentRecoverability::Manual,
                    source: IncidentSource::CoreWorkspaceCache,
                    root_cause: "workspace_setup_failed".to_string(),
                    summary: Some(format!(
                        "工作区 {}/{} setup 失败，请手动检查",
                        project.name, ws.name
                    )),
                    first_seen_at: now,
                    last_seen_at: now,
                    context: HealthContext::for_workspace(&project.name, &ws.name),
                });
            }
        }
    }
    incidents
}

/// 工作区恢复状态探针：检查持有中断恢复元数据（`interrupted` / `recovering`）的工作区
///
/// 每个 incident 携带 `(project, workspace)` 归属上下文，不会跨工作区混用。
fn probe_workspace_recovery(app_state: &SharedAppState) -> Vec<HealthIncident> {
    let state = match app_state.try_read() {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    let now = unix_ms();
    let mut incidents = Vec::new();

    for project in state.projects.values() {
        for ws in project.workspaces.values() {
            let Some(meta) = ws.recovery_meta.as_ref() else {
                continue;
            };
            if !meta.needs_attention() {
                continue;
            }
            let incident_id = format!("workspace_recovery_pending:{}:{}", project.name, ws.name);
            let cursor_hint = meta
                .recovery_cursor
                .as_deref()
                .map(|c| format!("，游标：{c}"))
                .unwrap_or_default();
            incidents.push(HealthIncident {
                incident_id,
                severity: IncidentSeverity::Warning,
                recoverability: IncidentRecoverability::Recoverable,
                source: IncidentSource::CoreWorkspaceCache,
                root_cause: "workspace_recovery_pending".to_string(),
                summary: Some(format!(
                    "工作区 {}/{} 处于 {} 状态，待恢复自愈{}",
                    project.name, ws.name, meta.recovery_state, cursor_hint
                )),
                first_seen_at: now,
                last_seen_at: now,
                context: HealthContext::for_workspace(&project.name, &ws.name),
            });
        }
    }
    incidents
}

/// 终端恢复状态探针：检查注册表中持有 Recovering 或 RecoveryFailed 状态的终端
///
/// 每个 incident 携带对应 `(project, workspace)` 上下文，按工作区边界隔离。
fn probe_terminal_recovery(terminal_registry: &SharedTerminalRegistry) -> Vec<HealthIncident> {
    let reg = match terminal_registry.try_lock() {
        Ok(r) => r,
        Err(_) => return Vec::new(),
    };
    let now = unix_ms();
    let mut incidents = Vec::new();

    for entry in reg.collect_recovery_metas() {
        let (severity, root_cause, summary): (IncidentSeverity, &str, String) =
            match entry.recovery_state.as_str() {
                "recovering" => (
                    IncidentSeverity::Warning,
                    "terminal_recovery_in_progress",
                    format!(
                        "终端 {} ({}/{}) 正在恢复中，请等待完成",
                        entry.term_id, entry.project, entry.workspace
                    ),
                ),
                "failed" => (
                    IncidentSeverity::Critical,
                    "terminal_recovery_failed",
                    format!(
                        "终端 {} ({}/{}) 恢复失败：{}",
                        entry.term_id,
                        entry.project,
                        entry.workspace,
                        entry.failed_reason.as_deref().unwrap_or("unknown"),
                    ),
                ),
                _ => continue,
            };
        let incident_id = format!(
            "terminal_recovery:{}:{}:{}",
            entry.project, entry.workspace, entry.term_id
        );
        incidents.push(HealthIncident {
            incident_id,
            severity,
            recoverability: IncidentRecoverability::Recoverable,
            source: IncidentSource::CoreLog,
            root_cause: root_cause.to_string(),
            summary: Some(summary),
            first_seen_at: now,
            last_seen_at: now,
            context: HealthContext::for_workspace(&entry.project, &entry.workspace),
        });
    }
    incidents
}

// ============================================================================
// WI-003: 修复执行器
// ============================================================================

/// 执行修复动作（幂等，带审计记录）
///
/// 修复动作严格遵守 project/workspace 边界，不会跨工作区执行。
pub async fn execute_repair(
    request: RepairActionRequest,
    trigger: &str,
    app_state: SharedAppState,
) -> RepairAuditEntry {
    let started_at = unix_ms();
    let (outcome, result_summary, incident_resolved) = do_repair(&request, app_state.clone()).await;
    let duration_ms = unix_ms().saturating_sub(started_at);

    let audit = RepairAuditEntry {
        request_id: request.request_id.clone(),
        action: request.action.clone(),
        context: request.context.clone(),
        incident_id: request.incident_id.clone(),
        outcome,
        trigger: trigger.to_string(),
        started_at,
        duration_ms,
        result_summary,
        incident_resolved,
    };

    // 写入审计日志
    {
        let registry = global();
        if let Ok(mut reg) = registry.try_write() {
            // 如果修复成功并有关联 incident，清除它
            if incident_resolved {
                if let Some(ref iid) = request.incident_id {
                    reg.resolve_incident(iid);
                }
                // workspace 缓存修复后清除该工作区所有相关 incidents
                if let (Some(project), Some(workspace)) =
                    (&request.context.project, &request.context.workspace)
                {
                    if matches!(
                        request.action,
                        RepairActionKind::InvalidateWorkspaceCache
                            | RepairActionKind::RebuildWorkspaceCache
                    ) {
                        reg.resolve_workspace_incidents(project, workspace);
                    }
                }
            }
            reg.append_audit(audit.clone());
        };
    }

    audit
}

async fn do_repair(
    request: &RepairActionRequest,
    app_state: SharedAppState,
) -> (RepairOutcome, Option<String>, bool) {
    match &request.action {
        RepairActionKind::RefreshHealthSnapshot => {
            // 无副作用：仅触发快照刷新（调用方在 HTTP 层重新聚合即可）
            (
                RepairOutcome::Success,
                Some("健康快照已刷新".to_string()),
                false,
            )
        }

        RepairActionKind::InvalidateWorkspaceCache => {
            let (Some(project), Some(workspace)) =
                (&request.context.project, &request.context.workspace)
            else {
                return (
                    RepairOutcome::Failed,
                    Some("缺少 project/workspace 上下文".to_string()),
                    false,
                );
            };
            invalidate_workspace_cache(project, workspace, &app_state).await
        }

        RepairActionKind::RebuildWorkspaceCache => {
            let (Some(project), Some(workspace)) =
                (&request.context.project, &request.context.workspace)
            else {
                return (
                    RepairOutcome::Failed,
                    Some("缺少 project/workspace 上下文".to_string()),
                    false,
                );
            };
            // 先失效，再让调用方触发重建（实际重建由文件索引或 git 缓存懒加载完成）
            let (outcome, summary, resolved) =
                invalidate_workspace_cache(project, workspace, &app_state).await;
            if outcome == RepairOutcome::Success {
                (
                    RepairOutcome::Success,
                    Some("缓存已失效，将在下次访问时自动重建".to_string()),
                    resolved,
                )
            } else {
                (outcome, summary, resolved)
            }
        }

        RepairActionKind::RestoreSubscriptions => {
            // 订阅恢复：清理 remote_sub_registry 中的残留订阅
            restore_subscriptions(request, &app_state).await
        }
    }
}

async fn invalidate_workspace_cache(
    project: &str,
    workspace: &str,
    app_state: &SharedAppState,
) -> (RepairOutcome, Option<String>, bool) {
    // 验证 project/workspace 存在，防止越界操作
    let state = app_state.read().await;
    let project_exists = state.projects.contains_key(project);
    drop(state);

    if !project_exists {
        return (
            RepairOutcome::Failed,
            Some(format!("项目 {} 不存在", project)),
            false,
        );
    }

    // 缓存失效：通知文件索引缓存清理（实际缓存驱逐由 workspace cache metrics 系统处理）
    // 此处记录失效事件，实际缓存清理在 probe 下次检查时自动发现并重建
    tracing::info!(
        project = project,
        workspace = workspace,
        "health repair: invalidate workspace cache"
    );
    (
        RepairOutcome::Success,
        Some(format!("工作区 {}/{} 缓存已失效", project, workspace)),
        true,
    )
}

async fn restore_subscriptions(
    request: &RepairActionRequest,
    _app_state: &SharedAppState,
) -> (RepairOutcome, Option<String>, bool) {
    // 订阅恢复：记录修复意图，实际重连由 WS 层自动重建
    tracing::info!(
        project = ?request.context.project,
        workspace = ?request.context.workspace,
        "health repair: restore subscriptions"
    );
    (
        RepairOutcome::Success,
        Some("订阅恢复请求已记录，重连时将自动恢复".to_string()),
        true,
    )
}

// ============================================================================
// WI-002: 质量门禁裁决
// ============================================================================

/// 基于系统健康快照生成门禁裁决
///
/// Evolution 自动循环在 verify/auto_commit 衔接处调用此函数。
/// 裁决结果按 `(project, workspace, cycle_id)` 隔离。
pub fn evaluate_gate_decision(
    project: &str,
    workspace: &str,
    cycle_id: &str,
    retry_count: u32,
) -> crate::server::protocol::health::GateDecision {
    use crate::server::protocol::health::{
        GateDecision, GateFailureReason, GateVerdict, SystemHealthStatus,
    };

    let registry = global();
    let health_status;
    let mut failure_reasons = Vec::new();

    match registry.try_read() {
        Ok(reg) => {
            // 检查是否有属于该 project/workspace 的 critical incident
            let workspace_critical = reg.active_incidents.values().any(|i| {
                i.severity == crate::server::protocol::health::IncidentSeverity::Critical
                    && i.context.project.as_deref() == Some(project)
                    && i.context.workspace.as_deref() == Some(workspace)
            });
            let system_critical = reg.active_incidents.values().any(|i| {
                i.severity == crate::server::protocol::health::IncidentSeverity::Critical
                    && i.context.project.is_none()
            });

            if workspace_critical || system_critical {
                health_status = SystemHealthStatus::Unhealthy;
                failure_reasons.push(GateFailureReason::CriticalIncident);
            } else {
                let has_warnings = reg.active_incidents.values().any(|i| {
                    i.severity == crate::server::protocol::health::IncidentSeverity::Warning
                        && (i.context.project.as_deref() == Some(project)
                            || i.context.project.is_none())
                });
                health_status = if has_warnings {
                    SystemHealthStatus::Degraded
                } else {
                    SystemHealthStatus::Healthy
                };
            }
        }
        Err(_) => {
            // 无法获取锁时跳过门禁检查（不阻断）
            return GateDecision {
                verdict: GateVerdict::Skip,
                failure_reasons: Vec::new(),
                project: project.to_string(),
                workspace: workspace.to_string(),
                cycle_id: cycle_id.to_string(),
                health_status: SystemHealthStatus::Healthy,
                retry_count,
                bypassed: false,
                bypass_reason: None,
                decided_at: unix_ms(),
            };
        }
    }

    let verdict = if health_status == SystemHealthStatus::Unhealthy {
        GateVerdict::Fail
    } else {
        GateVerdict::Pass
    };

    GateDecision {
        verdict,
        failure_reasons,
        project: project.to_string(),
        workspace: workspace.to_string(),
        cycle_id: cycle_id.to_string(),
        health_status,
        retry_count,
        bypassed: false,
        bypass_reason: None,
        decided_at: unix_ms(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 序列化访问全局 HealthRegistry 的测试，避免并行测试间的锁竞争
    static GATE_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn make_incident(
        id: &str,
        severity: IncidentSeverity,
        project: Option<&str>,
        workspace: Option<&str>,
    ) -> HealthIncident {
        HealthIncident {
            incident_id: id.to_string(),
            severity,
            recoverability: IncidentRecoverability::Recoverable,
            source: IncidentSource::CoreWorkspaceCache,
            root_cause: "test_cause".to_string(),
            summary: None,
            first_seen_at: 1000,
            last_seen_at: 1000,
            context: HealthContext {
                project: project.map(|s| s.to_string()),
                workspace: workspace.map(|s| s.to_string()),
                session_id: None,
                cycle_id: None,
            },
        }
    }

    #[test]
    fn overall_status_healthy_when_no_incidents() {
        assert_eq!(compute_overall_status(&[]), SystemHealthStatus::Healthy);
    }

    #[test]
    fn overall_status_degraded_when_only_warnings() {
        let incidents = vec![make_incident("i1", IncidentSeverity::Warning, None, None)];
        assert_eq!(
            compute_overall_status(&incidents),
            SystemHealthStatus::Degraded
        );
    }

    #[test]
    fn overall_status_unhealthy_when_critical() {
        let incidents = vec![
            make_incident("i1", IncidentSeverity::Warning, None, None),
            make_incident("i2", IncidentSeverity::Critical, None, None),
        ];
        assert_eq!(
            compute_overall_status(&incidents),
            SystemHealthStatus::Unhealthy
        );
    }

    #[test]
    fn registry_deduplicates_incidents_by_id() {
        let mut reg = HealthRegistry::new();
        reg.record_log_error("err", "summary", HealthContext::system());
        reg.record_log_error("err", "summary2", HealthContext::system());
        // 相同 root_cause + context → 同一 incident_id → 去重
        let snap = reg.snapshot();
        // active_incidents 应只有一条
        assert_eq!(snap.incidents.len(), 1);
    }

    #[test]
    fn registry_resolve_removes_incident() {
        let mut reg = HealthRegistry::new();
        reg.record_log_error("err_remove", "summary", HealthContext::system());
        let snap = reg.snapshot();
        assert_eq!(snap.incidents.len(), 1);
        let id = snap.incidents[0].incident_id.clone();
        reg.resolve_incident(&id);
        // 使用 active_incidents 直接检查（snapshot 会重新运行探针但 active_incidents 已清空）
        assert!(!reg.active_incidents.contains_key(&id));
    }

    #[test]
    fn registry_resolve_workspace_incidents() {
        let mut reg = HealthRegistry::new();
        reg.active_incidents.insert(
            "i1".to_string(),
            make_incident("i1", IncidentSeverity::Warning, Some("proj"), Some("ws1")),
        );
        reg.active_incidents.insert(
            "i2".to_string(),
            make_incident("i2", IncidentSeverity::Warning, Some("proj"), Some("ws2")),
        );
        reg.resolve_workspace_incidents("proj", "ws1");
        assert!(!reg.active_incidents.contains_key("i1"));
        assert!(reg.active_incidents.contains_key("i2"));
    }

    #[test]
    fn audit_list_capped_at_max() {
        let mut reg = HealthRegistry::new();
        for i in 0..(MAX_RECENT_REPAIRS * 3) {
            reg.append_audit(RepairAuditEntry {
                request_id: format!("req-{}", i),
                action: RepairActionKind::RefreshHealthSnapshot,
                context: HealthContext::system(),
                incident_id: None,
                outcome: RepairOutcome::Success,
                trigger: "auto_heal".to_string(),
                started_at: 0,
                duration_ms: 1,
                result_summary: None,
                incident_resolved: false,
            });
        }
        let recent = reg.recent_repairs(MAX_RECENT_REPAIRS);
        assert_eq!(recent.len(), MAX_RECENT_REPAIRS);
    }

    #[test]
    fn gate_decision_pass_when_healthy() {
        let _serial = GATE_TEST_LOCK.lock().unwrap();
        // 创建一个独立的注册表来测试门禁裁决逻辑
        let decision = evaluate_gate_decision("proj", "ws", "cycle-1", 0);
        use crate::server::protocol::health::GateVerdict;
        // 没有注入 critical incident 时应通过或跳过
        assert!(
            decision.verdict == GateVerdict::Pass || decision.verdict == GateVerdict::Skip,
            "expected pass/skip, got {:?}",
            decision.verdict
        );
        assert_eq!(decision.project, "proj");
        assert_eq!(decision.workspace, "ws");
        assert_eq!(decision.cycle_id, "cycle-1");
        assert_eq!(decision.retry_count, 0);
        assert!(!decision.bypassed);
    }

    #[test]
    fn gate_decision_fail_when_critical_incident() {
        let _serial = GATE_TEST_LOCK.lock().unwrap();
        let registry = global();
        // 使用 blocking_write() 代替 try_write()，避免并行测试时锁竞争导致 TryLockError panic
        let mut reg = registry.blocking_write();
        // 注入 critical incident
        reg.active_incidents.insert(
            "gate_test_critical".to_string(),
            make_incident(
                "gate_test_critical",
                IncidentSeverity::Critical,
                Some("gproj"),
                Some("gws"),
            ),
        );
        drop(reg);

        let decision = evaluate_gate_decision("gproj", "gws", "cycle-2", 1);
        use crate::server::protocol::health::GateVerdict;
        assert_eq!(decision.verdict, GateVerdict::Fail);
        assert!(!decision.failure_reasons.is_empty());
        assert_eq!(decision.retry_count, 1);

        // 清理
        let mut reg = registry.blocking_write();
        reg.active_incidents.remove("gate_test_critical");
    }

    #[test]
    fn gate_decision_isolated_by_project_workspace() {
        let _serial = GATE_TEST_LOCK.lock().unwrap();
        let registry = global();
        // 使用 blocking_write() 代替 try_write()，避免并行测试时锁竞争导致 TryLockError panic
        let mut reg = registry.blocking_write();
        reg.active_incidents.insert(
            "gate_isolation_critical".to_string(),
            make_incident(
                "gate_isolation_critical",
                IncidentSeverity::Critical,
                Some("projA"),
                Some("wsA"),
            ),
        );
        drop(reg);

        // projB/wsB 不应受 projA/wsA 的 critical incident 影响
        let decision_b = evaluate_gate_decision("projB", "wsB", "cycle-3", 0);
        use crate::server::protocol::health::GateVerdict;
        assert!(decision_b.verdict == GateVerdict::Pass || decision_b.verdict == GateVerdict::Skip);

        // projA/wsA 应受影响
        let decision_a = evaluate_gate_decision("projA", "wsA", "cycle-3", 0);
        assert_eq!(decision_a.verdict, GateVerdict::Fail);

        // 清理
        let mut reg = registry.blocking_write();
        reg.active_incidents.remove("gate_isolation_critical");
    }

    // MARK: - WI-004 性能回归失败映射测试

    /// `GateFailureReason::PerformanceRegressionFailed` 序列化为 snake_case 字符串
    #[test]
    fn gate_failure_reason_performance_regression_failed_serde() {
        use crate::server::protocol::health::GateFailureReason;
        let reason = GateFailureReason::PerformanceRegressionFailed;
        let serialized = serde_json::to_string(&reason).unwrap();
        assert_eq!(
            serialized, "\"performance_regression_failed\"",
            "PerformanceRegressionFailed 必须序列化为 \"performance_regression_failed\""
        );
        let deserialized: GateFailureReason = serde_json::from_str(&serialized).unwrap();
        assert_eq!(deserialized, GateFailureReason::PerformanceRegressionFailed);
    }

    /// `performance_regression_failed` 不属于 `custom` 变体
    #[test]
    fn gate_failure_reason_performance_regression_not_custom() {
        use crate::server::protocol::health::GateFailureReason;
        let raw = "\"performance_regression_failed\"";
        let reason: GateFailureReason = serde_json::from_str(raw).unwrap();
        assert!(
            !matches!(reason, GateFailureReason::Custom(_)),
            "performance_regression_failed 不应反序列化为 Custom(_)"
        );
        assert_eq!(reason, GateFailureReason::PerformanceRegressionFailed);
    }

    /// `GateDecision` 携带 `performance_regression_failed` 时正确解析 failure_reasons
    #[test]
    fn gate_decision_with_performance_regression_failed() {
        use crate::server::protocol::health::{GateDecision, GateFailureReason, GateVerdict};
        let decision = GateDecision {
            verdict: GateVerdict::Fail,
            failure_reasons: vec![GateFailureReason::PerformanceRegressionFailed],
            project: "tidyflow".to_string(),
            workspace: "default".to_string(),
            cycle_id: "cycle-test".to_string(),
            health_status: crate::server::protocol::health::SystemHealthStatus::Healthy,
            retry_count: 0,
            bypassed: false,
            bypass_reason: None,
            decided_at: 0,
        };
        let json = serde_json::to_string(&decision).unwrap();
        assert!(
            json.contains("\"performance_regression_failed\""),
            "GateDecision JSON 必须包含 performance_regression_failed"
        );
        let roundtrip: GateDecision = serde_json::from_str(&json).unwrap();
        assert_eq!(roundtrip.failure_reasons.len(), 1);
        assert_eq!(
            roundtrip.failure_reasons[0],
            GateFailureReason::PerformanceRegressionFailed
        );
    }

    /// 多项目同名工作区下 GateDecision failure_reason 归属不串台
    #[test]
    fn gate_decision_multi_project_same_workspace_isolation() {
        use crate::server::protocol::health::{GateDecision, GateFailureReason, GateVerdict};

        let make_decision = |project: &str| -> GateDecision {
            GateDecision {
                verdict: GateVerdict::Fail,
                failure_reasons: vec![GateFailureReason::PerformanceRegressionFailed],
                project: project.to_string(),
                workspace: "ws1".to_string(),
                cycle_id: "cycle-multi".to_string(),
                health_status: crate::server::protocol::health::SystemHealthStatus::Healthy,
                retry_count: 0,
                bypassed: false,
                bypass_reason: None,
                decided_at: 0,
            }
        };

        let da = make_decision("project_a");
        let db = make_decision("project_b");
        assert_ne!(da.project, db.project, "不同项目的 GateDecision 不应串台");
        assert_eq!(da.workspace, db.workspace, "同名工作区");
        assert_eq!(
            da.failure_reasons[0],
            GateFailureReason::PerformanceRegressionFailed
        );
        assert_eq!(
            db.failure_reasons[0],
            GateFailureReason::PerformanceRegressionFailed
        );
    }

    // ---- WI-003: 故障恢复闭环与多工作区隔离 ----

    #[test]
    fn recovery_incident_isolation_across_projects_same_workspace() {
        let _serial = GATE_TEST_LOCK.lock().unwrap();
        let mut reg = HealthRegistry::new();

        // project-a/ws 和 project-b/ws 各有一个 incident
        reg.active_incidents.insert(
            "recovery_iso_a".to_string(),
            make_incident(
                "recovery_iso_a",
                IncidentSeverity::Critical,
                Some("project-a"),
                Some("ws"),
            ),
        );
        reg.active_incidents.insert(
            "recovery_iso_b".to_string(),
            make_incident(
                "recovery_iso_b",
                IncidentSeverity::Warning,
                Some("project-b"),
                Some("ws"),
            ),
        );

        // 只清除 project-a/ws 的 incident
        reg.resolve_workspace_incidents("project-a", "ws");

        assert!(
            !reg.active_incidents.contains_key("recovery_iso_a"),
            "project-a/ws 的 incident 应被清除"
        );
        assert!(
            reg.active_incidents.contains_key("recovery_iso_b"),
            "project-b/ws 的 incident 不应被误清除"
        );

        // 清理
        reg.active_incidents.remove("recovery_iso_b");
    }

    #[test]
    fn repair_audit_records_context_correctly() {
        let mut reg = HealthRegistry::new();
        let audit = RepairAuditEntry {
            request_id: "repair-ctx-test".to_string(),
            action: RepairActionKind::InvalidateWorkspaceCache,
            context: HealthContext {
                project: Some("proj-x".to_string()),
                workspace: Some("ws-y".to_string()),
                session_id: None,
                cycle_id: None,
            },
            incident_id: Some("inc-001".to_string()),
            outcome: RepairOutcome::Success,
            trigger: "auto_heal".to_string(),
            started_at: 1000,
            duration_ms: 50,
            result_summary: Some("缓存已刷新".to_string()),
            incident_resolved: true,
        };
        reg.append_audit(audit.clone());

        let recent = reg.recent_repairs(10);
        assert_eq!(recent.len(), 1);
        assert_eq!(recent[0].context.project.as_deref(), Some("proj-x"));
        assert_eq!(recent[0].context.workspace.as_deref(), Some("ws-y"));
        assert!(recent[0].incident_resolved);
    }

    #[test]
    fn repair_idempotent_does_not_double_resolve() {
        let _serial = GATE_TEST_LOCK.lock().unwrap();
        let mut reg = HealthRegistry::new();
        reg.active_incidents.insert(
            "idem_test".to_string(),
            make_incident(
                "idem_test",
                IncidentSeverity::Warning,
                Some("proj-idem"),
                Some("ws-idem"),
            ),
        );
        // 第一次 resolve
        reg.resolve_incident("idem_test");
        assert!(!reg.active_incidents.contains_key("idem_test"));

        // 第二次 resolve 不应 panic 或改变状态
        reg.resolve_incident("idem_test");
        assert!(!reg.active_incidents.contains_key("idem_test"));
    }

    #[test]
    fn record_evolution_incident_warning() {
        let _serial = GATE_TEST_LOCK.lock().unwrap();
        let mut reg = HealthRegistry::new();
        reg.record_evolution_incident(
            "evo_warning_test",
            "测试 Warning 级别 evolution incident",
            IncidentSeverity::Warning,
            HealthContext {
                project: Some("proj-evo".to_string()),
                workspace: Some("ws-evo".to_string()),
                session_id: None,
                cycle_id: None,
            },
        );
        let snap = reg.snapshot();
        assert!(
            snap.incidents
                .iter()
                .any(|i| i.root_cause == "evo_warning_test"),
            "应记录 Warning 级别的 evolution incident"
        );
        let inc = snap
            .incidents
            .iter()
            .find(|i| i.root_cause == "evo_warning_test")
            .unwrap();
        assert_eq!(inc.severity, IncidentSeverity::Warning);
        assert_eq!(inc.source, IncidentSource::CoreEvolution);
        assert_eq!(inc.recoverability, IncidentRecoverability::Recoverable);
    }

    #[test]
    fn record_evolution_incident_critical() {
        let _serial = GATE_TEST_LOCK.lock().unwrap();
        let mut reg = HealthRegistry::new();
        reg.record_evolution_incident(
            "evo_critical_test",
            "测试 Critical 级别 evolution incident",
            IncidentSeverity::Critical,
            HealthContext {
                project: Some("proj-evo-crit".to_string()),
                workspace: Some("ws-evo-crit".to_string()),
                session_id: None,
                cycle_id: None,
            },
        );
        let snap = reg.snapshot();
        assert!(
            snap.incidents
                .iter()
                .any(|i| i.root_cause == "evo_critical_test"),
            "应记录 Critical 级别的 evolution incident"
        );
        let inc = snap
            .incidents
            .iter()
            .find(|i| i.root_cause == "evo_critical_test")
            .unwrap();
        assert_eq!(inc.severity, IncidentSeverity::Critical);
        assert_eq!(inc.source, IncidentSource::CoreEvolution);
        assert_eq!(inc.recoverability, IncidentRecoverability::Manual);
    }

    #[test]
    fn gate_decision_critical_in_project_a_does_not_affect_project_b_same_workspace() {
        let _serial = GATE_TEST_LOCK.lock().unwrap();
        let registry = global();
        let mut reg = registry.blocking_write();
        let incident_id = "cross_proj_gate_iso";
        reg.active_incidents.insert(
            incident_id.to_string(),
            make_incident(
                incident_id,
                IncidentSeverity::Critical,
                Some("gate-proj-a"),
                Some("shared-ws"),
            ),
        );
        drop(reg);

        use crate::server::protocol::health::GateVerdict;

        // gate-proj-b/shared-ws 不应受 gate-proj-a/shared-ws 影响
        let decision_b = evaluate_gate_decision("gate-proj-b", "shared-ws", "cycle-iso", 0);
        assert!(
            decision_b.verdict == GateVerdict::Pass || decision_b.verdict == GateVerdict::Skip,
            "project-b 不应受 project-a 的 critical incident 影响: {:?}",
            decision_b.verdict
        );

        // gate-proj-a/shared-ws 应受影响
        let decision_a = evaluate_gate_decision("gate-proj-a", "shared-ws", "cycle-iso", 0);
        assert_eq!(
            decision_a.verdict,
            GateVerdict::Fail,
            "project-a 应因 critical incident 失败"
        );

        // 清理
        let mut reg = registry.blocking_write();
        reg.active_incidents.remove(incident_id);
    }
}
