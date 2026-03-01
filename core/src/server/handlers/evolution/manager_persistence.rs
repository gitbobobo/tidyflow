use std::path::Path;

use chrono::Utc;

use super::stage::{agent_name, next_stage, prompt_id_for_stage, prompt_template_for_stage};
use super::utils::{cycle_dir_path, evolution_workspace_dir, write_json};
use super::{EvolutionManager, StageSession, STAGES};

fn collect_session_ids(sessions: &[StageSession]) -> Vec<String> {
    let mut session_ids: Vec<String> = Vec::new();
    for session in sessions {
        if !session_ids.iter().any(|sid| sid == &session.session_id) {
            session_ids.push(session.session_id.clone());
        }
    }
    session_ids
}

fn merge_stage_payload(
    existing: Option<serde_json::Value>,
    cycle_id: &str,
    stage: &str,
    status: &str,
    error_message: Option<&str>,
    judge_result: Option<bool>,
    chat_sessions: serde_json::Value,
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
                "result": if stage == "judge" && status == "done" {
                    if judge_result.unwrap_or(true) { "pass" } else { "fail" }
                } else {
                    "n/a"
                },
                "reason": ""
            }),
        );
    }

    if stage == "judge" && status == "done" {
        if let Some(decision_obj) = obj.get_mut("decision").and_then(|v| v.as_object_mut()) {
            if !decision_obj
                .get("result")
                .and_then(|v| v.as_str())
                .map(|v| !v.trim().is_empty())
                .unwrap_or(false)
            {
                decision_obj.insert(
                    "result".to_string(),
                    serde_json::Value::String(if judge_result.unwrap_or(true) {
                        "pass".to_string()
                    } else {
                        "fail".to_string()
                    }),
                );
            }
        }
    }

    if !obj
        .get("next_action")
        .map(|v| v.is_object())
        .unwrap_or(false)
    {
        obj.insert(
            "next_action".to_string(),
            serde_json::json!({
                "type": "goto_stage",
                "target": next_stage(stage).unwrap_or("none")
            }),
        );
    }

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
            if !timing_obj.contains_key("duration_ms") {
                timing_obj.insert("duration_ms".to_string(), serde_json::json!(0));
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
    cycle_dir: &Path,
    stage_file: &Path,
    workspace_root: &str,
) -> serde_json::Value {
    serde_json::json!({
        "PROJECT": project,
        "WORKSPACE": workspace,
        "CYCLE_ID": cycle_id,
        "GLOBAL_LOOP_ROUND": round,
        "CURRENT_STAGE": stage,
        "VERIFY_ITERATION": verify_iteration,
        "VERIFY_ITERATION_LIMIT": verify_iteration_limit,
        "CYCLE_DIR": cycle_dir,
        "CYCLE_FILE_PATH": cycle_dir.join("cycle.json"),
        "PLAN_EXECUTION_PATH": cycle_dir.join("plan.execution.json"),
        "IMPLEMENT_GENERAL_RESULT_PATH": cycle_dir.join("implement_general.result.json"),
        "IMPLEMENT_VISUAL_RESULT_PATH": cycle_dir.join("implement_visual.result.json"),
        "IMPLEMENT_ADVANCED_RESULT_PATH": cycle_dir.join("implement_advanced.result.json"),
        "VERIFY_RESULT_PATH": cycle_dir.join("verify.result.json"),
        "JUDGE_RESULT_PATH": cycle_dir.join("judge.result.json"),
        "STAGE_FILE_PATH": stage_file,
        "DIRECTION_STAGE_FILE_PATH": cycle_dir.join("stage.direction.json"),
        "DIRECTION_LIFECYCLE_SCAN_PATH": cycle_dir.join("direction.lifecycle_scan.json"),
        "CHAT_MAP_PATH": cycle_dir.join("chat.map.json"),
        "ENV_CONTRACT_PATH": evolution_workspace_dir(workspace_root)
            .map(|p| p.join("env.contract.json"))
            .unwrap_or_else(|_| Path::new("env.contract.json").to_path_buf()),
        "ENV_VALUES_LOCAL_PATH": evolution_workspace_dir(workspace_root)
            .map(|p| p.join("env.values.local.json"))
            .unwrap_or_else(|_| Path::new("env.values.local.json").to_path_buf()),
        "WORKSPACE_BLOCKER_FILE_PATH": evolution_workspace_dir(workspace_root)
            .map(|p| p.join("workspace.blockers.json"))
            .unwrap_or_else(|_| Path::new("workspace.blockers.json").to_path_buf()),
        "WORKSPACE_ROOT": "由程序注入，禁止自行推断",
    })
}

