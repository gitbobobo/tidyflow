use std::collections::HashMap;

use crate::server::handlers::evolution_prompts::{
    STAGE_AUTO_COMMIT_PROMPT, STAGE_DIRECTION_PROMPT, STAGE_IMPLEMENT_PROMPT,
    STAGE_INTEGRATION_PROMPT, STAGE_PLAN_PROMPT, STAGE_REIMPLEMENT_PROMPT, STAGE_VERIFY_PROMPT,
};
use crate::server::protocol::EvolutionAgentInfo;

use super::consts::{
    compare_runtime_stage_names, parse_implement_stage_instance, parse_reimplement_stage_instance,
    parse_verify_stage_instance, ImplementationStageKind, STAGES,
};

fn runtime_extra_stages(stage_statuses: &HashMap<String, String>) -> Vec<String> {
    let mut stages: Vec<String> = stage_statuses
        .keys()
        .filter(|stage| !STAGES.contains(&stage.as_str()))
        .cloned()
        .collect();
    stages.sort_by(|left, right| compare_runtime_stage_names(left, right));
    stages
}

pub(super) fn build_agents(
    stage_statuses: &HashMap<String, String>,
    stage_tool_call_counts: &HashMap<String, u32>,
    stage_started_ats: &HashMap<String, String>,
    stage_duration_ms: &HashMap<String, u64>,
) -> Vec<EvolutionAgentInfo> {
    let extra_stages = runtime_extra_stages(stage_statuses);
    let base_stages: Vec<&str> = STAGES
        .iter()
        .copied()
        .filter(|stage| stage_statuses.contains_key(*stage))
        .collect();
    let mut agents = Vec::with_capacity(base_stages.len() + extra_stages.len());

    for stage in base_stages {
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
            started_at: stage_started_ats.get(&stage).cloned(),
            duration_ms: stage_duration_ms.get(&stage).copied(),
        });
    }

    agents
}

pub(super) fn agent_name(stage: &str) -> &'static str {
    if let Some((kind, _)) = parse_implement_stage_instance(stage) {
        return match kind {
            ImplementationStageKind::General => "ImplementGeneralAgent",
            ImplementationStageKind::Visual => "ImplementVisualAgent",
            ImplementationStageKind::Advanced => "ImplementAdvancedAgent",
        };
    }
    if parse_reimplement_stage_instance(stage).is_some() {
        return "ReimplementAgent";
    }
    if parse_verify_stage_instance(stage).is_some() {
        return "VerifyAgent";
    }
    match stage {
        "direction" => "DirectionAgent",
        "plan" => "PlanAgent",
        "auto_commit" => "AutoCommitAgent",
        "integration" => "IntegrationAgent",
        _ => "UnknownAgent",
    }
}

#[allow(dead_code)]
pub(super) fn next_stage(stage: &str) -> Option<&'static str> {
    match stage {
        "direction" => Some("plan"),
        "auto_commit" => Some("integration"),
        "integration" => Some("direction"),
        _ => None,
    }
}

pub(super) fn prompt_template_for_stage(stage: &str) -> Option<&'static str> {
    if parse_implement_stage_instance(stage).is_some() {
        return Some(STAGE_IMPLEMENT_PROMPT);
    }
    if parse_reimplement_stage_instance(stage).is_some() {
        return Some(STAGE_REIMPLEMENT_PROMPT);
    }
    if parse_verify_stage_instance(stage).is_some() {
        return Some(STAGE_VERIFY_PROMPT);
    }
    match stage {
        "direction" => Some(STAGE_DIRECTION_PROMPT),
        "plan" => Some(STAGE_PLAN_PROMPT),
        "auto_commit" => Some(STAGE_AUTO_COMMIT_PROMPT),
        "integration" => Some(STAGE_INTEGRATION_PROMPT),
        _ => None,
    }
}

#[allow(dead_code)]
pub(super) fn prompt_id_for_stage(stage: &str) -> Option<&'static str> {
    if parse_implement_stage_instance(stage).is_some() {
        return Some("builtin://evolution/stage.implement.prompt");
    }
    if parse_reimplement_stage_instance(stage).is_some() {
        return Some("builtin://evolution/stage.reimplement.prompt");
    }
    if parse_verify_stage_instance(stage).is_some() {
        return Some("builtin://evolution/stage.verify.prompt");
    }
    match stage {
        "direction" => Some("builtin://evolution/stage.direction.prompt"),
        "plan" => Some("builtin://evolution/stage.plan.prompt"),
        "auto_commit" => Some("builtin://evolution/stage.auto_commit.prompt"),
        "integration" => Some("builtin://evolution/stage.integration.prompt"),
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
    fn next_stage_unknown_should_return_none() {
        assert_eq!(next_stage("unknown"), None);
        assert_eq!(next_stage("bootstrap"), None);
        assert_eq!(next_stage(""), None);
    }
}
