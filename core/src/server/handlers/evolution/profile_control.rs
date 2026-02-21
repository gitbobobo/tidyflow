use tracing::info;

use crate::server::context::HandlerContext;

use super::profile::{
    default_stage_profiles, from_persisted_profiles, normalize_profiles,
    normalize_profiles_lenient, profile_key, profile_legacy_keys, to_persisted_profiles,
};
use super::utils::workspace_key;
use super::EvolutionManager;

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

        let direction_model = normalized
            .iter()
            .find(|item| item.stage == "direction")
            .and_then(|item| item.model.as_ref())
            .map(|m| format!("{}/{}", m.provider_id, m.model_id))
            .unwrap_or_else(|| "default".to_string());
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
            default_stage_profiles()
        } else {
            normalize_profiles_lenient(from_persisted_profiles(from_state))
        };

        let direction_model = profiles
            .iter()
            .find(|item| item.stage == "direction")
            .and_then(|item| item.model.as_ref())
            .map(|m| format!("{}/{}", m.provider_id, m.model_id))
            .unwrap_or_else(|| "default".to_string());
        info!(
            "evolution profile loaded: project={}, workspace={}, source={}, stages={}, direction_model={}",
            project,
            workspace,
            profile_source,
            profiles.len(),
            direction_model
        );

        profiles
    }
}