impl EvolutionManager {
    pub(super) async fn persist_cycle_file(&self, key: &str) -> Result<(), String> {
        let state = self.state.lock().await;
        let Some(entry) = state.workspaces.get(key) else {
            return Ok(());
        };
        let cycle_dir = cycle_dir_path(&entry.workspace_root, &entry.cycle_id)?;
        std::fs::create_dir_all(&cycle_dir).map_err(|e| e.to_string())?;

        let mut stage_files = serde_json::Map::new();
        for stage in STAGES {
            stage_files.insert(
                stage.to_string(),
                serde_json::Value::String(format!("stage.{}.json", stage)),
            );
        }

        let payload = serde_json::json!({
            "$schema_version": "1.0",
            "cycle_id": entry.cycle_id,
            "project": entry.project,
            "workspace": entry.workspace,
            "status": entry.status,
            "current_stage": entry.current_stage,
            "pipeline": STAGES,
            "verify_iteration": entry.verify_iteration,
            "verify_iteration_limit": entry.verify_iteration_limit,
            "global_loop_round": entry.global_loop_round,
            "loop_round_limit": entry.loop_round_limit,
            "interrupt": {
                "requested": entry.stop_requested,
                "requested_by": if entry.stop_requested { "user" } else { "" },
                "requested_at": if entry.stop_requested { Utc::now().to_rfc3339() } else { "".to_string() },
                "reason": if entry.stop_requested { "manual stop" } else { "" }
            },
            "direction": {
                "selected_type": "architecture",
                "candidate_scores": [],
                "final_reason": "evolution auto scheduler"
            },
            "llm_defined_acceptance": {
                "criteria": entry.llm_defined_acceptance_criteria.clone()
            },
            "stage_files": stage_files,
            "chat_map_file": "chat.map.json",
            "handoff_file": "handoff.md",
            "terminal_reason_code": entry.terminal_reason_code.clone(),
            "rate_limit_recovery": {
                "resume_at": entry.rate_limit_resume_at.clone(),
                "last_error": entry.rate_limit_error_message.clone(),
            },
            "created_at": entry.created_at.clone(),
            "updated_at": Utc::now().to_rfc3339(),
        });

        write_json(&cycle_dir.join("cycle.json"), &payload)
    }

    pub(super) async fn persist_stage_file(
        &self,
        key: &str,
        stage: &str,
        status: &str,
        error_message: Option<&str>,
        judge_result: Option<bool>,
    ) -> Result<(), String> {
        let state = self.state.lock().await;
        let Some(entry) = state.workspaces.get(key) else {
            return Ok(());
        };
        let cycle_dir = cycle_dir_path(&entry.workspace_root, &entry.cycle_id)?;
        std::fs::create_dir_all(&cycle_dir).map_err(|e| e.to_string())?;
        let session_ids = entry
            .stage_session_history
            .get(stage)
            .map(|items| collect_session_ids(items))
            .unwrap_or_default();
        let outputs = if session_ids.is_empty() {
            serde_json::json!([])
        } else {
            serde_json::json!([
                {
                    "type": "chat_session",
                    "session_id": session_ids.last().cloned().unwrap_or_default(),
                    "session_ids": session_ids,
                }
            ])
        };

        let stage_file_path = cycle_dir.join(format!("stage.{}.json", stage));
        let existing = std::fs::read_to_string(&stage_file_path)
            .ok()
            .and_then(|content| serde_json::from_str::<serde_json::Value>(&content).ok());
        let now = Utc::now().to_rfc3339();
        let payload = merge_stage_payload(
            existing,
            &entry.cycle_id,
            stage,
            status,
            error_message,
            judge_result,
            outputs,
            &now,
        );

        write_json(&stage_file_path, &payload)
    }

    pub(super) async fn persist_chat_map(&self, key: &str) -> Result<(), String> {
        let state = self.state.lock().await;
        let Some(entry) = state.workspaces.get(key) else {
            return Ok(());
        };
        let cycle_dir = cycle_dir_path(&entry.workspace_root, &entry.cycle_id)?;
        std::fs::create_dir_all(&cycle_dir).map_err(|e| e.to_string())?;

        let mut session_rows: Vec<(String, Vec<StageSession>)> = entry
            .stage_session_history
            .iter()
            .map(|(stage, sessions)| (stage.clone(), sessions.clone()))
            .collect();
        session_rows.sort_by(|a, b| a.0.cmp(&b.0));
        let sessions: Vec<serde_json::Value> = session_rows
            .into_iter()
            .map(|(stage, stage_sessions)| {
                let session_ids = collect_session_ids(&stage_sessions);
                let latest = stage_sessions.last().cloned();
                serde_json::json!({
                    "stage": stage,
                    "ai_tool": latest.as_ref().map(|item| item.ai_tool.clone()).unwrap_or_default(),
                    "session_id": latest.as_ref().map(|item| item.session_id.clone()).unwrap_or_default(),
                    "session_ids": session_ids,
                })
            })
            .collect();

        let payload = serde_json::json!({
            "$schema_version": "1.0",
            "cycle_id": entry.cycle_id,
            "project": entry.project,
            "workspace": entry.workspace,
            "sessions": sessions,
            "updated_at": Utc::now().to_rfc3339(),
        });

        write_json(&cycle_dir.join("chat.map.json"), &payload)
    }

