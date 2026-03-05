use std::collections::HashMap;

use crate::server::handlers::evolution_prompts::{
    STAGE_AUTO_COMMIT_PROMPT, STAGE_DIRECTION_PROMPT, STAGE_IMPLEMENT_ADVANCED_PROMPT,
    STAGE_IMPLEMENT_GENERAL_PROMPT, STAGE_IMPLEMENT_VISUAL_PROMPT, STAGE_JUDGE_PROMPT,
    STAGE_PLAN_PROMPT, STAGE_REPORT_PROMPT, STAGE_VERIFY_PROMPT,
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
        "judge" => "JudgeAgent",
        "report" => "ReportAgent",
        "auto_commit" => "AutoCommitAgent",
        _ => "UnknownAgent",
    }
}

pub(super) fn next_stage(stage: &str) -> Option<&'static str> {
    match stage {
        "direction" => Some("plan"),
        "plan" => Some("implement_general"),
        "implement_general" => Some("implement_visual"),
        "implement_visual" => Some("verify"),
        "implement_advanced" => Some("verify"),
        "verify" => Some("judge"),
        "judge" => Some("report"),
        "report" => Some("auto_commit"),
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
        "judge" => Some(STAGE_JUDGE_PROMPT),
        "report" => Some(STAGE_REPORT_PROMPT),
        "auto_commit" => Some(STAGE_AUTO_COMMIT_PROMPT),
        _ => None,
    }
}

pub(super) fn prompt_id_for_stage(stage: &str) -> Option<&'static str> {
    match stage {
        "direction" => Some("builtin://evolution/stage.direction.prompt"),
        "plan" => Some("builtin://evolution/stage.plan.prompt"),
        "implement_general" => Some("builtin://evolution/stage.implement_general.prompt"),
        "implement_visual" => Some("builtin://evolution/stage.implement_visual.prompt"),
        "implement_advanced" => Some("builtin://evolution/stage.implement_advanced.prompt"),
        "verify" => Some("builtin://evolution/stage.verify.prompt"),
        "judge" => Some("builtin://evolution/stage.judge.prompt"),
        "report" => Some("builtin://evolution/stage.report.prompt"),
        "auto_commit" => Some("builtin://evolution/stage.auto_commit.prompt"),
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

    #[test]
    fn build_agents_should_include_runtime_extra_stage() {
        let mut statuses: HashMap<String, String> = HashMap::new();
        statuses.insert("auto_commit".to_string(), "running".to_string());
        let counts: HashMap<String, u32> = HashMap::new();

        let agents = build_agents(&statuses, &counts, &HashMap::new(), &HashMap::new());
        assert!(
            agents.iter().any(|agent| agent.stage == "auto_commit"),
            "运行时额外阶段应出现在 agents 列表中"
        );
    }

    #[test]
    fn active_agents_should_include_runtime_extra_stage() {
        let mut statuses: HashMap<String, String> = HashMap::new();
        statuses.insert("auto_commit".to_string(), "running".to_string());

        let active = active_agents(&statuses);
        assert!(
            active.contains(&"AutoCommitAgent".to_string()),
            "运行中的 auto_commit 应出现在 active_agents 中"
        );
    }

    #[test]
    fn implement_prompt_templates_should_be_independent() {
        let general = prompt_template_for_stage("implement_general")
            .expect("general prompt template should exist");
        let visual = prompt_template_for_stage("implement_visual")
            .expect("visual prompt template should exist");
        let advanced = prompt_template_for_stage("implement_advanced")
            .expect("advanced prompt template should exist");

        assert_ne!(
            general, visual,
            "implement_general 与 implement_visual 提示词不可复用同一文本"
        );
        assert_ne!(
            general, advanced,
            "implement_general 与 implement_advanced 提示词不可复用同一文本"
        );
        assert_ne!(
            visual, advanced,
            "implement_visual 与 implement_advanced 提示词不可复用同一文本"
        );
    }

    #[test]
    fn implement_prompt_ids_should_be_independent() {
        let general =
            prompt_id_for_stage("implement_general").expect("general prompt id should exist");
        let visual =
            prompt_id_for_stage("implement_visual").expect("visual prompt id should exist");
        let advanced =
            prompt_id_for_stage("implement_advanced").expect("advanced prompt id should exist");
        assert_ne!(general, visual);
        assert_ne!(general, advanced);
        assert_ne!(visual, advanced);
    }
}
