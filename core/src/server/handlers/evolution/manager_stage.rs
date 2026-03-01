use chrono::Utc;
use futures::StreamExt;
use std::collections::{HashMap, HashSet};
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
use super::utils::{cycle_dir_path, write_json};
use super::{EvolutionManager, MAX_STAGE_RUNTIME_SECS, STAGES};

const AUTO_COMMIT_MAX_ATTEMPTS: u32 = 2;
const AUTO_COMMIT_RETRY_DELAY_SECS: u64 = 2;
const VALIDATION_REMINDER_MAX_RETRIES: u32 = 2;
const IMPLEMENT_CONFIG_RESERVED_PREFIX: &str = "__evo_internal_";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum PlanImplementationAgent {
    ImplementGeneral,
    ImplementVisual,
    ImplementAdvanced,
}

impl PlanImplementationAgent {
    fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "implement_general" => Some(Self::ImplementGeneral),
            "implement_visual" => Some(Self::ImplementVisual),
            "implement_advanced" => Some(Self::ImplementAdvanced),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ImplementLane {
    General,
    Visual,
    Advanced,
}

impl ImplementLane {
    fn as_str(self) -> &'static str {
        match self {
            Self::General => "implement_general",
            Self::Visual => "implement_visual",
            Self::Advanced => "implement_advanced",
        }
    }
}

struct PlanRoutingTables {
    lane_presence: HashSet<PlanImplementationAgent>,
    criteria_to_checks: HashMap<String, Vec<String>>,
    check_to_agents: HashMap<String, HashSet<PlanImplementationAgent>>,
}

struct StageRunContext {
    ai_tool: String,
    session_id: String,
    directory: String,
    agent: Arc<dyn AiAgent>,
    model: Option<AiModelSelection>,
    mode: Option<String>,
    config_overrides: Option<HashMap<String, serde_json::Value>>,
}

fn sanitize_ai_config_options(
    options: &HashMap<String, serde_json::Value>,
) -> Option<HashMap<String, serde_json::Value>> {
    if options.is_empty() {
        return None;
    }
    let filtered: HashMap<String, serde_json::Value> = options
        .iter()
        .filter_map(|(key, value)| {
            if key.starts_with(IMPLEMENT_CONFIG_RESERVED_PREFIX) {
                None
            } else {
                Some((key.clone(), value.clone()))
            }
        })
        .collect();
    if filtered.is_empty() {
        None
    } else {
        Some(filtered)
    }
}

fn ordered_lanes_from_agent_presence(
    agent_presence: &HashSet<PlanImplementationAgent>,
) -> Vec<ImplementLane> {
    let has_general = agent_presence.contains(&PlanImplementationAgent::ImplementGeneral);
    let has_visual = agent_presence.contains(&PlanImplementationAgent::ImplementVisual);
    let has_advanced = agent_presence.contains(&PlanImplementationAgent::ImplementAdvanced);
    if has_general && has_visual {
        return vec![ImplementLane::General, ImplementLane::Visual];
    }
    if has_general {
        return vec![ImplementLane::General];
    }
    if has_visual {
        return vec![ImplementLane::Visual];
    }
    if has_advanced {
        return vec![ImplementLane::Advanced];
    }
    vec![ImplementLane::General]
}

