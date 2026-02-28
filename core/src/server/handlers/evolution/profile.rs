use std::collections::HashMap;

use crate::server::handlers::ai::normalize_ai_tool;
use crate::server::protocol::ai;
use crate::server::protocol::{
    EvolutionImplementAgentProfileInfo, EvolutionImplementAgentProfilesInfo,
    EvolutionStageProfileInfo,
};
use crate::workspace::state::{
    EvolutionImplementAgentProfile, EvolutionImplementAgentProfiles, EvolutionModelSelection,
    EvolutionStageProfile,
};

use super::STAGES;

pub(super) fn default_evolution_ai_tool() -> String {
    "codex".to_string()
}

pub(super) fn normalize_profiles(
    input: Vec<EvolutionStageProfileInfo>,
) -> Result<Vec<EvolutionStageProfileInfo>, String> {
    let mut by_stage: HashMap<String, EvolutionStageProfileInfo> = HashMap::new();
    for profile in input {
        let stage = profile.normalized_stage();
        if profile.is_legacy_bootstrap_stage() {
            continue;
        }
        if STAGES.contains(&stage.as_str()) {
            let ai_tool = normalize_ai_tool_compatible(&profile.ai_tool).ok_or_else(|| {
                format!("invalid ai_tool for stage '{}': {}", stage, profile.ai_tool)
            })?;
            by_stage.insert(
                stage.clone(),
                EvolutionStageProfileInfo {
                    stage,
                    ai_tool,
                    mode: profile.mode,
                    model: profile.model,
                    config_options: profile.config_options,
                },
            );
        }
    }

    let mut result = Vec::with_capacity(STAGES.len());
    for stage in STAGES {
        result.push(by_stage.remove(stage).unwrap_or(EvolutionStageProfileInfo {
            stage: stage.to_string(),
            ai_tool: default_evolution_ai_tool(),
            mode: None,
            model: None,
            config_options: HashMap::new(),
        }));
    }
    Ok(result)
}

pub(super) fn normalize_profiles_lenient(
    input: Vec<EvolutionStageProfileInfo>,
) -> Vec<EvolutionStageProfileInfo> {
    let mut by_stage: HashMap<String, EvolutionStageProfileInfo> = HashMap::new();
    for profile in input {
        let stage = profile.normalized_stage();
        if profile.is_legacy_bootstrap_stage() {
            continue;
        }
        if !STAGES.contains(&stage.as_str()) {
            continue;
        }
        let ai_tool = normalize_ai_tool_compatible(&profile.ai_tool)
            .unwrap_or_else(default_evolution_ai_tool);
        by_stage.insert(
            stage.clone(),
            EvolutionStageProfileInfo {
                stage,
                ai_tool,
                mode: profile.mode,
                model: profile.model,
                config_options: profile.config_options,
            },
        );
    }

    STAGES
        .iter()
        .map(|stage| {
            by_stage
                .remove(*stage)
                .unwrap_or(EvolutionStageProfileInfo {
                    stage: stage.to_string(),
                    ai_tool: default_evolution_ai_tool(),
                    mode: None,
                    model: None,
                    config_options: HashMap::new(),
                })
        })
        .collect()
}

pub(super) fn direction_model_label(profiles: &[EvolutionStageProfileInfo]) -> String {
    profiles
        .iter()
        .find(|item| item.normalized_stage() == "direction")
        .and_then(|item| item.model.as_ref())
        .map(|m| format!("{}/{}", m.provider_id, m.model_id))
        .unwrap_or_else(|| "default".to_string())
}

pub(super) fn default_stage_profiles() -> Vec<EvolutionStageProfileInfo> {
    STAGES
        .iter()
        .map(|stage| EvolutionStageProfileInfo {
            stage: stage.to_string(),
            ai_tool: default_evolution_ai_tool(),
            mode: None,
            model: None,
            config_options: HashMap::new(),
        })
        .collect()
}

pub(super) fn profile_for_stage(
    profiles: &[EvolutionStageProfileInfo],
    stage: &str,
) -> EvolutionStageProfileInfo {
    profiles
        .iter()
        .find(|p| p.stage == stage)
        .cloned()
        .unwrap_or(EvolutionStageProfileInfo {
            stage: stage.to_string(),
            ai_tool: default_evolution_ai_tool(),
            mode: None,
            model: None,
            config_options: HashMap::new(),
        })
}

