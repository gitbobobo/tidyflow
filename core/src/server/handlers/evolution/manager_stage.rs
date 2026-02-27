use chrono::Utc;
use futures::StreamExt;
use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;
use tokio::time::{sleep, timeout, Duration};
use tracing::warn;
use uuid::Uuid;

use crate::ai::{AiAgent, AiModelSelection, AiQuestionRequest};
use crate::server::context::HandlerContext;
use crate::server::handlers::ai::{
    ensure_agent, infer_selection_hint_from_messages, merge_session_selection_hint,
    normalize_part_for_wire, resolve_directory,
};
use crate::server::handlers::git::branch_commit::spawn_git_ai_commit_task;
use crate::server::protocol::ServerMessage;

use super::profile::profile_for_stage;
use super::utils::cycle_dir_path;
use super::{EvolutionManager, MAX_STAGE_RUNTIME_SECS, STAGES};

const AUTO_COMMIT_MAX_ATTEMPTS: u32 = 2;
const AUTO_COMMIT_RETRY_DELAY_SECS: u64 = 2;
const VALIDATION_REMINDER_MAX_RETRIES: u32 = 2;

fn parse_judge_result_text(value: &str) -> Option<bool> {
    let normalized = value.trim().to_ascii_lowercase();
    if normalized == "pass" {
        return Some(true);
    }
    if normalized == "fail" {
        return Some(false);
    }
    None
}

fn parse_judge_result_from_json(value: &serde_json::Value) -> Option<bool> {
    let overall = value
        .pointer("/overall_result/result")
        .and_then(|v| v.as_str())
        .and_then(parse_judge_result_text);
    if overall.is_some() {
        return overall;
    }

    value
        .pointer("/decision/result")
        .and_then(|v| v.as_str())
        .and_then(parse_judge_result_text)
}

fn should_auto_commit_after_report(status: &str) -> bool {
    status == "completed"
}

fn should_start_next_round(status: &str, global_loop_round: u32, loop_round_limit: u32) -> bool {
    should_auto_commit_after_report(status) && global_loop_round < loop_round_limit
}

fn read_json_file(cycle_dir: &Path, file_name: &str) -> Result<serde_json::Value, String> {
    let path = cycle_dir.join(file_name);
    let content =
        std::fs::read_to_string(&path).map_err(|e| format!("读取 {} 失败: {}", file_name, e))?;
    serde_json::from_str::<serde_json::Value>(&content)
        .map_err(|e| format!("解析 {} 失败: {}", file_name, e))
}

fn id_from_value(item: &serde_json::Value, keys: &[&str]) -> Option<String> {
    if let Some(value) = item.as_str() {
        let normalized = value.trim();
        if !normalized.is_empty() {
            return Some(normalized.to_string());
        }
    }
    let obj = item.as_object()?;
    for key in keys {
        if let Some(value) = obj.get(*key).and_then(|v| v.as_str()) {
            let normalized = value.trim();
            if !normalized.is_empty() {
                return Some(normalized.to_string());
            }
        }
    }
    None
}

fn collect_unique_ids(
    items: &[serde_json::Value],
    keys: &[&str],
    label: &str,
) -> Result<Vec<String>, String> {
    let mut ids = Vec::new();
    let mut seen = HashSet::new();
    for (idx, item) in items.iter().enumerate() {
        let id =
            id_from_value(item, keys).ok_or_else(|| format!("{}[{}] 缺少有效 id", label, idx))?;
        if !seen.insert(id.clone()) {
            return Err(format!("{} 存在重复 id: {}", label, id));
        }
        ids.push(id);
    }
    Ok(ids)
}

fn as_failing_status(status: &str) -> bool {
    matches!(
        status.trim().to_ascii_lowercase().as_str(),
        "fail" | "failed" | "insufficient_evidence" | "missing" | "not_covered" | "not_done"
    )
}

impl EvolutionManager {
    fn validate_implement_artifact(cycle_dir: &Path, verify_iteration: u32) -> Result<(), String> {
        if verify_iteration == 0 {
            return Ok(());
        }
        let value = read_json_file(cycle_dir, "implement.result.json")?;
        let backlog = value
            .pointer("/failure_backlog")
            .and_then(|v| v.as_array())
            .ok_or_else(|| {
                "implement.result.json 缺少 failure_backlog（重实现轮必须提供）".to_string()
            })?;
        let coverage = value
            .pointer("/backlog_coverage")
            .and_then(|v| v.as_array())
            .ok_or_else(|| {
                "implement.result.json 缺少 backlog_coverage（重实现轮必须提供）".to_string()
            })?;
        let summary = value
            .pointer("/backlog_coverage_summary")
            .and_then(|v| v.as_object())
            .ok_or_else(|| {
                "implement.result.json 缺少 backlog_coverage_summary（重实现轮必须提供）"
                    .to_string()
            })?;
        for key in ["total", "done", "blocked", "not_done"] {
            if !summary
                .get(key)
                .and_then(|v| v.as_u64())
                .map(|_| true)
                .unwrap_or(false)
            {
                return Err(format!(
                    "implement.result.json.backlog_coverage_summary.{} 必须是数字",
                    key
                ));
            }
        }
        let backlog_ids = collect_unique_ids(backlog, &["id"], "failure_backlog")?;
        let coverage_ids = collect_unique_ids(coverage, &["id", "item_id"], "backlog_coverage")?;
        if backlog_ids.len() != coverage_ids.len() {
            return Err(format!(
                "failure_backlog 与 backlog_coverage 数量不一致: {} vs {}",
                backlog_ids.len(),
                coverage_ids.len()
            ));
        }
        let backlog_set: HashSet<String> = backlog_ids.into_iter().collect();
        let coverage_set: HashSet<String> = coverage_ids.into_iter().collect();
        if backlog_set != coverage_set {
            return Err("backlog_coverage 未完整覆盖 failure_backlog".to_string());
        }
        Ok(())
    }

    fn validate_verify_artifact(cycle_dir: &Path, verify_iteration: u32) -> Result<(), String> {
        if verify_iteration == 0 {
            return Ok(());
        }
        let verify_value = read_json_file(cycle_dir, "verify.result.json")?;
        let implement_value = read_json_file(cycle_dir, "implement.result.json")?;

        let backlog = implement_value
            .pointer("/failure_backlog")
            .and_then(|v| v.as_array())
            .ok_or_else(|| "implement.result.json 缺少 failure_backlog".to_string())?;
        let backlog_ids = collect_unique_ids(backlog, &["id"], "failure_backlog")?;
        let backlog_set: HashSet<String> = backlog_ids.iter().cloned().collect();

        let carry_items = verify_value
            .pointer("/carryover_verification/items")
            .and_then(|v| v.as_array())
            .ok_or_else(|| {
                "verify.result.json 缺少 carryover_verification.items（重实现轮必须提供）"
                    .to_string()
            })?;
        let carry_summary = verify_value
            .pointer("/carryover_verification/summary")
            .and_then(|v| v.as_object())
            .ok_or_else(|| {
                "verify.result.json 缺少 carryover_verification.summary（重实现轮必须提供）"
                    .to_string()
            })?;
        for key in ["total", "covered", "missing", "blocked"] {
            if !carry_summary
                .get(key)
                .and_then(|v| v.as_u64())
                .map(|_| true)
                .unwrap_or(false)
            {
                return Err(format!(
                    "verify.result.json.carryover_verification.summary.{} 必须是数字",
                    key
                ));
            }
        }
        let total = carry_summary
            .get("total")
            .and_then(|v| v.as_u64())
            .unwrap_or_default() as usize;
        if total != backlog_ids.len() {
            return Err(format!(
                "carryover_verification.summary.total 与 failure_backlog 数量不一致: {} vs {}",
                total,
                backlog_ids.len()
            ));
        }
        let carry_ids = collect_unique_ids(
            carry_items,
            &["id", "item_id"],
            "carryover_verification.items",
        )?;
        let carry_set: HashSet<String> = carry_ids.into_iter().collect();
        let missing_ids: Vec<String> = backlog_set
            .difference(&carry_set)
            .cloned()
            .collect::<Vec<String>>();
        if !missing_ids.is_empty() {
            return Err(format!(
                "carryover_verification.items 缺少 backlog 项: {:?}",
                missing_ids
            ));
        }
        Ok(())
    }

