use chrono::Utc;
use futures::StreamExt;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use tokio::time::{sleep, timeout, Duration};
use tracing::{error, info, warn};
use uuid::Uuid;

use crate::ai::{AiAgent, AiModelSelection, AiQuestionRequest};
use crate::server::context::HandlerContext;
use crate::server::handlers::ai::{
    apply_stream_snapshot_cache_op, build_ai_session_messages_update, emit_ops_for_cache_op,
    ensure_agent, infer_selection_hint_from_messages, map_ai_messages_for_wire,
    map_ai_selection_hint_to_wire, mark_stream_snapshot_terminal, merge_session_selection_hint,
    normalize_part_for_wire, record_session_index_created, resolve_directory, seed_stream_snapshot,
    split_utf8_text_by_max_bytes, stream_key, touch_session_index_updated_at,
};
use crate::server::protocol::ai::AiSessionOrigin;
use crate::server::protocol::{AIGitCommit, ServerMessage};

use super::consts::{
    implement_stage_name, parse_implement_stage_instance, parse_reimplement_stage_instance,
    reimplement_stage_name, stage_artifact_file, ImplementationStageKind,
    IMPLEMENTATION_STAGE_KINDS, MANAGED_BACKLOG_FILE, STAGE_ARTIFACT_REQUIRED_SCHEMA_VERSION,
};
use super::profile::profile_for_stage;
use super::utils::{
    cycle_dir_path, inject_stage_artifact_updated_at, read_json, read_text,
    sanitize_validation_attempt, sanitize_validation_attempts, write_json, write_jsonc_text,
    write_text,
};
use super::{EvolutionManager, MAX_STAGE_RUNTIME_SECS, STAGES};

const VALIDATION_REMINDER_MAX_RETRIES: u32 = 3;
const IMPLEMENT_CONFIG_RESERVED_PREFIX: &str = "__evo_internal_";
const STAGE_STREAM_IDLE_TIMEOUT_SECS: u64 = 600;
const STAGE_STREAM_IDLE_RECOVERY_MAX_ATTEMPTS: u32 = 2;
const STAGE_STREAM_IDLE_RECOVERY_COOLDOWN_MS: u64 = 800;
const STAGE_STREAM_IDLE_RECOVERY_MESSAGE: &str = "继续";
const MAX_AI_SESSION_OP_TEXT_CHUNK_BYTES: usize = 120_000;
const PLAN_MARKDOWN_FILE: &str = "plan.md";
const PLAN_MD_SECTION_GOAL: &str = "# 本轮目标";
const PLAN_MD_SECTION_DIRECTION: &str = "## 方向摘要";
const PLAN_MD_SECTION_WORK_ITEMS: &str = "## 工作项分配";
const PLAN_MD_SECTION_ORDER: &str = "## 执行顺序";
const PLAN_MD_SECTION_CHECKS: &str = "## 验证计划";
const PLAN_MD_SECTION_RISKS: &str = "## 风险与边界";

async fn touch_session_index_updated_at_for_evolution(
    ctx: &HandlerContext,
    project: &str,
    workspace: &str,
    ai_tool: &str,
    session_id: &str,
) {
    let updated_at_ms = Utc::now().timestamp_millis();
    if let Err(e) = touch_session_index_updated_at(
        &ctx.ai_state,
        project,
        workspace,
        ai_tool,
        session_id,
        updated_at_ms,
    )
    .await
    {
        warn!(
            "evolution touch session index updated_at failed: project={}, workspace={}, ai_tool={}, session_id={}, updated_at_ms={}, error={}",
            project, workspace, ai_tool, session_id, updated_at_ms, e
        );
    }
}

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

struct PlanRoutingTables {
    criteria_to_checks: HashMap<String, Vec<String>>,
    check_to_stage_kinds: HashMap<String, HashSet<ImplementationStageKind>>,
}

#[derive(Debug, Clone)]
struct PlanWorkItem {
    id: String,
    title: String,
    implementation_stage_kind: ImplementationStageKind,
    depends_on: Vec<String>,
    linked_check_ids: Vec<String>,
    definition_of_done: Vec<String>,
    targets: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ImplementationStageInstance {
    stage: String,
    kind: ImplementationStageKind,
    index: u32,
    work_item_ids: Vec<String>,
}

#[cfg(test)]
type ImplementLane = ImplementationStageKind;

struct StageRunContext {
    ai_tool: String,
    session_id: String,
    directory: String,
    agent: Arc<dyn AiAgent>,
    model: Option<AiModelSelection>,
    mode: Option<String>,
    config_overrides: Option<HashMap<String, serde_json::Value>>,
}

#[derive(Debug, Clone)]
struct StageValidationContext {
    cycle_id: String,
    verify_iteration: u32,
    backlog_contract_version: u32,
    stage_started_at: Option<chrono::DateTime<Utc>>,
    workspace_root: String,
}

#[derive(Debug, Clone)]
struct ArtifactValidationError {
    code: &'static str,
    message: String,
    issues: Vec<String>,
}

impl ArtifactValidationError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        let message = message.into();
        Self {
            code,
            message: message.clone(),
            issues: vec![message],
        }
    }

    fn with_issues(code: &'static str, message: impl Into<String>, issues: Vec<String>) -> Self {
        let message = message.into();
        let issues = if issues.is_empty() {
            vec![message.clone()]
        } else {
            issues
        };
        Self {
            code,
            message,
            issues,
        }
    }

    fn issues(&self) -> &[String] {
        &self.issues
    }

    #[cfg(test)]
    fn contains(&self, needle: &str) -> bool {
        let needle = needle.trim();
        if needle.is_empty() {
            return false;
        }
        self.message.contains(needle)
            || self.issues.iter().any(|issue| issue.contains(needle))
            || self.to_stage_error().contains(needle)
    }

    fn to_stage_error(&self) -> String {
        format!("evo_stage_output_invalid:{}: {}", self.code, self.message)
    }
}

#[derive(Debug, Clone, Default)]
struct ValidationReport {
    issues: Vec<String>,
}

impl ValidationReport {
    fn push(&mut self, issue: impl Into<String>) {
        let issue = issue.into();
        let normalized = issue.trim();
        if normalized.is_empty() {
            return;
        }
        if !self.issues.iter().any(|existing| existing == normalized) {
            self.issues.push(normalized.to_string());
        }
    }

    fn capture<T>(&mut self, result: Result<T, String>) -> Option<T> {
        match result {
            Ok(value) => Some(value),
            Err(err) => {
                self.push(err);
                None
            }
        }
    }

    fn merge(&mut self, other: ValidationReport) {
        for issue in other.issues {
            self.push(issue);
        }
    }

    fn is_empty(&self) -> bool {
        self.issues.is_empty()
    }

    fn summary(&self) -> String {
        match self.issues.len() {
            0 => "未提供详细错误信息（artifact_contract_violation）".to_string(),
            1 => self.issues[0].clone(),
            count => format!("共 {} 项问题；首项：{}", count, self.issues[0]),
        }
    }

    fn into_error(self, code: &'static str) -> Result<(), ArtifactValidationError> {
        if self.is_empty() {
            Ok(())
        } else {
            let summary = self.summary();
            Err(ArtifactValidationError::with_issues(
                code,
                summary,
                self.issues,
            ))
        }
    }
}

#[derive(Debug, Clone)]
struct ValidationReminderSpec {
    error_code: String,
    summary: String,
    issues: Vec<String>,
    fix_hints: Vec<String>,
    immediate_fix_actions: Vec<String>,
    raw_error: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ManagedBacklogFile {
    #[serde(rename = "$schema_version", default = "default_schema_version")]
    schema_version: String,
    cycle_id: String,
    verify_iteration: u32,
    items: Vec<ManagedBacklogItem>,
    summary: ManagedBacklogSummary,
    updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ManagedBacklogItem {
    id: String,
    source_criteria_id: String,
    source_check_id: String,
    work_item_id: String,
    implementation_stage_kind: String,
    #[serde(default)]
    requirement_ref: String,
    #[serde(default)]
    description: String,
    status: String,
    #[serde(default)]
    evidence: serde_json::Value,
    #[serde(default)]
    notes: String,
    created_at: String,
    updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ManagedBacklogSummary {
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
    implementation_stage_kind: String,
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

fn implementation_stage_kind_rank(kind: ImplementationStageKind) -> usize {
    IMPLEMENTATION_STAGE_KINDS
        .iter()
        .position(|candidate| *candidate == kind)
        .unwrap_or(IMPLEMENTATION_STAGE_KINDS.len())
}

fn implementation_stage_kind_for_stage(stage: &str) -> Option<ImplementationStageKind> {
    if let Some((kind, _)) = parse_implement_stage_instance(stage) {
        return Some(kind);
    }
    match stage.trim().to_ascii_lowercase().as_str() {
        "implement_general" => Some(ImplementationStageKind::General),
        "implement_visual" => Some(ImplementationStageKind::Visual),
        "implement_advanced" => Some(ImplementationStageKind::Advanced),
        _ => None,
    }
}

fn is_runtime_implement_stage(stage: &str) -> bool {
    implementation_stage_kind_for_stage(stage).is_some()
}

fn is_runtime_reimplement_stage(stage: &str) -> bool {
    parse_reimplement_stage_instance(stage).is_some()
}

fn parse_non_empty_string(value: &serde_json::Value) -> Option<String> {
    value
        .as_str()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn parse_string_list(
    item: &serde_json::Map<String, serde_json::Value>,
    key: &str,
    item_label: &str,
    allow_empty: bool,
) -> Result<Vec<String>, String> {
    let values = item
        .get(key)
        .and_then(|value| value.as_array())
        .ok_or_else(|| format!("{} 缺少 {}", item_label, key))?;
    if !allow_empty && values.is_empty() {
        return Err(format!("{}.{} 不能为空", item_label, key));
    }
    let mut out = Vec::with_capacity(values.len());
    for (idx, value) in values.iter().enumerate() {
        let parsed = value
            .as_str()
            .map(|raw| raw.trim().to_string())
            .filter(|raw| !raw.is_empty())
            .ok_or_else(|| format!("{}.{}[{}] 必须是非空字符串", item_label, key, idx))?;
        out.push(parsed);
    }
    Ok(out)
}

fn collect_plan_acceptance_criteria_ids(
    value: &serde_json::Value,
    report: &mut ValidationReport,
) -> Option<HashSet<String>> {
    let acceptance_criteria = value.get("acceptance_criteria").and_then(|v| v.as_array());
    let mut criteria_ids = HashSet::new();
    match acceptance_criteria {
        Some(items) => {
            if items.is_empty() {
                report.push("plan.jsonc.acceptance_criteria 不能为空");
            }
            for (idx, item) in items.iter().enumerate() {
                let Some(criteria_id) = id_from_value(item, &["criteria_id"]) else {
                    report.push(format!("acceptance_criteria[{}] 缺少 criteria_id", idx));
                    continue;
                };
                if !criteria_ids.insert(criteria_id.clone()) {
                    report.push(format!(
                        "plan.jsonc.acceptance_criteria 存在重复 criteria_id: {}",
                        criteria_id
                    ));
                }
                let description = item
                    .get("description")
                    .and_then(|v| v.as_str())
                    .map(|v| v.trim())
                    .unwrap_or_default();
                if description.is_empty() {
                    report.push(format!("acceptance_criteria[{}].description 不能为空", idx));
                }
            }
            Some(criteria_ids)
        }
        None => {
            report.push("plan.jsonc 缺少 acceptance_criteria");
            None
        }
    }
}

fn parse_plan_routing_tables_report(
    value: &serde_json::Value,
) -> (Option<PlanRoutingTables>, ValidationReport) {
    let mut report = ValidationReport::default();
    let expected_criteria_ids = collect_plan_acceptance_criteria_ids(value, &mut report);

    let checks = value
        .pointer("/verification_plan/checks")
        .and_then(|v| v.as_array());
    let mut check_ids = HashSet::new();
    match checks {
        Some(checks) => {
            for (idx, check) in checks.iter().enumerate() {
                match id_from_value(check, &["id"]) {
                    Some(check_id) => {
                        if !check_ids.insert(check_id.clone()) {
                            report.push(format!(
                                "verification_plan.checks 存在重复 id: {}",
                                check_id
                            ));
                        }
                    }
                    None => report.push(format!("verification_plan.checks[{}] 缺少有效 id", idx)),
                }
            }
            if check_ids.is_empty() {
                report.push("verification_plan.checks 不能为空");
            }
        }
        None => report.push("plan.jsonc 缺少 verification_plan.checks"),
    }

    let work_items = value.pointer("/work_items").and_then(|v| v.as_array());
    let mut work_item_ids = HashSet::new();
    let mut check_to_stage_kinds: HashMap<String, HashSet<ImplementationStageKind>> =
        HashMap::new();
    match work_items {
        Some(work_items) => {
            if work_items.is_empty() {
                report.push("work_items 不能为空");
            }
            for (idx, item) in work_items.iter().enumerate() {
                let Some(item_obj) = item.as_object() else {
                    report.push(format!("work_items[{}] 必须是对象", idx));
                    continue;
                };

                let work_id = match item_obj.get("id").and_then(parse_non_empty_string) {
                    Some(work_id) => {
                        if !work_item_ids.insert(work_id.clone()) {
                            report.push(format!("work_items.id 存在重复值: {}", work_id));
                        }
                        Some(work_id)
                    }
                    None => {
                        report.push(format!("work_items[{}] 缺少 id", idx));
                        None
                    }
                };

                let agent = match item_obj
                    .get("implementation_stage_kind")
                    .and_then(|v| v.as_str())
                {
                    Some(agent_raw) => match ImplementationStageKind::parse(agent_raw) {
                        Some(agent) => {
                            if matches!(agent, ImplementationStageKind::Advanced) {
                                report.push(format!(
                                    "work_items[{}].implementation_stage_kind 仅允许 general 或 visual",
                                    idx
                                ));
                                None
                            } else {
                                Some(agent)
                            }
                        }
                        None => {
                            report.push(format!(
                                "work_items[{}].implementation_stage_kind 非法: {}",
                                idx, agent_raw
                            ));
                            None
                        }
                    },
                    None => {
                        report.push(format!(
                            "work_items[{}] 缺少 implementation_stage_kind",
                            idx
                        ));
                        None
                    }
                };

                let linked = match item_obj.get("linked_check_ids").and_then(|v| v.as_array()) {
                    Some(linked) => linked,
                    None => {
                        report.push(format!("work_items[{}] 缺少 linked_check_ids", idx));
                        continue;
                    }
                };
                if linked.is_empty() {
                    report.push(format!("work_items[{}].linked_check_ids 不能为空", idx));
                }
                for (check_idx, check_value) in linked.iter().enumerate() {
                    let Some(check_id) = check_value
                        .as_str()
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                    else {
                        report.push(format!(
                            "work_items[{}].linked_check_ids[{}] 必须是非空字符串",
                            idx, check_idx
                        ));
                        continue;
                    };
                    if !check_ids.contains(&check_id) {
                        report.push(format!(
                            "work_items[{}].linked_check_ids 包含未知 check_id: {}",
                            idx, check_id
                        ));
                        continue;
                    }
                    if let Some(agent) = agent {
                        let _ = &work_id;
                        check_to_stage_kinds
                            .entry(check_id)
                            .or_default()
                            .insert(agent);
                    }
                }
            }
        }
        None => report.push("plan.jsonc 缺少 work_items"),
    }

    let acceptance_mapping = value
        .pointer("/verification_plan/acceptance_mapping")
        .and_then(|v| v.as_array());
    let mut criteria_to_checks: HashMap<String, Vec<String>> = HashMap::new();
    match acceptance_mapping {
        Some(acceptance_mapping) => {
            let mut seen_criteria_ids = HashSet::new();
            for (idx, item) in acceptance_mapping.iter().enumerate() {
                let Some(item_obj) = item.as_object() else {
                    report.push(format!("acceptance_mapping[{}] 必须是对象", idx));
                    continue;
                };
                let Some(criteria_id) =
                    item_obj.get("criteria_id").and_then(parse_non_empty_string)
                else {
                    report.push(format!("acceptance_mapping[{}] 缺少 criteria_id", idx));
                    continue;
                };
                if !seen_criteria_ids.insert(criteria_id.clone()) {
                    report.push(format!(
                        "verification_plan.acceptance_mapping 存在重复 criteria_id: {}",
                        criteria_id
                    ));
                }
                let Some(check_ids_raw) = item_obj.get("check_ids").and_then(|v| v.as_array())
                else {
                    report.push(format!("acceptance_mapping[{}] 缺少 check_ids", idx));
                    continue;
                };
                if check_ids_raw.is_empty() {
                    report.push(format!("acceptance_mapping[{}].check_ids 不能为空", idx));
                }

                let mut mapped_to_work_item = false;
                let mut mapped_checks = Vec::with_capacity(check_ids_raw.len());
                for (check_idx, value) in check_ids_raw.iter().enumerate() {
                    let Some(check_id) = value
                        .as_str()
                        .map(|v| v.trim().to_string())
                        .filter(|v| !v.is_empty())
                    else {
                        report.push(format!(
                            "acceptance_mapping[{}].check_ids[{}] 必须是非空字符串",
                            idx, check_idx
                        ));
                        continue;
                    };
                    if !check_ids.contains(&check_id) {
                        report.push(format!(
                            "acceptance_mapping[{}].check_ids 包含未知 check_id: {}",
                            idx, check_id
                        ));
                        continue;
                    }
                    if check_to_stage_kinds.contains_key(&check_id) {
                        mapped_to_work_item = true;
                    }
                    mapped_checks.push(check_id);
                }
                if !mapped_to_work_item {
                    report.push(format!(
                        "acceptance_mapping[{}].check_ids 未关联任何 work_item",
                        idx
                    ));
                }
                criteria_to_checks.insert(criteria_id, mapped_checks);
            }
            if acceptance_mapping.is_empty() {
                report.push("verification_plan.acceptance_mapping 不能为空");
            }
        }
        None => report.push("plan.jsonc 缺少 verification_plan.acceptance_mapping"),
    }
    if let Some(expected_criteria_ids) = expected_criteria_ids {
        let actual_criteria_ids: HashSet<String> = criteria_to_checks.keys().cloned().collect();
        if actual_criteria_ids != expected_criteria_ids {
            report.push(format!(
                "verification_plan.acceptance_mapping 与 plan.acceptance_criteria 不一致: mapping={:?}, plan={:?}",
                actual_criteria_ids, expected_criteria_ids
            ));
        }
    }

    if report.is_empty() {
        (
            Some(PlanRoutingTables {
                criteria_to_checks,
                check_to_stage_kinds,
            }),
            report,
        )
    } else {
        (None, report)
    }
}

fn parse_plan_routing_tables(value: &serde_json::Value) -> Result<PlanRoutingTables, String> {
    let (tables, report) = parse_plan_routing_tables_report(value);
    tables.ok_or_else(|| report.summary())
}

fn parse_plan_work_items(value: &serde_json::Value) -> Result<Vec<PlanWorkItem>, String> {
    let work_items = value
        .get("work_items")
        .and_then(|items| items.as_array())
        .ok_or_else(|| "plan.jsonc 缺少 work_items".to_string())?;
    if work_items.is_empty() {
        return Err("plan.jsonc.work_items 不能为空".to_string());
    }

    let mut seen_ids = HashSet::new();
    let mut parsed_items = Vec::with_capacity(work_items.len());

    for (idx, item) in work_items.iter().enumerate() {
        let item_obj = item
            .as_object()
            .ok_or_else(|| format!("work_items[{}] 必须是对象", idx))?;
        let item_label = format!("work_items[{}]", idx);
        let id = item_obj
            .get("id")
            .and_then(parse_non_empty_string)
            .ok_or_else(|| format!("{} 缺少 id", item_label))?;
        if !seen_ids.insert(id.clone()) {
            return Err(format!("work_items.id 存在重复值: {}", id));
        }

        let title = item_obj
            .get("title")
            .and_then(parse_non_empty_string)
            .ok_or_else(|| format!("{}.title 不能为空", item_label))?;
        let implementation_stage_kind = item_obj
            .get("implementation_stage_kind")
            .and_then(|value| value.as_str())
            .and_then(ImplementationStageKind::parse)
            .ok_or_else(|| format!("{}.implementation_stage_kind 缺失或非法", item_label))?;
        if implementation_stage_kind == ImplementationStageKind::Advanced {
            return Err(format!(
                "{}.implementation_stage_kind 仅允许 general 或 visual",
                item_label
            ));
        }

        let depends_on = match item_obj.get("depends_on") {
            Some(value) => {
                let depends_on = value
                    .as_array()
                    .ok_or_else(|| format!("{}.depends_on 必须是数组", item_label))?;
                let mut parsed = Vec::with_capacity(depends_on.len());
                for (dep_idx, dep) in depends_on.iter().enumerate() {
                    let dep = dep
                        .as_str()
                        .map(|raw| raw.trim().to_string())
                        .filter(|raw| !raw.is_empty())
                        .ok_or_else(|| {
                            format!("{}.depends_on[{}] 必须是非空字符串", item_label, dep_idx)
                        })?;
                    parsed.push(dep);
                }
                parsed
            }
            None => Vec::new(),
        };
        let linked_check_ids = parse_string_list(item_obj, "linked_check_ids", &item_label, false)?;
        let definition_of_done =
            parse_string_list(item_obj, "definition_of_done", &item_label, false)?;
        let targets = parse_string_list(item_obj, "targets", &item_label, true)?;

        parsed_items.push(PlanWorkItem {
            id,
            title,
            implementation_stage_kind,
            depends_on,
            linked_check_ids,
            definition_of_done,
            targets,
        });
    }

    let known_ids: HashSet<String> = parsed_items.iter().map(|item| item.id.clone()).collect();
    for item in &parsed_items {
        for dependency in &item.depends_on {
            if dependency == &item.id {
                return Err(format!("work_item {} 不能依赖自身", item.id));
            }
            if !known_ids.contains(dependency) {
                return Err(format!(
                    "work_item {} 依赖了未知 work_item: {}",
                    item.id, dependency
                ));
            }
        }
    }

    let _ = build_implementation_stage_instances(&parsed_items)?;
    Ok(parsed_items)
}

fn build_implementation_stage_instances(
    work_items: &[PlanWorkItem],
) -> Result<Vec<ImplementationStageInstance>, String> {
    let mut indegree: HashMap<String, usize> = HashMap::new();
    let mut dependents: HashMap<String, Vec<String>> = HashMap::new();
    let mut original_positions: HashMap<String, usize> = HashMap::new();
    let mut by_id: HashMap<String, &PlanWorkItem> = HashMap::new();

    for (idx, item) in work_items.iter().enumerate() {
        indegree.insert(item.id.clone(), item.depends_on.len());
        original_positions.insert(item.id.clone(), idx);
        by_id.insert(item.id.clone(), item);
        for dependency in &item.depends_on {
            dependents
                .entry(dependency.clone())
                .or_default()
                .push(item.id.clone());
        }
    }

    let mut kind_indexes: HashMap<ImplementationStageKind, u32> = HashMap::new();
    let mut remaining: HashSet<String> = work_items.iter().map(|item| item.id.clone()).collect();
    let mut instances = Vec::new();

    while !remaining.is_empty() {
        let mut ready = remaining
            .iter()
            .filter_map(|id| {
                let pending = indegree.get(id).copied().unwrap_or(usize::MAX);
                (pending == 0).then_some(id.clone())
            })
            .collect::<Vec<String>>();
        if ready.is_empty() {
            return Err("work_items.depends_on 存在循环依赖".to_string());
        }

        ready.sort_by(|left, right| {
            let left_item = by_id.get(left).copied().expect("ready item must exist");
            let right_item = by_id.get(right).copied().expect("ready item must exist");
            implementation_stage_kind_rank(left_item.implementation_stage_kind)
                .cmp(&implementation_stage_kind_rank(
                    right_item.implementation_stage_kind,
                ))
                .then_with(|| {
                    original_positions
                        .get(left)
                        .copied()
                        .unwrap_or(usize::MAX)
                        .cmp(&original_positions.get(right).copied().unwrap_or(usize::MAX))
                })
        });

        for kind in IMPLEMENTATION_STAGE_KINDS {
            let work_item_ids = ready
                .iter()
                .filter(|id| {
                    by_id
                        .get(id.as_str())
                        .map(|item| item.implementation_stage_kind == kind)
                        .unwrap_or(false)
                })
                .cloned()
                .collect::<Vec<String>>();
            if work_item_ids.is_empty() {
                continue;
            }

            let index = kind_indexes.entry(kind).or_insert(0);
            *index += 1;
            instances.push(ImplementationStageInstance {
                stage: implement_stage_name(kind, *index),
                kind,
                index: *index,
                work_item_ids,
            });
        }

        for id in ready {
            remaining.remove(&id);
            if let Some(children) = dependents.get(&id) {
                for child in children {
                    if let Some(pending) = indegree.get_mut(child) {
                        *pending = pending.saturating_sub(1);
                    }
                }
            }
        }
    }

    Ok(merge_adjacent_implementation_stage_instances(instances))
}

fn merge_adjacent_implementation_stage_instances(
    instances: Vec<ImplementationStageInstance>,
) -> Vec<ImplementationStageInstance> {
    let mut merged: Vec<ImplementationStageInstance> = Vec::with_capacity(instances.len());

    for instance in instances {
        if let Some(previous) = merged.last_mut() {
            if previous.kind == instance.kind {
                previous.work_item_ids.extend(instance.work_item_ids);
                continue;
            }
        }
        merged.push(instance);
    }

    merged
}

fn validate_plan_markdown_artifact(
    cycle_dir: &Path,
    _plan_value: &serde_json::Value,
) -> Result<(), String> {
    read_text_file(cycle_dir, PLAN_MARKDOWN_FILE).map(|_| ())
}

#[cfg(test)]
fn is_criteria_failure_status(status: &str) -> bool {
    matches!(
        normalize_acceptance_evaluation_status(status),
        Some("fail" | "insufficient_evidence")
    )
}

fn is_carryover_failure_status(status: &str) -> bool {
    matches!(
        status.trim().to_ascii_lowercase().as_str(),
        "missing" | "blocked"
    )
}

fn normalize_acceptance_evaluation_status(status: &str) -> Option<&'static str> {
    match status.trim().to_ascii_lowercase().as_str() {
        "pass" => Some("pass"),
        "fail" => Some("fail"),
        "insufficient_evidence" => Some("insufficient_evidence"),
        _ => None,
    }
}

fn parse_adjudication_result_text(value: &str) -> Option<bool> {
    let normalized = value.trim().to_ascii_lowercase();
    if normalized == "pass" {
        return Some(true);
    }
    if normalized == "fail" {
        return Some(false);
    }
    None
}

fn parse_adjudication_result_from_json(value: &serde_json::Value) -> Option<bool> {
    let adjudication = value
        .pointer("/adjudication/overall_result/result")
        .and_then(|v| v.as_str())
        .and_then(parse_adjudication_result_text);
    if adjudication.is_some() {
        return adjudication;
    }

    let overall = value
        .pointer("/overall_result/result")
        .and_then(|v| v.as_str())
        .and_then(parse_adjudication_result_text);
    if overall.is_some() {
        return overall;
    }

    value
        .pointer("/decision/result")
        .and_then(|v| v.as_str())
        .and_then(parse_adjudication_result_text)
}

fn should_start_next_round(status: &str, global_loop_round: u32, loop_round_limit: u32) -> bool {
    status == "completed" && global_loop_round < loop_round_limit
}

fn read_json_file(cycle_dir: &Path, file_name: &str) -> Result<serde_json::Value, String> {
    let path = cycle_dir.join(file_name);
    read_json(&path)
}

fn read_text_file(cycle_dir: &Path, file_name: &str) -> Result<String, String> {
    let path = cycle_dir.join(file_name);
    read_text(&path)
}

fn parse_non_empty_string_field(value: Option<&serde_json::Value>) -> Option<String> {
    value
        .and_then(|v| v.as_str())
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

fn extract_cycle_title_from_direction_stage(stage_json: &serde_json::Value) -> Option<String> {
    parse_non_empty_string_field(stage_json.get("title"))
        .or_else(|| parse_non_empty_string_field(stage_json.get("direction_statement")))
}

fn parse_rfc3339_utc(raw: &str) -> Option<chrono::DateTime<Utc>> {
    chrono::DateTime::parse_from_rfc3339(raw)
        .ok()
        .map(|v| v.with_timezone(&Utc))
}

fn extract_artifact_updated_at(value: &serde_json::Value) -> Option<chrono::DateTime<Utc>> {
    for pointer in [
        "/updated_at",
        "/system_metadata/updated_at",
        "/timing/completed_at",
    ] {
        if let Some(ts) = value.pointer(pointer).and_then(|v| v.as_str()) {
            if let Some(parsed) = parse_rfc3339_utc(ts.trim()) {
                return Some(parsed);
            }
        }
    }
    None
}

fn ensure_artifact_freshness(
    label: &str,
    value: &serde_json::Value,
    started_at: Option<chrono::DateTime<Utc>>,
) -> Result<(), String> {
    let Some(started_at) = started_at else {
        return Ok(());
    };
    // updated_at 由系统在接收产物时自动注入；若代理未提供则跳过时效校验。
    let Some(updated_at) = extract_artifact_updated_at(value) else {
        return Ok(());
    };
    if updated_at < started_at {
        return Err(format!(
            "{} 时间戳早于本次阶段开始时间: updated_at={}, stage_started_at={}",
            label,
            updated_at.to_rfc3339(),
            started_at.to_rfc3339()
        ));
    }
    Ok(())
}

fn ensure_cycle_id_matches(
    label: &str,
    value: &serde_json::Value,
    expected_cycle_id: &str,
) -> Result<(), String> {
    let cycle_id = value
        .get("cycle_id")
        .and_then(|v| v.as_str())
        .map(|v| v.trim())
        .filter(|v| !v.is_empty())
        .ok_or_else(|| format!("{} 缺少 cycle_id", label))?;
    if cycle_id != expected_cycle_id {
        return Err(format!(
            "{}.cycle_id 不匹配: {} != {}",
            label, cycle_id, expected_cycle_id
        ));
    }
    Ok(())
}

/// WI-004: Evolution 结构化错误日志落盘
/// 输出字段：cycle_id、stage、error_code、error_message
/// 日志经 tracing Layer 最终写入 ~/.tidyflow/logs/YYYY-MM-DD.log
fn log_evolution_error(cycle_id: &str, stage: &str, error_code: &str, message: &str) {
    error!(
        cycle_id = cycle_id,
        stage = stage,
        error_code = error_code,
        "evolution error: {}",
        message
    );
}

/// WI-005: 校验工作区 workspace_root 及 cycle 目录存在且可访问
fn check_workspace_boundary(workspace_root: &str, cycle_id: &str) -> Result<(), String> {
    let root = workspace_root.trim();
    if root.is_empty() {
        return Err(
            "evo_boundary_empty_project: workspace_root 为空，请先配置有效的项目目录".to_string(),
        );
    }
    let root_path = std::path::Path::new(root);
    if !root_path.exists() {
        return Err(format!(
            "evo_boundary_workspace_missing: workspace_root 不存在: {}",
            root
        ));
    }
    let cycle_dir = root_path.join(".tidyflow").join("evolution").join(cycle_id);
    if !cycle_dir.exists() {
        return Err(format!(
            "evo_boundary_cycle_dir_missing: cycle 目录不存在: {}",
            cycle_dir.display()
        ));
    }
    Ok(())
}
fn ensure_schema_version(
    label: &str,
    value: &serde_json::Value,
    expected: &str,
) -> Result<(), String> {
    let version = value
        .get("$schema_version")
        .and_then(|v| v.as_str())
        .map(|v| v.trim())
        .filter(|v| !v.is_empty())
        .ok_or_else(|| format!("{} 缺少 $schema_version 字段", label))?;
    if version != expected {
        return Err(format!(
            "{} $schema_version 版本不符: 期望 {}, 实际 {}",
            label, expected, version
        ));
    }
    Ok(())
}

/// WI-003: 校验阶段产物的 `stage` 字段必须等于期望值
fn ensure_stage_field_matches(
    label: &str,
    value: &serde_json::Value,
    expected_stage: &str,
) -> Result<(), String> {
    let stage = value
        .get("stage")
        .and_then(|v| v.as_str())
        .map(|v| v.trim())
        .filter(|v| !v.is_empty())
        .ok_or_else(|| format!("{} 缺少 stage 字段", label))?;
    if stage != expected_stage {
        return Err(format!(
            "{} stage 字段不符: 期望 {}, 实际 {}",
            label, expected_stage, stage
        ));
    }
    Ok(())
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

/// 从 verify.jsonc 的 full_next_iteration_requirements 中提取需求项列表。
/// 兼容三种格式：
/// 1. 直接数组 `[...]`
/// 2. 对象 `{"items": [...]}`
/// 3. 对象 `{"acceptance_failures": [...], "carryover_failures": [...]}`
fn extract_verify_requirements(verify: &serde_json::Value) -> Option<Vec<serde_json::Value>> {
    let fnir = verify
        .pointer("/adjudication/full_next_iteration_requirements")
        .or_else(|| verify.pointer("/full_next_iteration_requirements"))?;

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

/// 为 verify requirement 生成“覆盖匹配键”集合，用于与 verify 未通过项对齐。
///
/// 兼容场景：
/// - 旧格式：仅包含 `criteria_id`/`id`
/// - 新格式：同时包含 `id` + `criteria_id` + `source_criteria_id`
/// - 字符串条目：`["AC-001", ...]`
///
/// 注意：这里不做“唯一主键”判定，而是收集所有可用标识。
/// 这样可以避免当 requirement 同时携带 `id` 与 `criteria_id` 时，
/// 由于主键选择顺序不同导致误判“未覆盖 verify 未通过项”。
fn collect_requirement_match_keys(
    items: &[serde_json::Value],
    label: &str,
) -> Result<HashSet<String>, String> {
    const CANDIDATE_KEYS: &[&str] = &[
        "criteria_id",
        "source_criteria_id",
        "criterion_id",
        "requirement_id",
        "failure_backlog_id",
        "backlog_id",
        "id",
        "item_id",
        "title",
        "check_id",
        "source_check_id",
    ];

    let mut keys = HashSet::new();
    for (idx, item) in items.iter().enumerate() {
        let mut matched = false;

        if let Some(value) = item.as_str() {
            let normalized = value.trim();
            if !normalized.is_empty() {
                keys.insert(normalized.to_string());
                matched = true;
            }
        }

        if let Some(obj) = item.as_object() {
            for key in CANDIDATE_KEYS {
                if let Some(value) = obj.get(*key).and_then(|v| v.as_str()) {
                    let normalized = value.trim();
                    if !normalized.is_empty() {
                        keys.insert(normalized.to_string());
                        matched = true;
                    }
                }
            }
        }

        if !matched {
            return Err(format!(
                "{}[{}] 缺少可匹配标识（至少包含 criteria_id/source_criteria_id/id/item_id/title 之一）",
                label, idx
            ));
        }
    }
    Ok(keys)
}

fn as_failing_status(status: &str) -> bool {
    matches!(
        status.trim().to_ascii_lowercase().as_str(),
        "fail" | "failed" | "insufficient_evidence" | "missing" | "not_covered" | "not_done"
    )
}

fn is_valid_implementation_stage_kind(agent: &str) -> bool {
    let normalized = agent.trim().to_ascii_lowercase();
    normalized == "unknown" || ImplementationStageKind::parse(&normalized).is_some()
}

fn is_unknown_selector_value(value: &str) -> bool {
    let normalized = value.trim();
    normalized.is_empty() || normalized.eq_ignore_ascii_case("unknown")
}

fn backlog_contract_version_from_cycle(cycle_dir: &Path) -> Result<u32, String> {
    let cycle = read_json_file(cycle_dir, "cycle.jsonc")?;
    let version = cycle
        .get("backlog_contract_version")
        .and_then(|v| v.as_u64())
        .unwrap_or(1) as u32;
    Ok(version)
}

fn managed_backlog_path(cycle_dir: &Path) -> PathBuf {
    cycle_dir.join(MANAGED_BACKLOG_FILE)
}

fn normalize_backlog_status(status: &str) -> Option<&'static str> {
    match status.trim().to_ascii_lowercase().as_str() {
        "done" => Some("done"),
        "blocked" => Some("blocked"),
        "not_done" | "notdone" | "missing" => Some("not_done"),
        _ => None,
    }
}

fn coverage_summary(items: &[ManagedBacklogItem]) -> ManagedBacklogSummary {
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
    ManagedBacklogSummary {
        total,
        done,
        blocked,
        not_done,
    }
}

fn validate_requirement_selector_against_plan(
    selector_label: &str,
    source_criteria_id: &str,
    source_check_id: &str,
    work_item_id: &str,
    implementation_stage_kind: ImplementationStageKind,
    tables: &PlanRoutingTables,
    check_to_work_items: &HashMap<String, Vec<(String, ImplementationStageKind)>>,
) -> Result<(), String> {
    let mapped_checks = tables
        .criteria_to_checks
        .get(source_criteria_id)
        .ok_or_else(|| {
            format!(
                "{}.source_criteria_id 未在 plan.acceptance_mapping 中定义: {}",
                selector_label, source_criteria_id
            )
        })?;
    if !mapped_checks
        .iter()
        .any(|check_id| check_id == source_check_id)
    {
        return Err(format!(
            "{}.source_check_id 与 source_criteria_id 不匹配: {} -> {}",
            selector_label, source_criteria_id, source_check_id
        ));
    }
    let mapped_agents = tables
        .check_to_stage_kinds
        .get(source_check_id)
        .ok_or_else(|| {
            format!(
                "{}.source_check_id 未关联任何 implementation_stage_kind: {}",
                selector_label, source_check_id
            )
        })?;
    if !mapped_agents.contains(&implementation_stage_kind) {
        return Err(format!(
            "{}.implementation_stage_kind 与 source_check_id 不匹配: {} -> {}",
            selector_label,
            source_check_id,
            implementation_stage_kind.as_str()
        ));
    }
    let mapped_work_items = check_to_work_items.get(source_check_id).ok_or_else(|| {
        format!(
            "{}.source_check_id 未关联任何 work_item: {}",
            selector_label, source_check_id
        )
    })?;
    if !mapped_work_items
        .iter()
        .any(|(id, agent)| id == work_item_id && *agent == implementation_stage_kind)
    {
        return Err(format!(
            "{}.work_item_id 与 source_check_id/implementation_stage_kind 不匹配: ({}, {}, {})",
            selector_label,
            source_check_id,
            work_item_id,
            implementation_stage_kind.as_str()
        ));
    }
    Ok(())
}

fn render_jsonc_template(template: &str, replacements: &[(&str, String)]) -> String {
    let mut output = template.to_string();
    for (key, value) in replacements {
        output = output.replace(key, value);
    }
    output
}

fn direction_stage_template(cycle_id: &str) -> String {
    render_jsonc_template(
        r#"{
  // Direction 阶段模板：只填写注释标明的可写字段
  // schema 版本，由系统维护
  "$schema_version": "2.0",
  // 固定阶段名，不可修改
  "stage": "direction",
  // 当前循环 ID，必须与 cycle.jsonc 保持一致
  "cycle_id": "__CYCLE_ID__",
  // 阶段状态；运行中写 running，完成后写 completed/failed/blocked
  "status": "running",
  // 本轮唯一方向句，必须是非空字符串；一句话即可说明本轮要进化什么
  "direction_statement": "",
  // 更新时间，由系统自动注入，代理无需填写
  "updated_at": ""
}
"#,
        &[("__CYCLE_ID__", cycle_id.to_string())],
    )
}

fn plan_stage_template(cycle_id: &str) -> String {
    render_jsonc_template(
        r#"{
  // Plan 阶段模板：拆解 work_items 与验证计划
  "$schema_version": "2.0",
  // 固定阶段名，不可修改
  "stage": "plan",
  // 当前循环 ID，必须与 direction.jsonc / cycle.jsonc 保持一致
  "cycle_id": "__CYCLE_ID__",
  // 阶段状态；运行中写 running，完成后写 completed/failed/blocked
  "status": "running",
  "decision": {
    // 决策结果；plan 阶段通常保留 n/a
    "result": "n/a",
    // 规划原因或约束说明，必须非空
    "reason": ""
  },
  // 本轮计划摘要，必须非空
  "summary": "",
  // 本轮验收标准，由 plan 阶段定义且必须可验证
  "acceptance_criteria": [
    // {
    //   "criteria_id": "AC-001",
    //   "description": "可验证描述"
    // }
  ],
  // 工作项列表，不能为空
  "work_items": [
    // {
    //   "id": "WI-001",
    //   "title": "实现播放控制入口",
    //   "type": "code",
    //   "priority": "p0",
    //   "depends_on": [],
    //   "targets": ["clients/desktop/src/player.tsx"],
    //   "definition_of_done": ["按钮可触发播放/暂停"],
    //   "risk": "low",
    //   "rollback": "git restore --source=HEAD -- <path>",
    //   "implementation_stage_kind": "general", // 仅允许 general 或 visual
    //   "linked_check_ids": ["CHK-001"]
    // }
  ],
  "verification_plan": {
    // 验证检查项，id 必须唯一且可执行
    "checks": [
      // {
      //   "id": "CHK-001",
      //   "name": "cargo test",
      //   "kind": "command",
      //   "command": "cargo test -p tidyflow-core evolution",
      //   "expected": "exit_code=0"
      // }
    ],
    // 验收标准与检查项的映射，必须完整覆盖 plan.acceptance_criteria
    "acceptance_mapping": [
      // {
      //   "criteria_id": "AC-001",
      //   "description": "播放控制可验证",
      //   "check_ids": ["CHK-001"]
      // }
    ]
  },
  // 更新时间，由系统自动注入，代理无需填写
  "updated_at": ""
}
"#,
        &[("__CYCLE_ID__", cycle_id.to_string())],
    )
}

fn plan_markdown_template(cycle_id: &str) -> String {
    format!(
        r#"{goal}
- 循环 ID：{cycle_id}
- 本轮目标：

{direction}
- 方向句：
- 计划阶段将在此处补充验收标准：

{work_items}
### WI-001 占位标题
- 负责代理：
- 目标文件：
- 完成定义：
- 关联检查：
- 风险：

{order}
1. 先完成方向对应的核心工作项。
2. 再按依赖顺序推进其余工作项。
3. 最后集中执行验证计划。

{checks}
### CHK-001 占位检查
- 执行方式：
- 预期结果：
- 覆盖工作项：

{risks}
- 风险：
- 非目标：
"#,
        goal = PLAN_MD_SECTION_GOAL,
        cycle_id = cycle_id,
        direction = PLAN_MD_SECTION_DIRECTION,
        work_items = PLAN_MD_SECTION_WORK_ITEMS,
        order = PLAN_MD_SECTION_ORDER,
        checks = PLAN_MD_SECTION_CHECKS,
        risks = PLAN_MD_SECTION_RISKS,
    )
}

fn implement_stage_template(
    stage: &str,
    cycle_id: &str,
    verify_iteration: u32,
    backlog_contract_version: u32,
) -> String {
    render_jsonc_template(
        r#"{
  // 实现阶段模板：仅回填当前阶段实例负责的执行结果
  "$schema_version": "2.0",
  // 当前实现阶段名，固定为系统调度值
  "stage": "__STAGE__",
  // 当前循环 ID，必须与 cycle.jsonc 保持一致
  "cycle_id": "__CYCLE_ID__",
  // 阶段状态；完成后写 done/blocked/failed/skipped
  "status": "running",
  "decision": {
    // 实施阶段通常保留 n/a；如需说明可写 reason
    "result": "n/a",
    "reason": ""
  },
  // 当前阶段实例的实施摘要，必须存在
  "summary": "",
  // 工作项执行结果，仅填写当前阶段实例处理的 work_items
  "work_item_results": [
    // {
    //   "work_item_id": "WI-001",
    //   "status": "done",
    //   "summary": "完成内容摘要",
    //   "evidence_paths": []
    // }
  ],
  // 实际变更文件路径数组，可为空
  "changed_files": [],
  // 执行过的命令数组，可为空
  "commands_executed": [],
  // 快速检查结果数组；即使没有检查项也必须保留 []
  "quick_checks": [
    // {
    //   "name": "cargo test -p tidyflow-core evolution",
    //   "result": "pass",
    //   "details": "可选补充说明"
    // }
  ],
  // 当前 verify 重试轮次，由系统注入，不可改为其它数字
  "verify_iteration": __VERIFY_ITERATION__,
  // backlog 契约版本，由系统注入
  "backlog_contract_version": __BACKLOG_CONTRACT_VERSION__,
  // backlog v2 回填数组。VERIFY_ITERATION>0 且 BACKLOG_CONTRACT_VERSION>=2 时必须按此结构填写。
  // reimplement 阶段必须沿用 ISSUES_TO_FIX / managed.backlog.jsonc 中原始整改项的 implementation_stage_kind。
  "backlog_resolution_updates": [
    // {
    //   "source_criteria_id": "AC-001",
    //   "source_check_id": "CHK-001",
    //   "work_item_id": "WI-001",
    //   "implementation_stage_kind": "__BACKLOG_IMPLEMENTATION_STAGE_KIND__",
    //   "status": "done",
    //   "evidence": null,
    //   "notes": ""
    // }
  ],
  // 以下三个字段由系统同步回填；代理不要伪造主键或改写系统统计
  "failure_backlog": [],
  "backlog_coverage": [],
  "backlog_coverage_summary": {
    "total": 0,
    "done": 0,
    "blocked": 0,
    "not_done": 0
  },
  // 更新时间，由系统自动注入，代理无需填写
  "updated_at": ""
}
"#,
        &[
            ("__STAGE__", stage.to_string()),
            ("__CYCLE_ID__", cycle_id.to_string()),
            ("__VERIFY_ITERATION__", verify_iteration.to_string()),
            (
                "__BACKLOG_IMPLEMENTATION_STAGE_KIND__",
                implementation_stage_kind_for_stage(stage)
                    .map(|kind| kind.as_str().to_string())
                    .unwrap_or_else(|| "general".to_string()),
            ),
            (
                "__BACKLOG_CONTRACT_VERSION__",
                backlog_contract_version.to_string(),
            ),
        ],
    )
}

fn verify_stage_template(
    cycle_id: &str,
    verify_iteration: u32,
    verify_iteration_limit: u32,
) -> String {
    render_jsonc_template(
        r#"{
  // Verify 阶段模板：统一写入验证结果与裁决结果
  "$schema_version": "2.0",
  // 固定阶段名，不可修改
  "stage": "verify",
  // 当前循环 ID，必须与 cycle.jsonc 保持一致
  "cycle_id": "__CYCLE_ID__",
  // 阶段状态；完成后写 done/failed/blocked
  "status": "running",
  "decision": {
    // verify 阶段通常保留 n/a；如需说明可写 reason
    "result": "n/a",
    "reason": ""
  },
  // 当前 verify 重试轮次，由系统注入
  "verify_iteration": __VERIFY_ITERATION__,
  // verify 最大轮次，由系统注入
  "verify_iteration_limit": __VERIFY_ITERATION_LIMIT__,
  // 本轮验证摘要，必须存在
  "summary": "",
  // 检查项执行结果数组，可为空但字段必须存在
  "check_results": [
    // {
    //   "check_id": "CHK-001",
    //   "result": "pass",
    //   "details": "执行结果摘要"
    // }
  ],
  // 验收标准评估，必须完整覆盖 plan.acceptance_criteria
  // criteria_id 集必须与 plan.acceptance_criteria 完全一致
  "acceptance_evaluation": [
    // {
    //   "criteria_id": "AC-001",
    //   "status": "pass",
    //   "evidence_paths": [],
    //   "reason": "判定原因"
    // }
  ],
  "verification_overall": {
    // 总体验证结果：pass | fail
    "result": "fail",
    // 总结原因，必须存在
    "reason": ""
  },
  // 重实现轮的延续验证覆盖；VERIFY_ITERATION>0 时必须完整维护
  "carryover_verification": {
    "items": [],
    "summary": {
      "total": 0,
      "covered": 0,
      "missing": 0,
      "blocked": 0
    }
  },
  "adjudication": {
    // 验收标准裁决，必须完整覆盖 acceptance_evaluation
    "criteria_judgement": [
      // {
      //   "criteria_id": "AC-001",
      //   "result": "pass",
      //   "reason": "裁决原因"
      // }
    ],
    "overall_result": {
      // 裁决总结果：pass | fail
      "result": "fail",
      "reason": ""
    },
    // 阶段编排由系统负责：系统会依据 overall_result、verify_iteration、
    // verify_iteration_limit 和 full_next_iteration_requirements 自动决定后续阶段
    // 需要重实现时必须输出完整 selector 信息
    "full_next_iteration_requirements": [
      // {
      //   "requirement_id": "REQ-001",
      //   "description": "下一轮必须完成的整改项",
      //   "source_criteria_id": "AC-001",
      //   "source_check_id": "CHK-001",
      //   "work_item_id": "WI-001",
      //   "implementation_stage_kind": "general"
      // }
    ]
  },
  // 更新时间，由系统自动注入，代理无需填写
  "updated_at": ""
}
"#,
        &[
            ("__CYCLE_ID__", cycle_id.to_string()),
            ("__VERIFY_ITERATION__", verify_iteration.to_string()),
            (
                "__VERIFY_ITERATION_LIMIT__",
                verify_iteration_limit.to_string(),
            ),
        ],
    )
}

fn auto_commit_stage_template(cycle_id: &str) -> String {
    render_jsonc_template(
        r#"{
  // Auto commit 阶段模板：仅记录提交决策与结果
  "$schema_version": "2.0",
  // 固定阶段名，不可修改
  "stage": "auto_commit",
  // 当前循环 ID，必须与 cycle.jsonc 保持一致
  "cycle_id": "__CYCLE_ID__",
  // 阶段状态；完成后写 done/failed/blocked
  "status": "running",
  "decision": {
    // 自动提交结果；通常保留 n/a，并在 reason 中说明
    "result": "n/a",
    // 若无可提交变更，需明确写出“无可提交变更”或 no changes to commit
    "reason": ""
  },
  // 更新时间，由系统自动注入，代理无需填写
  "updated_at": ""
}
"#,
        &[("__CYCLE_ID__", cycle_id.to_string())],
    )
}

fn managed_backlog_template(cycle_id: &str, verify_iteration: u32) -> String {
    render_jsonc_template(
        r#"{
  // 托管 backlog 模板：系统维护 selector 与统计，代理仅按注释填写 backlog_resolution_updates
  "$schema_version": "2.0",
  // 当前循环 ID，由系统注入
  "cycle_id": "__CYCLE_ID__",
  // 当前 verify 重试轮次，由系统注入
  "verify_iteration": __VERIFY_ITERATION__,
  // 托管整改项列表；系统生成，不要手工伪造主键
  "items": [
    // {
    //   "id": "fb-001",
    //   "source_criteria_id": "AC-001",
    //   "source_check_id": "CHK-001",
    //   "work_item_id": "WI-001",
    //   "implementation_stage_kind": "general",
    //   "requirement_ref": "REQ-001",
    //   "description": "系统生成的整改项描述",
    //   "status": "not_done",
    //   "evidence": null,
    //   "notes": "",
    //   "created_at": "2026-03-06T00:00:00Z",
    //   "updated_at": "2026-03-06T00:00:00Z"
    // }
  ],
  // 系统维护的统计汇总
  "summary": {
    "total": 0,
    "done": 0,
    "blocked": 0,
    "not_done": 0
  },
  // 更新时间，由系统自动注入，代理无需填写
  "updated_at": ""
}
"#,
        &[
            ("__CYCLE_ID__", cycle_id.to_string()),
            ("__VERIFY_ITERATION__", verify_iteration.to_string()),
        ],
    )
}

