use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Utc};
use tracing::warn;
use uuid::Uuid;

use crate::server::context::HandlerContext;
use crate::server::handlers::ai::resolve_directory;
use crate::server::protocol::{
    EvolutionCycleHistoryItem, EvolutionCycleStageHistoryEntry, EvolutionSessionExecutionEntry,
    EvolutionWorkspaceItem, ServerMessage,
};

use super::consts::compare_runtime_stage_names;
use super::stage::{agent_name, build_agents};
use super::utils::{evolution_workspace_dir, read_json, workspace_key};
use super::{
    EvolutionManager, SnapshotResult, StartWorkspaceReq, WorkspaceRunState,
    BACKLOG_CONTRACT_VERSION_V2, DEFAULT_VERIFY_LIMIT, STAGES,
};

fn initial_global_loop_round() -> u32 {
    1
}

/// 从 RFC3339 起始时间戳到当前时间计算耗时（毫秒）
fn compute_evo_duration_ms(created_at: &str) -> Option<u64> {
    let start = DateTime::parse_from_rfc3339(created_at).ok()?;
    let now = Utc::now();
    let d = now.signed_duration_since(start).num_milliseconds();
    if d >= 0 { Some(d as u64) } else { None }
}

/// 从两个 RFC3339 时间戳间计算耗时（毫秒），用于历史循环
fn compute_evo_duration_between(created_at: &str, updated_at: &str) -> Option<u64> {
    let start = DateTime::parse_from_rfc3339(created_at).ok()?;
    let end = DateTime::parse_from_rfc3339(updated_at).ok()?;
    let d = end.signed_duration_since(start).num_milliseconds();
    if d >= 0 { Some(d as u64) } else { None }
}

/// 从历史循环状态判定是否可重试
fn is_cycle_retryable(status: &str, terminal_reason_code: Option<&str>) -> bool {
    // failed_exhausted 表示重试次数耗尽但可以再来
    if status == "failed_exhausted" {
        return true;
    }
    // terminal_reason_code 指定可重试的场景
    if let Some(code) = terminal_reason_code {
        return code == "verify_exhausted"
            || code == "loop_exhausted"
            || code == "evo_gate_decision_blocked";
    }
    false
}

fn is_terminal_execution_status(status: &str) -> bool {
    matches!(
        status,
        "done" | "failed" | "blocked" | "skipped" | "stopped" | "interrupted" | "completed"
    )
}

fn non_empty_string(v: Option<&serde_json::Value>) -> Option<String> {
    v.and_then(|value| value.as_str())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

#[allow(dead_code)]
fn extract_cycle_title_from_direction_stage(stage_json: &serde_json::Value) -> Option<String> {
    non_empty_string(stage_json.get("title"))
        .or_else(|| non_empty_string(stage_json.get("direction_statement")))
}

fn extract_cycle_title_from_cycle_file(cycle_json: &serde_json::Value) -> Option<String> {
    non_empty_string(cycle_json.get("title"))
}

#[allow(dead_code)]
fn resolve_cycle_history_title(
    direction_stage_title: Option<String>,
    cycle_file_title: Option<String>,
) -> Option<String> {
    direction_stage_title.or(cycle_file_title)
}

fn parse_cycle_session_executions(
    cycle_json: &serde_json::Value,
) -> Vec<EvolutionSessionExecutionEntry> {
    cycle_json
        .get("executions")
        .and_then(|value| value.as_array())
        .into_iter()
        .flatten()
        .filter_map(|item| item.as_object())
        .filter_map(|item| {
            let session_id = non_empty_string(item.get("session_id"))?;
            let stage =
                non_empty_string(item.get("stage")).unwrap_or_else(|| "unknown".to_string());
            let status =
                non_empty_string(item.get("status")).unwrap_or_else(|| "unknown".to_string());
            if !is_terminal_execution_status(&status) {
                return None;
            }

            Some(EvolutionSessionExecutionEntry {
                stage,
                agent: non_empty_string(item.get("agent")).unwrap_or_default(),
                ai_tool: non_empty_string(item.get("ai_tool")).unwrap_or_default(),
                session_id,
                status,
                started_at: non_empty_string(item.get("started_at")).unwrap_or_default(),
                completed_at: non_empty_string(item.get("completed_at")),
                duration_ms: item.get("duration_ms").and_then(|value| value.as_u64()),
                tool_call_count: item
                    .get("tool_call_count")
                    .and_then(|value| value.as_u64())
                    .map(|value| value as u32)
                    .unwrap_or(0),
            })
        })
        .collect()
}

fn is_terminal_stage_status(status: &str) -> bool {
    matches!(
        status.trim().to_ascii_lowercase().as_str(),
        "done" | "failed" | "blocked" | "skipped" | "stopped" | "interrupted" | "completed"
    )
}

fn parse_cycle_stage_history_entries(
    cycle_json: &serde_json::Value,
) -> Vec<EvolutionCycleStageHistoryEntry> {
    let Some(stage_runtime) = cycle_json
        .get("stage_runtime")
        .and_then(|value| value.as_object())
    else {
        return Vec::new();
    };

    let mut stage_names: Vec<String> = stage_runtime.keys().cloned().collect();
    stage_names.sort_by(|left, right| compare_runtime_stage_names(left, right));

    let mut stages = Vec::new();
    for stage in stage_names {
        let Some(runtime) = stage_runtime
            .get(&stage)
            .and_then(|value| value.as_object())
        else {
            continue;
        };
        let status =
            non_empty_string(runtime.get("status")).unwrap_or_else(|| "unknown".to_string());
        if !is_terminal_stage_status(&status) {
            continue;
        }
        let ai_tool = non_empty_string(runtime.get("ai_tool")).unwrap_or_default();
        let duration_ms = runtime
            .get("timing")
            .and_then(|value| value.as_object())
            .and_then(|timing| timing.get("duration_ms"))
            .and_then(|value| value.as_u64());
        stages.push(EvolutionCycleStageHistoryEntry {
            stage: stage.clone(),
            agent: agent_name(&stage).to_string(),
            ai_tool,
            status,
            duration_ms,
        });
    }
    stages
}

fn extract_terminal_error_from_stage_runtime(cycle_json: &serde_json::Value) -> Option<String> {
    let stage_runtime = cycle_json.get("stage_runtime")?.as_object()?;
    let mut stage_names: Vec<String> = stage_runtime.keys().cloned().collect();
    stage_names.sort_by(|left, right| compare_runtime_stage_names(left, right));
    for stage in stage_names {
        let message = stage_runtime
            .get(&stage)
            .and_then(|value| value.get("error"))
            .and_then(|value| value.get("message"))
            .and_then(|value| value.as_str())
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty());
        if message.is_some() {
            return message;
        }
    }
    None
}

