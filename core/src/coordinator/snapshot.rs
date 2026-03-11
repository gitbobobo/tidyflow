//! 跨工作区状态快照生成与恢复
//!
//! 支持将协调层状态序列化为可持久化的快照，
//! 并在异常中断后从快照恢复协调层状态。
//!
//! ## 设计要点
//!
//! - 快照显式区分瞬时状态和持久化状态，恢复时仅加载持久化部分。
//! - 每个工作区的快照独立，支持选择性恢复（单个工作区或全部）。
//! - 恢复入口由 Core 驱动，不依赖客户端自行推导重建。

use std::collections::HashMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::identity::{CoordinatorScope, WorkspaceCoordinatorId};
use super::model::{
    AiDomainPhase, AiDomainState, CoordinatorHealth, FileDomainPhase, FileDomainState,
    TerminalDomainPhase, TerminalDomainState, WorkspaceCoordinatorState,
};

/// 快照版本，用于向前兼容
pub const SNAPSHOT_VERSION: u32 = 1;

// ============================================================================
// 工作区快照条目
// ============================================================================

/// 持久化部分：可写入存储的协调元数据
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PersistableCoordinatorMeta {
    /// AI 领域相位（用于恢复后的初始判断）
    pub ai_phase: AiDomainPhase,
    /// 终端领域相位
    pub terminal_phase: TerminalDomainPhase,
    /// 文件领域相位
    pub file_phase: FileDomainPhase,
    /// 协调健康度
    pub health: CoordinatorHealth,
    /// 状态版本号
    pub version: u64,
}

impl From<&WorkspaceCoordinatorState> for PersistableCoordinatorMeta {
    fn from(state: &WorkspaceCoordinatorState) -> Self {
        Self {
            ai_phase: state.ai.phase,
            terminal_phase: state.terminal.phase,
            file_phase: state.file.phase,
            health: state.health,
            version: state.version,
        }
    }
}

/// 单个工作区的协调层快照条目
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkspaceSnapshotEntry {
    /// 工作区身份
    pub id: WorkspaceCoordinatorId,
    /// 持久化元数据（可恢复部分）
    pub persistable: PersistableCoordinatorMeta,
    /// 快照生成时间
    pub captured_at: DateTime<Utc>,
}

// ============================================================================
// 跨工作区快照
// ============================================================================

/// 跨工作区协调层快照
///
/// 包含所有工作区的协调元数据，可序列化写入存储。
/// 恢复时按作用域选择性加载。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CoordinatorSnapshot {
    /// 快照格式版本
    pub snapshot_version: u32,
    /// 快照生成时间
    pub created_at: DateTime<Utc>,
    /// 工作区快照条目（键为 global_key）
    pub workspaces: HashMap<String, WorkspaceSnapshotEntry>,
}

impl CoordinatorSnapshot {
    /// 从协调层状态集合生成快照
    pub fn capture(states: &HashMap<String, WorkspaceCoordinatorState>) -> Self {
        let workspaces = states
            .iter()
            .map(|(key, state)| {
                let entry = WorkspaceSnapshotEntry {
                    id: state.id.clone(),
                    persistable: PersistableCoordinatorMeta::from(state),
                    captured_at: Utc::now(),
                };
                (key.clone(), entry)
            })
            .collect();

        Self {
            snapshot_version: SNAPSHOT_VERSION,
            created_at: Utc::now(),
            workspaces,
        }
    }

    /// 按作用域筛选快照条目
    pub fn entries_for_scope(&self, scope: &CoordinatorScope) -> Vec<&WorkspaceSnapshotEntry> {
        self.workspaces
            .values()
            .filter(|entry| scope.contains(&entry.id))
            .collect()
    }

    /// 工作区数量
    pub fn workspace_count(&self) -> usize {
        self.workspaces.len()
    }

    /// 快照是否为空
    pub fn is_empty(&self) -> bool {
        self.workspaces.is_empty()
    }

    /// JSON 序列化（用于持久化写入）
    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string_pretty(self)
    }

    /// 从 JSON 反序列化（用于持久化加载）
    pub fn from_json(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json)
    }
}

// ============================================================================
// 恢复入口
// ============================================================================

/// 恢复结果状态
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RecoveryStatus {
    /// 恢复成功
    Restored,
    /// 部分恢复（某些工作区快照条目缺失或损坏）
    PartiallyRestored,
    /// 未找到有效快照
    NoSnapshot,
    /// 恢复失败
    Failed,
}

/// 单个工作区的恢复结果
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkspaceRecoveryResult {
    pub id: WorkspaceCoordinatorId,
    pub status: RecoveryStatus,
    /// 恢复后的协调状态（成功时有值）
    pub recovered_state: Option<WorkspaceCoordinatorState>,
    /// 恢复说明
    pub message: String,
}