pub(super) fn default_implement_agent_profile() -> EvolutionImplementAgentProfileInfo {
    EvolutionImplementAgentProfileInfo {
        ai_tool: default_evolution_ai_tool(),
        mode: None,
        model: None,
        config_options: HashMap::new(),
    }
}

fn normalize_implement_agent_profile(
    input: EvolutionImplementAgentProfileInfo,
) -> EvolutionImplementAgentProfileInfo {
    let ai_tool = normalize_ai_tool_compatible(&input.ai_tool).unwrap_or_else(default_evolution_ai_tool);
    EvolutionImplementAgentProfileInfo {
        ai_tool,
        mode: input.mode,
        model: input.model,
        config_options: input.config_options,
    }
}

pub(super) fn normalize_implement_agent_profiles(
    input: EvolutionImplementAgentProfilesInfo,
) -> EvolutionImplementAgentProfilesInfo {
    EvolutionImplementAgentProfilesInfo {
        general: normalize_implement_agent_profile(input.general),
        visual: normalize_implement_agent_profile(input.visual),
        advanced: normalize_implement_agent_profile(input.advanced),
    }
}

pub(super) fn to_persisted_profiles(
    input: &[EvolutionStageProfileInfo],
) -> Vec<EvolutionStageProfile> {
    input
        .iter()
        .map(|p| EvolutionStageProfile {
            stage: p.stage.clone(),
            ai_tool: p.ai_tool.clone(),
            mode: p.mode.clone(),
            model: p.model.as_ref().map(|m| EvolutionModelSelection {
                provider_id: m.provider_id.clone(),
                model_id: m.model_id.clone(),
            }),
            config_options: p.config_options.clone(),
        })
        .collect()
}

pub(super) fn from_persisted_profiles(
    input: Vec<EvolutionStageProfile>,
) -> Vec<EvolutionStageProfileInfo> {
    input
        .into_iter()
        .map(|p| EvolutionStageProfileInfo {
            stage: p.stage,
            ai_tool: p.ai_tool,
            mode: p.mode,
            model: p.model.map(|m| ai::ModelSelection {
                provider_id: m.provider_id,
                model_id: m.model_id,
            }),
            config_options: p.config_options,
        })
        .collect()
}

pub(super) fn from_persisted_implement_profiles(
    input: EvolutionImplementAgentProfiles,
) -> EvolutionImplementAgentProfilesInfo {
    fn to_protocol(input: EvolutionImplementAgentProfile) -> EvolutionImplementAgentProfileInfo {
        EvolutionImplementAgentProfileInfo {
            ai_tool: input.ai_tool,
            mode: input.mode,
            model: input.model.map(|m| ai::ModelSelection {
                provider_id: m.provider_id,
                model_id: m.model_id,
            }),
            config_options: input.config_options,
        }
    }

    normalize_implement_agent_profiles(EvolutionImplementAgentProfilesInfo {
        general: to_protocol(input.general),
        visual: to_protocol(input.visual),
        advanced: to_protocol(input.advanced),
    })
}

pub(super) fn profile_key(project: &str, workspace: &str) -> String {
    format!(
        "{}/{}",
        normalize_profile_project_name(project),
        normalize_profile_workspace_name(workspace)
    )
}

pub(super) fn profile_legacy_keys(project: &str, workspace: &str) -> Vec<String> {
    let mut keys: Vec<String> = Vec::new();
    let project_trimmed = project.trim();
    let workspace_trimmed = workspace.trim();
    let canonical = profile_key(project, workspace);

    let raw = format!("{}/{}", project, workspace);
    if raw != canonical {
        keys.push(raw);
    }

    let trimmed = format!("{}/{}", project_trimmed, workspace_trimmed);
    if trimmed != canonical && !keys.contains(&trimmed) {
        keys.push(trimmed);
    }

    if normalize_profile_workspace_name(workspace) == "default" {
        let legacy_default = format!("{}/(default)", normalize_profile_project_name(project));
        if legacy_default != canonical && !keys.contains(&legacy_default) {
            keys.push(legacy_default);
        }
    }

    keys
}