fn build_cycle_history_item(
    cycle_id: String,
    cycle_json: &serde_json::Value,
) -> Option<EvolutionCycleHistoryItem> {
    let status = cycle_json["status"]
        .as_str()
        .unwrap_or("unknown")
        .to_string();
    let global_loop_round = cycle_json["global_loop_round"].as_u64().unwrap_or(0) as u32;
    let created_at = cycle_json["created_at"].as_str().unwrap_or("").to_string();
    let updated_at = cycle_json["updated_at"].as_str().unwrap_or("").to_string();
    let terminal_reason_code = cycle_json["terminal_reason_code"]
        .as_str()
        .filter(|value| !value.is_empty())
        .map(|value| value.to_string());
    let terminal_error_message = cycle_json["terminal_error_message"]
        .as_str()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .or_else(|| extract_terminal_error_from_stage_runtime(cycle_json));
    let executions = parse_cycle_session_executions(cycle_json);
    let stages = parse_cycle_stage_history_entries(cycle_json);
    if stages.is_empty() && executions.is_empty() {
        return None;
    }

    let duration_ms = compute_evo_duration_between(&created_at, &updated_at);
    let retryable = is_cycle_retryable(&status, terminal_reason_code.as_deref());
    let error_code = terminal_reason_code.clone();

    Some(EvolutionCycleHistoryItem {
        cycle_id,
        title: extract_cycle_title_from_cycle_file(cycle_json),
        status,
        global_loop_round,
        created_at,
        updated_at,
        terminal_reason_code,
        terminal_error_message,
        executions,
        stages,
        duration_ms,
        error_code,
        retryable,
    })
}

#[allow(dead_code)]
fn parse_stage_session_executions(
    stage_name: &str,
    stage_json: &serde_json::Value,
) -> Vec<EvolutionSessionExecutionEntry> {
    let stage_status = stage_json["status"]
        .as_str()
        .unwrap_or("unknown")
        .to_string();
    let stage_agent = stage_json["agent"].as_str().unwrap_or("").to_string();
    let stage_ai_tool = stage_json["ai_tool"].as_str().unwrap_or("").to_string();
    let stage_timing = &stage_json["timing"];
    let stage_started_at = non_empty_string(stage_timing.get("started_at"));
    let stage_completed_at = non_empty_string(stage_timing.get("completed_at"));
    let stage_duration_ms = stage_timing["duration_ms"].as_u64();
    let stage_tool_call_count = stage_json["tool_call_count"]
        .as_u64()
        .map(|v| v as u32)
        .unwrap_or(0);

    let mut executions = Vec::new();
    let metadata_executions = stage_json
        .get("system_metadata")
        .and_then(|v| v.get("session_executions"))
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    for item in metadata_executions {
        let session_id = non_empty_string(item.get("session_id"));
        let Some(session_id) = session_id else {
            continue;
        };
        let status = non_empty_string(item.get("status")).unwrap_or_else(|| stage_status.clone());
        if !is_terminal_execution_status(&status) {
            continue;
        }
        let stage = non_empty_string(item.get("stage")).unwrap_or_else(|| stage_name.to_string());
        let agent = non_empty_string(item.get("agent")).unwrap_or_else(|| stage_agent.clone());
        let ai_tool =
            non_empty_string(item.get("ai_tool")).unwrap_or_else(|| stage_ai_tool.clone());
        let started_at = non_empty_string(item.get("started_at"))
            .or_else(|| stage_started_at.clone())
            .unwrap_or_default();
        let completed_at =
            non_empty_string(item.get("completed_at")).or_else(|| stage_completed_at.clone());
        let duration_ms = item
            .get("duration_ms")
            .and_then(|v| v.as_u64())
            .or(stage_duration_ms);
        let tool_call_count = item
            .get("tool_call_count")
            .and_then(|v| v.as_u64())
            .map(|v| v as u32)
            .unwrap_or(stage_tool_call_count);

        executions.push(EvolutionSessionExecutionEntry {
            stage,
            agent,
            ai_tool,
            session_id,
            status,
            started_at,
            completed_at,
            duration_ms,
            tool_call_count,
        });
    }

    if !executions.is_empty() {
        return executions;
    }

    if !is_terminal_execution_status(&stage_status) {
        return Vec::new();
    }

    let mut session_ids: Vec<String> = Vec::new();
    if let Some(outputs) = stage_json.get("outputs").and_then(|v| v.as_array()) {
        for output in outputs {
            if let Some(value) = non_empty_string(output.get("session_id")) {
                if !session_ids.iter().any(|sid| sid == &value) {
                    session_ids.push(value);
                }
            }
            if let Some(items) = output.get("session_ids").and_then(|v| v.as_array()) {
                for item in items {
                    if let Some(value) = non_empty_string(Some(item)) {
                        if !session_ids.iter().any(|sid| sid == &value) {
                            session_ids.push(value);
                        }
                    }
                }
            }
        }
    }

    if session_ids.is_empty() {
        return Vec::new();
    }

    session_ids
        .into_iter()
        .map(|session_id| EvolutionSessionExecutionEntry {
            stage: stage_name.to_string(),
            agent: stage_agent.clone(),
            ai_tool: stage_ai_tool.clone(),
            session_id,
            status: stage_status.clone(),
            started_at: stage_started_at.clone().unwrap_or_default(),
            completed_at: stage_completed_at.clone(),
            duration_ms: stage_duration_ms,
            tool_call_count: stage_tool_call_count,
        })
        .collect()
}

