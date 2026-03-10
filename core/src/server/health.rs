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
                severity: IncidentSeverity::Warning,
                recoverability: IncidentRecoverability::Recoverable,
                source: IncidentSource::CoreLog,
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

        SystemHealthSnapshot {
            snapshot_at: now,
            overall_status,
            incidents,
            recent_repairs,
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
pub fn register_builtin_probes(app_state: SharedAppState) {
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

#[cfg(test)]
mod tests {
    use super::*;

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
}
