use std::collections::HashMap;

use crate::server::handlers::evolution_prompts::{
    STAGE_DIRECTION_PROMPT, STAGE_IMPLEMENT_PROMPT, STAGE_JUDGE_PROMPT, STAGE_PLAN_PROMPT,
    STAGE_REPORT_PROMPT, STAGE_VERIFY_PROMPT,
};
use crate::server::protocol::EvolutionAgentInfo;

use super::STAGES;

pub(super) fn build_agents(
    stage_statuses: &HashMap<String, String>,
    stage_tool_call_counts: &HashMap<String, u32>,
) -> Vec<EvolutionAgentInfo> {
    let mut agents = Vec::with_capacity(STAGES.len());

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
        "direction" => Some("builtin://evolution/stage.direction.prompt"),
        "plan" => Some("builtin://evolution/stage.plan.prompt"),
        "implement" => Some("builtin://evolution/stage.implement.prompt"),
        "verify" => Some("builtin://evolution/stage.verify.prompt"),
        "judge" => Some("builtin://evolution/stage.judge.prompt"),
        "report" => Some("builtin://evolution/stage.report.prompt"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stages_should_not_contain_bootstrap() {
        // bootstrap 已从 STAGES 集合中移除，确保常量不包含该旧阶段
        assert!(!STAGES.contains(&"bootstrap"), "STAGES 不应包含 bootstrap");
    }

    #[test]
    fn stages_first_element_should_be_direction() {
        // 第一个阶段必须是 direction（bootstrap 被移除后的起始阶段）
        assert_eq!(STAGES[0], "direction", "STAGES 的第一个元素应为 direction");
    }

    #[test]
    fn next_stage_with_unknown_stage_should_return_none() {
        // 未知 stage 输入必须安全返回 None，不可 panic
        assert_eq!(next_stage("unknown"), None);
        assert_eq!(next_stage("bootstrap"), None);
        assert_eq!(next_stage(""), None);
    }
}