impl EvolutionManager {
    pub(super) async fn start_workspace(
        &self,
        req: StartWorkspaceReq,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        let key = workspace_key(&req.project, &req.workspace);
        let workspace_root =
            resolve_directory(&ctx.app_state, &req.project, &req.workspace).await?;
        if self
            .emit_blocking_required_if_any(
                &req.project,
                &req.workspace,
                &workspace_root,
                "start",
                None,
                None,
                ctx,
            )
            .await?
        {
            return Ok(());
        }

        {
            let workers = self.workers.lock().await;
            if workers.contains_key(&key) {
                return Err(format!("evo_workspace_locked: {}", key));
            }
        }

        let stage_profiles = if req.stage_profiles.is_empty() {
            self.get_agent_profile(&req.project, &req.workspace, ctx)
                .await
        } else {
            super::profile::normalize_profiles(req.stage_profiles)?
        };
        let now = Utc::now();
        let cycle_id = now.format("%Y-%m-%dT%H-%M-%S-%3fZ").to_string();

        let mut stage_statuses = HashMap::new();
        let mut stage_tool_call_counts = HashMap::new();
        let mut stage_seen_tool_calls = HashMap::new();
        for stage in STAGES {
            stage_statuses.insert(stage.to_string(), "pending".to_string());
            stage_tool_call_counts.insert(stage.to_string(), 0);
            stage_seen_tool_calls.insert(stage.to_string(), HashSet::new());
        }

        let global_loop_round = {
            let mut state = self.state.lock().await;
            state.activation_state = "activated".to_string();
            if let Some(existing) = state.workspaces.get(&key) {
                let is_terminal = existing.status == "completed"
                    || existing.status == "failed_exhausted"
                    || existing.status == "failed_system";
                if !is_terminal {
                    return Err(format!("evo_workspace_locked: {}", key));
                }
            }
            let round = initial_global_loop_round();
            let now_rfc3339 = Utc::now().to_rfc3339();
            state.workspaces.insert(
                key.clone(),
                WorkspaceRunState {
                    project: req.project.clone(),
                    workspace: req.workspace.clone(),
                    workspace_root: workspace_root.clone(),
                    priority: req.priority,
                    status: "queued".to_string(),
                    cycle_id: cycle_id.clone(),
                    cycle_title: None,
                    current_stage: "direction".to_string(),
                    global_loop_round: round,
                    loop_round_limit: req.loop_round_limit.max(1),
                    verify_iteration: 0,
                    verify_iteration_limit: DEFAULT_VERIFY_LIMIT,
                    backlog_contract_version: BACKLOG_CONTRACT_VERSION_V2,
                    created_at: now_rfc3339,
                    stop_requested: false,
                    terminal_reason_code: None,
                    terminal_error_message: None,
                    rate_limit_resume_at: None,
                    rate_limit_error_message: None,
                    stage_profiles,
                    stage_statuses,
                    stage_sessions: HashMap::new(),
                    stage_session_history: HashMap::new(),
                    stage_tool_call_counts,
                    stage_seen_tool_calls,
                    stage_retry_counts: HashMap::new(),
                    session_executions: Vec::new(),
                    stage_started_ats: HashMap::new(),
                    stage_duration_ms: HashMap::new(),
                },
            );
            round
        };

        if let Err(e) = self.persist_cycle_file(&key).await {
            warn!("persist cycle file failed: {}", e);
        }

        self.broadcast(
            ctx,
            ServerMessage::EvoWorkspaceStarted {
                event_id: Uuid::new_v4().to_string(),
                event_seq: self.next_seq(&key).await,
                project: req.project.clone(),
                workspace: req.workspace.clone(),
                cycle_id: cycle_id.clone(),
                ts: Utc::now().to_rfc3339(),
                source: "user".to_string(),
                status: "queued".to_string(),
            },
        )
        .await;

        self.broadcast_scheduler(ctx).await;
        self.spawn_worker(key, global_loop_round, ctx.clone()).await;
        Ok(())
    }

    pub(super) async fn stop_workspace(
        &self,
        project: &str,
        workspace: &str,
        reason: Option<String>,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        let key = workspace_key(project, workspace);
        let (cycle_id, status) = {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(&key) else {
                return Err(format!("evo_cycle_not_found: {}", key));
            };
            entry.stop_requested = true;
            (entry.cycle_id.clone(), entry.status.clone())
        };

        self.broadcast(
            ctx,
            ServerMessage::EvoWorkspaceStopped {
                event_id: Uuid::new_v4().to_string(),
                event_seq: self.next_seq(&key).await,
                project: project.to_string(),
                workspace: workspace.to_string(),
                cycle_id,
                ts: Utc::now().to_rfc3339(),
                source: "user".to_string(),
                status,
                reason,
            },
        )
        .await;

        self.broadcast_scheduler(ctx).await;
        Ok(())
    }

