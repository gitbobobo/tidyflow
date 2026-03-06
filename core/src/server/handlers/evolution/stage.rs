use std::collections::HashMap;

use crate::server::handlers::evolution_prompts::{
    STAGE_AUTO_COMMIT_PROMPT, STAGE_DIRECTION_PROMPT, STAGE_IMPLEMENT_ADVANCED_PROMPT,
    STAGE_IMPLEMENT_GENERAL_PROMPT, STAGE_IMPLEMENT_VISUAL_PROMPT, STAGE_PLAN_PROMPT,
    STAGE_VERIFY_PROMPT,
};
use crate::server::protocol::EvolutionAgentInfo;

use super::STAGES;

fn runtime_extra_stages(stage_statuses: &HashMap<String, String>) -> Vec<String> {
    let mut stages: Vec<String> = stage_statuses
        .keys()
        .filter(|stage| !STAGES.contains(&stage.as_str()))
        .cloned()
        .collect();
    stages.sort();
    stages
}

pub(super) fn build_agents(
    stage_statuses: &HashMap<String, String>,
    stage_tool_call_counts: &HashMap<String, u32>,
    stage_started_ats: &HashMap<String, String>,
    stage_duration_ms: &HashMap<String, u64>,
) -> Vec<EvolutionAgentInfo> {
    let extra_stages = runtime_extra_stages(stage_statuses);
    let mut agents = Vec::with_capacity(STAGES.len() + extra_stages.len());

    for stage in STAGES {
        let status = stage_statuses
            .get(stage)
            .cloned()
            .unwrap_or_else(|| "pending".to_string());
        let tool_call_count = *stage_tool_call_counts.get(stage).unwrap_or(&0);

        agents.push(EvolutionAgentInfo {
            stage: stage.to_string(),
            agent: agent_name(stage).to_string(),
            status,
            tool_call_count,
            latest_message: None,
            started_at: stage_started_ats.get(stage).cloned(),
            duration_ms: stage_duration_ms.get(stage).copied(),
        });
    }

    for stage in extra_stages {
        let status = stage_statuses
            .get(&stage)
            .cloned()
            .unwrap_or_else(|| "pending".to_string());
        let tool_call_count = *stage_tool_call_counts.get(&stage).unwrap_or(&0);
        agents.push(EvolutionAgentInfo {
            stage: stage.clone(),
            agent: agent_name(&stage).to_string(),
            status,
            tool_call_count,
            latest_message: None,
            started_at: stage_started_ats.get(&stage).cloned(),
            duration_ms: stage_duration_ms.get(&stage).copied(),
        });
    }

    agents
}

pub(super) fn active_agents(stage_statuses: &HashMap<String, String>) -> Vec<String> {
    let mut stages: Vec<String> = STAGES.iter().map(|stage| stage.to_string()).collect();
    stages.extend(runtime_extra_stages(stage_statuses));
    stages
        .into_iter()
        .filter_map(|stage| {
            let status = stage_statuses
                .get(&stage)
                .map(|v| v.as_str())
                .unwrap_or("pending");
            if status == "running" {
                Some(agent_name(&stage).to_string())
            } else {
                None
            }
        })
        .collect()
}

pub(super) fn agent_name(stage: &str) -> &'static str {
    match stage {
        "direction" => "DirectionAgent",
        "plan" => "PlanAgent",
        "implement_general" => "ImplementGeneralAgent",
        "implement_visual" => "ImplementVisualAgent",
        "implement_advanced" => "ImplementAdvancedAgent",
        "verify" => "VerifyAgent",
        "auto_commit" => "AutoCommitAgent",
        _ => "UnknownAgent",
    }
}

#[allow(dead_code)]
pub(super) fn next_stage(stage: &str) -> Option<&'static str> {
    match stage {
        "direction" => Some("plan"),
        "plan" => Some("implement_general"),
        "implement_general" => Some("implement_visual"),
        "implement_visual" => Some("verify"),
        "implement_advanced" => Some("verify"),
        "verify" => Some("auto_commit"),
        "auto_commit" => Some("direction"),
        _ => None,
    }
}

pub(super) fn prompt_template_for_stage(stage: &str) -> Option<&'static str> {
    match stage {
        "direction" => Some(STAGE_DIRECTION_PROMPT),
        "plan" => Some(STAGE_PLAN_PROMPT),
        "implement_general" => Some(STAGE_IMPLEMENT_GENERAL_PROMPT),
        "implement_visual" => Some(STAGE_IMPLEMENT_VISUAL_PROMPT),
        "implement_advanced" => Some(STAGE_IMPLEMENT_ADVANCED_PROMPT),
        "verify" => Some(STAGE_VERIFY_PROMPT),
        "auto_commit" => Some(STAGE_AUTO_COMMIT_PROMPT),
        _ => None,
    }
}

#[allow(dead_code)]
pub(super) fn prompt_id_for_stage(stage: &str) -> Option<&'static str> {
    match stage {
        "direction" => Some("builtin://evolution/stage.direction.prompt"),
        "plan" => Some("builtin://evolution/stage.plan.prompt"),
        "implement_general" => Some("builtin://evolution/stage.implement_general.prompt"),
        "implement_visual" => Some("builtin://evolution/stage.implement_visual.prompt"),
        "implement_advanced" => Some("builtin://evolution/stage.implement_advanced.prompt"),
        "verify" => Some("builtin://evolution/stage.verify.prompt"),
        "auto_commit" => Some("builtin://evolution/stage.auto_commit.prompt"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stages_should_not_contain_judge_or_bootstrap() {
        assert!(!STAGES.contains(&"judge"), "STAGES 不应包含 judge");
        assert!(!STAGES.contains(&"bootstrap"), "STAGES 不应包含 bootstrap");
    }

    #[test]
    fn next_stage_verify_should_goto_auto_commit() {
        assert_eq!(next_stage("verify"), Some("auto_commit"));
    }

    #[test]
    fn next_stage_unknown_should_return_none() {
        assert_eq!(next_stage("unknown"), None);
        assert_eq!(next_stage("bootstrap"), None);
        assert_eq!(next_stage(""), None);
    }
}
