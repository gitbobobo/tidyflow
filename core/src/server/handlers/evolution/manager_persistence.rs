use std::collections::HashSet;
use std::path::{Path, PathBuf};

use chrono::Utc;

use super::consts::{
    compare_runtime_stage_names, parse_implement_stage_instance, parse_reimplement_stage_instance,
    reimplement_stage_name, stage_artifact_file, ImplementationStageKind,
};
use super::stage::{agent_name, prompt_id_for_stage, prompt_template_for_stage};
use super::utils::{
    cycle_dir_path, evolution_workspace_dir, read_json, sanitize_validation_attempts, write_json,
};
use super::{EvolutionManager, StageSession, STAGES};

fn stage_artifact_path(cycle_dir: &Path, stage: &str) -> PathBuf {
    stage_artifact_file(stage)
        .map(|file| cycle_dir.join(file))
        .unwrap_or_else(|| cycle_dir.join("unknown.jsonc"))
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

fn collect_session_ids(sessions: &[StageSession]) -> Vec<String> {
    let mut session_ids: Vec<String> = Vec::new();
    for session in sessions {
        if !session_ids.iter().any(|sid| sid == &session.session_id) {
            session_ids.push(session.session_id.clone());
        }
    }
    session_ids
}

#[allow(dead_code)]
fn merge_stage_payload(
    existing: Option<serde_json::Value>,
    cycle_id: &str,
    stage: &str,
    status: &str,
    error_message: Option<&str>,
    verify_result: Option<bool>,
    ai_tool: Option<&str>,
    stage_duration_ms: Option<u64>,
    chat_sessions: serde_json::Value,
    session_executions: serde_json::Value,
    now_rfc3339: &str,
) -> serde_json::Value {
    let mut payload = existing.unwrap_or_else(|| serde_json::json!({}));
    if !payload.is_object() {
        payload = serde_json::json!({});
    }
    let obj = payload
        .as_object_mut()
        .expect("payload must be JSON object after normalization");

    obj.insert(
        "$schema_version".to_string(),
        serde_json::Value::String("1.0".to_string()),
    );
    obj.insert(
        "cycle_id".to_string(),
        serde_json::Value::String(cycle_id.to_string()),
    );
    obj.insert(
        "stage".to_string(),
        serde_json::Value::String(stage.to_string()),
    );
    obj.insert(
        "agent".to_string(),
        serde_json::Value::String(agent_name(stage).to_string()),
    );
    obj.insert(
        "status".to_string(),
        serde_json::Value::String(status.to_string()),
    );
    if let Some(ai_tool) = ai_tool.filter(|v| !v.trim().is_empty()) {
        obj.insert(
            "ai_tool".to_string(),
            serde_json::Value::String(ai_tool.to_string()),
        );
    }

    if !obj.get("inputs").map(|v| v.is_array()).unwrap_or(false) {
        obj.insert(
            "inputs".to_string(),
            serde_json::json!([{
                "type": "prompt",
                "path": prompt_id_for_stage(stage).unwrap_or_default()
            }]),
        );
    }

    if !obj.get("outputs").map(|v| v.is_array()).unwrap_or(false) {
        obj.insert("outputs".to_string(), chat_sessions.clone());
    }

    if !obj.get("decision").map(|v| v.is_object()).unwrap_or(false) {
        obj.insert(
            "decision".to_string(),
            serde_json::json!({
                "result": if stage == "verify" && status == "done" {
                    if verify_result.unwrap_or(true) { "pass" } else { "fail" }
                } else {
                    "n/a"
                },
                "reason": ""
            }),
        );
    }

    if stage == "verify" && status == "done" {
        if let Some(decision_obj) = obj.get_mut("decision").and_then(|v| v.as_object_mut()) {
            if !decision_obj
                .get("result")
                .and_then(|v| v.as_str())
                .map(|v| !v.trim().is_empty())
                .unwrap_or(false)
            {
                decision_obj.insert(
                    "result".to_string(),
                    serde_json::Value::String(if verify_result.unwrap_or(true) {
                        "pass".to_string()
                    } else {
                        "fail".to_string()
                    }),
                );
            }
        }
    }

    // 阶段编排由系统负责，新产物不再保留历史 next_action 字段。
    obj.remove("next_action");

    if !obj.get("timing").map(|v| v.is_object()).unwrap_or(false) {
        obj.insert("timing".to_string(), serde_json::json!({}));
    }
    if let Some(timing_obj) = obj.get_mut("timing").and_then(|v| v.as_object_mut()) {
        if !timing_obj
            .get("started_at")
            .and_then(|v| v.as_str())
            .map(|v| !v.trim().is_empty())
            .unwrap_or(false)
        {
            timing_obj.insert(
                "started_at".to_string(),
                serde_json::Value::String(now_rfc3339.to_string()),
            );
        }
        if status == "done" {
            timing_obj.insert(
                "completed_at".to_string(),
                serde_json::Value::String(now_rfc3339.to_string()),
            );
            let duration_ms = stage_duration_ms
                .or_else(|| timing_obj.get("duration_ms").and_then(|v| v.as_u64()))
                .or_else(|| {
                    timing_obj
                        .get("started_at")
                        .and_then(|v| v.as_str())
                        .map(|v| v.trim())
                        .filter(|v| !v.is_empty())
                        .and_then(|started| {
                            let start = chrono::DateTime::parse_from_rfc3339(started).ok()?;
                            let end = chrono::DateTime::parse_from_rfc3339(now_rfc3339).ok()?;
                            let elapsed = end.signed_duration_since(start).num_milliseconds();
                            if elapsed >= 0 {
                                Some(elapsed as u64)
                            } else {
                                None
                            }
                        })
                });
            if let Some(duration_ms) = duration_ms {
                timing_obj.insert("duration_ms".to_string(), serde_json::json!(duration_ms));
            } else if !timing_obj.contains_key("duration_ms") {
                timing_obj.insert("duration_ms".to_string(), serde_json::Value::Null);
            }
        } else {
            if !timing_obj.contains_key("completed_at") {
                timing_obj.insert(
                    "completed_at".to_string(),
                    serde_json::Value::String(String::new()),
                );
            }
            if !timing_obj.contains_key("duration_ms") {
                timing_obj.insert("duration_ms".to_string(), serde_json::Value::Null);
            }
        }
    }

    match error_message {
        Some(message) => {
            obj.insert(
                "error".to_string(),
                serde_json::json!({ "message": message }),
            );
        }
        None => {
            if !obj.contains_key("error") {
                obj.insert("error".to_string(), serde_json::Value::Null);
            }
        }
    }

    let mut system_metadata = obj
        .remove("system_metadata")
        .filter(|v| v.is_object())
        .unwrap_or_else(|| serde_json::json!({}));
    if let Some(system_obj) = system_metadata.as_object_mut() {
        system_obj.insert("chat_sessions".to_string(), chat_sessions);
        system_obj.insert("session_executions".to_string(), session_executions);
        system_obj.insert(
            "updated_at".to_string(),
            serde_json::Value::String(now_rfc3339.to_string()),
        );
    }
    obj.insert("system_metadata".to_string(), system_metadata);

    payload
}

fn build_prompt_context(
    project: &str,
    workspace: &str,
    cycle_id: &str,
    stage: &str,
    round: u32,
    verify_iteration: u32,
    verify_iteration_limit: u32,
    backlog_contract_version: u32,
    cycle_dir: &Path,
    workspace_root: &str,
) -> serde_json::Value {
    let implement_kind = implementation_stage_kind_for_stage(stage)
        .map(|kind| kind.as_str().to_string())
        .unwrap_or_default();
    serde_json::json!({
        "PROJECT": project,
        "WORKSPACE": workspace,
        "CYCLE_ID": cycle_id,
        "GLOBAL_LOOP_ROUND": round,
        "CURRENT_STAGE": stage,
        "VERIFY_ITERATION": verify_iteration,
        "VERIFY_ITERATION_LIMIT": verify_iteration_limit,
        "BACKLOG_CONTRACT_VERSION": backlog_contract_version,
        "CYCLE_DIR": cycle_dir,
        "CYCLE_FILE_PATH": cycle_dir.join("cycle.jsonc"),
        "CURRENT_STAGE_ARTIFACT_PATH": stage_artifact_path(cycle_dir, stage),
        "DIRECTION_ARTIFACT_PATH": stage_artifact_path(cycle_dir, "direction"),
        "PLAN_ARTIFACT_PATH": stage_artifact_path(cycle_dir, "plan"),
        "PLAN_MARKDOWN_PATH": cycle_dir.join("plan.md"),
        "VERIFY_ARTIFACT_PATH": stage_artifact_path(cycle_dir, "verify"),
        "AUTO_COMMIT_ARTIFACT_PATH": stage_artifact_path(cycle_dir, "auto_commit"),
        "LAST_REIMPLEMENT_ARTIFACT_PATH": if verify_iteration > 0 {
            stage_artifact_path(cycle_dir, &reimplement_stage_name(verify_iteration))
        } else {
            cycle_dir.join("reimplement.none.jsonc")
        },
        "IMPLEMENT_STAGE_KIND": implement_kind,
        "TASKS_TO_COMPLETE": "",
        "REPAIR_ITEMS_TO_COMPLETE": "",
        "ENV_CONTRACT_PATH": evolution_workspace_dir(workspace_root)
            .map(|p| p.join("env.contract.jsonc"))
            .unwrap_or_else(|_| Path::new("env.contract.jsonc").to_path_buf()),
        "ENV_VALUES_LOCAL_PATH": evolution_workspace_dir(workspace_root)
            .map(|p| p.join("env.values.local.jsonc"))
            .unwrap_or_else(|_| Path::new("env.values.local.jsonc").to_path_buf()),
        "WORKSPACE_ROOT": "由程序注入，禁止自行推断",
    })
}

fn push_required_key(keys: &mut Vec<&'static str>, key: &'static str) {
    if !keys.iter().any(|existing| *existing == key) {
        keys.push(key);
    }
}

fn required_context_keys(
    stage: &str,
    verify_iteration: u32,
    _backlog_contract_version: u32,
) -> Vec<&'static str> {
    let mut keys = vec![
        "PROJECT",
        "WORKSPACE",
        "CYCLE_ID",
        "CURRENT_STAGE",
        "GLOBAL_LOOP_ROUND",
        "VERIFY_ITERATION",
        "VERIFY_ITERATION_LIMIT",
        "BACKLOG_CONTRACT_VERSION",
        "CYCLE_FILE_PATH",
        "CURRENT_STAGE_ARTIFACT_PATH",
    ];

    match stage {
        "direction" => {}
        "plan" => {
            push_required_key(&mut keys, "DIRECTION_ARTIFACT_PATH");
            push_required_key(&mut keys, "PLAN_MARKDOWN_PATH");
        }
        "verify" => {
            push_required_key(&mut keys, "DIRECTION_ARTIFACT_PATH");
            push_required_key(&mut keys, "PLAN_ARTIFACT_PATH");
            push_required_key(&mut keys, "PLAN_MARKDOWN_PATH");
            if verify_iteration > 0 {
                push_required_key(&mut keys, "LAST_REIMPLEMENT_ARTIFACT_PATH");
            }
        }
        "auto_commit" => {
            push_required_key(&mut keys, "PLAN_MARKDOWN_PATH");
            push_required_key(&mut keys, "VERIFY_ARTIFACT_PATH");
        }
        _ if implementation_stage_kind_for_stage(stage).is_some() => {
            push_required_key(&mut keys, "DIRECTION_ARTIFACT_PATH");
            push_required_key(&mut keys, "PLAN_ARTIFACT_PATH");
            push_required_key(&mut keys, "PLAN_MARKDOWN_PATH");
            push_required_key(&mut keys, "IMPLEMENT_STAGE_KIND");
            push_required_key(&mut keys, "TASKS_TO_COMPLETE");
        }
        _ if parse_reimplement_stage_instance(stage).is_some() => {
            push_required_key(&mut keys, "DIRECTION_ARTIFACT_PATH");
            push_required_key(&mut keys, "PLAN_ARTIFACT_PATH");
            push_required_key(&mut keys, "PLAN_MARKDOWN_PATH");
            push_required_key(&mut keys, "VERIFY_ARTIFACT_PATH");
            push_required_key(&mut keys, "REPAIR_ITEMS_TO_COMPLETE");
        }
        _ => {}
    }

    if implementation_stage_kind_for_stage(stage).is_some() && verify_iteration > 0 {
        push_required_key(&mut keys, "VERIFY_ARTIFACT_PATH");
    }

    keys
}