#[cfg(test)]
fn should_force_advanced_reimplementation(verify_iteration: u32) -> bool {
    verify_iteration >= 2
}

impl EvolutionManager {
    fn validate_plan_artifact(
        cycle_dir: &Path,
        validation_ctx: Option<&StageValidationContext>,
    ) -> Result<(), ArtifactValidationError> {
        let value = read_json_file(cycle_dir, "plan.jsonc")
            .map_err(|e| ArtifactValidationError::new("artifact_contract_violation", e))?;
        let mut report = ValidationReport::default();
        // WI-003: 校验 $schema_version 与 stage 字段
        report.capture(ensure_schema_version(
            "plan.jsonc",
            &value,
            STAGE_ARTIFACT_REQUIRED_SCHEMA_VERSION,
        ));
        report.capture(ensure_stage_field_matches("plan.jsonc", &value, "plan"));
        let (_, routing_report) = parse_plan_routing_tables_report(&value);
        report.merge(routing_report);

        if let Some(ctx) = validation_ctx {
            report.capture(ensure_cycle_id_matches("plan.jsonc", &value, &ctx.cycle_id));
            report.capture(ensure_artifact_freshness(
                "plan.jsonc",
                &value,
                ctx.stage_started_at,
            ));
        }
        report.capture(validate_plan_markdown_artifact(cycle_dir, &value));

        report.into_error("artifact_contract_violation")
    }

    fn implement_result_file_for_stage(stage: &str) -> Option<String> {
        stage_artifact_file(stage)
    }

    fn preferred_stage_kind_from_set(
        stage_kinds: &HashSet<ImplementationStageKind>,
    ) -> Option<ImplementationStageKind> {
        if stage_kinds.contains(&ImplementationStageKind::General) {
            return Some(ImplementationStageKind::General);
        }
        if stage_kinds.contains(&ImplementationStageKind::Visual) {
            return Some(ImplementationStageKind::Visual);
        }
        if stage_kinds.contains(&ImplementationStageKind::Advanced) {
            return Some(ImplementationStageKind::Advanced);
        }
        None
    }

