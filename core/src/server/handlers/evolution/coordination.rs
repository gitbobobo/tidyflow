use std::collections::VecDeque;

use super::types::{ProjectCoordinationState, WorkspaceRunState};
use super::EvolutionManager;

const COORDINATION_WAIT_SLICE_MS: u64 = 120;

pub(super) enum CoordinationGateResult {
    Ready,
    Wait,
    Missing,
}

fn is_default_workspace(workspace: &str) -> bool {
    workspace.trim() == "default"
}

fn is_terminal_workspace_status(status: &str) -> bool {
    matches!(
        status.trim().to_ascii_lowercase().as_str(),
        "completed" | "failed_exhausted" | "failed_system" | "stopped" | "interrupted"
    )
}

fn is_running_stage_task(entry: &WorkspaceRunState) -> bool {
    entry.status == "running"
}

fn peer_workspace_name(
    workspaces: &std::collections::HashMap<String, WorkspaceRunState>,
    key: &str,
) -> Option<String> {
    workspaces.get(key).map(|entry| entry.workspace.clone())
}

fn clear_coordination(entry: &mut WorkspaceRunState) {
    entry.coordination_state = None;
    entry.coordination_reason = None;
    entry.coordination_peer_workspace = None;
    entry.coordination_queue_index = None;
}

fn set_coordination_wait(
    entry: &mut WorkspaceRunState,
    state: &str,
    reason: String,
    peer_workspace: Option<String>,
    queue_index: Option<u32>,
) {
    entry.coordination_state = Some(state.to_string());
    entry.coordination_reason = Some(reason);
    entry.coordination_peer_workspace = peer_workspace;
    entry.coordination_queue_index = queue_index;
}

fn ensure_project_state<'a>(
    coordination: &'a mut std::collections::HashMap<String, ProjectCoordinationState>,
    project: &str,
) -> &'a mut ProjectCoordinationState {
    coordination.entry(project.to_string()).or_default()
}

fn prune_integration_queue(
    project_state: &mut ProjectCoordinationState,
    workspaces: &std::collections::HashMap<String, WorkspaceRunState>,
    project: &str,
) {
    project_state.pending_integration_queue.retain(|queued_key| {
        let Some(entry) = workspaces.get(queued_key) else {
            return false;
        };
        entry.project == project
            && !is_default_workspace(&entry.workspace)
            && !is_terminal_workspace_status(&entry.status)
            && entry.current_stage == "integration"
    });
}

fn refresh_active_direction_summaries(
    project_state: &mut ProjectCoordinationState,
    workspaces: &std::collections::HashMap<String, WorkspaceRunState>,
    project: &str,
) {
    project_state.active_direction_summaries.clear();
    for (key, entry) in workspaces {
        if entry.project != project || is_terminal_workspace_status(&entry.status) {
            continue;
        }
        let Some(title) = entry
            .cycle_title
            .as_ref()
            .map(|value| value.trim())
            .filter(|value| !value.is_empty())
        else {
            continue;
        };
        project_state
            .active_direction_summaries
            .insert(key.clone(), title.to_string());
    }
}

fn project_has_pending_or_running_integration(
    project_state: &ProjectCoordinationState,
) -> bool {
    project_state.integration_lock_owner.is_some() || !project_state.pending_integration_queue.is_empty()
}

fn default_workspace_running(
    workspaces: &std::collections::HashMap<String, WorkspaceRunState>,
    project: &str,
) -> bool {
    workspaces.values().any(|entry| {
        entry.project == project
            && is_default_workspace(&entry.workspace)
            && is_running_stage_task(entry)
    })
}

fn queue_index(queue: &VecDeque<String>, key: &str) -> Option<u32> {
    queue.iter()
        .position(|queued| queued == key)
        .map(|idx| idx as u32)
}

impl EvolutionManager {
    pub(super) async fn coordination_wait_slice_ms(&self) -> u64 {
        COORDINATION_WAIT_SLICE_MS
    }

