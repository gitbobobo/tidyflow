use super::{EvolutionManager, StageSession};

impl EvolutionManager {
    pub(super) async fn set_stage_status(&self, key: &str, stage: &str, status: &str) {
        let mut state = self.state.lock().await;
        if let Some(entry) = state.workspaces.get_mut(key) {
            entry
                .stage_statuses
                .insert(stage.to_string(), status.to_string());
        }
    }

    pub(super) async fn set_stage_session(
        &self,
        key: &str,
        stage: &str,
        ai_tool: &str,
        session_id: &str,
    ) {
        let mut state = self.state.lock().await;
        if let Some(entry) = state.workspaces.get_mut(key) {
            entry.stage_sessions.insert(
                stage.to_string(),
                StageSession {
                    ai_tool: ai_tool.to_string(),
                    session_id: session_id.to_string(),
                },
            );
        }
    }

    pub(super) async fn next_seq(&self, key: &str) -> u64 {
        let mut state = self.state.lock().await;
        let seq = state.seq_by_workspace.entry(key.to_string()).or_insert(0);
        *seq += 1;
        *seq
    }

    pub(super) async fn can_run_with_priority(&self, key: &str) -> bool {
        let state = self.state.lock().await;
        let Some(entry) = state.workspaces.get(key) else {
            return false;
        };
        let current_priority = entry.priority;
        !state.workspaces.iter().any(|(other_key, other)| {
            other_key != key
                && !other.stop_requested
                && (other.status == "queued" || other.status == "running")
                && other.priority > current_priority
        })
    }
}
