use std::path::Path;

use chrono::Utc;

use super::stage::{agent_name, next_stage, prompt_id_for_stage, prompt_template_for_stage};
use super::utils::{cycle_dir_path, evolution_workspace_dir, write_json};
use super::{EvolutionManager, StageSession, STAGES};

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
            "auto_loop_enabled": entry.auto_loop_enabled,
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
                "criteria": [],
                "minimum_evidence_policy": {
                    "strategy": "llm_decided",
                    "description": "auto"
                }
            },
            "stage_files": stage_files,
            "chat_map_file": "chat.map.json",
            "evidence_index_file": "evidence.index.json",
            "handoff_file": "handoff.md",
            "created_at": Utc::now().to_rfc3339(),
            "updated_at": Utc::now().to_rfc3339(),
        });

        write_json(&cycle_dir.join("cycle.json"), &payload)
    }

    pub(super) async fn persist_stage_file(
        &self,
        key: &str,
        stage: &str,
        status: &str,
        session_id: Option<&str>,
        error_message: Option<&str>,
    ) -> Result<(), String> {
        let state = self.state.lock().await;
        let Some(entry) = state.workspaces.get(key) else {
            return Ok(());
        };
        let cycle_dir = cycle_dir_path(&entry.workspace_root, &entry.cycle_id)?;
        std::fs::create_dir_all(&cycle_dir).map_err(|e| e.to_string())?;

        let payload = serde_json::json!({
            "$schema_version": "1.0",
            "cycle_id": entry.cycle_id,
            "stage": stage,
            "agent": agent_name(stage),
            "status": status,
            "inputs": [
                {"type": "prompt", "path": prompt_id_for_stage(stage).unwrap_or_default()}
            ],
            "outputs": if let Some(sid) = session_id {
                serde_json::json!([
                    {"type": "chat_session", "session_id": sid}
                ])
            } else {
                serde_json::json!([])
            },
            "decision": {
                "result": if stage == "judge" && status == "done" { "pass" } else { "n/a" },
                "reason": ""
            },
            "next_action": {
                "type": "goto_stage",
                "target": next_stage(stage).unwrap_or("none")
            },
            "timing": {
                "started_at": Utc::now().to_rfc3339(),
                "completed_at": if status == "done" { Utc::now().to_rfc3339() } else { "".to_string() },
                "duration_ms": if status == "done" { serde_json::json!(0) } else { serde_json::Value::Null }
            },
            "error": error_message.map(|e| serde_json::json!({"message": e}))
        });

        write_json(&cycle_dir.join(format!("stage.{}.json", stage)), &payload)
    }

    pub(super) async fn persist_chat_map(&self, key: &str) -> Result<(), String> {
        let state = self.state.lock().await;
        let Some(entry) = state.workspaces.get(key) else {
            return Ok(());
        };
        let cycle_dir = cycle_dir_path(&entry.workspace_root, &entry.cycle_id)?;
        std::fs::create_dir_all(&cycle_dir).map_err(|e| e.to_string())?;

        let mut session_rows: Vec<(String, StageSession)> = entry
            .stage_sessions
            .iter()
            .map(|(stage, session)| (stage.clone(), session.clone()))
            .collect();
        session_rows.sort_by(|a, b| a.0.cmp(&b.0));
        let sessions: Vec<serde_json::Value> = session_rows
            .into_iter()
            .map(|(stage, session)| {
                serde_json::json!({
                    "stage": stage,
                    "ai_tool": session.ai_tool,
                    "session_id": session.session_id,
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
        let context = serde_json::json!({
            "PROJECT": project,
            "WORKSPACE": workspace,
            "CYCLE_ID": cycle_id,
            "GLOBAL_LOOP_ROUND": round,
            "CURRENT_STAGE": stage,
            "VERIFY_ITERATION": verify_iteration,
            "VERIFY_ITERATION_LIMIT": verify_iteration_limit,
            "CYCLE_DIR": cycle_dir,
            "STAGE_FILE_PATH": stage_file,
            "EVIDENCE_INDEX_PATH": cycle_dir.join("evidence.index.json"),
            "CHAT_MAP_PATH": cycle_dir.join("chat.map.json"),
            "BOOTSTRAP_STATE_PATH": evolution_workspace_dir(&workspace_root)
                .map(|p| p.join("bootstrap.state.json"))
                .unwrap_or_else(|_| Path::new("bootstrap.state.json").to_path_buf()),
            "TEST_ADAPTER_PATH": evolution_workspace_dir(&workspace_root)
                .map(|p| p.join("test.adapter.json"))
                .unwrap_or_else(|_| Path::new("test.adapter.json").to_path_buf()),
            "ENV_CONTRACT_PATH": evolution_workspace_dir(&workspace_root)
                .map(|p| p.join("env.contract.json"))
                .unwrap_or_else(|_| Path::new("env.contract.json").to_path_buf()),
            "ENV_VALUES_LOCAL_PATH": evolution_workspace_dir(&workspace_root)
                .map(|p| p.join("env.values.local.json"))
                .unwrap_or_else(|_| Path::new("env.values.local.json").to_path_buf()),
            "WORKSPACE_ROOT": "由程序注入，禁止自行推断",
        });

        Ok(format!(
            "{}\n\n---\n\n## 程序注入上下文（请直接使用，禁止自行推断路径）\n```json\n{}\n```\n",
            prompt_body,
            serde_json::to_string_pretty(&context).unwrap_or_else(|_| "{}".to_string())
        ))
    }
}