    pub(super) async fn build_stage_prompt(
        &self,
        key: &str,
        project: &str,
        workspace: &str,
        cycle_id: &str,
        stage: &str,
        round: u32,
    ) -> Result<String, String> {
        let prompt_body = prompt_template_for_stage(stage)
            .ok_or_else(|| format!("unknown stage prompt template: {}", stage))?;

        let (verify_iteration, verify_iteration_limit, workspace_root) = {
            let state = self.state.lock().await;
            let Some(entry) = state.workspaces.get(key) else {
                return Err("workspace state missing".to_string());
            };
            (
                entry.verify_iteration,
                entry.verify_iteration_limit,
                entry.workspace_root.clone(),
            )
        };

        let cycle_dir = cycle_dir_path(&workspace_root, cycle_id)?;
        let stage_file = cycle_dir.join(format!("stage.{}.json", stage));
        let context = build_prompt_context(
            project,
            workspace,
            cycle_id,
            stage,
            round,
            verify_iteration,
            verify_iteration_limit,
            &cycle_dir,
            &stage_file,
            &workspace_root,
        );

        Ok(format!(
            "{}\n\n---\n\n## 程序注入上下文（请直接使用，禁止自行推断路径）\n```json\n{}\n```\n",
            prompt_body,
            serde_json::to_string_pretty(&context).unwrap_or_else(|_| "{}".to_string())
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::{build_prompt_context, collect_session_ids, merge_stage_payload, StageSession};
    use std::path::Path;

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
    fn merge_stage_payload_should_preserve_agent_decision_and_next_action() {
        let existing = serde_json::json!({
            "$schema_version": "1.0",
            "cycle_id": "cycle-a",
            "stage": "judge",
            "agent": "JudgeAgent",
            "status": "done",
            "decision": {
                "result": "fail",
                "reason": "agent decided by evidence"
            },
            "next_action": {
                "type": "stop_cycle",
                "target": null
            },
            "outputs": [{"type": "file", "path": "judge.result.json"}]
        });
        let merged = merge_stage_payload(
            Some(existing),
            "cycle-a",
            "judge",
            "done",
            None,
            Some(false),
            serde_json::json!([{
                "type": "chat_session",
                "session_id": "session-1",
                "session_ids": ["session-1"]
            }]),
            "2026-02-27T00:00:00Z",
        );

        assert_eq!(merged["decision"]["reason"], "agent decided by evidence");
        assert_eq!(merged["next_action"]["type"], "stop_cycle");
        assert_eq!(merged["next_action"]["target"], serde_json::Value::Null);
        assert_eq!(
            merged["system_metadata"]["chat_sessions"][0]["session_id"],
            "session-1"
        );
    }

    #[test]
    fn build_prompt_context_should_include_explicit_result_paths() {
        let cycle_dir = Path::new("/tmp/tidyflow-cycle");
        let stage_file = cycle_dir.join("stage.implement_general.json");
        let context = build_prompt_context(
            "demo",
            "default",
            "cycle-1",
            "implement_general",
            1,
            1,
            5,
            cycle_dir,
            &stage_file,
            "/tmp/workspace",
        );
        assert_eq!(
            context
                .get("PLAN_EXECUTION_PATH")
                .and_then(|v| v.as_str())
                .unwrap_or_default(),
            "/tmp/tidyflow-cycle/plan.execution.json"
        );
        assert_eq!(
            context
                .get("IMPLEMENT_GENERAL_RESULT_PATH")
                .and_then(|v| v.as_str())
                .unwrap_or_default(),
            "/tmp/tidyflow-cycle/implement_general.result.json"
        );
        assert_eq!(
            context
                .get("IMPLEMENT_VISUAL_RESULT_PATH")
                .and_then(|v| v.as_str())
                .unwrap_or_default(),
            "/tmp/tidyflow-cycle/implement_visual.result.json"
        );
        assert_eq!(
            context
                .get("IMPLEMENT_ADVANCED_RESULT_PATH")
                .and_then(|v| v.as_str())
                .unwrap_or_default(),
            "/tmp/tidyflow-cycle/implement_advanced.result.json"
        );
        assert_eq!(
            context
                .get("VERIFY_RESULT_PATH")
                .and_then(|v| v.as_str())
                .unwrap_or_default(),
            "/tmp/tidyflow-cycle/verify.result.json"
        );
        assert_eq!(
            context
                .get("JUDGE_RESULT_PATH")
                .and_then(|v| v.as_str())
                .unwrap_or_default(),
            "/tmp/tidyflow-cycle/judge.result.json"
        );
    }
}