    pub(super) async fn stop_all(&self, reason: Option<String>, ctx: &HandlerContext) {
        let keys = {
            let mut state = self.state.lock().await;
            let mut keys = Vec::new();
            for (key, entry) in state.workspaces.iter_mut() {
                entry.stop_requested = true;
                keys.push((
                    key.clone(),
                    entry.project.clone(),
                    entry.workspace.clone(),
                    entry.cycle_id.clone(),
                    entry.status.clone(),
                ));
            }
            keys
        };

        for (key, project, workspace, cycle_id, status) in keys {
            self.broadcast(
                ctx,
                ServerMessage::EvoWorkspaceStopped {
                    event_id: Uuid::new_v4().to_string(),
                    event_seq: self.next_seq(&key).await,
                    project,
                    workspace,
                    cycle_id,
                    ts: Utc::now().to_rfc3339(),
                    source: "user".to_string(),
                    status,
                    reason: reason.clone(),
                },
            )
            .await;
        }

        self.broadcast_scheduler(ctx).await;
    }

    pub(super) async fn resume_workspace(
        &self,
        project: &str,
        workspace: &str,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        let key = workspace_key(project, workspace);
        {
            let workers = self.workers.lock().await;
            if workers.contains_key(&key) {
                return Ok(());
            }
        }

        let (cycle_id, current_stage, workspace_root) = {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(&key) else {
                return Err(format!("evo_cycle_not_found: {}", key));
            };
            if entry.status != "interrupted" && entry.status != "stopped" {
                return Err(format!("evo_resume_not_allowed: {}", entry.status));
            }
            (
                entry.cycle_id.clone(),
                entry.current_stage.clone(),
                entry.workspace_root.clone(),
            )
        };
        if self
            .emit_blocking_required_if_any(
                project,
                workspace,
                &workspace_root,
                "resume",
                Some(&cycle_id),
                Some(&current_stage),
                ctx,
            )
            .await?
        {
            return Ok(());
        }

        {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(&key) else {
                return Err(format!("evo_cycle_not_found: {}", key));
            };
            entry.stop_requested = false;
            entry.status = "queued".to_string();
            entry.terminal_reason_code = None;
            entry.terminal_error_message = None;
            entry.rate_limit_resume_at = None;
            entry.rate_limit_error_message = None;
        }

        self.broadcast(
            ctx,
            ServerMessage::EvoWorkspaceResumed {
                event_id: Uuid::new_v4().to_string(),
                event_seq: self.next_seq(&key).await,
                project: project.to_string(),
                workspace: workspace.to_string(),
                cycle_id,
                ts: Utc::now().to_rfc3339(),
                source: "user".to_string(),
                status: "queued".to_string(),
            },
        )
        .await;

        self.broadcast_scheduler(ctx).await;
        self.spawn_worker(key, 0, ctx.clone()).await;
        Ok(())
    }

    /// 在循环运行或排队中动态调整最大轮次上限
    pub(super) async fn adjust_loop_round(
        &self,
        project: &str,
        workspace: &str,
        new_limit: u32,
        _ctx: &HandlerContext,
    ) -> Result<(), String> {
        let new_limit = new_limit.max(1);
        let key = workspace_key(project, workspace);
        let mut state = self.state.lock().await;
        let Some(entry) = state.workspaces.get_mut(&key) else {
            return Err(format!("evo_cycle_not_found: {}", key));
        };
        if entry.status != "running" && entry.status != "queued" {
            return Err(format!(
                "evo_adjust_loop_round_not_allowed: status={}",
                entry.status
            ));
        }
        entry.loop_round_limit = new_limit;
        Ok(())
    }

