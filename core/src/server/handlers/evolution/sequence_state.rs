use crate::server::protocol::EvolutionSessionExecutionEntry;

use super::stage::agent_name;
use super::{EvolutionManager, StageSession, WorkspaceRunState};

fn is_terminal_session_status(status: &str) -> bool {
    matches!(
        status,
        "done" | "failed" | "blocked" | "skipped" | "stopped" | "interrupted" | "completed"
    )
}

fn is_in_rate_limit_cooldown(entry: &WorkspaceRunState) -> bool {
    let Some(resume_at) = entry.rate_limit_resume_at.as_deref() else {
        return false;
    };
    let Ok(resume_at) = chrono::DateTime::parse_from_rfc3339(resume_at) else {
        return true;
    };
    resume_at.with_timezone(&chrono::Utc) > chrono::Utc::now()
}

impl EvolutionManager {
    pub(super) async fn set_stage_status(&self, key: &str, stage: &str, status: &str) {
        let mut state = self.state.lock().await;
        if let Some(entry) = state.workspaces.get_mut(key) {
            entry
                .stage_statuses
                .insert(stage.to_string(), status.to_string());

            // 每次进入 running 状态时重置计时起点，确保重试链路中只统计本次代理会话耗时
            if status == "running" {
                entry
                    .stage_started_ats
                    .insert(stage.to_string(), chrono::Utc::now().to_rfc3339());
                // 清除上次完成的耗时，避免快照显示旧轮次的 duration
                entry.stage_duration_ms.remove(stage);
            }

            // 代理完成时计算耗时
            if status == "done" || status == "failed" || status == "skipped" {
                if let Some(started_at_str) = entry.stage_started_ats.get(stage) {
                    if let Ok(started_at) = chrono::DateTime::parse_from_rfc3339(started_at_str) {
                        let elapsed = chrono::Utc::now()
                            .signed_duration_since(started_at)
                            .num_milliseconds();
                        if elapsed > 0 {
                            entry
                                .stage_duration_ms
                                .insert(stage.to_string(), elapsed as u64);
                        }
                    }
                }
            }
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
            let stage_key = stage.to_string();
            let session = StageSession {
                ai_tool: ai_tool.to_string(),
                session_id: session_id.to_string(),
            };

            let history = entry
                .stage_session_history
                .entry(stage_key.clone())
                .or_insert_with(Vec::new);
            if !history.iter().any(|item| {
                item.ai_tool == session.ai_tool && item.session_id == session.session_id
            }) {
                history.push(session.clone());
            }

            entry.stage_sessions.insert(stage_key, session);
        }
    }

    pub(super) async fn record_session_execution_started(
        &self,
        key: &str,
        stage: &str,
        ai_tool: &str,
        session_id: &str,
    ) {
        let mut state = self.state.lock().await;
        let Some(entry) = state.workspaces.get_mut(key) else {
            return;
        };
        entry
            .session_executions
            .push(EvolutionSessionExecutionEntry {
                stage: stage.to_string(),
                agent: agent_name(stage).to_string(),
                ai_tool: ai_tool.to_string(),
                session_id: session_id.to_string(),
                status: "running".to_string(),
                started_at: chrono::Utc::now().to_rfc3339(),
                completed_at: None,
                duration_ms: None,
                tool_call_count: 0,
            });
    }

    pub(super) async fn finalize_session_execution(
        &self,
        key: &str,
        stage: &str,
        session_id: &str,
        status: &str,
        tool_call_count: u32,
    ) {
        let mut state = self.state.lock().await;
        let Some(entry) = state.workspaces.get_mut(key) else {
            return;
        };
        let Some(execution) = entry
            .session_executions
            .iter_mut()
            .rev()
            .find(|item| item.stage == stage && item.session_id == session_id)
        else {
            return;
        };

        execution.status = status.to_string();
        execution.tool_call_count = tool_call_count;

        if !is_terminal_session_status(status) {
            return;
        }

        if execution.completed_at.is_none() {
            let now = chrono::Utc::now();
            execution.completed_at = Some(now.to_rfc3339());
            if let Ok(started_at) = chrono::DateTime::parse_from_rfc3339(&execution.started_at) {
                let elapsed = now.signed_duration_since(started_at).num_milliseconds();
                if elapsed >= 0 {
                    execution.duration_ms = Some(elapsed as u64);
                }
            }
        }
    }