    fn validate_judge_artifact(cycle_dir: &Path, verify_iteration: u32) -> Result<(), String> {
        if verify_iteration == 0 {
            return Ok(());
        }
        let judge_value = read_json_file(cycle_dir, "judge.result.json")?;
        let verify_value = read_json_file(cycle_dir, "verify.result.json")?;

        let requirements = judge_value
            .pointer("/full_next_iteration_requirements")
            .and_then(|v| v.as_array())
            .ok_or_else(|| {
                "judge.result.json 缺少 full_next_iteration_requirements（重实现轮必须提供）"
                    .to_string()
            })?;
        let requirement_ids = collect_unique_ids(
            requirements,
            &["id", "item_id", "criteria_id", "title"],
            "full_next_iteration_requirements",
        )?;
        let requirement_set: HashSet<String> = requirement_ids.into_iter().collect();

        let acceptance = verify_value
            .pointer("/acceptance_evaluation")
            .and_then(|v| v.as_array())
            .ok_or_else(|| "verify.result.json 缺少 acceptance_evaluation".to_string())?;
        let mut expected = HashSet::new();
        for (idx, item) in acceptance.iter().enumerate() {
            let status = item
                .get("status")
                .and_then(|v| v.as_str())
                .ok_or_else(|| format!("acceptance_evaluation[{}] 缺少 status", idx))?;
            if as_failing_status(status) {
                let criteria_id = id_from_value(item, &["criteria_id"])
                    .ok_or_else(|| format!("acceptance_evaluation[{}] 缺少 criteria_id", idx))?;
                expected.insert(criteria_id);
            }
        }

        if let Some(items) = verify_value
            .pointer("/carryover_verification/items")
            .and_then(|v| v.as_array())
        {
            for (idx, item) in items.iter().enumerate() {
                let status = item
                    .get("status")
                    .and_then(|v| v.as_str())
                    .unwrap_or("missing");
                if as_failing_status(status) {
                    let item_id = id_from_value(item, &["id", "item_id"])
                        .ok_or_else(|| format!("carryover_verification.items[{}] 缺少 id", idx))?;
                    expected.insert(item_id);
                }
            }
        }

        let missing_expected: Vec<String> = expected
            .difference(&requirement_set)
            .cloned()
            .collect::<Vec<String>>();
        if !missing_expected.is_empty() {
            return Err(format!(
                "full_next_iteration_requirements 未覆盖 verify 未通过项: {:?}",
                missing_expected
            ));
        }
        Ok(())
    }

    fn validate_stage_artifacts(
        stage: &str,
        cycle_dir: &Path,
        verify_iteration: u32,
    ) -> Result<(), String> {
        match stage {
            "implement" => Self::validate_implement_artifact(cycle_dir, verify_iteration),
            "verify" => Self::validate_verify_artifact(cycle_dir, verify_iteration),
            "judge" => Self::validate_judge_artifact(cycle_dir, verify_iteration),
            _ => Ok(()),
        }
    }

