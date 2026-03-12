use std::collections::HashMap;

use axum::{extract::State, Json};
use serde::{Deserialize, Serialize};

use super::common::{build_http_handler_context, map_query_error, ApiError};
use crate::server::context::SharedAppState;
use crate::server::perf::{PerfMetricsSnapshot, TerminalPerfSnapshot};
use crate::server::protocol::health::{
    HealthIncident, RepairActionRequest, RepairAuditEntry, SystemHealthSnapshot,
};
use crate::server::protocol::{
    FileCacheMetricsInfo, GitCacheMetricsInfo, ServerMessage, WorkspaceCacheMetricsInfo,
    WorkspaceInfo, PROTOCOL_VERSION,
};
use crate::server::terminal_registry::TerminalResourceInfo;
use crate::workspace::cache_metrics::WorkspaceCacheSnapshot;
use crate::workspace::state::DEFAULT_WORKSPACE_NAME;

#[derive(Debug, Clone, Serialize)]
pub(in crate::server::ws) struct SystemSnapshotResponse {
    #[serde(rename = "type")]
    msg_type: &'static str,
    core_version: String,
    protocol_version: u32,
    workspace_items: Vec<SystemSnapshotWorkspaceItem>,
    /// 每个工作区的缓存可观测性指标，由 Core 权威输出，按 `(project, workspace)` 隔离
    cache_metrics: Vec<WorkspaceCacheMetricsInfo>,
    /// 系统健康 incidents（v1.41）
    health_incidents: Vec<HealthIncident>,
    /// 最近修复审计摘要（v1.41）
    recent_repairs: Vec<RepairAuditEntry>,
    /// 终端注册表资源压力快照
    terminal_resource: TerminalResourceSnapshot,
    /// 统一性能指标快照（v1.42 可观测性收敛）
    perf_metrics: PerfMetricsSnapshot,
    /// 结构化日志关联上下文摘要
    log_context: LogContextSummary,
    /// 调度优化建议列表（v1.44，Core 权威输出）
    #[serde(skip_serializing_if = "Vec::is_empty")]
    scheduling_recommendations: Vec<crate::server::protocol::health::SchedulingRecommendation>,
    /// 预测异常摘要列表（v1.44，Core 权威输出）
    #[serde(skip_serializing_if = "Vec::is_empty")]
    predictive_anomalies: Vec<crate::server::protocol::health::PredictiveAnomaly>,
    /// 智能演化分析摘要列表（v1.45，Core 权威输出，按 (project, workspace, cycle_id) 隔离）
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    analysis_summaries: Vec<crate::server::protocol::health::EvolutionAnalysisSummary>,
    /// 全链路性能可观测快照（WI-001/WI-002 新增，Core 权威真源）
    performance_observability: crate::server::protocol::health::PerformanceObservabilitySnapshot,
}

/// 结构化日志关联上下文摘要（供调试面板快速关联日志与快照）
#[derive(Debug, Clone, Serialize)]
pub(in crate::server::ws) struct LogContextSummary {
    /// 日志文件路径（当天）
    pub log_file: String,
    /// 日志保留天数
    pub retention_days: u64,
    /// 是否启用了 perf 日志（TIDYFLOW_PERF_LOG）
    pub perf_logging_enabled: bool,
}

/// 终端资源压力快照（用于 system_snapshot）
#[derive(Debug, Clone, Serialize)]
pub(in crate::server::ws) struct TerminalResourceSnapshot {
    pub total_terminal_count: usize,
    pub total_scrollback_bytes: usize,
    pub global_budget_bytes: usize,
    pub budget_used_percent: u8,
    pub reclaimed_total: u64,
    pub scrollback_trim_total: u64,
    pub per_workspace: Vec<WorkspaceTerminalSnapshot>,
}

/// 单工作区终端摘要
#[derive(Debug, Clone, Serialize)]
pub(in crate::server::ws) struct WorkspaceTerminalSnapshot {
    pub project: String,
    pub workspace: String,
    pub terminal_count: usize,
    pub scrollback_bytes: usize,
}

#[derive(Debug, Clone, Serialize)]
pub(in crate::server::ws) struct SystemSnapshotWorkspaceItem {
    project: String,
    workspace: String,
    path: String,
    branch: String,
    workspace_status: String,
    evolution_status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    evolution_cycle_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    failure_reason: Option<String>,
    /// 工作区恢复状态摘要（按 (project, workspace) 隔离，无中断时为 None）
    #[serde(skip_serializing_if = "Option::is_none")]
    recovery_state: Option<String>,
    /// 恢复游标（上次已知执行位置）
    #[serde(skip_serializing_if = "Option::is_none")]
    recovery_cursor: Option<String>,
    /// Coordinator AI 聚合状态种子（重连后快速恢复工作区展示状态）
    #[serde(skip_serializing_if = "Option::is_none")]
    coordinator_ai: Option<crate::server::protocol::CoordinatorAiDomainStateDto>,
    /// Coordinator 终端领域状态种子（v1.47，重连后快速恢复终端域状态）
    #[serde(skip_serializing_if = "Option::is_none")]
    coordinator_terminal: Option<crate::server::protocol::CoordinatorTerminalDomainStateDto>,
    /// Coordinator 文件领域状态种子（v1.47，重连后快速恢复文件域状态）
    #[serde(skip_serializing_if = "Option::is_none")]
    coordinator_file: Option<crate::server::protocol::CoordinatorFileDomainStateDto>,
}

