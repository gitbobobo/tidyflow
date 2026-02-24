use std::collections::HashMap;

use crate::server::handlers::ai::SharedAIState;
use crate::server::handlers::evolution_prompts::{
    STAGE_DIRECTION_PROMPT, STAGE_IMPLEMENT_PROMPT, STAGE_JUDGE_PROMPT, STAGE_PLAN_PROMPT,
    STAGE_REPORT_PROMPT, STAGE_VERIFY_PROMPT,
};
use crate::server::protocol::EvolutionAgentInfo;

use super::STAGES;
use super::StageSession;

const MAX_MESSAGE_LENGTH: usize = 200;

pub(super) async fn build_agents(
    stage_statuses: &HashMap<String, String>,
    stage_sessions: &HashMap<String, StageSession>,
    ai_state: &SharedAIState,
    workspace_root: &str,
) -> Vec<EvolutionAgentInfo> {
    let mut agents = Vec::with_capacity(STAGES.len());
    let ai_state_locked = ai_state.lock().await;

    for stage in STAGES {
        let status = stage_statuses
            .get(stage)
            .cloned()
            .unwrap_or_else(|| "pending".to_string());

        // 获取最新消息
        let latest_message = if let Some(session) = stage_sessions.get(stage) {
            get_latest_assistant_message(&ai_state_locked, workspace_root, &session.session_id, &session.ai_tool)
                .await
        } else {
            None
        };

        agents.push(EvolutionAgentInfo {
            stage: stage.to_string(),
            agent: agent_name(stage).to_string(),
            status,
            latest_message,
        });
    }
    agents
}

async fn get_latest_assistant_message(
    ai_state: &crate::server::handlers::ai::AIState,
    workspace_root: &str,
    session_id: &str,
    ai_tool: &str,
) -> Option<String> {
    let agent = ai_state.agents.get(ai_tool)?;
    let directory = workspace_root;

    let messages = match agent.list_messages(directory, session_id, Some(50)).await {
        Ok(m) => m,
        Err(_) => return None,
    };

    // 倒序查找最新的 assistant 消息
    for message in messages.iter().rev() {
        if message.role == "assistant" {
            // 提取 text 内容
            for part in &message.parts {
                if let Some(text) = &part.text {
                    if !text.trim().is_empty() {
                        return Some(truncate_message(text));
                    }
                }
            }
        }
    }

    None
}

fn truncate_message(text: &str) -> String {
    if text.len() > MAX_MESSAGE_LENGTH {
        format!("{}...", &text[..MAX_MESSAGE_LENGTH])
    } else {
        text.to_string()
    }
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