    fn parse_check_to_work_items(
        plan: &serde_json::Value,
    ) -> Result<HashMap<String, Vec<(String, ImplementationStageKind)>>, String> {
        let work_items = plan
            .pointer("/work_items")
            .and_then(|v| v.as_array())
            .ok_or_else(|| "plan.jsonc 缺少 work_items".to_string())?;
        let mut mapping: HashMap<String, Vec<(String, ImplementationStageKind)>> = HashMap::new();
        for (idx, item) in work_items.iter().enumerate() {
            let obj = item
                .as_object()
                .ok_or_else(|| format!("work_items[{}] 必须是对象", idx))?;
            let work_item_id = obj
                .get("id")
                .and_then(parse_non_empty_string)
                .ok_or_else(|| format!("work_items[{}] 缺少 id", idx))?;
            let agent = obj
                .get("implementation_stage_kind")
                .and_then(|v| v.as_str())
                .and_then(ImplementationStageKind::parse)
                .ok_or_else(|| {
                    format!("work_items[{}].implementation_stage_kind 缺失或非法", idx)
                })?;
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

    fn load_plan_work_items(cycle_dir: &Path) -> Result<Vec<PlanWorkItem>, String> {
        let plan = read_json_file(cycle_dir, "plan.jsonc")?;
        parse_plan_work_items(&plan)
    }

    fn resolve_initial_implementation_stage_instances(
        cycle_dir: &Path,
    ) -> Result<Vec<ImplementationStageInstance>, String> {
        let work_items = Self::load_plan_work_items(cycle_dir)?;
        build_implementation_stage_instances(&work_items)
    }

    fn find_initial_implementation_stage_instance(
        cycle_dir: &Path,
        stage: &str,
    ) -> Result<Option<ImplementationStageInstance>, String> {
        Ok(
            Self::resolve_initial_implementation_stage_instances(cycle_dir)?
                .into_iter()
                .find(|instance| instance.stage == stage),
        )
    }

    fn next_initial_implementation_stage(
        cycle_dir: &Path,
        current_stage: &str,
    ) -> Result<Option<String>, String> {
        let stages = Self::resolve_initial_implementation_stage_instances(cycle_dir)?;
        let position = stages
            .iter()
            .position(|instance| instance.stage == current_stage)
            .ok_or_else(|| format!("stage {} 不在首轮实现序列中", current_stage))?;
        Ok(stages
            .get(position + 1)
            .map(|instance| instance.stage.clone()))
    }

    pub(super) fn tasks_to_complete_for_stage(
        cycle_dir: &Path,
        stage: &str,
    ) -> Result<String, String> {
        let instance = Self::find_initial_implementation_stage_instance(cycle_dir, stage)?
            .ok_or_else(|| format!("找不到实现阶段实例: {}", stage))?;
        let work_items = Self::load_plan_work_items(cycle_dir)?;
        let work_items_by_id: HashMap<String, PlanWorkItem> = work_items
            .into_iter()
            .map(|item| (item.id.clone(), item))
            .collect();

        let mut sections = Vec::new();
        for work_item_id in instance.work_item_ids {
            let item = work_items_by_id
                .get(&work_item_id)
                .ok_or_else(|| format!("plan.jsonc 缺少 work_item: {}", work_item_id))?;
            let depends_text = if item.depends_on.is_empty() {
                "无".to_string()
            } else {
                item.depends_on.join(", ")
            };
            let targets_text = if item.targets.is_empty() {
                "- 无明确目标文件".to_string()
            } else {
                item.targets
                    .iter()
                    .map(|target| format!("- {}", target))
                    .collect::<Vec<String>>()
                    .join("\n")
            };
            let dod_text = item
                .definition_of_done
                .iter()
                .map(|line| format!("- {}", line))
                .collect::<Vec<String>>()
                .join("\n");
            let checks_text = item
                .linked_check_ids
                .iter()
                .map(|check| format!("- {}", check))
                .collect::<Vec<String>>()
                .join("\n");
            sections.push(format!(
                "### {} {}\n- 实现阶段类型：{}\n- 直接依赖（系统已按依赖调度）：{}\n- 目标文件：\n{}\n- 完成定义：\n{}\n- 关联检查：\n{}",
                item.id,
                item.title,
                item.implementation_stage_kind.as_str(),
                depends_text,
                targets_text,
                dod_text,
                checks_text
            ));
        }

        Ok(sections.join("\n\n"))
    }

    pub(super) fn issues_to_fix_for_stage(cycle_dir: &Path, stage: &str) -> Result<String, String> {
        let round = parse_reimplement_stage_instance(stage)
            .ok_or_else(|| format!("不是有效的重实现阶段: {}", stage))?;
        let verify = read_json_file(cycle_dir, "verify.jsonc")?;
        let requirements = extract_verify_requirements(&verify).ok_or_else(|| {
            "verify.jsonc 缺少 adjudication.full_next_iteration_requirements".to_string()
        })?;
        let mut sections = Vec::with_capacity(requirements.len());
        for (idx, requirement) in requirements.iter().enumerate() {
            let requirement_id = id_from_value(
                requirement,
                &[
                    "requirement_id",
                    "failure_backlog_id",
                    "backlog_id",
                    "id",
                    "item_id",
                ],
            )
            .unwrap_or_else(|| format!("REQ-{}", idx + 1));
            let description = requirement
                .get("description")
                .and_then(|value| value.as_str())
                .map(|value| value.trim())
                .filter(|value| !value.is_empty())
                .unwrap_or("未提供描述");
            let source_criteria_id = id_from_value(
                requirement,
                &["source_criteria_id", "criteria_id", "criterion_id"],
            )
            .unwrap_or_else(|| "unknown".to_string());
            let source_check_id = id_from_value(
                requirement,
                &["source_check_id", "check_id", "linked_check_id"],
            )
            .unwrap_or_else(|| "unknown".to_string());
            let work_item_id = id_from_value(requirement, &["work_item_id"])
                .unwrap_or_else(|| "unknown".to_string());
            let implementation_stage_kind = requirement
                .get("implementation_stage_kind")
                .and_then(|value| value.as_str())
                .unwrap_or("unknown");

            sections.push(format!(
                "### {}（第 {} 次重实现）\n- 问题描述：{}\n- source_criteria_id：{}\n- source_check_id：{}\n- work_item_id：{}\n- implementation_stage_kind：{}",
                requirement_id,
                round,
                description,
                source_criteria_id,
                source_check_id,
                work_item_id,
                implementation_stage_kind
            ));
        }

        Ok(sections.join("\n\n"))
    }

    fn ensure_runtime_stage_state_pending(
        stage_statuses: &mut HashMap<String, String>,
        stage_tool_call_counts: &mut HashMap<String, u32>,
        stage: &str,
    ) {
        stage_statuses
            .entry(stage.to_string())
            .or_insert_with(|| "pending".to_string());
        stage_tool_call_counts.entry(stage.to_string()).or_insert(0);
    }

    fn read_managed_backlog(cycle_dir: &Path) -> Result<ManagedBacklogFile, String> {
        let value = read_json(&managed_backlog_path(cycle_dir))
            .map_err(|e| format!("读取 {} 失败: {}", MANAGED_BACKLOG_FILE, e))?;
        serde_json::from_value::<ManagedBacklogFile>(value)
            .map_err(|e| format!("解析 {} 失败: {}", MANAGED_BACKLOG_FILE, e))
    }

    fn write_managed_backlog(cycle_dir: &Path, payload: &ManagedBacklogFile) -> Result<(), String> {
        let value = serde_json::to_value(payload)
            .map_err(|e| format!("序列化 {} 失败: {}", MANAGED_BACKLOG_FILE, e))?;
        write_json(&managed_backlog_path(cycle_dir), &value)
    }

    fn generate_managed_backlog_from_verify(
        cycle_dir: &Path,
        verify_iteration: u32,
    ) -> Result<(), String> {
        let plan = read_json_file(cycle_dir, "plan.jsonc")?;
        let tables = parse_plan_routing_tables(&plan)?;
        let check_to_work_items = Self::parse_check_to_work_items(&plan)?;
        let verify_result = read_json_file(cycle_dir, "verify.jsonc")?;
        let requirements = extract_verify_requirements(&verify_result).ok_or_else(|| {
            "verify.jsonc 缺少 adjudication.full_next_iteration_requirements（重实现轮必须提供）"
                .to_string()
        })?;
        let cycle_id = read_json_file(cycle_dir, "cycle.jsonc")?
            .get("cycle_id")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();

        let previous_backlog_items = Self::read_managed_backlog(cycle_dir)
            .map(|file| file.items)
            .unwrap_or_default();
        let mut previous_by_id: HashMap<String, usize> = HashMap::new();
        let mut previous_by_requirement_ref: HashMap<String, usize> = HashMap::new();
        for (idx, item) in previous_backlog_items.iter().enumerate() {
            if !item.id.trim().is_empty() {
                previous_by_id.entry(item.id.clone()).or_insert(idx);
            }
            let requirement_ref = item.requirement_ref.trim();
            if !requirement_ref.is_empty() {
                previous_by_requirement_ref
                    .entry(requirement_ref.to_string())
                    .or_insert(idx);
            }
        }

        let mut seen_selectors: HashSet<(String, String, String, String)> = HashSet::new();
        let mut backlog_items: Vec<ManagedBacklogItem> = Vec::new();

        for (idx, requirement) in requirements.iter().enumerate() {
            let requirement_ref = id_from_value(
                requirement,
                &[
                    "requirement_id",
                    "failure_backlog_id",
                    "backlog_id",
                    "id",
                    "item_id",
                    "criteria_id",
                    "title",
                    "check_id",
                    "source_check_id",
                ],
            )
            .unwrap_or_else(|| format!("requirement-{}", idx + 1));
            let previous_selector_ref = id_from_value(
                requirement,
                &[
                    "requirement_id",
                    "failure_backlog_id",
                    "backlog_id",
                    "id",
                    "item_id",
                ],
            );
            let previous_item = previous_selector_ref
                .as_ref()
                .and_then(|key| {
                    previous_by_id
                        .get(key)
                        .or_else(|| previous_by_requirement_ref.get(key))
                })
                .and_then(|index| previous_backlog_items.get(*index));

            let mut source_criteria_id = id_from_value(
                requirement,
                &["source_criteria_id", "criteria_id", "criterion_id"],
            );
            if source_criteria_id.is_none() {
                source_criteria_id = previous_item.map(|item| item.source_criteria_id.clone());
            }
            let source_criteria_id = source_criteria_id.ok_or_else(|| {
                format!(
                    "full_next_iteration_requirements[{}] 缺少 source_criteria_id（无法映射 selector）",
                    idx
                )
            })?;
            if is_unknown_selector_value(&source_criteria_id) {
                return Err(format!(
                    "full_next_iteration_requirements[{}].source_criteria_id 不能为空且不能为 unknown",
                    idx
                ));
            }

            let mut source_check_id = id_from_value(
                requirement,
                &["source_check_id", "check_id", "linked_check_id"],
            );
            if source_check_id.is_none() {
                source_check_id = previous_item.map(|item| item.source_check_id.clone());
            }
            if source_check_id.is_none() {
                source_check_id = tables
                    .criteria_to_checks
                    .get(&source_criteria_id)
                    .and_then(|checks| checks.first().cloned());
            }
            let source_check_id = source_check_id.ok_or_else(|| {
                format!(
                    "full_next_iteration_requirements[{}] 缺少 source_check_id（无法映射 selector）",
                    idx
                )
            })?;
            if is_unknown_selector_value(&source_check_id) {
                return Err(format!(
                    "full_next_iteration_requirements[{}].source_check_id 不能为空且不能为 unknown",
                    idx
                ));
            }

            let mut implementation_stage_kind = None;
            if let Some(raw_agent) = requirement
                .get("implementation_stage_kind")
                .and_then(|v| v.as_str())
            {
                let parsed = ImplementationStageKind::parse(raw_agent).ok_or_else(|| {
                    format!(
                        "full_next_iteration_requirements[{}].implementation_stage_kind 非法: {}",
                        idx, raw_agent
                    )
                })?;
                implementation_stage_kind = Some(parsed);
            }
            if implementation_stage_kind.is_none() {
                implementation_stage_kind = previous_item.and_then(|item| {
                    ImplementationStageKind::parse(&item.implementation_stage_kind)
                });
            }
            if implementation_stage_kind.is_none() {
                let mut agent_set: HashSet<ImplementationStageKind> = HashSet::new();
                if let Some(mapped) = tables.check_to_stage_kinds.get(&source_check_id) {
                    agent_set.extend(mapped.iter().copied());
                }
                if let Some(checks) = tables.criteria_to_checks.get(&source_criteria_id) {
                    for check_id in checks {
                        if let Some(mapped) = tables.check_to_stage_kinds.get(check_id) {
                            agent_set.extend(mapped.iter().copied());
                        }
                    }
                }
                implementation_stage_kind = Self::preferred_stage_kind_from_set(&agent_set);
            }
            let implementation_stage_kind = implementation_stage_kind.ok_or_else(|| {
                format!(
                    "full_next_iteration_requirements[{}] 缺少 implementation_stage_kind（无法映射 selector）",
                    idx
                )
            })?;
            let implementation_stage_kind_text = implementation_stage_kind.as_str().to_string();

            let mut work_item_id = id_from_value(requirement, &["work_item_id"]);
            if work_item_id.is_none() {
                work_item_id = previous_item.map(|item| item.work_item_id.clone());
            }
            if work_item_id.is_none() {
                if let Some(mapped_items) = check_to_work_items.get(&source_check_id) {
                    let preferred = mapped_items
                        .iter()
                        .find(|(_, agent)| *agent == implementation_stage_kind)
                        .or_else(|| mapped_items.first());
                    work_item_id = preferred.map(|(id, _)| id.clone());
                }
            }
            let work_item_id = work_item_id.ok_or_else(|| {
                format!(
                    "full_next_iteration_requirements[{}] 缺少 work_item_id（无法映射 selector）",
                    idx
                )
            })?;
            if is_unknown_selector_value(&work_item_id) {
                return Err(format!(
                    "full_next_iteration_requirements[{}].work_item_id 不能为空且不能为 unknown",
                    idx
                ));
            }

            validate_requirement_selector_against_plan(
                &format!("full_next_iteration_requirements[{}]", idx),
                &source_criteria_id,
                &source_check_id,
                &work_item_id,
                implementation_stage_kind,
                &tables,
                &check_to_work_items,
            )?;

            let selector = (
                source_criteria_id.clone(),
                source_check_id.clone(),
                work_item_id.clone(),
                implementation_stage_kind_text.clone(),
            );
            if !seen_selectors.insert(selector) {
                continue;
            }

            let now = Utc::now().to_rfc3339();
            backlog_items.push(ManagedBacklogItem {
                id: Uuid::now_v7().to_string(),
                source_criteria_id,
                source_check_id,
                work_item_id,
                implementation_stage_kind: implementation_stage_kind_text,
                requirement_ref,
                description: requirement
                    .get("description")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string(),
                status: "not_done".to_string(),
                evidence: serde_json::Value::Null,
                notes: String::new(),
                created_at: now.clone(),
                updated_at: now,
            });
        }

        let summary = coverage_summary(&backlog_items);
        let now = Utc::now().to_rfc3339();
        Self::write_managed_backlog(
            cycle_dir,
            &ManagedBacklogFile {
                schema_version: default_schema_version(),
                cycle_id,
                verify_iteration,
                items: backlog_items,
                summary,
                updated_at: now,
            },
        )?;
        Ok(())
    }

    fn sync_managed_backlog_for_execution_stage(
        cycle_dir: &Path,
        stage: &str,
    ) -> Result<(), ArtifactValidationError> {
        let Some(file_name) = Self::implement_result_file_for_stage(stage) else {
            return Ok(());
        };
        let expected_stage_kind = implementation_stage_kind_for_stage(stage);
        if expected_stage_kind.is_none() && !is_runtime_reimplement_stage(stage) {
            return Ok(());
        }

        let mut managed_backlog = Self::read_managed_backlog(cycle_dir)
            .map_err(|e| ArtifactValidationError::new("managed_backlog_sync_failed", e))?;
        let mut stage_result = read_json_file(cycle_dir, &file_name)
            .map_err(|e| ArtifactValidationError::new("managed_backlog_sync_failed", e))?;
        let updates = stage_result
            .pointer("/backlog_resolution_updates")
            .and_then(|v| v.as_array())
            .ok_or_else(|| {
                ArtifactValidationError::new(
                    "managed_backlog_sync_failed",
                    format!("{}.backlog_resolution_updates 缺失", file_name),
                )
            })?;

        #[derive(Clone)]
        struct PendingBacklogUpdate {
            index: usize,
            status: String,
            evidence: serde_json::Value,
            notes: String,
        }

        let mut report = ValidationReport::default();
        let mut pending_updates: Vec<PendingBacklogUpdate> = Vec::new();

        for (idx, item) in updates.iter().enumerate() {
            let parsed = match serde_json::from_value::<BacklogResolutionUpdate>(item.clone()) {
                Ok(parsed) => parsed,
                Err(e) => {
                    report.push(format!(
                        "{}.backlog_resolution_updates[{}] 非法: {}",
                        file_name, idx, e
                    ));
                    continue;
                }
            };

            let mut item_has_error = false;
            if parsed.source_criteria_id.trim().is_empty()
                || parsed.source_check_id.trim().is_empty()
                || parsed.work_item_id.trim().is_empty()
            {
                report.push(format!(
                    "{}.backlog_resolution_updates[{}] selector 字段不能为空",
                    file_name, idx
                ));
                item_has_error = true;
            }
            if let Some(expected_kind) = expected_stage_kind {
                if ImplementationStageKind::parse(&parsed.implementation_stage_kind)
                    != Some(expected_kind)
                {
                    report.push(format!(
                        "{}.backlog_resolution_updates[{}].implementation_stage_kind 必须等于 {}",
                        file_name,
                        idx,
                        expected_kind.as_str()
                    ));
                    item_has_error = true;
                }
            }
            let normalized_status = match normalize_backlog_status(&parsed.status) {
                Some(status) => status.to_string(),
                None => {
                    report.push(format!(
                        "{}.backlog_resolution_updates[{}].status 必须是 done|blocked|not_done",
                        file_name, idx
                    ));
                    item_has_error = true;
                    String::new()
                }
            };
            if item_has_error {
                continue;
            }

            let (matched_indexes, matched_by) =
                Self::match_managed_backlog_indexes(&managed_backlog.items, &parsed);

            if !matched_indexes.is_empty() && matched_by != "work_item_id" {
                warn!(
                    "evo_backlog_mapping_fallback: cycle_dir={}, stage={}, selector=({}, {}, {}, {}), resolved_by={}, candidates={}",
                    cycle_dir.display(),
                    stage,
                    parsed.source_criteria_id,
                    parsed.source_check_id,
                    parsed.work_item_id,
                    parsed.implementation_stage_kind,
                    matched_by,
                    matched_indexes.len()
                );
            }

            if matched_indexes.is_empty() {
                warn!(
                    "evo_backlog_mapping_missing: cycle_dir={}, stage={}, selector=({}, {}, {}, {}), candidates=0",
                    cycle_dir.display(),
                    stage,
                    parsed.source_criteria_id,
                    parsed.source_check_id,
                    parsed.work_item_id,
                    parsed.implementation_stage_kind
                );
                report.push(format!(
                    "evo_backlog_mapping_missing: selector=({}, {}, {}, {}), candidates=0",
                    parsed.source_criteria_id,
                    parsed.source_check_id,
                    parsed.work_item_id,
                    parsed.implementation_stage_kind
                ));
                continue;
            }
            if matched_indexes.len() > 1 {
                warn!(
                    "evo_backlog_mapping_ambiguous: cycle_dir={}, stage={}, selector=({}, {}, {}, {}), candidates={}",
                    cycle_dir.display(),
                    stage,
                    parsed.source_criteria_id,
                    parsed.source_check_id,
                    parsed.work_item_id,
                    parsed.implementation_stage_kind,
                    matched_indexes.len()
                );
                report.push(format!(
                    "evo_backlog_mapping_ambiguous: selector=({}, {}, {}, {}), candidates={}",
                    parsed.source_criteria_id,
                    parsed.source_check_id,
                    parsed.work_item_id,
                    parsed.implementation_stage_kind,
                    matched_indexes.len()
                ));
                continue;
            }

            pending_updates.push(PendingBacklogUpdate {
                index: matched_indexes[0],
                status: normalized_status,
                evidence: parsed.evidence,
                notes: parsed.notes,
            });
        }

        report.into_error("managed_backlog_sync_failed")?;

        let now = Utc::now().to_rfc3339();
        for pending in pending_updates {
            let backlog_item = managed_backlog
                .items
                .get_mut(pending.index)
                .ok_or_else(|| {
                    ArtifactValidationError::new(
                        "managed_backlog_sync_failed",
                        format!("managed.backlog.jsonc selector 索引越界（stage={}）", stage),
                    )
                })?;
            backlog_item.status = pending.status;
            backlog_item.evidence = pending.evidence;
            backlog_item.notes = pending.notes;
            backlog_item.updated_at = now.clone();
        }

        managed_backlog.summary = coverage_summary(&managed_backlog.items);
        managed_backlog.updated_at = Utc::now().to_rfc3339();

        let stage_backlog = managed_backlog
            .items
            .iter()
            .filter(|item| {
                expected_stage_kind
                    .map(|kind| {
                        ImplementationStageKind::parse(&item.implementation_stage_kind)
                            == Some(kind)
                    })
                    .unwrap_or(true)
            })
            .cloned()
            .collect::<Vec<ManagedBacklogItem>>();
        let stage_summary = coverage_summary(&stage_backlog);

        let stage_backlog_json = stage_backlog
            .iter()
            .map(|item| {
                serde_json::json!({
                    "id": item.id,
                    "source_criteria_id": item.source_criteria_id,
                    "source_check_id": item.source_check_id,
                    "work_item_id": item.work_item_id,
                    "implementation_stage_kind": item.implementation_stage_kind,
                    "description": item.description,
                    "requirement_ref": item.requirement_ref
                })
            })
            .collect::<Vec<serde_json::Value>>();
        let stage_coverage_json = stage_backlog
            .iter()
            .map(|item| {
                serde_json::json!({
                    "id": item.id,
                    "item_id": item.id,
                    "failure_backlog_id": item.id,
                    "backlog_id": item.id,
                    "source_criteria_id": item.source_criteria_id,
                    "source_check_id": item.source_check_id,
                    "work_item_id": item.work_item_id,
                    "implementation_stage_kind": item.implementation_stage_kind,
                    "status": item.status,
                    "evidence": item.evidence,
                    "notes": item.notes
                })
            })
            .collect::<Vec<serde_json::Value>>();

        let stage_obj = stage_result.as_object_mut().ok_or_else(|| {
            ArtifactValidationError::new(
                "managed_backlog_sync_failed",
                format!("{} 顶层必须是对象", file_name),
            )
        })?;
        stage_obj.insert(
            "failure_backlog".to_string(),
            serde_json::Value::Array(stage_backlog_json),
        );
        stage_obj.insert(
            "backlog_coverage".to_string(),
            serde_json::Value::Array(stage_coverage_json),
        );
        stage_obj.insert(
            "backlog_coverage_summary".to_string(),
            serde_json::json!({
                "total": stage_summary.total,
                "done": stage_summary.done,
                "blocked": stage_summary.blocked,
                "not_done": stage_summary.not_done
            }),
        );
        stage_obj.insert(
            "updated_at".to_string(),
            serde_json::Value::String(Utc::now().to_rfc3339()),
        );
        write_json(&cycle_dir.join(file_name), &stage_result)
            .map_err(|e| ArtifactValidationError::new("managed_backlog_sync_failed", e))?;
        Self::write_managed_backlog(cycle_dir, &managed_backlog)
            .map_err(|e| ArtifactValidationError::new("managed_backlog_sync_failed", e))?;
        Ok(())
    }

    #[cfg(test)]
    fn sync_managed_backlog_for_implement_stage(
        cycle_dir: &Path,
        stage: &str,
    ) -> Result<(), ArtifactValidationError> {
        Self::sync_managed_backlog_for_execution_stage(cycle_dir, stage)
    }

    #[cfg(test)]
    fn resolve_implement_lanes(
        cycle_dir: &Path,
        verify_iteration: u32,
    ) -> Result<Vec<ImplementLane>, String> {
        if verify_iteration >= 2 {
            return Ok(vec![ImplementationStageKind::Advanced]);
        }

        let plan = read_json_file(cycle_dir, "plan.jsonc")?;
        let tables = parse_plan_routing_tables(&plan)?;
        if verify_iteration == 0 {
            let instances = Self::resolve_initial_implementation_stage_instances(cycle_dir)?;
            let mut kinds = Vec::new();
            for instance in instances {
                if !kinds.contains(&instance.kind) {
                    kinds.push(instance.kind);
                }
            }
            return Ok(if kinds.is_empty() {
                vec![ImplementationStageKind::General]
            } else {
                kinds
            });
        }

        match Self::map_failed_agents_from_results(cycle_dir, &tables)? {
            Some(mut kinds) => {
                let mut ordered = IMPLEMENTATION_STAGE_KINDS
                    .iter()
                    .copied()
                    .filter(|kind| kinds.remove(kind))
                    .collect::<Vec<ImplementationStageKind>>();
                if ordered.is_empty() {
                    ordered.push(ImplementationStageKind::General);
                }
                Ok(ordered)
            }
            None => Ok(vec![ImplementationStageKind::General]),
        }
    }

    fn match_managed_backlog_indexes(
        backlog_items: &[ManagedBacklogItem],
        parsed: &BacklogResolutionUpdate,
    ) -> (Vec<usize>, &'static str) {
        let parsed_stage_kind = ImplementationStageKind::parse(&parsed.implementation_stage_kind);
        let by_work_item_id = backlog_items
            .iter()
            .enumerate()
            .filter(|(_, backlog)| {
                let backlog_stage_kind =
                    ImplementationStageKind::parse(&backlog.implementation_stage_kind);
                backlog.source_criteria_id == parsed.source_criteria_id
                    && backlog.source_check_id == parsed.source_check_id
                    && backlog.work_item_id == parsed.work_item_id
                    && backlog_stage_kind == parsed_stage_kind
            })
            .map(|(i, _)| i)
            .collect::<Vec<usize>>();
        if !by_work_item_id.is_empty() {
            return (by_work_item_id, "work_item_id");
        }

        let by_requirement_ref = backlog_items
            .iter()
            .enumerate()
            .filter(|(_, backlog)| {
                let backlog_stage_kind =
                    ImplementationStageKind::parse(&backlog.implementation_stage_kind);
                backlog.source_criteria_id == parsed.source_criteria_id
                    && backlog.source_check_id == parsed.source_check_id
                    && backlog.requirement_ref == parsed.work_item_id
                    && backlog_stage_kind == parsed_stage_kind
            })
            .map(|(i, _)| i)
            .collect::<Vec<usize>>();
        if !by_requirement_ref.is_empty() {
            return (by_requirement_ref, "requirement_ref");
        }

        let by_backlog_id = backlog_items
            .iter()
            .enumerate()
            .filter(|(_, backlog)| {
                let backlog_stage_kind =
                    ImplementationStageKind::parse(&backlog.implementation_stage_kind);
                backlog.source_criteria_id == parsed.source_criteria_id
                    && backlog.source_check_id == parsed.source_check_id
                    && backlog.id == parsed.work_item_id
                    && backlog_stage_kind == parsed_stage_kind
            })
            .map(|(i, _)| i)
            .collect::<Vec<usize>>();
        if !by_backlog_id.is_empty() {
            return (by_backlog_id, "backlog_id");
        }

        (Vec::new(), "work_item_id")
    }

    fn collect_reimplementation_backlog(
        cycle_dir: &Path,
        backlog_contract_version: u32,
        verify_iteration: u32,
    ) -> Result<(Vec<serde_json::Value>, Vec<serde_json::Value>), String> {
        if backlog_contract_version >= 2 {
            let backlog = Self::read_managed_backlog(cycle_dir)?;
            let backlog_values = backlog
                .items
                .iter()
                .map(|item| {
                    serde_json::json!({
                        "id": item.id,
                        "source_criteria_id": item.source_criteria_id,
                        "source_check_id": item.source_check_id,
                        "work_item_id": item.work_item_id,
                        "implementation_stage_kind": item.implementation_stage_kind
                    })
                })
                .collect::<Vec<serde_json::Value>>();
            let coverage_values = backlog
                .items
                .iter()
                .map(|item| {
                    serde_json::json!({
                        "id": item.id,
                        "item_id": item.id,
                        "status": item.status
                    })
                })
                .collect::<Vec<serde_json::Value>>();
            return Ok((backlog_values, coverage_values));
        }

        let stage = reimplement_stage_name(verify_iteration);
        let file_name = Self::implement_result_file_for_stage(&stage)
            .ok_or_else(|| format!("无法解析重实现阶段产物: {}", stage))?;
        let value = match read_json_file(cycle_dir, &file_name) {
            Ok(value) => value,
            Err(_) => {
                let mut all_backlog: Vec<serde_json::Value> = Vec::new();
                let mut all_coverage: Vec<serde_json::Value> = Vec::new();
                let mut saw_legacy_file = false;
                for legacy_file in [
                    "implement_general.jsonc",
                    "implement_visual.jsonc",
                    "implement_advanced.jsonc",
                ] {
                    let value = match read_json_file(cycle_dir, legacy_file) {
                        Ok(value) => value,
                        Err(_) => continue,
                    };
                    saw_legacy_file = true;
                    let backlog = value
                        .pointer("/failure_backlog")
                        .and_then(|v| v.as_array())
                        .ok_or_else(|| {
                            format!("{} 缺少 failure_backlog（重实现轮必须提供）", legacy_file)
                        })?;
                    let coverage = value
                        .pointer("/backlog_coverage")
                        .and_then(|v| v.as_array())
                        .ok_or_else(|| {
                            format!("{} 缺少 backlog_coverage（重实现轮必须提供）", legacy_file)
                        })?;
                    let summary = value
                        .pointer("/backlog_coverage_summary")
                        .and_then(|v| v.as_object())
                        .ok_or_else(|| {
                            format!(
                                "{} 缺少 backlog_coverage_summary（重实现轮必须提供）",
                                legacy_file
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
                                legacy_file, key
                            ));
                        }
                    }
                    all_backlog.extend(backlog.iter().cloned());
                    all_coverage.extend(coverage.iter().cloned());
                }
                if !saw_legacy_file {
                    return Err(format!(
                        "读取 {} 失败: No such file or directory",
                        file_name
                    ));
                }
                return Ok((all_backlog, all_coverage));
            }
        };
        let backlog = value
            .pointer("/failure_backlog")
            .and_then(|v| v.as_array())
            .ok_or_else(|| format!("{} 缺少 failure_backlog（重实现轮必须提供）", file_name))?;
        let coverage = value
            .pointer("/backlog_coverage")
            .and_then(|v| v.as_array())
            .ok_or_else(|| format!("{} 缺少 backlog_coverage（重实现轮必须提供）", file_name))?;
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
        Ok((backlog.to_vec(), coverage.to_vec()))
    }

    fn validate_implement_artifact(
        stage: &str,
        cycle_dir: &Path,
        verify_iteration: u32,
        backlog_contract_version: u32,
        validation_ctx: Option<&StageValidationContext>,
    ) -> Result<(), ArtifactValidationError> {
        let file_name = Self::implement_result_file_for_stage(stage).ok_or_else(|| {
            ArtifactValidationError::new(
                "artifact_contract_violation",
                format!("未知 implement stage: {}", stage),
            )
        })?;
        let expected_stage_kind = implementation_stage_kind_for_stage(stage);
        let value = read_json_file(cycle_dir, &file_name)
            .map_err(|e| ArtifactValidationError::new("artifact_contract_violation", e))?;
        let mut report = ValidationReport::default();
        // WI-003: 校验 $schema_version 与 stage 字段
        report.capture(ensure_schema_version(
            &file_name,
            &value,
            STAGE_ARTIFACT_REQUIRED_SCHEMA_VERSION,
        ));
        report.capture(ensure_stage_field_matches(&file_name, &value, stage));
        if let Some(ctx) = validation_ctx {
            report.capture(ensure_cycle_id_matches(&file_name, &value, &ctx.cycle_id));
            report.capture(ensure_artifact_freshness(
                &file_name,
                &value,
                ctx.stage_started_at,
            ));
        }

        let file_verify_iteration = value
            .get("verify_iteration")
            .and_then(|v| v.as_u64())
            .map(|v| v as u32);
        match file_verify_iteration {
            Some(file_verify_iteration) if file_verify_iteration != verify_iteration => {
                report.push(format!(
                    "{}.verify_iteration 不匹配: {} != {}",
                    file_name, file_verify_iteration, verify_iteration
                ));
            }
            Some(_) => {}
            None => report.push(format!("{} 缺少 verify_iteration", file_name)),
        }

        let status = value
            .get("status")
            .and_then(|v| v.as_str())
            .map(|v| v.trim().to_ascii_lowercase());
        match status.as_deref() {
            Some("done" | "failed" | "blocked" | "skipped") => {}
            Some(status) => report.push(format!(
                "{}.status 非法: {}（必须是 done|failed|blocked|skipped）",
                file_name, status
            )),
            None => report.push(format!("{} 缺少 status", file_name)),
        }

        for key in [
            "work_item_results",
            "changed_files",
            "commands_executed",
            "quick_checks",
        ] {
            if value.get(key).and_then(|v| v.as_array()).is_none() {
                report.push(format!("{} 缺少 {} 数组", file_name, key));
            }
        }
        if value.get("summary").and_then(|v| v.as_str()).is_none() {
            report.push(format!("{} 缺少 summary 字段", file_name));
        }
        if verify_iteration > 0 && backlog_contract_version >= 2 {
            let updates = value
                .pointer("/backlog_resolution_updates")
                .and_then(|v| v.as_array());
            match updates {
                Some(updates) => {
                    for (idx, item) in updates.iter().enumerate() {
                        match serde_json::from_value::<BacklogResolutionUpdate>(item.clone()) {
                            Ok(parsed) => {
                                if parsed.source_criteria_id.trim().is_empty()
                                    || parsed.source_check_id.trim().is_empty()
                                    || parsed.work_item_id.trim().is_empty()
                                {
                                    report.push(format!(
                                        "{}.backlog_resolution_updates[{}] selector 字段不能为空",
                                        file_name, idx
                                    ));
                                }
                                if let Some(expected_kind) = expected_stage_kind {
                                    if ImplementationStageKind::parse(
                                        &parsed.implementation_stage_kind,
                                    ) != Some(expected_kind)
                                    {
                                        report.push(format!(
                                            "{}.backlog_resolution_updates[{}].implementation_stage_kind 必须等于 {}",
                                            file_name,
                                            idx,
                                            expected_kind.as_str()
                                        ));
                                    }
                                }
                                if normalize_backlog_status(&parsed.status).is_none() {
                                    report.push(format!(
                                        "{}.backlog_resolution_updates[{}].status 必须是 done|blocked|not_done",
                                        file_name, idx
                                    ));
                                }
                            }
                            Err(e) => report.push(format!(
                                "{}.backlog_resolution_updates[{}] 非法: {}",
                                file_name, idx, e
                            )),
                        }
                    }
                }
                None => report.push(format!("{} 缺少 backlog_resolution_updates", file_name)),
            }

            let backlog = Self::read_managed_backlog(cycle_dir)
                .map_err(|e| ArtifactValidationError::new("artifact_contract_violation", e))?;
            if let Some(ctx) = validation_ctx {
                if backlog.cycle_id != ctx.cycle_id {
                    report.push(format!(
                        "{}.cycle_id 不匹配: {} != {}",
                        MANAGED_BACKLOG_FILE, backlog.cycle_id, ctx.cycle_id
                    ));
                }
            }
            if backlog.verify_iteration != verify_iteration {
                report.push(format!(
                    "{}.verify_iteration 不匹配: {} != {}",
                    MANAGED_BACKLOG_FILE, backlog.verify_iteration, verify_iteration
                ));
            }

            for (idx, item) in backlog.items.iter().enumerate() {
                if item.id.trim().is_empty() {
                    report.push(format!("managed.backlog.jsonc.items[{}].id 不能为空", idx));
                }
                if !is_valid_implementation_stage_kind(&item.implementation_stage_kind) {
                    report.push(format!(
                        "managed.backlog.jsonc.items[{}].implementation_stage_kind 必须是 general|visual|advanced|unknown",
                        idx
                    ));
                }
                if normalize_backlog_status(&item.status).is_none() {
                    report.push(format!(
                        "managed.backlog.jsonc.items[{}].status 必须是 done|blocked|not_done",
                        idx
                    ));
                }
            }
            return report.into_error("artifact_contract_violation");
        }

        if verify_iteration > 0 && backlog_contract_version < 2 {
            let (backlog, coverage) = Self::collect_reimplementation_backlog(
                cycle_dir,
                backlog_contract_version,
                verify_iteration,
            )
            .map_err(|e| ArtifactValidationError::new("artifact_contract_violation", e))?;
            for (idx, item) in backlog.iter().enumerate() {
                let Some(obj) = item.as_object() else {
                    report.push(format!("failure_backlog[{}] 必须是对象", idx));
                    continue;
                };
                let agent = obj
                    .get("implementation_stage_kind")
                    .and_then(|v| v.as_str())
                    .map(|v| v.trim().to_ascii_lowercase());
                let Some(agent) = agent else {
                    report.push(format!(
                        "failure_backlog[{}].implementation_stage_kind 缺失或非法",
                        idx
                    ));
                    continue;
                };
                if !is_valid_implementation_stage_kind(agent.as_str()) {
                    report.push(format!(
                        "failure_backlog[{}].implementation_stage_kind 必须是 general|visual|advanced|unknown",
                        idx
                    ));
                }
            }
            let backlog_ids = match collect_unique_ids(&backlog, &["id"], "failure_backlog") {
                Ok(ids) => Some(ids),
                Err(err) => {
                    report.push(err);
                    None
                }
            };
            let coverage_ids =
                match collect_unique_ids(&coverage, &["id", "item_id"], "backlog_coverage") {
                    Ok(ids) => Some(ids),
                    Err(err) => {
                        report.push(err);
                        None
                    }
                };
            if let (Some(backlog_ids), Some(coverage_ids)) = (backlog_ids, coverage_ids) {
                if backlog_ids.len() != coverage_ids.len() {
                    report.push(format!(
                        "failure_backlog 与 backlog_coverage 数量不一致: {} vs {}",
                        backlog_ids.len(),
                        coverage_ids.len()
                    ));
                }
                let backlog_set: HashSet<String> = backlog_ids.into_iter().collect();
                let coverage_set: HashSet<String> = coverage_ids.into_iter().collect();
                if backlog_set != coverage_set {
                    report.push("backlog_coverage 未完整覆盖 failure_backlog");
                }
            }
        }

        report.into_error("artifact_contract_violation")
    }

    fn validate_verify_artifact(
        cycle_dir: &Path,
        verify_iteration: u32,
        backlog_contract_version: u32,
        validation_ctx: Option<&StageValidationContext>,
    ) -> Result<(), ArtifactValidationError> {
        let verify_value = read_json_file(cycle_dir, "verify.jsonc")
            .map_err(|e| ArtifactValidationError::new("artifact_contract_violation", e))?;
        let mut report = ValidationReport::default();
        // WI-003: 校验 $schema_version 与 stage 字段
        report.capture(ensure_schema_version(
            "verify.jsonc",
            &verify_value,
            STAGE_ARTIFACT_REQUIRED_SCHEMA_VERSION,
        ));
        report.capture(ensure_stage_field_matches(
            "verify.jsonc",
            &verify_value,
            "verify",
        ));
        if let Some(ctx) = validation_ctx {
            report.capture(ensure_cycle_id_matches(
                "verify.jsonc",
                &verify_value,
                &ctx.cycle_id,
            ));
            report.capture(ensure_artifact_freshness(
                "verify.jsonc",
                &verify_value,
                ctx.stage_started_at,
            ));
        }
        let verify_file_iteration = verify_value
            .get("verify_iteration")
            .and_then(|v| v.as_u64())
            .map(|v| v as u32);
        match verify_file_iteration {
            Some(file_iteration) if file_iteration != verify_iteration => report.push(format!(
                "verify.jsonc.verify_iteration 不匹配: {} != {}",
                file_iteration, verify_iteration
            )),
            Some(_) => {}
            None => report.push("verify.jsonc 缺少 verify_iteration"),
        }

        let acceptance_items = verify_value
            .pointer("/acceptance_evaluation")
            .and_then(|v| v.as_array());
        if acceptance_items.is_none() {
            report.push("verify.jsonc 缺少 acceptance_evaluation");
        }

        let expected_criteria: HashSet<String> = read_json_file(cycle_dir, "plan.jsonc")
            .map_err(|e| ArtifactValidationError::new("artifact_contract_violation", e))?
            .get("acceptance_criteria")
            .and_then(|v| v.as_array())
            .ok_or_else(|| {
                ArtifactValidationError::new(
                    "artifact_contract_violation",
                    "plan.jsonc 缺少 acceptance_criteria",
                )
            })?
            .iter()
            .enumerate()
            .map(|(idx, item)| {
                id_from_value(item, &["criteria_id"])
                    .ok_or_else(|| format!("acceptance_criteria[{}] 缺少 criteria_id", idx))
            })
            .collect::<Result<HashSet<String>, String>>()
            .map_err(|e| ArtifactValidationError::new("artifact_contract_violation", e))?;

        let mut actual_criteria = HashSet::new();
        let mut has_failing_acceptance = false;
        if let Some(acceptance_items) = acceptance_items {
            for (idx, item) in acceptance_items.iter().enumerate() {
                let Some(criteria_id) = id_from_value(item, &["criteria_id"]) else {
                    report.push(format!("acceptance_evaluation[{}] 缺少 criteria_id", idx));
                    continue;
                };
                let Some(status) = item.get("status").and_then(|v| v.as_str()) else {
                    report.push(format!("acceptance_evaluation[{}] 缺少 status", idx));
                    continue;
                };
                if normalize_acceptance_evaluation_status(status).is_none() {
                    report.push(format!(
                        "acceptance_evaluation[{}].status 非法: {}（{}），必须是 pass|fail|insufficient_evidence",
                        idx, status, criteria_id
                    ));
                }
                if as_failing_status(status) {
                    has_failing_acceptance = true;
                }
                actual_criteria.insert(criteria_id);
            }
        }
        if actual_criteria != expected_criteria {
            report.push(format!(
                "acceptance_evaluation 覆盖不完整: expected={:?}, actual={:?}",
                expected_criteria, actual_criteria
            ));
        }

        let verification_overall_result = verify_value
            .pointer("/verification_overall/result")
            .and_then(|v| v.as_str())
            .map(|v| v.trim().to_ascii_lowercase());
        match verification_overall_result.as_deref() {
            Some("pass" | "fail") => {}
            Some(result) => report.push(format!(
                "verify.jsonc.verification_overall.result 非法: {}",
                result
            )),
            None => report.push("verify.jsonc 缺少 verification_overall.result"),
        }
        if has_failing_acceptance && verification_overall_result.as_deref() == Some("pass") {
            report.push(
                "acceptance_evaluation 存在未通过项时 verification_overall.result 不得为 pass",
            );
        }

        let _verify_iteration_limit = verify_value
            .get("verify_iteration_limit")
            .and_then(|v| v.as_u64())
            .map(|v| v as u32);
        match _verify_iteration_limit {
            Some(0) => report.push("verify.jsonc.verify_iteration_limit 必须大于 0"),
            Some(_) => {}
            None => report.push("verify.jsonc 缺少 verify_iteration_limit"),
        }

        let criteria_judgement = verify_value
            .pointer("/adjudication/criteria_judgement")
            .and_then(|v| v.as_array());
        if criteria_judgement.is_none() {
            report.push("verify.jsonc 缺少 adjudication.criteria_judgement");
        }
        let mut judgement_criteria = HashSet::new();
        if let Some(criteria_judgement) = criteria_judgement {
            for (idx, item) in criteria_judgement.iter().enumerate() {
                let Some(criteria_id) = id_from_value(item, &["criteria_id"]) else {
                    report.push(format!(
                        "adjudication.criteria_judgement[{}] 缺少 criteria_id",
                        idx
                    ));
                    continue;
                };
                let Some(result) = item
                    .get("result")
                    .or_else(|| item.get("status"))
                    .and_then(|v| v.as_str())
                    .map(|v| v.trim().to_ascii_lowercase())
                else {
                    report.push(format!(
                        "adjudication.criteria_judgement[{}] 缺少 result/status",
                        idx
                    ));
                    continue;
                };
                if !matches!(result.as_str(), "pass" | "fail" | "insufficient_evidence") {
                    report.push(format!(
                        "adjudication.criteria_judgement[{}].result/status 非法: {}",
                        idx, result
                    ));
                }
                judgement_criteria.insert(criteria_id);
            }
        }
        if judgement_criteria != expected_criteria {
            report.push(format!(
                "adjudication.criteria_judgement 覆盖不完整: expected={:?}, actual={:?}",
                expected_criteria, judgement_criteria
            ));
        }

        let adjudication_result = verify_value
            .pointer("/adjudication/overall_result/result")
            .and_then(|v| v.as_str())
            .map(|v| v.trim().to_ascii_lowercase());
        let adjudication_failed = adjudication_result.as_deref() == Some("fail");
        match adjudication_result.as_deref() {
            Some("pass" | "fail") => {}
            Some(_) => {
                report.push("verify.jsonc.adjudication.overall_result.result 必须是 pass 或 fail")
            }
            None => report.push("verify.jsonc 缺少 adjudication.overall_result.result"),
        }

        let requirements = extract_verify_requirements(&verify_value).unwrap_or_default();
        if backlog_contract_version >= 2 && adjudication_failed && requirements.is_empty() {
            report.push("verify.jsonc 缺少 adjudication.full_next_iteration_requirements");
        }

        let should_validate_v2_selector =
            backlog_contract_version >= 2 && (verify_iteration > 0 || adjudication_failed);
        if should_validate_v2_selector {
            let plan_value = read_json_file(cycle_dir, "plan.jsonc")
                .map_err(|e| ArtifactValidationError::new("artifact_contract_violation", e))?;
            let plan_tables = parse_plan_routing_tables(&plan_value);
            let check_to_work_items = Self::parse_check_to_work_items(&plan_value);
            match (plan_tables, check_to_work_items) {
                (Ok(tables), Ok(check_to_work_items)) => {
                    for (idx, requirement) in requirements.iter().enumerate() {
                        let selector_label =
                            format!("adjudication.full_next_iteration_requirements[{}]", idx);
                        let source_criteria_id = id_from_value(
                            requirement,
                            &["source_criteria_id", "criteria_id", "criterion_id"],
                        );
                        let source_check_id = id_from_value(
                            requirement,
                            &["source_check_id", "check_id", "linked_check_id"],
                        );
                        let work_item_id = id_from_value(requirement, &["work_item_id"]);
                        let raw_agent = requirement
                            .get("implementation_stage_kind")
                            .and_then(|v| v.as_str());

                        let Some(source_criteria_id) = source_criteria_id else {
                            report.push(format!("{}.source_criteria_id 缺失", selector_label));
                            continue;
                        };
                        if is_unknown_selector_value(&source_criteria_id) {
                            report.push(format!(
                                "{}.source_criteria_id 不能为空且不能为 unknown",
                                selector_label
                            ));
                        }

                        let Some(source_check_id) = source_check_id else {
                            report.push(format!("{}.source_check_id 缺失", selector_label));
                            continue;
                        };
                        if is_unknown_selector_value(&source_check_id) {
                            report.push(format!(
                                "{}.source_check_id 不能为空且不能为 unknown",
                                selector_label
                            ));
                        }

                        let Some(work_item_id) = work_item_id else {
                            report.push(format!("{}.work_item_id 缺失", selector_label));
                            continue;
                        };
                        if is_unknown_selector_value(&work_item_id) {
                            report.push(format!(
                                "{}.work_item_id 不能为空且不能为 unknown",
                                selector_label
                            ));
                        }

                        let Some(raw_agent) = raw_agent else {
                            report
                                .push(format!("{}.implementation_stage_kind 缺失", selector_label));
                            continue;
                        };
                        if is_unknown_selector_value(raw_agent) {
                            report.push(format!(
                                "{}.implementation_stage_kind 不能为空且不能为 unknown",
                                selector_label
                            ));
                            continue;
                        }
                        let Some(implementation_stage_kind) =
                            ImplementationStageKind::parse(raw_agent)
                        else {
                            report.push(format!(
                                "{}.implementation_stage_kind 非法: {}",
                                selector_label, raw_agent
                            ));
                            continue;
                        };

                        report.capture(validate_requirement_selector_against_plan(
                            &selector_label,
                            &source_criteria_id,
                            &source_check_id,
                            &work_item_id,
                            implementation_stage_kind,
                            &tables,
                            &check_to_work_items,
                        ));
                    }
                }
                (Err(err), _) | (_, Err(err)) => report.push(err),
            }
        }

        let mut expected = HashSet::new();
        if let Some(acceptance_items) = acceptance_items {
            for (idx, item) in acceptance_items.iter().enumerate() {
                let Some(status) = item.get("status").and_then(|v| v.as_str()) else {
                    report.push(format!("acceptance_evaluation[{}] 缺少 status", idx));
                    continue;
                };
                if as_failing_status(status) {
                    match id_from_value(item, &["criteria_id"]) {
                        Some(criteria_id) => {
                            expected.insert(criteria_id);
                        }
                        None => {
                            report.push(format!("acceptance_evaluation[{}] 缺少 criteria_id", idx))
                        }
                    }
                }
            }
        }

        if verify_iteration > 0 {
            let (backlog, _) = Self::collect_reimplementation_backlog(
                cycle_dir,
                backlog_contract_version,
                verify_iteration,
            )
            .map_err(|e| ArtifactValidationError::new("artifact_contract_violation", e))?;
            let backlog_ids = collect_unique_ids(&backlog, &["id"], "failure_backlog")
                .map_err(|e| ArtifactValidationError::new("artifact_contract_violation", e))?;
            let backlog_set: HashSet<String> = backlog_ids.iter().cloned().collect();

            let carry_items = verify_value
                .pointer("/carryover_verification/items")
                .and_then(|v| v.as_array());
            let carry_summary = verify_value
                .pointer("/carryover_verification/summary")
                .and_then(|v| v.as_object());

            match carry_summary {
                Some(carry_summary) => {
                    for key in ["total", "covered", "missing", "blocked"] {
                        if !carry_summary
                            .get(key)
                            .and_then(|v| v.as_u64())
                            .map(|_| true)
                            .unwrap_or(false)
                        {
                            report.push(format!(
                                "verify.jsonc.carryover_verification.summary.{} 必须是数字",
                                key
                            ));
                        }
                    }
                    let total = carry_summary
                        .get("total")
                        .and_then(|v| v.as_u64())
                        .unwrap_or_default() as usize;
                    if total != backlog_ids.len() {
                        report.push(format!(
                            "carryover_verification.summary.total 与 failure_backlog 数量不一致: {} vs {}",
                            total,
                            backlog_ids.len()
                        ));
                    }
                    let carry_missing = carry_summary
                        .get("missing")
                        .and_then(|v| v.as_u64())
                        .unwrap_or_default();
                    if carry_missing > 0 && verification_overall_result.as_deref() == Some("pass") {
                        report.push(
                            "carryover_verification.summary.missing > 0 时 verification_overall.result 不得为 pass",
                        );
                    }
                }
                None => report
                    .push("verify.jsonc 缺少 carryover_verification.summary（重实现轮必须提供）"),
            }

            match carry_items {
                Some(carry_items) => {
                    let carry_ids = match collect_unique_ids(
                        carry_items,
                        &["id", "item_id"],
                        "carryover_verification.items",
                    ) {
                        Ok(ids) => Some(ids),
                        Err(err) => {
                            report.push(err);
                            None
                        }
                    };
                    if let Some(carry_ids) = carry_ids {
                        let carry_set: HashSet<String> = carry_ids.into_iter().collect();
                        let missing_ids: Vec<String> = backlog_set
                            .difference(&carry_set)
                            .cloned()
                            .collect::<Vec<String>>();
                        if !missing_ids.is_empty() {
                            report.push(format!(
                                "carryover_verification.items 缺少 backlog 项: {:?}",
                                missing_ids
                            ));
                        }
                    }

                    for (idx, item) in carry_items.iter().enumerate() {
                        let status = item
                            .get("status")
                            .and_then(|v| v.as_str())
                            .unwrap_or("missing");
                        if is_carryover_failure_status(status) {
                            match id_from_value(item, &["id", "item_id"]) {
                                Some(item_id) => {
                                    expected.insert(item_id);
                                }
                                None => report
                                    .push(format!("carryover_verification.items[{}] 缺少 id", idx)),
                            }
                        }
                    }
                }
                None => report
                    .push("verify.jsonc 缺少 carryover_verification.items（重实现轮必须提供）"),
            }
        }

        if !requirements.is_empty() {
            match collect_requirement_match_keys(
                &requirements,
                "adjudication.full_next_iteration_requirements",
            ) {
                Ok(requirement_set) => {
                    let missing_expected: Vec<String> = expected
                        .difference(&requirement_set)
                        .cloned()
                        .collect::<Vec<String>>();
                    if !missing_expected.is_empty() {
                        report.push(format!(
                            "adjudication.full_next_iteration_requirements 未覆盖 verify 未通过项: {:?}",
                            missing_expected
                        ));
                    }
                }
                Err(err) => report.push(err),
            }
        }

        report.into_error("artifact_contract_violation")
    }
    fn validate_direction_artifact(
        cycle_dir: &Path,
        validation_ctx: Option<&StageValidationContext>,
    ) -> Result<(), ArtifactValidationError> {
        let stage_value = read_json_file(cycle_dir, "direction.jsonc")
            .map_err(|e| ArtifactValidationError::new("artifact_contract_violation", e))?;
        let mut report = ValidationReport::default();
        // WI-003: 校验 $schema_version 与 stage 字段
        report.capture(ensure_schema_version(
            "direction.jsonc",
            &stage_value,
            STAGE_ARTIFACT_REQUIRED_SCHEMA_VERSION,
        ));
        report.capture(ensure_stage_field_matches(
            "direction.jsonc",
            &stage_value,
            "direction",
        ));
        if let Some(ctx) = validation_ctx {
            report.capture(ensure_cycle_id_matches(
                "direction.jsonc",
                &stage_value,
                &ctx.cycle_id,
            ));
            report.capture(ensure_artifact_freshness(
                "direction.jsonc",
                &stage_value,
                ctx.stage_started_at,
            ));
        }
        match stage_value.get("direction_statement") {
            Some(value) => match value.as_str() {
                Some(text) if !text.trim().is_empty() => {}
                Some(_) => report.push("direction.jsonc.direction_statement 不能为空"),
                None => report.push("direction.jsonc.direction_statement 必须是非空字符串"),
            },
            None => report.push("direction.jsonc 缺少 direction_statement"),
        }

        for key in ["updated_at"] {
            match stage_value.get(key) {
                Some(value) => match value.as_str() {
                    Some(text) if !text.trim().is_empty() => {}
                    Some(_) => report.push(format!("direction.jsonc.{} 不能为空", key)),
                    None => report.push(format!("direction.jsonc.{} 必须是非空字符串", key)),
                },
                None => report.push(format!("direction.jsonc.{} 缺少", key)),
            }
        }
        report.into_error("artifact_contract_violation")
    }

    fn validate_auto_commit_artifact(
        cycle_dir: &Path,
        validation_ctx: Option<&StageValidationContext>,
    ) -> Result<(), ArtifactValidationError> {
        let stage_auto_commit = read_json_file(cycle_dir, "auto_commit.jsonc")
            .map_err(|e| ArtifactValidationError::new("artifact_contract_violation", e))?;
        let mut report = ValidationReport::default();
        if let Some(ctx) = validation_ctx {
            report.capture(ensure_cycle_id_matches(
                "auto_commit.jsonc",
                &stage_auto_commit,
                &ctx.cycle_id,
            ));
            report.capture(ensure_artifact_freshness(
                "auto_commit.jsonc",
                &stage_auto_commit,
                ctx.stage_started_at,
            ));
        }
        if let Some(ctx) = validation_ctx {
            let workspace_root = Path::new(ctx.workspace_root.as_str());
            let repo_dirty = git_repo_has_changes(workspace_root)
                .map_err(|e| ArtifactValidationError::new("artifact_contract_violation", e))?;
            if repo_dirty {
                let reason = stage_auto_commit
                    .pointer("/decision/reason")
                    .and_then(|v| v.as_str())
                    .map(|v| v.to_ascii_lowercase())
                    .unwrap_or_default();
                let no_changes_declared =
                    reason.contains("无可提交变更") || reason.contains("no changes to commit");
                if !no_changes_declared {
                    report
                        .push("auto_commit 阶段结束后工作区仍有未提交变更，且未声明“无可提交变更”");
                }
            }
        }
        report.into_error("artifact_contract_violation")
    }

    fn validate_stage_artifacts_with_context(
        stage: &str,
        cycle_dir: &Path,
        verify_iteration: u32,
        backlog_contract_version: u32,
        validation_ctx: Option<&StageValidationContext>,
    ) -> Result<(), ArtifactValidationError> {
        match stage {
            "direction" => Self::validate_direction_artifact(cycle_dir, validation_ctx),
            "plan" => Self::validate_plan_artifact(cycle_dir, validation_ctx),
            "verify" => Self::validate_verify_artifact(
                cycle_dir,
                verify_iteration,
                backlog_contract_version,
                validation_ctx,
            ),
            "auto_commit" => Self::validate_auto_commit_artifact(cycle_dir, validation_ctx),
            _ if is_runtime_implement_stage(stage) || is_runtime_reimplement_stage(stage) => {
                Self::validate_implement_artifact(
                    stage,
                    cycle_dir,
                    verify_iteration,
                    backlog_contract_version,
                    validation_ctx,
                )
            }
            _ => Ok(()),
        }
    }

    #[cfg(test)]
    fn validate_stage_artifacts(
        stage: &str,
        cycle_dir: &Path,
        verify_iteration: u32,
        backlog_contract_version: u32,
    ) -> Result<(), String> {
        Self::validate_stage_artifacts_with_context(
            stage,
            cycle_dir,
            verify_iteration,
            backlog_contract_version,
            None,
        )
        .map_err(|err| err.message)
    }

    fn extract_acceptance_mapping_criteria(
        value: &serde_json::Value,
    ) -> Result<Vec<serde_json::Value>, String> {
        let mapping = value
            .pointer("/verification_plan/acceptance_mapping")
            .and_then(|v| v.as_array())
            .ok_or_else(|| "plan.jsonc 缺少 verification_plan.acceptance_mapping".to_string())?;

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

    fn extract_plan_acceptance_criteria(
        value: &serde_json::Value,
    ) -> Result<Vec<serde_json::Value>, String> {
        let criteria = value
            .get("acceptance_criteria")
            .and_then(|v| v.as_array())
            .ok_or_else(|| "plan.jsonc 缺少 acceptance_criteria".to_string())?;

        let mut out = Vec::new();
        for item in criteria {
            let Some(obj) = item.as_object() else {
                return Err("acceptance_criteria 条目必须是对象".to_string());
            };
            let criteria_id = obj
                .get("criteria_id")
                .and_then(|v| v.as_str())
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty())
                .ok_or_else(|| "acceptance_criteria 条目缺少 criteria_id".to_string())?;
            let description = obj
                .get("description")
                .and_then(|v| v.as_str())
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty())
                .ok_or_else(|| format!("{} 的 description 不能为空", criteria_id))?;
            out.push(serde_json::json!({
                "criteria_id": criteria_id,
                "description": description,
            }));
        }
        if out.is_empty() {
            return Err("plan.jsonc.acceptance_criteria 不能为空".to_string());
        }
        Ok(out)
    }

