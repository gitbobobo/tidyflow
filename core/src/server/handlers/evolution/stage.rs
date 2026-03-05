use std::collections::HashMap;

use crate::server::handlers::evolution_prompts::{
    STAGE_AUTO_COMMIT_DELIVERABLE_PROMPT, STAGE_AUTO_COMMIT_MISSION_PROMPT,
    STAGE_DIRECTION_DELIVERABLE_PROMPT, STAGE_DIRECTION_MISSION_PROMPT,
    STAGE_IMPLEMENT_ADVANCED_DELIVERABLE_PROMPT, STAGE_IMPLEMENT_ADVANCED_MISSION_PROMPT,
    STAGE_IMPLEMENT_GENERAL_DELIVERABLE_PROMPT, STAGE_IMPLEMENT_GENERAL_MISSION_PROMPT,
    STAGE_IMPLEMENT_VISUAL_DELIVERABLE_PROMPT, STAGE_IMPLEMENT_VISUAL_MISSION_PROMPT,
    STAGE_JUDGE_DELIVERABLE_PROMPT, STAGE_JUDGE_MISSION_PROMPT, STAGE_PLAN_DELIVERABLE_PROMPT,
    STAGE_PLAN_MISSION_PROMPT, STAGE_REPORT_DELIVERABLE_PROMPT, STAGE_REPORT_MISSION_PROMPT,
    STAGE_VERIFY_DELIVERABLE_PROMPT, STAGE_VERIFY_MISSION_PROMPT,
};
use crate::server::protocol::EvolutionAgentInfo;

use super::STAGES;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum StagePromptPhase {
    Mission,
    Deliverable,
}

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

pub(super) fn prompt_template_for_stage_phase(
    stage: &str,
    phase: StagePromptPhase,
) -> Option<&'static str> {
    match (stage, phase) {
        ("direction", StagePromptPhase::Mission) => Some(STAGE_DIRECTION_MISSION_PROMPT),
        ("direction", StagePromptPhase::Deliverable) => Some(STAGE_DIRECTION_DELIVERABLE_PROMPT),
        ("plan", StagePromptPhase::Mission) => Some(STAGE_PLAN_MISSION_PROMPT),
        ("plan", StagePromptPhase::Deliverable) => Some(STAGE_PLAN_DELIVERABLE_PROMPT),
        ("implement_general", StagePromptPhase::Mission) => {
            Some(STAGE_IMPLEMENT_GENERAL_MISSION_PROMPT)
        }
        ("implement_general", StagePromptPhase::Deliverable) => {
            Some(STAGE_IMPLEMENT_GENERAL_DELIVERABLE_PROMPT)
        }
        ("implement_visual", StagePromptPhase::Mission) => {
            Some(STAGE_IMPLEMENT_VISUAL_MISSION_PROMPT)
        }
        ("implement_visual", StagePromptPhase::Deliverable) => {
            Some(STAGE_IMPLEMENT_VISUAL_DELIVERABLE_PROMPT)
        }
        ("implement_advanced", StagePromptPhase::Mission) => {
            Some(STAGE_IMPLEMENT_ADVANCED_MISSION_PROMPT)
        }
        ("implement_advanced", StagePromptPhase::Deliverable) => {
            Some(STAGE_IMPLEMENT_ADVANCED_DELIVERABLE_PROMPT)
        }
        ("verify", StagePromptPhase::Mission) => Some(STAGE_VERIFY_MISSION_PROMPT),
        ("verify", StagePromptPhase::Deliverable) => Some(STAGE_VERIFY_DELIVERABLE_PROMPT),
        ("judge", StagePromptPhase::Mission) => Some(STAGE_JUDGE_MISSION_PROMPT),
        ("judge", StagePromptPhase::Deliverable) => Some(STAGE_JUDGE_DELIVERABLE_PROMPT),
        ("report", StagePromptPhase::Mission) => Some(STAGE_REPORT_MISSION_PROMPT),
        ("report", StagePromptPhase::Deliverable) => Some(STAGE_REPORT_DELIVERABLE_PROMPT),
        ("auto_commit", StagePromptPhase::Mission) => Some(STAGE_AUTO_COMMIT_MISSION_PROMPT),
        ("auto_commit", StagePromptPhase::Deliverable) => {
            Some(STAGE_AUTO_COMMIT_DELIVERABLE_PROMPT)
        }
        _ => None,
    }
}