fn parse_non_empty_string(value: &serde_json::Value) -> Option<String> {
    value
        .as_str()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn parse_plan_routing_tables(value: &serde_json::Value) -> Result<PlanRoutingTables, String> {
    let checks = value
        .pointer("/verification_plan/checks")
        .and_then(|v| v.as_array())
        .ok_or_else(|| "plan.execution.json 缺少 verification_plan.checks".to_string())?;
    let mut check_ids = HashSet::new();
    for (idx, check) in checks.iter().enumerate() {
        let check_id = id_from_value(check, &["id"])
            .ok_or_else(|| format!("verification_plan.checks[{}] 缺少有效 id", idx))?;
        if !check_ids.insert(check_id.clone()) {
            return Err(format!(
                "verification_plan.checks 存在重复 id: {}",
                check_id
            ));
        }
    }
    if check_ids.is_empty() {
        return Err("verification_plan.checks 不能为空".to_string());
    }

    let work_items = value
        .pointer("/work_items")
        .and_then(|v| v.as_array())
        .ok_or_else(|| "plan.execution.json 缺少 work_items".to_string())?;
    if work_items.is_empty() {
        return Err("work_items 不能为空".to_string());
    }

    let mut work_item_ids = HashSet::new();
    let mut lane_presence: HashSet<PlanImplementationAgent> = HashSet::new();
    let mut check_to_agents: HashMap<String, HashSet<PlanImplementationAgent>> = HashMap::new();

    for (idx, item) in work_items.iter().enumerate() {
        let item_obj = item
            .as_object()
            .ok_or_else(|| format!("work_items[{}] 必须是对象", idx))?;
        let work_id = item_obj
            .get("id")
            .and_then(parse_non_empty_string)
            .ok_or_else(|| format!("work_items[{}] 缺少 id", idx))?;
        if !work_item_ids.insert(work_id.clone()) {
            return Err(format!("work_items.id 存在重复值: {}", work_id));
        }

        let agent_raw = item_obj
            .get("implementation_agent")
            .and_then(|v| v.as_str())
            .ok_or_else(|| format!("work_items[{}] 缺少 implementation_agent", idx))?;
        let agent = PlanImplementationAgent::parse(agent_raw).ok_or_else(|| {
            format!(
                "work_items[{}].implementation_agent 非法: {}",
                idx, agent_raw
            )
        })?;
        lane_presence.insert(agent);

        let linked = item_obj
            .get("linked_check_ids")
            .and_then(|v| v.as_array())
            .ok_or_else(|| format!("work_items[{}] 缺少 linked_check_ids", idx))?;
        if linked.is_empty() {
            return Err(format!("work_items[{}].linked_check_ids 不能为空", idx));
        }
        for (check_idx, check_value) in linked.iter().enumerate() {
            let check_id = check_value
                .as_str()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .ok_or_else(|| {
                    format!(
                        "work_items[{}].linked_check_ids[{}] 必须是非空字符串",
                        idx, check_idx
                    )
                })?;
            if !check_ids.contains(&check_id) {
                return Err(format!(
                    "work_items[{}].linked_check_ids 包含未知 check_id: {}",
                    idx, check_id
                ));
            }
            check_to_agents.entry(check_id).or_default().insert(agent);
        }
    }

    let acceptance_mapping = value
        .pointer("/verification_plan/acceptance_mapping")
        .and_then(|v| v.as_array())
        .ok_or_else(|| {
            "plan.execution.json 缺少 verification_plan.acceptance_mapping".to_string()
        })?;

    let mut criteria_to_checks: HashMap<String, Vec<String>> = HashMap::new();
    for (idx, item) in acceptance_mapping.iter().enumerate() {
        let item_obj = item
            .as_object()
            .ok_or_else(|| format!("acceptance_mapping[{}] 必须是对象", idx))?;
        let criteria_id = item_obj
            .get("criteria_id")
            .and_then(parse_non_empty_string)
            .ok_or_else(|| format!("acceptance_mapping[{}] 缺少 criteria_id", idx))?;
        let check_ids_raw = item_obj
            .get("check_ids")
            .and_then(|v| v.as_array())
            .ok_or_else(|| format!("acceptance_mapping[{}] 缺少 check_ids", idx))?;
        if check_ids_raw.is_empty() {
            return Err(format!("acceptance_mapping[{}].check_ids 不能为空", idx));
        }

        let mut mapped_to_work_item = false;
        let mut mapped_checks = Vec::with_capacity(check_ids_raw.len());
        for (check_idx, value) in check_ids_raw.iter().enumerate() {
            let check_id = value
                .as_str()
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty())
                .ok_or_else(|| {
                    format!(
                        "acceptance_mapping[{}].check_ids[{}] 必须是非空字符串",
                        idx, check_idx
                    )
                })?;
            if !check_ids.contains(&check_id) {
                return Err(format!(
                    "acceptance_mapping[{}].check_ids 包含未知 check_id: {}",
                    idx, check_id
                ));
            }
            if check_to_agents.contains_key(&check_id) {
                mapped_to_work_item = true;
            }
            mapped_checks.push(check_id);
        }
        if !mapped_to_work_item {
            return Err(format!(
                "acceptance_mapping[{}].check_ids 未关联任何 work_item",
                idx
            ));
        }
        criteria_to_checks.insert(criteria_id, mapped_checks);
    }

    Ok(PlanRoutingTables {
        lane_presence,
        criteria_to_checks,
        check_to_agents,
    })
}

fn is_criteria_failure_status(status: &str) -> bool {
    matches!(
        status.trim().to_ascii_lowercase().as_str(),
        "fail" | "insufficient_evidence"
    )
}