/// 恢复入口：从快照恢复协调层状态
///
/// 异常中断后由 Core 调用，不依赖客户端推导。
/// 返回每个工作区的恢复结果，调用方可据此决定后续动作。
pub fn restore_from_snapshot(
    snapshot: &CoordinatorSnapshot,
    scope: &CoordinatorScope,
) -> Vec<WorkspaceRecoveryResult> {
    let entries = snapshot.entries_for_scope(scope);

    if entries.is_empty() {
        return vec![WorkspaceRecoveryResult {
            id: WorkspaceCoordinatorId::new("_system", "_none"),
            status: RecoveryStatus::NoSnapshot,
            recovered_state: None,
            message: "指定作用域内无快照条目".to_string(),
        }];
    }

    entries
        .into_iter()
        .map(|entry| {
            // 从持久化元数据重建协调状态
            // 瞬时部分（活跃会话数、终端数等）归零，仅保留相位和版本
            let mut state = WorkspaceCoordinatorState::new(entry.id.clone());
            state.ai = AiDomainState {
                phase: entry.persistable.ai_phase,
                active_session_count: 0,
                total_session_count: 0,
            };
            state.terminal = TerminalDomainState {
                phase: entry.persistable.terminal_phase,
                alive_count: 0,
                total_count: 0,
            };
            state.file = FileDomainState {
                phase: entry.persistable.file_phase,
                watcher_active: false,
                indexing_in_progress: false,
            };
            state.health = state.compute_health();
            state.version = entry.persistable.version;

            WorkspaceRecoveryResult {
                id: entry.id.clone(),
                status: RecoveryStatus::Restored,
                recovered_state: Some(state),
                message: format!(
                    "从快照恢复成功 (版本={}, 快照时间={})",
                    entry.persistable.version, entry.captured_at
                ),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_test_states() -> HashMap<String, WorkspaceCoordinatorState> {
        let mut states = HashMap::new();

        let id_a = WorkspaceCoordinatorId::new("proj-a", "default");
        let mut state_a = WorkspaceCoordinatorState::new(id_a.clone());
        state_a.update_ai(AiDomainState {
            phase: AiDomainPhase::Active,
            active_session_count: 2,
            total_session_count: 5,
        });
        states.insert(id_a.global_key(), state_a);

        let id_b = WorkspaceCoordinatorId::new("proj-a", "feature-1");
        let state_b = WorkspaceCoordinatorState::new(id_b.clone());
        states.insert(id_b.global_key(), state_b);

        let id_c = WorkspaceCoordinatorId::new("proj-b", "default");
        let mut state_c = WorkspaceCoordinatorState::new(id_c.clone());
        state_c.update_file(FileDomainState {
            phase: FileDomainPhase::Error,
            watcher_active: false,
            indexing_in_progress: false,
        });
        states.insert(id_c.global_key(), state_c);

        states
    }

    #[test]
    fn snapshot_capture_and_count() {
        let states = make_test_states();
        let snapshot = CoordinatorSnapshot::capture(&states);
        assert_eq!(snapshot.workspace_count(), 3);
        assert!(!snapshot.is_empty());
        assert_eq!(snapshot.snapshot_version, SNAPSHOT_VERSION);
    }

    #[test]
    fn snapshot_scope_filter() {
        let states = make_test_states();
        let snapshot = CoordinatorSnapshot::capture(&states);

        let all = snapshot.entries_for_scope(&CoordinatorScope::system());
        assert_eq!(all.len(), 3);

        let proj_a = snapshot.entries_for_scope(&CoordinatorScope::project("proj-a"));
        assert_eq!(proj_a.len(), 2);

        let ws_one = snapshot.entries_for_scope(&CoordinatorScope::workspace("proj-b", "default"));
        assert_eq!(ws_one.len(), 1);
    }

    #[test]
    fn snapshot_json_roundtrip() {
        let states = make_test_states();
        let snapshot = CoordinatorSnapshot::capture(&states);
        let json = snapshot.to_json().unwrap();
        let parsed = CoordinatorSnapshot::from_json(&json).unwrap();
        assert_eq!(snapshot.workspace_count(), parsed.workspace_count());
        assert_eq!(snapshot.snapshot_version, parsed.snapshot_version);
    }

    #[test]
    fn restore_from_snapshot_system_scope() {
        let states = make_test_states();
        let snapshot = CoordinatorSnapshot::capture(&states);
        let results = restore_from_snapshot(&snapshot, &CoordinatorScope::system());
        assert_eq!(results.len(), 3);
        assert!(results.iter().all(|r| r.status == RecoveryStatus::Restored));

        // 恢复后瞬时部分归零
        for r in &results {
            let state = r.recovered_state.as_ref().unwrap();
            assert_eq!(state.ai.active_session_count, 0);
            assert_eq!(state.terminal.alive_count, 0);
            assert!(!state.file.watcher_active);
        }
    }

    #[test]
    fn restore_from_snapshot_workspace_scope() {
        let states = make_test_states();
        let snapshot = CoordinatorSnapshot::capture(&states);
        let results =
            restore_from_snapshot(&snapshot, &CoordinatorScope::workspace("proj-a", "default"));
        assert_eq!(results.len(), 1);
        let result = &results[0];
        assert_eq!(result.status, RecoveryStatus::Restored);
        assert_eq!(result.id.project, "proj-a");
        assert_eq!(result.id.workspace, "default");
        // AI 相位保留（从快照恢复）
        let state = result.recovered_state.as_ref().unwrap();
        assert_eq!(state.ai.phase, AiDomainPhase::Active);
    }

    #[test]
    fn restore_from_empty_scope_returns_no_snapshot() {
        let states = make_test_states();
        let snapshot = CoordinatorSnapshot::capture(&states);
        let results = restore_from_snapshot(
            &snapshot,
            &CoordinatorScope::workspace("nonexistent", "ws"),
        );
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].status, RecoveryStatus::NoSnapshot);
    }

    #[test]
    fn persistable_meta_distinguishes_transient_state() {
        let id = WorkspaceCoordinatorId::new("proj", "ws");
        let mut state = WorkspaceCoordinatorState::new(id);
        state.update_ai(AiDomainState {
            phase: AiDomainPhase::Active,
            active_session_count: 3,
            total_session_count: 10,
        });

        let meta = PersistableCoordinatorMeta::from(&state);
        assert_eq!(meta.ai_phase, AiDomainPhase::Active);
        // 注意：meta 中不保存 active_session_count（瞬时数据）
        // 这个设计确保恢复时不会使用过时的计数值
    }
}