    /// 从已完成的会话执行中提取学习数据并馈送到参数自学习系统
    pub(super) async fn feed_learning_from_execution(
        &self,
        key: &str,
        stage: &str,
        session_id: &str,
    ) {
        let state = self.state.lock().await;
        let Some(entry) = state.workspaces.get(key) else {
            return;
        };
        let Some(execution) = entry
            .session_executions
            .iter()
            .rev()
            .find(|item| item.stage == stage && item.session_id == session_id)
        else {
            return;
        };
        let success = execution.status == "done" || execution.status == "completed";
        let duration_ms = execution.duration_ms;
        let tool_calls = execution.tool_call_count;
        let project = entry.project.clone();
        let workspace = entry.workspace.clone();
        drop(state);

        self.record_learning_result(&project, &workspace, stage, success, duration_ms, tool_calls);
    }

    pub(super) async fn stage_tool_call_count(&self, key: &str, stage: &str) -> u32 {
        let state = self.state.lock().await;
        state
            .workspaces
            .get(key)
            .and_then(|entry| entry.stage_tool_call_counts.get(stage).copied())
            .unwrap_or(0)
    }

    pub(super) async fn reset_stage_tool_call_tracking(&self, key: &str, stage: &str) {
        let mut state = self.state.lock().await;
        if let Some(entry) = state.workspaces.get_mut(key) {
            entry.stage_tool_call_counts.insert(stage.to_string(), 0);
            entry
                .stage_seen_tool_calls
                .insert(stage.to_string(), std::collections::HashSet::new());
        }
    }

