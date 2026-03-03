use chrono::Utc;
use futures::StreamExt;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use tokio::time::{sleep, timeout, Duration};
use tracing::{info, warn};
use uuid::Uuid;

use crate::ai::{AiAgent, AiModelSelection, AiQuestionRequest};
use crate::server::context::HandlerContext;
use crate::server::handlers::ai::{
    apply_stream_snapshot_cache_op, build_ai_session_messages_update, ensure_agent,
    infer_selection_hint_from_messages, map_ai_messages_for_wire, map_ai_selection_hint_to_wire,
    mark_stream_snapshot_terminal, merge_session_selection_hint, normalize_part_for_wire,
    resolve_directory, seed_stream_snapshot, split_utf8_text_by_max_bytes, stream_key,
};
use crate::server::protocol::{AIGitCommit, ServerMessage};

use super::profile::profile_for_stage;
use super::utils::{cycle_dir_path, write_json};
use super::{EvolutionManager, MAX_STAGE_RUNTIME_SECS, STAGES};

const VALIDATION_REMINDER_MAX_RETRIES: u32 = 2;
const IMPLEMENT_CONFIG_RESERVED_PREFIX: &str = "__evo_internal_";
const STAGE_STREAM_IDLE_TIMEOUT_SECS: u64 = 600;
const STAGE_STREAM_IDLE_RECOVERY_MAX_ATTEMPTS: u32 = 2;
const STAGE_STREAM_IDLE_RECOVERY_COOLDOWN_MS: u64 = 800;
const STAGE_STREAM_IDLE_RECOVERY_MESSAGE: &str = "继续";
const MANAGED_FAILURE_BACKLOG_FILE: &str = "managed.failure_backlog.json";
const MANAGED_BACKLOG_COVERAGE_FILE: &str = "managed.backlog_coverage.json";
const MAX_AI_SESSION_OP_TEXT_CHUNK_BYTES: usize = 120_000;

fn build_stage_part_updated_ops(
    message_id: String,
    part: crate::server::protocol::ai::PartInfo,
) -> Vec<crate::server::protocol::ai::AiSessionCacheOpInfo> {
    if let Some(text) = part.text.clone() {
        if text.len() > MAX_AI_SESSION_OP_TEXT_CHUNK_BYTES {
            let mut base_part = part.clone();
            base_part.text = None;
            let mut ops = vec![
                crate::server::protocol::ai::AiSessionCacheOpInfo::PartUpdated {
                    message_id: message_id.clone(),
                    part: base_part,
                },
            ];
            for chunk in split_utf8_text_by_max_bytes(&text, MAX_AI_SESSION_OP_TEXT_CHUNK_BYTES) {
                ops.push(
                    crate::server::protocol::ai::AiSessionCacheOpInfo::PartDelta {
                        message_id: message_id.clone(),
                        part_id: part.id.clone(),
                        part_type: part.part_type.clone(),
                        field: "text".to_string(),
                        delta: chunk,
                    },
                );
            }
            return ops;
        }
    }
    vec![crate::server::protocol::ai::AiSessionCacheOpInfo::PartUpdated { message_id, part }]
}

fn build_stage_part_delta_ops(
    message_id: String,
    part_id: String,
    part_type: String,
    field: String,
    delta: String,
) -> Vec<crate::server::protocol::ai::AiSessionCacheOpInfo> {
    if delta.len() <= MAX_AI_SESSION_OP_TEXT_CHUNK_BYTES {
        return vec![
            crate::server::protocol::ai::AiSessionCacheOpInfo::PartDelta {
                message_id,
                part_id,
                part_type,
                field,
                delta,
            },
        ];
    }
    split_utf8_text_by_max_bytes(&delta, MAX_AI_SESSION_OP_TEXT_CHUNK_BYTES)
        .into_iter()
        .map(
            |chunk| crate::server::protocol::ai::AiSessionCacheOpInfo::PartDelta {
                message_id: message_id.clone(),
                part_id: part_id.clone(),
                part_type: part_type.clone(),
                field: field.clone(),
                delta: chunk,
            },
        )
        .collect::<Vec<_>>()
}