    async fn ensure_acceptance_consistency(&self, key: &str, cycle_id: &str) -> Result<(), String> {
        let workspace_root = {
            let state = self.state.lock().await;
            let Some(entry) = state.workspaces.get(key) else {
                return Err("workspace state missing".to_string());
            };
            entry.workspace_root.clone()
        };
        let cycle_dir = cycle_dir_path(&workspace_root, cycle_id)?;
        let parsed = read_json(&cycle_dir.join("plan.jsonc"))
            .map_err(|e| format!("读取 plan.jsonc 失败: {}", e))?;
        let criteria_from_plan = Self::extract_plan_acceptance_criteria(&parsed)?;
        let expected_ids: std::collections::HashSet<String> = criteria_from_plan
            .iter()
            .filter_map(|v| {
                v.get("criteria_id")
                    .and_then(|x| x.as_str())
                    .map(|s| s.to_string())
            })
            .collect();
        let actual_ids: std::collections::HashSet<String> =
            Self::extract_acceptance_mapping_criteria(&parsed)?
                .iter()
                .filter_map(|v| {
                    v.get("criteria_id")
                        .and_then(|x| x.as_str())
                        .map(|s| s.to_string())
                })
                .collect();
        if expected_ids != actual_ids {
            return Err(format!(
                "criteria_id 集不一致: acceptance_criteria={:?}, acceptance_mapping={:?}",
                expected_ids, actual_ids
            ));
        }
        Ok(())
    }