    fn extract_acceptance_mapping_criteria(
        value: &serde_json::Value,
    ) -> Result<Vec<serde_json::Value>, String> {
        let mapping = value
            .pointer("/verification_plan/acceptance_mapping")
            .and_then(|v| v.as_array())
            .ok_or_else(|| {
                "plan.execution.json 缺少 verification_plan.acceptance_mapping".to_string()
            })?;

        let mut out = Vec::new();
        for item in mapping {
            let Some(obj) = item.as_object() else {
                return Err("acceptance_mapping 条目必须是对象".to_string());
            };
            let criteria_id = obj
                .get("criteria_id")
                .and_then(|v| v.as_str())
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty())
                .ok_or_else(|| "acceptance_mapping 条目缺少 criteria_id".to_string())?;
            let check_ids = obj
                .get("check_ids")
                .and_then(|v| v.as_array())
                .ok_or_else(|| format!("{} 缺少 check_ids", criteria_id))?;
            if check_ids.is_empty() {
                return Err(format!("{} 的 check_ids 不能为空", criteria_id));
            }
            out.push(serde_json::json!({
                "criteria_id": criteria_id,
                "description": obj.get("description").and_then(|v| v.as_str()).unwrap_or(""),
                "check_ids": check_ids,
            }));
        }
        Ok(out)
    }

    async fn sync_acceptance_criteria_from_plan(
        &self,
        key: &str,
        cycle_id: &str,
    ) -> Result<(), String> {
        let workspace_root = {
            let state = self.state.lock().await;
            let Some(entry) = state.workspaces.get(key) else {
                return Err("workspace state missing".to_string());
            };
            entry.workspace_root.clone()
        };
        let cycle_dir = cycle_dir_path(&workspace_root, cycle_id)?;
        let plan_path = cycle_dir.join("plan.execution.json");
        let content = std::fs::read_to_string(&plan_path)
            .map_err(|e| format!("读取 plan.execution.json 失败: {}", e))?;
        let parsed: serde_json::Value = serde_json::from_str(&content)
            .map_err(|e| format!("解析 plan.execution.json 失败: {}", e))?;
        let criteria = Self::extract_acceptance_mapping_criteria(&parsed)?;
        if criteria.is_empty() {
            return Err("acceptance_mapping 为空".to_string());
        }
        let mut state = self.state.lock().await;
        let Some(entry) = state.workspaces.get_mut(key) else {
            return Err("workspace state missing".to_string());
        };
        entry.llm_defined_acceptance_criteria = criteria;
        Ok(())
    }

    async fn ensure_acceptance_consistency(&self, key: &str, cycle_id: &str) -> Result<(), String> {
        let workspace_root = {
            let state = self.state.lock().await;
            let Some(entry) = state.workspaces.get(key) else {
                return Err("workspace state missing".to_string());
            };
            if entry.llm_defined_acceptance_criteria.is_empty() {
                return Err("cycle llm_defined_acceptance.criteria 为空".to_string());
            }
            entry.workspace_root.clone()
        };
        let cycle_dir = cycle_dir_path(&workspace_root, cycle_id)?;
        let plan_path = cycle_dir.join("plan.execution.json");
        let content = std::fs::read_to_string(&plan_path)
            .map_err(|e| format!("读取 plan.execution.json 失败: {}", e))?;
        let parsed: serde_json::Value = serde_json::from_str(&content)
            .map_err(|e| format!("解析 plan.execution.json 失败: {}", e))?;
        let criteria_from_plan = Self::extract_acceptance_mapping_criteria(&parsed)?;
        let expected_ids: std::collections::HashSet<String> = criteria_from_plan
            .iter()
            .filter_map(|v| {
                v.get("criteria_id")
                    .and_then(|x| x.as_str())
                    .map(|s| s.to_string())
            })
            .collect();
        let actual_ids: std::collections::HashSet<String> = {
            let state = self.state.lock().await;
            let Some(entry) = state.workspaces.get(key) else {
                return Err("workspace state missing".to_string());
            };
            entry
                .llm_defined_acceptance_criteria
                .iter()
                .filter_map(|v| {
                    v.get("criteria_id")
                        .and_then(|x| x.as_str())
                        .map(|s| s.to_string())
                })
                .collect()
        };
        if expected_ids != actual_ids {
            return Err(format!(
                "criteria_id 集不一致: plan={:?}, cycle={:?}",
                expected_ids, actual_ids
            ));
        }
        Ok(())
    }

    pub(super) async fn interrupt_for_blockers(
        &self,
        key: &str,
        cycle_id: &str,
        reason: &str,
        ctx: &HandlerContext,
    ) {
        let maybe = {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(key) else {
                return;
            };
            entry.status = "interrupted".to_string();
            entry.stop_requested = false;
            entry.terminal_reason_code = Some(reason.to_string());
            Some((entry.project.clone(), entry.workspace.clone()))
        };
        let Some((project, workspace)) = maybe else {
            return;
        };
        self.persist_cycle_file(key).await.ok();
        self.broadcast(
            ctx,
            ServerMessage::EvoWorkspaceStopped {
                event_id: Uuid::new_v4().to_string(),
                event_seq: self.next_seq(key).await,
                project: project.clone(),
                workspace: workspace.clone(),
                cycle_id: cycle_id.to_string(),
                ts: Utc::now().to_rfc3339(),
                source: "system".to_string(),
                status: "interrupted".to_string(),
                reason: Some(reason.to_string()),
            },
        )
        .await;
        self.broadcast_cycle_update(key, ctx, "system").await;
        self.broadcast_scheduler(ctx).await;
        if let Some(root) = {
            let state = self.state.lock().await;
            state
                .workspaces
                .get(key)
                .map(|item| item.workspace_root.clone())
        } {
            if let Err(err) = self
                .emit_blocking_required_if_any(
                    &project,
                    &workspace,
                    &root,
                    "stage_interrupt",
                    Some(cycle_id),
                    None,
                    ctx,
                )
                .await
            {
                warn!("emit blocking required failed: {}", err);
            }
        }
    }

    async fn block_current_stage_by_question(
        &self,
        key: &str,
        project: &str,
        workspace: &str,
        cycle_id: &str,
        stage: &str,
        request: &AiQuestionRequest,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        let workspace_root = {
            let state = self.state.lock().await;
            let Some(entry) = state.workspaces.get(key) else {
                return Err("workspace state missing".to_string());
            };
            entry.workspace_root.clone()
        };
        self.add_blocker_from_question(
            project,
            workspace,
            &workspace_root,
            cycle_id,
            stage,
            request,
        )
        .await?;
        self.set_stage_status(key, stage, "blocked").await;
        self.persist_stage_file(
            key,
            stage,
            "blocked",
            Some("human blocker created from AI question"),
            None,
        )
        .await
        .ok();
        self.persist_cycle_file(key).await.ok();
        self.broadcast_cycle_update(key, ctx, "agent").await;
        Ok(())
    }

    async fn run_with_retry<F, Fut>(
        max_attempts: u32,
        retry_delay: Duration,
        mut runner: F,
    ) -> Result<(), String>
    where
        F: FnMut(u32) -> Fut,
        Fut: std::future::Future<Output = Result<(), String>>,
    {
        if max_attempts == 0 {
            return Err("max_attempts must be greater than 0".to_string());
        }

        let mut last_err: Option<String> = None;
        for attempt in 1..=max_attempts {
            match runner(attempt).await {
                Ok(()) => return Ok(()),
                Err(err) => {
                    last_err = Some(err.clone());
                    if attempt < max_attempts {
                        warn!(
                            "auto commit attempt {}/{} failed: {}, retrying in {}s",
                            attempt,
                            max_attempts,
                            err,
                            retry_delay.as_secs()
                        );
                        sleep(retry_delay).await;
                    } else {
                        warn!(
                            "auto commit attempt {}/{} failed: {}",
                            attempt, max_attempts, err
                        );
                    }
                }
            }
        }

        Err(format!(
            "auto commit failed after {} attempts: {}",
            max_attempts,
            last_err.unwrap_or_else(|| "unknown error".to_string())
        ))
    }

    async fn run_auto_commit_once(
        project: String,
        workspace: String,
        workspace_root: std::path::PathBuf,
        ai_agent: String,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        let rx = spawn_git_ai_commit_task(
            project,
            workspace,
            workspace_root,
            Some(ai_agent),
            "AI 提交",
            ctx,
        )
        .await;
        match rx.await {
            Ok(crate::server::protocol::ServerMessage::GitAICommitResult {
                success,
                message,
                ..
            }) => {
                if success {
                    Ok(())
                } else {
                    Err(message)
                }
            }
            Ok(_) => Err("unexpected message type from AI commit task".to_string()),
            Err(_) => Err("AI commit task channel closed unexpectedly".to_string()),
        }
    }

    async fn run_auto_commit_after_round(
        &self,
        project: &str,
        workspace: &str,
        workspace_root: &str,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        let ai_agent = {
            let state = ctx.app_state.read().await;
            state
                .client_settings
                .commit_ai_agent
                .clone()
                .unwrap_or_else(|| "cursor".to_string())
        };
        let root = std::path::PathBuf::from(workspace_root);
        Self::run_with_retry(
            AUTO_COMMIT_MAX_ATTEMPTS,
            Duration::from_secs(AUTO_COMMIT_RETRY_DELAY_SECS),
            move |_attempt| {
                let project = project.to_string();
                let workspace = workspace.to_string();
                let root = root.clone();
                let ai_agent = ai_agent.clone();
                let ctx = ctx.clone();
                async move { Self::run_auto_commit_once(project, workspace, root, ai_agent, &ctx).await }
            },
        )
        .await
    }

    fn supports_validation_reminder(stage: &str) -> bool {
        matches!(stage, "implement" | "verify" | "judge")
    }

    fn should_retry_validation_with_reminder(stage: &str, err: &str) -> bool {
        Self::supports_validation_reminder(stage) && err.starts_with("evo_stage_output_invalid:")
    }

    fn build_validation_reminder_message(stage: &str, validation_err: &str) -> String {
        format!(
            "<system-reminder>{stage} 阶段产物有问题：{validation_err}。请修复</system-reminder>"
        )
    }

    async fn consume_stage_stream(
        &self,
        key: &str,
        project: &str,
        workspace: &str,
        cycle_id: &str,
        stage: &str,
        ai_tool: &str,
        session_id: &str,
        directory: &str,
        agent: &Arc<dyn AiAgent>,
        mut stream: crate::ai::AiEventStream,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        loop {
            let next = timeout(Duration::from_secs(MAX_STAGE_RUNTIME_SECS), stream.next()).await;
            match next {
                Ok(Some(Ok(event))) => match event {
                    crate::ai::AiEvent::Done => {
                        let adapter_hint =
                            match agent.session_selection_hint(directory, session_id).await {
                                Ok(Some(adapter_hint)) => adapter_hint,
                                Ok(None) => crate::ai::AiSessionSelectionHint::default(),
                                Err(_) => crate::ai::AiSessionSelectionHint::default(),
                            };
                        let inferred_hint =
                            match agent.list_messages(directory, session_id, Some(200)).await {
                                Ok(messages) => {
                                    let wire_messages: Vec<
                                        crate::server::protocol::ai::MessageInfo,
                                    > = messages
                                        .into_iter()
                                        .map(|m| crate::server::protocol::ai::MessageInfo {
                                            id: m.id,
                                            role: m.role,
                                            created_at: m.created_at,
                                            agent: m.agent,
                                            model_provider_id: m.model_provider_id,
                                            model_id: m.model_id,
                                            parts: m
                                                .parts
                                                .into_iter()
                                                .map(normalize_part_for_wire)
                                                .collect(),
                                        })
                                        .collect();
                                    infer_selection_hint_from_messages(&wire_messages)
                                }
                                Err(_) => crate::ai::AiSessionSelectionHint::default(),
                            };
                        let selection_hint =
                            merge_session_selection_hint(adapter_hint, inferred_hint);
                        self.broadcast(
                            ctx,
                            ServerMessage::AIChatDone {
                                project_name: project.to_string(),
                                workspace_name: workspace.to_string(),
                                ai_tool: ai_tool.to_string(),
                                session_id: session_id.to_string(),
                                selection_hint,
                            },
                        )
                        .await;
                        break;
                    }
                    crate::ai::AiEvent::Error { message } => {
                        self.broadcast(
                            ctx,
                            ServerMessage::AIChatErrorV2 {
                                project_name: project.to_string(),
                                workspace_name: workspace.to_string(),
                                ai_tool: ai_tool.to_string(),
                                session_id: session_id.to_string(),
                                error: message.clone(),
                            },
                        )
                        .await;
                        return Err(format!("stage stream error: {}", message));
                    }
                    crate::ai::AiEvent::MessageUpdated {
                        message_id,
                        role,
                        selection_hint,
                    } => {
                        self.broadcast(
                            ctx,
                            ServerMessage::AIChatMessageUpdated {
                                project_name: project.to_string(),
                                workspace_name: workspace.to_string(),
                                ai_tool: ai_tool.to_string(),
                                session_id: session_id.to_string(),
                                message_id,
                                role,
                                selection_hint: selection_hint.map(|hint| {
                                    crate::server::protocol::ai::SessionSelectionHint {
                                        agent: hint.agent,
                                        model_provider_id: hint.model_provider_id,
                                        model_id: hint.model_id,
                                    }
                                }),
                            },
                        )
                        .await;
                    }
                    crate::ai::AiEvent::PartUpdated { message_id, part } => {
                        let mut tool_call_count_changed = false;
                        if part.part_type == "tool" {
                            let call_key = part
                                .tool_call_id
                                .as_deref()
                                .filter(|v| !v.trim().is_empty())
                                .unwrap_or(part.id.as_str());
                            tool_call_count_changed =
                                self.record_stage_tool_call(key, stage, call_key).await;
                        }
                        self.broadcast(
                            ctx,
                            ServerMessage::AIChatPartUpdated {
                                project_name: project.to_string(),
                                workspace_name: workspace.to_string(),
                                ai_tool: ai_tool.to_string(),
                                session_id: session_id.to_string(),
                                message_id,
                                part: normalize_part_for_wire(part),
                            },
                        )
                        .await;
                        if tool_call_count_changed {
                            self.broadcast_cycle_update(key, ctx, "agent").await;
                        }
                    }
                    crate::ai::AiEvent::PartDelta {
                        message_id,
                        part_id,
                        part_type,
                        field,
                        delta,
                    } => {
                        let tool_call_count_changed = if part_type == "tool" {
                            self.record_stage_tool_call(key, stage, &part_id).await
                        } else {
                            false
                        };
                        self.broadcast(
                            ctx,
                            ServerMessage::AIChatPartDelta {
                                project_name: project.to_string(),
                                workspace_name: workspace.to_string(),
                                ai_tool: ai_tool.to_string(),
                                session_id: session_id.to_string(),
                                message_id,
                                part_id,
                                part_type,
                                field,
                                delta,
                            },
                        )
                        .await;
                        if tool_call_count_changed {
                            self.broadcast_cycle_update(key, ctx, "agent").await;
                        }
                    }
                    crate::ai::AiEvent::QuestionAsked { request } => {
                        self.block_current_stage_by_question(
                            key, project, workspace, cycle_id, stage, &request, ctx,
                        )
                        .await?;
                        return Err("evo_human_blocking_required:ai_question".to_string());
                    }
                    crate::ai::AiEvent::QuestionCleared { .. } => {}
                },
                Ok(Some(Err(err))) => return Err(err),
                Ok(None) => break,
                Err(_) => return Err("stage stream timeout".to_string()),
            }
        }

        Ok(())
    }

    async fn resolve_judge_result(&self, key: &str, cycle_id: &str) -> Result<bool, String> {
        let mut judge_pass = true;
        let maybe_workspace_root = {
            let state = self.state.lock().await;
            state
                .workspaces
                .get(key)
                .map(|entry| entry.workspace_root.clone())
        };

        if let Some(workspace_root) = maybe_workspace_root {
            if let Ok(cycle_dir) = cycle_dir_path(&workspace_root, cycle_id) {
                let mut file_judge_result: Option<bool> = None;
                let judge_result_path = cycle_dir.join("judge.result.json");
                if let Ok(content) = std::fs::read_to_string(&judge_result_path) {
                    if let Ok(json) = serde_json::from_str::<serde_json::Value>(&content) {
                        if let Some(parsed) = parse_judge_result_from_json(&json) {
                            file_judge_result = Some(parsed);
                        }
                    }
                }

                if file_judge_result.is_none() {
                    let stage_judge_path = cycle_dir.join("stage.judge.json");
                    if let Ok(content) = std::fs::read_to_string(&stage_judge_path) {
                        if let Ok(json) = serde_json::from_str::<serde_json::Value>(&content) {
                            if let Some(parsed) = parse_judge_result_from_json(&json) {
                                file_judge_result = Some(parsed);
                            }
                        }
                    }
                }

                if let Some(parsed) = file_judge_result {
                    judge_pass = parsed;
                } else {
                    return Err(
                        "judge structured result missing: require judge.result.json or stage.judge.json with pass/fail"
                            .to_string(),
                    );
                }
            }
        } else {
            warn!(
                "judge result resolve skipped: workspace missing, key={}",
                key
            );
        }

        Ok(judge_pass)
    }

    async fn validate_stage_outputs(
        &self,
        key: &str,
        stage: &str,
        cycle_id: &str,
    ) -> Result<(), String> {
        let validation_ctx = {
            let state = self.state.lock().await;
            state
                .workspaces
                .get(key)
                .map(|entry| (entry.workspace_root.clone(), entry.verify_iteration))
        };
        if let Some((workspace_root, verify_iteration)) = validation_ctx {
            let cycle_dir = cycle_dir_path(&workspace_root, cycle_id)?;
            Self::validate_stage_artifacts(stage, &cycle_dir, verify_iteration)
                .map_err(|e| format!("evo_stage_output_invalid: {}", e))?;
        }
        Ok(())
    }

    async fn send_validation_reminder_in_same_session(
        &self,
        key: &str,
        project: &str,
        workspace: &str,
        cycle_id: &str,
        stage: &str,
        ai_tool: &str,
        session_id: &str,
        directory: &str,
        agent: &Arc<dyn AiAgent>,
        validation_err: &str,
        model: Option<AiModelSelection>,
        mode: Option<String>,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        let reminder = Self::build_validation_reminder_message(stage, validation_err);
        let stream = agent
            .send_message(directory, session_id, &reminder, None, None, model, mode)
            .await
            .map_err(|e| format!("validation reminder send failed: {}", e))?;
        self.consume_stage_stream(
            key, project, workspace, cycle_id, stage, ai_tool, session_id, directory, agent,
            stream, ctx,
        )
        .await
    }

    async fn finalize_stage_failed(
        &self,
        key: &str,
        stage: &str,
        error_message: &str,
        ctx: &HandlerContext,
    ) {
        self.set_stage_status(key, stage, "failed").await;
        self.persist_stage_file(key, stage, "failed", Some(error_message), None)
            .await
            .ok();
        self.persist_cycle_file(key).await.ok();
        self.broadcast_cycle_update(key, ctx, "system").await;
    }

    pub(super) async fn run_stage(
        &self,
        key: &str,
        project: &str,
        workspace: &str,
        cycle_id: &str,
        stage: &str,
        round: u32,
        ctx: &HandlerContext,
    ) -> Result<bool, String> {
        let profile = {
            let state = self.state.lock().await;
            let entry = state
                .workspaces
                .get(key)
                .ok_or_else(|| "workspace state missing".to_string())?;
            profile_for_stage(&entry.stage_profiles, stage)
        };
        let ai_tool = profile.ai_tool.clone();

        self.set_stage_status(key, stage, "running").await;
        self.reset_stage_tool_call_tracking(key, stage).await;
        self.persist_cycle_file(key).await.ok();
        self.persist_stage_file(key, stage, "running", None, None)
            .await
            .ok();
        self.broadcast_cycle_update(key, ctx, "orchestrator").await;

        let directory = resolve_directory(&ctx.app_state, project, workspace).await?;
        let agent = ensure_agent(&ctx.ai_state, &ai_tool).await?;

        let title = format!("Evolution {} {}", stage, cycle_id);
        let session = agent.create_session(&directory, &title).await?;
        self.set_stage_session(key, stage, &ai_tool, &session.id)
            .await;
        self.persist_chat_map(key).await.ok();
        self.persist_stage_file(key, stage, "running", None, None)
            .await
            .ok();

        let prompt = self
            .build_stage_prompt(key, project, workspace, cycle_id, stage, round)
            .await?;

        let model = profile.model.as_ref().map(|m| AiModelSelection {
            provider_id: m.provider_id.clone(),
            model_id: m.model_id.clone(),
        });
        let mode = profile.mode.clone();

        let stream = agent
            .send_message(
                &directory,
                &session.id,
                &prompt,
                None,
                None,
                model.clone(),
                mode.clone(),
            )
            .await?;
        self.consume_stage_stream(
            key,
            project,
            workspace,
            cycle_id,
            stage,
            &ai_tool,
            &session.id,
            &directory,
            &agent,
            stream,
            ctx,
        )
        .await?;

        let mut judge_pass = true;
        let mut reminder_attempts: u32 = 0;
        loop {
            if stage == "judge" {
                judge_pass = self.resolve_judge_result(key, cycle_id).await?;
            }

            match self.validate_stage_outputs(key, stage, cycle_id).await {
                Ok(()) => break,
                Err(validation_err) => {
                    if !Self::should_retry_validation_with_reminder(stage, &validation_err) {
                        return Err(validation_err);
                    }

                    if reminder_attempts >= VALIDATION_REMINDER_MAX_RETRIES {
                        self.finalize_stage_failed(key, stage, &validation_err, ctx)
                            .await;
                        return Err(validation_err);
                    }

                    reminder_attempts += 1;
                    let reminder_result = self
                        .send_validation_reminder_in_same_session(
                            key,
                            project,
                            workspace,
                            cycle_id,
                            stage,
                            &ai_tool,
                            &session.id,
                            &directory,
                            &agent,
                            &validation_err,
                            model.clone(),
                            mode.clone(),
                            ctx,
                        )
                        .await;

                    if let Err(reminder_err) = reminder_result {
                        if reminder_err.starts_with("evo_human_blocking_required") {
                            return Err(reminder_err);
                        }

                        let combined_err = format!(
                            "{}; validation reminder failed: {}",
                            validation_err, reminder_err
                        );
                        warn!(
                            "validation reminder failed: key={}, stage={}, attempt={}/{}, error={}",
                            key,
                            stage,
                            reminder_attempts,
                            VALIDATION_REMINDER_MAX_RETRIES,
                            combined_err
                        );

                        if reminder_attempts >= VALIDATION_REMINDER_MAX_RETRIES {
                            self.finalize_stage_failed(key, stage, &combined_err, ctx)
                                .await;
                            return Err(combined_err);
                        }
                    }
                }
            }
        }

        let blocker_check_ctx = {
            let state = self.state.lock().await;
            state.workspaces.get(key).map(|entry| {
                (
                    entry.workspace_root.clone(),
                    entry.project.clone(),
                    entry.workspace.clone(),
                )
            })
        };
        let has_stage_blocker =
            if let Some((workspace_root, project_name, workspace_name)) = blocker_check_ctx {
                self.has_stage_blocker(
                    &workspace_root,
                    &project_name,
                    &workspace_name,
                    cycle_id,
                    stage,
                )
                .await
            } else {
                false
            };
        if has_stage_blocker {
            self.set_stage_status(key, stage, "blocked").await;
            self.persist_stage_file(
                key,
                stage,
                "blocked",
                Some("stage blocked by unresolved human blocker"),
                None,
            )
            .await
            .ok();
            self.persist_cycle_file(key).await.ok();
            self.broadcast_cycle_update(key, ctx, "agent").await;
            return Err("evo_human_blocking_required:stage_blocker_file".to_string());
        }

        self.set_stage_status(key, stage, "done").await;
        self.persist_stage_file(
            key,
            stage,
            "done",
            None,
            if stage == "judge" {
                Some(judge_pass)
            } else {
                None
            },
        )
        .await
        .ok();
        self.persist_cycle_file(key).await.ok();
        self.broadcast_cycle_update(key, ctx, "agent").await;

        Ok(judge_pass)
    }

    pub(super) async fn after_stage_success(
        &self,
        key: &str,
        stage: &str,
        judge_pass: bool,
        ctx: &HandlerContext,
    ) -> bool {
        let cycle_for_validation = {
            let state = self.state.lock().await;
            state.workspaces.get(key).map(|e| e.cycle_id.clone())
        };
        if stage == "plan" {
            let Some(cycle_id) = cycle_for_validation.clone() else {
                return false;
            };
            if let Err(err) = self
                .sync_acceptance_criteria_from_plan(key, &cycle_id)
                .await
            {
                self.mark_failed_with_code(key, "evo_acceptance_source_missing", &err, ctx)
                    .await;
                return false;
            }
        }
        if stage == "judge" {
            let Some(cycle_id) = cycle_for_validation.clone() else {
                return false;
            };
            if let Err(err) = self.ensure_acceptance_consistency(key, &cycle_id).await {
                self.mark_failed_with_code(key, "evo_acceptance_mapping_inconsistent", &err, ctx)
                    .await;
                return false;
            }
        }
        let mut emit_judge: Option<(String, String, String, String)> = None;
        let mut stage_changed: Option<(String, String, String, String, String)> = None;
        let mut post_auto_commit_stage_changed: Option<(String, String, String, String, String)> =
            None;
        let mut auto_next_cycle = false;
        let mut auto_commit_ctx: Option<(String, String, String, String, bool)> = None;
        let mut auto_loop_gate: Option<(String, String, String, String)> = None;

        {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(key) else {
                return false;
            };

            let previous = entry.current_stage.clone();
            let mut next_stage = previous.clone();

            match stage {
                "bootstrap" => next_stage = "direction".to_string(),
                "direction" => next_stage = "plan".to_string(),
                "plan" => next_stage = "implement".to_string(),
                "implement" => next_stage = "verify".to_string(),
                "verify" => next_stage = "judge".to_string(),
                "judge" => {
                    entry.last_judge_result = Some(judge_pass);
                    if judge_pass {
                        entry.terminal_reason_code = None;
                        emit_judge = Some((
                            entry.project.clone(),
                            entry.workspace.clone(),
                            entry.cycle_id.clone(),
                            "pass".to_string(),
                        ));
                        next_stage = "report".to_string();
                    } else if entry.verify_iteration + 1 < entry.verify_iteration_limit {
                        entry.terminal_reason_code = None;
                        entry.verify_iteration += 1;
                        emit_judge = Some((
                            entry.project.clone(),
                            entry.workspace.clone(),
                            entry.cycle_id.clone(),
                            "fail".to_string(),
                        ));
                        next_stage = "implement".to_string();
                    } else {
                        entry.status = "failed_exhausted".to_string();
                        entry.terminal_reason_code =
                            Some("evo_verify_iteration_exhausted".to_string());
                        emit_judge = Some((
                            entry.project.clone(),
                            entry.workspace.clone(),
                            entry.cycle_id.clone(),
                            "fail".to_string(),
                        ));
                        next_stage = "report".to_string();
                    }
                }
                "report" => {
                    if entry.status != "failed_system" {
                        entry.status = if entry.last_judge_result.unwrap_or(false) {
                            entry.terminal_reason_code = None;
                            "completed".to_string()
                        } else {
                            if entry.terminal_reason_code.is_none() {
                                entry.terminal_reason_code = Some("evo_judge_failed".to_string());
                            }
                            "failed_exhausted".to_string()
                        };
                    }
                    if should_auto_commit_after_report(&entry.status) {
                        let should_start_next_round = should_start_next_round(
                            &entry.status,
                            entry.global_loop_round,
                            entry.loop_round_limit,
                        );
                        auto_commit_ctx = Some((
                            entry.project.clone(),
                            entry.workspace.clone(),
                            entry.workspace_root.clone(),
                            entry.cycle_id.clone(),
                            should_start_next_round,
                        ));
                        if should_start_next_round {
                            auto_loop_gate = Some((
                                entry.project.clone(),
                                entry.workspace.clone(),
                                entry.workspace_root.clone(),
                                entry.cycle_id.clone(),
                            ));
                        }
                    }
                }
                _ => {}
            }

            if stage != "report" {
                entry.current_stage = next_stage.clone();
                stage_changed = Some((
                    entry.project.clone(),
                    entry.workspace.clone(),
                    entry.cycle_id.clone(),
                    previous,
                    next_stage,
                ));
            }
        }

        if let Some((project, workspace, workspace_root, cycle_id)) = auto_loop_gate {
            match self
                .emit_blocking_required_if_any(
                    &project,
                    &workspace,
                    &workspace_root,
                    "auto_loop",
                    Some(&cycle_id),
                    Some("report"),
                    ctx,
                )
                .await
            {
                Ok(true) => {
                    self.interrupt_for_blockers(key, &cycle_id, "workspace_blockers_pending", ctx)
                        .await;
                    return false;
                }
                Ok(false) => {}
                Err(err) => {
                    self.mark_failed_with_code(
                        key,
                        "evo_internal_error",
                        &format!("blocker gate check failed: {}", err),
                        ctx,
                    )
                    .await;
                    return false;
                }
            }
        }

        if let Some((project, workspace, workspace_root, cycle_id, should_start_next_round)) =
            auto_commit_ctx
        {
            {
                let mut state = self.state.lock().await;
                let Some(entry) = state.workspaces.get_mut(key) else {
                    return false;
                };
                entry.current_stage = "auto_commit".to_string();
                entry
                    .stage_statuses
                    .insert("auto_commit".to_string(), "running".to_string());
            }
            self.persist_cycle_file(key).await.ok();
            self.broadcast(
                ctx,
                ServerMessage::EvoStageChanged {
                    event_id: Uuid::new_v4().to_string(),
                    event_seq: self.next_seq(key).await,
                    project: project.clone(),
                    workspace: workspace.clone(),
                    cycle_id: cycle_id.clone(),
                    ts: Utc::now().to_rfc3339(),
                    source: "orchestrator".to_string(),
                    from_stage: "report".to_string(),
                    to_stage: "auto_commit".to_string(),
                    verify_iteration: self
                        .state
                        .lock()
                        .await
                        .workspaces
                        .get(key)
                        .map(|v| v.verify_iteration)
                        .unwrap_or(0),
                },
            )
            .await;
            self.broadcast_cycle_update(key, ctx, "orchestrator").await;

            if let Err(err) = self
                .run_auto_commit_after_round(&project, &workspace, &workspace_root, ctx)
                .await
            {
                {
                    let mut state = self.state.lock().await;
                    if let Some(entry) = state.workspaces.get_mut(key) {
                        entry
                            .stage_statuses
                            .insert("auto_commit".to_string(), "failed".to_string());
                    }
                }
                self.mark_failed_with_code(
                    key,
                    "evo_auto_commit_failed",
                    &format!("auto commit after round failed: {}", err),
                    ctx,
                )
                .await;
                return false;
            }

            {
                let mut state = self.state.lock().await;
                let Some(entry) = state.workspaces.get_mut(key) else {
                    return false;
                };
                entry
                    .stage_statuses
                    .insert("auto_commit".to_string(), "done".to_string());
                if should_start_next_round {
                    entry.global_loop_round += 1;
                    entry.verify_iteration = 0;
                    entry.cycle_id = Utc::now().format("%Y-%m-%dT%H-%M-%S-%3fZ").to_string();
                    entry.created_at = Utc::now().to_rfc3339();
                    entry.current_stage = "direction".to_string();
                    entry.status = "queued".to_string();
                    entry.last_judge_result = None;
                    entry.terminal_reason_code = None;
                    entry.llm_defined_acceptance_criteria.clear();
                    entry.stage_sessions.clear();
                    entry.stage_session_history.clear();
                    entry.stage_statuses.clear();
                    entry.stage_tool_call_counts.clear();
                    entry.stage_seen_tool_calls.clear();
                    for s in STAGES {
                        entry
                            .stage_statuses
                            .insert(s.to_string(), "pending".to_string());
                    }
                    auto_next_cycle = true;
                    post_auto_commit_stage_changed = Some((
                        entry.project.clone(),
                        entry.workspace.clone(),
                        entry.cycle_id.clone(),
                        "auto_commit".to_string(),
                        entry.current_stage.clone(),
                    ));
                } else {
                    entry.current_stage = "report".to_string();
                    post_auto_commit_stage_changed = Some((
                        entry.project.clone(),
                        entry.workspace.clone(),
                        entry.cycle_id.clone(),
                        "auto_commit".to_string(),
                        "report".to_string(),
                    ));
                }
            }
        }

        if let Some((project, workspace, cycle_id, result)) = emit_judge {
            self.broadcast(
                ctx,
                ServerMessage::EvoJudgeResult {
                    event_id: Uuid::new_v4().to_string(),
                    event_seq: self.next_seq(key).await,
                    project,
                    workspace,
                    cycle_id,
                    ts: Utc::now().to_rfc3339(),
                    source: "agent".to_string(),
                    result: result.clone(),
                    reason: if result == "pass" {
                        "judge pass".to_string()
                    } else {
                        "judge fail".to_string()
                    },
                    next_action: if result == "pass" {
                        "goto_stage:report".to_string()
                    } else {
                        "goto_stage:implement".to_string()
                    },
                },
            )
            .await;
        }

        if let Some((project, workspace, cycle_id, from_stage, to_stage)) = stage_changed {
            self.broadcast(
                ctx,
                ServerMessage::EvoStageChanged {
                    event_id: Uuid::new_v4().to_string(),
                    event_seq: self.next_seq(key).await,
                    project,
                    workspace,
                    cycle_id,
                    ts: Utc::now().to_rfc3339(),
                    source: "orchestrator".to_string(),
                    from_stage,
                    to_stage,
                    verify_iteration: self
                        .state
                        .lock()
                        .await
                        .workspaces
                        .get(key)
                        .map(|v| v.verify_iteration)
                        .unwrap_or(0),
                },
            )
            .await;
        }

        if let Some((project, workspace, cycle_id, from_stage, to_stage)) =
            post_auto_commit_stage_changed
        {
            self.broadcast(
                ctx,
                ServerMessage::EvoStageChanged {
                    event_id: Uuid::new_v4().to_string(),
                    event_seq: self.next_seq(key).await,
                    project,
                    workspace,
                    cycle_id,
                    ts: Utc::now().to_rfc3339(),
                    source: "orchestrator".to_string(),
                    from_stage,
                    to_stage,
                    verify_iteration: self
                        .state
                        .lock()
                        .await
                        .workspaces
                        .get(key)
                        .map(|v| v.verify_iteration)
                        .unwrap_or(0),
                },
            )
            .await;
        }

        self.persist_cycle_file(key).await.ok();
        self.broadcast_cycle_update(key, ctx, "orchestrator").await;
        self.broadcast_scheduler(ctx).await;
        auto_next_cycle
    }

    pub(super) async fn mark_interrupted(&self, key: &str, ctx: &HandlerContext) {
        let maybe = {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(key) else {
                return;
            };
            entry.status = "interrupted".to_string();
            entry.stop_requested = true;
            entry.terminal_reason_code = Some("evo_stop_requested".to_string());
            Some((
                entry.project.clone(),
                entry.workspace.clone(),
                entry.cycle_id.clone(),
            ))
        };

        if let Some((project, workspace, cycle_id)) = maybe {
            self.persist_cycle_file(key).await.ok();
            self.broadcast(
                ctx,
                ServerMessage::EvoWorkspaceStopped {
                    event_id: Uuid::new_v4().to_string(),
                    event_seq: self.next_seq(key).await,
                    project,
                    workspace,
                    cycle_id,
                    ts: Utc::now().to_rfc3339(),
                    source: "system".to_string(),
                    status: "interrupted".to_string(),
                    reason: Some("stop_requested".to_string()),
                },
            )
            .await;
            self.broadcast_scheduler(ctx).await;
            self.broadcast_cycle_update(key, ctx, "system").await;
        }
    }

    pub(super) async fn mark_failed_system(&self, key: &str, err: &str, ctx: &HandlerContext) {
        self.mark_failed_with_code(key, "evo_internal_error", err, ctx)
            .await;
    }

    pub(super) async fn mark_failed_with_code(
        &self,
        key: &str,
        code: &str,
        err: &str,
        ctx: &HandlerContext,
    ) {
        let maybe = {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(key) else {
                return;
            };
            entry.status = "failed_system".to_string();
            entry.terminal_reason_code = Some(code.to_string());
            Some((
                entry.project.clone(),
                entry.workspace.clone(),
                entry.cycle_id.clone(),
            ))
        };

        if let Some((project, workspace, cycle_id)) = maybe {
            self.persist_cycle_file(key).await.ok();
            self.broadcast(
                ctx,
                ServerMessage::EvoError {
                    event_id: Some(Uuid::new_v4().to_string()),
                    event_seq: Some(self.next_seq(key).await),
                    project: Some(project),
                    workspace: Some(workspace),
                    cycle_id: Some(cycle_id),
                    ts: Utc::now().to_rfc3339(),
                    source: "system".to_string(),
                    code: code.to_string(),
                    message: err.to_string(),
                    context: None,
                },
            )
            .await;
            self.broadcast_cycle_update(key, ctx, "system").await;
            self.broadcast_scheduler(ctx).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::{stage::next_stage, STAGES};
    use super::{
        parse_judge_result_from_json, should_auto_commit_after_report, should_start_next_round,
        EvolutionManager,
    };
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::Arc;
    use tempfile::tempdir;
    use tokio::time::Duration;

    fn write_json(path: &std::path::Path, value: serde_json::Value) {
        let content = serde_json::to_string_pretty(&value).expect("serialize json failed");
        std::fs::write(path, content).expect("write json failed");
    }

    #[test]
    fn parse_judge_result_json_schema() {
        let value = serde_json::json!({
            "overall_result": {
                "result": "fail"
            }
        });
        assert_eq!(parse_judge_result_from_json(&value), Some(false));
    }

    #[test]
    fn parse_stage_judge_json_schema() {
        let value = serde_json::json!({
            "decision": {
                "result": "pass"
            }
        });
        assert_eq!(parse_judge_result_from_json(&value), Some(true));
    }

    #[test]
    fn should_retry_validation_with_reminder_should_match_supported_stage_and_error() {
        assert!(EvolutionManager::should_retry_validation_with_reminder(
            "implement",
            "evo_stage_output_invalid: x"
        ));
        assert!(EvolutionManager::should_retry_validation_with_reminder(
            "verify",
            "evo_stage_output_invalid: y"
        ));
        assert!(EvolutionManager::should_retry_validation_with_reminder(
            "judge",
            "evo_stage_output_invalid: z"
        ));
        assert!(!EvolutionManager::should_retry_validation_with_reminder(
            "plan",
            "evo_stage_output_invalid: x"
        ));
        assert!(!EvolutionManager::should_retry_validation_with_reminder(
            "judge",
            "stage stream timeout"
        ));
    }

    // ── 六阶段新约束回归测试 ──────────────────────────────────────────────

    #[test]
    fn stages_should_not_contain_bootstrap() {
        // bootstrap 已从 STAGES 集合移除，manager_stage 层回归确认
        assert!(!STAGES.contains(&"bootstrap"), "STAGES 不应包含 bootstrap");
    }

    #[test]
    fn stages_initial_stage_should_be_direction() {
        // 循环起始阶段为 direction（取代旧 bootstrap）
        assert_eq!(STAGES[0], "direction", "初始 stage 应为 direction");
    }

    #[test]
    fn next_stage_report_should_loop_back_to_direction() {
        // report 之后循环回 direction，确保六阶段闭环
        assert_eq!(next_stage("report"), Some("direction"));
    }

    #[test]
    fn next_stage_unknown_should_return_none() {
        // 未知 stage 必须安全返回 None，不可 panic
        assert_eq!(next_stage("bootstrap"), None, "bootstrap 应返回 None");
        assert_eq!(next_stage("unknown"), None, "unknown 应返回 None");
        assert_eq!(next_stage(""), None, "空字符串应返回 None");
    }

    #[test]
    fn extract_acceptance_mapping_criteria_should_work() {
        let input = serde_json::json!({
            "verification_plan": {
                "acceptance_mapping": [
                    {
                        "criteria_id": "ac-1",
                        "description": "desc",
                        "check_ids": ["v-1", "v-5"]
                    }
                ]
            }
        });
        let result = EvolutionManager::extract_acceptance_mapping_criteria(&input)
            .expect("extract criteria should succeed");
        assert_eq!(result.len(), 1);
        assert_eq!(result[0]["criteria_id"], "ac-1");
    }

    #[test]
    fn extract_acceptance_mapping_criteria_should_reject_empty_check_ids() {
        let input = serde_json::json!({
            "verification_plan": {
                "acceptance_mapping": [
                    {
                        "criteria_id": "ac-1",
                        "check_ids": []
                    }
                ]
            }
        });
        let err = EvolutionManager::extract_acceptance_mapping_criteria(&input)
            .expect_err("empty check_ids should fail");
        assert!(
            err.contains("check_ids"),
            "error should mention check_ids, got: {}",
            err
        );
    }

    #[test]
    fn report_completed_final_round_should_auto_commit_but_not_start_next_round() {
        assert!(
            should_auto_commit_after_report("completed"),
            "completed 应触发自动提交"
        );
        assert!(
            !should_start_next_round("completed", 1, 1),
            "最终轮不应自动开始下一轮"
        );
    }

    #[test]
    fn report_completed_non_final_round_should_auto_commit_and_start_next_round() {
        assert!(
            should_auto_commit_after_report("completed"),
            "completed 应触发自动提交"
        );
        assert!(
            should_start_next_round("completed", 1, 3),
            "非最终轮应自动开始下一轮"
        );
    }

    #[test]
    fn report_failed_exhausted_should_not_auto_commit_or_start_next_round() {
        assert!(
            !should_auto_commit_after_report("failed_exhausted"),
            "失败轮不应触发自动提交"
        );
        assert!(
            !should_start_next_round("failed_exhausted", 1, 3),
            "失败轮不应自动开始下一轮"
        );
    }

    #[test]
    fn report_completed_exceeded_round_should_not_start_next_round() {
        assert!(
            !should_start_next_round("completed", 4, 3),
            "已超过上限时不应继续下一轮"
        );
    }

    #[tokio::test]
    async fn auto_commit_retry_should_succeed_on_second_attempt() {
        let attempts = Arc::new(AtomicU32::new(0));
        let attempts_for_runner = attempts.clone();
        let result = EvolutionManager::run_with_retry(2, Duration::from_millis(0), move |_| {
            let attempts = attempts_for_runner.clone();
            async move {
                let current = attempts.fetch_add(1, Ordering::SeqCst) + 1;
                if current == 1 {
                    return Err("first attempt failed".to_string());
                }
                Ok(())
            }
        })
        .await;

        assert!(result.is_ok(), "第二次重试应成功");
        assert_eq!(attempts.load(Ordering::SeqCst), 2, "应执行两次自动提交尝试");
    }

    #[tokio::test]
    async fn auto_commit_retry_should_fail_after_two_attempts() {
        let attempts = Arc::new(AtomicU32::new(0));
        let attempts_for_runner = attempts.clone();
        let result = EvolutionManager::run_with_retry(2, Duration::from_millis(0), move |_| {
            let attempts = attempts_for_runner.clone();
            async move {
                attempts.fetch_add(1, Ordering::SeqCst);
                Err("always failed".to_string())
            }
        })
        .await;

        assert!(result.is_err(), "两次都失败时应返回错误");
        let err = result.expect_err("应返回失败结果");
        assert!(
            err.contains("after 2 attempts"),
            "错误信息应包含重试次数，实际: {}",
            err
        );
        assert_eq!(
            attempts.load(Ordering::SeqCst),
            2,
            "失败场景也应执行两次自动提交尝试"
        );
    }

    #[test]
    fn validate_stage_artifacts_should_reject_missing_failure_backlog_on_reimplementation() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("implement.result.json"),
            serde_json::json!({
                "backlog_coverage": [],
                "backlog_coverage_summary": {
                    "total": 0,
                    "done": 0,
                    "blocked": 0,
                    "not_done": 0
                }
            }),
        );
        let err = EvolutionManager::validate_stage_artifacts("implement", dir.path(), 1)
            .expect_err("missing failure_backlog should fail");
        assert!(err.contains("failure_backlog"));
    }

    #[test]
    fn validate_stage_artifacts_should_reject_backlog_coverage_mismatch() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("implement.result.json"),
            serde_json::json!({
                "failure_backlog": [{"id": "f-1"}, {"id": "f-2"}],
                "backlog_coverage": [{"id": "f-1"}],
                "backlog_coverage_summary": {
                    "total": 2,
                    "done": 1,
                    "blocked": 0,
                    "not_done": 1
                }
            }),
        );
        let err = EvolutionManager::validate_stage_artifacts("implement", dir.path(), 1)
            .expect_err("coverage mismatch should fail");
        assert!(err.contains("数量不一致"));
    }

    #[test]
    fn validate_stage_artifacts_should_reject_verify_missing_backlog_items() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("implement.result.json"),
            serde_json::json!({
                "failure_backlog": [{"id": "f-1"}, {"id": "f-2"}],
                "backlog_coverage": [{"id": "f-1"}, {"id": "f-2"}],
                "backlog_coverage_summary": {
                    "total": 2,
                    "done": 2,
                    "blocked": 0,
                    "not_done": 0
                }
            }),
        );
        write_json(
            &dir.path().join("verify.result.json"),
            serde_json::json!({
                "acceptance_evaluation": [],
                "carryover_verification": {
                    "items": [{"id": "f-1", "status": "done"}],
                    "summary": {"total": 2, "covered": 1, "missing": 1, "blocked": 0}
                }
            }),
        );
        let err = EvolutionManager::validate_stage_artifacts("verify", dir.path(), 1)
            .expect_err("verify missing backlog items should fail");
        assert!(err.contains("缺少 backlog 项"));
    }

    #[test]
    fn validate_stage_artifacts_should_reject_judge_missing_verify_failed_requirements() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("verify.result.json"),
            serde_json::json!({
                "acceptance_evaluation": [
                    {"criteria_id": "ac-1", "status": "fail"}
                ],
                "carryover_verification": {
                    "items": [{"id": "f-1", "status": "missing"}],
                    "summary": {"total": 1, "covered": 0, "missing": 1, "blocked": 0}
                }
            }),
        );
        write_json(
            &dir.path().join("judge.result.json"),
            serde_json::json!({
                "full_next_iteration_requirements": [
                    {"id": "ac-1"}
                ]
            }),
        );
        let err = EvolutionManager::validate_stage_artifacts("judge", dir.path(), 1)
            .expect_err("judge requirements missing should fail");
        assert!(err.contains("未覆盖 verify 未通过项"));
    }
}