    /// 应用调度建议到自适应调度状态
    ///
    /// 消费分析引擎输出的调度建议，动态调整并发上限、排队策略和降级行为。
    /// 所有调优动作受安全边界约束，超出边界时自动回退到保守默认值。
    /// 决策按工作区隔离，并记录审计信息。
    pub(super) async fn apply_scheduling_recommendations(
        &self,
        recommendations: &[crate::server::protocol::health::SchedulingRecommendation],
        aggregates: &[crate::server::protocol::health::ObservationAggregate],
    ) {
        use crate::server::protocol::health::SchedulingRecommendationKind;
        use super::consts::*;
        use super::types::{AdaptiveDecision, AdaptiveDecisionKind};

        let mut state = self.state.lock().await;
        let now_str = chrono::Utc::now().to_rfc3339();

        for rec in recommendations {
            match rec.kind {
                SchedulingRecommendationKind::ReduceConcurrency => {
                    let suggested = rec.suggested_value.unwrap_or(1) as u32;
                    let current = state.adaptive.effective_max_parallel.unwrap_or(state.max_parallel_workspaces);
                    let new_val = suggested.clamp(ADAPTIVE_MIN_PARALLEL, ADAPTIVE_MAX_PARALLEL);
                    if new_val < current {
                        let decision = AdaptiveDecision {
                            kind: AdaptiveDecisionKind::ConcurrencyAdjusted,
                            reason: rec.reason.clone(),
                            previous_value: current as i64,
                            new_value: new_val as i64,
                            safe_lower_bound: ADAPTIVE_MIN_PARALLEL as i64,
                            safe_upper_bound: ADAPTIVE_MAX_PARALLEL as i64,
                            decided_at: now_str.clone(),
                        };
                        state.adaptive.effective_max_parallel = Some(new_val);
                        state.adaptive.record_decision(decision);
                        tracing::info!(
                            "adaptive scheduling: 降低并发上限 {} → {}，原因: {}",
                            current, new_val, rec.reason
                        );
                    }
                }
                SchedulingRecommendationKind::IncreaseConcurrency => {
                    let suggested = rec.suggested_value.unwrap_or(4) as u32;
                    let current = state.adaptive.effective_max_parallel.unwrap_or(state.max_parallel_workspaces);
                    let new_val = suggested.clamp(ADAPTIVE_MIN_PARALLEL, ADAPTIVE_MAX_PARALLEL);
                    if new_val > current {
                        let decision = AdaptiveDecision {
                            kind: AdaptiveDecisionKind::ConcurrencyAdjusted,
                            reason: rec.reason.clone(),
                            previous_value: current as i64,
                            new_value: new_val as i64,
                            safe_lower_bound: ADAPTIVE_MIN_PARALLEL as i64,
                            safe_upper_bound: ADAPTIVE_MAX_PARALLEL as i64,
                            decided_at: now_str.clone(),
                        };
                        state.adaptive.effective_max_parallel = Some(new_val);
                        state.adaptive.record_decision(decision);
                        tracing::info!(
                            "adaptive scheduling: 提高并发上限 {} → {}，原因: {}",
                            current, new_val, rec.reason
                        );
                    }
                }
                SchedulingRecommendationKind::EnableDegradation => {
                    if let (Some(project), Some(workspace)) = (&rec.context.project, &rec.context.workspace) {
                        let key = format!("{}:{}", project, workspace);
                        if state.adaptive.degraded_workspaces.len() < ADAPTIVE_MAX_DEGRADED_WORKSPACES
                            && !state.adaptive.degraded_workspaces.contains(&key)
                        {
                            state.adaptive.degraded_workspaces.insert(key.clone());
                            let decision = AdaptiveDecision {
                                kind: AdaptiveDecisionKind::WorkspaceDegraded,
                                reason: rec.reason.clone(),
                                previous_value: 0,
                                new_value: 1,
                                safe_lower_bound: 0,
                                safe_upper_bound: ADAPTIVE_MAX_DEGRADED_WORKSPACES as i64,
                                decided_at: now_str.clone(),
                            };
                            state.adaptive.record_decision(decision);
                            tracing::info!(
                                "adaptive scheduling: 降级工作区 {}，原因: {}",
                                key, rec.reason
                            );
                        }
                    }
                }
                SchedulingRecommendationKind::DeferQueuing => {
                    if let (Some(project), Some(workspace)) = (&rec.context.project, &rec.context.workspace) {
                        let key = format!("{}:{}", project, workspace);
                        let defer_secs = ADAPTIVE_MAX_DEFER_SECS.min(60);
                        let resume_at = (chrono::Utc::now() + chrono::Duration::seconds(defer_secs as i64)).to_rfc3339();
                        state.adaptive.deferred_workspaces.insert(key.clone(), resume_at);
                        let decision = AdaptiveDecision {
                            kind: AdaptiveDecisionKind::QueueDeferred,
                            reason: rec.reason.clone(),
                            previous_value: 0,
                            new_value: defer_secs as i64,
                            safe_lower_bound: 0,
                            safe_upper_bound: ADAPTIVE_MAX_DEFER_SECS as i64,
                            decided_at: now_str.clone(),
                        };
                        state.adaptive.record_decision(decision);
                        tracing::info!(
                            "adaptive scheduling: 延迟排队 {} {}秒，原因: {}",
                            key, defer_secs, rec.reason
                        );
                    }
                }
                SchedulingRecommendationKind::AdjustPriority => {
                    // 优先级调整由外部配置控制，此处仅记录建议
                    tracing::debug!("adaptive scheduling: 收到优先级调整建议: {}", rec.reason);
                }
            }
        }

        // 清理已过期的延迟排队项
        let now = chrono::Utc::now();
        state.adaptive.deferred_workspaces.retain(|_, resume_at| {
            chrono::DateTime::parse_from_rfc3339(resume_at)
                .map(|t| t.with_timezone(&chrono::Utc) > now)
                .unwrap_or(false)
        });

        // 清理健康恢复的降级工作区
        for agg in aggregates {
            if agg.health_score >= 0.8 && agg.consecutive_failures == 0 {
                let key = format!("{}:{}", agg.project, agg.workspace);
                if state.adaptive.degraded_workspaces.remove(&key) {
                    tracing::info!(
                        "adaptive scheduling: 工作区 {} 健康恢复，解除降级",
                        key
                    );
                }
            }
        }
    }

    pub(super) async fn build_snapshot(&self, _ctx: &HandlerContext) -> SnapshotResult {
        let state = self.state.lock().await;
        let running_count = state
            .workspaces
            .values()
            .filter(|w| w.status == "running")
            .count() as u32;
        let queued_count = state
            .workspaces
            .values()
            .filter(|w| w.status == "queued")
            .count() as u32;

        let mut workspace_items: Vec<EvolutionWorkspaceItem> = Vec::new();

        for w in state.workspaces.values() {
            let agents = build_agents(
                &w.stage_statuses,
                &w.stage_tool_call_counts,
                &w.stage_started_ats,
                &w.stage_duration_ms,
            );

            // 统一运行状态面板：计算总耗时和重试资格
            let is_terminal = matches!(
                w.status.as_str(),
                "completed" | "failed_exhausted" | "failed_system" | "stopped"
            );
            let started_at = Some(w.created_at.clone());
            let duration_ms = if is_terminal {
                compute_evo_duration_ms(&w.created_at)
            } else {
                None
            };
            // failed_exhausted 可安全重试，failed_system 不可重试
            let retryable = w.status == "failed_exhausted";
            let error_code = if is_terminal && w.status != "completed" {
                w.terminal_reason_code.clone().or_else(|| Some(w.status.clone()))
            } else {
                None
            };

            // 记录终态循环到观测历史（按 (project, workspace) 隔离）
            if is_terminal {
                let now_ms = chrono::Utc::now().timestamp_millis() as u64;
                crate::server::perf::record_workspace_cycle(
                    crate::server::perf::WorkspaceCycleRecord {
                        project: w.project.clone(),
                        workspace: w.workspace.clone(),
                        cycle_id: w.cycle_id.clone(),
                        success: w.status == "completed",
                        duration_ms,
                        rate_limit_hit: w.rate_limit_error_message.is_some(),
                        timestamp: now_ms,
                    },
                );
            }

            workspace_items.push(EvolutionWorkspaceItem {
                project: w.project.clone(),
                workspace: w.workspace.clone(),
                cycle_id: w.cycle_id.clone(),
                title: w.cycle_title.clone(),
                status: w.status.clone(),
                current_stage: w.current_stage.clone(),
                global_loop_round: w.global_loop_round,
                loop_round_limit: w.loop_round_limit,
                verify_iteration: w.verify_iteration,
                verify_iteration_limit: w.verify_iteration_limit,
                agents,
                executions: w.session_executions.clone(),
                terminal_reason_code: w.terminal_reason_code.clone(),
                terminal_error_message: w.terminal_error_message.clone(),
                rate_limit_error_message: w.rate_limit_error_message.clone(),
                started_at,
                duration_ms,
                error_code,
                retryable,
            });
        }

        workspace_items.sort_by(|a, b| {
            (a.project.clone(), a.workspace.clone()).cmp(&(b.project.clone(), b.workspace.clone()))
        });

        // 获取观测聚合以填充调度器压力信息
        let aggregates = crate::server::perf::build_observation_aggregates(
            &std::collections::HashMap::new(),
        );
        let recommendations = crate::server::perf::build_scheduling_recommendations(
            &aggregates,
            state.max_parallel_workspaces,
            running_count,
        );
        let global_pressure = if recommendations
            .iter()
            .any(|r| r.kind == crate::server::protocol::health::SchedulingRecommendationKind::ReduceConcurrency)
        {
            Some("high".to_string())
        } else if recommendations.is_empty() {
            Some("low".to_string())
        } else {
            Some("moderate".to_string())
        };

        // 使用自适应调度的有效并发上限
        let effective_max_parallel = state.adaptive.effective_max_parallel.unwrap_or(state.max_parallel_workspaces);

        SnapshotResult {
            scheduler: crate::server::protocol::EvolutionSchedulerInfo {
                activation_state: state.activation_state.clone(),
                max_parallel_workspaces: effective_max_parallel,
                running_count,
                queued_count,
                pressure_level: global_pressure,
                recommendation_count: recommendations.len() as u32,
            },
            workspace_items,
        }
    }