fn is_carryover_failure_status(status: &str) -> bool {
    matches!(
        status.trim().to_ascii_lowercase().as_str(),
        "missing" | "blocked"
    )
}

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
    fn validate_plan_artifact(cycle_dir: &Path) -> Result<(), String> {
        let value = read_json_file(cycle_dir, "plan.execution.json")?;
        parse_plan_routing_tables(&value)?;
        Ok(())
    }

    fn implement_result_file_for_lane(lane: ImplementLane) -> &'static str {
        match lane {
            ImplementLane::General => "implement_general.result.json",
            ImplementLane::Visual => "implement_visual.result.json",
            ImplementLane::Advanced => "implement_advanced.result.json",
        }
    }

    fn implement_result_file_for_stage(stage: &str) -> Option<&'static str> {
        match stage {
            "implement_general" => {
                Some(Self::implement_result_file_for_lane(ImplementLane::General))
            }
            "implement_visual" => Some(Self::implement_result_file_for_lane(ImplementLane::Visual)),
            "implement_advanced" => Some(Self::implement_result_file_for_lane(
                ImplementLane::Advanced,
            )),
            _ => None,
        }
    }

    fn collect_reimplementation_backlog(
        cycle_dir: &Path,
    ) -> Result<(Vec<serde_json::Value>, Vec<serde_json::Value>), String> {
        let mut all_backlog: Vec<serde_json::Value> = Vec::new();
        let mut all_coverage: Vec<serde_json::Value> = Vec::new();
        for lane in [
            ImplementLane::General,
            ImplementLane::Visual,
            ImplementLane::Advanced,
        ] {
            let file_name = Self::implement_result_file_for_lane(lane);
            let value = read_json_file(cycle_dir, file_name)?;
            let backlog = value
                .pointer("/failure_backlog")
                .and_then(|v| v.as_array())
                .ok_or_else(|| format!("{} 缺少 failure_backlog（重实现轮必须提供）", file_name))?;
            let coverage = value
                .pointer("/backlog_coverage")
                .and_then(|v| v.as_array())
                .ok_or_else(|| {
                    format!("{} 缺少 backlog_coverage（重实现轮必须提供）", file_name)
                })?;
            let summary = value
                .pointer("/backlog_coverage_summary")
                .and_then(|v| v.as_object())
                .ok_or_else(|| {
                    format!(
                        "{} 缺少 backlog_coverage_summary（重实现轮必须提供）",
                        file_name
                    )
                })?;
            for key in ["total", "done", "blocked", "not_done"] {
                if !summary
                    .get(key)
                    .and_then(|v| v.as_u64())
                    .map(|_| true)
                    .unwrap_or(false)
                {
                    return Err(format!(
                        "{}.backlog_coverage_summary.{} 必须是数字",
                        file_name, key
                    ));
                }
            }
            all_backlog.extend(backlog.iter().cloned());
            all_coverage.extend(coverage.iter().cloned());
        }
        Ok((all_backlog, all_coverage))
    }

    fn validate_implement_artifact(cycle_dir: &Path, verify_iteration: u32) -> Result<(), String> {
        if verify_iteration == 0 {
            return Ok(());
        }
        let (backlog, coverage) = Self::collect_reimplementation_backlog(cycle_dir)?;
        for (idx, item) in backlog.iter().enumerate() {
            let Some(obj) = item.as_object() else {
                return Err(format!("failure_backlog[{}] 必须是对象", idx));
            };
            let agent = obj
                .get("implementation_agent")
                .and_then(|v| v.as_str())
                .map(|v| v.trim().to_ascii_lowercase())
                .ok_or_else(|| {
                    format!("failure_backlog[{}].implementation_agent 缺失或非法", idx)
                })?;
            if !matches!(
                agent.as_str(),
                "implement_general" | "implement_visual" | "implement_advanced" | "unknown"
            ) {
                return Err(format!(
                    "failure_backlog[{}].implementation_agent 必须是 implement_general|implement_visual|implement_advanced|unknown",
                    idx
                ));
            }
        }
        let backlog_ids = collect_unique_ids(&backlog, &["id"], "failure_backlog")?;
        let coverage_ids = collect_unique_ids(&coverage, &["id", "item_id"], "backlog_coverage")?;
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
        let (backlog, _) = Self::collect_reimplementation_backlog(cycle_dir)?;
        let backlog_ids = collect_unique_ids(&backlog, &["id"], "failure_backlog")?;
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
            "plan" => Self::validate_plan_artifact(cycle_dir),
            "implement_general" | "implement_visual" | "implement_advanced" => {
                Self::validate_implement_artifact(cycle_dir, verify_iteration)
            }
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

    fn build_implement_lane_prompt(
        base_prompt: String,
        lane: ImplementLane,
        selected_lanes: &[ImplementLane],
        verify_iteration: u32,
    ) -> String {
        let ordered = selected_lanes
            .iter()
            .map(|item| item.as_str())
            .collect::<Vec<&str>>()
            .join(" -> ");
        let lane_guidance = match lane {
            ImplementLane::General => {
                "仅处理 plan.execution.json 中 implementation_agent=implement_general 的任务。"
            }
            ImplementLane::Visual => {
                "仅处理 plan.execution.json 中 implementation_agent=implement_visual 的任务。"
            }
            ImplementLane::Advanced => {
                "优先处理 verify/judge 失败项与 backlog 未完成项，可跨类别修复。"
            }
        };
        format!(
            "{}\n\n<system-reminder>implement lane={}；verify_iteration={}；本轮 lane 执行顺序={}。{} 若本 lane 无任务，允许保持最小改动并在对应 implement_*.result.json 说明。</system-reminder>\n",
            base_prompt,
            lane.as_str(),
            verify_iteration,
            ordered,
            lane_guidance
        )
    }

    fn map_failed_agents_from_results(
        cycle_dir: &Path,
        tables: &PlanRoutingTables,
    ) -> Result<Option<HashSet<PlanImplementationAgent>>, String> {
        let verify = read_json_file(cycle_dir, "verify.result.json")?;
        let judge = read_json_file(cycle_dir, "judge.result.json")?;

        let mut failed_criteria_ids: Vec<String> = Vec::new();
        if let Some(items) = verify
            .pointer("/acceptance_evaluation")
            .and_then(|v| v.as_array())
        {
            for item in items {
                let Some(status) = item.get("status").and_then(|v| v.as_str()) else {
                    continue;
                };
                if !is_criteria_failure_status(status) {
                    continue;
                }
                if let Some(criteria_id) = id_from_value(item, &["criteria_id"]) {
                    failed_criteria_ids.push(criteria_id);
                }
            }
        }
        if let Some(items) = judge
            .pointer("/criteria_judgement")
            .and_then(|v| v.as_array())
        {
            for item in items {
                let Some(status) = item.get("status").and_then(|v| v.as_str()) else {
                    continue;
                };
                if !is_criteria_failure_status(status) {
                    continue;
                }
                if let Some(criteria_id) = id_from_value(item, &["criteria_id"]) {
                    failed_criteria_ids.push(criteria_id);
                }
            }
        }

        let mut failed_carryover_ids: Vec<String> = Vec::new();
        if let Some(items) = verify
            .pointer("/carryover_verification/items")
            .and_then(|v| v.as_array())
        {
            for item in items {
                let status = item
                    .get("status")
                    .and_then(|v| v.as_str())
                    .unwrap_or("missing");
                if !is_carryover_failure_status(status) {
                    continue;
                }
                if let Some(item_id) = id_from_value(item, &["id", "item_id", "criteria_id"]) {
                    failed_carryover_ids.push(item_id);
                }
            }
        }

        let mut mapped_agents: HashSet<PlanImplementationAgent> = HashSet::new();
        let mut incomplete_mapping = false;
        let mut has_failure_signal = false;

        for criteria_id in failed_criteria_ids {
            has_failure_signal = true;
            let Some(check_ids) = tables.criteria_to_checks.get(&criteria_id) else {
                incomplete_mapping = true;
                continue;
            };
            let mut mapped_in_this_criteria = false;
            for check_id in check_ids {
                if let Some(agents) = tables.check_to_agents.get(check_id) {
                    mapped_agents.extend(agents.iter().copied());
                    mapped_in_this_criteria = true;
                } else {
                    incomplete_mapping = true;
                }
            }
            if !mapped_in_this_criteria {
                incomplete_mapping = true;
            }
        }

        for item_id in failed_carryover_ids {
            has_failure_signal = true;
            let mut item_mapped = false;

            if let Some(agents) = tables.check_to_agents.get(&item_id) {
                mapped_agents.extend(agents.iter().copied());
                item_mapped = true;
            }

            if let Some(check_ids) = tables.criteria_to_checks.get(&item_id) {
                let mut criteria_mapped = false;
                for check_id in check_ids {
                    if let Some(agents) = tables.check_to_agents.get(check_id) {
                        mapped_agents.extend(agents.iter().copied());
                        criteria_mapped = true;
                    } else {
                        incomplete_mapping = true;
                    }
                }
                if criteria_mapped {
                    item_mapped = true;
                } else {
                    incomplete_mapping = true;
                }
            }

            if !item_mapped {
                incomplete_mapping = true;
            }
        }

        if !has_failure_signal || mapped_agents.is_empty() || incomplete_mapping {
            return Ok(None);
        }
        Ok(Some(mapped_agents))
    }

    fn resolve_implement_lanes(
        cycle_dir: &Path,
        verify_iteration: u32,
    ) -> Result<Vec<ImplementLane>, String> {
        if verify_iteration >= 2 {
            return Ok(vec![ImplementLane::Advanced]);
        }

        let plan = read_json_file(cycle_dir, "plan.execution.json")?;
        let tables = parse_plan_routing_tables(&plan)?;

        if verify_iteration == 0 {
            return Ok(ordered_lanes_from_agent_presence(&tables.lane_presence));
        }

        let failed_agents = match Self::map_failed_agents_from_results(cycle_dir, &tables) {
            Ok(value) => value,
            Err(err) => {
                warn!(
                    "failed to map reimplementation categories, fallback to general: {}",
                    err
                );
                None
            }
        };
        if let Some(agents) = failed_agents {
            return Ok(ordered_lanes_from_agent_presence(&agents));
        }

        // verify_iteration=1 且失败项无法完成映射：按约定回退为仅 general。
        Ok(vec![ImplementLane::General])
    }

    fn lane_for_stage(stage: &str) -> Option<ImplementLane> {
        match stage {
            "implement_general" => Some(ImplementLane::General),
            "implement_visual" => Some(ImplementLane::Visual),
            "implement_advanced" => Some(ImplementLane::Advanced),
            _ => None,
        }
    }

    fn stage_for_lane(lane: ImplementLane) -> &'static str {
        match lane {
            ImplementLane::General => "implement_general",
            ImplementLane::Visual => "implement_visual",
            ImplementLane::Advanced => "implement_advanced",
        }
    }

    fn should_execute_stage_for_lanes(stage: &str, lanes: &[ImplementLane]) -> bool {
        let Some(target_lane) = Self::lane_for_stage(stage) else {
            return true;
        };
        lanes.iter().any(|lane| *lane == target_lane)
    }

    fn persist_empty_implement_result_file(
        cycle_dir: &Path,
        stage: &str,
        verify_iteration: u32,
        status: &str,
    ) -> Result<(), String> {
        let Some(file_name) = Self::implement_result_file_for_stage(stage) else {
            return Ok(());
        };
        let payload = serde_json::json!({
            "$schema_version": "1.0",
            "stage": stage,
            "status": status,
            "verify_iteration": verify_iteration,
            "failure_backlog": [],
            "backlog_coverage": [],
            "backlog_coverage_summary": {
                "total": 0,
                "done": 0,
                "blocked": 0,
                "not_done": 0
            },
            "updated_at": Utc::now().to_rfc3339(),
        });
        write_json(&cycle_dir.join(file_name), &payload)
    }

    fn ensure_implement_result_placeholders(
        cycle_dir: &Path,
        verify_iteration: u32,
        selected_lanes: &[ImplementLane],
    ) -> Result<(), String> {
        for lane in [
            ImplementLane::General,
            ImplementLane::Visual,
            ImplementLane::Advanced,
        ] {
            if selected_lanes.iter().any(|item| *item == lane) {
                continue;
            }
            let stage = Self::stage_for_lane(lane);
            Self::persist_empty_implement_result_file(
                cycle_dir,
                stage,
                verify_iteration,
                "skipped",
            )?;
        }
        Ok(())
    }

    async fn run_stage_session_once(
        &self,
        key: &str,
        project: &str,
        workspace: &str,
        cycle_id: &str,
        stage: &str,
        profile: crate::server::protocol::EvolutionStageProfileInfo,
        prompt: String,
        ctx: &HandlerContext,
    ) -> Result<StageRunContext, String> {
        let ai_tool = profile.ai_tool.clone();
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

        let model = profile.model.as_ref().map(|m| AiModelSelection {
            provider_id: m.provider_id.clone(),
            model_id: m.model_id.clone(),
        });
        let mode = profile.mode.clone();
        let config_overrides = sanitize_ai_config_options(&profile.config_options);

        let stream = agent
            .send_message_with_config(
                &directory,
                &session.id,
                &prompt,
                None,
                None,
                None,
                model.clone(),
                mode.clone(),
                config_overrides.clone(),
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

        Ok(StageRunContext {
            ai_tool,
            session_id: session.id,
            directory,
            agent,
            model,
            mode,
            config_overrides,
        })
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
        matches!(
            stage,
            "plan"
                | "implement_general"
                | "implement_visual"
                | "implement_advanced"
                | "verify"
                | "judge"
        )
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
                    crate::ai::AiEvent::Done { stop_reason } => {
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
                                stop_reason,
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
                                        config_options: hint.config_options,
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
                    crate::ai::AiEvent::SessionConfigOptionsUpdated { .. } => {}
                    crate::ai::AiEvent::SlashCommandsUpdated { .. } => {}
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
        config_overrides: Option<std::collections::HashMap<String, serde_json::Value>>,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        let reminder = Self::build_validation_reminder_message(stage, validation_err);
        let stream = agent
            .send_message_with_config(
                directory,
                session_id,
                &reminder,
                None,
                None,
                None,
                model,
                mode,
                config_overrides,
            )
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
        let (verify_iteration, workspace_root, stage_profile) = {
            let state = self.state.lock().await;
            let entry = state
                .workspaces
                .get(key)
                .ok_or_else(|| "workspace state missing".to_string())?;
            (
                entry.verify_iteration,
                entry.workspace_root.clone(),
                profile_for_stage(&entry.stage_profiles, stage),
            )
        };

        let cycle_dir = cycle_dir_path(&workspace_root, cycle_id)?;
        let implement_lanes = if Self::lane_for_stage(stage).is_some() {
            let lanes = Self::resolve_implement_lanes(&cycle_dir, verify_iteration)?;
            Self::ensure_implement_result_placeholders(&cycle_dir, verify_iteration, &lanes)?;
            Some(lanes)
        } else {
            None
        };

        if let Some(lanes) = implement_lanes.as_ref() {
            if !Self::should_execute_stage_for_lanes(stage, lanes) {
                self.reset_stage_tool_call_tracking(key, stage).await;
                self.set_stage_status(key, stage, "skipped").await;
                self.persist_stage_file(key, stage, "skipped", None, None)
                    .await
                    .ok();
                Self::persist_empty_implement_result_file(
                    &cycle_dir,
                    stage,
                    verify_iteration,
                    "skipped",
                )?;
                self.persist_cycle_file(key).await.ok();
                self.broadcast_cycle_update(key, ctx, "orchestrator").await;
                return Ok(false);
            }
        }

        self.set_stage_status(key, stage, "running").await;
        self.reset_stage_tool_call_tracking(key, stage).await;
        self.persist_cycle_file(key).await.ok();
        self.persist_stage_file(key, stage, "running", None, None)
            .await
            .ok();
        self.broadcast_cycle_update(key, ctx, "orchestrator").await;

        let prompt = if let Some(lanes) = implement_lanes.as_ref() {
            let lane = Self::lane_for_stage(stage)
                .ok_or_else(|| format!("invalid implement stage: {}", stage))?;
            let base_prompt = self
                .build_stage_prompt(key, project, workspace, cycle_id, stage, round)
                .await?;
            Self::build_implement_lane_prompt(base_prompt, lane, lanes, verify_iteration)
        } else {
            self.build_stage_prompt(key, project, workspace, cycle_id, stage, round)
                .await?
        };
        let run_ctx = self
            .run_stage_session_once(
                key,
                project,
                workspace,
                cycle_id,
                stage,
                stage_profile,
                prompt,
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
                            &run_ctx.ai_tool,
                            &run_ctx.session_id,
                            &run_ctx.directory,
                            &run_ctx.agent,
                            &validation_err,
                            run_ctx.model.clone(),
                            run_ctx.mode.clone(),
                            run_ctx.config_overrides.clone(),
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

        if let Some(file_name) = Self::implement_result_file_for_stage(stage) {
            let path = cycle_dir.join(file_name);
            if !path.exists() {
                Self::persist_empty_implement_result_file(
                    &cycle_dir,
                    stage,
                    verify_iteration,
                    "done",
                )?;
            }
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
                "plan" => next_stage = "implement_general".to_string(),
                "implement_general" => {
                    let lanes = cycle_dir_path(&entry.workspace_root, &entry.cycle_id)
                        .ok()
                        .and_then(|dir| {
                            Self::resolve_implement_lanes(&dir, entry.verify_iteration).ok()
                        })
                        .unwrap_or_else(|| vec![ImplementLane::General, ImplementLane::Visual]);
                    let has_visual = lanes.iter().any(|lane| *lane == ImplementLane::Visual);
                    let has_advanced = lanes.iter().any(|lane| *lane == ImplementLane::Advanced);
                    if has_visual {
                        next_stage = "implement_visual".to_string();
                    } else if has_advanced {
                        entry
                            .stage_statuses
                            .insert("implement_visual".to_string(), "skipped".to_string());
                        entry
                            .stage_tool_call_counts
                            .insert("implement_visual".to_string(), 0);
                        next_stage = "implement_advanced".to_string();
                    } else {
                        entry
                            .stage_statuses
                            .insert("implement_visual".to_string(), "skipped".to_string());
                        entry
                            .stage_tool_call_counts
                            .insert("implement_visual".to_string(), 0);
                        entry
                            .stage_statuses
                            .insert("implement_advanced".to_string(), "skipped".to_string());
                        entry
                            .stage_tool_call_counts
                            .insert("implement_advanced".to_string(), 0);
                        next_stage = "verify".to_string();
                    }
                }
                "implement_visual" => {
                    entry
                        .stage_statuses
                        .insert("implement_advanced".to_string(), "skipped".to_string());
                    entry
                        .stage_tool_call_counts
                        .insert("implement_advanced".to_string(), 0);
                    next_stage = "verify".to_string();
                }
                "implement_advanced" => next_stage = "verify".to_string(),
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
                        for stage_name in [
                            "implement_general",
                            "implement_visual",
                            "implement_advanced",
                            "verify",
                            "judge",
                        ] {
                            entry
                                .stage_statuses
                                .insert(stage_name.to_string(), "pending".to_string());
                            entry
                                .stage_tool_call_counts
                                .insert(stage_name.to_string(), 0);
                        }
                        let lanes = match cycle_dir_path(&entry.workspace_root, &entry.cycle_id) {
                            Ok(cycle_dir) => match Self::resolve_implement_lanes(
                                &cycle_dir,
                                entry.verify_iteration,
                            ) {
                                Ok(value) => value,
                                Err(err) => {
                                    warn!(
                                        "resolve implement lanes failed (project={}, workspace={}, verify_iteration={}): {}",
                                        entry.project,
                                        entry.workspace,
                                        entry.verify_iteration,
                                        err
                                    );
                                    vec![ImplementLane::General]
                                }
                            },
                            Err(err) => {
                                warn!(
                                    "resolve cycle dir failed (project={}, workspace={}): {}",
                                    entry.project, entry.workspace, err
                                );
                                vec![ImplementLane::General]
                            }
                        };
                        emit_judge = Some((
                            entry.project.clone(),
                            entry.workspace.clone(),
                            entry.cycle_id.clone(),
                            "fail".to_string(),
                        ));
                        let has_general_or_visual = lanes.iter().any(|lane| {
                            matches!(lane, ImplementLane::General | ImplementLane::Visual)
                        });
                        let has_advanced =
                            lanes.iter().any(|lane| *lane == ImplementLane::Advanced);
                        if has_general_or_visual {
                            next_stage = "implement_general".to_string();
                        } else if has_advanced {
                            next_stage = "implement_advanced".to_string();
                        } else {
                            next_stage = "implement_general".to_string();
                        }
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
                    entry.rate_limit_resume_at = None;
                    entry.rate_limit_error_message = None;
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
                        "goto_stage:implement_general".to_string()
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
        EvolutionManager, ImplementLane,
    };
    use std::path::Path;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::Arc;
    use tempfile::tempdir;
    use tokio::time::Duration;

    fn write_json(path: &std::path::Path, value: serde_json::Value) {
        let content = serde_json::to_string_pretty(&value).expect("serialize json failed");
        std::fs::write(path, content).expect("write json failed");
    }

    fn base_plan_json(work_items: Vec<serde_json::Value>) -> serde_json::Value {
        serde_json::json!({
            "$schema_version": "1.0",
            "cycle_id": "c-1",
            "selected_direction_type": "architecture",
            "goal": "demo",
            "scope": {"in": ["core"], "out": []},
            "work_items": work_items,
            "verification_plan": {
                "checks": [
                    {"id": "v-1"},
                    {"id": "v-2"}
                ],
                "acceptance_mapping": [
                    {"criteria_id": "ac-1", "check_ids": ["v-1"]},
                    {"criteria_id": "ac-2", "check_ids": ["v-2"]}
                ]
            }
        })
    }

    fn base_implement_result_json(
        backlog: Vec<serde_json::Value>,
        coverage: Vec<serde_json::Value>,
    ) -> serde_json::Value {
        let total = backlog.len() as u64;
        let done = coverage
            .iter()
            .filter(|item| item.get("status").and_then(|v| v.as_str()) == Some("done"))
            .count() as u64;
        let blocked = coverage
            .iter()
            .filter(|item| item.get("status").and_then(|v| v.as_str()) == Some("blocked"))
            .count() as u64;
        let not_done = coverage
            .iter()
            .filter(|item| item.get("status").and_then(|v| v.as_str()) == Some("not_done"))
            .count() as u64;
        serde_json::json!({
            "failure_backlog": backlog,
            "backlog_coverage": coverage,
            "backlog_coverage_summary": {
                "total": total,
                "done": done,
                "blocked": blocked,
                "not_done": not_done
            }
        })
    }

    fn write_empty_implement_result_triplet(dir: &Path) {
        for file in [
            "implement_general.result.json",
            "implement_visual.result.json",
            "implement_advanced.result.json",
        ] {
            write_json(
                &dir.join(file),
                base_implement_result_json(Vec::new(), Vec::new()),
            );
        }
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
            "implement_visual",
            "evo_stage_output_invalid: x"
        ));
        assert!(EvolutionManager::should_retry_validation_with_reminder(
            "implement_advanced",
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
        assert!(EvolutionManager::should_retry_validation_with_reminder(
            "plan",
            "evo_stage_output_invalid: x"
        ));
        assert!(EvolutionManager::should_retry_validation_with_reminder(
            "implement_general",
            "evo_stage_output_invalid: x"
        ));
        assert!(!EvolutionManager::should_retry_validation_with_reminder(
            "judge",
            "stage stream timeout"
        ));
    }

    // ── 八阶段新约束回归测试 ──────────────────────────────────────────────

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
        // report 之后循环回 direction，确保八阶段闭环
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
        write_empty_implement_result_triplet(dir.path());
        write_json(
            &dir.path().join("implement_general.result.json"),
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
        let err = EvolutionManager::validate_stage_artifacts("implement_visual", dir.path(), 1)
            .expect_err("missing failure_backlog should fail");
        assert!(err.contains("failure_backlog"));
    }

    #[test]
    fn validate_stage_artifacts_should_validate_implement_general() {
        let dir = tempdir().expect("tempdir should succeed");
        write_empty_implement_result_triplet(dir.path());
        write_json(
            &dir.path().join("implement_general.result.json"),
            serde_json::json!({
                "failure_backlog": [],
                "backlog_coverage_summary": {
                    "total": 0,
                    "done": 0,
                    "blocked": 0,
                    "not_done": 0
                }
            }),
        );
        let err = EvolutionManager::validate_stage_artifacts("implement_general", dir.path(), 1)
            .expect_err("missing backlog_coverage should fail");
        assert!(err.contains("backlog_coverage"));
    }

    #[test]
    fn validate_stage_artifacts_should_reject_backlog_coverage_mismatch() {
        let dir = tempdir().expect("tempdir should succeed");
        write_empty_implement_result_triplet(dir.path());
        write_json(
            &dir.path().join("implement_general.result.json"),
            base_implement_result_json(
                vec![
                    serde_json::json!({"id": "f-1", "implementation_agent": "implement_general"}),
                    serde_json::json!({"id": "f-2", "implementation_agent": "implement_visual"}),
                ],
                vec![serde_json::json!({"id": "f-1", "status": "done"})],
            ),
        );
        let err = EvolutionManager::validate_stage_artifacts("implement_visual", dir.path(), 1)
            .expect_err("coverage mismatch should fail");
        assert!(err.contains("数量不一致"));
    }

    #[test]
    fn validate_stage_artifacts_should_reject_verify_missing_backlog_items() {
        let dir = tempdir().expect("tempdir should succeed");
        write_empty_implement_result_triplet(dir.path());
        write_json(
            &dir.path().join("implement_general.result.json"),
            base_implement_result_json(
                vec![
                    serde_json::json!({"id": "f-1", "implementation_agent": "implement_general"}),
                    serde_json::json!({"id": "f-2", "implementation_agent": "implement_general"}),
                ],
                vec![
                    serde_json::json!({"id": "f-1", "status": "done"}),
                    serde_json::json!({"id": "f-2", "status": "done"}),
                ],
            ),
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

    #[test]
    fn validate_plan_artifact_should_reject_missing_implementation_agent() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.execution.json"),
            base_plan_json(vec![serde_json::json!({
                "id": "w-1",
                "title": "x",
                "type": "code",
                "priority": "p0",
                "depends_on": [],
                "targets": ["core/src/lib.rs"],
                "definition_of_done": ["done"],
                "risk": "low",
                "rollback": "git restore",
                "linked_check_ids": ["v-1"]
            })]),
        );
        let err = EvolutionManager::validate_stage_artifacts("plan", dir.path(), 0)
            .expect_err("missing implementation_agent should fail");
        assert!(err.contains("implementation_agent"));
    }

    #[test]
    fn validate_plan_artifact_should_reject_invalid_agent() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.execution.json"),
            base_plan_json(vec![serde_json::json!({
                "id": "w-1",
                "title": "x",
                "type": "code",
                "priority": "p0",
                "depends_on": [],
                "targets": ["core/src/lib.rs"],
                "definition_of_done": ["done"],
                "risk": "low",
                "rollback": "git restore",
                "implementation_agent": "nonsense",
                "linked_check_ids": ["v-1"]
            })]),
        );
        let err = EvolutionManager::validate_stage_artifacts("plan", dir.path(), 0)
            .expect_err("invalid implementation_agent should fail");
        assert!(err.contains("implementation_agent"));
    }

    #[test]
    fn validate_plan_artifact_should_reject_missing_linked_check_ids() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.execution.json"),
            base_plan_json(vec![serde_json::json!({
                "id": "w-1",
                "title": "x",
                "type": "code",
                "priority": "p0",
                "depends_on": [],
                "targets": ["core/src/lib.rs"],
                "definition_of_done": ["done"],
                "risk": "low",
                "rollback": "git restore",
                "implementation_agent": "implement_general"
            })]),
        );
        let err = EvolutionManager::validate_stage_artifacts("plan", dir.path(), 0)
            .expect_err("missing linked_check_ids should fail");
        assert!(err.contains("linked_check_ids"));
    }

    #[test]
    fn validate_plan_artifact_should_reject_unknown_linked_check_id() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.execution.json"),
            base_plan_json(vec![serde_json::json!({
                "id": "w-1",
                "title": "x",
                "type": "code",
                "priority": "p0",
                "depends_on": [],
                "targets": ["core/src/lib.rs"],
                "definition_of_done": ["done"],
                "risk": "low",
                "rollback": "git restore",
                "implementation_agent": "implement_general",
                "linked_check_ids": ["v-404"]
            })]),
        );
        let err = EvolutionManager::validate_stage_artifacts("plan", dir.path(), 0)
            .expect_err("unknown linked_check_ids should fail");
        assert!(err.contains("未知 check_id"));
    }

    #[test]
    fn resolve_implement_lanes_should_use_general_only_on_first_iteration() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.execution.json"),
            base_plan_json(vec![
                serde_json::json!({
                    "id": "w-1",
                    "title": "x",
                    "type": "code",
                    "priority": "p0",
                    "depends_on": [],
                    "targets": ["core/src/lib.rs"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_agent": "implement_general",
                    "linked_check_ids": ["v-1"]
                }),
                serde_json::json!({
                    "id": "w-2",
                    "title": "y",
                    "type": "test",
                    "priority": "p1",
                    "depends_on": [],
                    "targets": ["core/tests/x.rs"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_agent": "implement_general",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        let lanes = EvolutionManager::resolve_implement_lanes(dir.path(), 0)
            .expect("lane resolve should succeed");
        assert_eq!(lanes, vec![ImplementLane::General]);
    }

    #[test]
    fn resolve_implement_lanes_should_use_visual_only_on_first_iteration() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.execution.json"),
            base_plan_json(vec![
                serde_json::json!({
                    "id": "w-1",
                    "title": "x",
                    "type": "code",
                    "priority": "p0",
                    "depends_on": [],
                    "targets": ["app/TidyFlow/View.swift"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_agent": "implement_visual",
                    "linked_check_ids": ["v-1"]
                }),
                serde_json::json!({
                    "id": "w-2",
                    "title": "y",
                    "type": "test",
                    "priority": "p1",
                    "depends_on": [],
                    "targets": ["app/TidyFlowTests/ViewTests.swift"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_agent": "implement_visual",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        let lanes = EvolutionManager::resolve_implement_lanes(dir.path(), 0)
            .expect("lane resolve should succeed");
        assert_eq!(lanes, vec![ImplementLane::Visual]);
    }

    #[test]
    fn resolve_implement_lanes_should_use_general_then_visual_on_first_iteration() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.execution.json"),
            base_plan_json(vec![
                serde_json::json!({
                    "id": "w-1",
                    "title": "x",
                    "type": "code",
                    "priority": "p0",
                    "depends_on": [],
                    "targets": ["core/src/lib.rs"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_agent": "implement_general",
                    "linked_check_ids": ["v-1"]
                }),
                serde_json::json!({
                    "id": "w-2",
                    "title": "y",
                    "type": "code",
                    "priority": "p1",
                    "depends_on": [],
                    "targets": ["app/TidyFlow/View.swift"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_agent": "implement_visual",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        let lanes = EvolutionManager::resolve_implement_lanes(dir.path(), 0)
            .expect("lane resolve should succeed");
        assert_eq!(lanes, vec![ImplementLane::General, ImplementLane::Visual]);
    }

    #[test]
    fn resolve_implement_lanes_should_map_only_general_on_reimplementation() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.execution.json"),
            base_plan_json(vec![
                serde_json::json!({
                    "id": "w-1",
                    "title": "x",
                    "type": "code",
                    "priority": "p0",
                    "depends_on": [],
                    "targets": ["core/src/lib.rs"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_agent": "implement_general",
                    "linked_check_ids": ["v-1"]
                }),
                serde_json::json!({
                    "id": "w-2",
                    "title": "y",
                    "type": "code",
                    "priority": "p1",
                    "depends_on": [],
                    "targets": ["app/TidyFlow/View.swift"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_agent": "implement_visual",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        write_json(
            &dir.path().join("verify.result.json"),
            serde_json::json!({
                "acceptance_evaluation": [{"criteria_id": "ac-1", "status": "fail"}],
                "carryover_verification": {"items": [], "summary": {"total": 0, "covered": 0, "missing": 0, "blocked": 0}}
            }),
        );
        write_json(
            &dir.path().join("judge.result.json"),
            serde_json::json!({
                "criteria_judgement": []
            }),
        );
        let lanes = EvolutionManager::resolve_implement_lanes(dir.path(), 1)
            .expect("lane resolve should succeed");
        assert_eq!(lanes, vec![ImplementLane::General]);
    }

    #[test]
    fn resolve_implement_lanes_should_map_only_visual_on_reimplementation() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.execution.json"),
            base_plan_json(vec![
                serde_json::json!({
                    "id": "w-1",
                    "title": "x",
                    "type": "code",
                    "priority": "p0",
                    "depends_on": [],
                    "targets": ["core/src/lib.rs"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_agent": "implement_general",
                    "linked_check_ids": ["v-1"]
                }),
                serde_json::json!({
                    "id": "w-2",
                    "title": "y",
                    "type": "code",
                    "priority": "p1",
                    "depends_on": [],
                    "targets": ["app/TidyFlow/View.swift"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_agent": "implement_visual",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        write_json(
            &dir.path().join("verify.result.json"),
            serde_json::json!({
                "acceptance_evaluation": [{"criteria_id": "ac-2", "status": "insufficient_evidence"}],
                "carryover_verification": {"items": [], "summary": {"total": 0, "covered": 0, "missing": 0, "blocked": 0}}
            }),
        );
        write_json(
            &dir.path().join("judge.result.json"),
            serde_json::json!({
                "criteria_judgement": []
            }),
        );
        let lanes = EvolutionManager::resolve_implement_lanes(dir.path(), 1)
            .expect("lane resolve should succeed");
        assert_eq!(lanes, vec![ImplementLane::Visual]);
    }

    #[test]
    fn resolve_implement_lanes_should_map_general_then_visual_on_reimplementation() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.execution.json"),
            base_plan_json(vec![
                serde_json::json!({
                    "id": "w-1",
                    "title": "x",
                    "type": "code",
                    "priority": "p0",
                    "depends_on": [],
                    "targets": ["core/src/lib.rs"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_agent": "implement_general",
                    "linked_check_ids": ["v-1"]
                }),
                serde_json::json!({
                    "id": "w-2",
                    "title": "y",
                    "type": "code",
                    "priority": "p1",
                    "depends_on": [],
                    "targets": ["app/TidyFlow/View.swift"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_agent": "implement_visual",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        write_json(
            &dir.path().join("verify.result.json"),
            serde_json::json!({
                "acceptance_evaluation": [{"criteria_id": "ac-1", "status": "fail"}],
                "carryover_verification": {"items": [{"id": "ac-2", "status": "missing"}], "summary": {"total": 1, "covered": 0, "missing": 1, "blocked": 0}}
            }),
        );
        write_json(
            &dir.path().join("judge.result.json"),
            serde_json::json!({
                "criteria_judgement": []
            }),
        );
        let lanes = EvolutionManager::resolve_implement_lanes(dir.path(), 1)
            .expect("lane resolve should succeed");
        assert_eq!(lanes, vec![ImplementLane::General, ImplementLane::Visual]);
    }

    #[test]
    fn resolve_implement_lanes_should_fallback_to_general_when_mapping_unknown() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.execution.json"),
            base_plan_json(vec![
                serde_json::json!({
                    "id": "w-1",
                    "title": "x",
                    "type": "code",
                    "priority": "p0",
                    "depends_on": [],
                    "targets": ["core/src/lib.rs"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_agent": "implement_general",
                    "linked_check_ids": ["v-1"]
                }),
                serde_json::json!({
                    "id": "w-2",
                    "title": "y",
                    "type": "code",
                    "priority": "p1",
                    "depends_on": [],
                    "targets": ["app/TidyFlow/View.swift"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_agent": "implement_visual",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        write_json(
            &dir.path().join("verify.result.json"),
            serde_json::json!({
                "acceptance_evaluation": [{"criteria_id": "ac-404", "status": "fail"}],
                "carryover_verification": {"items": [], "summary": {"total": 0, "covered": 0, "missing": 0, "blocked": 0}}
            }),
        );
        write_json(
            &dir.path().join("judge.result.json"),
            serde_json::json!({
                "criteria_judgement": []
            }),
        );
        let lanes = EvolutionManager::resolve_implement_lanes(dir.path(), 1)
            .expect("lane resolve should succeed");
        assert_eq!(lanes, vec![ImplementLane::General]);
    }

    #[test]
    fn resolve_implement_lanes_should_use_advanced_after_second_reimplementation() {
        let dir = tempdir().expect("tempdir should succeed");
        let lanes = EvolutionManager::resolve_implement_lanes(dir.path(), 2)
            .expect("advanced lane resolve should succeed");
        assert_eq!(lanes, vec![ImplementLane::Advanced]);
    }

    #[test]
    fn validate_implement_artifact_should_reject_invalid_failure_backlog_agent() {
        let dir = tempdir().expect("tempdir should succeed");
        write_empty_implement_result_triplet(dir.path());
        write_json(
            &dir.path().join("implement_general.result.json"),
            base_implement_result_json(
                vec![serde_json::json!({"id": "f-1", "implementation_agent": "advanced"})],
                vec![serde_json::json!({"id": "f-1", "status": "done"})],
            ),
        );
        let err = EvolutionManager::validate_stage_artifacts("implement_visual", dir.path(), 1)
            .expect_err("invalid failure_backlog implementation_agent should fail");
        assert!(err.contains("implementation_agent"));
    }
}
