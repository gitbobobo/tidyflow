use std::collections::{HashMap, HashSet};

use chrono::Utc;
use tracing::warn;
use uuid::Uuid;

use crate::server::context::HandlerContext;
use crate::server::handlers::ai::resolve_directory;
use crate::server::protocol::{
    EvolutionCycleHistoryItem, EvolutionCycleStageHistoryEntry, EvolutionSessionExecutionEntry,
    EvolutionWorkspaceItem, ServerMessage,
};

use super::stage::{active_agents, build_agents};
use super::utils::{evolution_workspace_dir, read_json, workspace_key};
use super::{
    EvolutionManager, SnapshotResult, StartWorkspaceReq, WorkspaceRunState,
    BACKLOG_CONTRACT_VERSION_V2, DEFAULT_VERIFY_LIMIT, STAGES,
};

fn initial_global_loop_round() -> u32 {
    1
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

fn extract_cycle_title_from_direction_stage(stage_json: &serde_json::Value) -> Option<String> {
    non_empty_string(stage_json.get("cycle_title"))
        .or_else(|| non_empty_string(stage_json.pointer("/decision/context/selected_title")))
}

fn extract_cycle_title_from_cycle_file(cycle_json: &serde_json::Value) -> Option<String> {
    non_empty_string(cycle_json.get("title"))
        .or_else(|| non_empty_string(cycle_json.get("cycle_title")))
}

fn resolve_cycle_history_title(
    direction_stage_title: Option<String>,
    cycle_file_title: Option<String>,
) -> Option<String> {
    direction_stage_title.or(cycle_file_title)
}

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
                    llm_defined_acceptance_criteria: Vec::new(),
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

    pub(super) async fn open_stage_chat(
        &self,
        project: &str,
        workspace: &str,
        cycle_id: &str,
        stage: &str,
    ) -> Option<(String, String)> {
        let key = workspace_key(project, workspace);
        let state = self.state.lock().await;
        let entry = state.workspaces.get(&key)?;
        if entry.cycle_id != cycle_id {
            return None;
        }
        let session = entry.stage_sessions.get(stage)?.clone();
        Some((session.ai_tool, session.session_id))
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
                active_agents: active_agents(&w.stage_statuses),
                terminal_reason_code: w.terminal_reason_code.clone(),
                terminal_error_message: w.terminal_error_message.clone(),
                rate_limit_error_message: w.rate_limit_error_message.clone(),
            });
        }

        workspace_items.sort_by(|a, b| {
            (a.project.clone(), a.workspace.clone()).cmp(&(b.project.clone(), b.workspace.clone()))
        });

        SnapshotResult {
            scheduler: crate::server::protocol::EvolutionSchedulerInfo {
                activation_state: state.activation_state.clone(),
                max_parallel_workspaces: state.max_parallel_workspaces,
                running_count,
                queued_count,
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

            let status = json["status"].as_str().unwrap_or("unknown").to_string();
            let global_loop_round = json["global_loop_round"].as_u64().unwrap_or(0) as u32;
            let created_at = json["created_at"].as_str().unwrap_or("").to_string();
            let updated_at = json["updated_at"].as_str().unwrap_or("").to_string();
            let cycle_file_title = extract_cycle_title_from_cycle_file(&json);
            let mut direction_stage_title: Option<String> = None;
            let terminal_reason_code = json["terminal_reason_code"]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string());
            let mut fallback_terminal_error_message: Option<String> = None;
            let terminal_error_message = json["terminal_error_message"]
                .as_str()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty());

            // 读取各阶段文件
            let mut stages: Vec<EvolutionCycleStageHistoryEntry> = Vec::new();
            let mut executions: Vec<EvolutionSessionExecutionEntry> = Vec::new();
            for stage_name in STAGES.iter() {
                let stage_file = path.join(format!("stage.{}.jsonc", stage_name));
                if !stage_file.exists() {
                    continue;
                }
                let stage_json = match read_json(&stage_file) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                if *stage_name == "direction" && direction_stage_title.is_none() {
                    direction_stage_title = extract_cycle_title_from_direction_stage(&stage_json);
                }

                executions.extend(parse_stage_session_executions(stage_name, &stage_json));

                let stage_status = stage_json["status"]
                    .as_str()
                    .unwrap_or("unknown")
                    .to_string();
                if fallback_terminal_error_message.is_none() {
                    fallback_terminal_error_message = stage_json
                        .get("error")
                        .and_then(|v| v.get("message"))
                        .and_then(|v| v.as_str())
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty());
                }
                // 只包含已完成的阶段
                if stage_status != "done" {
                    continue;
                }

                let agent = stage_json["agent"].as_str().unwrap_or("").to_string();
                let ai_tool = stage_json["ai_tool"].as_str().unwrap_or("").to_string();
                let duration_ms = stage_json["timing"]["duration_ms"].as_u64();

                stages.push(EvolutionCycleStageHistoryEntry {
                    stage: stage_name.to_string(),
                    agent,
                    ai_tool,
                    status: stage_status,
                    duration_ms,
                });
            }

            executions.sort_by(|lhs, rhs| {
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

            // 只包含有已完成阶段或已结束会话的循环
            if stages.is_empty() && executions.is_empty() {
                continue;
            }
            let cycle_title = resolve_cycle_history_title(direction_stage_title, cycle_file_title);

            cycles.push(EvolutionCycleHistoryItem {
                cycle_id,
                title: cycle_title,
                status,
                global_loop_round,
                created_at,
                updated_at,
                terminal_reason_code,
                terminal_error_message: terminal_error_message.or(fallback_terminal_error_message),
                executions,
                stages,
            });
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
        extract_cycle_title_from_cycle_file, extract_cycle_title_from_direction_stage,
        initial_global_loop_round, parse_stage_session_executions, resolve_cycle_history_title,
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
    fn extract_cycle_title_from_direction_stage_should_prefer_cycle_title() {
        let stage_json = serde_json::json!({
            "cycle_title": "  新标题  ",
            "decision": {
                "context": {
                    "selected_title": "旧标题"
                }
            }
        });
        let title = extract_cycle_title_from_direction_stage(&stage_json);
        assert_eq!(title.as_deref(), Some("新标题"));
    }

    #[test]
    fn extract_cycle_title_from_direction_stage_should_fallback_to_selected_title() {
        let stage_json = serde_json::json!({
            "decision": {
                "context": {
                    "selected_title": "  方向标题  "
                }
            }
        });
        let title = extract_cycle_title_from_direction_stage(&stage_json);
        assert_eq!(title.as_deref(), Some("方向标题"));
    }

    #[test]
    fn extract_cycle_title_from_cycle_file_should_support_legacy_cycle_title_key() {
        let cycle_json = serde_json::json!({
            "cycle_title": "  兼容标题  "
        });
        let title = extract_cycle_title_from_cycle_file(&cycle_json);
        assert_eq!(title.as_deref(), Some("兼容标题"));
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
}