    async fn sync_direction_state_from_artifact(
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
        let direction_stage = read_json_file(&cycle_dir, "direction.jsonc")?;
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

    #[cfg(test)]
    fn map_failed_agents_from_results(
        cycle_dir: &Path,
        tables: &PlanRoutingTables,
    ) -> Result<Option<HashSet<ImplementationStageKind>>, String> {
        let verify = read_json_file(cycle_dir, "verify.jsonc")?;

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
        if let Some(items) = verify
            .pointer("/adjudication/criteria_judgement")
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

        let mut mapped_agents: HashSet<ImplementationStageKind> = HashSet::new();
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
                if let Some(agents) = tables.check_to_stage_kinds.get(check_id) {
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

            if let Some(agents) = tables.check_to_stage_kinds.get(&item_id) {
                mapped_agents.extend(agents.iter().copied());
                item_mapped = true;
            }

            if let Some(check_ids) = tables.criteria_to_checks.get(&item_id) {
                let mut criteria_mapped = false;
                for check_id in check_ids {
                    if let Some(agents) = tables.check_to_stage_kinds.get(check_id) {
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

    fn stage_owned_artifact_paths(stage: &str, cycle_dir: &Path) -> Vec<PathBuf> {
        match stage {
            "direction" => vec![cycle_dir.join("direction.jsonc")],
            "plan" => vec![
                cycle_dir.join("plan.jsonc"),
                cycle_dir.join(PLAN_MARKDOWN_FILE),
            ],
            "verify" => vec![cycle_dir.join("verify.jsonc")],
            "auto_commit" => vec![cycle_dir.join("auto_commit.jsonc")],
            other => stage_artifact_file(other)
                .map(|file_name| vec![cycle_dir.join(file_name)])
                .unwrap_or_default(),
        }
    }

    fn reset_stage_owned_artifacts(stage: &str, cycle_dir: &Path) -> Result<(), String> {
        for path in Self::stage_owned_artifact_paths(stage, cycle_dir) {
            if !path.exists() {
                continue;
            }
            if let Err(err) = std::fs::remove_file(&path) {
                return Err(format!("清理旧产物失败 ({}): {}", path.display(), err));
            }
        }
        Ok(())
    }

    fn ensure_jsonc_template(path: &Path, content: &str) -> Result<(), String> {
        let mut target = path.to_path_buf();
        if target
            .extension()
            .and_then(|v| v.to_str())
            .map(|v| v.eq_ignore_ascii_case("json"))
            .unwrap_or(false)
        {
            target.set_extension("jsonc");
        }
        if target.exists() {
            return Ok(());
        }
        write_jsonc_text(&target, content)
            .map_err(|e| format!("写入 JSONC 模板失败 ({}): {}", target.display(), e))
    }

    fn ensure_text_template(path: &Path, content: &str) -> Result<(), String> {
        if path.exists() {
            return Ok(());
        }
        write_text(path, content)
            .map_err(|e| format!("写入文本模板失败 ({}): {}", path.display(), e))
    }

    fn ensure_stage_templates(
        stage: &str,
        cycle_dir: &Path,
        verify_iteration: u32,
        verify_iteration_limit: u32,
        backlog_contract_version: u32,
    ) -> Result<(), String> {
        let cycle_id = read_json_file(cycle_dir, "cycle.jsonc")
            .ok()
            .and_then(|v| {
                v.get("cycle_id")
                    .and_then(|x| x.as_str())
                    .map(|s| s.to_string())
            })
            .unwrap_or_default();

        match stage {
            "direction" => {
                Self::ensure_jsonc_template(
                    &cycle_dir.join("direction.jsonc"),
                    &direction_stage_template(&cycle_id),
                )?;
            }
            "plan" => {
                Self::ensure_jsonc_template(
                    &cycle_dir.join("plan.jsonc"),
                    &plan_stage_template(&cycle_id),
                )?;
                Self::ensure_text_template(
                    &cycle_dir.join(PLAN_MARKDOWN_FILE),
                    &plan_markdown_template(&cycle_id),
                )?;
            }
            "verify" => {
                Self::ensure_jsonc_template(
                    &cycle_dir.join("verify.jsonc"),
                    &verify_stage_template(&cycle_id, verify_iteration, verify_iteration_limit),
                )?;
            }
            "auto_commit" => {
                Self::ensure_jsonc_template(
                    &cycle_dir.join("auto_commit.jsonc"),
                    &auto_commit_stage_template(&cycle_id),
                )?;
            }
            _ if is_runtime_implement_stage(stage) || is_runtime_reimplement_stage(stage) => {
                let artifact_file =
                    stage_artifact_file(stage).ok_or_else(|| format!("未知实现阶段: {}", stage))?;
                Self::ensure_jsonc_template(
                    &cycle_dir.join(artifact_file),
                    &implement_stage_template(
                        stage,
                        &cycle_id,
                        verify_iteration,
                        backlog_contract_version,
                    ),
                )?;
            }
            _ => {}
        }

        if verify_iteration > 0 && backlog_contract_version >= 2 {
            Self::ensure_jsonc_template(
                &cycle_dir.join(MANAGED_BACKLOG_FILE),
                &managed_backlog_template(&cycle_id, verify_iteration),
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
        let created_at_ms = Utc::now().timestamp_millis();
        if let Err(err) = record_session_index_created(
            &ctx.ai_state,
            project,
            workspace,
            &ai_tool,
            &directory,
            &session.id,
            &session.title,
            created_at_ms,
            AiSessionOrigin::EvolutionSystem,
        )
        .await
        {
            warn!(
                "evolution create session persist index failed: project={}, workspace={}, stage={}, ai_tool={}, session_id={}, error={}",
                project, workspace, stage, ai_tool, session.id, err
            );
            if let Err(delete_err) = agent.delete_session(&directory, &session.id).await {
                warn!(
                    "evolution create session rollback delete failed: project={}, workspace={}, stage={}, ai_tool={}, session_id={}, error={}",
                    project, workspace, stage, ai_tool, session.id, delete_err
                );
            }
            return Err(format!("failed to persist ai session index: {}", err));
        }
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
                touch_session_index_updated_at_for_evolution(
                    ctx,
                    project,
                    workspace,
                    &ai_tool,
                    &session.id,
                )
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
            touch_session_index_updated_at_for_evolution(
                ctx,
                project,
                workspace,
                &ai_tool,
                &session.id,
            )
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

    #[cfg(test)]
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
        matches!(stage, "direction" | "plan" | "verify" | "auto_commit")
            || is_runtime_implement_stage(stage)
            || is_runtime_reimplement_stage(stage)
    }

    fn should_retry_validation_with_reminder(stage: &str, err: &str) -> bool {
        if !Self::supports_validation_reminder(stage) {
            return false;
        }

        let normalized_err = err.trim();
        normalized_err.starts_with("evo_stage_output_invalid:")
            || normalized_err.contains("artifact_contract_violation")
            || normalized_err.contains("evo_backlog_mapping_missing")
            || normalized_err.contains("evo_backlog_mapping_ambiguous")
    }

    fn validation_target_files_for_stage(stage: &str) -> String {
        let normalized_stage = stage.trim().to_ascii_lowercase();
        match normalized_stage.as_str() {
            "direction" => "direction.jsonc / cycle.jsonc".to_string(),
            "plan" => "plan.jsonc / plan.md / direction.jsonc".to_string(),
            "verify" => "verify.jsonc / plan.jsonc / plan.md / managed.backlog.jsonc".to_string(),
            "auto_commit" => "auto_commit.jsonc / git 工作区状态".to_string(),
            _ => {
                if let Some(file_name) = stage_artifact_file(stage) {
                    return format!(
                        "{} / plan.jsonc / plan.md / managed.backlog.jsonc",
                        file_name
                    );
                }
                let stage_name = if normalized_stage.is_empty() {
                    "unknown".to_string()
                } else {
                    normalized_stage
                };
                format!("{}.jsonc / 对应阶段产物", stage_name)
            }
        }
    }

    fn build_validation_fix_hint(stage: &str, error_message: &str) -> String {
        let normalized_error_message = error_message.trim();
        let normalized_stage = stage.trim().to_ascii_lowercase();
        let expected_stage_kind =
            implementation_stage_kind_for_stage(stage).map(|kind| kind.as_str().to_string());
        let expected_selector_text = match stage.trim().to_ascii_lowercase().as_str() {
            "implement_general" | "implement_visual" | "implement_advanced" => {
                stage.trim().to_ascii_lowercase()
            }
            _ => expected_stage_kind.clone().unwrap_or_default(),
        };
        let is_execution_stage =
            expected_stage_kind.is_some() || is_runtime_reimplement_stage(stage);

        if normalized_stage == "verify"
            && normalized_error_message.contains("carryover_verification.items")
            && normalized_error_message.contains("缺少 backlog 项")
        {
            return "carryover_verification.items[*].id 或 item_id 必须与 managed.backlog.jsonc.items[*].id 一一对应；不要自造 CARRYOVER-001 这类占位 ID，也不要只写 backlog 字段。请把报错里缺失的 backlog 真实 id 直接填回对应条目。".to_string();
        }

        if normalized_stage == "verify"
            && normalized_error_message.contains("carryover_verification.items[")
            && (normalized_error_message.contains("缺少有效 id")
                || normalized_error_message.contains("缺少 id"))
        {
            return "carryover_verification.items[*] 必须填写 id 或 item_id，且该值必须直接复用 managed.backlog.jsonc.items[*].id；不要生成新的流水号，也不要只补 backlog / failure_backlog_id 这类旁路字段。".to_string();
        }

        if normalized_stage == "verify"
            && normalized_error_message.contains("carryover_verification.summary.total")
            && normalized_error_message.contains("failure_backlog 数量不一致")
        {
            return "carryover_verification.summary.total 必须等于 managed.backlog.jsonc.items 的数量；covered / missing / blocked 也要与 carryover_verification.items 的实际状态统计保持一致。".to_string();
        }

        if is_execution_stage && normalized_error_message.contains("quick_checks") {
            return "quick_checks 必须是数组（[]），即使没有检查项也必须输出 []；不要写成对象。"
                .to_string();
        }

        if is_execution_stage
            && normalized_error_message.contains("backlog_resolution_updates")
            && normalized_error_message.contains("selector 字段不能为空")
        {
            return "backlog_resolution_updates[*].selector 必须完整填写 source_criteria_id/source_check_id/work_item_id/implementation_stage_kind。".to_string();
        }

        if expected_stage_kind.is_some()
            && normalized_error_message.contains("backlog_resolution_updates")
            && normalized_error_message.contains("implementation_stage_kind")
            && normalized_error_message.contains("必须等于")
        {
            return format!(
                "backlog_resolution_updates[*].implementation_stage_kind 必须等于当前实现阶段类型（{}）；不要复用其它类型的值。",
                expected_selector_text
            );
        }

        if is_execution_stage
            && normalized_error_message.contains("backlog_resolution_updates")
            && (normalized_error_message.contains("缺失")
                || normalized_error_message.contains("缺少")
                || normalized_error_message.contains("必须是数组"))
        {
            return "BACKLOG_CONTRACT_VERSION>=2 时必须输出 backlog_resolution_updates 数组；若本阶段无需回填，也要写 []。".to_string();
        }

        if is_execution_stage
            && normalized_error_message.contains("backlog_resolution_updates")
            && normalized_error_message.contains("status 必须是 done|blocked|not_done")
        {
            return "backlog_resolution_updates[*].status 只能是 done、blocked 或 not_done；不要使用其它状态值。".to_string();
        }

        if !expected_selector_text.is_empty() {
            if normalized_error_message.contains("evo_backlog_mapping_missing") {
                return format!(
                    "无法将 backlog_resolution_updates 的 selector 映射到 managed.backlog.jsonc。请复制该文件中 implementation_stage_kind={} 的原始 selector 组合后再回填。",
                    expected_selector_text
                );
            }

            if normalized_error_message.contains("evo_backlog_mapping_ambiguous") {
                return format!(
                    "selector 映射出现歧义，请在 backlog_resolution_updates 中使用与 managed.backlog.jsonc 一一对应且唯一的 selector（implementation_stage_kind={}）。",
                    expected_selector_text
                );
            }
        }

        if normalized_error_message.contains("不能为空")
            || normalized_error_message.contains("必须是")
        {
            if let Some(field) = [
                "ui_capability",
                "test_capability",
                "build_capability",
                "runtime_capability",
            ]
            .iter()
            .find(|field| normalized_error_message.contains(**field))
            {
                return format!(
                    "{} 必须填写为非空字符串（建议值：none|partial|full），禁止使用 true/false。",
                    field
                );
            }
        }

        if normalized_error_message.contains("必须是数字") {
            return "将该字段改为数字类型（JSON number），不要使用字符串或对象。".to_string();
        }
        if normalized_error_message.contains("plan.md") && normalized_error_message.contains("读取")
        {
            return "补齐 plan.md 文件即可；当前系统只要求该文件存在，不校验其具体格式。"
                .to_string();
        }
        if normalized_error_message.contains("必须是对象") {
            return "将该字段改为对象类型（{}），并补齐对象内必填子字段。".to_string();
        }
        if normalized_error_message.contains("缺少") && normalized_error_message.contains("数组")
        {
            return "该字段必须是数组（[]），请按契约补齐并填充至少所需条目。".to_string();
        }
        if normalized_error_message.contains("必须是数组")
            || normalized_error_message.contains("写成数组")
        {
            return "将该字段改为数组类型（[]），元素结构按阶段契约输出。".to_string();
        }
        if normalized_error_message.contains("不能为空") {
            return "将必填字段填为非空值（字符串非空、数组至少 1 项、对象含必需键）。".to_string();
        }
        if normalized_error_message.contains("缺少") {
            return "补齐缺失字段，保持字段名与层级路径和阶段产物契约一致。".to_string();
        }
        if normalized_error_message.contains("不匹配")
            || normalized_error_message.contains("不一致")
        {
            return "修正关联字段，使跨文件/跨字段引用保持一一对应且数值一致。".to_string();
        }
        if normalized_error_message.contains("覆盖不完整")
            || normalized_error_message.contains("未完整覆盖")
        {
            return "补齐缺失项，确保 expected 集合与 actual 集合完全一致。".to_string();
        }
        if normalized_error_message.contains("非法") {
            return "将字段值改为契约允许枚举值；必要时参考该阶段允许值列表。".to_string();
        }
        if normalized_error_message.contains("必须是") {
            return "将字段值改为契约要求的类型或枚举值，严格按提示中的允许集合填写。".to_string();
        }

        "请逐项核对字段名、字段类型（数组/对象/数字）、枚举值与必填项，修复后重新输出本阶段产物。"
            .to_string()
    }

    fn build_validation_reminder_spec(
        stage: &str,
        validation_err: &ArtifactValidationError,
    ) -> ValidationReminderSpec {
        let mut fix_hints = Vec::new();
        for issue in validation_err.issues() {
            let hint = Self::build_validation_fix_hint(stage, issue);
            if !fix_hints.iter().any(|existing| existing == &hint) {
                fix_hints.push(hint);
            }
        }
        let target_files = Self::validation_target_files_for_stage(stage);
        let immediate_fix_actions = vec![
            format!("打开并修改目标产物：{}", target_files),
            "按“问题清单”逐项修正字段名/类型/必填项，务必一次性改完再重试。".to_string(),
            "重新输出本阶段产物并自检；不要只解释，不要停留在分析。".to_string(),
        ];

        ValidationReminderSpec {
            error_code: validation_err.code.to_string(),
            summary: validation_err.message.clone(),
            issues: validation_err.issues().to_vec(),
            fix_hints,
            immediate_fix_actions,
            raw_error: validation_err.to_stage_error(),
        }
    }

    fn build_validation_reminder_message(
        stage: &str,
        validation_err: &ArtifactValidationError,
    ) -> String {
        let spec = Self::build_validation_reminder_spec(stage, validation_err);
        let mut lines = vec![
            format!("【VALIDATION_BLOCKER｜阶段:{}】", stage),
            format!("错误码：{}", spec.error_code),
            format!("摘要：{}", spec.summary),
            "问题清单：".to_string(),
        ];
        for (idx, issue) in spec.issues.iter().enumerate() {
            lines.push(format!("{}. {}", idx + 1, issue));
        }
        if !spec.fix_hints.is_empty() {
            lines.push("修复提示：".to_string());
            for (idx, hint) in spec.fix_hints.iter().enumerate() {
                lines.push(format!("{}. {}", idx + 1, hint));
            }
        }
        lines.extend(vec![
            "立即修复动作：".to_string(),
            format!(
                "1. {}",
                spec.immediate_fix_actions
                    .first()
                    .cloned()
                    .unwrap_or_default()
            ),
            format!(
                "2. {}",
                spec.immediate_fix_actions
                    .get(1)
                    .cloned()
                    .unwrap_or_default()
            ),
            format!(
                "3. {}",
                spec.immediate_fix_actions
                    .get(2)
                    .cloned()
                    .unwrap_or_default()
            ),
            format!("原始报错：{}", spec.raw_error),
        ]);
        format!("<system-reminder>{}</system-reminder>", lines.join("\n"))
    }

    #[cfg(test)]
    fn parse_validation_error_code_and_message(validation_err: &str) -> (String, String) {
        let trimmed = validation_err.trim();
        let payload = trimmed
            .strip_prefix("evo_stage_output_invalid:")
            .unwrap_or(trimmed)
            .trim();
        if payload.is_empty() {
            return (
                "artifact_contract_violation".to_string(),
                "未提供详细错误信息（artifact_contract_violation）".to_string(),
            );
        }
        if let Some((code, message)) = payload.split_once(':') {
            let normalized_code = code.trim();
            let normalized_message = message.trim();
            if !normalized_code.is_empty() {
                if normalized_message.is_empty() {
                    return (
                        normalized_code.to_string(),
                        format!("未提供详细错误信息（{}）", normalized_code),
                    );
                }
                return (normalized_code.to_string(), normalized_message.to_string());
            }
        }
        (
            "artifact_contract_violation".to_string(),
            payload.to_string(),
        )
    }

    fn append_stage_validation_attempt(
        cycle_dir: &Path,
        stage: &str,
        attempt: u32,
        session_id: &str,
        validation_err: &ArtifactValidationError,
    ) -> Result<(), String> {
        let cycle_file = cycle_dir.join("cycle.jsonc");
        let mut value = if cycle_file.exists() {
            read_json(&cycle_file)
                .map_err(|e| format!("读取 {} 失败: {}", cycle_file.display(), e))?
        } else {
            serde_json::json!({})
        };
        let obj = value
            .as_object_mut()
            .ok_or_else(|| format!("{} 顶层必须是对象", cycle_file.display()))?;
        let stage_runtime = obj
            .entry("stage_runtime".to_string())
            .or_insert_with(|| serde_json::json!({}));
        let runtime_obj = stage_runtime
            .as_object_mut()
            .ok_or_else(|| format!("{}.stage_runtime 必须是对象", cycle_file.display()))?;
        let stage_entry = runtime_obj
            .entry(stage.to_string())
            .or_insert_with(|| serde_json::json!({}));
        let stage_obj = stage_entry.as_object_mut().ok_or_else(|| {
            format!(
                "{}.stage_runtime.{} 必须是对象",
                cycle_file.display(),
                stage
            )
        })?;
        let attempts = stage_obj
            .entry("validation_attempts".to_string())
            .or_insert_with(|| serde_json::json!([]));
        let attempts_array = attempts
            .as_array_mut()
            .ok_or_else(|| format!("{}.validation_attempts 必须是数组", cycle_file.display()))?;
        let existing_attempts = sanitize_validation_attempts(Some(&serde_json::Value::Array(
            std::mem::take(attempts_array),
        )));
        *attempts_array = existing_attempts.as_array().cloned().unwrap_or_default();
        attempts_array.push(sanitize_validation_attempt(serde_json::json!({
            "attempt": attempt,
            "error_code": validation_err.code,
            "message": validation_err.message.clone(),
            "issues": validation_err.issues().to_vec(),
            "ts": Utc::now().to_rfc3339(),
            "session_id": session_id,
        })));
        write_json(&cycle_file, &value)
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
                                let emit_ops = emit_ops_for_cache_op(&snapshot, &op);
                                self.broadcast(
                                    ctx,
                                    build_ai_session_messages_update(
                                        project,
                                        workspace,
                                        ai_tool,
                                        session_id,
                                        &snapshot,
                                        Some(emit_ops),
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
                                let emit_ops = emit_ops_for_cache_op(&snapshot, &op);
                                self.broadcast(
                                    ctx,
                                    build_ai_session_messages_update(
                                        project,
                                        workspace,
                                        ai_tool,
                                        session_id,
                                        &snapshot,
                                        Some(emit_ops),
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
                            touch_session_index_updated_at_for_evolution(
                                ctx, project, workspace, ai_tool, session_id,
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

    fn resolve_stage_outcome_from_validated_artifacts(
        stage: &str,
        cycle_dir: &Path,
    ) -> Result<Option<bool>, ArtifactValidationError> {
        match stage {
            // 阶段特有结果提取必须建立在统一产物校验已经通过的前提上，
            // 避免某个阶段提前读产物并绕过 reminder 重试链路。
            "verify" => {
                let json = read_json_file(cycle_dir, "verify.jsonc")
                    .map_err(|e| ArtifactValidationError::new("artifact_contract_violation", e))?;
                let verify_pass = parse_adjudication_result_from_json(&json).ok_or_else(|| {
                    ArtifactValidationError::new(
                        "artifact_contract_violation",
                        "verify.jsonc 缺少 adjudication.overall_result.result（必须是 pass 或 fail）",
                    )
                })?;
                Ok(Some(verify_pass))
            }
            _ => Ok(None),
        }
    }

    async fn validate_stage_outputs(
        &self,
        key: &str,
        stage: &str,
        cycle_id: &str,
    ) -> Result<(), ArtifactValidationError> {
        let validation_ctx = {
            let state = self.state.lock().await;
            state
                .workspaces
                .get(key)
                .map(|entry| StageValidationContext {
                    cycle_id: cycle_id.to_string(),
                    verify_iteration: entry.verify_iteration,
                    backlog_contract_version: entry.backlog_contract_version,
                    stage_started_at: entry
                        .stage_started_ats
                        .get(stage)
                        .and_then(|v| parse_rfc3339_utc(v)),
                    workspace_root: entry.workspace_root.clone(),
                })
        };
        if let Some(mut ctx) = validation_ctx {
            let cycle_dir = cycle_dir_path(&ctx.workspace_root, cycle_id)
                .map_err(|e| ArtifactValidationError::new("artifact_contract_violation", e))?;
            let contract_version = if ctx.backlog_contract_version == 0 {
                backlog_contract_version_from_cycle(&cycle_dir)
                    .map_err(|e| ArtifactValidationError::new("artifact_contract_violation", e))?
            } else {
                ctx.backlog_contract_version
            };
            ctx.backlog_contract_version = contract_version;
            // 系统在校验前自动注入 updated_at，代理无需维护该字段
            if let Some(artifact_file) = stage_artifact_file(stage) {
                let artifact_path = cycle_dir.join(artifact_file);
                if let Err(e) = inject_stage_artifact_updated_at(&artifact_path) {
                    warn!(
                        "inject updated_at failed: stage={}, path={}, error={}",
                        stage,
                        artifact_path.display(),
                        e
                    );
                }
            }
            if ctx.verify_iteration > 0
                && contract_version >= 2
                && (is_runtime_implement_stage(stage) || is_runtime_reimplement_stage(stage))
            {
                Self::sync_managed_backlog_for_execution_stage(&cycle_dir, stage)?;
            }
            Self::validate_stage_artifacts_with_context(
                stage,
                &cycle_dir,
                ctx.verify_iteration,
                contract_version,
                Some(&ctx),
            )?;
            if stage == "direction" {
                self.sync_direction_state_from_artifact(key, cycle_id)
                    .await
                    .map_err(|e| ArtifactValidationError::new("direction_state_sync_failed", e))?;
            }
        }
        Ok(())
    }

    async fn send_stage_prompt_in_same_session(
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
        prompt: &str,
        model: Option<AiModelSelection>,
        mode: Option<String>,
        config_overrides: Option<std::collections::HashMap<String, serde_json::Value>>,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        let stream = agent
            .send_message_with_config(
                directory,
                session_id,
                prompt,
                None,
                None,
                None,
                model.clone(),
                mode.clone(),
                config_overrides.clone(),
            )
            .await
            .map_err(|e| format!("stage prompt send failed: {}", e))?;
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
        validation_err: &ArtifactValidationError,
        model: Option<AiModelSelection>,
        mode: Option<String>,
        config_overrides: Option<std::collections::HashMap<String, serde_json::Value>>,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        let reminder = Self::build_validation_reminder_message(stage, validation_err);
        self.send_stage_prompt_in_same_session(
            key,
            project,
            workspace,
            cycle_id,
            stage,
            ai_tool,
            session_id,
            directory,
            agent,
            &reminder,
            model,
            mode,
            config_overrides,
            ctx,
        )
        .await
        .map_err(|e| format!("validation reminder send failed: {}", e))
    }

    async fn finalize_stage_failed(
        &self,
        key: &str,
        stage: &str,
        project: &str,
        workspace: &str,
        ai_tool: Option<&str>,
        session_id: Option<&str>,
        error_message: &str,
        ctx: &HandlerContext,
    ) {
        // WI-004: 结构化错误日志落盘
        let cycle_id = {
            let state = self.state.lock().await;
            state
                .workspaces
                .get(key)
                .map(|e| e.cycle_id.clone())
                .unwrap_or_default()
        };
        log_evolution_error(&cycle_id, stage, "evo_stage_failed", error_message);
        self.set_stage_status(key, stage, "failed").await;
        if let Some(session_id) = session_id {
            let tool_call_count = self.stage_tool_call_count(key, stage).await;
            self.finalize_session_execution(key, stage, session_id, "failed", tool_call_count)
                .await;
            if let Some(ai_tool) = ai_tool {
                touch_session_index_updated_at_for_evolution(
                    ctx, project, workspace, ai_tool, session_id,
                )
                .await;
            }
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
        let (
            verify_iteration,
            verify_iteration_limit,
            backlog_contract_version,
            workspace_root,
            stage_profile,
        ) = {
            let state = self.state.lock().await;
            let entry = state
                .workspaces
                .get(key)
                .ok_or_else(|| "workspace state missing".to_string())?;
            (
                entry.verify_iteration,
                entry.verify_iteration_limit,
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

        // WI-005: 边界场景预检，空项目 / 缺失目录及早返回结构化错误
        if let Err(boundary_err) = check_workspace_boundary(&workspace_root, cycle_id) {
            log_evolution_error(cycle_id, stage, "evo_boundary_check_failed", &boundary_err);
            return Err(boundary_err);
        }

        let cycle_dir = cycle_dir_path(&workspace_root, cycle_id)?;
        Self::reset_stage_owned_artifacts(stage, &cycle_dir)?;
        Self::ensure_stage_templates(
            stage,
            &cycle_dir,
            verify_iteration,
            verify_iteration_limit,
            backlog_contract_version,
        )?;

        self.set_stage_status(key, stage, "running").await;
        self.reset_stage_tool_call_tracking(key, stage).await;
        self.persist_cycle_file(key).await.ok();
        self.persist_stage_file(key, stage, "running", None, None)
            .await
            .ok();
        self.broadcast_cycle_update(key, ctx, "orchestrator").await;

        let mut injected_context_keys: HashSet<String> = HashSet::new();
        let (stage_prompt, prompt_injected_keys) = self
            .build_stage_prompt(
                key,
                project,
                workspace,
                cycle_id,
                stage,
                round,
                &injected_context_keys,
            )
            .await?;
        injected_context_keys.extend(prompt_injected_keys);

        let run_ctx = self
            .run_stage_session_once(
                key,
                project,
                workspace,
                cycle_id,
                stage,
                stage_profile,
                stage_prompt,
                ctx,
            )
            .await?;

        let mut verify_pass = true;
        let mut reminder_attempts: u32 = 0;
        loop {
            let validation_result = match self.validate_stage_outputs(key, stage, cycle_id).await {
                Ok(()) => Self::resolve_stage_outcome_from_validated_artifacts(stage, &cycle_dir),
                Err(validation_err) => Err(validation_err),
            };

            match validation_result {
                Ok(Some(stage_verify_pass)) => {
                    verify_pass = stage_verify_pass;
                    break;
                }
                Ok(None) => break,
                Err(validation_err) => {
                    let validation_err_text = validation_err.to_stage_error();
                    let validation_attempt_no = reminder_attempts + 1;
                    if let Err(log_err) = Self::append_stage_validation_attempt(
                        &cycle_dir,
                        stage,
                        validation_attempt_no,
                        &run_ctx.session_id,
                        &validation_err,
                    ) {
                        warn!(
                            "append validation attempt failed: key={}, stage={}, attempt={}, error={}",
                            key, stage, validation_attempt_no, log_err
                        );
                    }

                    if !Self::should_retry_validation_with_reminder(stage, &validation_err_text) {
                        let tool_call_count = self.stage_tool_call_count(key, stage).await;
                        self.finalize_session_execution(
                            key,
                            stage,
                            &run_ctx.session_id,
                            "failed",
                            tool_call_count,
                        )
                        .await;
                        touch_session_index_updated_at_for_evolution(
                            ctx,
                            project,
                            workspace,
                            &run_ctx.ai_tool,
                            &run_ctx.session_id,
                        )
                        .await;
                        return Err(validation_err_text);
                    }

                    if reminder_attempts >= VALIDATION_REMINDER_MAX_RETRIES {
                        self.finalize_stage_failed(
                            key,
                            stage,
                            project,
                            workspace,
                            Some(run_ctx.ai_tool.as_str()),
                            Some(&run_ctx.session_id),
                            &validation_err_text,
                            ctx,
                        )
                        .await;
                        return Err(validation_err_text);
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
                            validation_err_text, reminder_err
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
                                project,
                                workspace,
                                Some(run_ctx.ai_tool.as_str()),
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
            touch_session_index_updated_at_for_evolution(
                ctx,
                project,
                workspace,
                &run_ctx.ai_tool,
                &run_ctx.session_id,
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

        let tool_call_count = self.stage_tool_call_count(key, stage).await;
        self.finalize_session_execution(key, stage, &run_ctx.session_id, "done", tool_call_count)
            .await;
        touch_session_index_updated_at_for_evolution(
            ctx,
            project,
            workspace,
            &run_ctx.ai_tool,
            &run_ctx.session_id,
        )
        .await;
        self.set_stage_status(key, stage, "done").await;
        self.persist_stage_file(
            key,
            stage,
            "done",
            None,
            if stage == "verify" {
                Some(verify_pass)
            } else {
                None
            },
        )
        .await
        .ok();
        if let Err(err) = self.persist_cycle_file(key).await {
            warn!(
                "evolution run_stage done persist_cycle_file failed: key={}, cycle_id={}, stage={}, session_id={}, error={}",
                key, cycle_id, stage, run_ctx.session_id, err
            );
        }
        self.broadcast_cycle_update(key, ctx, "agent").await;
        info!(
            "evolution run_stage done: key={}, cycle_id={}, stage={}, session_id={}, verify_pass={}, tool_calls={}",
            key, cycle_id, stage, run_ctx.session_id, verify_pass, tool_call_count
        );

        Ok(verify_pass)
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
        let created_at_ms = Utc::now().timestamp_millis();
        if let Err(err) = record_session_index_created(
            &ctx.ai_state,
            project,
            workspace,
            &profile.ai_tool,
            &directory,
            &session.id,
            &session.title,
            created_at_ms,
            AiSessionOrigin::EvolutionSystem,
        )
        .await
        {
            warn!(
                "evolution auto_commit persist session index failed: project={}, workspace={}, ai_tool={}, session_id={}, error={}",
                project, workspace, profile.ai_tool, session.id, err
            );
            if let Err(delete_err) = agent.delete_session(&directory, &session.id).await {
                warn!(
                    "evolution auto_commit rollback delete failed: project={}, workspace={}, ai_tool={}, session_id={}, error={}",
                    project, workspace, profile.ai_tool, session.id, delete_err
                );
            }
            return Err(format!("failed to persist ai session index: {}", err));
        }

        let model = profile.model.as_ref().map(|m| AiModelSelection {
            provider_id: m.provider_id.clone(),
            model_id: m.model_id.clone(),
        });
        let mode = profile.mode.clone();
        let config_overrides = sanitize_ai_config_options(&profile.config_options);

        let mut stream = match agent
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
            .await
        {
            Ok(stream) => stream,
            Err(err) => {
                touch_session_index_updated_at_for_evolution(
                    ctx,
                    project,
                    workspace,
                    &profile.ai_tool,
                    &session.id,
                )
                .await;
                return Err(err);
            }
        };

        loop {
            let next = timeout(
                Duration::from_secs(STAGE_STREAM_IDLE_TIMEOUT_SECS),
                stream.next(),
            )
            .await;
            match next {
                Ok(Some(Ok(crate::ai::AiEvent::Done { .. }))) => break,
                Ok(Some(Ok(crate::ai::AiEvent::Error { message }))) => {
                    touch_session_index_updated_at_for_evolution(
                        ctx,
                        project,
                        workspace,
                        &profile.ai_tool,
                        &session.id,
                    )
                    .await;
                    return Err(format!("auto_commit 会话失败: {}", message));
                }
                Ok(Some(Ok(crate::ai::AiEvent::QuestionAsked { .. }))) => {
                    touch_session_index_updated_at_for_evolution(
                        ctx,
                        project,
                        workspace,
                        &profile.ai_tool,
                        &session.id,
                    )
                    .await;
                    return Err("auto_commit 不支持人工提问".to_string());
                }
                Ok(Some(Ok(_))) => {}
                Ok(Some(Err(err))) => {
                    touch_session_index_updated_at_for_evolution(
                        ctx,
                        project,
                        workspace,
                        &profile.ai_tool,
                        &session.id,
                    )
                    .await;
                    return Err(err);
                }
                Ok(None) => break,
                Err(_) => {
                    touch_session_index_updated_at_for_evolution(
                        ctx,
                        project,
                        workspace,
                        &profile.ai_tool,
                        &session.id,
                    )
                    .await;
                    return Err("auto_commit 会话超时".to_string());
                }
            }
        }
        touch_session_index_updated_at_for_evolution(
            ctx,
            project,
            workspace,
            &profile.ai_tool,
            &session.id,
        )
        .await;

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
        verify_pass: bool,
        ctx: &HandlerContext,
    ) -> bool {
        // 阶段成功后重置该阶段的重试计数，防止旧计数影响下一轮
        {
            let mut state = self.state.lock().await;
            if let Some(entry) = state.workspaces.get_mut(key) {
                entry.stage_retry_counts.remove(stage);
            }
        }
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
                "evolution after_stage_success enter: key={}, stage={}, verify_pass={}, status={}, current_stage={}, cycle_id={}, verify_iteration={}, global_loop_round={}",
                key,
                stage,
                verify_pass,
                status,
                current_stage,
                cycle_id,
                verify_iteration,
                global_loop_round
            );
        } else {
            warn!(
                "evolution after_stage_success enter: workspace state missing: key={}, stage={}, verify_pass={}",
                key, stage, verify_pass
            );
        }
        if stage == "verify" {
            let Some(cycle_id) = cycle_for_validation.clone() else {
                warn!(
                    "evolution after_stage_success verify adjudication validation skipped: missing cycle_id: key={}, stage={}",
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
        let mut stage_changed: Option<(String, String, String, String, String)> = None;
        let mut post_stage_changed: Option<(String, String, String, String, String)> = None;
        let mut auto_next_cycle = false;
        let mut auto_loop_gate: Option<(String, String, String, String)> = None;
        let mut should_start_next_round_after_auto_commit = false;
        let mut managed_backlog_generation_error: Option<String> = None;

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
                "plan" => match cycle_dir_path(&entry.workspace_root, &entry.cycle_id) {
                    Ok(cycle_dir) => {
                        match Self::resolve_initial_implementation_stage_instances(&cycle_dir) {
                            Ok(instances) => {
                                for instance in &instances {
                                    Self::ensure_runtime_stage_state_pending(
                                        &mut entry.stage_statuses,
                                        &mut entry.stage_tool_call_counts,
                                        &instance.stage,
                                    );
                                }
                                next_stage = instances
                                    .first()
                                    .map(|instance| instance.stage.clone())
                                    .unwrap_or_else(|| "verify".to_string());
                            }
                            Err(err) => {
                                entry.status = "failed_system".to_string();
                                entry.terminal_reason_code =
                                    Some("evo_initial_stage_resolution_failed".to_string());
                                entry.terminal_error_message = Some(err);
                                next_stage = previous.clone();
                            }
                        }
                    }
                    Err(err) => {
                        entry.status = "failed_system".to_string();
                        entry.terminal_reason_code =
                            Some("evo_initial_stage_resolution_failed".to_string());
                        entry.terminal_error_message = Some(err);
                        next_stage = previous.clone();
                    }
                },
                _ if is_runtime_implement_stage(stage) => {
                    match cycle_dir_path(&entry.workspace_root, &entry.cycle_id) {
                        Ok(cycle_dir) => {
                            next_stage = Self::next_initial_implementation_stage(&cycle_dir, stage)
                                .ok()
                                .flatten()
                                .unwrap_or_else(|| "verify".to_string());
                        }
                        Err(err) => {
                            entry.status = "failed_system".to_string();
                            entry.terminal_reason_code =
                                Some("evo_initial_stage_resolution_failed".to_string());
                            entry.terminal_error_message = Some(err);
                            next_stage = previous.clone();
                        }
                    }
                }
                _ if is_runtime_reimplement_stage(stage) => next_stage = "verify".to_string(),
                "verify" => {
                    if verify_pass {
                        entry.terminal_reason_code = None;
                        entry.terminal_error_message = None;
                        next_stage = "auto_commit".to_string();
                    } else if entry.verify_iteration + 1 < entry.verify_iteration_limit {
                        entry.terminal_reason_code = None;
                        entry.terminal_error_message = None;
                        entry.verify_iteration += 1;
                        Self::ensure_runtime_stage_state_pending(
                            &mut entry.stage_statuses,
                            &mut entry.stage_tool_call_counts,
                            "verify",
                        );
                        entry
                            .stage_statuses
                            .insert("verify".to_string(), "pending".to_string());
                        entry.stage_tool_call_counts.insert("verify".to_string(), 0);
                        entry.stage_started_ats.remove("verify");
                        entry.stage_duration_ms.remove("verify");
                        if entry.backlog_contract_version >= 2 {
                            match cycle_dir_path(&entry.workspace_root, &entry.cycle_id) {
                                Ok(cycle_dir) => {
                                    if let Err(err) = Self::generate_managed_backlog_from_verify(
                                        &cycle_dir,
                                        entry.verify_iteration,
                                    ) {
                                        managed_backlog_generation_error = Some(format!(
                                            "managed backlog generation failed (project={}, workspace={}, cycle_id={}, verify_iteration={}): {}",
                                            entry.project,
                                            entry.workspace,
                                            entry.cycle_id,
                                            entry.verify_iteration,
                                            err
                                        ));
                                        entry.status = "failed_system".to_string();
                                        entry.terminal_reason_code =
                                            Some("evo_backlog_generation_failed".to_string());
                                        entry.terminal_error_message =
                                            managed_backlog_generation_error.clone();
                                        next_stage = previous.clone();
                                    }
                                }
                                Err(err) => {
                                    managed_backlog_generation_error = Some(format!(
                                        "managed backlog generation skipped: resolve cycle dir failed (project={}, workspace={}, cycle_id={}): {}",
                                        entry.project, entry.workspace, entry.cycle_id, err
                                    ));
                                    entry.status = "failed_system".to_string();
                                    entry.terminal_reason_code =
                                        Some("evo_backlog_generation_failed".to_string());
                                    entry.terminal_error_message =
                                        managed_backlog_generation_error.clone();
                                    next_stage = previous.clone();
                                }
                            }
                        }
                        if managed_backlog_generation_error.is_none() {
                            let reimplement_stage = reimplement_stage_name(entry.verify_iteration);
                            Self::ensure_runtime_stage_state_pending(
                                &mut entry.stage_statuses,
                                &mut entry.stage_tool_call_counts,
                                &reimplement_stage,
                            );
                            entry
                                .stage_statuses
                                .insert(reimplement_stage.clone(), "pending".to_string());
                            entry
                                .stage_tool_call_counts
                                .insert(reimplement_stage.clone(), 0);
                            entry.stage_started_ats.remove(&reimplement_stage);
                            entry.stage_duration_ms.remove(&reimplement_stage);
                            next_stage = reimplement_stage;
                        }
                    } else {
                        entry.status = "failed_exhausted".to_string();
                        entry.terminal_reason_code =
                            Some("evo_verify_iteration_exhausted".to_string());
                        entry.terminal_error_message = None;
                        next_stage = previous.clone();
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

            let should_advance = !matches!(stage, "auto_commit") && next_stage != previous;
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
        if let Some(err) = managed_backlog_generation_error {
            self.mark_failed_with_code(key, "evo_backlog_generation_failed", &err, ctx)
                .await;
            return false;
        }
        if !matches!(stage, "auto_commit") && stage_changed.is_none() {
            warn!(
                "evolution after_stage_success no stage_changed emitted: key={}, stage={}, verify_pass={}",
                key, stage, verify_pass
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
            entry.terminal_reason_code = None;
            entry.terminal_error_message = None;
            entry.rate_limit_resume_at = None;
            entry.rate_limit_error_message = None;
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
                "evolution after_stage_success exit: key={}, stage={}, verify_pass={}, auto_next_cycle={}, status={}, current_stage={}, cycle_id={}, verify_iteration={}, global_loop_round={}",
                key,
                stage,
                verify_pass,
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
            // WI-004: 结构化错误日志落盘，包含 cycle_id、error_code、message
            log_evolution_error(&cycle_id, "system", code, &normalized_err);
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
        auto_commit_stage_template, check_workspace_boundary, direction_stage_template,
        ensure_schema_version, ensure_stage_field_matches, implement_stage_template,
        log_evolution_error, managed_backlog_template, parse_adjudication_result_from_json,
        plan_markdown_template, plan_stage_template, should_force_advanced_reimplementation,
        should_start_next_round, verify_stage_template, ArtifactValidationError, EvolutionManager,
        ImplementLane, StageValidationContext, PLAN_MARKDOWN_FILE,
    };
    use chrono::Utc;
    use std::path::Path;
    use std::process::Command;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::Arc;
    use tempfile::tempdir;
    use tokio::time::Duration;

    fn write_json(path: &std::path::Path, value: serde_json::Value) {
        super::write_json(path, &value).expect("write json failed");
    }

    fn base_plan_json(work_items: Vec<serde_json::Value>) -> serde_json::Value {
        serde_json::json!({
            "$schema_version": "2.0",
            "stage": "plan",
            "cycle_id": "c-1",
            "goal": "demo",
            "scope": {"in": ["core"], "out": []},
            "acceptance_criteria": [
                {"criteria_id": "ac-1", "description": "验收标准 1"},
                {"criteria_id": "ac-2", "description": "验收标准 2"}
            ],
            "work_items": work_items,
            "verification_plan": {
                "checks": [
                    {"id": "v-1"},
                    {"id": "v-2"}
                ],
                "acceptance_mapping": [
                    {"criteria_id": "ac-1", "description": "验收标准 1", "check_ids": ["v-1"]},
                    {"criteria_id": "ac-2", "description": "验收标准 2", "check_ids": ["v-2"]}
                ]
            },
            "updated_at": "2026-03-02T00:00:00Z"
        })
    }

    fn write_plan_markdown(dir: &Path) {
        super::write_text(
            &dir.join(PLAN_MARKDOWN_FILE),
            &plan_markdown_template("c-1"),
        )
        .expect("write plan markdown failed");
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
            "$schema_version": "2.0",
            "cycle_id": "c-1",
            "verify_iteration": 1,
            "status": "done",
            "summary": "ok",
            "work_item_results": [],
            "changed_files": [],
            "commands_executed": [],
            "quick_checks": [],
            "backlog_resolution_updates": [],
            "failure_backlog": backlog,
            "backlog_coverage": coverage,
            "backlog_coverage_summary": {
                "total": total,
                "done": done,
                "blocked": blocked,
                "not_done": not_done
            },
            "updated_at": "2026-03-02T00:00:00Z"
        })
    }

    fn base_implement_result_with_updates(updates: Vec<serde_json::Value>) -> serde_json::Value {
        let mut value = base_implement_result_json(Vec::new(), Vec::new());
        let obj = value
            .as_object_mut()
            .expect("implement result must be object");
        obj.insert(
            "stage".to_string(),
            serde_json::Value::String("implement_general".to_string()),
        );
        obj.insert(
            "backlog_resolution_updates".to_string(),
            serde_json::Value::Array(updates),
        );
        value
    }

    fn write_empty_implement_result_triplet(dir: &Path) {
        for (file, stage) in [
            ("implement_general.jsonc", "implement_general"),
            ("implement_visual.jsonc", "implement_visual"),
            ("implement_advanced.jsonc", "implement_advanced"),
        ] {
            let mut value = base_implement_result_json(Vec::new(), Vec::new());
            value
                .as_object_mut()
                .expect("implement result must be object")
                .insert(
                    "stage".to_string(),
                    serde_json::Value::String(stage.to_string()),
                );
            write_json(&dir.join(file), value);
        }
    }

    fn write_managed_backlog_files(
        dir: &Path,
        cycle_id: &str,
        verify_iteration: u32,
        backlog: Vec<serde_json::Value>,
        coverage: Vec<serde_json::Value>,
    ) {
        let coverage_by_id: std::collections::HashMap<String, &serde_json::Value> = coverage
            .iter()
            .filter_map(|item| {
                let key = item
                    .get("id")
                    .or_else(|| item.get("item_id"))
                    .and_then(|value| value.as_str())
                    .map(|value| value.trim().to_string())
                    .filter(|value| !value.is_empty())?;
                Some((key, item))
            })
            .collect();
        let items = backlog
            .into_iter()
            .map(|item| {
                let mut obj = item.as_object().cloned().unwrap_or_default();
                let item_id = obj
                    .get("id")
                    .and_then(|value| value.as_str())
                    .map(|value| value.trim().to_string())
                    .filter(|value| !value.is_empty())
                    .unwrap_or_else(|| format!("backlog-{}", obj.len()));
                let coverage_item = coverage_by_id.get(&item_id);
                obj.insert("id".to_string(), serde_json::json!(item_id));
                obj.entry("status".to_string()).or_insert_with(|| {
                    serde_json::json!(coverage_item
                        .and_then(|value| value.get("status"))
                        .and_then(|value| value.as_str())
                        .unwrap_or("not_done"))
                });
                obj.entry("evidence".to_string())
                    .or_insert_with(|| serde_json::json!({}));
                obj.entry("notes".to_string())
                    .or_insert_with(|| serde_json::json!(""));
                obj.entry("requirement_ref".to_string())
                    .or_insert_with(|| serde_json::json!(""));
                obj.entry("description".to_string())
                    .or_insert_with(|| serde_json::json!(""));
                obj.entry("created_at".to_string())
                    .or_insert_with(|| serde_json::json!("2026-03-02T00:00:00Z"));
                obj.entry("updated_at".to_string())
                    .or_insert_with(|| serde_json::json!("2026-03-02T00:00:00Z"));
                serde_json::Value::Object(obj)
            })
            .collect::<Vec<serde_json::Value>>();
        let total = items.len() as u64;
        let done = items
            .iter()
            .filter(|item| item.get("status").and_then(|v| v.as_str()) == Some("done"))
            .count() as u64;
        let blocked = items
            .iter()
            .filter(|item| item.get("status").and_then(|v| v.as_str()) == Some("blocked"))
            .count() as u64;
        let not_done = total.saturating_sub(done).saturating_sub(blocked);
        write_json(
            &dir.join("managed.backlog.jsonc"),
            serde_json::json!({
                "$schema_version": "2.0",
                "cycle_id": cycle_id,
                "verify_iteration": verify_iteration,
                "items": items,
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

    fn write_valid_direction_artifacts(dir: &Path) {
        write_json(
            &dir.join("direction.jsonc"),
            serde_json::json!({
                "$schema_version": "2.0",
                "stage": "direction",
                "cycle_id": "c-1",
                "status": "done",
                "direction_statement": "优先提升自主进化计划链路的稳定性与可验证性。",
                "updated_at": "2026-03-02T00:00:00Z"
            }),
        );
        write_json(
            &dir.join("cycle.jsonc"),
            serde_json::json!({
                "$schema_version": "2.0",
                "cycle_id": "c-1",
                "title": "优先提升自主进化计划链路的稳定性与可验证性。",
                "status": "running",
                "stage_runtime": {},
                "executions": []
            }),
        );
    }

    #[test]
    fn parse_adjudication_result_json_schema() {
        let value = serde_json::json!({
            "overall_result": {
                "result": "fail"
            }
        });
        assert_eq!(parse_adjudication_result_from_json(&value), Some(false));
    }

    #[test]
    fn parse_stage_verify_json_schema() {
        let value = serde_json::json!({
            "decision": {
                "result": "pass"
            }
        });
        assert_eq!(parse_adjudication_result_from_json(&value), Some(true));
    }

    #[test]
    fn resolve_stage_outcome_from_validated_artifacts_should_ignore_non_verify_stage() {
        let dir = tempdir().expect("tempdir should succeed");
        let outcome =
            EvolutionManager::resolve_stage_outcome_from_validated_artifacts("plan", dir.path())
                .expect("non-verify stage should not require extra outcome parsing");
        assert_eq!(outcome, None);
    }

    #[test]
    fn resolve_stage_outcome_from_validated_artifacts_should_parse_verify_pass_result() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "$schema_version": "2.0",
                "stage": "verify",
                "cycle_id": "c-1",
                "adjudication": {
                    "overall_result": {
                        "result": "pass"
                    }
                }
            }),
        );
        let outcome =
            EvolutionManager::resolve_stage_outcome_from_validated_artifacts("verify", dir.path())
                .expect("verify outcome should be readable after validation");
        assert_eq!(outcome, Some(true));
    }

    #[test]
    fn validate_stage_artifacts_should_reject_verify_invalid_jsonc_with_parse_error() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.jsonc"),
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
                "implementation_stage_kind": "implement_general",
                "linked_check_ids": ["v-1", "v-2"]
            })]),
        );
        write_empty_implement_result_triplet(dir.path());
        super::write_jsonc_text(
            &dir.path().join("verify.jsonc"),
            r#"{
  "$schema_version": "2.0",
  "stage": "verify",
  "cycle_id": "c-1",
  "verify_iteration": 0,
  "verify_iteration_limit": 2,
  "summary": "bad",
  "acceptance_evaluation": [],
  "verification_overall": {"result": "pass"},
  "carryover_verification": {
    "items": [],
    "summary": {"total": 0, "covered": 0, "missing": 0, "blocked": 0}
  },
  "adjudication": {
    "criteria_judgement": [],
    "overall_result": {
      "result": "pass",
      "reason": "本轮目标"建立核心质量基线"已达成"
    },
    "full_next_iteration_requirements": []
  },
  "updated_at": "2026-03-02T00:00:00Z"
}"#,
        )
        .expect("invalid verify jsonc should be written as raw text");

        let err = EvolutionManager::validate_stage_artifacts("verify", dir.path(), 0, 2)
            .expect_err("invalid verify jsonc should fail validation");
        assert!(err.contains("解析"));
        assert!(err.contains("verify.jsonc"));
        let stage_err = ArtifactValidationError::new("artifact_contract_violation", err.clone())
            .to_stage_error();
        assert!(EvolutionManager::should_retry_validation_with_reminder(
            "verify", &stage_err
        ));
    }

    fn expected_validation_reminder(
        stage: &str,
        error_code: &str,
        summary: &str,
        issues: &[&str],
        fix_hints: &[&str],
        target_files: &str,
        raw_error: &str,
    ) -> String {
        let issue_lines = issues
            .iter()
            .enumerate()
            .map(|(idx, issue)| format!("{}. {}", idx + 1, issue))
            .collect::<Vec<_>>()
            .join("\n");
        let fix_hint_lines = if fix_hints.is_empty() {
            String::new()
        } else {
            format!(
                "\n修复提示：\n{}",
                fix_hints
                    .iter()
                    .enumerate()
                    .map(|(idx, hint)| format!("{}. {}", idx + 1, hint))
                    .collect::<Vec<_>>()
                    .join("\n")
            )
        };
        format!(
            "<system-reminder>【VALIDATION_BLOCKER｜阶段:{}】\n错误码：{}\n摘要：{}\n问题清单：\n{}{}\n立即修复动作：\n1. 打开并修改目标产物：{}\n2. 按“问题清单”逐项修正字段名/类型/必填项，务必一次性改完再重试。\n3. 重新输出本阶段产物并自检；不要只解释，不要停留在分析。\n原始报错：{}</system-reminder>",
            stage, error_code, summary, issue_lines, fix_hint_lines, target_files, raw_error
        )
    }

    #[test]
    fn should_retry_validation_with_reminder_should_match_supported_stage_and_error() {
        assert!(EvolutionManager::should_retry_validation_with_reminder(
            "direction",
            "evo_stage_output_invalid: x"
        ));
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
            "plan",
            "evo_stage_output_invalid: x"
        ));
        assert!(EvolutionManager::should_retry_validation_with_reminder(
            "implement_general",
            "evo_stage_output_invalid: x"
        ));
        assert!(EvolutionManager::should_retry_validation_with_reminder(
            "auto_commit",
            "evo_stage_output_invalid: x"
        ));
        assert!(EvolutionManager::should_retry_validation_with_reminder(
            "implement_advanced",
            "evo_backlog_mapping_missing: selector=(ac-1, chk-1, wi-1, implement_advanced), candidates=0"
        ));
        assert!(EvolutionManager::should_retry_validation_with_reminder(
            "implement_general",
            "artifact_contract_violation: implement_general.jsonc 缺少 quick_checks"
        ));
        assert!(!EvolutionManager::should_retry_validation_with_reminder(
            "custom_stage",
            "stage stream timeout"
        ));
    }

    #[test]
    fn parse_validation_error_code_and_message_should_parse_standard_stage_error() {
        let (code, message) = EvolutionManager::parse_validation_error_code_and_message(
            "evo_stage_output_invalid:artifact_contract_violation: verify.jsonc 缺少 adjudication.overall_result",
        );
        assert_eq!(code, "artifact_contract_violation");
        assert_eq!(message, "verify.jsonc 缺少 adjudication.overall_result");
    }

    #[test]
    fn parse_validation_error_code_and_message_should_keep_code_when_message_missing() {
        let (code, message) = EvolutionManager::parse_validation_error_code_and_message(
            "evo_stage_output_invalid:artifact_contract_violation:",
        );
        assert_eq!(code, "artifact_contract_violation");
        assert_eq!(message, "未提供详细错误信息（artifact_contract_violation）");
    }

    #[test]
    fn parse_validation_error_code_and_message_should_fallback_when_prefix_missing() {
        let (code, message) = EvolutionManager::parse_validation_error_code_and_message(
            "verify.jsonc 缺少 adjudication.overall_result",
        );
        assert_eq!(code, "artifact_contract_violation");
        assert_eq!(message, "verify.jsonc 缺少 adjudication.overall_result");
    }

    #[test]
    fn parse_validation_error_code_and_message_should_preserve_multi_colon_message() {
        let (code, message) = EvolutionManager::parse_validation_error_code_and_message(
            "evo_stage_output_invalid:artifact_contract_violation: expected:foo, actual:bar",
        );
        assert_eq!(code, "artifact_contract_violation");
        assert_eq!(message, "expected:foo, actual:bar");
    }

    #[test]
    fn validation_target_files_for_stage_should_match_all_supported_and_unknown() {
        assert_eq!(
            EvolutionManager::validation_target_files_for_stage("direction"),
            "direction.jsonc / cycle.jsonc"
        );
        assert_eq!(
            EvolutionManager::validation_target_files_for_stage("plan"),
            "plan.jsonc / plan.md / direction.jsonc"
        );
        assert_eq!(
            EvolutionManager::validation_target_files_for_stage("implement_general"),
            "implement_general.jsonc / plan.jsonc / plan.md / managed.backlog.jsonc"
        );
        assert_eq!(
            EvolutionManager::validation_target_files_for_stage("implement_visual"),
            "implement_visual.jsonc / plan.jsonc / plan.md / managed.backlog.jsonc"
        );
        assert_eq!(
            EvolutionManager::validation_target_files_for_stage("implement_advanced"),
            "implement_advanced.jsonc / plan.jsonc / plan.md / managed.backlog.jsonc"
        );
        assert_eq!(
            EvolutionManager::validation_target_files_for_stage("verify"),
            "verify.jsonc / plan.jsonc / plan.md / managed.backlog.jsonc"
        );
        assert_eq!(
            EvolutionManager::validation_target_files_for_stage("auto_commit"),
            "auto_commit.jsonc / git 工作区状态"
        );
        assert_eq!(
            EvolutionManager::validation_target_files_for_stage("custom_stage"),
            "custom_stage.jsonc / 对应阶段产物"
        );
    }

    #[test]
    fn build_validation_reminder_message_should_match_snapshot_for_missing_field() {
        let err = ArtifactValidationError::new(
            "artifact_contract_violation",
            "读取 plan.md 失败: 读取 /tmp/cycle/plan.md 失败: No such file or directory (os error 2)",
        );
        let raw_error = err.to_stage_error();
        let msg = EvolutionManager::build_validation_reminder_message("plan", &err);
        let expected = expected_validation_reminder(
            "plan",
            "artifact_contract_violation",
            "读取 plan.md 失败: 读取 /tmp/cycle/plan.md 失败: No such file or directory (os error 2)",
            &["读取 plan.md 失败: 读取 /tmp/cycle/plan.md 失败: No such file or directory (os error 2)"],
            &["补齐 plan.md 文件即可；当前系统只要求该文件存在，不校验其具体格式。"],
            "plan.jsonc / plan.md / direction.jsonc",
            &raw_error,
        );
        assert_eq!(msg, expected);
    }

    #[test]
    fn build_validation_reminder_message_should_match_snapshot_for_non_empty_constraint() {
        let err = ArtifactValidationError::new(
            "artifact_contract_violation",
            "direction.jsonc.direction_statement 不能为空",
        );
        let raw_error = err.to_stage_error();
        let msg = EvolutionManager::build_validation_reminder_message("direction", &err);
        let expected = expected_validation_reminder(
            "direction",
            "artifact_contract_violation",
            "direction.jsonc.direction_statement 不能为空",
            &["direction.jsonc.direction_statement 不能为空"],
            &["将必填字段填为非空值（字符串非空、数组至少 1 项、对象含必需键）。"],
            "direction.jsonc / cycle.jsonc",
            &raw_error,
        );
        assert_eq!(msg, expected);
    }

    #[test]
    fn build_validation_reminder_message_should_match_snapshot_for_direction_missing_field_constraint(
    ) {
        let err = ArtifactValidationError::new(
            "artifact_contract_violation",
            "direction.jsonc 缺少 direction_statement",
        );
        let raw_error = err.to_stage_error();
        let msg = EvolutionManager::build_validation_reminder_message("direction", &err);
        let expected = expected_validation_reminder(
            "direction",
            "artifact_contract_violation",
            "direction.jsonc 缺少 direction_statement",
            &["direction.jsonc 缺少 direction_statement"],
            &["补齐缺失字段，保持字段名与层级路径和阶段产物契约一致。"],
            "direction.jsonc / cycle.jsonc",
            &raw_error,
        );
        assert_eq!(msg, expected);
    }

    #[test]
    fn build_validation_reminder_message_should_match_snapshot_for_number_type_constraint() {
        let err = ArtifactValidationError::new(
            "artifact_contract_violation",
            "verify.jsonc.carryover_verification.summary.total 必须是数字",
        );
        let raw_error = err.to_stage_error();
        let msg = EvolutionManager::build_validation_reminder_message("verify", &err);
        let expected = expected_validation_reminder(
            "verify",
            "artifact_contract_violation",
            "verify.jsonc.carryover_verification.summary.total 必须是数字",
            &["verify.jsonc.carryover_verification.summary.total 必须是数字"],
            &["将该字段改为数字类型（JSON number），不要使用字符串或对象。"],
            "verify.jsonc / plan.jsonc / plan.md / managed.backlog.jsonc",
            &raw_error,
        );
        assert_eq!(msg, expected);
    }

    #[test]
    fn build_validation_reminder_message_should_explain_verify_carryover_missing_id_mapping() {
        let err = ArtifactValidationError::new(
            "artifact_contract_violation",
            "carryover_verification.items[0] 缺少有效 id",
        );
        let raw_error = err.to_stage_error();
        let msg = EvolutionManager::build_validation_reminder_message("verify", &err);
        let expected = expected_validation_reminder(
            "verify",
            "artifact_contract_violation",
            "carryover_verification.items[0] 缺少有效 id",
            &["carryover_verification.items[0] 缺少有效 id"],
            &["carryover_verification.items[*] 必须填写 id 或 item_id，且该值必须直接复用 managed.backlog.jsonc.items[*].id；不要生成新的流水号，也不要只补 backlog / failure_backlog_id 这类旁路字段。"],
            "verify.jsonc / plan.jsonc / plan.md / managed.backlog.jsonc",
            &raw_error,
        );
        assert_eq!(msg, expected);
    }

    #[test]
    fn build_validation_reminder_message_should_explain_verify_carryover_missing_backlog_item_mapping(
    ) {
        let err = ArtifactValidationError::new(
            "artifact_contract_violation",
            "carryover_verification.items 缺少 backlog 项: [\"019ccc60-4fdf-7201-adc0-3dd6b8c666d1\"]",
        );
        let raw_error = err.to_stage_error();
        let msg = EvolutionManager::build_validation_reminder_message("verify", &err);
        let expected = expected_validation_reminder(
            "verify",
            "artifact_contract_violation",
            "carryover_verification.items 缺少 backlog 项: [\"019ccc60-4fdf-7201-adc0-3dd6b8c666d1\"]",
            &["carryover_verification.items 缺少 backlog 项: [\"019ccc60-4fdf-7201-adc0-3dd6b8c666d1\"]"],
            &["carryover_verification.items[*].id 或 item_id 必须与 managed.backlog.jsonc.items[*].id 一一对应；不要自造 CARRYOVER-001 这类占位 ID，也不要只写 backlog 字段。请把报错里缺失的 backlog 真实 id 直接填回对应条目。"],
            "verify.jsonc / plan.jsonc / plan.md / managed.backlog.jsonc",
            &raw_error,
        );
        assert_eq!(msg, expected);
    }

    #[test]
    fn build_validation_reminder_message_should_match_snapshot_for_implement_quick_checks_array() {
        let err = ArtifactValidationError::new(
            "artifact_contract_violation",
            "implement_advanced.jsonc.quick_checks 必须是数组",
        );
        let raw_error = err.to_stage_error();
        let msg = EvolutionManager::build_validation_reminder_message("implement_advanced", &err);
        let expected = expected_validation_reminder(
            "implement_advanced",
            "artifact_contract_violation",
            "implement_advanced.jsonc.quick_checks 必须是数组",
            &["implement_advanced.jsonc.quick_checks 必须是数组"],
            &["quick_checks 必须是数组（[]），即使没有检查项也必须输出 []；不要写成对象。"],
            "implement_advanced.jsonc / plan.jsonc / plan.md / managed.backlog.jsonc",
            &raw_error,
        );
        assert_eq!(msg, expected);
    }

    #[test]
    fn build_validation_reminder_message_should_match_snapshot_for_implement_backlog_mapping_missing(
    ) {
        let err = ArtifactValidationError::new(
            "artifact_contract_violation",
            "evo_backlog_mapping_missing: selector=(ac-1, chk-1, wi-1, implement_advanced), candidates=0",
        );
        let raw_error = err.to_stage_error();
        let msg = EvolutionManager::build_validation_reminder_message("implement_advanced", &err);
        let expected = expected_validation_reminder(
            "implement_advanced",
            "artifact_contract_violation",
            "evo_backlog_mapping_missing: selector=(ac-1, chk-1, wi-1, implement_advanced), candidates=0",
            &["evo_backlog_mapping_missing: selector=(ac-1, chk-1, wi-1, implement_advanced), candidates=0"],
            &["无法将 backlog_resolution_updates 的 selector 映射到 managed.backlog.jsonc。请复制该文件中 implementation_stage_kind=implement_advanced 的原始 selector 组合后再回填。"],
            "implement_advanced.jsonc / plan.jsonc / plan.md / managed.backlog.jsonc",
            &raw_error,
        );
        assert_eq!(msg, expected);
    }

    #[test]
    fn build_validation_reminder_message_should_match_snapshot_for_plan_markdown_missing() {
        let err = ArtifactValidationError::new(
            "artifact_contract_violation",
            "读取 plan.md 失败: 读取 /tmp/cycle/plan.md 失败: No such file or directory (os error 2)",
        );
        let raw_error = err.to_stage_error();
        let msg = EvolutionManager::build_validation_reminder_message("plan", &err);
        let expected = expected_validation_reminder(
            "plan",
            "artifact_contract_violation",
            "读取 plan.md 失败: 读取 /tmp/cycle/plan.md 失败: No such file or directory (os error 2)",
            &["读取 plan.md 失败: 读取 /tmp/cycle/plan.md 失败: No such file or directory (os error 2)"],
            &["补齐 plan.md 文件即可；当前系统只要求该文件存在，不校验其具体格式。"],
            "plan.jsonc / plan.md / direction.jsonc",
            &raw_error,
        );
        assert_eq!(msg, expected);
    }

    #[test]
    fn build_validation_reminder_message_should_include_all_issues_and_deduped_fix_hints() {
        let err = ArtifactValidationError::with_issues(
            "artifact_contract_violation",
            "共 3 项问题；首项：direction.jsonc.direction_statement 不能为空",
            vec![
                "direction.jsonc.direction_statement 不能为空".to_string(),
                "direction.jsonc.updated_at 不能为空".to_string(),
                "direction.jsonc.direction_statement 不能为空".to_string(),
            ],
        );
        let msg = EvolutionManager::build_validation_reminder_message("direction", &err);
        assert!(
            msg.contains("摘要：共 3 项问题；首项：direction.jsonc.direction_statement 不能为空")
        );
        assert!(msg.contains("1. direction.jsonc.direction_statement 不能为空"));
        assert!(msg.contains("2. direction.jsonc.updated_at 不能为空"));
        assert!(msg.contains("3. direction.jsonc.direction_statement 不能为空"));
        assert_eq!(msg.matches("将必填字段填为非空值").count(), 1);
    }

    #[test]
    fn stage_templates_should_include_field_comments_and_example_objects() {
        let direction = direction_stage_template("c-42");
        assert!(
            direction.contains("// 本轮唯一方向句，必须是非空字符串；一句话即可说明本轮要进化什么")
        );
        assert!(direction.contains("\"direction_statement\": \"\""));
        assert!(!direction.contains("\"title\": \"\""));

        let plan = plan_stage_template("c-42");
        assert!(plan.contains("// 本轮验收标准，由 plan 阶段定义且必须可验证"));
        assert!(plan.contains("// 工作项列表，不能为空"));
        assert!(plan.contains("//   \"implementation_stage_kind\": \"general\""));
        assert!(plan.contains("//   \"check_ids\": [\"CHK-001\"]"));
        assert!(plan.contains("// 验收标准与检查项的映射，必须完整覆盖 plan.acceptance_criteria"));

        let plan_markdown = plan_markdown_template("c-42");
        assert!(plan_markdown.contains("# 本轮目标"));
        assert!(plan_markdown.contains("- 方向句："));
        assert!(plan_markdown.contains("## 工作项分配"));
        assert!(plan_markdown.contains("### WI-001 占位标题"));
        assert!(plan_markdown.contains("## 验证计划"));
        assert!(plan_markdown.contains("### CHK-001 占位检查"));

        let implement = implement_stage_template("implement.general.1", "c-42", 1, 2);
        assert!(implement.contains("// backlog v2 回填数组。VERIFY_ITERATION>0 且 BACKLOG_CONTRACT_VERSION>=2 时必须按此结构填写。"));
        assert!(implement.contains("//   \"implementation_stage_kind\": \"general\""));

        let verify = verify_stage_template("c-42", 1, 3);
        assert!(verify.contains("// criteria_id 集必须与 plan.acceptance_criteria 完全一致"));
        assert!(verify.contains("//   \"criteria_id\": \"AC-001\""));
        assert!(verify.contains("// 需要重实现时必须输出完整 selector 信息"));

        let auto_commit = auto_commit_stage_template("c-42");
        assert!(auto_commit
            .contains("// 若无可提交变更，需明确写出“无可提交变更”或 no changes to commit"));

        let managed_backlog = managed_backlog_template("c-42", 1);
        assert!(managed_backlog.contains("// 托管整改项列表；系统生成，不要手工伪造主键"));
        assert!(managed_backlog.contains("//   \"requirement_ref\": \"REQ-001\""));
    }

    #[test]
    fn ensure_stage_templates_should_create_plan_jsonc_and_plan_markdown() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("cycle.jsonc"),
            serde_json::json!({
                "cycle_id": "c-42"
            }),
        );

        EvolutionManager::ensure_stage_templates("plan", dir.path(), 1, 3, 2)
            .expect("plan templates should be created");

        let plan_json = dir.path().join("plan.jsonc");
        let plan_markdown = dir.path().join(PLAN_MARKDOWN_FILE);
        assert!(plan_json.exists(), "plan.jsonc should exist");
        assert!(plan_markdown.exists(), "plan.md should exist");

        let markdown = std::fs::read_to_string(&plan_markdown).expect("plan.md should be readable");
        assert!(markdown.contains("# 本轮目标"));
        assert!(markdown.contains("### WI-001 占位标题"));
    }

    #[test]
    fn validate_direction_artifact_should_aggregate_multiple_issues() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("direction.jsonc"),
            serde_json::json!({
                "$schema_version": "2.0",
                "stage": "direction",
                "cycle_id": "c-1",
                "status": "done",
                "direction_statement": "",
                "updated_at": ""
            }),
        );

        let err = EvolutionManager::validate_direction_artifact(dir.path(), None)
            .expect_err("invalid direction artifact should fail");
        assert_eq!(err.issues().len(), 2);
        assert_eq!(
            err.issues()[0],
            "direction.jsonc.direction_statement 不能为空"
        );
        assert!(err.contains("direction.jsonc.updated_at 不能为空"));
    }

    #[test]
    fn validate_direction_artifact_should_accept_single_sentence_direction() {
        let dir = tempdir().expect("tempdir should succeed");
        write_valid_direction_artifacts(dir.path());

        EvolutionManager::validate_stage_artifacts("direction", dir.path(), 0, 1)
            .expect("一句话方向应通过校验");
    }

    #[test]
    fn validate_direction_artifact_should_reject_blank_direction_statement() {
        let dir = tempdir().expect("tempdir should succeed");
        write_valid_direction_artifacts(dir.path());
        write_json(
            &dir.path().join("direction.jsonc"),
            serde_json::json!({
                "$schema_version": "2.0",
                "stage": "direction",
                "cycle_id": "c-1",
                "status": "done",
                "direction_statement": "   ",
                "updated_at": "2026-03-02T00:00:00Z"
            }),
        );

        let err = EvolutionManager::validate_direction_artifact(dir.path(), None)
            .expect_err("空白方向句应失败");
        assert!(err.contains("direction.jsonc.direction_statement 不能为空"));
    }

    #[test]
    fn validate_plan_artifact_should_require_plan_markdown_to_exist() {
        let dir = tempdir().expect("tempdir should succeed");
        write_valid_direction_artifacts(dir.path());
        write_json(
            &dir.path().join("plan.jsonc"),
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
                "implementation_stage_kind": "implement_general",
                "linked_check_ids": ["v-1", "v-2"]
            })]),
        );

        let err = EvolutionManager::validate_stage_artifacts("plan", dir.path(), 0, 1)
            .expect_err("missing plan.md should fail");
        assert!(err.contains("plan.md"));
    }

    #[test]
    fn validate_plan_artifact_should_accept_existing_plan_markdown() {
        let dir = tempdir().expect("tempdir should succeed");
        write_valid_direction_artifacts(dir.path());
        write_json(
            &dir.path().join("plan.jsonc"),
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
                "implementation_stage_kind": "implement_general",
                "linked_check_ids": ["v-1", "v-2"]
            })]),
        );
        write_plan_markdown(dir.path());

        EvolutionManager::validate_stage_artifacts("plan", dir.path(), 0, 1)
            .expect("existing plan.md should pass");
    }

    #[test]
    fn sync_managed_backlog_should_aggregate_multiple_mapping_issues_without_partial_write() {
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
                "implementation_stage_kind": "implement_general",
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
                "implementation_stage_kind": "implement_general",
                "status": "not_done",
                "evidence": null,
                "notes": "",
                "updated_at": "2026-03-02T00:00:00Z"
            })],
        );
        write_json(
            &dir.path().join("implement_general.jsonc"),
            base_implement_result_with_updates(vec![
                serde_json::json!({
                    "source_criteria_id": "ac-x",
                    "source_check_id": "v-x",
                    "work_item_id": "w-x",
                    "implementation_stage_kind": "implement_general",
                    "status": "done",
                    "evidence": {"proof": "x"},
                    "notes": "missing mapping"
                }),
                serde_json::json!({
                    "source_criteria_id": "ac-1",
                    "source_check_id": "v-1",
                    "work_item_id": "w-1",
                    "implementation_stage_kind": "implement_general",
                    "status": "finished",
                    "evidence": {"proof": "bad status"},
                    "notes": "invalid status"
                }),
            ]),
        );

        let err = EvolutionManager::sync_managed_backlog_for_implement_stage(
            dir.path(),
            "implement_general",
        )
        .expect_err("managed backlog sync should aggregate mapping issues");
        assert_eq!(err.issues().len(), 2);
        assert!(err.contains("evo_backlog_mapping_missing"));
        assert!(err.contains("status 必须是 done|blocked|not_done"));

        let managed_backlog = super::read_json_file(dir.path(), "managed.backlog.jsonc")
            .expect("managed backlog should be readable");
        assert_eq!(
            managed_backlog["items"][0]["status"],
            serde_json::json!("not_done")
        );
    }

