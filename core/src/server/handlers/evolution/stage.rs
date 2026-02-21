use std::collections::HashMap;

use crate::server::handlers::evolution_prompts::{
    STAGE_BOOTSTRAP_PROMPT, STAGE_DIRECTION_PROMPT, STAGE_IMPLEMENT_PROMPT, STAGE_JUDGE_PROMPT,
    STAGE_PLAN_PROMPT, STAGE_REPORT_PROMPT, STAGE_VERIFY_PROMPT,
};
use crate::server::protocol::EvolutionAgentInfo;

use super::STAGES;

pub(super) fn build_agents(stage_statuses: &HashMap<String, String>) -> Vec<EvolutionAgentInfo> {
    let mut agents = Vec::with_capacity(STAGES.len());
    for stage in STAGES {
        let status = stage_statuses
            .get(stage)
            .cloned()
            .unwrap_or_else(|| "pending".to_string());
        agents.push(EvolutionAgentInfo {
            stage: stage.to_string(),
            agent: agent_name(stage).to_string(),
            status,
        });
    }
    agents
}

pub(super) fn active_agents(stage_statuses: &HashMap<String, String>) -> Vec<String> {
    STAGES
        .iter()
        .filter_map(|stage| {
            let status = stage_statuses
                .get(*stage)
                .map(|v| v.as_str())
                .unwrap_or("pending");
            if status == "running" {
                Some(agent_name(stage).to_string())
            } else {
                None
            }
        })
        .collect()
}

pub(super) fn agent_name(stage: &str) -> &'static str {
    match stage {
        "bootstrap" => "BootstrapAgent",
        "direction" => "DirectionAgent",
        "plan" => "PlanAgent",
        "implement" => "ImplementAgent",
        "verify" => "VerifyAgent",
        "judge" => "JudgeAgent",
        "report" => "ReportAgent",
        _ => "UnknownAgent",
    }
}

pub(super) fn next_stage(stage: &str) -> Option<&'static str> {
    match stage {
        "bootstrap" => Some("direction"),
        "direction" => Some("plan"),
        "plan" => Some("implement"),
        "implement" => Some("verify"),
        "verify" => Some("judge"),
        "judge" => Some("report"),
        "report" => Some("direction"),
        _ => None,
    }
}

pub(super) fn prompt_template_for_stage(stage: &str) -> Option<&'static str> {
    match stage {
        "bootstrap" => Some(STAGE_BOOTSTRAP_PROMPT),
        "direction" => Some(STAGE_DIRECTION_PROMPT),
        "plan" => Some(STAGE_PLAN_PROMPT),
        "implement" => Some(STAGE_IMPLEMENT_PROMPT),
        "verify" => Some(STAGE_VERIFY_PROMPT),
        "judge" => Some(STAGE_JUDGE_PROMPT),
        "report" => Some(STAGE_REPORT_PROMPT),
        _ => None,
    }
}

pub(super) fn prompt_id_for_stage(stage: &str) -> Option<&'static str> {
    match stage {
        "bootstrap" => Some("builtin://evolution/stage.bootstrap.prompt"),
        "direction" => Some("builtin://evolution/stage.direction.prompt"),
        "plan" => Some("builtin://evolution/stage.plan.prompt"),
        "implement" => Some("builtin://evolution/stage.implement.prompt"),
        "verify" => Some("builtin://evolution/stage.verify.prompt"),
        "judge" => Some("builtin://evolution/stage.judge.prompt"),
        "report" => Some("builtin://evolution/stage.report.prompt"),
        _ => None,
    }
}