    pub(super) async fn release_project_coordination(&self, key: &str, stage: Option<&str>) {
        let mut state = self.state.lock().await;
        let workspaces_snapshot = state.workspaces.clone();
        let Some(project) = state
            .workspaces
            .get(key)
            .map(|entry| entry.project.clone())
        else {
            return;
        };
        if let Some(project_state) = state.project_coordination.get_mut(&project) {
            if project_state.direction_lock_owner.as_deref() == Some(key)
                && stage == Some("direction")
            {
                project_state.direction_lock_owner = None;
            }
            if project_state.integration_lock_owner.as_deref() == Some(key)
                && stage == Some("integration")
            {
                project_state.integration_lock_owner = None;
            }
            project_state.pending_integration_queue.retain(|queued| queued != key);
            refresh_active_direction_summaries(project_state, &workspaces_snapshot, &project);
        }
        if let Some(entry) = state.workspaces.get_mut(key) {
            clear_coordination(entry);
        }
    }

    pub(super) async fn project_direction_summaries(
        &self,
        project: &str,
        exclude_key: &str,
    ) -> Vec<serde_json::Value> {
        let state = self.state.lock().await;
        state
            .workspaces
            .iter()
            .filter(|(key, entry)| {
                entry.project == project
                    && *key != exclude_key
                    && !is_terminal_workspace_status(&entry.status)
            })
            .filter_map(|(_, entry)| {
                entry.cycle_title.as_ref().and_then(|title| {
                    let trimmed = title.trim();
                    if trimmed.is_empty() {
                        None
                    } else {
                        Some(serde_json::json!({
                            "workspace": entry.workspace,
                            "current_stage": entry.current_stage,
                            "direction": trimmed,
                        }))
                    }
                })
            })
            .collect()
    }

    pub(super) async fn project_integration_context(
        &self,
        project: &str,
        key: &str,
    ) -> (Vec<String>, Option<String>, Option<u32>) {
        let state = self.state.lock().await;
        let Some(project_state) = state.project_coordination.get(project) else {
            return (Vec::new(), None, None);
        };
        let queue = project_state
            .pending_integration_queue
            .iter()
            .filter_map(|queued_key| peer_workspace_name(&state.workspaces, queued_key))
            .collect::<Vec<_>>();
        let active = project_state
            .integration_lock_owner
            .as_deref()
            .and_then(|owner| peer_workspace_name(&state.workspaces, owner));
        let index = queue_index(&project_state.pending_integration_queue, key);
        (queue, active, index)
    }