    #[test]
    fn validation_reminder_max_retries_should_be_three() {
        assert_eq!(super::VALIDATION_REMINDER_MAX_RETRIES, 3);
    }

    #[test]
    fn should_attempt_idle_recovery_should_allow_within_limit() {
        assert!(super::should_attempt_idle_recovery(0));
        assert!(super::should_attempt_idle_recovery(1));
        assert!(!super::should_attempt_idle_recovery(2));
        assert!(!super::should_attempt_idle_recovery(3));
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
    fn next_stage_verify_should_goto_auto_commit() {
        assert_eq!(next_stage("verify"), Some("auto_commit"));
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
    fn completed_exceeded_round_should_not_start_next_round() {
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
    fn validate_stage_artifacts_should_reject_direction_missing_statement() {
        let dir = tempdir().expect("tempdir should succeed");
        write_valid_direction_artifacts(dir.path());

        let mut stage_direction = super::read_json_file(dir.path(), "direction.jsonc")
            .expect("direction.jsonc should be readable");
        stage_direction
            .as_object_mut()
            .expect("direction.jsonc should be object")
            .remove("direction_statement");
        write_json(&dir.path().join("direction.jsonc"), stage_direction);

        let err = EvolutionManager::validate_stage_artifacts("direction", dir.path(), 0, 1)
            .expect_err("missing direction_statement should fail");
        assert!(err.contains("direction_statement"));
    }

    #[test]
    fn validate_stage_artifacts_should_reject_first_round_missing_implement_result_file() {
        let dir = tempdir().expect("tempdir should succeed");
        let err = EvolutionManager::validate_stage_artifacts("implement_general", dir.path(), 0, 1)
            .expect_err("first round missing implement result should fail");
        assert!(err.contains("implement_general.jsonc"));
    }

    #[test]
    fn validate_stage_artifacts_should_reject_first_round_verify_missing_acceptance_evaluation() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.jsonc"),
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
                "implementation_stage_kind": "implement_general",
                "linked_check_ids": ["v-1", "v-2"]
            })]),
        );
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "$schema_version": "2.0",
                "stage": "verify",
                "cycle_id": "c-1",
                "verify_iteration": 0,
                "summary": "verify",
                "check_results": [],
                "verification_overall": {"result": "pass"},
                "updated_at": "2026-03-02T00:00:00Z"
            }),
        );

        let err = EvolutionManager::validate_stage_artifacts("verify", dir.path(), 0, 1)
            .expect_err("missing acceptance_evaluation should fail");
        assert!(err.contains("acceptance_evaluation"));
    }

    #[test]
    fn validate_stage_artifacts_should_reject_first_round_verify_missing_criteria_coverage() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.jsonc"),
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
                "implementation_stage_kind": "implement_general",
                "linked_check_ids": ["v-1", "v-2"]
            })]),
        );
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "$schema_version": "2.0",
                "stage": "verify",
                "cycle_id": "c-1",
                "verify_iteration": 0,
                "summary": "verify",
                "check_results": [],
                "acceptance_evaluation": [
                    {"criteria_id": "ac-1", "status": "pass"},
                    {"criteria_id": "ac-2", "status": "pass"}
                ],
                "verification_overall": {"result": "pass"},
                "carryover_verification": {
                    "items": [],
                    "summary": {"total": 0, "covered": 0, "missing": 0, "blocked": 0}
                },
                "verify_iteration_limit": 2,
                "adjudication": {
                    "criteria_judgement": [
                        {"criteria_id": "ac-1", "result": "pass"}
                    ],
                    "overall_result": {"result": "pass"},
                    "full_next_iteration_requirements": []
                },
                "updated_at": "2026-03-02T00:00:00Z"
            }),
        );

        let err = EvolutionManager::validate_stage_artifacts("verify", dir.path(), 0, 1)
            .expect_err("first round missing criteria coverage should fail");
        assert!(err.contains("criteria_judgement 覆盖不完整"));
    }

    #[test]
    fn validate_stage_artifacts_should_reject_managed_backlog_verify_iteration_mismatch() {
        let dir = tempdir().expect("tempdir should succeed");
        write_managed_backlog_files(
            dir.path(),
            "c-1",
            2,
            vec![serde_json::json!({
                "id": "fb-1",
                "source_criteria_id": "ac-1",
                "source_check_id": "v-1",
                "work_item_id": "w-1",
                "implementation_stage_kind": "implement_general",
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
                "implementation_stage_kind": "implement_general",
                "status": "done",
                "evidence": null,
                "notes": "",
                "updated_at": "2026-03-02T00:00:00Z"
            })],
        );
        write_json(
            &dir.path().join("implement_general.jsonc"),
            base_implement_result_with_updates(Vec::new()),
        );

        let err = EvolutionManager::validate_stage_artifacts("implement_general", dir.path(), 1, 2)
            .expect_err("managed backlog verify_iteration mismatch should fail");
        assert!(err.contains("managed.backlog.jsonc.verify_iteration"));
    }

    #[test]
    fn validate_stage_artifacts_with_context_should_reject_stale_artifact_timestamp() {
        let dir = tempdir().expect("tempdir should succeed");
        write_empty_implement_result_triplet(dir.path());

        let mut result = super::read_json_file(dir.path(), "implement_general.jsonc")
            .expect("implement result should be readable");
        result
            .as_object_mut()
            .expect("implement result should be object")
            .insert(
                "updated_at".to_string(),
                serde_json::json!("2026-03-01T00:00:00Z"),
            );
        write_json(&dir.path().join("implement_general.jsonc"), result);

        let started_at = chrono::DateTime::parse_from_rfc3339("2026-03-02T12:00:00Z")
            .expect("parse started_at should succeed")
            .with_timezone(&Utc);
        let ctx = StageValidationContext {
            cycle_id: "c-1".to_string(),
            verify_iteration: 1,
            backlog_contract_version: 1,
            stage_started_at: Some(started_at),
            workspace_root: dir.path().display().to_string(),
        };
        let err = EvolutionManager::validate_stage_artifacts_with_context(
            "implement_general",
            dir.path(),
            1,
            1,
            Some(&ctx),
        )
        .expect_err("stale artifact should fail freshness check");
        assert!(err.contains("时间戳早于本次阶段开始时间"));
    }

    #[test]
    fn validate_stage_artifacts_with_context_should_reject_dirty_auto_commit_without_reason() {
        let dir = tempdir().expect("tempdir should succeed");
        let init_status = Command::new("git")
            .arg("init")
            .current_dir(dir.path())
            .status()
            .expect("git init should run");
        assert!(init_status.success(), "git init should succeed");
        std::fs::write(dir.path().join("dirty.txt"), "dirty")
            .expect("write dirty file should succeed");

        write_json(
            &dir.path().join("auto_commit.jsonc"),
            serde_json::json!({
                "$schema_version": "1.0",
                "cycle_id": "c-1",
                "decision": {"reason": "auto commit done"},
                "updated_at": "2026-03-02T00:00:00Z"
            }),
        );

        let started_at = chrono::DateTime::parse_from_rfc3339("2026-03-01T12:00:00Z")
            .expect("parse started_at should succeed")
            .with_timezone(&Utc);
        let ctx = StageValidationContext {
            cycle_id: "c-1".to_string(),
            verify_iteration: 0,
            backlog_contract_version: 1,
            stage_started_at: Some(started_at),
            workspace_root: dir.path().display().to_string(),
        };
        let err = EvolutionManager::validate_stage_artifacts_with_context(
            "auto_commit",
            dir.path(),
            0,
            1,
            Some(&ctx),
        )
        .expect_err("dirty auto_commit without reason should fail");
        assert!(err.contains("工作区仍有未提交变更"));
    }

    #[test]
    fn validate_stage_artifacts_should_reject_missing_failure_backlog_on_reimplementation() {
        let dir = tempdir().expect("tempdir should succeed");
        write_empty_implement_result_triplet(dir.path());
        write_json(
            &dir.path().join("implement_general.jsonc"),
            serde_json::json!({
                "$schema_version": "1.0",
                "cycle_id": "c-1",
                "verify_iteration": 1,
                "status": "done",
                "summary": "ok",
                "work_item_results": [],
                "changed_files": [],
                "commands_executed": [],
                "quick_checks": [],
                "backlog_coverage": [],
                "backlog_coverage_summary": {
                    "total": 0,
                    "done": 0,
                    "blocked": 0,
                    "not_done": 0
                },
                "updated_at": "2026-03-02T00:00:00Z"
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
            &dir.path().join("implement_general.jsonc"),
            serde_json::json!({
                "$schema_version": "1.0",
                "cycle_id": "c-1",
                "verify_iteration": 1,
                "status": "done",
                "summary": "ok",
                "work_item_results": [],
                "changed_files": [],
                "commands_executed": [],
                "quick_checks": [],
                "failure_backlog": [],
                "backlog_coverage_summary": {
                    "total": 0,
                    "done": 0,
                    "blocked": 0,
                    "not_done": 0
                },
                "updated_at": "2026-03-02T00:00:00Z"
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
            &dir.path().join("implement_general.jsonc"),
            base_implement_result_json(
                vec![
                    serde_json::json!({"id": "f-1", "implementation_stage_kind": "implement_general"}),
                    serde_json::json!({"id": "f-2", "implementation_stage_kind": "implement_visual"}),
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
            &dir.path().join("plan.jsonc"),
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
                "implementation_stage_kind": "implement_general",
                "linked_check_ids": ["v-1", "v-2"]
            })]),
        );
        write_json(
            &dir.path().join("implement_general.jsonc"),
            base_implement_result_json(
                vec![
                    serde_json::json!({"id": "f-1", "implementation_stage_kind": "implement_general"}),
                    serde_json::json!({"id": "f-2", "implementation_stage_kind": "implement_general"}),
                ],
                vec![
                    serde_json::json!({"id": "f-1", "status": "done"}),
                    serde_json::json!({"id": "f-2", "status": "done"}),
                ],
            ),
        );
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "$schema_version": "2.0",
                "stage": "verify",
                "cycle_id": "c-1",
                "verify_iteration": 1,
                "verify_iteration_limit": 2,
                "summary": "verify",
                "check_results": [],
                "acceptance_evaluation": [
                    {"criteria_id": "ac-1", "status": "pass"},
                    {"criteria_id": "ac-2", "status": "pass"}
                ],
                "verification_overall": {"result": "fail"},
                "carryover_verification": {
                    "items": [{"id": "f-1", "status": "done"}],
                    "summary": {"total": 2, "covered": 1, "missing": 1, "blocked": 0}
                },
                "adjudication": {
                    "criteria_judgement": [
                        {"criteria_id": "ac-1", "result": "pass"},
                        {"criteria_id": "ac-2", "result": "pass"}
                    ],
                    "overall_result": {"result": "fail"},
                    "full_next_iteration_requirements": []
                },
                "updated_at": "2026-03-02T00:00:00Z"
            }),
        );
        let err = EvolutionManager::validate_stage_artifacts("verify", dir.path(), 1, 1)
            .expect_err("verify missing backlog items should fail");
        assert!(err.contains("缺少 backlog 项"));
    }

    #[test]
    fn validate_stage_artifacts_should_reject_verify_missing_acceptance_status() {
        let dir = tempdir().expect("tempdir should succeed");
        write_empty_implement_result_triplet(dir.path());
        write_json(
            &dir.path().join("plan.jsonc"),
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
                "implementation_stage_kind": "implement_general",
                "linked_check_ids": ["v-1", "v-2"]
            })]),
        );
        write_json(
            &dir.path().join("implement_general.jsonc"),
            base_implement_result_json(
                vec![
                    serde_json::json!({"id": "f-1", "implementation_stage_kind": "implement_general"}),
                ],
                vec![serde_json::json!({"id": "f-1", "status": "done"})],
            ),
        );
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "$schema_version": "2.0",
                "stage": "verify",
                "cycle_id": "c-1",
                "verify_iteration": 1,
                "summary": "verify",
                "check_results": [],
                "acceptance_evaluation": [
                    {"criteria_id": "ac-1"},
                    {"criteria_id": "ac-2", "status": "pass"}
                ],
                "verification_overall": {"result": "fail"},
                "carryover_verification": {
                    "items": [{"id": "f-1", "status": "done"}],
                    "summary": {"total": 1, "covered": 1, "missing": 0, "blocked": 0}
                },
                "updated_at": "2026-03-02T00:00:00Z"
            }),
        );
        let err = EvolutionManager::validate_stage_artifacts("verify", dir.path(), 1, 1)
            .expect_err("verify acceptance 缺少 status 应失败");
        assert!(err.contains("acceptance_evaluation[0] 缺少 status"));
    }

    #[test]
    fn validate_stage_artifacts_should_reject_verify_invalid_acceptance_status() {
        let dir = tempdir().expect("tempdir should succeed");
        write_empty_implement_result_triplet(dir.path());
        write_json(
            &dir.path().join("plan.jsonc"),
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
                "implementation_stage_kind": "implement_general",
                "linked_check_ids": ["v-1", "v-2"]
            })]),
        );
        write_json(
            &dir.path().join("implement_general.jsonc"),
            base_implement_result_json(
                vec![
                    serde_json::json!({"id": "f-1", "implementation_stage_kind": "implement_general"}),
                ],
                vec![serde_json::json!({"id": "f-1", "status": "done"})],
            ),
        );
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "$schema_version": "2.0",
                "stage": "verify",
                "cycle_id": "c-1",
                "verify_iteration": 1,
                "summary": "verify",
                "check_results": [],
                "acceptance_evaluation": [
                    {"criteria_id": "ac-1", "status": "failed"},
                    {"criteria_id": "ac-2", "status": "pass"}
                ],
                "verification_overall": {"result": "fail"},
                "carryover_verification": {
                    "items": [{"id": "f-1", "status": "done"}],
                    "summary": {"total": 1, "covered": 1, "missing": 0, "blocked": 0}
                },
                "updated_at": "2026-03-02T00:00:00Z"
            }),
        );
        let err = EvolutionManager::validate_stage_artifacts("verify", dir.path(), 1, 1)
            .expect_err("verify acceptance 非法 status 应失败");
        assert!(err.contains("acceptance_evaluation[0].status 非法"));
    }

    #[test]
    fn validate_stage_artifacts_should_reject_verify_missing_failed_requirements() {
        let dir = tempdir().expect("tempdir should succeed");
        write_empty_implement_result_triplet(dir.path());
        write_json(
            &dir.path().join("implement_general.jsonc"),
            base_implement_result_json(
                vec![
                    serde_json::json!({"id": "f-1", "implementation_stage_kind": "implement_general"}),
                ],
                vec![serde_json::json!({"id": "f-1", "status": "not_done"})],
            ),
        );
        write_json(
            &dir.path().join("plan.jsonc"),
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
                "implementation_stage_kind": "implement_general",
                "linked_check_ids": ["v-1", "v-2"]
            })]),
        );
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "$schema_version": "2.0",
                "stage": "verify",
                "cycle_id": "c-1",
                "verify_iteration": 1,
                "summary": "verify",
                "check_results": [],
                "acceptance_evaluation": [
                    {"criteria_id": "ac-1", "status": "fail"},
                    {"criteria_id": "ac-2", "status": "pass"}
                ],
                "verification_overall": {"result": "fail"},
                "carryover_verification": {
                    "items": [{"id": "f-1", "status": "missing"}],
                    "summary": {"total": 1, "covered": 0, "missing": 1, "blocked": 0}
                },
                "updated_at": "2026-03-02T00:00:00Z"
            }),
        );
        let mut verify = super::read_json_file(dir.path(), "verify.jsonc")
            .expect("verify result should be readable");
        verify
            .as_object_mut()
            .expect("verify result should be object")
            .insert("verify_iteration_limit".to_string(), serde_json::json!(2));
        verify
            .as_object_mut()
            .expect("verify result should be object")
            .insert(
                "adjudication".to_string(),
                serde_json::json!({
                    "criteria_judgement": [
                        {"criteria_id": "ac-1", "result": "fail"},
                        {"criteria_id": "ac-2", "result": "pass"}
                    ],
                    "overall_result": {"result": "fail"},
                    "full_next_iteration_requirements": [
                        {"id": "ac-1"}
                    ]
                }),
            );
        write_json(&dir.path().join("verify.jsonc"), verify);
        let err = EvolutionManager::validate_stage_artifacts("verify", dir.path(), 1, 1)
            .expect_err("verify requirements missing should fail");
        assert!(err.contains("未覆盖 verify 未通过项"));
    }

    #[test]
    fn validate_stage_artifacts_should_reject_verify_v2_missing_selector_fields() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.jsonc"),
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_general",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "$schema_version": "2.0",
                "stage": "verify",
                "cycle_id": "c-1",
                "verify_iteration": 1,
                "summary": "verify",
                "check_results": [],
                "acceptance_evaluation": [
                    {"criteria_id": "ac-1", "status": "fail"},
                    {"criteria_id": "ac-2", "status": "pass"}
                ],
                "verification_overall": {"result": "fail"},
                "carryover_verification": {
                    "items": [],
                    "summary": {"total": 0, "covered": 0, "missing": 0, "blocked": 0}
                },
                "updated_at": "2026-03-02T00:00:00Z"
            }),
        );
        write_managed_backlog_files(dir.path(), "c-1", 1, Vec::new(), Vec::new());
        let mut verify = super::read_json_file(dir.path(), "verify.jsonc")
            .expect("verify result should be readable");
        verify
            .as_object_mut()
            .expect("verify result should be object")
            .insert("verify_iteration_limit".to_string(), serde_json::json!(2));
        verify
            .as_object_mut()
            .expect("verify result should be object")
            .insert(
                "adjudication".to_string(),
                serde_json::json!({
                    "criteria_judgement": [
                        {"criteria_id": "ac-1", "result": "fail"},
                        {"criteria_id": "ac-2", "result": "pass"}
                    ],
                    "overall_result": {"result": "fail"},
                    "full_next_iteration_requirements": [
                        {"criteria_id": "ac-1"}
                    ]
                }),
            );
        write_json(&dir.path().join("verify.jsonc"), verify);
        let err = EvolutionManager::validate_stage_artifacts("verify", dir.path(), 1, 2)
            .expect_err("v2 verify 缺少 selector 字段应失败");
        assert!(err.contains("source_check_id"));
    }

    #[test]
    fn validate_stage_artifacts_should_accept_verify_v2_complete_selector_fields() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.jsonc"),
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_general",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "$schema_version": "2.0",
                "stage": "verify",
                "cycle_id": "c-1",
                "verify_iteration": 1,
                "summary": "verify",
                "check_results": [],
                "acceptance_evaluation": [
                    {"criteria_id": "ac-1", "status": "fail"},
                    {"criteria_id": "ac-2", "status": "pass"}
                ],
                "verification_overall": {"result": "fail"},
                "carryover_verification": {
                    "items": [],
                    "summary": {"total": 0, "covered": 0, "missing": 0, "blocked": 0}
                },
                "updated_at": "2026-03-02T00:00:00Z"
            }),
        );
        write_managed_backlog_files(dir.path(), "c-1", 1, Vec::new(), Vec::new());
        let mut verify = super::read_json_file(dir.path(), "verify.jsonc")
            .expect("verify result should be readable");
        verify
            .as_object_mut()
            .expect("verify result should be object")
            .insert("verify_iteration_limit".to_string(), serde_json::json!(2));
        verify
            .as_object_mut()
            .expect("verify result should be object")
            .insert(
                "adjudication".to_string(),
                serde_json::json!({
                    "criteria_judgement": [
                        {"criteria_id": "ac-1", "result": "fail"},
                        {"criteria_id": "ac-2", "result": "pass"}
                    ],
                    "overall_result": {"result": "fail"},
                    "full_next_iteration_requirements": [
                        {
                            "id": "ac-1",
                            "criteria_id": "ac-1",
                            "source_criteria_id": "ac-1",
                            "source_check_id": "v-1",
                            "work_item_id": "w-1",
                            "implementation_stage_kind": "implement_general"
                        }
                    ]
                }),
            );
        write_json(&dir.path().join("verify.jsonc"), verify);
        EvolutionManager::validate_stage_artifacts("verify", dir.path(), 1, 2)
            .expect("v2 verify 完整 selector 应通过");
    }

    #[test]
    fn validate_stage_artifacts_should_reject_verify_v2_missing_selector_fields_on_first_iteration_fail(
    ) {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.jsonc"),
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_general",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "$schema_version": "2.0",
                "stage": "verify",
                "cycle_id": "c-1",
                "verify_iteration": 0,
                "summary": "verify",
                "check_results": [],
                "acceptance_evaluation": [
                    {"criteria_id": "ac-1", "status": "fail"},
                    {"criteria_id": "ac-2", "status": "pass"}
                ],
                "verification_overall": {"result": "fail"},
                "carryover_verification": {
                    "items": [],
                    "summary": {"total": 0, "covered": 0, "missing": 0, "blocked": 0}
                },
                "verify_iteration_limit": 2,
                "adjudication": {
                    "criteria_judgement": [
                        {"criteria_id": "ac-1", "result": "fail"},
                        {"criteria_id": "ac-2", "result": "pass"}
                    ],
                    "overall_result": {"result": "fail"},
                    "full_next_iteration_requirements": [
                        {"criteria_id": "ac-1"}
                    ]
                },
                "updated_at": "2026-03-02T00:00:00Z"
            }),
        );
        let err = EvolutionManager::validate_stage_artifacts("verify", dir.path(), 0, 2)
            .expect_err("首轮 fail 且 v2 缺少 selector 字段应失败");
        assert!(err.contains("source_check_id"));
    }

    #[test]
    fn validate_stage_artifacts_should_accept_verify_v2_complete_selector_fields_on_first_iteration_fail(
    ) {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.jsonc"),
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_general",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "$schema_version": "2.0",
                "stage": "verify",
                "cycle_id": "c-1",
                "verify_iteration": 0,
                "summary": "verify",
                "check_results": [],
                "acceptance_evaluation": [
                    {"criteria_id": "ac-1", "status": "fail"},
                    {"criteria_id": "ac-2", "status": "pass"}
                ],
                "verification_overall": {"result": "fail"},
                "carryover_verification": {
                    "items": [],
                    "summary": {"total": 0, "covered": 0, "missing": 0, "blocked": 0}
                },
                "verify_iteration_limit": 2,
                "adjudication": {
                    "criteria_judgement": [
                        {"criteria_id": "ac-1", "result": "fail"},
                        {"criteria_id": "ac-2", "result": "pass"}
                    ],
                    "overall_result": {"result": "fail"},
                    "full_next_iteration_requirements": [
                        {
                            "source_criteria_id": "ac-1",
                            "source_check_id": "v-1",
                            "work_item_id": "w-1",
                            "implementation_stage_kind": "implement_general"
                        }
                    ]
                },
                "updated_at": "2026-03-02T00:00:00Z"
            }),
        );
        EvolutionManager::validate_stage_artifacts("verify", dir.path(), 0, 2)
            .expect("首轮 fail 且 v2 提供完整 selector 应通过");
    }

    #[test]
    fn validate_stage_artifacts_should_accept_verify_requirements_with_mixed_id_fields() {
        let dir = tempdir().expect("tempdir should succeed");
        write_empty_implement_result_triplet(dir.path());
        write_json(
            &dir.path().join("implement_general.jsonc"),
            base_implement_result_json(
                vec![
                    serde_json::json!({"id": "f-1", "implementation_stage_kind": "implement_general"}),
                ],
                vec![serde_json::json!({"id": "f-1", "status": "not_done"})],
            ),
        );
        write_json(
            &dir.path().join("plan.jsonc"),
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
                "implementation_stage_kind": "implement_general",
                "linked_check_ids": ["v-1", "v-2"]
            })]),
        );
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "$schema_version": "2.0",
                "stage": "verify",
                "cycle_id": "c-1",
                "verify_iteration": 1,
                "summary": "verify",
                "check_results": [],
                "acceptance_evaluation": [
                    {"criteria_id": "ac-1", "status": "insufficient_evidence"},
                    {"criteria_id": "ac-2", "status": "pass"}
                ],
                "verification_overall": {"result": "fail"},
                "carryover_verification": {
                    "items": [{"id": "f-1", "status": "missing"}],
                    "summary": {"total": 1, "covered": 0, "missing": 1, "blocked": 0}
                },
                "updated_at": "2026-03-02T00:00:00Z"
            }),
        );
        let mut verify = super::read_json_file(dir.path(), "verify.jsonc")
            .expect("verify result should be readable");
        verify
            .as_object_mut()
            .expect("verify result should be object")
            .insert("verify_iteration_limit".to_string(), serde_json::json!(2));
        verify
            .as_object_mut()
            .expect("verify result should be object")
            .insert(
                "adjudication".to_string(),
                serde_json::json!({
                    "criteria_judgement": [
                        {"criteria_id": "ac-1", "result": "fail"},
                        {"criteria_id": "ac-2", "result": "pass"}
                    ],
                    "overall_result": {"result": "fail"},
                    "full_next_iteration_requirements": [
                        {
                            "id": "f-1",
                            "criteria_id": "ac-1"
                        }
                    ]
                }),
            );
        write_json(&dir.path().join("verify.jsonc"), verify);

        EvolutionManager::validate_stage_artifacts("verify", dir.path(), 1, 1)
            .expect("verify requirement 同时包含 id 和 criteria_id 应视为覆盖 verify 未通过项");
    }

    #[test]
    fn validate_plan_artifact_should_reject_missing_implementation_stage_kind() {
        let dir = tempdir().expect("tempdir should succeed");
        write_valid_direction_artifacts(dir.path());
        write_plan_markdown(dir.path());
        write_json(
            &dir.path().join("plan.jsonc"),
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
            .expect_err("missing implementation_stage_kind should fail");
        assert!(err.contains("implementation_stage_kind"));
    }

    #[test]
    fn validate_plan_artifact_should_reject_invalid_agent() {
        let dir = tempdir().expect("tempdir should succeed");
        write_valid_direction_artifacts(dir.path());
        write_plan_markdown(dir.path());
        write_json(
            &dir.path().join("plan.jsonc"),
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
                "implementation_stage_kind": "nonsense",
                "linked_check_ids": ["v-1"]
            })]),
        );
        let err = EvolutionManager::validate_stage_artifacts("plan", dir.path(), 0, 1)
            .expect_err("invalid implementation_stage_kind should fail");
        assert!(err.contains("implementation_stage_kind"));
    }

    #[test]
    fn validate_plan_artifact_should_reject_advanced_agent() {
        let dir = tempdir().expect("tempdir should succeed");
        write_valid_direction_artifacts(dir.path());
        write_plan_markdown(dir.path());
        write_json(
            &dir.path().join("plan.jsonc"),
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
                "implementation_stage_kind": "implement_advanced",
                "linked_check_ids": ["v-1"]
            })]),
        );
        let err = EvolutionManager::validate_stage_artifacts("plan", dir.path(), 0, 1)
            .expect_err("advanced implementation_stage_kind should fail");
        assert!(err.contains("仅允许 general 或 visual"));
    }

    #[test]
    fn validate_plan_artifact_should_reject_missing_linked_check_ids() {
        let dir = tempdir().expect("tempdir should succeed");
        write_valid_direction_artifacts(dir.path());
        write_plan_markdown(dir.path());
        write_json(
            &dir.path().join("plan.jsonc"),
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
                "implementation_stage_kind": "implement_general"
            })]),
        );
        let err = EvolutionManager::validate_stage_artifacts("plan", dir.path(), 0, 1)
            .expect_err("missing linked_check_ids should fail");
        assert!(err.contains("linked_check_ids"));
    }

    #[test]
    fn validate_plan_artifact_should_reject_unknown_linked_check_id() {
        let dir = tempdir().expect("tempdir should succeed");
        write_valid_direction_artifacts(dir.path());
        write_plan_markdown(dir.path());
        write_json(
            &dir.path().join("plan.jsonc"),
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
                "implementation_stage_kind": "implement_general",
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
            &dir.path().join("plan.jsonc"),
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_general",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        let lanes = EvolutionManager::resolve_implement_lanes(dir.path(), 0)
            .expect("lane resolve should succeed");
        assert_eq!(lanes, vec![ImplementLane::General]);
    }

    #[test]
    fn resolve_initial_implementation_stage_instances_should_repeat_stage_kind_by_dependency_layer()
    {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.jsonc"),
            base_plan_json(vec![
                serde_json::json!({
                    "id": "w-1",
                    "title": "通用基础改动",
                    "type": "code",
                    "priority": "p0",
                    "depends_on": [],
                    "targets": ["core/src/lib.rs"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_stage_kind": "general",
                    "linked_check_ids": ["v-1"]
                }),
                serde_json::json!({
                    "id": "w-2",
                    "title": "视觉层改动",
                    "type": "code",
                    "priority": "p1",
                    "depends_on": ["w-1"],
                    "targets": ["app/TidyFlow/View.swift"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_stage_kind": "visual",
                    "linked_check_ids": ["v-2"]
                }),
                serde_json::json!({
                    "id": "w-3",
                    "title": "通用收尾改动",
                    "type": "code",
                    "priority": "p1",
                    "depends_on": ["w-2"],
                    "targets": ["core/src/server/mod.rs"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_stage_kind": "general",
                    "linked_check_ids": ["v-1"]
                }),
            ]),
        );

        let instances =
            EvolutionManager::resolve_initial_implementation_stage_instances(dir.path())
                .expect("stage instances should resolve");
        let stages = instances
            .iter()
            .map(|item| item.stage.as_str())
            .collect::<Vec<_>>();
        assert_eq!(
            stages,
            vec![
                "implement.general.1",
                "implement.visual.1",
                "implement.general.2"
            ]
        );
        assert_eq!(instances[0].work_item_ids, vec!["w-1"]);
        assert_eq!(instances[1].work_item_ids, vec!["w-2"]);
        assert_eq!(instances[2].work_item_ids, vec!["w-3"]);
    }

    #[test]
    fn resolve_initial_implementation_stage_instances_should_merge_adjacent_same_kind() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.jsonc"),
            base_plan_json(vec![
                serde_json::json!({
                    "id": "w-1",
                    "title": "通用基础改动",
                    "type": "code",
                    "priority": "p0",
                    "depends_on": [],
                    "targets": ["core/src/lib.rs"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_stage_kind": "general",
                    "linked_check_ids": ["v-1"]
                }),
                serde_json::json!({
                    "id": "w-2",
                    "title": "通用中间改动",
                    "type": "code",
                    "priority": "p1",
                    "depends_on": ["w-1"],
                    "targets": ["core/src/server/mod.rs"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_stage_kind": "general",
                    "linked_check_ids": ["v-1"]
                }),
                serde_json::json!({
                    "id": "w-3",
                    "title": "视觉收尾改动",
                    "type": "code",
                    "priority": "p1",
                    "depends_on": ["w-2"],
                    "targets": ["app/TidyFlow/View.swift"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_stage_kind": "visual",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );

        let instances =
            EvolutionManager::resolve_initial_implementation_stage_instances(dir.path())
                .expect("stage instances should resolve");
        let stages = instances
            .iter()
            .map(|item| item.stage.as_str())
            .collect::<Vec<_>>();
        assert_eq!(stages, vec!["implement.general.1", "implement.visual.1"]);
        assert_eq!(instances[0].work_item_ids, vec!["w-1", "w-2"]);
        assert_eq!(instances[1].work_item_ids, vec!["w-3"]);
    }

    #[test]
    fn resolve_initial_implementation_stage_instances_should_chain_merge_three_adjacent_same_kind()
    {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.jsonc"),
            base_plan_json(vec![
                serde_json::json!({
                    "id": "w-1",
                    "title": "通用基础改动",
                    "type": "code",
                    "priority": "p0",
                    "depends_on": [],
                    "targets": ["core/src/lib.rs"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_stage_kind": "general",
                    "linked_check_ids": ["v-1"]
                }),
                serde_json::json!({
                    "id": "w-2",
                    "title": "通用中间改动",
                    "type": "code",
                    "priority": "p1",
                    "depends_on": ["w-1"],
                    "targets": ["core/src/server/mod.rs"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_stage_kind": "general",
                    "linked_check_ids": ["v-1"]
                }),
                serde_json::json!({
                    "id": "w-3",
                    "title": "通用收尾改动",
                    "type": "code",
                    "priority": "p1",
                    "depends_on": ["w-2"],
                    "targets": ["core/src/main.rs"],
                    "definition_of_done": ["done"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_stage_kind": "general",
                    "linked_check_ids": ["v-1"]
                }),
            ]),
        );

        let instances =
            EvolutionManager::resolve_initial_implementation_stage_instances(dir.path())
                .expect("stage instances should resolve");
        let stages = instances
            .iter()
            .map(|item| item.stage.as_str())
            .collect::<Vec<_>>();
        assert_eq!(stages, vec!["implement.general.1"]);
        assert_eq!(instances[0].work_item_ids, vec!["w-1", "w-2", "w-3"]);
    }

    #[test]
    fn tasks_to_complete_for_stage_should_only_include_current_stage_items() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.jsonc"),
            base_plan_json(vec![
                serde_json::json!({
                    "id": "w-1",
                    "title": "通用基础改动",
                    "type": "code",
                    "priority": "p0",
                    "depends_on": [],
                    "targets": ["core/src/lib.rs"],
                    "definition_of_done": ["完成基础抽象"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_stage_kind": "general",
                    "linked_check_ids": ["v-1"]
                }),
                serde_json::json!({
                    "id": "w-2",
                    "title": "视觉层改动",
                    "type": "code",
                    "priority": "p1",
                    "depends_on": ["w-1"],
                    "targets": ["app/TidyFlow/View.swift"],
                    "definition_of_done": ["完成视觉接入"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_stage_kind": "visual",
                    "linked_check_ids": ["v-2"]
                }),
                serde_json::json!({
                    "id": "w-3",
                    "title": "通用收尾改动",
                    "type": "code",
                    "priority": "p1",
                    "depends_on": ["w-2"],
                    "targets": ["core/src/server/mod.rs"],
                    "definition_of_done": ["完成收尾"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_stage_kind": "general",
                    "linked_check_ids": ["v-1"]
                }),
            ]),
        );

        let tasks =
            EvolutionManager::tasks_to_complete_for_stage(dir.path(), "implement.general.2")
                .expect("tasks should resolve");
        assert!(tasks.contains("### w-3 通用收尾改动"));
        assert!(tasks.contains("- 实现阶段类型：general"));
        assert!(!tasks.contains("### w-1 通用基础改动"));
        assert!(!tasks.contains("### w-2 视觉层改动"));
    }

    #[test]
    fn tasks_to_complete_for_stage_should_include_all_merged_same_kind_items() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.jsonc"),
            base_plan_json(vec![
                serde_json::json!({
                    "id": "w-1",
                    "title": "通用基础改动",
                    "type": "code",
                    "priority": "p0",
                    "depends_on": [],
                    "targets": ["core/src/lib.rs"],
                    "definition_of_done": ["完成基础抽象"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_stage_kind": "general",
                    "linked_check_ids": ["v-1"]
                }),
                serde_json::json!({
                    "id": "w-2",
                    "title": "通用中间改动",
                    "type": "code",
                    "priority": "p1",
                    "depends_on": ["w-1"],
                    "targets": ["core/src/server/mod.rs"],
                    "definition_of_done": ["完成接口收敛"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_stage_kind": "general",
                    "linked_check_ids": ["v-1"]
                }),
                serde_json::json!({
                    "id": "w-3",
                    "title": "视觉层改动",
                    "type": "code",
                    "priority": "p1",
                    "depends_on": ["w-2"],
                    "targets": ["app/TidyFlow/View.swift"],
                    "definition_of_done": ["完成视觉接入"],
                    "risk": "low",
                    "rollback": "git restore",
                    "implementation_stage_kind": "visual",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );

        let tasks =
            EvolutionManager::tasks_to_complete_for_stage(dir.path(), "implement.general.1")
                .expect("tasks should resolve");
        assert!(tasks.contains("### w-1 通用基础改动"));
        assert!(tasks.contains("### w-2 通用中间改动"));
        assert!(tasks.contains("- 实现阶段类型：general"));
        assert!(!tasks.contains("### w-3 视觉层改动"));
    }

    #[test]
    fn issues_to_fix_for_stage_should_render_verify_requirements_for_reimplement_stage() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "$schema_version": "2.0",
                "stage": "verify",
                "cycle_id": "c-1",
                "status": "done",
                "decision": {"result": "fail", "reason": "需要重实现"},
                "acceptance_evaluation": [],
                "carryover_verification": {"items": []},
                "adjudication": {
                    "criteria_judgement": [],
                    "full_next_iteration_requirements": [
                        {
                            "requirement_id": "REQ-001",
                            "description": "修复通用层接口遗漏",
                            "source_criteria_id": "ac-1",
                            "source_check_id": "v-1",
                            "work_item_id": "w-1",
                            "implementation_stage_kind": "general"
                        }
                    ]
                },
                "updated_at": "2026-03-08T00:00:00Z"
            }),
        );

        let issues = EvolutionManager::issues_to_fix_for_stage(dir.path(), "reimplement.1")
            .expect("issues should resolve");
        assert!(issues.contains("### REQ-001（第 1 次重实现）"));
        assert!(issues.contains("修复通用层接口遗漏"));
        assert!(issues.contains("implementation_stage_kind：general"));
    }

    #[test]
    fn resolve_implement_lanes_should_use_visual_only_on_first_iteration() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.jsonc"),
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
                    "implementation_stage_kind": "implement_visual",
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
                    "implementation_stage_kind": "implement_visual",
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
            &dir.path().join("plan.jsonc"),
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_visual",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        let lanes = EvolutionManager::resolve_implement_lanes(dir.path(), 0)
            .expect("lane resolve should succeed");
        assert_eq!(lanes, vec![ImplementLane::General, ImplementLane::Visual]);
    }

    #[test]
    fn resolve_implement_lanes_should_reject_advanced_agent_in_plan_on_first_iteration() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.jsonc"),
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_advanced",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        let err = EvolutionManager::resolve_implement_lanes(dir.path(), 0)
            .expect_err("advanced plan agent should be rejected");
        assert!(err.contains("仅允许 general 或 visual"));
    }

    #[test]
    fn resolve_implement_lanes_should_map_only_general_on_reimplementation() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.jsonc"),
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_visual",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "acceptance_evaluation": [{"criteria_id": "ac-1", "status": "fail"}],
                "carryover_verification": {"items": [], "summary": {"total": 0, "covered": 0, "missing": 0, "blocked": 0}}
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
            &dir.path().join("plan.jsonc"),
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_visual",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "acceptance_evaluation": [{"criteria_id": "ac-2", "status": "insufficient_evidence"}],
                "carryover_verification": {"items": [], "summary": {"total": 0, "covered": 0, "missing": 0, "blocked": 0}}
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
            &dir.path().join("plan.jsonc"),
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_visual",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "acceptance_evaluation": [{"criteria_id": "ac-1", "status": "fail"}],
                "carryover_verification": {"items": [{"id": "ac-2", "status": "missing"}], "summary": {"total": 1, "covered": 0, "missing": 1, "blocked": 0}}
            }),
        );
        let lanes = EvolutionManager::resolve_implement_lanes(dir.path(), 1)
            .expect("lane resolve should succeed");
        assert_eq!(lanes, vec![ImplementLane::General, ImplementLane::Visual]);
    }

    #[test]
    fn resolve_implement_lanes_should_reject_advanced_agent_in_plan_on_reimplementation() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.jsonc"),
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_advanced",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "acceptance_evaluation": [{"criteria_id": "ac-1", "status": "fail"}],
                "carryover_verification": {"items": [{"id": "ac-2", "status": "missing"}], "summary": {"total": 1, "covered": 0, "missing": 1, "blocked": 0}}
            }),
        );
        let err = EvolutionManager::resolve_implement_lanes(dir.path(), 1)
            .expect_err("advanced plan agent should be rejected");
        assert!(err.contains("仅允许 general 或 visual"));
    }

    #[test]
    fn resolve_implement_lanes_should_fallback_to_general_when_mapping_unknown() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("plan.jsonc"),
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_visual",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "acceptance_evaluation": [{"criteria_id": "ac-404", "status": "fail"}],
                "carryover_verification": {"items": [], "summary": {"total": 0, "covered": 0, "missing": 0, "blocked": 0}}
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
    fn deterministic_policy_should_force_advanced_after_second_reimplementation() {
        assert!(!should_force_advanced_reimplementation(1));
        assert!(should_force_advanced_reimplementation(2));
    }

    #[test]
    fn validate_implement_artifact_should_reject_invalid_failure_backlog_agent() {
        let dir = tempdir().expect("tempdir should succeed");
        write_empty_implement_result_triplet(dir.path());
        write_json(
            &dir.path().join("implement_general.jsonc"),
            base_implement_result_json(
                vec![serde_json::json!({"id": "f-1", "implementation_stage_kind": "nonsense"})],
                vec![serde_json::json!({"id": "f-1", "status": "done"})],
            ),
        );
        let err = EvolutionManager::validate_stage_artifacts("implement_visual", dir.path(), 1, 1)
            .expect_err("invalid failure_backlog implementation_stage_kind should fail");
        assert!(err.contains("implementation_stage_kind"));
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
                "implementation_stage_kind": "implement_general",
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
                "implementation_stage_kind": "implement_general",
                "status": "done",
                "evidence": null,
                "notes": "",
                "updated_at": "2026-03-02T00:00:00Z"
            })],
        );
        write_json(
            &dir.path().join("implement_general.jsonc"),
            base_implement_result_with_updates(Vec::new()),
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
                "implementation_stage_kind": "implement_general",
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
                "implementation_stage_kind": "implement_general",
                "status": "not_done",
                "evidence": null,
                "notes": "",
                "updated_at": "2026-03-02T00:00:00Z"
            })],
        );
        write_json(
            &dir.path().join("implement_general.jsonc"),
            base_implement_result_with_updates(vec![serde_json::json!({
                    "source_criteria_id": "ac-404",
                    "source_check_id": "v-404",
                    "work_item_id": "w-x",
                    "implementation_stage_kind": "implement_general",
                    "status": "done",
                    "evidence": {"proof": "x"},
                    "notes": "x"
            })]),
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_general",
                    "status": "not_done",
                    "evidence": null,
                    "notes": "",
                    "updated_at": "2026-03-02T00:00:00Z"
                }),
            ],
        );
        write_json(
            &dir.path().join("implement_general.jsonc"),
            base_implement_result_with_updates(vec![serde_json::json!({
                    "source_criteria_id": "ac-1",
                    "source_check_id": "v-1",
                    "work_item_id": "w-1",
                    "implementation_stage_kind": "implement_general",
                    "status": "done",
                    "evidence": {"proof": "x"},
                    "notes": "x"
            })]),
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
                "implementation_stage_kind": "implement_general",
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
                "implementation_stage_kind": "implement_general",
                "status": "not_done",
                "evidence": null,
                "notes": "",
                "updated_at": "2026-03-02T00:00:00Z"
            })],
        );
        write_json(
            &dir.path().join("implement_general.jsonc"),
            base_implement_result_with_updates(vec![serde_json::json!({
                    "source_criteria_id": "ac-1",
                    "source_check_id": "v-1",
                    "work_item_id": "w-1",
                    "implementation_stage_kind": "implement_general",
                    "status": "done",
                    "evidence": {"proof": "done"},
                    "notes": "resolved"
            })]),
        );
        EvolutionManager::sync_managed_backlog_for_implement_stage(dir.path(), "implement_general")
            .expect("sync should succeed");
        let result = super::read_json_file(dir.path(), "implement_general.jsonc")
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
    fn sync_managed_backlog_should_fallback_to_requirement_ref_when_work_item_id_mismatched() {
        let dir = tempdir().expect("tempdir should succeed");
        write_managed_backlog_files(
            dir.path(),
            "c-1",
            1,
            vec![serde_json::json!({
                "id": "fb-1",
                "source_criteria_id": "AC-005",
                "source_check_id": "check_unit_integration_tests",
                "work_item_id": "wi_feature_tests_quality_004",
                "implementation_stage_kind": "implement_general",
                "requirement_ref": "NIR-AC005-TESTS-001",
                "description": "",
                "created_at": "2026-03-02T00:00:00Z",
                "updated_at": "2026-03-02T00:00:00Z"
            })],
            vec![serde_json::json!({
                "backlog_id": "fb-1",
                "source_criteria_id": "AC-005",
                "source_check_id": "check_unit_integration_tests",
                "work_item_id": "wi_feature_tests_quality_004",
                "implementation_stage_kind": "implement_general",
                "status": "not_done",
                "evidence": null,
                "notes": "",
                "updated_at": "2026-03-02T00:00:00Z"
            })],
        );
        write_json(
            &dir.path().join("implement_general.jsonc"),
            base_implement_result_with_updates(vec![serde_json::json!({
                    "source_criteria_id": "AC-005",
                    "source_check_id": "check_unit_integration_tests",
                    "work_item_id": "NIR-AC005-TESTS-001",
                    "implementation_stage_kind": "implement_general",
                    "status": "done",
                    "evidence": {"proof": "fixed"},
                    "notes": "resolved via requirement_ref"
            })]),
        );

        EvolutionManager::sync_managed_backlog_for_implement_stage(dir.path(), "implement_general")
            .expect("should fallback by requirement_ref");

        let coverage = super::read_json_file(dir.path(), "managed.backlog.jsonc")
            .expect("coverage should be readable");
        assert_eq!(coverage["items"][0]["status"], serde_json::json!("done"));

        let result = super::read_json_file(dir.path(), "implement_general.jsonc")
            .expect("result should be readable");
        assert_eq!(
            result["failure_backlog"][0]["work_item_id"],
            serde_json::json!("wi_feature_tests_quality_004")
        );
        assert_eq!(
            result["backlog_coverage"][0]["work_item_id"],
            serde_json::json!("wi_feature_tests_quality_004")
        );
    }

    #[test]
    fn generate_managed_backlog_should_create_files_on_verify_fail() {
        let dir = tempdir().expect("tempdir should succeed");
        write_json(
            &dir.path().join("cycle.jsonc"),
            serde_json::json!({
                "cycle_id": "c-1"
            }),
        );
        write_json(
            &dir.path().join("plan.jsonc"),
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_general",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "adjudication": {
                    "full_next_iteration_requirements": [{
                        "criteria_id": "ac-1",
                        "check_id": "v-1",
                        "work_item_id": "w-1",
                        "title": "need fix"
                    }]
                }
            }),
        );
        EvolutionManager::generate_managed_backlog_from_verify(dir.path(), 1)
            .expect("managed backlog generation should succeed");
        let backlog = super::read_json_file(dir.path(), "managed.backlog.jsonc")
            .expect("managed backlog should exist");
        let coverage = super::read_json_file(dir.path(), "managed.backlog.jsonc")
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
    fn generate_managed_backlog_from_verify_with_items_object() {
        let dir = tempfile::tempdir().unwrap();
        write_json(
            &dir.path().join("cycle.jsonc"),
            serde_json::json!({
                "cycle_id": "c-2"
            }),
        );
        write_json(
            &dir.path().join("plan.jsonc"),
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_general",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        // verify.adjudication 使用 {"items": [...]} 对象格式（而非直接数组）
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "adjudication": {
                    "full_next_iteration_requirements": {
                        "items": [{
                            "criteria_id": "ac-1",
                            "check_id": "v-1",
                            "work_item_id": "w-1",
                            "title": "need fix"
                        }]
                    }
                }
            }),
        );
        EvolutionManager::generate_managed_backlog_from_verify(dir.path(), 1)
            .expect("managed backlog generation should succeed with items object format");
        let backlog = super::read_json_file(dir.path(), "managed.backlog.jsonc")
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
    fn generate_managed_backlog_from_verify_with_acceptance_failures() {
        let dir = tempfile::tempdir().unwrap();
        write_json(
            &dir.path().join("cycle.jsonc"),
            serde_json::json!({ "cycle_id": "c-3" }),
        );
        write_json(
            &dir.path().join("plan.jsonc"),
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_general",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        // verify.adjudication 使用 {"acceptance_failures": [...], "carryover_failures": [...]} 格式
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "adjudication": {
                    "full_next_iteration_requirements": {
                        "carryover_failures": [],
                        "acceptance_failures": [
                            {
                                "type": "criteria_gap",
                                "criteria_id": "ac-1",
                                "check_ids": ["v-1"],
                                "required_items": ["fix core compilation errors"]
                            },
                            {
                                "type": "criteria_gap",
                                "criteria_id": "ac-2",
                                "check_ids": ["v-2"],
                                "required_items": ["fix extra compilation errors"]
                            }
                        ],
                        "notes": "fix all errors"
                    }
                }
            }),
        );
        EvolutionManager::generate_managed_backlog_from_verify(dir.path(), 1)
            .expect("managed backlog generation should succeed with acceptance_failures format");
        let backlog = super::read_json_file(dir.path(), "managed.backlog.jsonc")
            .expect("managed backlog should exist");
        // check_ids 有 2 个元素，应展开为 2 条 backlog 项
        assert_eq!(
            backlog["items"]
                .as_array()
                .map(|items| items.len())
                .unwrap_or(0),
            2
        );
        let coverage = super::read_json_file(dir.path(), "managed.backlog.jsonc")
            .expect("managed coverage should exist");
        assert_eq!(
            coverage["items"]
                .as_array()
                .map(|items| items.len())
                .unwrap_or(0),
            2
        );
    }

    #[test]
    fn generate_managed_backlog_from_verify_should_backfill_selector_from_previous_backlog() {
        let dir = tempfile::tempdir().unwrap();
        write_json(
            &dir.path().join("cycle.jsonc"),
            serde_json::json!({ "cycle_id": "c-4" }),
        );
        write_json(
            &dir.path().join("plan.jsonc"),
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_general",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        write_managed_backlog_files(
            dir.path(),
            "c-4",
            1,
            vec![serde_json::json!({
                "id": "fb-1",
                "source_criteria_id": "ac-1",
                "source_check_id": "v-1",
                "work_item_id": "w-1",
                "implementation_stage_kind": "implement_general",
                "requirement_ref": "legacy-ref",
                "description": "old",
                "created_at": "2026-03-02T00:00:00Z",
                "updated_at": "2026-03-02T00:00:00Z"
            })],
            vec![serde_json::json!({
                "backlog_id": "fb-1",
                "source_criteria_id": "ac-1",
                "source_check_id": "v-1",
                "work_item_id": "w-1",
                "implementation_stage_kind": "implement_general",
                "status": "not_done",
                "evidence": null,
                "notes": "",
                "updated_at": "2026-03-02T00:00:00Z"
            })],
        );
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "adjudication": {
                    "full_next_iteration_requirements": [{
                        "requirement_id": "fb-1",
                        "id": "fb-1",
                        "description": "use previous selector"
                    }]
                }
            }),
        );
        EvolutionManager::generate_managed_backlog_from_verify(dir.path(), 2)
            .expect("应可从上一轮 backlog 回填 selector");
        let backlog = super::read_json_file(dir.path(), "managed.backlog.jsonc")
            .expect("managed backlog should exist");
        let item = &backlog["items"][0];
        assert_eq!(item["source_criteria_id"], serde_json::json!("ac-1"));
        assert_eq!(item["source_check_id"], serde_json::json!("v-1"));
        assert_eq!(item["work_item_id"], serde_json::json!("w-1"));
        assert_eq!(
            item["implementation_stage_kind"],
            serde_json::json!("general")
        );
    }

    #[test]
    fn generate_managed_backlog_from_verify_should_reject_unresolved_selector() {
        let dir = tempfile::tempdir().unwrap();
        write_json(
            &dir.path().join("cycle.jsonc"),
            serde_json::json!({ "cycle_id": "c-5" }),
        );
        write_json(
            &dir.path().join("plan.jsonc"),
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
                    "implementation_stage_kind": "implement_general",
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
                    "implementation_stage_kind": "implement_general",
                    "linked_check_ids": ["v-2"]
                }),
            ]),
        );
        write_json(
            &dir.path().join("verify.jsonc"),
            serde_json::json!({
                "adjudication": {
                    "full_next_iteration_requirements": [{
                        "id": "opaque-only"
                    }]
                }
            }),
        );
        let err = EvolutionManager::generate_managed_backlog_from_verify(dir.path(), 1)
            .expect_err("无法映射 selector 时应失败");
        assert!(err.contains("source_criteria_id"));
    }

    // WI-003: 阶段产物契约校验测试
    #[test]
    fn stage_artifact_contract_validation_schema_version_should_reject_wrong_version() {
        use super::super::consts::STAGE_ARTIFACT_REQUIRED_SCHEMA_VERSION;
        let value = serde_json::json!({ "$schema_version": "1.0" });
        let result =
            ensure_schema_version("test.jsonc", &value, STAGE_ARTIFACT_REQUIRED_SCHEMA_VERSION);
        assert!(result.is_err(), "版本不符应返回错误");
        let err = result.unwrap_err();
        assert!(err.contains("$schema_version"), "错误应包含字段名: {}", err);
        assert!(
            err.contains(STAGE_ARTIFACT_REQUIRED_SCHEMA_VERSION),
            "错误应包含期望版本: {}",
            err
        );
    }

    #[test]
    fn stage_artifact_contract_validation_schema_version_should_accept_correct_version() {
        use super::super::consts::STAGE_ARTIFACT_REQUIRED_SCHEMA_VERSION;
        let value = serde_json::json!({ "$schema_version": "2.0" });
        let result =
            ensure_schema_version("test.jsonc", &value, STAGE_ARTIFACT_REQUIRED_SCHEMA_VERSION);
        assert!(result.is_ok(), "版本正确应通过: {:?}", result);
    }

    #[test]
    fn stage_artifact_contract_validation_schema_version_should_reject_missing_field() {
        use super::super::consts::STAGE_ARTIFACT_REQUIRED_SCHEMA_VERSION;
        let value = serde_json::json!({ "stage": "plan" });
        let result =
            ensure_schema_version("plan.jsonc", &value, STAGE_ARTIFACT_REQUIRED_SCHEMA_VERSION);
        assert!(result.is_err(), "缺少 $schema_version 应返回错误");
        let err = result.unwrap_err();
        assert!(err.contains("缺少"), "错误应说明字段缺失: {}", err);
    }

    #[test]
    fn stage_artifact_contract_validation_stage_field_should_detect_mismatch() {
        let value = serde_json::json!({ "stage": "plan" });
        let result =
            ensure_stage_field_matches("implement_general.jsonc", &value, "implement_general");
        assert!(result.is_err(), "stage 不符应返回错误");
        let err = result.unwrap_err();
        assert!(err.contains("stage"), "错误应包含 stage 字段名: {}", err);
    }

    #[test]
    fn stage_artifact_contract_validation_stage_field_should_accept_match() {
        let value = serde_json::json!({ "stage": "direction" });
        let result = ensure_stage_field_matches("direction.jsonc", &value, "direction");
        assert!(result.is_ok(), "stage 匹配应通过: {:?}", result);
    }

    #[test]
    fn stage_artifact_contract_validation_direction_should_reject_wrong_schema() {
        let dir = tempdir().expect("tempdir should be created");
        let file = dir.path().join("direction.jsonc");
        std::fs::write(
            &file,
            r#"{
  "$schema_version": "1.0",
  "stage": "direction",
  "cycle_id": "test-cycle",
  "status": "completed",
  "direction_statement": "测试方向",
  "updated_at": "2026-01-01T00:00:00Z"
}"#,
        )
        .unwrap();
        let result = EvolutionManager::validate_direction_artifact(dir.path(), None);
        assert!(result.is_err(), "旧版 schema_version 应被拒绝");
        let err_msg = result.unwrap_err().to_stage_error();
        assert!(
            err_msg.contains("$schema_version"),
            "错误应提及 schema_version: {}",
            err_msg
        );
    }

    // WI-004: 结构化错误日志测试
    #[test]
    fn evolution_structured_error_logging_should_not_panic_with_empty_fields() {
        // 验证结构化日志 helper 以空字段调用不会 panic
        log_evolution_error("", "", "", "");
        log_evolution_error("cycle-001", "direction", "evo_test_error", "测试错误消息");
    }

    #[test]
    fn evolution_structured_error_logging_should_accept_unicode_message() {
        // 验证 Unicode 错误消息可正常记录
        log_evolution_error(
            "2026-03-06T16-59-43-008Z",
            "implement_general",
            "evo_stage_failed",
            "空项目/配置缺失/网络中断均可结构化输出：校验失败 $schema_version 不匹配",
        );
    }

    // WI-005: 边界场景恢复测试
    #[test]
    fn evolution_boundary_recovery_empty_workspace_should_return_structured_error() {
        let result = check_workspace_boundary("", "cycle-001");
        assert!(result.is_err(), "空 workspace_root 应返回错误");
        let err = result.unwrap_err();
        assert!(
            err.contains("evo_boundary_empty_project"),
            "错误码应包含 evo_boundary_empty_project: {}",
            err
        );
    }

    #[test]
    fn evolution_boundary_recovery_missing_workspace_root_should_return_structured_error() {
        let result = check_workspace_boundary("/nonexistent/path/that/does/not/exist", "cycle-001");
        assert!(result.is_err(), "不存在的 workspace_root 应返回错误");
        let err = result.unwrap_err();
        assert!(
            err.contains("evo_boundary_workspace_missing"),
            "错误码应包含 evo_boundary_workspace_missing: {}",
            err
        );
    }

    #[test]
    fn evolution_boundary_recovery_missing_cycle_dir_should_return_structured_error() {
        let dir = tempdir().expect("tempdir should be created");
        let result = check_workspace_boundary(dir.path().to_str().unwrap(), "nonexistent-cycle");
        assert!(result.is_err(), "cycle 目录不存在应返回错误");
        let err = result.unwrap_err();
        assert!(
            err.contains("evo_boundary_cycle_dir_missing"),
            "错误码应包含 evo_boundary_cycle_dir_missing: {}",
            err
        );
    }

    #[test]
    fn evolution_boundary_recovery_valid_workspace_should_pass() {
        let dir = tempdir().expect("tempdir should be created");
        let cycle_id = "2026-03-06T16-59-43-008Z";
        let cycle_dir = dir
            .path()
            .join(".tidyflow")
            .join("evolution")
            .join(cycle_id);
        std::fs::create_dir_all(&cycle_dir).unwrap();
        let result = check_workspace_boundary(dir.path().to_str().unwrap(), cycle_id);
        assert!(result.is_ok(), "有效工作区应通过边界检查: {:?}", result);
    }

    #[test]
    fn ensure_artifact_freshness_should_pass_when_updated_at_is_absent() {
        // 系统会自动注入 updated_at，代理未提供时不应报错
        let value = serde_json::json!({
            "cycle_id": "c-1",
            "stage": "implement_general",
            "status": "done"
        });
        let started_at = Some(Utc::now() - chrono::Duration::seconds(10));
        let result = super::ensure_artifact_freshness("test.jsonc", &value, started_at);
        assert!(result.is_ok(), "缺少 updated_at 时不应报错: {:?}", result);
    }

    #[test]
    fn ensure_artifact_freshness_should_pass_when_started_at_is_none() {
        // 无阶段开始时间时跳过校验
        let value = serde_json::json!({"updated_at": "2020-01-01T00:00:00Z"});
        let result = super::ensure_artifact_freshness("test.jsonc", &value, None);
        assert!(
            result.is_ok(),
            "started_at 为 None 时应跳过校验: {:?}",
            result
        );
    }

    #[test]
    fn ensure_artifact_freshness_should_fail_when_updated_at_is_before_stage_start() {
        // updated_at 早于阶段开始时间应报错
        let old_ts = "2020-01-01T00:00:00Z";
        let value = serde_json::json!({"updated_at": old_ts});
        let started_at = Some(Utc::now());
        let result = super::ensure_artifact_freshness("test.jsonc", &value, started_at);
        assert!(
            result.is_err(),
            "updated_at 早于阶段开始时间应返回 Err: {:?}",
            result
        );
        let msg = result.unwrap_err();
        assert!(
            msg.contains("时间戳早于本次阶段开始时间"),
            "错误信息应包含时间戳说明: {}",
            msg
        );
    }

    #[test]
    fn ensure_artifact_freshness_should_pass_with_fresh_updated_at() {
        // updated_at 在阶段开始之后应通过
        let future_ts = (Utc::now() + chrono::Duration::seconds(1)).to_rfc3339();
        let value = serde_json::json!({"updated_at": future_ts});
        let started_at = Some(Utc::now() - chrono::Duration::seconds(5));
        let result = super::ensure_artifact_freshness("test.jsonc", &value, started_at);
        assert!(result.is_ok(), "新鲜的 updated_at 应通过校验: {:?}", result);
    }

    // WI-004 (CHK-002): 验证系统对全部 7 类阶段产物均能自动注入/覆盖 updated_at
    #[test]
    fn validate_stage_artifacts_should_auto_inject_updated_at_for_all_stage_files() {
        use super::super::utils::inject_stage_artifact_updated_at;

        let stage_files = [
            "direction.jsonc",
            "plan.jsonc",
            "implement_general.jsonc",
            "implement_visual.jsonc",
            "implement_advanced.jsonc",
            "verify.jsonc",
            "auto_commit.jsonc",
        ];

        let dir = tempdir().expect("tempdir should be created");

        for file_name in &stage_files {
            let path = dir.path().join(file_name);
            // 写入旧时间戳（2020 年），期望被系统覆盖为当前时间
            std::fs::write(
                &path,
                r#"{"cycle_id":"c-1","stage":"test","updated_at":"2020-01-01T00:00:00Z"}"#,
            )
            .unwrap_or_else(|_| panic!("写入 {} 失败", file_name));

            inject_stage_artifact_updated_at(&path)
                .unwrap_or_else(|e| panic!("{} 注入失败: {}", file_name, e));

            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|_| panic!("读取 {} 失败", file_name));
            let value: serde_json::Value = serde_json::from_str(&content)
                .unwrap_or_else(|_| panic!("解析 {} 失败", file_name));
            let updated_at = value["updated_at"].as_str().unwrap_or("");

            assert!(!updated_at.is_empty(), "updated_at 不能为空: {}", file_name);
            let parsed = chrono::DateTime::parse_from_rfc3339(updated_at).unwrap_or_else(|_| {
                panic!(
                    "{} 的 updated_at 必须是有效 RFC3339: {}",
                    file_name, updated_at
                )
            });
            let old_ts = chrono::DateTime::parse_from_rfc3339("2020-01-01T00:00:00Z").unwrap();
            assert!(
                parsed > old_ts,
                "注入的 updated_at 必须晚于旧时间戳 2020-01-01: {}",
                file_name
            );
        }
    }

    // WI-004 (CHK-003): 验证非法 JSON 或缺失必填字段时系统返回结构化报错
    #[test]
    fn validate_stage_artifacts_should_reject_invalid_json_or_missing_required_fields() {
        // Part 1: 非法 JSON（trailing comma）应被 read_json 拒绝
        {
            let dir = tempdir().expect("tempdir should be created");
            let path = dir.path().join("plan.jsonc");
            std::fs::write(&path, r#"{"cycle_id": "c-1", "status": "done",}"#)
                .expect("写入非法 JSON 文件");

            let result = super::super::utils::read_json(&path);
            assert!(result.is_err(), "trailing comma 的非法 JSON 应被拒绝");
            let err = result.unwrap_err();
            assert!(err.contains("解析"), "错误应来自 JSON 解析阶段: {}", err);
        }

        // Part 2: implement_general.jsonc 缺少 quick_checks 数组字段应被 schema 校验拒绝
        {
            let dir = tempdir().expect("tempdir should be created");
            write_json(
                &dir.path().join("implement_general.jsonc"),
                serde_json::json!({
                    "$schema_version": "2.0",
                    "stage": "implement_general",
                    "cycle_id": "c-1",
                    "verify_iteration": 0,
                    "status": "done",
                    "summary": "ok",
                    "work_item_results": [],
                    "changed_files": [],
                    "commands_executed": [],
                    // quick_checks 故意缺失，期望 schema 校验报错
                    "updated_at": "2026-03-02T00:00:00Z"
                }),
            );

            let err =
                EvolutionManager::validate_stage_artifacts("implement_general", dir.path(), 0, 1)
                    .expect_err("缺少 quick_checks 应被 schema 校验拒绝");
            assert!(
                err.contains("quick_checks"),
                "错误信息应提及缺失字段 quick_checks: {}",
                err
            );
        }

        // Part 3: direction.jsonc 缺少 direction_statement 必填字段应被 schema 校验拒绝
        {
            let dir = tempdir().expect("tempdir should be created");
            write_json(
                &dir.path().join("direction.jsonc"),
                serde_json::json!({
                    "$schema_version": "2.0",
                    "stage": "direction",
                    "cycle_id": "c-1",
                    "status": "done",
                    // direction_statement 故意缺失
                    "updated_at": "2026-03-02T00:00:00Z"
                }),
            );

            let err = EvolutionManager::validate_stage_artifacts("direction", dir.path(), 0, 1)
                .expect_err("缺少 direction_statement 应被 schema 校验拒绝");
            assert!(
                err.contains("direction_statement"),
                "错误信息应提及缺失字段 direction_statement: {}",
                err
            );
        }
    }
}