#[derive(Debug, Clone)]
struct EvolutionWorkspaceSummary {
    status: String,
    cycle_id: Option<String>,
    title: Option<String>,
    failure_reason: Option<String>,
}

pub(in crate::server::ws) async fn system_snapshot_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
) -> Result<Json<SystemSnapshotResponse>, ApiError> {
    let handler_ctx = build_http_handler_context(&ctx, None);
    let evo_snapshot =
        crate::server::handlers::evolution::query_evolution_snapshot(None, None, &handler_ctx)
            .await
            .map_err(map_query_error)?;
    // 提取调度器信息（避免重复查询）
    let (evo_scheduler_info, evo_index) = evolution_index_and_scheduler_from_message(evo_snapshot)?;

    // 终端资源快照（提前提取，复用于 coordinator 种子和 terminal_resource 字段）
    let (terminal_resource, terminal_registry_info) = {
        let reg = ctx.terminal_registry.lock().await;
        let info = reg.resource_info();
        let perf = crate::server::perf::snapshot_terminal_perf();
        let resource = build_terminal_resource_snapshot(info.clone(), perf);
        (resource, info)
    };

    let (workspace_items, cache_metrics) = build_workspace_items_and_metrics(
        &ctx.app_state,
        &evo_index,
        &ctx.ai_state,
        &terminal_registry_info,
    )
    .await;

    // 聚合健康快照（含调度优化建议和预测异常）
    let health_snapshot = {
        let registry = crate::server::health::global();
        let mut reg = registry.write().await;

        // 提取缓存命中率用于观测聚合
        let cache_hit_ratios: std::collections::HashMap<(String, String), f64> = cache_metrics
            .iter()
            .map(|m| {
                let total = m.file_cache.hit_count + m.file_cache.miss_count;
                let ratio = if total > 0 {
                    m.file_cache.hit_count as f64 / total as f64
                } else {
                    1.0
                };
                ((m.project.clone(), m.workspace.clone()), ratio)
            })
            .collect();

        reg.snapshot_with_predictions(
            &cache_hit_ratios,
            evo_scheduler_info.0,
            evo_scheduler_info.1,
        )
    };

    // 统一性能指标快照
    let perf_metrics = crate::server::perf::snapshot_perf_metrics();

    // 全链路性能可观测快照（WI-001/WI-002）
    let performance_observability = crate::server::perf::build_performance_observability_snapshot();

    // 结构化日志关联上下文
    let log_context = build_log_context_summary();

    Ok(Json(SystemSnapshotResponse {
        msg_type: "system_snapshot",
        core_version: env!("CARGO_PKG_VERSION").to_string(),
        protocol_version: PROTOCOL_VERSION,
        workspace_items,
        cache_metrics,
        health_incidents: health_snapshot.incidents,
        recent_repairs: health_snapshot.recent_repairs,
        terminal_resource,
        perf_metrics,
        log_context,
        scheduling_recommendations: health_snapshot.scheduling_recommendations,
        predictive_anomalies: health_snapshot.predictive_anomalies,
        analysis_summaries: Vec::new(), // WI-002 将实现实际生成逻辑
        performance_observability,
    }))
}