    pub(super) async fn apply_project_coordination_gate(
        &self,
        key: &str,
    ) -> CoordinationGateResult {
        let mut state = self.state.lock().await;
        let Some((project, workspace, current_stage)) = state.workspaces.get(key).map(|entry| {
            (
                entry.project.clone(),
                entry.workspace.clone(),
                entry.current_stage.clone(),
            )
        }) else {
            return CoordinationGateResult::Missing;
        };

        let workspaces_snapshot = state.workspaces.clone();
        let project_state = ensure_project_state(&mut state.project_coordination, &project);
        prune_integration_queue(project_state, &workspaces_snapshot, &project);
        refresh_active_direction_summaries(project_state, &workspaces_snapshot, &project);

        if current_stage == "direction" {
            if project_state.direction_lock_owner.is_none()
                || project_state.direction_lock_owner.as_deref() == Some(key)
            {
                project_state.direction_lock_owner = Some(key.to_string());
                if let Some(entry) = state.workspaces.get_mut(key) {
                    clear_coordination(entry);
                }
                return CoordinationGateResult::Ready;
            }
            let peer = project_state
                .direction_lock_owner
                .as_deref()
                .and_then(|owner| peer_workspace_name(&workspaces_snapshot, owner));
            if let Some(entry) = state.workspaces.get_mut(key) {
                set_coordination_wait(
                    entry,
                    "waiting_direction_turn",
                    "等待同项目其他工作区完成方向选择".to_string(),
                    peer,
                    None,
                );
            }
            return CoordinationGateResult::Wait;
        }

        if current_stage == "integration" && !is_default_workspace(&workspace) {
            if project_state.integration_lock_owner.as_deref() != Some(key)
                && !project_state.pending_integration_queue.iter().any(|queued| queued == key)
            {
                project_state
                .pending_integration_queue
                .push_back(key.to_string());
            }

            if project_state.integration_lock_owner.as_deref() == Some(key) {
                if let Some(entry) = state.workspaces.get_mut(key) {
                    set_coordination_wait(
                        entry,
                        "integrating",
                        "正在执行项目级集成".to_string(),
                        None,
                        None,
                    );
                }
                return CoordinationGateResult::Ready;
            }

            if let Some(active_owner) = project_state.integration_lock_owner.as_deref() {
                let peer = peer_workspace_name(&workspaces_snapshot, active_owner);
                let idx = queue_index(&project_state.pending_integration_queue, key);
                if let Some(entry) = state.workspaces.get_mut(key) {
                    set_coordination_wait(
                        entry,
                        "waiting_integration_slot",
                        "等待同项目其他工作区完成 integration".to_string(),
                        peer,
                        idx,
                    );
                }
                return CoordinationGateResult::Wait;
            }

            let front = project_state.pending_integration_queue.front().cloned();
            if front.as_deref() != Some(key) {
                let peer = front
                    .as_deref()
                    .and_then(|queued_key| peer_workspace_name(&workspaces_snapshot, queued_key));
                let idx = queue_index(&project_state.pending_integration_queue, key);
                if let Some(entry) = state.workspaces.get_mut(key) {
                    set_coordination_wait(
                        entry,
                        "waiting_integration_slot",
                        "等待 FIFO integration 队列轮到当前工作区".to_string(),
                        peer,
                        idx,
                    );
                }
                return CoordinationGateResult::Wait;
            }

            if default_workspace_running(&workspaces_snapshot, &project) {
                if let Some(entry) = state.workspaces.get_mut(key) {
                    set_coordination_wait(
                        entry,
                        "waiting_mainline_stage_completion",
                        "等待主分支工作区完成当前阶段任务".to_string(),
                        Some("default".to_string()),
                        Some(0),
                    );
                }
                return CoordinationGateResult::Wait;
            }

            project_state.integration_lock_owner = Some(key.to_string());
            if project_state.pending_integration_queue.front().map(|v| v == key).unwrap_or(false) {
                project_state.pending_integration_queue.pop_front();
            }
            if let Some(entry) = state.workspaces.get_mut(key) {
                set_coordination_wait(
                    entry,
                    "integrating",
                    "正在执行项目级集成".to_string(),
                    None,
                    None,
                );
            }
            return CoordinationGateResult::Ready;
        }

        if is_default_workspace(&workspace) && project_has_pending_or_running_integration(project_state) {
            let peer = project_state
                .integration_lock_owner
                .as_deref()
                .and_then(|owner| peer_workspace_name(&workspaces_snapshot, owner))
                .or_else(|| {
                    project_state
                        .pending_integration_queue
                        .front()
                        .and_then(|queued| peer_workspace_name(&workspaces_snapshot, queued))
                });
            if let Some(entry) = state.workspaces.get_mut(key) {
                set_coordination_wait(
                    entry,
                    "waiting_project_integration_drain",
                    "等待项目中的功能分支依次完成 integration".to_string(),
                    peer,
                    None,
                );
            }
            return CoordinationGateResult::Wait;
        }

        if let Some(entry) = state.workspaces.get_mut(key) {
            clear_coordination(entry);
        }
        CoordinationGateResult::Ready
    }
}