    /// 从工作空间文件夹扫描历史循环记录
    pub(super) async fn list_cycle_history(
        &self,
        project: &str,
        workspace: &str,
        ctx: &HandlerContext,
    ) -> Result<Vec<EvolutionCycleHistoryItem>, String> {
        let workspace_root = resolve_directory(&ctx.app_state, project, workspace).await?;
        let evo_dir = evolution_workspace_dir(&workspace_root)?;

        if !evo_dir.exists() {
            return Ok(vec![]);
        }

        // 当前运行中的 cycle_id，用于排除
        let current_cycle_id = {
            let state = self.state.lock().await;
            let key = workspace_key(project, workspace);
            state
                .workspaces
                .get(&key)
                .map(|w| w.cycle_id.clone())
                .unwrap_or_default()
        };

        let mut cycles: Vec<EvolutionCycleHistoryItem> = Vec::new();

        let entries = std::fs::read_dir(&evo_dir).map_err(|e| e.to_string())?;
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let cycle_id = match path.file_name().and_then(|n| n.to_str()) {
                Some(name) => name.to_string(),
                None => continue,
            };

            // 跳过当前运行中的循环
            if !current_cycle_id.is_empty() && cycle_id == current_cycle_id {
                continue;
            }

            let cycle_file = path.join("cycle.jsonc");
            if !cycle_file.exists() {
                continue;
            }
            let json = match read_json(&cycle_file) {
                Ok(v) => v,
                Err(_) => continue,
            };

            let Some(mut item) = build_cycle_history_item(cycle_id.clone(), &json) else {
                continue;
            };

            item.executions.sort_by(|lhs, rhs| {
                let lhs_has_started = !lhs.started_at.is_empty();
                let rhs_has_started = !rhs.started_at.is_empty();
                match (lhs_has_started, rhs_has_started) {
                    (true, true) => lhs
                        .started_at
                        .cmp(&rhs.started_at)
                        .then_with(|| lhs.stage.cmp(&rhs.stage))
                        .then_with(|| lhs.session_id.cmp(&rhs.session_id)),
                    (true, false) => std::cmp::Ordering::Less,
                    (false, true) => std::cmp::Ordering::Greater,
                    (false, false) => lhs
                        .stage
                        .cmp(&rhs.stage)
                        .then_with(|| lhs.session_id.cmp(&rhs.session_id)),
                }
            });

            cycles.push(item);
        }