fn should_attempt_idle_recovery(stall_recovery_attempts: u32) -> bool {
    // 对所有 AI 工具统一启用 idle 超时恢复，避免不同工具行为不一致。
    stall_recovery_attempts < STAGE_STREAM_IDLE_RECOVERY_MAX_ATTEMPTS
}

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

    fn as_str(self) -> &'static str {
        match self {
            Self::ImplementGeneral => "implement_general",
            Self::ImplementVisual => "implement_visual",
            Self::ImplementAdvanced => "implement_advanced",
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

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ManagedFailureBacklogFile {
    #[serde(rename = "$schema_version", default = "default_schema_version")]
    schema_version: String,
    cycle_id: String,
    verify_iteration: u32,
    items: Vec<ManagedFailureBacklogItem>,
    updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ManagedFailureBacklogItem {
    id: String,
    source_criteria_id: String,
    source_check_id: String,
    work_item_id: String,
    implementation_agent: String,
    #[serde(default)]
    requirement_ref: String,
    #[serde(default)]
    description: String,
    created_at: String,
    updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ManagedBacklogCoverageFile {
    #[serde(rename = "$schema_version", default = "default_schema_version")]
    schema_version: String,
    cycle_id: String,
    verify_iteration: u32,
    items: Vec<ManagedBacklogCoverageItem>,
    summary: ManagedBacklogCoverageSummary,
    updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ManagedBacklogCoverageItem {
    backlog_id: String,
    source_criteria_id: String,
    source_check_id: String,
    work_item_id: String,
    implementation_agent: String,
    status: String,
    #[serde(default)]
    evidence: serde_json::Value,
    #[serde(default)]
    notes: String,
    updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ManagedBacklogCoverageSummary {
    total: u64,
    done: u64,
    blocked: u64,
    not_done: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BacklogResolutionUpdate {
    source_criteria_id: String,
    source_check_id: String,
    work_item_id: String,
    implementation_agent: String,
    status: String,
    #[serde(default)]
    evidence: serde_json::Value,
    #[serde(default)]
    notes: String,
}

fn default_schema_version() -> String {
    "1.0".to_string()
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
    let mut lanes = Vec::with_capacity(3);
    if agent_presence.contains(&PlanImplementationAgent::ImplementGeneral) {
        lanes.push(ImplementLane::General);
    }
    if agent_presence.contains(&PlanImplementationAgent::ImplementVisual) {
        lanes.push(ImplementLane::Visual);
    }
    if agent_presence.contains(&PlanImplementationAgent::ImplementAdvanced) {
        lanes.push(ImplementLane::Advanced);
    }
    if lanes.is_empty() {
        lanes.push(ImplementLane::General);
    }
    lanes
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

fn should_start_next_round(status: &str, global_loop_round: u32, loop_round_limit: u32) -> bool {
    status == "completed" && global_loop_round < loop_round_limit
}

fn read_json_file(cycle_dir: &Path, file_name: &str) -> Result<serde_json::Value, String> {
    let path = cycle_dir.join(file_name);
    let content =
        std::fs::read_to_string(&path).map_err(|e| format!("读取 {} 失败: {}", file_name, e))?;
    serde_json::from_str::<serde_json::Value>(&content)
        .map_err(|e| format!("解析 {} 失败: {}", file_name, e))
}

fn parse_non_empty_string_field(value: Option<&serde_json::Value>) -> Option<String> {
    value
        .and_then(|v| v.as_str())
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

fn extract_cycle_title_from_direction_stage(stage_json: &serde_json::Value) -> Option<String> {
    parse_non_empty_string_field(stage_json.get("cycle_title")).or_else(|| {
        parse_non_empty_string_field(stage_json.pointer("/decision/context/selected_title"))
    })
}

fn git_repo_has_changes(workspace_root: &Path) -> Result<bool, String> {
    let output = Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(workspace_root)
        .output()
        .map_err(|e| format!("执行 git status 失败: {}", e))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(format!("git status 执行失败: {}", stderr));
    }
    Ok(!String::from_utf8_lossy(&output.stdout).trim().is_empty())
}

fn git_head_sha(workspace_root: &Path) -> Result<Option<String>, String> {
    let output = Command::new("git")
        .args(["rev-parse", "--verify", "HEAD"])
        .current_dir(workspace_root)
        .output()
        .map_err(|e| format!("执行 git rev-parse 失败: {}", e))?;
    if !output.status.success() {
        return Ok(None);
    }
    let sha = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if sha.is_empty() {
        Ok(None)
    } else {
        Ok(Some(sha))
    }
}

fn collect_commits_between(
    workspace_root: &Path,
    before: Option<&str>,
    after: Option<&str>,
) -> Result<Vec<AIGitCommit>, String> {
    let Some(after_sha) = after else {
        return Ok(Vec::new());
    };
    if before == Some(after_sha) {
        return Ok(Vec::new());
    }

    let rev_list_output = if let Some(before_sha) = before {
        Command::new("git")
            .args([
                "rev-list",
                "--reverse",
                &format!("{}..{}", before_sha, after_sha),
            ])
            .current_dir(workspace_root)
            .output()
            .map_err(|e| format!("执行 git rev-list 失败: {}", e))?
    } else {
        Command::new("git")
            .args(["rev-list", "--reverse", after_sha])
            .current_dir(workspace_root)
            .output()
            .map_err(|e| format!("执行 git rev-list 失败: {}", e))?
    };
    if !rev_list_output.status.success() {
        let stderr = String::from_utf8_lossy(&rev_list_output.stderr)
            .trim()
            .to_string();
        return Err(format!("git rev-list 执行失败: {}", stderr));
    }

    let shas: Vec<String> = String::from_utf8_lossy(&rev_list_output.stdout)
        .lines()
        .map(|line| line.trim().to_string())
        .filter(|line| !line.is_empty())
        .collect();
    if shas.is_empty() {
        return Ok(Vec::new());
    }

    let mut commits: Vec<AIGitCommit> = Vec::with_capacity(shas.len());
    for sha in shas {
        let output = Command::new("git")
            .args([
                "show",
                "--name-only",
                "--pretty=format:%h%x1f%s",
                "-n",
                "1",
                &sha,
            ])
            .current_dir(workspace_root)
            .output()
            .map_err(|e| format!("执行 git show 失败: {}", e))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            return Err(format!("git show 执行失败: {}", stderr));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut lines = stdout.lines();
        let header = lines.next().unwrap_or_default();
        let mut header_parts = header.splitn(2, '\u{1f}');
        let short_sha = header_parts.next().unwrap_or_default().trim().to_string();
        let message = header_parts.next().unwrap_or_default().trim().to_string();
        let files: Vec<String> = lines
            .map(|line| line.trim().to_string())
            .filter(|line| !line.is_empty())
            .collect();

        commits.push(AIGitCommit {
            sha: if short_sha.is_empty() {
                sha.chars().take(7).collect::<String>()
            } else {
                short_sha
            },
            message,
            files,
        });
    }

    Ok(commits)
}

/// 从 judge.result.json 的 full_next_iteration_requirements 中提取需求项列表。
/// 兼容三种格式：
/// 1. 直接数组 `[...]`
/// 2. 对象 `{"items": [...]}`
/// 3. 对象 `{"acceptance_failures": [...], "carryover_failures": [...]}`
fn extract_judge_requirements(judge: &serde_json::Value) -> Option<Vec<serde_json::Value>> {
    let fnir = judge.pointer("/full_next_iteration_requirements")?;

    // 格式 1: 直接数组
    if let Some(arr) = fnir.as_array() {
        return Some(arr.clone());
    }

    // 格式 2: {"items": [...]}
    if let Some(arr) = fnir.pointer("/items").and_then(|v| v.as_array()) {
        return Some(arr.clone());
    }

    // 格式 3: {"acceptance_failures": [...], "carryover_failures": [...]}
    let mut items = Vec::new();
    for key in &["acceptance_failures", "carryover_failures"] {
        if let Some(arr) = fnir.get(*key).and_then(|v| v.as_array()) {
            for item in arr {
                // check_ids (数组) 展开为每个 check_id 一条独立项
                if let Some(check_ids) = item.get("check_ids").and_then(|v| v.as_array()) {
                    if check_ids.is_empty() {
                        items.push(item.clone());
                    } else {
                        for cid in check_ids {
                            let mut expanded = item.clone();
                            if let Some(obj) = expanded.as_object_mut() {
                                obj.remove("check_ids");
                                obj.insert("check_id".to_string(), cid.clone());
                            }
                            items.push(expanded);
                        }
                    }
                } else {
                    items.push(item.clone());
                }
            }
        }
    }

    if items.is_empty() {
        None
    } else {
        Some(items)
    }
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

fn is_valid_implementation_agent(agent: &str) -> bool {
    matches!(
        agent.trim().to_ascii_lowercase().as_str(),
        "implement_general" | "implement_visual" | "implement_advanced" | "unknown"
    )
}

fn backlog_contract_version_from_cycle(cycle_dir: &Path) -> Result<u32, String> {
    let cycle = read_json_file(cycle_dir, "cycle.json")?;
    let version = cycle
        .get("backlog_contract_version")
        .and_then(|v| v.as_u64())
        .unwrap_or(1) as u32;
    Ok(version)
}

fn managed_failure_backlog_path(cycle_dir: &Path) -> PathBuf {
    cycle_dir.join(MANAGED_FAILURE_BACKLOG_FILE)
}

fn managed_backlog_coverage_path(cycle_dir: &Path) -> PathBuf {
    cycle_dir.join(MANAGED_BACKLOG_COVERAGE_FILE)
}

fn normalize_backlog_status(status: &str) -> Option<&'static str> {
    match status.trim().to_ascii_lowercase().as_str() {
        "done" => Some("done"),
        "blocked" => Some("blocked"),
        "not_done" | "notdone" | "missing" => Some("not_done"),
        _ => None,
    }
}

fn coverage_summary(items: &[ManagedBacklogCoverageItem]) -> ManagedBacklogCoverageSummary {
    let total = items.len() as u64;
    let done = items
        .iter()
        .filter(|item| item.status.eq_ignore_ascii_case("done"))
        .count() as u64;
    let blocked = items
        .iter()
        .filter(|item| item.status.eq_ignore_ascii_case("blocked"))
        .count() as u64;
    let not_done = total.saturating_sub(done).saturating_sub(blocked);
    ManagedBacklogCoverageSummary {
        total,
        done,
        blocked,
        not_done,
    }
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

    fn preferred_agent_from_set(
        agents: &HashSet<PlanImplementationAgent>,
    ) -> Option<PlanImplementationAgent> {
        if agents.contains(&PlanImplementationAgent::ImplementGeneral) {
            return Some(PlanImplementationAgent::ImplementGeneral);
        }
        if agents.contains(&PlanImplementationAgent::ImplementVisual) {
            return Some(PlanImplementationAgent::ImplementVisual);
        }
        if agents.contains(&PlanImplementationAgent::ImplementAdvanced) {
            return Some(PlanImplementationAgent::ImplementAdvanced);
        }
        None
    }

    fn parse_check_to_work_items(
        plan: &serde_json::Value,
    ) -> Result<HashMap<String, Vec<(String, PlanImplementationAgent)>>, String> {
        let work_items = plan
            .pointer("/work_items")
            .and_then(|v| v.as_array())
            .ok_or_else(|| "plan.execution.json 缺少 work_items".to_string())?;
        let mut mapping: HashMap<String, Vec<(String, PlanImplementationAgent)>> = HashMap::new();
        for (idx, item) in work_items.iter().enumerate() {
            let obj = item
                .as_object()
                .ok_or_else(|| format!("work_items[{}] 必须是对象", idx))?;
            let work_item_id = obj
                .get("id")
                .and_then(parse_non_empty_string)
                .ok_or_else(|| format!("work_items[{}] 缺少 id", idx))?;
            let agent = obj
                .get("implementation_agent")
                .and_then(|v| v.as_str())
                .and_then(PlanImplementationAgent::parse)
                .ok_or_else(|| format!("work_items[{}].implementation_agent 缺失或非法", idx))?;
            let check_ids = obj
                .get("linked_check_ids")
                .and_then(|v| v.as_array())
                .ok_or_else(|| format!("work_items[{}] 缺少 linked_check_ids", idx))?;
            for (check_idx, check_id) in check_ids.iter().enumerate() {
                let check_id = check_id
                    .as_str()
                    .map(|v| v.trim().to_string())
                    .filter(|v| !v.is_empty())
                    .ok_or_else(|| {
                        format!(
                            "work_items[{}].linked_check_ids[{}] 必须是非空字符串",
                            idx, check_idx
                        )
                    })?;
                mapping
                    .entry(check_id)
                    .or_default()
                    .push((work_item_id.clone(), agent));
            }
        }
        Ok(mapping)
    }

    fn read_managed_failure_backlog(cycle_dir: &Path) -> Result<ManagedFailureBacklogFile, String> {
        let path = managed_failure_backlog_path(cycle_dir);
        let content = std::fs::read_to_string(&path)
            .map_err(|e| format!("读取 {} 失败: {}", MANAGED_FAILURE_BACKLOG_FILE, e))?;
        serde_json::from_str::<ManagedFailureBacklogFile>(&content)
            .map_err(|e| format!("解析 {} 失败: {}", MANAGED_FAILURE_BACKLOG_FILE, e))
    }

    fn write_managed_failure_backlog(
        cycle_dir: &Path,
        payload: &ManagedFailureBacklogFile,
    ) -> Result<(), String> {
        let value = serde_json::to_value(payload)
            .map_err(|e| format!("序列化 {} 失败: {}", MANAGED_FAILURE_BACKLOG_FILE, e))?;
        write_json(&managed_failure_backlog_path(cycle_dir), &value)
    }

    fn read_managed_backlog_coverage(
        cycle_dir: &Path,
    ) -> Result<ManagedBacklogCoverageFile, String> {
        let path = managed_backlog_coverage_path(cycle_dir);
        let content = std::fs::read_to_string(&path)
            .map_err(|e| format!("读取 {} 失败: {}", MANAGED_BACKLOG_COVERAGE_FILE, e))?;
        serde_json::from_str::<ManagedBacklogCoverageFile>(&content)
            .map_err(|e| format!("解析 {} 失败: {}", MANAGED_BACKLOG_COVERAGE_FILE, e))
    }

    fn write_managed_backlog_coverage(
        cycle_dir: &Path,
        payload: &ManagedBacklogCoverageFile,
    ) -> Result<(), String> {
        let value = serde_json::to_value(payload)
            .map_err(|e| format!("序列化 {} 失败: {}", MANAGED_BACKLOG_COVERAGE_FILE, e))?;
        write_json(&managed_backlog_coverage_path(cycle_dir), &value)
    }

    fn generate_managed_backlog_from_judge(
        cycle_dir: &Path,
        verify_iteration: u32,
    ) -> Result<(), String> {
        let plan = read_json_file(cycle_dir, "plan.execution.json")?;
        let tables = parse_plan_routing_tables(&plan)?;
        let check_to_work_items = Self::parse_check_to_work_items(&plan)?;
        let judge = read_json_file(cycle_dir, "judge.result.json")?;
        let requirements = extract_judge_requirements(&judge).ok_or_else(|| {
            "judge.result.json 缺少 full_next_iteration_requirements（重实现轮必须提供）"
                .to_string()
        })?;
        let cycle_id = read_json_file(cycle_dir, "cycle.json")?
            .get("cycle_id")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();

        let mut seen_selectors: HashSet<(String, String, String, String)> = HashSet::new();
        let mut backlog_items: Vec<ManagedFailureBacklogItem> = Vec::new();

        for (idx, requirement) in requirements.iter().enumerate() {
            let requirement_ref = id_from_value(
                requirement,
                &[
                    "id",
                    "item_id",
                    "criteria_id",
                    "title",
                    "check_id",
                    "source_check_id",
                ],
            )
            .unwrap_or_else(|| format!("requirement-{}", idx + 1));
            let source_criteria_id = id_from_value(
                requirement,
                &["source_criteria_id", "criteria_id", "criterion_id"],
            )
            .unwrap_or_else(|| "unknown".to_string());

            let mut source_check_id = id_from_value(
                requirement,
                &["source_check_id", "check_id", "linked_check_id"],
            );
            if source_check_id.is_none() {
                source_check_id = tables
                    .criteria_to_checks
                    .get(&source_criteria_id)
                    .and_then(|checks| checks.first().cloned());
            }
            let source_check_id = source_check_id.unwrap_or_else(|| "unknown".to_string());

            let mut agent_set: HashSet<PlanImplementationAgent> = HashSet::new();
            if let Some(agent) = requirement
                .get("implementation_agent")
                .and_then(|v| v.as_str())
                .and_then(PlanImplementationAgent::parse)
            {
                agent_set.insert(agent);
            } else {
                if let Some(mapped) = tables.check_to_agents.get(&source_check_id) {
                    agent_set.extend(mapped.iter().copied());
                }
                if let Some(checks) = tables.criteria_to_checks.get(&source_criteria_id) {
                    for check_id in checks {
                        if let Some(mapped) = tables.check_to_agents.get(check_id) {
                            agent_set.extend(mapped.iter().copied());
                        }
                    }
                }
            }
            let implementation_agent = Self::preferred_agent_from_set(&agent_set)
                .map(|agent| agent.as_str().to_string())
                .unwrap_or_else(|| "unknown".to_string());

            let mut work_item_id = id_from_value(requirement, &["work_item_id"]);
            if work_item_id.is_none() {
                if let Some(mapped_items) = check_to_work_items.get(&source_check_id) {
                    let preferred = mapped_items
                        .iter()
                        .find(|(_, agent)| agent.as_str() == implementation_agent)
                        .or_else(|| mapped_items.first());
                    work_item_id = preferred.map(|(id, _)| id.clone());
                }
            }
            let work_item_id =
                work_item_id.unwrap_or_else(|| format!("{}-wi", requirement_ref.clone()));

            let selector = (
                source_criteria_id.clone(),
                source_check_id.clone(),
                work_item_id.clone(),
                implementation_agent.clone(),
            );
            if !seen_selectors.insert(selector) {
                continue;
            }

            let now = Utc::now().to_rfc3339();
            backlog_items.push(ManagedFailureBacklogItem {
                id: Uuid::now_v7().to_string(),
                source_criteria_id,
                source_check_id,
                work_item_id,
                implementation_agent,
                requirement_ref,
                description: requirement
                    .get("description")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string(),
                created_at: now.clone(),
                updated_at: now,
            });
        }

        let coverage_items: Vec<ManagedBacklogCoverageItem> = backlog_items
            .iter()
            .map(|item| ManagedBacklogCoverageItem {
                backlog_id: item.id.clone(),
                source_criteria_id: item.source_criteria_id.clone(),
                source_check_id: item.source_check_id.clone(),
                work_item_id: item.work_item_id.clone(),
                implementation_agent: item.implementation_agent.clone(),
                status: "not_done".to_string(),
                evidence: serde_json::Value::Null,
                notes: String::new(),
                updated_at: Utc::now().to_rfc3339(),
            })
            .collect();
        let summary = coverage_summary(&coverage_items);
        let now = Utc::now().to_rfc3339();
        Self::write_managed_failure_backlog(
            cycle_dir,
            &ManagedFailureBacklogFile {
                schema_version: default_schema_version(),
                cycle_id: cycle_id.clone(),
                verify_iteration,
                items: backlog_items,
                updated_at: now.clone(),
            },
        )?;
        Self::write_managed_backlog_coverage(
            cycle_dir,
            &ManagedBacklogCoverageFile {
                schema_version: default_schema_version(),
                cycle_id,
                verify_iteration,
                items: coverage_items,
                summary,
                updated_at: now,
            },
        )?;
        Ok(())
    }

    fn sync_managed_backlog_for_implement_stage(
        cycle_dir: &Path,
        stage: &str,
    ) -> Result<(), String> {
        let Some(file_name) = Self::implement_result_file_for_stage(stage) else {
            return Ok(());
        };
        let Some(lane) = Self::lane_for_stage(stage) else {
            return Ok(());
        };
        let lane_name = lane.as_str();

        let mut managed_backlog = Self::read_managed_failure_backlog(cycle_dir)?;
        let mut managed_coverage = Self::read_managed_backlog_coverage(cycle_dir)?;
        let mut lane_result = read_json_file(cycle_dir, file_name)?;
        let updates = lane_result
            .pointer("/backlog_resolution_updates")
            .and_then(|v| v.as_array())
            .ok_or_else(|| format!("{}.backlog_resolution_updates 缺失", file_name))?;

        for (idx, item) in updates.iter().enumerate() {
            let parsed =
                serde_json::from_value::<BacklogResolutionUpdate>(item.clone()).map_err(|e| {
                    format!(
                        "{}.backlog_resolution_updates[{}] 非法: {}",
                        file_name, idx, e
                    )
                })?;
            if parsed.source_criteria_id.trim().is_empty()
                || parsed.source_check_id.trim().is_empty()
                || parsed.work_item_id.trim().is_empty()
            {
                return Err(format!(
                    "{}.backlog_resolution_updates[{}] selector 字段不能为空",
                    file_name, idx
                ));
            }
            if parsed.implementation_agent.trim() != lane_name {
                return Err(format!(
                    "{}.backlog_resolution_updates[{}].implementation_agent 必须等于 {}",
                    file_name, idx, lane_name
                ));
            }
            let Some(normalized_status) = normalize_backlog_status(&parsed.status) else {
                return Err(format!(
                    "{}.backlog_resolution_updates[{}].status 必须是 done|blocked|not_done",
                    file_name, idx
                ));
            };

            let matched_indexes = managed_backlog
                .items
                .iter()
                .enumerate()
                .filter(|(_, backlog)| {
                    backlog.source_criteria_id == parsed.source_criteria_id
                        && backlog.source_check_id == parsed.source_check_id
                        && backlog.work_item_id == parsed.work_item_id
                        && backlog.implementation_agent == parsed.implementation_agent
                })
                .map(|(i, _)| i)
                .collect::<Vec<usize>>();

            if matched_indexes.is_empty() {
                warn!(
                    "evo_backlog_mapping_missing: cycle_dir={}, stage={}, selector=({}, {}, {}, {}), candidates=0",
                    cycle_dir.display(),
                    stage,
                    parsed.source_criteria_id,
                    parsed.source_check_id,
                    parsed.work_item_id,
                    parsed.implementation_agent
                );
                return Err(format!(
                    "evo_backlog_mapping_missing: selector=({}, {}, {}, {}), candidates=0",
                    parsed.source_criteria_id,
                    parsed.source_check_id,
                    parsed.work_item_id,
                    parsed.implementation_agent
                ));
            }
            if matched_indexes.len() > 1 {
                warn!(
                    "evo_backlog_mapping_ambiguous: cycle_dir={}, stage={}, selector=({}, {}, {}, {}), candidates={}",
                    cycle_dir.display(),
                    stage,
                    parsed.source_criteria_id,
                    parsed.source_check_id,
                    parsed.work_item_id,
                    parsed.implementation_agent,
                    matched_indexes.len()
                );
                return Err(format!(
                    "evo_backlog_mapping_ambiguous: selector=({}, {}, {}, {}), candidates={}",
                    parsed.source_criteria_id,
                    parsed.source_check_id,
                    parsed.work_item_id,
                    parsed.implementation_agent,
                    matched_indexes.len()
                ));
            }
            let backlog_id = managed_backlog.items[matched_indexes[0]].id.clone();
            let coverage = managed_coverage
                .items
                .iter_mut()
                .find(|coverage| coverage.backlog_id == backlog_id)
                .ok_or_else(|| {
                    format!(
                        "managed.backlog_coverage 缺少 backlog_id={}（stage={}）",
                        backlog_id, stage
                    )
                })?;
            coverage.status = normalized_status.to_string();
            coverage.evidence = parsed.evidence;
            coverage.notes = parsed.notes;
            coverage.updated_at = Utc::now().to_rfc3339();
        }

        managed_coverage.summary = coverage_summary(&managed_coverage.items);
        managed_coverage.updated_at = Utc::now().to_rfc3339();
        Self::write_managed_backlog_coverage(cycle_dir, &managed_coverage)?;

        let lane_backlog = managed_backlog
            .items
            .iter()
            .filter(|item| item.implementation_agent == lane_name)
            .cloned()
            .collect::<Vec<ManagedFailureBacklogItem>>();
        let lane_ids: HashSet<String> = lane_backlog.iter().map(|item| item.id.clone()).collect();
        let lane_coverage = managed_coverage
            .items
            .iter()
            .filter(|item| lane_ids.contains(&item.backlog_id))
            .cloned()
            .collect::<Vec<ManagedBacklogCoverageItem>>();
        let lane_summary = coverage_summary(&lane_coverage);

        let lane_backlog_json = lane_backlog
            .iter()
            .map(|item| {
                serde_json::json!({
                    "id": item.id,
                    "source_criteria_id": item.source_criteria_id,
                    "source_check_id": item.source_check_id,
                    "work_item_id": item.work_item_id,
                    "implementation_agent": item.implementation_agent,
                    "description": item.description,
                    "requirement_ref": item.requirement_ref
                })
            })
            .collect::<Vec<serde_json::Value>>();
        let lane_coverage_json = lane_coverage
            .iter()
            .map(|item| {
                serde_json::json!({
                    "id": item.backlog_id,
                    "item_id": item.backlog_id,
                    "failure_backlog_id": item.backlog_id,
                    "backlog_id": item.backlog_id,
                    "source_criteria_id": item.source_criteria_id,
                    "source_check_id": item.source_check_id,
                    "work_item_id": item.work_item_id,
                    "implementation_agent": item.implementation_agent,
                    "status": item.status,
                    "evidence": item.evidence,
                    "notes": item.notes
                })
            })
            .collect::<Vec<serde_json::Value>>();

        let lane_obj = lane_result
            .as_object_mut()
            .ok_or_else(|| format!("{} 顶层必须是对象", file_name))?;
        lane_obj.insert(
            "failure_backlog".to_string(),
            serde_json::Value::Array(lane_backlog_json),
        );
        lane_obj.insert(
            "backlog_coverage".to_string(),
            serde_json::Value::Array(lane_coverage_json),
        );
        lane_obj.insert(
            "backlog_coverage_summary".to_string(),
            serde_json::json!({
                "total": lane_summary.total,
                "done": lane_summary.done,
                "blocked": lane_summary.blocked,
                "not_done": lane_summary.not_done
            }),
        );
        lane_obj.insert(
            "updated_at".to_string(),
            serde_json::Value::String(Utc::now().to_rfc3339()),
        );
        write_json(&cycle_dir.join(file_name), &lane_result)?;
        managed_backlog.updated_at = Utc::now().to_rfc3339();
        Self::write_managed_failure_backlog(cycle_dir, &managed_backlog)?;
        Ok(())
    }

    fn collect_reimplementation_backlog(
        cycle_dir: &Path,
        backlog_contract_version: u32,
    ) -> Result<(Vec<serde_json::Value>, Vec<serde_json::Value>), String> {
        if backlog_contract_version >= 2 {
            let backlog = Self::read_managed_failure_backlog(cycle_dir)?;
            let coverage = Self::read_managed_backlog_coverage(cycle_dir)?;
            let backlog_values = backlog
                .items
                .iter()
                .map(|item| {
                    serde_json::json!({
                        "id": item.id,
                        "source_criteria_id": item.source_criteria_id,
                        "source_check_id": item.source_check_id,
                        "work_item_id": item.work_item_id,
                        "implementation_agent": item.implementation_agent
                    })
                })
                .collect::<Vec<serde_json::Value>>();
            let coverage_values = coverage
                .items
                .iter()
                .map(|item| {
                    serde_json::json!({
                        "id": item.backlog_id,
                        "item_id": item.backlog_id,
                        "status": item.status
                    })
                })
                .collect::<Vec<serde_json::Value>>();
            return Ok((backlog_values, coverage_values));
        }

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

    fn validate_implement_artifact(
        cycle_dir: &Path,
        verify_iteration: u32,
        backlog_contract_version: u32,
    ) -> Result<(), String> {
        if verify_iteration == 0 {
            return Ok(());
        }
        if backlog_contract_version >= 2 {
            let backlog = Self::read_managed_failure_backlog(cycle_dir)?;
            let coverage = Self::read_managed_backlog_coverage(cycle_dir)?;
            let mut backlog_ids = HashSet::new();
            for (idx, item) in backlog.items.iter().enumerate() {
                if item.id.trim().is_empty() {
                    return Err(format!(
                        "managed.failure_backlog.items[{}].id 不能为空",
                        idx
                    ));
                }
                if !is_valid_implementation_agent(&item.implementation_agent) {
                    return Err(format!(
                        "managed.failure_backlog.items[{}].implementation_agent 必须是 implement_general|implement_visual|implement_advanced|unknown",
                        idx
                    ));
                }
                backlog_ids.insert(item.id.clone());
            }
            let mut coverage_ids = HashSet::new();
            for (idx, item) in coverage.items.iter().enumerate() {
                if item.backlog_id.trim().is_empty() {
                    return Err(format!(
                        "managed.backlog_coverage.items[{}].backlog_id 不能为空",
                        idx
                    ));
                }
                let Some(_) = normalize_backlog_status(&item.status) else {
                    return Err(format!(
                        "managed.backlog_coverage.items[{}].status 必须是 done|blocked|not_done",
                        idx
                    ));
                };
                coverage_ids.insert(item.backlog_id.clone());
            }
            if backlog_ids != coverage_ids {
                return Err("backlog_coverage 未完整覆盖 failure_backlog".to_string());
            }
            return Ok(());
        }

        let (backlog, coverage) =
            Self::collect_reimplementation_backlog(cycle_dir, backlog_contract_version)?;
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
            if !is_valid_implementation_agent(agent.as_str()) {
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

    fn validate_verify_artifact(
        cycle_dir: &Path,
        verify_iteration: u32,
        backlog_contract_version: u32,
    ) -> Result<(), String> {
        if verify_iteration == 0 {
            return Ok(());
        }
        let verify_value = read_json_file(cycle_dir, "verify.result.json")?;
        let (backlog, _) =
            Self::collect_reimplementation_backlog(cycle_dir, backlog_contract_version)?;
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

    fn validate_judge_artifact(
        cycle_dir: &Path,
        verify_iteration: u32,
        _backlog_contract_version: u32,
    ) -> Result<(), String> {
        if verify_iteration == 0 {
            return Ok(());
        }
        let judge_value = read_json_file(cycle_dir, "judge.result.json")?;
        let verify_value = read_json_file(cycle_dir, "verify.result.json")?;

        let requirements = extract_judge_requirements(&judge_value).ok_or_else(|| {
            "judge.result.json 缺少 full_next_iteration_requirements（重实现轮必须提供）"
                .to_string()
        })?;
        let requirement_ids = collect_unique_ids(
            &requirements,
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
        backlog_contract_version: u32,
    ) -> Result<(), String> {
        match stage {
            "plan" => Self::validate_plan_artifact(cycle_dir),
            "implement_general" | "implement_visual" | "implement_advanced" => {
                Self::validate_implement_artifact(
                    cycle_dir,
                    verify_iteration,
                    backlog_contract_version,
                )
            }
            "verify" => Self::validate_verify_artifact(
                cycle_dir,
                verify_iteration,
                backlog_contract_version,
            ),
            "judge" => {
                Self::validate_judge_artifact(cycle_dir, verify_iteration, backlog_contract_version)
            }
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

    async fn sync_cycle_title_from_direction_stage(
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
        let direction_stage = read_json_file(&cycle_dir, "stage.direction.json")?;
        let cycle_title = extract_cycle_title_from_direction_stage(&direction_stage);

        let mut state = self.state.lock().await;
        let Some(entry) = state.workspaces.get_mut(key) else {
            return Err("workspace state missing".to_string());
        };
        if entry.cycle_id != cycle_id {
            return Ok(());
        }
        entry.cycle_title = cycle_title;
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
        backlog_contract_version: u32,
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
            "backlog_contract_version": backlog_contract_version,
            "backlog_resolution_updates": [],
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
        backlog_contract_version: u32,
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
                backlog_contract_version,
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
        self.record_session_execution_started(key, stage, &ai_tool, &session.id)
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

        let stream = match agent
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
            .await
        {
            Ok(stream) => stream,
            Err(err) => {
                let tool_call_count = self.stage_tool_call_count(key, stage).await;
                self.finalize_session_execution(key, stage, &session.id, "failed", tool_call_count)
                    .await;
                return Err(err);
            }
        };
        if let Err(err) = self
            .consume_stage_stream(
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
                model.clone(),
                mode.clone(),
                config_overrides.clone(),
                ctx,
            )
            .await
        {
            let status = if err.starts_with("evo_human_blocking_required") {
                "blocked"
            } else {
                "failed"
            };
            let tool_call_count = self.stage_tool_call_count(key, stage).await;
            self.finalize_session_execution(key, stage, &session.id, status, tool_call_count)
                .await;
            return Err(err);
        }

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
        model: Option<AiModelSelection>,
        mode: Option<String>,
        config_overrides: Option<std::collections::HashMap<String, serde_json::Value>>,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        let idle_timeout_secs = STAGE_STREAM_IDLE_TIMEOUT_SECS.min(MAX_STAGE_RUNTIME_SECS);
        let mut stall_recovery_attempts: u32 = 0;
        let session_key = stream_key(ai_tool, directory, session_id);

        let seed_messages = match agent.list_messages(directory, session_id, None).await {
            Ok(messages) => map_ai_messages_for_wire(messages),
            Err(_) => Vec::new(),
        };
        let seed_selection_hint = match agent.session_selection_hint(directory, session_id).await {
            Ok(Some(hint)) => Some(map_ai_selection_hint_to_wire(hint)),
            _ => None,
        };
        seed_stream_snapshot(
            &ctx.ai_state,
            &session_key,
            seed_messages,
            seed_selection_hint,
            true,
        )
        .await;

        loop {
            let next = timeout(Duration::from_secs(idle_timeout_secs), stream.next()).await;
            match next {
                Ok(Some(Ok(event))) => {
                    stall_recovery_attempts = 0;
                    match event {
                        crate::ai::AiEvent::Done { stop_reason } => {
                            let adapter_hint =
                                match agent.session_selection_hint(directory, session_id).await {
                                    Ok(Some(adapter_hint)) => adapter_hint,
                                    Ok(None) => crate::ai::AiSessionSelectionHint::default(),
                                    Err(_) => crate::ai::AiSessionSelectionHint::default(),
                                };
                            let inferred_hint =
                                match agent.list_messages(directory, session_id, None).await {
                                    Ok(messages) => infer_selection_hint_from_messages(
                                        &map_ai_messages_for_wire(messages),
                                    ),
                                    Err(_) => crate::ai::AiSessionSelectionHint::default(),
                                };
                            let selection_hint =
                                merge_session_selection_hint(adapter_hint, inferred_hint);
                            if let Some(snapshot) = mark_stream_snapshot_terminal(
                                &ctx.ai_state,
                                &session_key,
                                selection_hint.clone(),
                            )
                            .await
                            {
                                self.broadcast(
                                    ctx,
                                    build_ai_session_messages_update(
                                        project, workspace, ai_tool, session_id, &snapshot, None,
                                        true,
                                    ),
                                )
                                .await;
                            }
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
                            if let Some(snapshot) =
                                mark_stream_snapshot_terminal(&ctx.ai_state, &session_key, None)
                                    .await
                            {
                                self.broadcast(
                                    ctx,
                                    build_ai_session_messages_update(
                                        project, workspace, ai_tool, session_id, &snapshot, None,
                                        true,
                                    ),
                                )
                                .await;
                            }
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
                            let wire_hint = selection_hint.map(map_ai_selection_hint_to_wire);
                            let op =
                                crate::server::protocol::ai::AiSessionCacheOpInfo::MessageUpdated {
                                    message_id,
                                    role,
                                };
                            let snapshot = apply_stream_snapshot_cache_op(
                                &ctx.ai_state,
                                &session_key,
                                &op,
                                wire_hint,
                            )
                            .await;
                            self.broadcast(
                                ctx,
                                build_ai_session_messages_update(
                                    project,
                                    workspace,
                                    ai_tool,
                                    session_id,
                                    &snapshot,
                                    Some(vec![op]),
                                    false,
                                ),
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
                            let ops = build_stage_part_updated_ops(
                                message_id,
                                normalize_part_for_wire(part),
                            );
                            for op in ops {
                                let snapshot = apply_stream_snapshot_cache_op(
                                    &ctx.ai_state,
                                    &session_key,
                                    &op,
                                    None,
                                )
                                .await;
                                self.broadcast(
                                    ctx,
                                    build_ai_session_messages_update(
                                        project,
                                        workspace,
                                        ai_tool,
                                        session_id,
                                        &snapshot,
                                        Some(vec![op]),
                                        false,
                                    ),
                                )
                                .await;
                            }
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
                            let ops = build_stage_part_delta_ops(
                                message_id, part_id, part_type, field, delta,
                            );
                            for op in ops {
                                let snapshot = apply_stream_snapshot_cache_op(
                                    &ctx.ai_state,
                                    &session_key,
                                    &op,
                                    None,
                                )
                                .await;
                                self.broadcast(
                                    ctx,
                                    build_ai_session_messages_update(
                                        project,
                                        workspace,
                                        ai_tool,
                                        session_id,
                                        &snapshot,
                                        Some(vec![op]),
                                        false,
                                    ),
                                )
                                .await;
                            }
                            if tool_call_count_changed {
                                self.broadcast_cycle_update(key, ctx, "agent").await;
                            }
                        }
                        crate::ai::AiEvent::QuestionAsked { request } => {
                            let tool_call_count = self.stage_tool_call_count(key, stage).await;
                            self.finalize_session_execution(
                                key,
                                stage,
                                session_id,
                                "blocked",
                                tool_call_count,
                            )
                            .await;
                            self.block_current_stage_by_question(
                                key, project, workspace, cycle_id, stage, &request, ctx,
                            )
                            .await?;
                            return Err("evo_human_blocking_required:ai_question".to_string());
                        }
                        crate::ai::AiEvent::QuestionCleared { .. } => {}
                        crate::ai::AiEvent::SessionConfigOptionsUpdated { .. } => {}
                        crate::ai::AiEvent::SlashCommandsUpdated { .. } => {}
                    }
                }
                Ok(Some(Err(err))) => {
                    if let Some(snapshot) =
                        mark_stream_snapshot_terminal(&ctx.ai_state, &session_key, None).await
                    {
                        self.broadcast(
                            ctx,
                            build_ai_session_messages_update(
                                project, workspace, ai_tool, session_id, &snapshot, None, true,
                            ),
                        )
                        .await;
                    }
                    return Err(err);
                }
                Ok(None) => {
                    if let Some(snapshot) =
                        mark_stream_snapshot_terminal(&ctx.ai_state, &session_key, None).await
                    {
                        self.broadcast(
                            ctx,
                            build_ai_session_messages_update(
                                project, workspace, ai_tool, session_id, &snapshot, None, true,
                            ),
                        )
                        .await;
                    }
                    break;
                }
                Err(_) => {
                    let stage_tool_call_count = {
                        let state = self.state.lock().await;
                        state
                            .workspaces
                            .get(key)
                            .and_then(|entry| entry.stage_tool_call_counts.get(stage).copied())
                            .unwrap_or(0)
                    };

                    let can_auto_recover = should_attempt_idle_recovery(stall_recovery_attempts);
                    if can_auto_recover {
                        stall_recovery_attempts += 1;
                        warn!(
                            "stage stream idle timeout: key={}, stage={}, ai_tool={}, session_id={}, tool_call_count={}, attempt={}/{}, action=abort_and_continue",
                            key,
                            stage,
                            ai_tool,
                            session_id,
                            stage_tool_call_count,
                            stall_recovery_attempts,
                            STAGE_STREAM_IDLE_RECOVERY_MAX_ATTEMPTS
                        );

                        if let Err(err) = agent.abort_session(directory, session_id).await {
                            warn!(
                                "stage stream idle recovery abort failed: key={}, stage={}, session_id={}, error={}",
                                key, stage, session_id, err
                            );
                        }

                        sleep(Duration::from_millis(
                            STAGE_STREAM_IDLE_RECOVERY_COOLDOWN_MS,
                        ))
                        .await;

                        match agent
                            .send_message_with_config(
                                directory,
                                session_id,
                                STAGE_STREAM_IDLE_RECOVERY_MESSAGE,
                                None,
                                None,
                                None,
                                model.clone(),
                                mode.clone(),
                                config_overrides.clone(),
                            )
                            .await
                        {
                            Ok(recovery_stream) => {
                                stream = recovery_stream;
                                continue;
                            }
                            Err(err) => {
                                return Err(format!(
                                    "stage stream timeout; idle recovery send failed: {}",
                                    err
                                ));
                            }
                        }
                    }

                    return Err(format!(
                        "stage stream timeout (idle {}s, tool_call_count={})",
                        idle_timeout_secs, stage_tool_call_count
                    ));
                }
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
            state.workspaces.get(key).map(|entry| {
                (
                    entry.workspace_root.clone(),
                    entry.verify_iteration,
                    entry.backlog_contract_version,
                )
            })
        };
        if let Some((workspace_root, verify_iteration, backlog_contract_version)) = validation_ctx {
            let cycle_dir = cycle_dir_path(&workspace_root, cycle_id)?;
            let contract_version = if backlog_contract_version == 0 {
                backlog_contract_version_from_cycle(&cycle_dir)?
            } else {
                backlog_contract_version
            };
            if verify_iteration > 0
                && contract_version >= 2
                && Self::lane_for_stage(stage).is_some()
            {
                Self::sync_managed_backlog_for_implement_stage(&cycle_dir, stage)?;
            }
            Self::validate_stage_artifacts(stage, &cycle_dir, verify_iteration, contract_version)
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
                model.clone(),
                mode.clone(),
                config_overrides.clone(),
            )
            .await
            .map_err(|e| format!("validation reminder send failed: {}", e))?;
        self.consume_stage_stream(
            key,
            project,
            workspace,
            cycle_id,
            stage,
            ai_tool,
            session_id,
            directory,
            agent,
            stream,
            model,
            mode,
            config_overrides,
            ctx,
        )
        .await
    }

    async fn finalize_stage_failed(
        &self,
        key: &str,
        stage: &str,
        session_id: Option<&str>,
        error_message: &str,
        ctx: &HandlerContext,
    ) {
        self.set_stage_status(key, stage, "failed").await;
        if let Some(session_id) = session_id {
            let tool_call_count = self.stage_tool_call_count(key, stage).await;
            self.finalize_session_execution(key, stage, session_id, "failed", tool_call_count)
                .await;
        }
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
        let (verify_iteration, backlog_contract_version, workspace_root, stage_profile) = {
            let state = self.state.lock().await;
            let entry = state
                .workspaces
                .get(key)
                .ok_or_else(|| "workspace state missing".to_string())?;
            (
                entry.verify_iteration,
                entry.backlog_contract_version,
                entry.workspace_root.clone(),
                profile_for_stage(&entry.stage_profiles, stage),
            )
        };
        info!(
            "evolution run_stage enter: key={}, project={}, workspace={}, cycle_id={}, stage={}, round={}, verify_iteration={}, backlog_contract_version={}",
            key,
            project,
            workspace,
            cycle_id,
            stage,
            round,
            verify_iteration,
            backlog_contract_version
        );

        let cycle_dir = cycle_dir_path(&workspace_root, cycle_id)?;
        let implement_lanes = if Self::lane_for_stage(stage).is_some() {
            let lanes = Self::resolve_implement_lanes(&cycle_dir, verify_iteration)?;
            Self::ensure_implement_result_placeholders(
                &cycle_dir,
                verify_iteration,
                backlog_contract_version,
                &lanes,
            )?;
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
                    backlog_contract_version,
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
                judge_pass = match self.resolve_judge_result(key, cycle_id).await {
                    Ok(value) => value,
                    Err(err) => {
                        let tool_call_count = self.stage_tool_call_count(key, stage).await;
                        self.finalize_session_execution(
                            key,
                            stage,
                            &run_ctx.session_id,
                            "failed",
                            tool_call_count,
                        )
                        .await;
                        return Err(err);
                    }
                };
            }

            match self.validate_stage_outputs(key, stage, cycle_id).await {
                Ok(()) => break,
                Err(validation_err) => {
                    if !Self::should_retry_validation_with_reminder(stage, &validation_err) {
                        let tool_call_count = self.stage_tool_call_count(key, stage).await;
                        self.finalize_session_execution(
                            key,
                            stage,
                            &run_ctx.session_id,
                            "failed",
                            tool_call_count,
                        )
                        .await;
                        return Err(validation_err);
                    }

                    if reminder_attempts >= VALIDATION_REMINDER_MAX_RETRIES {
                        self.finalize_stage_failed(
                            key,
                            stage,
                            Some(&run_ctx.session_id),
                            &validation_err,
                            ctx,
                        )
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
                            self.finalize_stage_failed(
                                key,
                                stage,
                                Some(&run_ctx.session_id),
                                &combined_err,
                                ctx,
                            )
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
            let tool_call_count = self.stage_tool_call_count(key, stage).await;
            self.finalize_session_execution(
                key,
                stage,
                &run_ctx.session_id,
                "blocked",
                tool_call_count,
            )
            .await;
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
                    backlog_contract_version,
                    "done",
                )?;
            }
        }

        let tool_call_count = self.stage_tool_call_count(key, stage).await;
        self.finalize_session_execution(key, stage, &run_ctx.session_id, "done", tool_call_count)
            .await;
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
        if stage == "direction" {
            if let Err(err) = self
                .sync_cycle_title_from_direction_stage(key, cycle_id)
                .await
            {
                warn!(
                    "sync cycle title from direction stage failed: key={}, cycle_id={}, error={}",
                    key, cycle_id, err
                );
            }
        }
        if let Err(err) = self.persist_cycle_file(key).await {
            warn!(
                "evolution run_stage done persist_cycle_file failed: key={}, cycle_id={}, stage={}, session_id={}, error={}",
                key, cycle_id, stage, run_ctx.session_id, err
            );
        }
        self.broadcast_cycle_update(key, ctx, "agent").await;
        info!(
            "evolution run_stage done: key={}, cycle_id={}, stage={}, session_id={}, judge_pass={}, tool_calls={}",
            key, cycle_id, stage, run_ctx.session_id, judge_pass, tool_call_count
        );

        Ok(judge_pass)
    }

    pub(super) async fn run_auto_commit_independent(
        &self,
        project: &str,
        workspace: &str,
        workspace_root: &Path,
        ctx: &HandlerContext,
    ) -> Result<(String, Vec<AIGitCommit>), String> {
        let before_has_changes = git_repo_has_changes(workspace_root)?;
        if !before_has_changes {
            return Ok(("No changes to commit".to_string(), Vec::new()));
        }

        let before_head = git_head_sha(workspace_root)?;
        let profiles = self.get_agent_profile(project, workspace, ctx).await;
        let profile = profile_for_stage(&profiles, "auto_commit");

        let prompt = r#"你是一个 Git 提交助手。请在当前目录分析变更并执行智能提交。这是纯本地操作，禁止任何网络请求。

请按以下步骤执行：
1. 运行 `git log --oneline -10` 了解现有提交风格（Conventional Commits 与否、中英文），并沿用
2. 运行 `git status` 和 `git diff` 理解所有变更（含未追踪文件）
3. 对未追踪文件进行判断：构建产物、缓存、IDE 配置、依赖目录、敏感文件等不应入库的文件，追加到 `.gitignore`（如已存在则跳过）
4. 将应提交的变更按逻辑分组为原子提交（按模块/关注点）
5. 对每组执行 `git add <files>` 然后 `git commit -m "<message>"`（若修改了 `.gitignore`，将其纳入第一个提交）
"#;

        let directory = resolve_directory(&ctx.app_state, project, workspace).await?;
        let agent = ensure_agent(&ctx.ai_state, &profile.ai_tool).await?;
        let session = agent
            .create_session(&directory, "Evolution auto_commit 独立执行")
            .await?;

        let model = profile.model.as_ref().map(|m| AiModelSelection {
            provider_id: m.provider_id.clone(),
            model_id: m.model_id.clone(),
        });
        let mode = profile.mode.clone();
        let config_overrides = sanitize_ai_config_options(&profile.config_options);

        let mut stream = agent
            .send_message_with_config(
                &directory,
                &session.id,
                prompt,
                None,
                None,
                None,
                model,
                mode,
                config_overrides,
            )
            .await?;

        loop {
            let next = timeout(
                Duration::from_secs(STAGE_STREAM_IDLE_TIMEOUT_SECS),
                stream.next(),
            )
            .await;
            match next {
                Ok(Some(Ok(crate::ai::AiEvent::Done { .. }))) => break,
                Ok(Some(Ok(crate::ai::AiEvent::Error { message }))) => {
                    return Err(format!("auto_commit 会话失败: {}", message));
                }
                Ok(Some(Ok(crate::ai::AiEvent::QuestionAsked { .. }))) => {
                    return Err("auto_commit 不支持人工提问".to_string());
                }
                Ok(Some(Ok(_))) => {}
                Ok(Some(Err(err))) => return Err(err),
                Ok(None) => break,
                Err(_) => return Err("auto_commit 会话超时".to_string()),
            }
        }

        let after_head = git_head_sha(workspace_root)?;
        let commits = collect_commits_between(
            workspace_root,
            before_head.as_deref(),
            after_head.as_deref(),
        )?;
        if commits.is_empty() {
            let after_has_changes = git_repo_has_changes(workspace_root)?;
            if after_has_changes {
                return Err("auto_commit 未生成提交，且工作区仍有未提交变更".to_string());
            }
            return Ok((
                "Auto commit completed with no new commits".to_string(),
                commits,
            ));
        }
        Ok((
            format!(
                "Auto commit completed. Created {} commit(s).",
                commits.len()
            ),
            commits,
        ))
    }

    pub(super) async fn after_stage_success(
        &self,
        key: &str,
        stage: &str,
        judge_pass: bool,
        ctx: &HandlerContext,
    ) -> bool {
        let (cycle_for_validation, before_snapshot) = {
            let state = self.state.lock().await;
            if let Some(entry) = state.workspaces.get(key) {
                (
                    Some(entry.cycle_id.clone()),
                    Some((
                        entry.status.clone(),
                        entry.current_stage.clone(),
                        entry.cycle_id.clone(),
                        entry.verify_iteration,
                        entry.global_loop_round,
                    )),
                )
            } else {
                (None, None)
            }
        };
        if let Some((status, current_stage, cycle_id, verify_iteration, global_loop_round)) =
            before_snapshot
        {
            info!(
                "evolution after_stage_success enter: key={}, stage={}, judge_pass={}, status={}, current_stage={}, cycle_id={}, verify_iteration={}, global_loop_round={}",
                key,
                stage,
                judge_pass,
                status,
                current_stage,
                cycle_id,
                verify_iteration,
                global_loop_round
            );
        } else {
            warn!(
                "evolution after_stage_success enter: workspace state missing: key={}, stage={}, judge_pass={}",
                key, stage, judge_pass
            );
        }
        if stage == "plan" {
            let Some(cycle_id) = cycle_for_validation.clone() else {
                warn!(
                    "evolution after_stage_success plan validation skipped: missing cycle_id: key={}, stage={}",
                    key, stage
                );
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
                warn!(
                    "evolution after_stage_success judge validation skipped: missing cycle_id: key={}, stage={}",
                    key, stage
                );
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
        let mut post_stage_changed: Option<(String, String, String, String, String)> = None;
        let mut auto_next_cycle = false;
        let mut auto_loop_gate: Option<(String, String, String, String)> = None;
        let mut should_start_next_round_after_auto_commit = false;

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
                    let lanes = cycle_dir_path(&entry.workspace_root, &entry.cycle_id)
                        .ok()
                        .and_then(|dir| {
                            Self::resolve_implement_lanes(&dir, entry.verify_iteration).ok()
                        })
                        .unwrap_or_else(|| vec![ImplementLane::Visual]);
                    let has_advanced = lanes.iter().any(|lane| *lane == ImplementLane::Advanced);
                    if has_advanced {
                        next_stage = "implement_advanced".to_string();
                    } else {
                        entry
                            .stage_statuses
                            .insert("implement_advanced".to_string(), "skipped".to_string());
                        entry
                            .stage_tool_call_counts
                            .insert("implement_advanced".to_string(), 0);
                        next_stage = "verify".to_string();
                    }
                }
                "implement_advanced" => next_stage = "verify".to_string(),
                "verify" => next_stage = "judge".to_string(),
                "judge" => {
                    entry.last_judge_result = Some(judge_pass);
                    if judge_pass {
                        entry.terminal_reason_code = None;
                        entry.terminal_error_message = None;
                        emit_judge = Some((
                            entry.project.clone(),
                            entry.workspace.clone(),
                            entry.cycle_id.clone(),
                            "pass".to_string(),
                        ));
                        next_stage = "report".to_string();
                    } else if entry.verify_iteration + 1 < entry.verify_iteration_limit {
                        entry.terminal_reason_code = None;
                        entry.terminal_error_message = None;
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
                        if entry.backlog_contract_version >= 2 {
                            match cycle_dir_path(&entry.workspace_root, &entry.cycle_id) {
                                Ok(cycle_dir) => {
                                    if let Err(err) = Self::generate_managed_backlog_from_judge(
                                        &cycle_dir,
                                        entry.verify_iteration,
                                    ) {
                                        warn!(
                                            "managed backlog generation failed (project={}, workspace={}, cycle_id={}, verify_iteration={}): {}",
                                            entry.project,
                                            entry.workspace,
                                            entry.cycle_id,
                                            entry.verify_iteration,
                                            err
                                        );
                                    }
                                }
                                Err(err) => {
                                    warn!(
                                        "managed backlog generation skipped: resolve cycle dir failed (project={}, workspace={}, cycle_id={}): {}",
                                        entry.project, entry.workspace, entry.cycle_id, err
                                    );
                                }
                            }
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
                        entry.terminal_error_message = None;
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
                            entry.terminal_error_message = None;
                            "completed".to_string()
                        } else {
                            if entry.terminal_reason_code.is_none() {
                                entry.terminal_reason_code = Some("evo_judge_failed".to_string());
                            }
                            entry.terminal_error_message = None;
                            "failed_exhausted".to_string()
                        };
                    }
                    if entry.status == "completed" {
                        next_stage = "auto_commit".to_string();
                    }
                }
                "auto_commit" => {
                    if entry.status != "failed_system" {
                        entry.status = "completed".to_string();
                        entry.terminal_reason_code = None;
                        entry.terminal_error_message = None;
                    }
                    should_start_next_round_after_auto_commit = should_start_next_round(
                        "completed",
                        entry.global_loop_round,
                        entry.loop_round_limit,
                    );
                    if should_start_next_round_after_auto_commit {
                        auto_loop_gate = Some((
                            entry.project.clone(),
                            entry.workspace.clone(),
                            entry.workspace_root.clone(),
                            entry.cycle_id.clone(),
                        ));
                    }
                }
                _ => {}
            }

            let should_advance = match stage {
                "report" => next_stage == "auto_commit",
                "auto_commit" => false,
                _ => true,
            };
            if should_advance {
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
        if !matches!(stage, "auto_commit") && stage_changed.is_none() {
            warn!(
                "evolution after_stage_success no stage_changed emitted: key={}, stage={}, judge_pass={}",
                key, stage, judge_pass
            );
        }
        if let Some((project, workspace, cycle_id, from_stage, to_stage)) = stage_changed.as_ref() {
            info!(
                "evolution after_stage_success stage_changed: key={}, project={}, workspace={}, cycle_id={}, from_stage={}, to_stage={}",
                key, project, workspace, cycle_id, from_stage, to_stage
            );
        }
        if let Some((project, workspace, cycle_id, from_stage, to_stage)) =
            post_stage_changed.as_ref()
        {
            info!(
                "evolution after_stage_success post_stage_changed: key={}, project={}, workspace={}, cycle_id={}, from_stage={}, to_stage={}",
                key, project, workspace, cycle_id, from_stage, to_stage
            );
        }

        if let Some((project, workspace, workspace_root, cycle_id)) = auto_loop_gate {
            match self
                .emit_blocking_required_if_any(
                    &project,
                    &workspace,
                    &workspace_root,
                    "auto_loop",
                    Some(&cycle_id),
                    Some("auto_commit"),
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

        if stage == "auto_commit" && should_start_next_round_after_auto_commit {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(key) else {
                return false;
            };
            entry.global_loop_round += 1;
            entry.verify_iteration = 0;
            entry.cycle_id = Utc::now().format("%Y-%m-%dT%H-%M-%S-%3fZ").to_string();
            entry.cycle_title = None;
            entry.created_at = Utc::now().to_rfc3339();
            entry.current_stage = "direction".to_string();
            entry.status = "queued".to_string();
            entry.last_judge_result = None;
            entry.terminal_reason_code = None;
            entry.terminal_error_message = None;
            entry.rate_limit_resume_at = None;
            entry.rate_limit_error_message = None;
            entry.llm_defined_acceptance_criteria.clear();
            entry.stage_sessions.clear();
            entry.stage_session_history.clear();
            entry.session_executions.clear();
            entry.stage_statuses.clear();
            entry.stage_tool_call_counts.clear();
            entry.stage_seen_tool_calls.clear();
            entry.stage_started_ats.clear();
            entry.stage_duration_ms.clear();
            for s in STAGES {
                entry
                    .stage_statuses
                    .insert(s.to_string(), "pending".to_string());
            }
            auto_next_cycle = true;
            post_stage_changed = Some((
                entry.project.clone(),
                entry.workspace.clone(),
                entry.cycle_id.clone(),
                "auto_commit".to_string(),
                "direction".to_string(),
            ));
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
            let verify_iteration = {
                let state = self.state.lock().await;
                state
                    .workspaces
                    .get(key)
                    .map(|v| v.verify_iteration)
                    .unwrap_or(0)
            };
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
                    verify_iteration,
                },
            )
            .await;
        }

        if let Some((project, workspace, cycle_id, from_stage, to_stage)) = post_stage_changed {
            let verify_iteration = {
                let state = self.state.lock().await;
                state
                    .workspaces
                    .get(key)
                    .map(|v| v.verify_iteration)
                    .unwrap_or(0)
            };
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
                    verify_iteration,
                },
            )
            .await;
        }

        if let Err(err) = self.persist_cycle_file(key).await {
            warn!(
                "evolution after_stage_success persist_cycle_file failed: key={}, stage={}, error={}",
                key, stage, err
            );
        }
        self.broadcast_cycle_update(key, ctx, "orchestrator").await;
        self.broadcast_scheduler(ctx).await;
        let after_snapshot = {
            let state = self.state.lock().await;
            state.workspaces.get(key).map(|entry| {
                (
                    entry.status.clone(),
                    entry.current_stage.clone(),
                    entry.cycle_id.clone(),
                    entry.verify_iteration,
                    entry.global_loop_round,
                )
            })
        };
        if let Some((status, current_stage, cycle_id, verify_iteration, global_loop_round)) =
            after_snapshot
        {
            info!(
                "evolution after_stage_success exit: key={}, stage={}, judge_pass={}, auto_next_cycle={}, status={}, current_stage={}, cycle_id={}, verify_iteration={}, global_loop_round={}",
                key,
                stage,
                judge_pass,
                auto_next_cycle,
                status,
                current_stage,
                cycle_id,
                verify_iteration,
                global_loop_round
            );
        } else {
            warn!(
                "evolution after_stage_success exit: workspace state missing: key={}, stage={}, auto_next_cycle={}",
                key, stage, auto_next_cycle
            );
        }
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
            entry.terminal_error_message = None;
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
        let normalized_err = {
            let trimmed = err.trim();
            let base = if trimmed.is_empty() {
                format!("{}: missing error details", code)
            } else {
                trimmed.to_string()
            };
            if base.chars().count() > 1200 {
                let mut shortened = String::with_capacity(1203);
                for ch in base.chars().take(1200) {
                    shortened.push(ch);
                }
                shortened.push_str("...");
                shortened
            } else {
                base
            }
        };

        let maybe = {
            let mut state = self.state.lock().await;
            let Some(entry) = state.workspaces.get_mut(key) else {
                return;
            };
            entry.status = "failed_system".to_string();
            entry.terminal_reason_code = Some(code.to_string());
            entry.terminal_error_message = Some(normalized_err.clone());
            entry.rate_limit_resume_at = None;
            entry.rate_limit_error_message = None;
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
                    message: normalized_err,
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
        parse_judge_result_from_json, should_start_next_round, EvolutionManager, ImplementLane,
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

    fn write_managed_backlog_files(
        dir: &Path,
        cycle_id: &str,
        verify_iteration: u32,
        backlog: Vec<serde_json::Value>,
        coverage: Vec<serde_json::Value>,
    ) {
        write_json(
            &dir.join("managed.failure_backlog.json"),
            serde_json::json!({
                "$schema_version": "1.0",
                "cycle_id": cycle_id,
                "verify_iteration": verify_iteration,
                "items": backlog,
                "updated_at": "2026-03-02T00:00:00Z"
            }),
        );
        let total = coverage.len() as u64;
        let done = coverage
            .iter()
            .filter(|item| item.get("status").and_then(|v| v.as_str()) == Some("done"))
            .count() as u64;
        let blocked = coverage
            .iter()
            .filter(|item| item.get("status").and_then(|v| v.as_str()) == Some("blocked"))
            .count() as u64;
        let not_done = total.saturating_sub(done).saturating_sub(blocked);
        write_json(
            &dir.join("managed.backlog_coverage.json"),
            serde_json::json!({
                "$schema_version": "1.0",
                "cycle_id": cycle_id,
                "verify_iteration": verify_iteration,
                "items": coverage,
                "summary": {
                    "total": total,
                    "done": done,
                    "blocked": blocked,
                    "not_done": not_done
                },
                "updated_at": "2026-03-02T00:00:00Z"
            }),
        );
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

    #[test]
    fn should_attempt_idle_recovery_should_allow_within_limit() {
        assert!(super::should_attempt_idle_recovery(0));
        assert!(super::should_attempt_idle_recovery(1));
        assert!(!super::should_attempt_idle_recovery(2));
        assert!(!super::should_attempt_idle_recovery(3));
    }

    // ── 九阶段新约束回归测试 ──────────────────────────────────────────────

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
    fn next_stage_report_should_goto_auto_commit() {
        assert_eq!(next_stage("report"), Some("auto_commit"));
    }

    #[test]
    fn next_stage_auto_commit_should_loop_back_to_direction() {
        assert_eq!(next_stage("auto_commit"), Some("direction"));
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
    fn auto_commit_completed_final_round_should_not_start_next_round() {
        assert!(
            !should_start_next_round("completed", 1, 1),
            "最终轮不应自动开始下一轮"
        );
    }

    #[test]
    fn auto_commit_completed_non_final_round_should_start_next_round() {
        assert!(
            should_start_next_round("completed", 1, 3),
            "非最终轮应自动开始下一轮"
        );
    }

    #[test]
    fn auto_commit_failed_exhausted_should_not_start_next_round() {
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
        let err = EvolutionManager::validate_stage_artifacts("implement_visual", dir.path(), 1, 1)
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
        let err = EvolutionManager::validate_stage_artifacts("implement_general", dir.path(), 1, 1)
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
        let err = EvolutionManager::validate_stage_artifacts("implement_visual", dir.path(), 1, 1)
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
        let err = EvolutionManager::validate_stage_artifacts("verify", dir.path(), 1, 1)
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
        let err = EvolutionManager::validate_stage_artifacts("judge", dir.path(), 1, 1)
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
        let err = EvolutionManager::validate_stage_artifacts("plan", dir.path(), 0, 1)
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
        let err = EvolutionManager::validate_stage_artifacts("plan", dir.path(), 0, 1)
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
        let err = EvolutionManager::validate_stage_artifacts("plan", dir.path(), 0, 1)
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
        let err = EvolutionManager::validate_stage_artifacts("plan", dir.path(), 0, 1)
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
    fn resolve_implement_lanes_should_keep_general_and_advanced_on_first_iteration() {
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
                    "targets": ["core/src/advanced.rs"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_agent": "implement_advanced",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        let lanes = EvolutionManager::resolve_implement_lanes(dir.path(), 0)
            .expect("lane resolve should succeed");
        assert_eq!(lanes, vec![ImplementLane::General, ImplementLane::Advanced]);
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
    fn resolve_implement_lanes_should_map_general_then_advanced_on_reimplementation() {
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
                    "targets": ["core/src/advanced.rs"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_agent": "implement_advanced",
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
        assert_eq!(lanes, vec![ImplementLane::General, ImplementLane::Advanced]);
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
        let err = EvolutionManager::validate_stage_artifacts("implement_visual", dir.path(), 1, 1)
            .expect_err("invalid failure_backlog implementation_agent should fail");
        assert!(err.contains("implementation_agent"));
    }

    #[test]
    fn validate_stage_artifacts_should_accept_v2_managed_backlog() {
        let dir = tempdir().expect("tempdir should succeed");
        write_managed_backlog_files(
            dir.path(),
            "c-1",
            1,
            vec![serde_json::json!({
                "id": "fb-1",
                "source_criteria_id": "ac-1",
                "source_check_id": "v-1",
                "work_item_id": "w-1",
                "implementation_agent": "implement_general",
                "requirement_ref": "ac-1",
                "description": "",
                "created_at": "2026-03-02T00:00:00Z",
                "updated_at": "2026-03-02T00:00:00Z"
            })],
            vec![serde_json::json!({
                "backlog_id": "fb-1",
                "source_criteria_id": "ac-1",
                "source_check_id": "v-1",
                "work_item_id": "w-1",
                "implementation_agent": "implement_general",
                "status": "done",
                "evidence": null,
                "notes": "",
                "updated_at": "2026-03-02T00:00:00Z"
            })],
        );
        EvolutionManager::validate_stage_artifacts("implement_general", dir.path(), 1, 2)
            .expect("v2 managed backlog should pass validation");
    }

    #[test]
    fn sync_managed_backlog_should_reject_selector_missing() {
        let dir = tempdir().expect("tempdir should succeed");
        write_managed_backlog_files(
            dir.path(),
            "c-1",
            1,
            vec![serde_json::json!({
                "id": "fb-1",
                "source_criteria_id": "ac-1",
                "source_check_id": "v-1",
                "work_item_id": "w-1",
                "implementation_agent": "implement_general",
                "requirement_ref": "ac-1",
                "description": "",
                "created_at": "2026-03-02T00:00:00Z",
                "updated_at": "2026-03-02T00:00:00Z"
            })],
            vec![serde_json::json!({
                "backlog_id": "fb-1",
                "source_criteria_id": "ac-1",
                "source_check_id": "v-1",
                "work_item_id": "w-1",
                "implementation_agent": "implement_general",
                "status": "not_done",
                "evidence": null,
                "notes": "",
                "updated_at": "2026-03-02T00:00:00Z"
            })],
        );
        write_json(
            &dir.path().join("implement_general.result.json"),
            serde_json::json!({
                "backlog_resolution_updates": [{
                    "source_criteria_id": "ac-404",
                    "source_check_id": "v-404",
                    "work_item_id": "w-x",
                    "implementation_agent": "implement_general",
                    "status": "done",
                    "evidence": {"proof": "x"},
                    "notes": "x"
                }]
            }),
        );
        let err = EvolutionManager::sync_managed_backlog_for_implement_stage(
            dir.path(),
            "implement_general",
        )
        .expect_err("missing selector should fail");
        assert!(err.contains("evo_backlog_mapping_missing"));
    }

    #[test]
    fn sync_managed_backlog_should_reject_selector_ambiguous() {
        let dir = tempdir().expect("tempdir should succeed");
        write_managed_backlog_files(
            dir.path(),
            "c-1",
            1,
            vec![
                serde_json::json!({
                    "id": "fb-1",
                    "source_criteria_id": "ac-1",
                    "source_check_id": "v-1",
                    "work_item_id": "w-1",
                    "implementation_agent": "implement_general",
                    "requirement_ref": "ac-1",
                    "description": "",
                    "created_at": "2026-03-02T00:00:00Z",
                    "updated_at": "2026-03-02T00:00:00Z"
                }),
                serde_json::json!({
                    "id": "fb-2",
                    "source_criteria_id": "ac-1",
                    "source_check_id": "v-1",
                    "work_item_id": "w-1",
                    "implementation_agent": "implement_general",
                    "requirement_ref": "ac-1",
                    "description": "",
                    "created_at": "2026-03-02T00:00:00Z",
                    "updated_at": "2026-03-02T00:00:00Z"
                }),
            ],
            vec![
                serde_json::json!({
                    "backlog_id": "fb-1",
                    "source_criteria_id": "ac-1",
                    "source_check_id": "v-1",
                    "work_item_id": "w-1",
                    "implementation_agent": "implement_general",
                    "status": "not_done",
                    "evidence": null,
                    "notes": "",
                    "updated_at": "2026-03-02T00:00:00Z"
                }),
                serde_json::json!({
                    "backlog_id": "fb-2",
                    "source_criteria_id": "ac-1",
                    "source_check_id": "v-1",
                    "work_item_id": "w-1",
                    "implementation_agent": "implement_general",
                    "status": "not_done",
                    "evidence": null,
                    "notes": "",
                    "updated_at": "2026-03-02T00:00:00Z"
                }),
            ],
        );
        write_json(
            &dir.path().join("implement_general.result.json"),
            serde_json::json!({
                "backlog_resolution_updates": [{
                    "source_criteria_id": "ac-1",
                    "source_check_id": "v-1",
                    "work_item_id": "w-1",
                    "implementation_agent": "implement_general",
                    "status": "done",
                    "evidence": {"proof": "x"},
                    "notes": "x"
                }]
            }),
        );
        let err = EvolutionManager::sync_managed_backlog_for_implement_stage(
            dir.path(),
            "implement_general",
        )
        .expect_err("ambiguous selector should fail");
        assert!(err.contains("evo_backlog_mapping_ambiguous"));
    }

    #[test]
    fn sync_managed_backlog_should_fill_result_and_validate() {
        let dir = tempdir().expect("tempdir should succeed");
        write_managed_backlog_files(
            dir.path(),
            "c-1",
            1,
            vec![serde_json::json!({
                "id": "fb-1",
                "source_criteria_id": "ac-1",
                "source_check_id": "v-1",
                "work_item_id": "w-1",
                "implementation_agent": "implement_general",
                "requirement_ref": "ac-1",
                "description": "",
                "created_at": "2026-03-02T00:00:00Z",
                "updated_at": "2026-03-02T00:00:00Z"
            })],
            vec![serde_json::json!({
                "backlog_id": "fb-1",
                "source_criteria_id": "ac-1",
                "source_check_id": "v-1",
                "work_item_id": "w-1",
                "implementation_agent": "implement_general",
                "status": "not_done",
                "evidence": null,
                "notes": "",
                "updated_at": "2026-03-02T00:00:00Z"
            })],
        );
        write_json(
            &dir.path().join("implement_general.result.json"),
            serde_json::json!({
                "backlog_resolution_updates": [{
                    "source_criteria_id": "ac-1",
                    "source_check_id": "v-1",
                    "work_item_id": "w-1",
                    "implementation_agent": "implement_general",
                    "status": "done",
                    "evidence": {"proof": "done"},
                    "notes": "resolved"
                }]
            }),
        );
        EvolutionManager::sync_managed_backlog_for_implement_stage(dir.path(), "implement_general")
            .expect("sync should succeed");
        let result = super::read_json_file(dir.path(), "implement_general.result.json")
            .expect("implement result should be readable");
        assert_eq!(
            result["backlog_coverage_summary"]["total"],
            serde_json::json!(1)
        );
        assert_eq!(
            result["backlog_coverage_summary"]["done"],
            serde_json::json!(1)
        );
        EvolutionManager::validate_stage_artifacts("implement_general", dir.path(), 1, 2)
            .expect("v2 validation should pass");
    }

    #[test]
    fn generate_managed_backlog_should_create_files_on_judge_fail() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("cycle.json"),
            serde_json::json!({
                "cycle_id": "c-1"
            }),
        );
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
                    "targets": ["core/src/extra.rs"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_agent": "implement_general",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        write_json(
            &dir.path().join("judge.result.json"),
            serde_json::json!({
                "full_next_iteration_requirements": [{
                    "criteria_id": "ac-1",
                    "check_id": "v-1",
                    "work_item_id": "w-1",
                    "title": "need fix"
                }]
            }),
        );
        EvolutionManager::generate_managed_backlog_from_judge(dir.path(), 1)
            .expect("managed backlog generation should succeed");
        let backlog = super::read_json_file(dir.path(), "managed.failure_backlog.json")
            .expect("managed backlog should exist");
        let coverage = super::read_json_file(dir.path(), "managed.backlog_coverage.json")
            .expect("managed coverage should exist");
        assert_eq!(
            backlog["items"]
                .as_array()
                .map(|items| items.len())
                .unwrap_or(0),
            1
        );
        assert_eq!(
            coverage["items"][0]["status"].as_str().unwrap_or_default(),
            "not_done"
        );
    }

    #[test]
    fn generate_managed_backlog_from_judge_with_items_object() {
        let dir = tempfile::tempdir().unwrap();
        write_json(
            &dir.path().join("cycle.json"),
            serde_json::json!({
                "cycle_id": "c-2"
            }),
        );
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
                    "targets": ["core/src/extra.rs"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_agent": "implement_general",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        // judge 使用 {"items": [...]} 对象格式（而非直接数组）
        write_json(
            &dir.path().join("judge.result.json"),
            serde_json::json!({
                "full_next_iteration_requirements": {
                    "items": [{
                        "criteria_id": "ac-1",
                        "check_id": "v-1",
                        "work_item_id": "w-1",
                        "title": "need fix"
                    }]
                }
            }),
        );
        EvolutionManager::generate_managed_backlog_from_judge(dir.path(), 1)
            .expect("managed backlog generation should succeed with items object format");
        let backlog = super::read_json_file(dir.path(), "managed.failure_backlog.json")
            .expect("managed backlog should exist");
        assert_eq!(
            backlog["items"]
                .as_array()
                .map(|items| items.len())
                .unwrap_or(0),
            1
        );
    }

    #[test]
    fn generate_managed_backlog_from_judge_with_acceptance_failures() {
        let dir = tempfile::tempdir().unwrap();
        write_json(
            &dir.path().join("cycle.json"),
            serde_json::json!({ "cycle_id": "c-3" }),
        );
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
                    "targets": ["core/src/extra.rs"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_agent": "implement_general",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        // judge 使用 {"acceptance_failures": [...], "carryover_failures": [...]} 格式
        write_json(
            &dir.path().join("judge.result.json"),
            serde_json::json!({
                "full_next_iteration_requirements": {
                    "carryover_failures": [],
                    "acceptance_failures": [
                        {
                            "type": "criteria_gap",
                            "criteria_id": "ac-1",
                            "check_ids": ["v-1", "v-2"],
                            "required_items": ["fix compilation errors"]
                        }
                    ],
                    "notes": "fix all errors"
                }
            }),
        );
        EvolutionManager::generate_managed_backlog_from_judge(dir.path(), 1)
            .expect("managed backlog generation should succeed with acceptance_failures format");
        let backlog = super::read_json_file(dir.path(), "managed.failure_backlog.json")
            .expect("managed backlog should exist");
        // check_ids 有 2 个元素，应展开为 2 条 backlog 项
        assert_eq!(
            backlog["items"]
                .as_array()
                .map(|items| items.len())
                .unwrap_or(0),
            2
        );
        let coverage = super::read_json_file(dir.path(), "managed.backlog_coverage.json")
            .expect("managed coverage should exist");
        assert_eq!(
            coverage["items"]
                .as_array()
                .map(|items| items.len())
                .unwrap_or(0),
            2
        );
    }
}