fn format_context_value(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::String(raw) => raw.clone(),
        serde_json::Value::Number(raw) => raw.to_string(),
        serde_json::Value::Bool(raw) => raw.to_string(),
        serde_json::Value::Null => "null".to_string(),
        other => serde_json::to_string(other).unwrap_or_else(|_| "<unserializable>".to_string()),
    }
}

fn escape_inline_code(raw: &str) -> String {
    raw.replace('`', "\\`").replace('\n', "\\n")
}

fn build_markdown_context_block(
    context_map: &serde_json::Map<String, serde_json::Value>,
    required_keys: &[&'static str],
    already_injected_keys: &HashSet<String>,
) -> (String, HashSet<String>) {
    let mut lines = vec!["## 注入上下文（按需）".to_string()];
    let mut injected = HashSet::new();

    for key in required_keys {
        if already_injected_keys.contains(*key) {
            continue;
        }
        let Some(value) = context_map.get(*key) else {
            continue;
        };
        let rendered = format_context_value(value);
        if rendered.contains('\n') {
            lines.push(format!("- `{}`：", key));
            lines.push("```text".to_string());
            lines.push(rendered);
            lines.push("```".to_string());
        } else {
            lines.push(format!("- `{}`：`{}`", key, escape_inline_code(&rendered)));
        }
        injected.insert((*key).to_string());
    }

    if injected.is_empty() {
        lines.push("- 本次无新增上下文，沿用当前会话已注入内容。".to_string());
    }

    (lines.join("\n"), injected)
}

impl EvolutionManager {
    pub(super) async fn persist_cycle_file(&self, key: &str) -> Result<(), String> {
        let state = self.state.lock().await;
        let Some(entry) = state.workspaces.get(key) else {
            return Ok(());
        };
        let cycle_dir = cycle_dir_path(&entry.workspace_root, &entry.cycle_id)?;
        std::fs::create_dir_all(&cycle_dir).map_err(|e| e.to_string())?;
        let existing_cycle = read_json(&cycle_dir.join("cycle.jsonc")).ok();

        let mut stage_runtime = serde_json::Map::new();
        let preserved_stage_runtime = existing_cycle
            .as_ref()
            .and_then(|value| value.get("stage_runtime"))
            .and_then(|value| value.as_object())
            .cloned()
            .unwrap_or_default();
        let mut pipeline: Vec<String> = STAGES.iter().map(|stage| (*stage).to_string()).collect();
        let mut extra_stages: Vec<String> = entry
            .stage_statuses
            .keys()
            .filter(|stage| !STAGES.contains(&stage.as_str()))
            .cloned()
            .collect();
        pipeline.append(&mut extra_stages);
        pipeline.sort_by(|left, right| compare_runtime_stage_names(left, right));
        pipeline.dedup();

        for stage in &pipeline {
            let session_ids = entry
                .stage_session_history
                .get(stage.as_str())
                .map(|items| collect_session_ids(items))
                .unwrap_or_default();
            let latest_ai_tool = entry
                .stage_session_history
                .get(stage.as_str())
                .and_then(|items| items.last())
                .map(|item| item.ai_tool.clone())
                .unwrap_or_default();
            let started_at = entry
                .stage_started_ats
                .get(stage.as_str())
                .cloned()
                .unwrap_or_default();
            let completed_at = entry
                .session_executions
                .iter()
                .rev()
                .find(|item| item.stage == *stage && item.completed_at.is_some())
                .and_then(|item| item.completed_at.clone());
            let duration_ms = entry
                .stage_duration_ms
                .get(stage.as_str())
                .copied()
                .or_else(|| {
                    entry
                        .session_executions
                        .iter()
                        .rev()
                        .find(|item| item.stage == *stage)
                        .and_then(|item| item.duration_ms)
                });
            let preserved_stage_entry = preserved_stage_runtime.get(stage.as_str());
            let validation_attempts =
                sanitize_validation_attempts(preserved_stage_entry.and_then(|value| value.get("validation_attempts")));
            let mut stage_payload = serde_json::json!({
                    "status": entry.stage_statuses.get(stage.as_str()).cloned().unwrap_or_else(|| "pending".to_string()),
                    "ai_tool": latest_ai_tool,
                    "timing": {
                        "started_at": started_at,
                        "completed_at": completed_at,
                        "duration_ms": duration_ms,
                    },
                    "tool_call_count": entry.stage_tool_call_counts.get(stage.as_str()).copied().unwrap_or(0),
                    "session_ids": session_ids,
                    "validation_attempts": validation_attempts,
                });
            if let Some(assigned_repair_plan) = preserved_stage_entry
                .and_then(|value| value.get("assigned_repair_plan"))
                .cloned()
            {
                if let Some(stage_payload_obj) = stage_payload.as_object_mut() {
                    stage_payload_obj.insert("assigned_repair_plan".to_string(), assigned_repair_plan);
                }
            }
            stage_runtime.insert(stage.to_string(), stage_payload);
        }

        let payload = serde_json::json!({
            "$schema_version": "2.0",
            "cycle_id": entry.cycle_id,
            "project": entry.project,
            "workspace": entry.workspace,
            "title": entry.cycle_title.clone(),
            "status": entry.status,
            "current_stage": entry.current_stage,
            "pipeline": pipeline,
            "verify_iteration": entry.verify_iteration,
            "verify_iteration_limit": entry.verify_iteration_limit,
            "backlog_contract_version": entry.backlog_contract_version,
            "global_loop_round": entry.global_loop_round,
            "loop_round_limit": entry.loop_round_limit,
            "interrupt": {
                "requested": entry.stop_requested,
                "requested_by": if entry.stop_requested { "user" } else { "" },
                "requested_at": if entry.stop_requested { Utc::now().to_rfc3339() } else { "".to_string() },
                "reason": if entry.stop_requested { "manual stop" } else { "" }
            },
            "stage_runtime": stage_runtime,
            "executions": entry.session_executions.clone(),
            "terminal_reason_code": entry.terminal_reason_code.clone(),
            "terminal_error_message": entry.terminal_error_message.clone(),
            "rate_limit_recovery": {
                "resume_at": entry.rate_limit_resume_at.clone(),
                "last_error": entry.rate_limit_error_message.clone(),
            },
            "created_at": entry.created_at.clone(),
            "updated_at": Utc::now().to_rfc3339(),
        });

        write_json(&cycle_dir.join("cycle.jsonc"), &payload)
    }

    pub(super) async fn persist_stage_file(
        &self,
        key: &str,
        stage: &str,
        status: &str,
        error_message: Option<&str>,
        _verify_result: Option<bool>,
    ) -> Result<(), String> {
        let (workspace_root, cycle_id) = {
            let state = self.state.lock().await;
            let Some(entry) = state.workspaces.get(key) else {
                return Ok(());
            };
            (entry.workspace_root.clone(), entry.cycle_id.clone())
        };
        self.persist_cycle_file(key).await?;
        let cycle_dir = cycle_dir_path(&workspace_root, &cycle_id)?;
        let cycle_file = cycle_dir.join("cycle.jsonc");
        let mut value = read_json(&cycle_file).unwrap_or_else(|_| serde_json::json!({}));
        let Some(runtime_obj) = value
            .get_mut("stage_runtime")
            .and_then(|runtime| runtime.as_object_mut())
        else {
            return Ok(());
        };
        let stage_entry = runtime_obj
            .entry(stage.to_string())
            .or_insert_with(|| serde_json::json!({}));
        if let Some(stage_obj) = stage_entry.as_object_mut() {
            stage_obj.insert("status".to_string(), serde_json::json!(status));
            match error_message {
                Some(message) => {
                    stage_obj.insert(
                        "error".to_string(),
                        serde_json::json!({ "message": message }),
                    );
                }
                None => {
                    stage_obj.remove("error");
                }
            }
        }
        write_json(&cycle_file, &value)
    }

    pub(super) async fn persist_chat_map(&self, key: &str) -> Result<(), String> {
        self.persist_cycle_file(key).await
    }

    pub(super) async fn build_stage_prompt(
        &self,
        key: &str,
        project: &str,
        workspace: &str,
        cycle_id: &str,
        stage: &str,
        round: u32,
        already_injected_keys: &HashSet<String>,
    ) -> Result<(String, HashSet<String>), String> {
        let prompt_body = prompt_template_for_stage(stage)
            .ok_or_else(|| format!("unknown stage prompt template: {}", stage))?;

        let (verify_iteration, verify_iteration_limit, backlog_contract_version, workspace_root) = {
            let state = self.state.lock().await;
            let Some(entry) = state.workspaces.get(key) else {
                return Err("workspace state missing".to_string());
            };
            (
                entry.verify_iteration,
                entry.verify_iteration_limit,
                entry.backlog_contract_version,
                entry.workspace_root.clone(),
            )
        };

        let cycle_dir = cycle_dir_path(&workspace_root, cycle_id)?;
        let context = build_prompt_context(
            project,
            workspace,
            cycle_id,
            stage,
            round,
            verify_iteration,
            verify_iteration_limit,
            backlog_contract_version,
            &cycle_dir,
            &workspace_root,
        );
        let mut context_map = context
            .as_object()
            .cloned()
            .ok_or_else(|| "prompt context should be JSON object".to_string())?;
        if parse_implement_stage_instance(stage).is_some() {
            let tasks = Self::tasks_to_complete_for_stage(&cycle_dir, stage)?;
            context_map.insert(
                "TASKS_TO_COMPLETE".to_string(),
                serde_json::Value::String(tasks),
            );
        }
        if parse_reimplement_stage_instance(stage).is_some() {
            let issues = Self::repair_items_to_complete_for_stage(&cycle_dir, stage)?;
            context_map.insert(
                "REPAIR_ITEMS_TO_COMPLETE".to_string(),
                serde_json::Value::String(issues),
            );
        }
        let required_keys =
            required_context_keys(stage, verify_iteration, backlog_contract_version);
        let (markdown_context, injected_keys) =
            build_markdown_context_block(&context_map, &required_keys, already_injected_keys);

        Ok((
            format!("{}\n\n---\n\n{}\n", prompt_body, markdown_context),
            injected_keys,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::super::utils::inject_stage_artifact_updated_at;
    use super::{
        build_markdown_context_block, build_prompt_context, collect_session_ids,
        merge_stage_payload, required_context_keys, StageSession,
    };
    use std::collections::HashSet;
    use std::path::Path;
    use tempfile::tempdir;

    #[test]
    fn collect_session_ids_should_keep_order_and_dedup() {
        let sessions = vec![
            StageSession {
                ai_tool: "codex".to_string(),
                session_id: "session-1".to_string(),
            },
            StageSession {
                ai_tool: "codex".to_string(),
                session_id: "session-1".to_string(),
            },
            StageSession {
                ai_tool: "codex".to_string(),
                session_id: "session-2".to_string(),
            },
        ];
        let session_ids = collect_session_ids(&sessions);
        assert_eq!(
            session_ids,
            vec!["session-1".to_string(), "session-2".to_string()]
        );
    }

    #[test]
    fn merge_stage_payload_should_preserve_agent_decision_and_drop_legacy_next_action() {
        let existing = serde_json::json!({
            "$schema_version": "1.0",
            "cycle_id": "cycle-a",
            "stage": "verify",
            "agent": "VerifyAgent",
            "status": "done",
            "decision": {
                "result": "fail",
                "reason": "agent decided by evidence"
            },
            "next_action": {
                "type": "stop_cycle",
                "target": null
            },
            "outputs": [{"type": "file", "path": "verify.jsonc"}]
        });
        let merged = merge_stage_payload(
            Some(existing),
            "cycle-a",
            "verify",
            "done",
            None,
            Some(false),
            Some("codex"),
            Some(1234),
            serde_json::json!([{
                "type": "chat_session",
                "session_id": "session-1",
                "session_ids": ["session-1"]
            }]),
            serde_json::json!([{
                "session_id": "session-1",
                "status": "done"
            }]),
            "2026-02-27T00:00:00Z",
        );

        assert_eq!(merged["decision"]["reason"], "agent decided by evidence");
        assert!(
            merged.get("next_action").is_none(),
            "legacy next_action should be removed from merged payload"
        );
        assert_eq!(
            merged["system_metadata"]["chat_sessions"][0]["session_id"],
            "session-1"
        );
        assert_eq!(
            merged["system_metadata"]["session_executions"][0]["session_id"],
            "session-1"
        );
        assert_eq!(merged["timing"]["duration_ms"], serde_json::json!(1234));
    }

    #[test]
    fn merge_stage_payload_should_overwrite_null_duration_when_done() {
        let existing = serde_json::json!({
            "timing": {
                "started_at": "2026-02-27T00:00:00Z",
                "duration_ms": null
            }
        });
        let merged = merge_stage_payload(
            Some(existing),
            "cycle-a",
            "verify",
            "done",
            None,
            None,
            Some("codex"),
            Some(3210),
            serde_json::json!([]),
            serde_json::json!([]),
            "2026-02-27T00:00:03Z",
        );
        assert_eq!(merged["timing"]["duration_ms"], serde_json::json!(3210));
    }

    #[test]
    fn build_prompt_context_should_include_explicit_result_paths() {
        let cycle_dir = Path::new("/tmp/tidyflow-cycle");
        let context = build_prompt_context(
            "demo",
            "default",
            "cycle-1",
            "implement.general.1",
            1,
            1,
            5,
            2,
            cycle_dir,
            "/tmp/workspace",
        );
        assert_eq!(
            context
                .get("BACKLOG_CONTRACT_VERSION")
                .and_then(|v| v.as_u64())
                .unwrap_or_default(),
            2
        );
        assert_eq!(
            context
                .get("CURRENT_STAGE_ARTIFACT_PATH")
                .and_then(|v| v.as_str())
                .unwrap_or_default(),
            "/tmp/tidyflow-cycle/implement.general.1.jsonc"
        );
        assert_eq!(
            context
                .get("LAST_REIMPLEMENT_ARTIFACT_PATH")
                .and_then(|v| v.as_str())
                .unwrap_or_default(),
            "/tmp/tidyflow-cycle/reimplement.1.jsonc"
        );
        assert_eq!(
            context
                .get("PLAN_ARTIFACT_PATH")
                .and_then(|v| v.as_str())
                .unwrap_or_default(),
            "/tmp/tidyflow-cycle/plan.jsonc"
        );
        assert_eq!(
            context
                .get("PLAN_MARKDOWN_PATH")
                .and_then(|v| v.as_str())
                .unwrap_or_default(),
            "/tmp/tidyflow-cycle/plan.md"
        );
        assert_eq!(
            context
                .get("IMPLEMENT_STAGE_KIND")
                .and_then(|v| v.as_str())
                .unwrap_or_default(),
            "general"
        );
        assert_eq!(
            context
                .get("VERIFY_ARTIFACT_PATH")
                .and_then(|v| v.as_str())
                .unwrap_or_default(),
            "/tmp/tidyflow-cycle/verify.jsonc"
        );
        assert_eq!(
            context
                .get("AUTO_COMMIT_ARTIFACT_PATH")
                .and_then(|v| v.as_str())
                .unwrap_or_default(),
            "/tmp/tidyflow-cycle/auto_commit.jsonc"
        );
    }

    #[test]
    fn required_context_keys_should_include_repair_plan_inputs_when_reimplementation_enabled() {
        let keys = required_context_keys("reimplement.1", 1, 2);
        assert!(keys.contains(&"REPAIR_ITEMS_TO_COMPLETE"));
        assert!(keys.contains(&"VERIFY_ARTIFACT_PATH"));
        assert!(keys.contains(&"PLAN_MARKDOWN_PATH"));
    }

    #[test]
    fn build_markdown_context_block_should_render_list_and_skip_already_injected() {
        let context = serde_json::json!({
            "PROJECT": "demo",
            "WORKSPACE": "default",
            "CYCLE_ID": "cycle-1"
        });
        let context_map = context.as_object().expect("context must be object");
        let required = vec!["PROJECT", "WORKSPACE", "CYCLE_ID"];
        let already = HashSet::from(["WORKSPACE".to_string()]);

        let (block, injected) = build_markdown_context_block(context_map, &required, &already);
        assert!(block.contains("## 注入上下文（按需）"));
        assert!(block.contains("- `PROJECT`：`demo`"));
        assert!(block.contains("- `CYCLE_ID`：`cycle-1`"));
        assert!(!block.contains("`WORKSPACE`"));
        assert!(injected.contains("PROJECT"));
        assert!(injected.contains("CYCLE_ID"));
        assert!(!injected.contains("WORKSPACE"));
    }

    #[test]
    fn build_markdown_context_block_should_emit_no_new_context_message() {
        let context = serde_json::json!({
            "PROJECT": "demo"
        });
        let context_map = context.as_object().expect("context must be object");
        let required = vec!["PROJECT"];
        let already = HashSet::from(["PROJECT".to_string()]);

        let (block, injected) = build_markdown_context_block(context_map, &required, &already);
        assert!(block.contains("本次无新增上下文"));
        assert!(injected.is_empty());
    }

    #[test]
    fn inject_stage_artifact_updated_at_should_write_valid_utc_rfc3339() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("implement_general.jsonc");
        std::fs::write(
            &path,
            r#"{"cycle_id":"cycle-1","stage":"implement_general","updated_at":""}"#,
        )
        .expect("write artifact");

        inject_stage_artifact_updated_at(&path).expect("inject should succeed");

        let value: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let updated_at = value["updated_at"].as_str().unwrap_or("");
        assert!(
            !updated_at.is_empty(),
            "updated_at should be non-empty after injection"
        );
        // 必须可解析为 RFC3339
        chrono::DateTime::parse_from_rfc3339(updated_at)
            .expect("injected updated_at must be valid RFC3339");
        // 其他字段不受影响
        assert_eq!(value["cycle_id"], "cycle-1");
        assert_eq!(value["stage"], "implement_general");
    }

    #[test]
    fn inject_stage_artifact_updated_at_should_overwrite_existing_timestamp() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("plan.jsonc");
        std::fs::write(
            &path,
            r#"{"cycle_id":"cycle-2","updated_at":"2020-01-01T00:00:00Z"}"#,
        )
        .expect("write artifact");

        inject_stage_artifact_updated_at(&path).expect("inject should succeed");

        let value: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let updated_at = value["updated_at"].as_str().unwrap_or("");
        let parsed = chrono::DateTime::parse_from_rfc3339(updated_at)
            .expect("injected updated_at must be valid RFC3339");
        // 注入时间必须晚于旧时间戳 2020-01-01
        let old_ts = chrono::DateTime::parse_from_rfc3339("2020-01-01T00:00:00Z").unwrap();
        assert!(parsed > old_ts, "injected timestamp should be newer");
    }

    #[test]
    fn inject_stage_artifact_updated_at_should_fail_for_missing_file() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("nonexistent.jsonc");
        let result = inject_stage_artifact_updated_at(&path);
        assert!(result.is_err(), "should fail when file does not exist");
    }
}
