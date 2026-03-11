use std::collections::HashMap;

use crate::server::handlers::ai::normalize_ai_tool;
use crate::server::protocol::ai;
use crate::server::protocol::EvolutionStageProfileInfo;
use crate::workspace::state::{EvolutionModelSelection, EvolutionStageProfile};

use super::consts::{stage_profile_stage, PROFILE_STAGES};

pub(super) fn default_evolution_ai_tool() -> String {
    "codex".to_string()
}

pub(super) fn normalize_profiles(
    input: Vec<EvolutionStageProfileInfo>,
) -> Result<Vec<EvolutionStageProfileInfo>, String> {
    let mut by_stage: HashMap<String, EvolutionStageProfileInfo> = HashMap::new();
    for profile in input {
        let normalized = profile.normalized_stage();
        if normalized == "bootstrap" {
            continue;
        }
        let stages: Vec<String> = if normalized == "implement" {
            vec![
                "implement_general".to_string(),
                "implement_visual".to_string(),
            ]
        } else {
            vec![normalized]
        };
        for stage in stages {
            if PROFILE_STAGES.contains(&stage.as_str()) {
                let ai_tool = normalize_ai_tool_compatible(&profile.ai_tool).ok_or_else(|| {
                    format!("invalid ai_tool for stage '{}': {}", stage, profile.ai_tool)
                })?;
                by_stage.insert(
                    stage.clone(),
                    EvolutionStageProfileInfo {
                        stage,
                        ai_tool,
                        mode: profile.mode.clone(),
                        model: profile.model.clone(),
                        config_options: profile.config_options.clone(),
                    },
                );
            }
        }
    }

    let mut result = Vec::with_capacity(PROFILE_STAGES.len());
    for stage in PROFILE_STAGES {
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
        let normalized = profile.normalized_stage();
        if normalized == "bootstrap" {
            continue;
        }
        let stages: Vec<String> = if normalized == "implement" {
            vec![
                "implement_general".to_string(),
                "implement_visual".to_string(),
            ]
        } else {
            vec![normalized]
        };
        for stage in stages {
            if !PROFILE_STAGES.contains(&stage.as_str()) {
                continue;
            }
            let ai_tool = normalize_ai_tool_compatible(&profile.ai_tool)
                .unwrap_or_else(default_evolution_ai_tool);
            by_stage.insert(
                stage.clone(),
                EvolutionStageProfileInfo {
                    stage,
                    ai_tool,
                    mode: profile.mode.clone(),
                    model: profile.model.clone(),
                    config_options: profile.config_options.clone(),
                },
            );
        }
    }

    PROFILE_STAGES
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
    PROFILE_STAGES
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
    let normalized = stage_profile_stage(stage).unwrap_or_else(|| stage.trim().to_string());
    profiles
        .iter()
        .find(|p| p.stage == normalized)
        .cloned()
        .unwrap_or(EvolutionStageProfileInfo {
            stage: normalized,
            ai_tool: default_evolution_ai_tool(),
            mode: None,
            model: None,
            config_options: HashMap::new(),
        })
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

// ============================================================================
// 参数自学习：按 (project, workspace) 隔离的执行历史与学习状态
// ============================================================================

/// 单个阶段的执行统计摘要
#[derive(Clone, Debug, Default)]
pub(super) struct StageExecutionStats {
    /// 成功次数
    pub(super) success_count: u32,
    /// 失败次数
    pub(super) failure_count: u32,
    /// 平均耗时（毫秒）
    pub(super) avg_duration_ms: Option<u64>,
    /// 最近一次耗时（毫秒）
    pub(super) last_duration_ms: Option<u64>,
    /// 累积 tool call 总数
    pub(super) total_tool_calls: u32,
    /// 最近连续失败次数（成功后归零）
    pub(super) consecutive_failures: u32,
}

impl StageExecutionStats {
    /// 记录一次阶段执行结果
    pub(super) fn record(&mut self, success: bool, duration_ms: Option<u64>, tool_calls: u32) {
        if success {
            self.success_count += 1;
            self.consecutive_failures = 0;
        } else {
            self.failure_count += 1;
            self.consecutive_failures += 1;
        }
        self.total_tool_calls += tool_calls;
        if let Some(dur) = duration_ms {
            self.last_duration_ms = Some(dur);
            let total_count = self.success_count + self.failure_count;
            if let Some(prev_avg) = self.avg_duration_ms {
                // 滑动平均
                self.avg_duration_ms =
                    Some((prev_avg * (total_count as u64 - 1) + dur) / total_count as u64);
            } else {
                self.avg_duration_ms = Some(dur);
            }
        }
    }

    /// 成功率 (0.0 - 1.0)
    pub(super) fn success_rate(&self) -> f64 {
        let total = self.success_count + self.failure_count;
        if total == 0 {
            return 1.0;
        }
        self.success_count as f64 / total as f64
    }
}

/// 按 (project, workspace) 隔离的参数学习状态
#[derive(Clone, Debug, Default)]
pub(super) struct ProfileLearningState {
    /// 各阶段执行统计：stage_name → stats
    pub(super) stage_stats: std::collections::HashMap<String, StageExecutionStats>,
    /// 安全基线配置快照（最后一次门禁通过时的配置）
    pub(super) safe_baseline_profiles:
        Option<Vec<crate::server::protocol::EvolutionStageProfileInfo>>,
    /// 基线记录时间（RFC3339）
    pub(super) baseline_recorded_at: Option<String>,
    /// 回退次数（用于防止频繁回退）
    pub(super) rollback_count: u32,
}

/// 最大连续失败次数阈值，超过后触发回退
pub(super) const LEARNING_ROLLBACK_THRESHOLD: u32 = 3;
/// 最大回退次数，超过后锁定到安全基线
pub(super) const LEARNING_MAX_ROLLBACKS: u32 = 5;

impl ProfileLearningState {
    /// 记录阶段执行结果
    pub(super) fn record_stage_result(
        &mut self,
        stage: &str,
        success: bool,
        duration_ms: Option<u64>,
        tool_calls: u32,
    ) {
        let stats = self.stage_stats.entry(stage.to_string()).or_default();
        stats.record(success, duration_ms, tool_calls);
    }

    /// 检查是否应回退到安全基线
    pub(super) fn should_rollback(&self) -> bool {
        if self.safe_baseline_profiles.is_none() {
            return false;
        }
        if self.rollback_count >= LEARNING_MAX_ROLLBACKS {
            return true; // 已达上限，始终使用安全基线
        }
        // 任意阶段连续失败超过阈值
        self.stage_stats
            .values()
            .any(|s| s.consecutive_failures >= LEARNING_ROLLBACK_THRESHOLD)
    }

    /// 记录安全基线（门禁通过时调用）
    pub(super) fn record_safe_baseline(
        &mut self,
        profiles: Vec<crate::server::protocol::EvolutionStageProfileInfo>,
    ) {
        self.safe_baseline_profiles = Some(profiles);
        self.baseline_recorded_at = Some(chrono::Utc::now().to_rfc3339());
        // 门禁通过时重置回退计数
        self.rollback_count = 0;
    }

    /// 执行回退并返回安全基线
    pub(super) fn rollback_to_baseline(
        &mut self,
    ) -> Option<Vec<crate::server::protocol::EvolutionStageProfileInfo>> {
        self.rollback_count += 1;
        // 重置所有阶段的连续失败计数
        for stats in self.stage_stats.values_mut() {
            stats.consecutive_failures = 0;
        }
        self.safe_baseline_profiles.clone()
    }
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
        assert_eq!(normalized.len(), PROFILE_STAGES.len());
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
        assert_eq!(normalized.len(), PROFILE_STAGES.len());
        assert_eq!(normalized[0].stage, "direction");
        assert!(normalized.iter().all(|item| item.stage != "bootstrap"));
    }

    #[test]
    fn profile_learning_records_success() {
        let mut state = ProfileLearningState::default();
        state.record_stage_result("direction", true, Some(5000), 10);
        let stats = state.stage_stats.get("direction").unwrap();
        assert_eq!(stats.success_count, 1);
        assert_eq!(stats.failure_count, 0);
        assert_eq!(stats.consecutive_failures, 0);
        assert!((stats.success_rate() - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn profile_learning_records_failure_and_rollback() {
        let mut state = ProfileLearningState::default();
        // 记录安全基线
        state.record_safe_baseline(default_stage_profiles());
        // 连续失败
        for _ in 0..LEARNING_ROLLBACK_THRESHOLD {
            state.record_stage_result("verify", false, Some(3000), 5);
        }
        assert!(state.should_rollback());
        let baseline = state.rollback_to_baseline();
        assert!(baseline.is_some());
        assert_eq!(state.rollback_count, 1);
        // 回退后连续失败计数重置
        let stats = state.stage_stats.get("verify").unwrap();
        assert_eq!(stats.consecutive_failures, 0);
    }

    #[test]
    fn profile_learning_no_rollback_without_baseline() {
        let mut state = ProfileLearningState::default();
        for _ in 0..10 {
            state.record_stage_result("verify", false, Some(3000), 5);
        }
        // 没有基线时不应触发回退
        assert!(!state.should_rollback());
    }

    #[test]
    fn profile_learning_max_rollback_locks_baseline() {
        let mut state = ProfileLearningState::default();
        state.record_safe_baseline(default_stage_profiles());
        state.rollback_count = LEARNING_MAX_ROLLBACKS;
        // 达到回退上限后，should_rollback 始终返回 true
        assert!(state.should_rollback());
    }

    #[test]
    fn profile_learning_success_resets_consecutive_failures() {
        let mut state = ProfileLearningState::default();
        state.record_stage_result("plan", false, None, 0);
        state.record_stage_result("plan", false, None, 0);
        assert_eq!(state.stage_stats["plan"].consecutive_failures, 2);
        state.record_stage_result("plan", true, Some(2000), 3);
        assert_eq!(state.stage_stats["plan"].consecutive_failures, 0);
        assert_eq!(state.stage_stats["plan"].success_count, 1);
        assert_eq!(state.stage_stats["plan"].failure_count, 2);
    }

    #[test]
    fn profile_learning_safe_baseline_resets_rollback_count() {
        let mut state = ProfileLearningState::default();
        state.rollback_count = 3;
        state.record_safe_baseline(default_stage_profiles());
        assert_eq!(state.rollback_count, 0);
    }
}