pub(super) fn prompt_id_for_stage_phase(
    stage: &str,
    phase: StagePromptPhase,
) -> Option<&'static str> {
    match (stage, phase) {
        ("direction", StagePromptPhase::Mission) => {
            Some("builtin://evolution/stage.direction.mission.prompt")
        }
        ("direction", StagePromptPhase::Deliverable) => {
            Some("builtin://evolution/stage.direction.deliverable.prompt")
        }
        ("plan", StagePromptPhase::Mission) => {
            Some("builtin://evolution/stage.plan.mission.prompt")
        }
        ("plan", StagePromptPhase::Deliverable) => {
            Some("builtin://evolution/stage.plan.deliverable.prompt")
        }
        ("implement_general", StagePromptPhase::Mission) => {
            Some("builtin://evolution/stage.implement_general.mission.prompt")
        }
        ("implement_general", StagePromptPhase::Deliverable) => {
            Some("builtin://evolution/stage.implement_general.deliverable.prompt")
        }
        ("implement_visual", StagePromptPhase::Mission) => {
            Some("builtin://evolution/stage.implement_visual.mission.prompt")
        }
        ("implement_visual", StagePromptPhase::Deliverable) => {
            Some("builtin://evolution/stage.implement_visual.deliverable.prompt")
        }
        ("implement_advanced", StagePromptPhase::Mission) => {
            Some("builtin://evolution/stage.implement_advanced.mission.prompt")
        }
        ("implement_advanced", StagePromptPhase::Deliverable) => {
            Some("builtin://evolution/stage.implement_advanced.deliverable.prompt")
        }
        ("verify", StagePromptPhase::Mission) => {
            Some("builtin://evolution/stage.verify.mission.prompt")
        }
        ("verify", StagePromptPhase::Deliverable) => {
            Some("builtin://evolution/stage.verify.deliverable.prompt")
        }
        ("judge", StagePromptPhase::Mission) => {
            Some("builtin://evolution/stage.judge.mission.prompt")
        }
        ("judge", StagePromptPhase::Deliverable) => {
            Some("builtin://evolution/stage.judge.deliverable.prompt")
        }
        ("report", StagePromptPhase::Mission) => {
            Some("builtin://evolution/stage.report.mission.prompt")
        }
        ("report", StagePromptPhase::Deliverable) => {
            Some("builtin://evolution/stage.report.deliverable.prompt")
        }
        ("auto_commit", StagePromptPhase::Mission) => {
            Some("builtin://evolution/stage.auto_commit.mission.prompt")
        }
        ("auto_commit", StagePromptPhase::Deliverable) => {
            Some("builtin://evolution/stage.auto_commit.deliverable.prompt")
        }
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
    fn implement_prompt_templates_should_be_independent_in_deliverable_phase() {
        let general =
            prompt_template_for_stage_phase("implement_general", StagePromptPhase::Deliverable)
                .expect("general deliverable prompt should exist");
        let visual =
            prompt_template_for_stage_phase("implement_visual", StagePromptPhase::Deliverable)
                .expect("visual deliverable prompt should exist");
        let advanced =
            prompt_template_for_stage_phase("implement_advanced", StagePromptPhase::Deliverable)
                .expect("advanced deliverable prompt should exist");

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
    fn implement_prompt_ids_should_be_independent_for_both_phases() {
        let mission_general =
            prompt_id_for_stage_phase("implement_general", StagePromptPhase::Mission)
                .expect("general mission id should exist");
        let mission_visual =
            prompt_id_for_stage_phase("implement_visual", StagePromptPhase::Mission)
                .expect("visual mission id should exist");
        let mission_advanced =
            prompt_id_for_stage_phase("implement_advanced", StagePromptPhase::Mission)
                .expect("advanced mission id should exist");
        assert_ne!(mission_general, mission_visual);
        assert_ne!(mission_general, mission_advanced);
        assert_ne!(mission_visual, mission_advanced);

        let deliverable_general =
            prompt_id_for_stage_phase("implement_general", StagePromptPhase::Deliverable)
                .expect("general deliverable id should exist");
        let deliverable_visual =
            prompt_id_for_stage_phase("implement_visual", StagePromptPhase::Deliverable)
                .expect("visual deliverable id should exist");
        let deliverable_advanced =
            prompt_id_for_stage_phase("implement_advanced", StagePromptPhase::Deliverable)
                .expect("advanced deliverable id should exist");
        assert_ne!(deliverable_general, deliverable_visual);
        assert_ne!(deliverable_general, deliverable_advanced);
        assert_ne!(deliverable_visual, deliverable_advanced);
    }
}