    pub(super) async fn record_stage_tool_call(
        &self,
        key: &str,
        stage: &str,
        call_key: &str,
    ) -> bool {
        let normalized_key = call_key.trim();
        if normalized_key.is_empty() {
            return false;
        }
        let mut state = self.state.lock().await;
        let Some(entry) = state.workspaces.get_mut(key) else {
            return false;
        };
        let seen = entry
            .stage_seen_tool_calls
            .entry(stage.to_string())
            .or_insert_with(std::collections::HashSet::new);
        if !seen.insert(normalized_key.to_string()) {
            return false;
        }
        let count = entry
            .stage_tool_call_counts
            .entry(stage.to_string())
            .or_insert(0);
        *count += 1;
        true
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
                && !is_in_rate_limit_cooldown(other)
                && other.priority > current_priority
        })
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::super::types::WorkspaceRunState;
    use super::EvolutionManager;

    fn workspace_state(priority: i32, status: &str) -> WorkspaceRunState {
        WorkspaceRunState {
            project: "p".to_string(),
            workspace: "w".to_string(),
            workspace_root: "/tmp".to_string(),
            priority,
            status: status.to_string(),
            cycle_id: "cycle-1".to_string(),
            cycle_title: None,
            current_stage: "verify.1".to_string(),
            global_loop_round: 1,
            loop_round_limit: 1,
            verify_iteration: 0,
            verify_iteration_limit: 1,
            backlog_contract_version: 2,
            created_at: "2026-03-01T00:00:00Z".to_string(),
            stop_requested: false,
            terminal_reason_code: None,
            terminal_error_message: None,
            rate_limit_resume_at: None,
            rate_limit_error_message: None,
            stage_profiles: Vec::new(),
            stage_statuses: HashMap::new(),
            stage_sessions: HashMap::new(),
            stage_session_history: HashMap::new(),
            stage_tool_call_counts: HashMap::new(),
            stage_seen_tool_calls: HashMap::new(),
            stage_retry_counts: HashMap::new(),
            session_executions: Vec::new(),
            stage_started_ats: HashMap::new(),
            stage_duration_ms: HashMap::new(),
        }
    }

    #[tokio::test]
    async fn session_execution_should_track_multiple_sessions_per_stage() {
        let manager = EvolutionManager::new();
        let key = "p:w".to_string();
        {
            let mut state = manager.state.lock().await;
            state
                .workspaces
                .insert(key.clone(), workspace_state(0, "running"));
        }

        manager
            .record_session_execution_started(&key, "verify.1", "codex", "sess-1")
            .await;
        manager
            .record_session_execution_started(&key, "verify.1", "codex", "sess-2")
            .await;

        manager
            .finalize_session_execution(&key, "verify.1", "sess-1", "done", 2)
            .await;
        manager
            .finalize_session_execution(&key, "verify.1", "sess-2", "failed", 4)
            .await;

        let state = manager.state.lock().await;
        let entry = state.workspaces.get(&key).expect("workspace should exist");
        assert_eq!(entry.session_executions.len(), 2);
        assert_eq!(entry.session_executions[0].session_id, "sess-1");
        assert_eq!(entry.session_executions[1].session_id, "sess-2");
        assert_eq!(entry.session_executions[0].status, "done");
        assert_eq!(entry.session_executions[1].status, "failed");
        assert_eq!(entry.session_executions[0].tool_call_count, 2);
        assert_eq!(entry.session_executions[1].tool_call_count, 4);
        assert!(entry.session_executions[0].completed_at.is_some());
        assert!(entry.session_executions[1].completed_at.is_some());
    }

    #[tokio::test]
    async fn can_run_with_priority_should_ignore_higher_priority_workspace_in_rate_limit_cooldown()
    {
        let manager = EvolutionManager::new();
        let future_resume_at = (chrono::Utc::now() + chrono::Duration::minutes(10)).to_rfc3339();
        {
            let mut state = manager.state.lock().await;
            state
                .workspaces
                .insert("low".to_string(), workspace_state(1, "queued"));
            let mut high = workspace_state(5, "queued");
            high.rate_limit_resume_at = Some(future_resume_at);
            state.workspaces.insert("high".to_string(), high);
        }

        assert!(
            manager.can_run_with_priority("low").await,
            "未来 resume_at 的高优先级工作区不应阻塞低优先级工作区"
        );
    }

    #[tokio::test]
    async fn can_run_with_priority_should_still_block_when_higher_priority_workspace_is_runnable() {
        let manager = EvolutionManager::new();
        {
            let mut state = manager.state.lock().await;
            state
                .workspaces
                .insert("low".to_string(), workspace_state(1, "queued"));
            let mut high = workspace_state(5, "queued");
            high.rate_limit_resume_at =
                Some((chrono::Utc::now() - chrono::Duration::minutes(1)).to_rfc3339());
            state.workspaces.insert("high".to_string(), high);
        }

        assert!(
            !manager.can_run_with_priority("low").await,
            "已过期的 resume_at 不应取消优先级阻塞"
        );
    }

    #[tokio::test]
    async fn can_run_with_priority_should_ignore_invalid_resume_at_instead_of_starving_queue() {
        let manager = EvolutionManager::new();
        {
            let mut state = manager.state.lock().await;
            state
                .workspaces
                .insert("low".to_string(), workspace_state(1, "queued"));
            let mut high = workspace_state(5, "queued");
            high.rate_limit_resume_at = Some("invalid-rfc3339".to_string());
            state.workspaces.insert("high".to_string(), high);
        }

        assert!(
            manager.can_run_with_priority("low").await,
            "非法 resume_at 不应阻塞可立即执行的低优先级工作区"
        );
    }
}