        // 按 updated_at 降序排列
        cycles.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));

        // 限制返回最近 20 条
        cycles.truncate(20);

        Ok(cycles)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        build_cycle_history_item, extract_cycle_title_from_cycle_file,
        extract_cycle_title_from_direction_stage, initial_global_loop_round,
        parse_cycle_session_executions, parse_cycle_stage_history_entries,
        parse_stage_session_executions, resolve_cycle_history_title,
    };

    #[test]
    fn start_round_should_reset_to_one() {
        assert_eq!(initial_global_loop_round(), 1);
    }

    #[test]
    fn parse_stage_session_executions_should_prefer_metadata() {
        let stage_json = serde_json::json!({
            "status": "done",
            "agent": "VerifyAgent",
            "ai_tool": "codex",
            "timing": {
                "started_at": "2026-03-01T00:00:00Z",
                "completed_at": "2026-03-01T00:00:05Z",
                "duration_ms": 5000
            },
            "system_metadata": {
                "session_executions": [
                    {
                        "stage": "verify",
                        "agent": "VerifyAgent",
                        "ai_tool": "codex",
                        "session_id": "sess-1",
                        "status": "done",
                        "started_at": "2026-03-01T00:00:00Z",
                        "completed_at": "2026-03-01T00:00:05Z",
                        "duration_ms": 5000,
                        "tool_call_count": 3
                    },
                    {
                        "stage": "verify",
                        "agent": "VerifyAgent",
                        "ai_tool": "codex",
                        "session_id": "sess-running",
                        "status": "running",
                        "started_at": "2026-03-01T00:01:00Z"
                    }
                ]
            }
        });

        let executions = parse_stage_session_executions("verify", &stage_json);
        assert_eq!(executions.len(), 1);
        assert_eq!(executions[0].session_id, "sess-1");
        assert_eq!(executions[0].duration_ms, Some(5000));
        assert_eq!(executions[0].tool_call_count, 3);
    }

    #[test]
    fn parse_stage_session_executions_should_fallback_to_outputs() {
        let stage_json = serde_json::json!({
            "status": "done",
            "agent": "VerifyAgent",
            "ai_tool": "codex",
            "timing": {
                "started_at": "2026-03-01T00:00:00Z",
                "completed_at": "2026-03-01T00:00:08Z",
                "duration_ms": 8000
            },
            "outputs": [
                {
                    "type": "chat_session",
                    "session_id": "sess-last",
                    "session_ids": ["sess-old", "sess-last"]
                }
            ]
        });

        let executions = parse_stage_session_executions("verify", &stage_json);
        assert_eq!(executions.len(), 2);
        assert_eq!(executions[0].stage, "verify");
        assert_eq!(executions[0].duration_ms, Some(8000));
    }

    #[test]
    fn extract_cycle_title_from_direction_stage_should_read_title() {
        let stage_json = serde_json::json!({
            "title": "  新标题  "
        });
        let title = extract_cycle_title_from_direction_stage(&stage_json);
        assert_eq!(title.as_deref(), Some("新标题"));
    }

    #[test]
    fn extract_cycle_title_from_direction_stage_should_fallback_to_direction_statement() {
        let stage_json = serde_json::json!({
            "direction_statement": "  方向标题  "
        });
        let title = extract_cycle_title_from_direction_stage(&stage_json);
        assert_eq!(title.as_deref(), Some("方向标题"));
    }

    #[test]
    fn extract_cycle_title_from_direction_stage_should_not_fallback_to_legacy_fields() {
        let stage_json = serde_json::json!({
            "decision": {
                "context": {
                    "selected_title": "  方向标题  "
                }
            }
        });
        let title = extract_cycle_title_from_direction_stage(&stage_json);
        assert_eq!(title, None);
    }

    #[test]
    fn extract_cycle_title_from_cycle_file_should_only_read_title() {
        let cycle_json = serde_json::json!({
            "title": "  当前标题  "
        });
        let title = extract_cycle_title_from_cycle_file(&cycle_json);
        assert_eq!(title.as_deref(), Some("当前标题"));
    }

    #[test]
    fn resolve_cycle_history_title_should_prefer_direction_stage_title() {
        let title = resolve_cycle_history_title(
            Some("方向标题".to_string()),
            Some("cycle 文件标题".to_string()),
        );
        assert_eq!(title.as_deref(), Some("方向标题"));
    }

    #[test]
    fn resolve_cycle_history_title_should_fallback_to_cycle_file_title() {
        let title = resolve_cycle_history_title(None, Some("cycle 文件标题".to_string()));
        assert_eq!(title.as_deref(), Some("cycle 文件标题"));
    }

    #[test]
    fn parse_cycle_session_executions_should_ignore_non_terminal_entries() {
        let cycle_json = serde_json::json!({
            "executions": [
                {
                    "stage": "verify",
                    "agent": "VerifyAgent",
                    "ai_tool": "codex",
                    "session_id": "sess-done",
                    "status": "done",
                    "started_at": "2026-03-01T00:00:00Z",
                    "completed_at": "2026-03-01T00:00:05Z",
                    "duration_ms": 5000,
                    "tool_call_count": 2
                },
                {
                    "stage": "plan",
                    "session_id": "sess-running",
                    "status": "running"
                }
            ]
        });

        let executions = parse_cycle_session_executions(&cycle_json);
        assert_eq!(executions.len(), 1);
        assert_eq!(executions[0].session_id, "sess-done");
    }

    #[test]
    fn parse_cycle_stage_history_entries_should_use_stage_runtime() {
        let cycle_json = serde_json::json!({
            "stage_runtime": {
                "direction": {
                    "status": "done",
                    "ai_tool": "codex",
                    "timing": {
                        "duration_ms": 1200
                    }
                },
                "plan": {
                    "status": "running",
                    "ai_tool": "codex",
                    "timing": {
                        "duration_ms": 800
                    }
                },
                "verify": {
                    "status": "failed",
                    "ai_tool": "codex",
                    "timing": {
                        "duration_ms": 2400
                    }
                }
            }
        });

        let stages = parse_cycle_stage_history_entries(&cycle_json);
        assert_eq!(stages.len(), 2);
        assert_eq!(stages[0].stage, "direction");
        assert_eq!(stages[0].agent, "DirectionAgent");
        assert_eq!(stages[1].stage, "verify");
        assert_eq!(stages[1].status, "failed");
    }

    // --- 以下为 WI-005 补齐的运行状态聚合回归护栏 ---

    #[test]
    fn is_cycle_retryable_should_allow_exhausted_statuses() {
        use super::is_cycle_retryable;
        // failed_exhausted 本身可重试
        assert!(is_cycle_retryable("failed_exhausted", None));
        assert!(is_cycle_retryable("failed_exhausted", Some("some_code")));
        // terminal_reason_code 为 verify_exhausted 或 loop_exhausted 可重试
        assert!(is_cycle_retryable("failed", Some("verify_exhausted")));
        assert!(is_cycle_retryable("failed", Some("loop_exhausted")));
        // 其它状态不可重试
        assert!(!is_cycle_retryable("failed", None));
        assert!(!is_cycle_retryable("failed_system", None));
        assert!(!is_cycle_retryable("completed", None));
        assert!(!is_cycle_retryable("running", None));
        assert!(!is_cycle_retryable("failed", Some("unknown_code")));
    }

    #[test]
    fn compute_evo_duration_between_should_return_positive_or_none() {
        use super::compute_evo_duration_between;
        // 正常正向耗时
        let ms = compute_evo_duration_between("2026-03-01T00:00:00Z", "2026-03-01T00:01:00Z");
        assert_eq!(ms, Some(60_000));
        // 同一时间 → 0ms
        let zero = compute_evo_duration_between("2026-03-01T00:00:00Z", "2026-03-01T00:00:00Z");
        assert_eq!(zero, Some(0));
        // 反向时间 → None
        let neg = compute_evo_duration_between("2026-03-01T00:01:00Z", "2026-03-01T00:00:00Z");
        assert_eq!(neg, None);
        // 无效 RFC3339 → None
        let bad = compute_evo_duration_between("not-a-date", "2026-03-01T00:00:00Z");
        assert_eq!(bad, None);
    }

    #[test]
    fn is_terminal_execution_status_should_match_known_statuses() {
        use super::is_terminal_execution_status;
        for status in &[
            "done",
            "failed",
            "blocked",
            "skipped",
            "stopped",
            "interrupted",
            "completed",
        ] {
            assert!(
                is_terminal_execution_status(status),
                "{} should be terminal",
                status
            );
        }
        for status in &["running", "pending", "queued", ""] {
            assert!(
                !is_terminal_execution_status(status),
                "{} should NOT be terminal",
                status
            );
        }
    }

    #[test]
    fn build_cycle_history_item_should_restore_runtime_title_and_error() {
        let cycle_json = serde_json::json!({
            "title": "结构化历史标题",
            "status": "failed_system",
            "global_loop_round": 2,
            "created_at": "2026-03-01T00:00:00Z",
            "updated_at": "2026-03-01T00:10:00Z",
            "stage_runtime": {
                "verify.1": {
                    "status": "failed",
                    "ai_tool": "codex",
                    "timing": {
                        "duration_ms": 3210
                    },
                    "error": {
                        "message": "verify.1.jsonc 缺少 adjudication.overall_result"
                    }
                }
            },
            "executions": [
                {
                    "stage": "verify.1",
                    "agent": "VerifyAgent",
                    "ai_tool": "codex",
                    "session_id": "sess-1",
                    "status": "failed",
                    "started_at": "2026-03-01T00:00:00Z",
                    "completed_at": "2026-03-01T00:00:04Z",
                    "duration_ms": 4000
                }
            ]
        });

        let item =
            build_cycle_history_item("cycle-1".to_string(), &cycle_json).expect("history item");
        assert_eq!(item.title.as_deref(), Some("结构化历史标题"));
        assert_eq!(
            item.terminal_error_message.as_deref(),
            Some("verify.1.jsonc 缺少 adjudication.overall_result")
        );
        assert_eq!(item.executions.len(), 1);
        assert_eq!(item.stages.len(), 1);
    }

    #[tokio::test]
    async fn adaptive_scheduling_applies_reduce_concurrency() {
        use crate::server::protocol::health::*;
        use super::super::EvolutionManager;

        let manager = EvolutionManager::new();
        let recommendations = vec![SchedulingRecommendation {
            recommendation_id: "test-reduce".to_string(),
            kind: SchedulingRecommendationKind::ReduceConcurrency,
            pressure_level: ResourcePressureLevel::High,
            reason: "test_high_pressure".to_string(),
            summary: None,
            suggested_value: Some(2),
            context: HealthContext::system(),
            generated_at: 1000,
            expires_at: 2000,
        }];
        manager.apply_scheduling_recommendations(&recommendations, &[]).await;
        let state = manager.state.lock().await;
        assert_eq!(state.adaptive.effective_max_parallel, Some(2));
        assert_eq!(state.adaptive.recent_decisions.len(), 1);
    }

    #[tokio::test]
    async fn adaptive_scheduling_respects_safety_bounds() {
        use crate::server::protocol::health::*;
        use super::super::EvolutionManager;

        let manager = EvolutionManager::new();
        // 尝试设置超出安全边界的值
        let recommendations = vec![SchedulingRecommendation {
            recommendation_id: "test-extreme".to_string(),
            kind: SchedulingRecommendationKind::ReduceConcurrency,
            pressure_level: ResourcePressureLevel::Critical,
            reason: "test_extreme_pressure".to_string(),
            summary: None,
            suggested_value: Some(0), // 低于 ADAPTIVE_MIN_PARALLEL
            context: HealthContext::system(),
            generated_at: 1000,
            expires_at: 2000,
        }];
        manager.apply_scheduling_recommendations(&recommendations, &[]).await;
        let state = manager.state.lock().await;
        // 应被 clamp 到最小值 1
        assert_eq!(state.adaptive.effective_max_parallel, Some(1));
    }

    #[tokio::test]
    async fn adaptive_scheduling_degraded_workspace_limit() {
        use crate::server::protocol::health::*;
        use super::super::EvolutionManager;

        let manager = EvolutionManager::new();
        let mut recommendations = Vec::new();
        // 尝试降级超过限制数量的工作区
        for i in 0..5 {
            recommendations.push(SchedulingRecommendation {
                recommendation_id: format!("test-degrade-{}", i),
                kind: SchedulingRecommendationKind::EnableDegradation,
                pressure_level: ResourcePressureLevel::High,
                reason: "test_failures".to_string(),
                summary: None,
                suggested_value: None,
                context: HealthContext::for_workspace(format!("proj{}", i), format!("ws{}", i)),
                generated_at: 1000,
                expires_at: 2000,
            });
        }
        manager.apply_scheduling_recommendations(&recommendations, &[]).await;
        let state = manager.state.lock().await;
        // 应不超过 ADAPTIVE_MAX_DEGRADED_WORKSPACES (3)
        assert!(state.adaptive.degraded_workspaces.len() <= 3);
    }
}