fn normalize_profile_project_name(project: &str) -> String {
    project.trim().to_string()
}

fn normalize_profile_workspace_name(workspace: &str) -> String {
    let trimmed = workspace.trim();
    if trimmed.eq_ignore_ascii_case("default") || trimmed.eq_ignore_ascii_case("(default)") {
        "default".to_string()
    } else {
        trimmed.to_string()
    }
}

fn normalize_ai_tool_compatible(tool: &str) -> Option<String> {
    if let Ok(v) = normalize_ai_tool(tool) {
        return Some(v);
    }

    let normalized = tool.trim().to_lowercase().replace('_', "-");
    let mapped = match normalized.as_str() {
        "open-code" => "opencode",
        "codex-app-server" | "codex-app" => "codex",
        "copilot-acp" | "github-copilot" => "copilot",
        "kimi-code" => "kimi",
        _ => return None,
    };
    Some(mapped.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profile_key_should_normalize_default_workspace_alias() {
        let canonical = profile_key("tidyflow", "default");
        assert_eq!(canonical, "tidyflow/default");
        assert_eq!(profile_key(" tidyflow ", "(default)"), canonical);
    }

    #[test]
    fn normalize_ai_tool_compatible_should_map_legacy_values() {
        assert_eq!(
            normalize_ai_tool_compatible("codex-app-server").as_deref(),
            Some("codex")
        );
        assert_eq!(
            normalize_ai_tool_compatible("github-copilot").as_deref(),
            Some("copilot")
        );
        assert_eq!(
            normalize_ai_tool_compatible("open-code").as_deref(),
            Some("opencode")
        );
        assert_eq!(
            normalize_ai_tool_compatible("kimi-code").as_deref(),
            Some("kimi")
        );
        assert_eq!(normalize_ai_tool_compatible("unknown-tool"), None);
    }

    #[test]
    fn normalize_profiles_lenient_should_fallback_invalid_ai_tool_to_default() {
        let profiles = vec![EvolutionStageProfileInfo {
            stage: "direction".to_string(),
            ai_tool: "legacy-unsupported-tool".to_string(),
            mode: Some("Default".to_string()),
            model: Some(ai::ModelSelection {
                provider_id: "codex".to_string(),
                model_id: "gpt-5.3-codex".to_string(),
            }),
            config_options: HashMap::new(),
        }];

        let normalized = normalize_profiles_lenient(profiles);
        let direction = normalized
            .into_iter()
            .find(|item| item.stage == "direction")
            .expect("missing direction stage");
        assert_eq!(direction.ai_tool, "codex");
    }

    #[test]
    fn normalize_profiles_should_ignore_legacy_bootstrap_stage() {
        let profiles = vec![
            EvolutionStageProfileInfo {
                stage: "bootstrap".to_string(),
                ai_tool: "codex".to_string(),
                mode: None,
                model: None,
                config_options: HashMap::new(),
            },
            EvolutionStageProfileInfo {
                stage: "direction".to_string(),
                ai_tool: "copilot".to_string(),
                mode: None,
                model: None,
                config_options: HashMap::new(),
            },
        ];

        let normalized = normalize_profiles(profiles).expect("normalize should succeed");
        assert_eq!(normalized.len(), STAGES.len());
        assert_eq!(normalized[0].stage, "direction");
        assert!(normalized.iter().all(|item| item.stage != "bootstrap"));
    }

    #[test]
    fn normalize_profiles_lenient_should_ignore_legacy_bootstrap_stage() {
        let profiles = vec![EvolutionStageProfileInfo {
            stage: " Bootstrap ".to_string(),
            ai_tool: "codex".to_string(),
            mode: None,
            model: None,
            config_options: HashMap::new(),
        }];

        let normalized = normalize_profiles_lenient(profiles);
        assert_eq!(normalized.len(), STAGES.len());
        assert_eq!(normalized[0].stage, "direction");
        assert!(normalized.iter().all(|item| item.stage != "bootstrap"));
    }
}
