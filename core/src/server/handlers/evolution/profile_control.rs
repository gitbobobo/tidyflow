use tracing::info;

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use crate::server::context::HandlerContext;

use super::profile::{
    default_stage_profiles, direction_model_label, from_persisted_profiles, normalize_profiles,
    normalize_profiles_lenient, profile_key, profile_legacy_keys, to_persisted_profiles,
};
use super::utils::workspace_key;
use super::EvolutionManager;

/// 全局学习状态存储（按 profile_key 隔离）
static LEARNING_STORE: OnceLock<Mutex<HashMap<String, super::profile::ProfileLearningState>>> =
    OnceLock::new();

pub(super) fn learning_store(
) -> &'static Mutex<HashMap<String, super::profile::ProfileLearningState>> {
    LEARNING_STORE.get_or_init(|| Mutex::new(HashMap::new()))
}

impl EvolutionManager {
    pub(super) async fn update_agent_profile(
        &self,
        project: &str,
        workspace: &str,
        stage_profiles: Vec<crate::server::protocol::EvolutionStageProfileInfo>,
        ctx: &HandlerContext,
    ) -> Result<Vec<crate::server::protocol::EvolutionStageProfileInfo>, String> {
        let normalized = normalize_profiles(stage_profiles)?;
        let storage_key = profile_key(project, workspace);
        let legacy_keys = profile_legacy_keys(project, workspace);
        {
            let mut state = ctx.app_state.write().await;
            state
                .client_settings
                .evolution_agent_profiles
                .insert(storage_key, to_persisted_profiles(&normalized));
            for legacy in legacy_keys {
                state
                    .client_settings
                    .evolution_agent_profiles
                    .remove(&legacy);
            }
        }
        let _ = ctx.save_tx.send(()).await;

        let key = workspace_key(project, workspace);
        {
            let mut state = self.state.lock().await;
            if let Some(entry) = state.workspaces.get_mut(&key) {
                if entry.status != "running" && entry.status != "queued" {
                    entry.stage_profiles = normalized.clone();
                }
            }
        }

        let direction_model = direction_model_label(&normalized);
        info!(
            "evolution profile updated: project={}, workspace={}, stages={}, direction_model={}",
            project,
            workspace,
            normalized.len(),
            direction_model
        );

        Ok(normalized)
    }

    pub(super) async fn get_agent_profile(
        &self,
        project: &str,
        workspace: &str,
        ctx: &HandlerContext,
    ) -> Vec<crate::server::protocol::EvolutionStageProfileInfo> {
        let storage_key = profile_key(project, workspace);
        let legacy_keys = profile_legacy_keys(project, workspace);
        let (profile_source, from_state) = {
            let state = ctx.app_state.read().await;
            let canonical = state
                .client_settings
                .evolution_agent_profiles
                .get(&storage_key)
                .cloned();
            if let Some(found) = canonical {
                ("canonical", found)
            } else {
                let legacy = legacy_keys
                    .into_iter()
                    .find_map(|key| {
                        state
                            .client_settings
                            .evolution_agent_profiles
                            .get(&key)
                            .cloned()
                    })
                    .unwrap_or_default();
                let source = if legacy.is_empty() {
                    "default"
                } else {
                    "legacy"
                };
                (source, legacy)
            }
        };

        let profiles = if from_state.is_empty() {
            let defaults = {
                let state = ctx.app_state.read().await;
                state.client_settings.evolution_default_profiles.clone()
            };
            if defaults.is_empty() {
                default_stage_profiles()
            } else {
                normalize_profiles_lenient(from_persisted_profiles(defaults))
            }
        } else {
            normalize_profiles_lenient(from_persisted_profiles(from_state))
        };

        let direction_model = direction_model_label(&profiles);
        info!(
            "evolution profile loaded: project={}, workspace={}, source={}, stages={}, direction_model={}",
            project,
            workspace,
            profile_source,
            profiles.len(),
            direction_model
        );

        // 自学习回退检查：如果连续失败超过阈值，回退到安全基线
        if let Some(baseline) = self.check_and_rollback(project, workspace) {
            info!(
                "profile learning: 使用安全基线 {}/{}, stages={}",
                project,
                workspace,
                baseline.len()
            );
            return baseline;
        }

        profiles
    }

    /// 记录阶段执行结果到学习状态
    pub(super) fn record_learning_result(
        &self,
        project: &str,
        workspace: &str,
        stage: &str,
        success: bool,
        duration_ms: Option<u64>,
        tool_calls: u32,
    ) {
        let key = profile_key(project, workspace);
        if let Ok(mut store) = learning_store().lock() {
            let state = store.entry(key).or_default();
            state.record_stage_result(stage, success, duration_ms, tool_calls);
            tracing::debug!(
                "profile learning: recorded {}/{} stage={} success={} duration={:?}",
                project,
                workspace,
                stage,
                success,
                duration_ms
            );
        }
    }

    /// 记录安全基线（门禁通过时调用）
    pub(super) fn record_safe_baseline(
        &self,
        project: &str,
        workspace: &str,
        profiles: Vec<crate::server::protocol::EvolutionStageProfileInfo>,
    ) {
        let key = profile_key(project, workspace);
        if let Ok(mut store) = learning_store().lock() {
            let state = store.entry(key).or_default();
            state.record_safe_baseline(profiles);
            info!(
                "profile learning: 记录安全基线 {}/{}",
                project, workspace
            );
        }
    }

    /// 检查是否应回退并返回安全基线
    pub(super) fn check_and_rollback(
        &self,
        project: &str,
        workspace: &str,
    ) -> Option<Vec<crate::server::protocol::EvolutionStageProfileInfo>> {
        let key = profile_key(project, workspace);
        if let Ok(mut store) = learning_store().lock() {
            if let Some(state) = store.get_mut(&key) {
                if state.should_rollback() {
                    tracing::warn!(
                        "profile learning: 触发回退 {}/{}，回退次数: {}",
                        project,
                        workspace,
                        state.rollback_count + 1
                    );
                    return state.rollback_to_baseline();
                }
            }
        }
        None
    }
}
