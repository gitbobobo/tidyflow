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
                display_status: crate::coordinator::model::AiDisplayStatus::Idle,
                active_tool_name: None,
                last_error_message: None,
                display_updated_at: 0,
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
            ..Default::default()
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
        let results =
            restore_from_snapshot(&snapshot, &CoordinatorScope::workspace("nonexistent", "ws"));
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
            ..Default::default()
        });

        let meta = PersistableCoordinatorMeta::from(&state);
        assert_eq!(meta.ai_phase, AiDomainPhase::Active);
        // 注意：meta 中不保存 active_session_count（瞬时数据）
        // 这个设计确保恢复时不会使用过时的计数值
    }

    /// 验证快照 roundtrip 与多工作区隔离：
    ///
    /// - system_snapshot coordinator_state 序列化和反序列化 roundtrip
    /// - 至少 3 次连续增量 coordinator_snapshot 更新（版本单调递增）
    /// - 旧版本不覆盖新版本（版本单调性）
    /// - 至少 2 个项目各自拥有同名 default 工作区，互不串状态
    #[test]
    fn coordinator_snapshot_roundtrip_preserves_project_workspace_isolation() {
        // ── 构建多项目同名工作区状态 ───────────────────────────────────────────
        let mut states: HashMap<String, WorkspaceCoordinatorState> = HashMap::new();

        // proj-a:default — AI active
        let id_a1 = WorkspaceCoordinatorId::new("proj-a", "default");
        let mut s_a1 = WorkspaceCoordinatorState::new(id_a1.clone());
        s_a1.update_ai(AiDomainState {
            phase: AiDomainPhase::Active,
            active_session_count: 2,
            total_session_count: 3,
            ..Default::default()
        });
        states.insert(id_a1.global_key(), s_a1);

        // proj-a:feature — idle
        let id_a2 = WorkspaceCoordinatorId::new("proj-a", "feature");
        let s_a2 = WorkspaceCoordinatorState::new(id_a2.clone());
        states.insert(id_a2.global_key(), s_a2);

        // proj-b:default — file error（与 proj-a:default 同名但不同项目）
        let id_b1 = WorkspaceCoordinatorId::new("proj-b", "default");
        let mut s_b1 = WorkspaceCoordinatorState::new(id_b1.clone());
        s_b1.update_file(FileDomainState {
            phase: FileDomainPhase::Error,
            watcher_active: false,
            indexing_in_progress: false,
        });
        states.insert(id_b1.global_key(), s_b1);

        // proj-b:feature — terminal active
        let id_b2 = WorkspaceCoordinatorId::new("proj-b", "feature");
        let mut s_b2 = WorkspaceCoordinatorState::new(id_b2.clone());
        s_b2.update_terminal(TerminalDomainState {
            phase: TerminalDomainPhase::Active,
            alive_count: 3,
            total_count: 5,
        });
        states.insert(id_b2.global_key(), s_b2);

        // ── Roundtrip：序列化再反序列化，工作区数量与相位不变 ───────────────────
        let snapshot = CoordinatorSnapshot::capture(&states);
        assert_eq!(snapshot.workspace_count(), 4);

        let json = snapshot.to_json().expect("序列化不应失败");
        let parsed = CoordinatorSnapshot::from_json(&json).expect("反序列化不应失败");
        assert_eq!(parsed.workspace_count(), 4);
        assert_eq!(parsed.snapshot_version, SNAPSHOT_VERSION);

        // 验证各工作区相位在 roundtrip 后保持一致
        let entry_a1 = parsed
            .workspaces
            .get(&id_a1.global_key())
            .expect("proj-a:default 应存在");
        assert_eq!(entry_a1.persistable.ai_phase, AiDomainPhase::Active);

        let entry_b1 = parsed
            .workspaces
            .get(&id_b1.global_key())
            .expect("proj-b:default 应存在");
        assert_eq!(entry_b1.persistable.file_phase, FileDomainPhase::Error);

        // ── 多项目同名工作区隔离：proj-a:default 和 proj-b:default 相位不同 ──────
        assert_ne!(
            entry_a1.persistable.ai_phase,
            AiDomainPhase::Idle,
            "proj-a:default 应为 Active"
        );
        assert_eq!(
            entry_b1.persistable.ai_phase,
            AiDomainPhase::Idle,
            "proj-b:default AI 应为 Idle，不受 proj-a 影响"
        );

        // ── 增量 coordinator_snapshot 更新（至少 3 次连续更新）──────────────────
        let mut live_state = WorkspaceCoordinatorState::new(id_a1.clone());
        let v0 = live_state.version;

        // 更新 1
        live_state.update_ai(AiDomainState {
            phase: AiDomainPhase::Active,
            active_session_count: 1,
            total_session_count: 1,
            ..Default::default()
        });
        let v1 = live_state.version;
        assert!(v1 > v0, "更新 1 后版本应递增");

        // 更新 2
        live_state.update_terminal(TerminalDomainState {
            phase: TerminalDomainPhase::Active,
            alive_count: 2,
            total_count: 2,
        });
        let v2 = live_state.version;
        assert!(v2 > v1, "更新 2 后版本应继续递增");

        // 更新 3
        live_state.update_file(FileDomainState {
            phase: FileDomainPhase::Ready,
            watcher_active: true,
            indexing_in_progress: false,
        });
        let v3 = live_state.version;
        assert!(v3 > v2, "更新 3 后版本应继续递增");

        // 连续更新快照，版本单调性：新版本快照不会丢失更新
        let mut evolving = HashMap::new();
        evolving.insert(id_a1.global_key(), live_state.clone());

        let snap_v3 = CoordinatorSnapshot::capture(&evolving);
        let snap_entry = snap_v3
            .workspaces
            .get(&id_a1.global_key())
            .expect("应存在");
        assert_eq!(snap_entry.persistable.version, v3, "快照应保存最新版本号");

        // ── 版本单调性：旧快照版本不覆盖新版本 ────────────────────────────────
        // 构造旧快照（版本 = v1）和新快照（版本 = v3），恢复后应用新版本
        let mut old_state = WorkspaceCoordinatorState::new(id_a1.clone());
        old_state.update_ai(AiDomainState::default()); // version = 2 < v3
        let old_snap_map: HashMap<String, WorkspaceCoordinatorState> =
            [(id_a1.global_key(), old_state)].into_iter().collect();
        let old_snap = CoordinatorSnapshot::capture(&old_snap_map);

        let new_results = restore_from_snapshot(&snap_v3, &CoordinatorScope::workspace("proj-a", "default"));
        let old_results = restore_from_snapshot(&old_snap, &CoordinatorScope::workspace("proj-a", "default"));

        let new_ver = new_results[0].recovered_state.as_ref().unwrap().version;
        let old_ver = old_results[0].recovered_state.as_ref().unwrap().version;
        assert!(
            new_ver > old_ver,
            "新快照版本 ({}) 应大于旧快照版本 ({})",
            new_ver,
            old_ver
        );

        // ── 恢复后跨项目 default 工作区互不串状态 ────────────────────────────
        let all_results = restore_from_snapshot(&parsed, &CoordinatorScope::system());
        assert_eq!(all_results.len(), 4);
        assert!(
            all_results.iter().all(|r| r.status == RecoveryStatus::Restored),
            "全量恢复应全部成功"
        );

        let restored_a1 = all_results
            .iter()
            .find(|r| r.id.project == "proj-a" && r.id.workspace == "default")
            .expect("proj-a:default 应在恢复结果中");
        let restored_b1 = all_results
            .iter()
            .find(|r| r.id.project == "proj-b" && r.id.workspace == "default")
            .expect("proj-b:default 应在恢复结果中");

        // proj-a:default 恢复后 AI Active；proj-b:default 恢复后 AI Idle
        assert_eq!(restored_a1.recovered_state.as_ref().unwrap().ai.phase, AiDomainPhase::Active);
        assert_eq!(restored_b1.recovered_state.as_ref().unwrap().ai.phase, AiDomainPhase::Idle);
        // proj-b:default 恢复后 file Error
        assert_eq!(restored_b1.recovered_state.as_ref().unwrap().file.phase, FileDomainPhase::Error);
    }
}