/// 系统健康快照专用端点（返回完整 SystemHealthSnapshot，含 incidents 与修复审计）
pub(in crate::server::ws) async fn system_health_snapshot_handler(
    State(_ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
) -> Result<Json<SystemHealthSnapshot>, ApiError> {
    let registry = crate::server::health::global();
    let mut reg = registry.write().await;
    let snapshot = reg.snapshot();
    Ok(Json(snapshot))
}

/// 修复动作请求体
#[derive(Debug, Deserialize)]
pub(in crate::server::ws) struct RepairRequestBody {
    pub request: RepairActionRequest,
}

/// 修复动作响应体
#[derive(Debug, Serialize)]
pub(in crate::server::ws) struct RepairResponseBody {
    pub audit: RepairAuditEntry,
}

/// 执行系统修复动作（HTTP POST）
pub(in crate::server::ws) async fn system_repair_handler(
    State(ctx): State<crate::server::ws::transport::bootstrap::AppContext>,
    Json(body): Json<RepairRequestBody>,
) -> Result<Json<RepairResponseBody>, ApiError> {
    let audit = crate::server::health::execute_repair(
        body.request,
        "client_request",
        ctx.app_state.clone(),
    )
    .await;
    Ok(Json(RepairResponseBody { audit }))
}

/// 从 Evolution 快照消息提取调度器信息和工作区索引（避免重复查询）
fn evolution_index_and_scheduler_from_message(
    msg: ServerMessage,
) -> Result<
    (
        (u32, u32),
        HashMap<(String, String), EvolutionWorkspaceSummary>,
    ),
    ApiError,
> {
    let ServerMessage::EvoSnapshot {
        scheduler,
        workspace_items,
    } = msg
    else {
        return Err(ApiError::Internal(
            "unexpected evolution snapshot response type".to_string(),
        ));
    };
    let scheduler_info = (scheduler.max_parallel_workspaces, scheduler.running_count);
    Ok((scheduler_info, evolution_index_from_items(&workspace_items)))
}

fn evolution_index_from_items(
    items: &[crate::server::protocol::EvolutionWorkspaceItem],
) -> HashMap<(String, String), EvolutionWorkspaceSummary> {
    let mut index = HashMap::with_capacity(items.len());
    for item in items {
        let cycle_id = non_empty_opt(Some(item.cycle_id.as_str()));
        let title = if cycle_id.is_some() {
            non_empty_opt(item.title.as_deref())
        } else {
            None
        };
        index.insert(
            (item.project.clone(), item.workspace.clone()),
            EvolutionWorkspaceSummary {
                status: non_empty_opt(Some(item.status.as_str()))
                    .unwrap_or_else(|| "not_started".to_string()),
                cycle_id,
                title,
                failure_reason: summarize_failure_reason(item),
            },
        );
    }
    index
}

async fn build_workspace_items_and_metrics(
    app_state: &SharedAppState,
    evo_index: &HashMap<(String, String), EvolutionWorkspaceSummary>,
    ai_state: &crate::server::handlers::ai::SharedAIState,
    terminal_info: &crate::server::terminal_registry::TerminalResourceInfo,
) -> (
    Vec<SystemSnapshotWorkspaceItem>,
    Vec<WorkspaceCacheMetricsInfo>,
) {
    // 提取 AI session status store（只加锁一次）
    let session_statuses = {
        let guard = ai_state.lock().await;
        guard.session_statuses.clone()
    };

    // 按 (project, workspace) 构建终端域聚合索引，复用已提取的 terminal_info
    let terminal_map: HashMap<
        (String, String),
        &crate::server::terminal_registry::WorkspaceTerminalInfo,
    > = terminal_info
        .per_workspace
        .iter()
        .map(|wi| ((wi.project.clone(), wi.workspace.clone()), wi))
        .collect();

    let mut items = Vec::new();
    let mut cache_metrics_list = Vec::new();

    {
        let state = app_state.read().await;
        for project in state.projects.values() {
            let project_name = project.name.clone();

            // default 虚拟工作区
            let default_root = project.root_path.to_string_lossy().to_string();
            let default_info = WorkspaceInfo {
                name: DEFAULT_WORKSPACE_NAME.to_string(),
                root: default_root.clone(),
                branch: project.default_branch.clone(),
                status: "ready".to_string(),
                sidebar_status: Default::default(),
            };
            let coordinator_ai_default =
                build_coordinator_ai_dto(&session_statuses, &project_name, DEFAULT_WORKSPACE_NAME);
            let coordinator_terminal_default = build_coordinator_terminal_dto(
                terminal_map.get(&(project_name.clone(), DEFAULT_WORKSPACE_NAME.to_string())),
            );
            let coordinator_file_default =
                build_coordinator_file_dto(&project_name, DEFAULT_WORKSPACE_NAME);
            items.push(build_workspace_item_with_coordinator(
                project_name.clone(),
                default_info,
                evo_index,
                None,
                None,
                coordinator_ai_default,
                coordinator_terminal_default,
                coordinator_file_default,
            ));
            cache_metrics_list.push(snapshot_to_metrics_info(
                &WorkspaceCacheSnapshot::from_counters(
                    &project_name,
                    DEFAULT_WORKSPACE_NAME,
                    &default_root,
                ),
            ));

            // 命名工作区
            let mut workspaces = project.workspaces.values().collect::<Vec<_>>();
            workspaces.sort_by(|a, b| a.name.cmp(&b.name));
            for ws in workspaces {
                let root = ws.worktree_path.to_string_lossy().to_string();
                let info = WorkspaceInfo {
                    name: ws.name.clone(),
                    root: root.clone(),
                    branch: ws.branch.clone(),
                    status: crate::application::project::workspace_status_str(&ws.status),
                    sidebar_status: Default::default(),
                };
                let recovery_state = ws.recovery_meta.as_ref().and_then(|m| {
                    if m.needs_attention() {
                        Some(m.recovery_state.clone())
                    } else {
                        None
                    }
                });
                let recovery_cursor = ws
                    .recovery_meta
                    .as_ref()
                    .and_then(|m| m.recovery_cursor.clone());
                let coordinator_ai =
                    build_coordinator_ai_dto(&session_statuses, &project_name, &ws.name);
                let coordinator_terminal = build_coordinator_terminal_dto(
                    terminal_map.get(&(project_name.clone(), ws.name.clone())),
                );
                let coordinator_file = build_coordinator_file_dto(&project_name, &ws.name);
                items.push(build_workspace_item_with_coordinator(
                    project_name.clone(),
                    info,
                    evo_index,
                    recovery_state,
                    recovery_cursor,
                    coordinator_ai,
                    coordinator_terminal,
                    coordinator_file,
                ));
                cache_metrics_list.push(snapshot_to_metrics_info(
                    &WorkspaceCacheSnapshot::from_counters(&project_name, &ws.name, &root),
                ));
            }
        }
    }

    items.sort_by(|a, b| {
        (a.project.clone(), a.workspace.clone()).cmp(&(b.project.clone(), b.workspace.clone()))
    });
    cache_metrics_list.sort_by(|a, b| {
        (a.project.clone(), a.workspace.clone()).cmp(&(b.project.clone(), b.workspace.clone()))
    });
    (items, cache_metrics_list)
}

/// 为指定工作区构建 Coordinator AI 展示状态 DTO（仅在有会话时返回）
fn build_coordinator_ai_dto(
    session_statuses: &std::sync::Arc<crate::ai::session_status::AiSessionStateStore>,
    project_name: &str,
    workspace_name: &str,
) -> Option<crate::server::protocol::CoordinatorAiDomainStateDto> {
    let ai_state = crate::ai::session_status::aggregate_workspace_ai_domain_state(
        session_statuses,
        project_name,
        workspace_name,
    );
    // 仅在有会话记录时才携带（避免每个工作区都传送空状态）
    if ai_state.total_session_count > 0 {
        Some(crate::server::protocol::CoordinatorAiDomainStateDto::from(
            &ai_state,
        ))
    } else {
        None
    }
}

/// 为指定工作区构建 Coordinator 终端领域状态 DTO（v1.47）
fn build_coordinator_terminal_dto(
    ws_terminal: Option<&&crate::server::terminal_registry::WorkspaceTerminalInfo>,
) -> Option<crate::server::protocol::CoordinatorTerminalDomainStateDto> {
    let info = ws_terminal?;
    // 仅在有终端时才携带种子
    if info.terminal_count == 0 {
        return None;
    }
    let alive = info.terminal_count as u32;
    let phase = if alive > 0 { "active" } else { "idle" };
    Some(crate::server::protocol::CoordinatorTerminalDomainStateDto {
        phase: phase.to_string(),
        alive_count: alive,
        total_count: alive,
    })
}

/// 为指定工作区构建 Coordinator 文件领域状态 DTO（v1.47）
fn build_coordinator_file_dto(
    project: &str,
    workspace: &str,
) -> Option<crate::server::protocol::CoordinatorFileDomainStateDto> {
    use crate::server::protocol::file::FileWorkspacePhase;
    let phase = crate::application::file::FileWorkspacePhaseTracker::current(project, workspace);
    // 仅在非 Idle 时才携带种子（避免每个工作区都传送初始空状态）
    if phase == FileWorkspacePhase::Idle {
        return None;
    }
    Some(crate::server::protocol::coordinator_file_dto_from_phase(
        phase,
    ))
}

fn snapshot_to_metrics_info(snap: &WorkspaceCacheSnapshot) -> WorkspaceCacheMetricsInfo {
    WorkspaceCacheMetricsInfo {
        project: snap.project.clone(),
        workspace: snap.workspace.clone(),
        file_cache: FileCacheMetricsInfo {
            hit_count: snap.file_cache.hit_count,
            miss_count: snap.file_cache.miss_count,
            rebuild_count: snap.file_cache.rebuild_count,
            incremental_update_count: snap.file_cache.incremental_update_count,
            eviction_count: snap.file_cache.eviction_count,
            item_count: snap.file_cache.item_count as u64,
            last_eviction_reason: snap.file_cache.last_eviction_reason.clone(),
        },
        git_cache: GitCacheMetricsInfo {
            hit_count: snap.git_cache.hit_count,
            miss_count: snap.git_cache.miss_count,
            rebuild_count: snap.git_cache.rebuild_count,
            eviction_count: snap.git_cache.eviction_count,
            item_count: snap.git_cache.item_count as u64,
            last_eviction_reason: snap.git_cache.last_eviction_reason.clone(),
        },
        budget_exceeded: snap.budget_exceeded,
        last_eviction_reason: snap.last_eviction_reason.clone(),
    }
}

/// 构建工作区快照条目（完整版，含恢复状态与三域 Coordinator 种子）
fn build_workspace_item_with_coordinator(
    project: String,
    workspace: WorkspaceInfo,
    evo_index: &HashMap<(String, String), EvolutionWorkspaceSummary>,
    recovery_state: Option<String>,
    recovery_cursor: Option<String>,
    coordinator_ai: Option<crate::server::protocol::CoordinatorAiDomainStateDto>,
    coordinator_terminal: Option<crate::server::protocol::CoordinatorTerminalDomainStateDto>,
    coordinator_file: Option<crate::server::protocol::CoordinatorFileDomainStateDto>,
) -> SystemSnapshotWorkspaceItem {
    let evo = evo_index.get(&(project.clone(), workspace.name.clone()));
    let evolution_status = evo
        .map(|v| v.status.clone())
        .unwrap_or_else(|| "not_started".to_string());
    let evolution_cycle_id = evo.and_then(|v| v.cycle_id.clone());
    let title = evo.and_then(|v| v.title.clone());
    let failure_reason = evo.and_then(|v| v.failure_reason.clone());

    SystemSnapshotWorkspaceItem {
        project,
        workspace: workspace.name,
        path: workspace.root,
        branch: workspace.branch,
        workspace_status: workspace.status,
        evolution_status,
        evolution_cycle_id,
        title,
        failure_reason,
        recovery_state,
        recovery_cursor,
        coordinator_ai,
        coordinator_terminal,
        coordinator_file,
    }
}

fn summarize_failure_reason(
    item: &crate::server::protocol::EvolutionWorkspaceItem,
) -> Option<String> {
    non_empty_opt(item.terminal_error_message.as_deref())
        .or_else(|| non_empty_opt(item.rate_limit_error_message.as_deref()))
        .or_else(|| non_empty_opt(item.terminal_reason_code.as_deref()))
}

fn non_empty_opt(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(|v| v.to_string())
}

fn build_terminal_resource_snapshot(
    info: TerminalResourceInfo,
    perf: TerminalPerfSnapshot,
) -> TerminalResourceSnapshot {
    let per_workspace = info
        .per_workspace
        .into_iter()
        .map(|w| WorkspaceTerminalSnapshot {
            project: w.project,
            workspace: w.workspace,
            terminal_count: w.terminal_count,
            scrollback_bytes: w.scrollback_bytes,
        })
        .collect();
    TerminalResourceSnapshot {
        total_terminal_count: info.total_terminal_count,
        total_scrollback_bytes: info.total_scrollback_bytes,
        global_budget_bytes: info.global_budget_bytes,
        budget_used_percent: info.budget_used_percent,
        reclaimed_total: perf.reclaimed_total,
        scrollback_trim_total: perf.scrollback_trim_total,
        per_workspace,
    }
}

fn build_log_context_summary() -> LogContextSummary {
    let log_dir = dirs::home_dir()
        .map(|h| h.join(".tidyflow").join("logs"))
        .unwrap_or_default();
    let today = chrono::Local::now().format("%Y-%m-%d").to_string();
    let suffix = std::env::var("TIDYFLOW_LOG_SUFFIX").ok().and_then(|s| {
        let trimmed = s.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    });
    let filename = match suffix {
        Some(s) => format!("{today}-{s}.log"),
        None => format!("{today}.log"),
    };
    let log_file = log_dir.join(&filename).to_string_lossy().to_string();
    let perf_logging_enabled = std::env::var("TIDYFLOW_PERF_LOG")
        .ok()
        .as_deref()
        .map(str::to_ascii_lowercase)
        .map_or(false, |v| matches!(v.as_str(), "1" | "true" | "yes" | "on"));
    LogContextSummary {
        log_file,
        retention_days: 7,
        perf_logging_enabled,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::extract::State;
    use chrono::Utc;
    use std::sync::Arc;

    use crate::server::handlers::ai::AIState;
    use crate::server::remote_sub_registry::RemoteSubRegistry;
    use crate::server::terminal_registry::TerminalRegistry;
    use crate::workspace::state::{AppState, Project, Workspace, WorkspaceStatus};

    fn test_item(
        cycle_id: &str,
        title: Option<&str>,
        terminal_reason_code: Option<&str>,
        terminal_error_message: Option<&str>,
        rate_limit_error_message: Option<&str>,
    ) -> crate::server::protocol::EvolutionWorkspaceItem {
        crate::server::protocol::EvolutionWorkspaceItem {
            project: "demo".to_string(),
            workspace: "default".to_string(),
            cycle_id: cycle_id.to_string(),
            title: title.map(|v| v.to_string()),
            status: "running".to_string(),
            current_stage: "direction".to_string(),
            global_loop_round: 1,
            loop_round_limit: 3,
            verify_iteration: 0,
            verify_iteration_limit: 2,
            agents: Vec::new(),
            executions: Vec::new(),
            terminal_reason_code: terminal_reason_code.map(|v| v.to_string()),
            terminal_error_message: terminal_error_message.map(|v| v.to_string()),
            rate_limit_error_message: rate_limit_error_message.map(|v| v.to_string()),
            started_at: None,
            duration_ms: None,
            error_code: None,
            retryable: false,
        }
    }

    fn make_test_state() -> AppState {
        let mut state = AppState::default();
        state.add_project(Project {
            name: "demo".to_string(),
            root_path: "/tmp/demo".into(),
            remote_url: None,
            default_branch: "main".to_string(),
            created_at: Utc::now(),
            workspaces: HashMap::from([(
                "alpha".to_string(),
                Workspace {
                    name: "alpha".to_string(),
                    worktree_path: "/tmp/demo/.worktrees/alpha".into(),
                    branch: "tidy/alpha".to_string(),
                    status: WorkspaceStatus::Ready,
                    created_at: Utc::now(),
                    last_accessed: Utc::now(),
                    setup_result: None,
                    recovery_meta: None,
                },
            )]),
            commands: Vec::new(),
        });
        state
    }

    async fn make_test_context(
        app_state: AppState,
    ) -> crate::server::ws::transport::bootstrap::AppContext {
        let shared_state: crate::server::context::SharedAppState =
            Arc::new(tokio::sync::RwLock::new(app_state));
        let (save_tx, _save_rx) = tokio::sync::mpsc::channel(8);
        let (scrollback_tx, _scrollback_rx) = tokio::sync::mpsc::channel(8);
        let (task_broadcast_tx, _task_broadcast_rx) = tokio::sync::broadcast::channel(8);
        crate::server::ws::transport::bootstrap::AppContext {
            app_state: shared_state,
            save_tx,
            terminal_registry: Arc::new(tokio::sync::Mutex::new(TerminalRegistry::new())),
            scrollback_tx,
            expected_ws_token: Some("required-token".to_string()),
            pairing_registry: Arc::new(tokio::sync::Mutex::new(
                crate::server::ws::pairing::new_pairing_registry(&[]),
            )),
            remote_sub_registry: Arc::new(tokio::sync::Mutex::new(RemoteSubRegistry::new())),
            task_broadcast_tx,
            running_commands: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
            running_ai_tasks: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
            task_history: Arc::new(tokio::sync::Mutex::new(Vec::new())),
            ai_state: Arc::new(tokio::sync::Mutex::new(AIState::new())),
            state_store: Arc::new(
                crate::workspace::state_store::StateStore::open_in_memory_for_test()
                    .await
                    .expect("test state store"),
            ),
        }
    }

    /// 空终端注册信息（测试用）
    fn empty_terminal_info() -> crate::server::terminal_registry::TerminalResourceInfo {
        crate::server::terminal_registry::TerminalResourceInfo {
            total_terminal_count: 0,
            total_scrollback_bytes: 0,
            global_budget_bytes: 64 * 1024 * 1024,
            budget_used_percent: 0,
            per_workspace: vec![],
        }
    }

    #[test]
    fn failure_reason_priority_should_be_terminal_then_rate_limit_then_code() {
        let a = test_item(
            "c1",
            Some("标题"),
            Some("reason_code"),
            Some("terminal_error"),
            Some("rate_limit"),
        );
        assert_eq!(
            summarize_failure_reason(&a),
            Some("terminal_error".to_string())
        );

        let b = test_item(
            "c1",
            Some("标题"),
            Some("reason_code"),
            None,
            Some("rate_limit"),
        );
        assert_eq!(summarize_failure_reason(&b), Some("rate_limit".to_string()));

        let c = test_item("c1", Some("标题"), Some("reason_code"), None, None);
        assert_eq!(
            summarize_failure_reason(&c),
            Some("reason_code".to_string())
        );
    }

    #[test]
    fn title_should_be_none_when_cycle_id_exists_but_title_missing() {
        let items = vec![test_item("cycle-1", None, None, None, None)];
        let idx = evolution_index_from_items(&items);
        let summary = idx
            .get(&("demo".to_string(), "default".to_string()))
            .expect("summary should exist");
        assert_eq!(summary.cycle_id.as_deref(), Some("cycle-1"));
        assert_eq!(summary.title, None);
    }

    #[tokio::test]
    async fn title_should_be_propagated_when_present() {
        let items = vec![test_item("cycle-2", Some("本轮标题"), None, None, None)];
        let idx = evolution_index_from_items(&items);
        let ai_state: crate::server::handlers::ai::SharedAIState =
            Arc::new(tokio::sync::Mutex::new(AIState::new()));
        let (result, _) = build_workspace_items_and_metrics(
            &Arc::new(tokio::sync::RwLock::new(make_test_state())),
            &idx,
            &ai_state,
            &empty_terminal_info(),
        )
        .await;
        let default_item = result
            .iter()
            .find(|it| it.project == "demo" && it.workspace == "default")
            .expect("default workspace should exist");
        assert_eq!(default_item.evolution_cycle_id.as_deref(), Some("cycle-2"));
        assert_eq!(default_item.title.as_deref(), Some("本轮标题"));
    }

    #[tokio::test]
    async fn workspace_items_should_include_default_and_not_started_when_no_evolution() {
        let state = make_test_state();
        let ai_state: crate::server::handlers::ai::SharedAIState =
            Arc::new(tokio::sync::Mutex::new(AIState::new()));
        let (items, cache_metrics) = build_workspace_items_and_metrics(
            &Arc::new(tokio::sync::RwLock::new(state)),
            &HashMap::new(),
            &ai_state,
            &empty_terminal_info(),
        )
        .await;
        let default_item = items
            .iter()
            .find(|it| it.project == "demo" && it.workspace == "default")
            .expect("default workspace should exist");
        assert_eq!(default_item.evolution_status, "not_started");
        assert_eq!(default_item.evolution_cycle_id, None);
        assert_eq!(default_item.title, None);
        // cache_metrics 应包含 default 工作区的指标条目
        assert!(cache_metrics
            .iter()
            .any(|m| m.project == "demo" && m.workspace == "default"));
    }

    #[tokio::test]
    async fn workspace_items_should_be_sorted_by_project_and_workspace() {
        let mut state = AppState::default();
        state.add_project(Project {
            name: "zeta".to_string(),
            root_path: "/tmp/zeta".into(),
            remote_url: None,
            default_branch: "main".to_string(),
            created_at: Utc::now(),
            workspaces: HashMap::new(),
            commands: Vec::new(),
        });
        state.add_project(Project {
            name: "alpha".to_string(),
            root_path: "/tmp/alpha".into(),
            remote_url: None,
            default_branch: "main".to_string(),
            created_at: Utc::now(),
            workspaces: HashMap::new(),
            commands: Vec::new(),
        });
        let ai_state: crate::server::handlers::ai::SharedAIState =
            Arc::new(tokio::sync::Mutex::new(AIState::new()));
        let (items, _) = build_workspace_items_and_metrics(
            &Arc::new(tokio::sync::RwLock::new(state)),
            &HashMap::new(),
            &ai_state,
            &empty_terminal_info(),
        )
        .await;
        assert_eq!(
            items
                .iter()
                .map(|i| format!("{}/{}", i.project, i.workspace))
                .collect::<Vec<_>>(),
            vec!["alpha/default".to_string(), "zeta/default".to_string()]
        );
    }

    #[tokio::test]
    async fn system_snapshot_should_allow_request_without_token() {
        let ctx = make_test_context(make_test_state()).await;
        let response = system_snapshot_handler(State(ctx))
            .await
            .expect("handler should return response")
            .0;

        assert_eq!(response.msg_type, "system_snapshot");
    }

    // CHK-004: system_snapshot 包含终端资源快照
    #[tokio::test]
    async fn system_snapshot_should_include_terminal_resource() {
        let ctx = make_test_context(make_test_state()).await;
        let response = system_snapshot_handler(State(ctx))
            .await
            .expect("handler should return response")
            .0;

        // 空注册表时应为 0
        assert_eq!(response.terminal_resource.total_terminal_count, 0);
        assert_eq!(response.terminal_resource.total_scrollback_bytes, 0);
        assert_eq!(response.terminal_resource.budget_used_percent, 0);
        assert!(response.terminal_resource.global_budget_bytes > 0);
        assert!(response.terminal_resource.per_workspace.is_empty());
    }

    // CHK-004: build_terminal_resource_snapshot 正确映射字段
    #[test]
    fn terminal_resource_snapshot_maps_correctly() {
        use crate::server::perf::TerminalPerfSnapshot;
        use crate::server::terminal_registry::{TerminalResourceInfo, WorkspaceTerminalInfo};

        let info = TerminalResourceInfo {
            total_terminal_count: 3,
            total_scrollback_bytes: 1024,
            global_budget_bytes: 64 * 1024 * 1024,
            budget_used_percent: 0,
            per_workspace: vec![WorkspaceTerminalInfo {
                project: "proj".to_string(),
                workspace: "ws".to_string(),
                terminal_count: 3,
                scrollback_bytes: 1024,
            }],
        };
        let perf = TerminalPerfSnapshot {
            reclaimed_total: 5,
            scrollback_trim_total: 2,
        };
        let snap = build_terminal_resource_snapshot(info, perf);
        assert_eq!(snap.total_terminal_count, 3);
        assert_eq!(snap.reclaimed_total, 5);
        assert_eq!(snap.scrollback_trim_total, 2);
        assert_eq!(snap.per_workspace.len(), 1);
        assert_eq!(snap.per_workspace[0].project, "proj");
    }

    /// CHK-005: system_snapshot 多工作区恢复状态隔离 — 不同项目中同名工作区的 recovery_state 独立
    #[tokio::test]
    async fn system_snapshot_should_isolate_recovery_state_per_project_workspace() {
        use crate::workspace::state::{Project, Workspace, WorkspaceRecoveryMeta, WorkspaceStatus};
        use std::collections::HashMap;

        let mut state = AppState::default();
        let now = Utc::now();

        // project-a: 同名工作区处于中断态
        let ws_interrupted = Workspace {
            name: "feature".to_string(),
            worktree_path: "/tmp/proj-a/.worktrees/feature".into(),
            branch: "feature/a".to_string(),
            status: WorkspaceStatus::Initializing,
            created_at: now,
            last_accessed: now,
            setup_result: None,
            recovery_meta: Some(WorkspaceRecoveryMeta {
                recovery_state: "interrupted".to_string(),
                recovery_cursor: Some("step-2".to_string()),
                failed_context: None,
                interrupted_at: Some(now),
            }),
        };
        state.add_project(Project {
            name: "project-a".to_string(),
            root_path: "/tmp/proj-a".into(),
            remote_url: None,
            default_branch: "main".to_string(),
            created_at: now,
            workspaces: HashMap::from([("feature".to_string(), ws_interrupted)]),
            commands: Vec::new(),
        });

        // project-b: 同名工作区无恢复元数据（正常态）
        let ws_normal = Workspace {
            name: "feature".to_string(),
            worktree_path: "/tmp/proj-b/.worktrees/feature".into(),
            branch: "feature/b".to_string(),
            status: WorkspaceStatus::Ready,
            created_at: now,
            last_accessed: now,
            setup_result: None,
            recovery_meta: None,
        };
        state.add_project(Project {
            name: "project-b".to_string(),
            root_path: "/tmp/proj-b".into(),
            remote_url: None,
            default_branch: "main".to_string(),
            created_at: now,
            workspaces: HashMap::from([("feature".to_string(), ws_normal)]),
            commands: Vec::new(),
        });

        let ai_state_4: crate::server::handlers::ai::SharedAIState =
            Arc::new(tokio::sync::Mutex::new(AIState::new()));
        let (items, _) = build_workspace_items_and_metrics(
            &Arc::new(tokio::sync::RwLock::new(state)),
            &HashMap::new(),
            &ai_state_4,
            &empty_terminal_info(),
        )
        .await;

        // 找到 project-a/feature 和 project-b/feature
        let item_a = items
            .iter()
            .find(|it| it.project == "project-a" && it.workspace == "feature")
            .expect("project-a/feature should be in items");
        let item_b = items
            .iter()
            .find(|it| it.project == "project-b" && it.workspace == "feature")
            .expect("project-b/feature should be in items");

        // project-a 应携带 recovery_state = "interrupted"
        assert_eq!(
            item_a.recovery_state.as_deref(),
            Some("interrupted"),
            "project-a/feature should have recovery_state=interrupted"
        );
        assert_eq!(
            item_a.recovery_cursor.as_deref(),
            Some("step-2"),
            "project-a/feature recovery_cursor should roundtrip"
        );

        // project-b 不应受 project-a 的中断态影响
        assert!(
            item_b.recovery_state.is_none(),
            "project-b/feature should have no recovery_state (no cross-workspace leakage)"
        );
        assert!(
            item_b.recovery_cursor.is_none(),
            "project-b/feature should have no recovery_cursor"
        );
    }

    /// 定向测试：system_snapshot 应包含 perf_metrics 和 log_context 可观测性字段
    #[tokio::test]
    async fn system_snapshot_should_include_perf_metrics_and_log_context() {
        // 递增一个全局计数器，确保快照能捕获到
        crate::server::perf::record_ws_decode_ms(42);

        let ctx = make_test_context(make_test_state()).await;
        let response = system_snapshot_handler(State(ctx))
            .await
            .expect("handler should return response")
            .0;

        // perf_metrics 应捕获到至少一条 ws_decode 记录
        assert!(
            response.perf_metrics.ws_decode.count >= 1,
            "ws_decode.count should reflect at least the record we just wrote"
        );
        assert!(
            response.perf_metrics.ws_decode.last_ms > 0,
            "ws_decode.last_ms should be nonzero"
        );

        // log_context 应包含有效日志路径和保留天数
        assert!(
            response.log_context.log_file.contains(".tidyflow/logs/"),
            "log_file should point to tidyflow logs directory"
        );
        assert_eq!(response.log_context.retention_days, 7);
    }

    /// 定向测试：perf_metrics 可正确序列化为 JSON（协议 v8 稳定输出）
    #[test]
    fn perf_metrics_snapshot_should_serialize_to_stable_json() {
        let snapshot = crate::server::perf::snapshot_perf_metrics();
        let json = serde_json::to_value(&snapshot).expect("should serialize");
        // 确认所有顶层字段存在
        assert!(json.get("ws_task_broadcast_lag_total").is_some());
        assert!(json.get("terminal_reclaimed_total").is_some());
        assert!(json.get("ws_outbound_loop_tick").is_some());
        assert!(json.get("ws_decode").is_some());
        assert!(json.get("ai_subscriber_fanout").is_some());
        assert!(json.get("evolution_cycle_update_emitted_total").is_some());
        // WsPipelineMetrics 嵌套结构应含 last_ms/max_ms/count
        let tick = json.get("ws_outbound_loop_tick").unwrap();
        assert!(tick.get("last_ms").is_some());
        assert!(tick.get("max_ms").is_some());
        assert!(tick.get("count").is_some());
    }

    /// CHK-003 定向测试：system_snapshot 的 performance_observability 字段结构正确存在
    ///
    /// 覆盖：PerformanceObservabilitySnapshot 顶层字段命名与协议约定一致；
    /// core_memory、ws_pipeline_latency、snapshot_at 均在序列化输出中稳定存在。
    #[tokio::test]
    async fn system_snapshot_should_include_perf_observability_fields() {
        let ctx = make_test_context(make_test_state()).await;
        let response = system_snapshot_handler(State(ctx))
            .await
            .expect("handler should return response")
            .0;

        let json =
            serde_json::to_value(&response.performance_observability).expect("should serialize");

        // 顶层字段必须存在
        assert!(
            json.get("core_memory").is_some(),
            "performance_observability.core_memory 必须存在"
        );
        assert!(
            json.get("ws_pipeline_latency").is_some(),
            "performance_observability.ws_pipeline_latency 必须存在"
        );
        assert!(
            json.get("snapshot_at").is_some(),
            "performance_observability.snapshot_at 必须存在"
        );

        // core_memory 结构必须包含预期字段
        let core_mem = &json["core_memory"];
        assert!(
            core_mem.get("resident_bytes").is_some(),
            "core_memory.resident_bytes 必须存在"
        );
        assert!(
            core_mem.get("phys_footprint_bytes").is_some(),
            "core_memory.phys_footprint_bytes 必须存在"
        );

        // ws_pipeline_latency 结构必须包含预期字段
        let ws_lat = &json["ws_pipeline_latency"];
        assert!(
            ws_lat.get("last_ms").is_some(),
            "ws_pipeline_latency.last_ms 必须存在"
        );
        assert!(
            ws_lat.get("p95_ms").is_some(),
            "ws_pipeline_latency.p95_ms 必须存在"
        );
        assert!(
            ws_lat.get("sample_count").is_some(),
            "ws_pipeline_latency.sample_count 必须存在"
        );
    }

    /// 定向测试：performance_observability 可正确序列化为 JSON（协议 v9 稳定字段名验证）
    #[test]
    fn perf_observability_snapshot_should_serialize_with_stable_field_names() {
        let obs = crate::server::perf::build_performance_observability_snapshot();
        let json = serde_json::to_value(&obs).expect("should serialize");

        // 确认字段使用 snake_case 命名
        assert!(
            json.get("core_memory").is_some(),
            "core_memory 字段命名必须为 snake_case"
        );
        assert!(
            json.get("ws_pipeline_latency").is_some(),
            "ws_pipeline_latency 字段命名必须为 snake_case"
        );
        assert!(
            json.get("snapshot_at").is_some(),
            "snapshot_at 字段必须存在"
        );

        // workspace_metrics / client_metrics / diagnoses 在空时应被省略（skip_serializing_if）
        // 验证这一行为符合协议约定
        let obs_empty = crate::server::protocol::health::PerformanceObservabilitySnapshot {
            core_memory: Default::default(),
            ws_pipeline_latency: crate::server::protocol::health::LatencyMetricWindow {
                last_ms: 0,
                avg_ms: 0,
                p95_ms: 0,
                max_ms: 0,
                sample_count: 0,
                window_size: 128,
            },
            workspace_metrics: Vec::new(),
            client_metrics: Vec::new(),
            diagnoses: Vec::new(),
            snapshot_at: 0,
        };
        let json_empty = serde_json::to_value(&obs_empty).expect("should serialize empty");
        // 空数组字段应被跳过
        assert!(
            json_empty.get("workspace_metrics").is_none(),
            "空 workspace_metrics 应被 skip_serializing_if 省略"
        );
        assert!(
            json_empty.get("client_metrics").is_none(),
            "空 client_metrics 应被 skip_serializing_if 省略"
        );
        assert!(
            json_empty.get("diagnoses").is_none(),
            "空 diagnoses 应被 skip_serializing_if 省略"
        );
    }
}
