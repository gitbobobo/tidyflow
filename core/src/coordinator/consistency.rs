//! 协调层一致性校验器与故障恢复编排
//!
//! 检测 AI、终端、文件状态之间的关键不一致，
//! 并输出可执行的恢复决策或降级结果。
//!
//! ## 校验规则
//!
//! 1. **文件系统可用性**：文件处于 Error 时，依赖文件操作的 AI 和终端应降级。
//! 2. **终端存活一致性**：终端相位为 Active 但计数为 0 表示状态漂移。
//! 3. **AI 会话一致性**：AI 相位为 Active 但无活跃会话表示状态漂移。
//! 4. **跨领域依赖**：AI 活跃但文件不可用时，AI 操作可能不完整。
//!
//! ## 恢复策略
//!
//! - 校验结果输出 `RecoveryDecision` 列表，每个决策包含作用域、动作和优先级。
//! - 恢复编排器按优先级顺序执行决策，支持幂等重试。
//! - 多工作区场景下，每个工作区独立校验，不互相影响。

use serde::{Deserialize, Serialize};

use super::identity::{CoordinatorScope, WorkspaceCoordinatorId};
use super::model::{
    AiDomainPhase, CoordinatorHealth, FileDomainPhase, TerminalDomainPhase,
    WorkspaceCoordinatorState,
};

// ============================================================================
// 不一致类型
// ============================================================================

/// 检测到的不一致类型
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InconsistencyKind {
    /// 终端相位为 Active 但存活计数为 0
    TerminalPhaseCountMismatch,
    /// AI 相位为 Active 但活跃会话数为 0
    AiPhaseCountMismatch,
    /// 文件不可用但 AI 仍在活跃（可能产生不完整结果）
    AiActiveWithFileUnavailable,
    /// 文件不可用但终端仍在活跃
    TerminalActiveWithFileUnavailable,
    /// 健康度与实际领域状态不匹配
    HealthStatusMismatch,
}

/// 检测到的不一致条目
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Inconsistency {
    /// 不一致类型
    pub kind: InconsistencyKind,
    /// 所属工作区
    pub workspace_id: WorkspaceCoordinatorId,
    /// 人类可读描述
    pub description: String,
    /// 严重级别
    pub severity: InconsistencySeverity,
}

/// 不一致严重级别
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InconsistencySeverity {
    /// 警告：状态不一致但功能可用
    Warning,
    /// 错误：需要修复才能正常运行
    Error,
    /// 危急：核心功能不可用
    Critical,
}

// ============================================================================
// 恢复决策
// ============================================================================

/// 恢复动作类型
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RecoveryAction {
    /// 重置领域相位为 Idle
    ResetDomainPhase { domain: String },
    /// 重新同步领域状态（从实际运行时重新采集）
    ResyncDomainState { domain: String },
    /// 重新计算协调健康度
    RecomputeHealth,
    /// 降级通知：标记工作区为降级状态
    MarkDegraded { reason: String },
    /// 完全重置工作区协调状态
    FullReset,
}

/// 恢复决策
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecoveryDecision {
    /// 恢复作用域
    pub scope: CoordinatorScope,
    /// 恢复动作
    pub action: RecoveryAction,
    /// 优先级（数字越小优先级越高）
    pub priority: u8,
    /// 此决策是否可幂等重试
    pub idempotent: bool,
    /// 关联的不一致条目
    pub triggered_by: InconsistencyKind,
    /// 人类可读说明
    pub description: String,
}

// ============================================================================
// 校验结果
// ============================================================================

/// 一致性校验结果
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConsistencyCheckResult {
    /// 检测到的不一致列表
    pub inconsistencies: Vec<Inconsistency>,
    /// 生成的恢复决策列表（按优先级排序）
    pub recovery_decisions: Vec<RecoveryDecision>,
    /// 校验是否通过（无不一致）
    pub is_consistent: bool,
}

impl ConsistencyCheckResult {
    /// 构造通过结果
    pub fn consistent() -> Self {
        Self {
            inconsistencies: vec![],
            recovery_decisions: vec![],
            is_consistent: true,
        }
    }
}

// ============================================================================
// 一致性校验器
// ============================================================================

/// 对单个工作区协调状态执行一致性校验
pub fn check_workspace_consistency(state: &WorkspaceCoordinatorState) -> ConsistencyCheckResult {
    let mut inconsistencies = Vec::new();
    let mut decisions = Vec::new();

    // 规则 1: 终端相位与计数一致性
    if state.terminal.phase == TerminalDomainPhase::Active && state.terminal.alive_count == 0 {
        inconsistencies.push(Inconsistency {
            kind: InconsistencyKind::TerminalPhaseCountMismatch,
            workspace_id: state.id.clone(),
            description: "终端相位为 Active 但存活终端数为 0".to_string(),
            severity: InconsistencySeverity::Warning,
        });
        decisions.push(RecoveryDecision {
            scope: CoordinatorScope::Workspace(state.id.clone()),
            action: RecoveryAction::ResyncDomainState {
                domain: "terminal".to_string(),
            },
            priority: 2,
            idempotent: true,
            triggered_by: InconsistencyKind::TerminalPhaseCountMismatch,
            description: "重新同步终端领域状态".to_string(),
        });
    }

    // 规则 2: AI 相位与计数一致性
    if state.ai.phase == AiDomainPhase::Active && state.ai.active_session_count == 0 {
        inconsistencies.push(Inconsistency {
            kind: InconsistencyKind::AiPhaseCountMismatch,
            workspace_id: state.id.clone(),
            description: "AI 相位为 Active 但活跃会话数为 0".to_string(),
            severity: InconsistencySeverity::Warning,
        });
        decisions.push(RecoveryDecision {
            scope: CoordinatorScope::Workspace(state.id.clone()),
            action: RecoveryAction::ResyncDomainState {
                domain: "ai".to_string(),
            },
            priority: 2,
            idempotent: true,
            triggered_by: InconsistencyKind::AiPhaseCountMismatch,
            description: "重新同步 AI 领域状态".to_string(),
        });
    }

    // 规则 3: AI 活跃但文件不可用
    if state.ai.phase == AiDomainPhase::Active && state.file.phase == FileDomainPhase::Error {
        inconsistencies.push(Inconsistency {
            kind: InconsistencyKind::AiActiveWithFileUnavailable,
            workspace_id: state.id.clone(),
            description: "AI 处于活跃状态但文件子系统不可用，AI 操作结果可能不完整".to_string(),
            severity: InconsistencySeverity::Error,
        });
        decisions.push(RecoveryDecision {
            scope: CoordinatorScope::Workspace(state.id.clone()),
            action: RecoveryAction::MarkDegraded {
                reason: "file_unavailable_during_ai_active".to_string(),
            },
            priority: 1,
            idempotent: true,
            triggered_by: InconsistencyKind::AiActiveWithFileUnavailable,
            description: "文件不可用时标记工作区为降级状态".to_string(),
        });
    }

    // 规则 4: 终端活跃但文件不可用
    if state.terminal.phase == TerminalDomainPhase::Active
        && state.file.phase == FileDomainPhase::Error
    {
        inconsistencies.push(Inconsistency {
            kind: InconsistencyKind::TerminalActiveWithFileUnavailable,
            workspace_id: state.id.clone(),
            description: "终端处于活跃状态但文件子系统不可用".to_string(),
            severity: InconsistencySeverity::Warning,
        });
    }

    // 规则 5: 健康度一致性
    let expected_health = state.compute_health();
    if state.health != expected_health {
        inconsistencies.push(Inconsistency {
            kind: InconsistencyKind::HealthStatusMismatch,
            workspace_id: state.id.clone(),
            description: format!(
                "健康度不一致: 当前={:?}, 预期={:?}",
                state.health, expected_health
            ),
            severity: InconsistencySeverity::Error,
        });
        decisions.push(RecoveryDecision {
            scope: CoordinatorScope::Workspace(state.id.clone()),
            action: RecoveryAction::RecomputeHealth,
            priority: 0,
            idempotent: true,
            triggered_by: InconsistencyKind::HealthStatusMismatch,
            description: "重新计算协调健康度".to_string(),
        });
    }

    // 按优先级排序恢复决策
    decisions.sort_by_key(|d| d.priority);

    let is_consistent = inconsistencies.is_empty();

    ConsistencyCheckResult {
        inconsistencies,
        recovery_decisions: decisions,
        is_consistent,
    }
}

/// 对多个工作区执行批量一致性校验
///
/// 每个工作区独立校验，返回合并的结果。
pub fn check_multi_workspace_consistency(
    states: &[&WorkspaceCoordinatorState],
) -> ConsistencyCheckResult {
    let mut all_inconsistencies = Vec::new();
    let mut all_decisions = Vec::new();

    for state in states {
        let result = check_workspace_consistency(state);
        all_inconsistencies.extend(result.inconsistencies);
        all_decisions.extend(result.recovery_decisions);
    }

    // 按优先级排序
    all_decisions.sort_by_key(|d| d.priority);
    let is_consistent = all_inconsistencies.is_empty();

    ConsistencyCheckResult {
        inconsistencies: all_inconsistencies,
        recovery_decisions: all_decisions,
        is_consistent,
    }
}

// ============================================================================
// 故障恢复编排
// ============================================================================

/// 恢复编排结果
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecoveryOrchestrationResult {
    /// 总决策数
    pub total_decisions: usize,
    /// 成功执行数
    pub executed: usize,
    /// 跳过数（已经一致）
    pub skipped: usize,
    /// 执行后的状态变更列表
    pub state_changes: Vec<StateChange>,
}

/// 状态变更记录
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StateChange {
    pub workspace_id: WorkspaceCoordinatorId,
    pub action_applied: String,
    pub before_health: CoordinatorHealth,
    pub after_health: CoordinatorHealth,
}

/// 执行恢复编排
///
/// 按优先级顺序执行恢复决策，修改传入的状态集合。
/// 每个决策幂等执行，安全重试。
pub fn orchestrate_recovery(
    decisions: &[RecoveryDecision],
    states: &mut std::collections::HashMap<String, WorkspaceCoordinatorState>,
) -> RecoveryOrchestrationResult {
    let mut executed = 0usize;
    let mut skipped = 0usize;
    let mut state_changes = Vec::new();

    for decision in decisions {
        match &decision.scope {
            CoordinatorScope::Workspace(ws_id) => {
                let key = ws_id.global_key();
                if let Some(state) = states.get_mut(&key) {
                    let before_health = state.health;
                    let applied = apply_recovery_action(state, &decision.action);
                    if applied {
                        executed += 1;
                        state_changes.push(StateChange {
                            workspace_id: ws_id.clone(),
                            action_applied: format!("{:?}", decision.action),
                            before_health,
                            after_health: state.health,
                        });
                    } else {
                        skipped += 1;
                    }
                } else {
                    skipped += 1;
                }
            }
            CoordinatorScope::System => {
                // 系统级恢复：遍历所有工作区
                for state in states.values_mut() {
                    let before_health = state.health;
                    let applied = apply_recovery_action(state, &decision.action);
                    if applied {
                        executed += 1;
                        state_changes.push(StateChange {
                            workspace_id: state.id.clone(),
                            action_applied: format!("{:?}", decision.action),
                            before_health,
                            after_health: state.health,
                        });
                    } else {
                        skipped += 1;
                    }
                }
            }
            CoordinatorScope::Project { project } => {
                let keys: Vec<_> = states
                    .keys()
                    .filter(|k| k.starts_with(&format!("{}:", project)))
                    .cloned()
                    .collect();
                for key in keys {
                    if let Some(state) = states.get_mut(&key) {
                        let before_health = state.health;
                        let applied = apply_recovery_action(state, &decision.action);
                        if applied {
                            executed += 1;
                            state_changes.push(StateChange {
                                workspace_id: state.id.clone(),
                                action_applied: format!("{:?}", decision.action),
                                before_health,
                                after_health: state.health,
                            });
                        } else {
                            skipped += 1;
                        }
                    }
                }
            }
        }
    }

    RecoveryOrchestrationResult {
        total_decisions: decisions.len(),
        executed,
        skipped,
        state_changes,
    }
}

/// 对单个状态应用恢复动作
fn apply_recovery_action(state: &mut WorkspaceCoordinatorState, action: &RecoveryAction) -> bool {
    match action {
        RecoveryAction::ResetDomainPhase { domain } => match domain.as_str() {
            "ai" => {
                state.ai.phase = AiDomainPhase::Idle;
                state.ai.active_session_count = 0;
                state.health = state.compute_health();
                true
            }
            "terminal" => {
                state.terminal.phase = TerminalDomainPhase::Idle;
                state.terminal.alive_count = 0;
                state.health = state.compute_health();
                true
            }
            "file" => {
                state.file.phase = FileDomainPhase::Idle;
                state.file.watcher_active = false;
                state.file.indexing_in_progress = false;
                state.health = state.compute_health();
                true
            }
            _ => false,
        },
        RecoveryAction::ResyncDomainState { domain } => match domain.as_str() {
            "ai" => {
                // 重新同步：如果活跃计数为 0 则回退到 Idle
                if state.ai.active_session_count == 0 && state.ai.phase == AiDomainPhase::Active {
                    state.ai.phase = AiDomainPhase::Idle;
                    state.health = state.compute_health();
                    true
                } else {
                    false
                }
            }
            "terminal" => {
                if state.terminal.alive_count == 0
                    && state.terminal.phase == TerminalDomainPhase::Active
                {
                    state.terminal.phase = TerminalDomainPhase::Idle;
                    state.health = state.compute_health();
                    true
                } else {
                    false
                }
            }
            _ => false,
        },
        RecoveryAction::RecomputeHealth => {
            let new_health = state.compute_health();
            if state.health != new_health {
                state.health = new_health;
                true
            } else {
                false
            }
        }
        RecoveryAction::MarkDegraded { .. } => {
            if state.health != CoordinatorHealth::Degraded
                && state.health != CoordinatorHealth::Faulted
            {
                state.health = CoordinatorHealth::Degraded;
                true
            } else {
                false
            }
        }
        RecoveryAction::FullReset => {
            state.reset();
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::coordinator::model::*;

    fn make_consistent_state() -> WorkspaceCoordinatorState {
        WorkspaceCoordinatorState::new(WorkspaceCoordinatorId::new("proj", "ws-1"))
    }

    #[test]
    fn consistent_state_passes_check() {
        let state = make_consistent_state();
        let result = check_workspace_consistency(&state);
        assert!(result.is_consistent);
        assert!(result.inconsistencies.is_empty());
        assert!(result.recovery_decisions.is_empty());
    }

    #[test]
    fn terminal_phase_count_mismatch_detected() {
        let mut state = make_consistent_state();
        state.terminal.phase = TerminalDomainPhase::Active;
        state.terminal.alive_count = 0;

        let result = check_workspace_consistency(&state);
        assert!(!result.is_consistent);
        assert!(result
            .inconsistencies
            .iter()
            .any(|i| i.kind == InconsistencyKind::TerminalPhaseCountMismatch));
    }

    #[test]
    fn ai_phase_count_mismatch_detected() {
        let mut state = make_consistent_state();
        state.ai.phase = AiDomainPhase::Active;
        state.ai.active_session_count = 0;

        let result = check_workspace_consistency(&state);
        assert!(!result.is_consistent);
        assert!(result
            .inconsistencies
            .iter()
            .any(|i| i.kind == InconsistencyKind::AiPhaseCountMismatch));
    }

    #[test]
    fn ai_active_with_file_unavailable_detected() {
        let mut state = make_consistent_state();
        state.ai.phase = AiDomainPhase::Active;
        state.ai.active_session_count = 1;
        state.file.phase = FileDomainPhase::Error;
        state.health = state.compute_health();

        let result = check_workspace_consistency(&state);
        assert!(!result.is_consistent);
        assert!(result
            .inconsistencies
            .iter()
            .any(|i| i.kind == InconsistencyKind::AiActiveWithFileUnavailable));
    }

    #[test]
    fn health_mismatch_detected() {
        let mut state = make_consistent_state();
        state.file.phase = FileDomainPhase::Error;
        // 故意不更新 health，制造不一致
        assert_ne!(state.health, state.compute_health());

        let result = check_workspace_consistency(&state);
        assert!(!result.is_consistent);
        assert!(result
            .inconsistencies
            .iter()
            .any(|i| i.kind == InconsistencyKind::HealthStatusMismatch));
    }

    #[test]
    fn recovery_decisions_sorted_by_priority() {
        let mut state = make_consistent_state();
        state.ai.phase = AiDomainPhase::Active;
        state.ai.active_session_count = 1;
        state.file.phase = FileDomainPhase::Error;
        // 故意不更新 health 制造 health mismatch + cross-domain issue
        let result = check_workspace_consistency(&state);
        assert!(!result.recovery_decisions.is_empty());

        // 验证决策按优先级排序
        for window in result.recovery_decisions.windows(2) {
            assert!(window[0].priority <= window[1].priority);
        }
    }

    #[test]
    fn multi_workspace_consistency_check() {
        let state_a = make_consistent_state();

        let mut state_b =
            WorkspaceCoordinatorState::new(WorkspaceCoordinatorId::new("proj", "ws-2"));
        state_b.terminal.phase = TerminalDomainPhase::Active;
        state_b.terminal.alive_count = 0;

        let result = check_multi_workspace_consistency(&[&state_a, &state_b]);
        // state_a 一致, state_b 不一致
        assert!(!result.is_consistent);
        assert_eq!(result.inconsistencies.len(), 1);
        assert_eq!(
            result.inconsistencies[0].workspace_id,
            WorkspaceCoordinatorId::new("proj", "ws-2")
        );
    }

    #[test]
    fn recovery_orchestration_fixes_inconsistency() {
        let mut states = std::collections::HashMap::new();

        let id = WorkspaceCoordinatorId::new("proj", "ws-1");
        let mut state = WorkspaceCoordinatorState::new(id.clone());
        state.terminal.phase = TerminalDomainPhase::Active;
        state.terminal.alive_count = 0;
        states.insert(id.global_key(), state);

        // 校验检测不一致
        let check = check_workspace_consistency(states.get(&id.global_key()).unwrap());
        assert!(!check.is_consistent);

        // 执行恢复
        let result = orchestrate_recovery(&check.recovery_decisions, &mut states);
        assert!(result.executed > 0);

        // 恢复后应该一致
        let recheck = check_workspace_consistency(states.get(&id.global_key()).unwrap());
        assert!(recheck.is_consistent);
    }

    #[test]
    fn recovery_is_idempotent() {
        let mut states = std::collections::HashMap::new();
        let id = WorkspaceCoordinatorId::new("proj", "ws-1");
        let mut state = WorkspaceCoordinatorState::new(id.clone());
        state.ai.phase = AiDomainPhase::Active;
        state.ai.active_session_count = 0;
        states.insert(id.global_key(), state);

        let check = check_workspace_consistency(states.get(&id.global_key()).unwrap());
        let result1 = orchestrate_recovery(&check.recovery_decisions, &mut states);
        assert!(result1.executed > 0);

        // 第二次执行相同恢复应该跳过（已经修复）
        let result2 = orchestrate_recovery(&check.recovery_decisions, &mut states);
        assert_eq!(result2.executed, 0);
    }

    #[test]
    fn full_reset_recovery() {
        let mut states = std::collections::HashMap::new();
        let id = WorkspaceCoordinatorId::new("proj", "ws-1");
        let mut state = WorkspaceCoordinatorState::new(id.clone());
        state.update_ai(AiDomainState {
            phase: AiDomainPhase::Active,
            active_session_count: 3,
            total_session_count: 10,
            ..Default::default()
        });
        state.update_terminal(TerminalDomainState {
            phase: TerminalDomainPhase::Active,
            alive_count: 2,
            total_count: 5,
        });
        states.insert(id.global_key(), state);

        let decisions = vec![RecoveryDecision {
            scope: CoordinatorScope::Workspace(id.clone()),
            action: RecoveryAction::FullReset,
            priority: 0,
            idempotent: true,
            triggered_by: InconsistencyKind::HealthStatusMismatch,
            description: "完全重置".to_string(),
        }];

        let result = orchestrate_recovery(&decisions, &mut states);
        assert_eq!(result.executed, 1);

        let state = states.get(&id.global_key()).unwrap();
        assert!(state.is_idle());
        assert_eq!(state.health, CoordinatorHealth::Healthy);
    }

    #[test]
    fn multi_workspace_parallel_recovery() {
        let mut states = std::collections::HashMap::new();

        // 工作区 A: 终端状态漂移
        let id_a = WorkspaceCoordinatorId::new("proj-a", "ws-1");
        let mut state_a = WorkspaceCoordinatorState::new(id_a.clone());
        state_a.terminal.phase = TerminalDomainPhase::Active;
        state_a.terminal.alive_count = 0;
        states.insert(id_a.global_key(), state_a);

        // 工作区 B: AI 状态漂移
        let id_b = WorkspaceCoordinatorId::new("proj-b", "ws-1");
        let mut state_b = WorkspaceCoordinatorState::new(id_b.clone());
        state_b.ai.phase = AiDomainPhase::Active;
        state_b.ai.active_session_count = 0;
        states.insert(id_b.global_key(), state_b);

        // 批量校验
        let refs: Vec<&WorkspaceCoordinatorState> = states.values().collect();
        let check = check_multi_workspace_consistency(&refs);
        assert!(!check.is_consistent);
        assert_eq!(check.inconsistencies.len(), 2);

        // 批量恢复
        let result = orchestrate_recovery(&check.recovery_decisions, &mut states);
        assert_eq!(result.executed, 2);

        // 两个工作区都应该一致
        for state in states.values() {
            let recheck = check_workspace_consistency(state);
            assert!(recheck.is_consistent);
        }
    }

    // ---- WI-003: 多项目同名工作区隔离与恢复闭环 ----

    #[test]
    fn recovery_isolation_same_workspace_name_different_projects() {
        let mut states = std::collections::HashMap::new();

        // 两个项目使用同名工作区 "feature"
        let id_a = WorkspaceCoordinatorId::new("proj-alpha", "feature");
        let mut state_a = WorkspaceCoordinatorState::new(id_a.clone());
        state_a.terminal.phase = TerminalDomainPhase::Active;
        state_a.terminal.alive_count = 0; // 不一致：需要恢复
        states.insert(id_a.global_key(), state_a);

        let id_b = WorkspaceCoordinatorId::new("proj-beta", "feature");
        let state_b = WorkspaceCoordinatorState::new(id_b.clone()); // 一致
        states.insert(id_b.global_key(), state_b);

        // 校验：只有 proj-alpha 不一致
        let check_a = check_workspace_consistency(states.get(&id_a.global_key()).unwrap());
        let check_b = check_workspace_consistency(states.get(&id_b.global_key()).unwrap());
        assert!(!check_a.is_consistent, "proj-alpha 应不一致");
        assert!(check_b.is_consistent, "proj-beta 应一致");

        // 对 proj-alpha 执行恢复
        let result = orchestrate_recovery(&check_a.recovery_decisions, &mut states);
        assert!(result.executed > 0, "应执行恢复动作");

        // 验证隔离：恢复只影响 proj-alpha，不影响 proj-beta
        let recheck_a = check_workspace_consistency(states.get(&id_a.global_key()).unwrap());
        let recheck_b = check_workspace_consistency(states.get(&id_b.global_key()).unwrap());
        assert!(recheck_a.is_consistent, "恢复后 proj-alpha 应一致");
        assert!(recheck_b.is_consistent, "proj-beta 应始终一致");

        // 验证 state_changes 只涉及 proj-alpha
        for change in &result.state_changes {
            assert_eq!(
                change.workspace_id.project, "proj-alpha",
                "state_change 只应包含 proj-alpha"
            );
        }
    }

    #[test]
    fn recovery_full_pipeline_probe_repair_recheck() {
        let mut states = std::collections::HashMap::new();

        // 第 1 步：创建不一致状态（模拟探针发现）
        let id = WorkspaceCoordinatorId::new("pipeline-proj", "ws-pipeline");
        let mut state = WorkspaceCoordinatorState::new(id.clone());
        state.ai.phase = AiDomainPhase::Active;
        state.ai.active_session_count = 0; // AI 相位与计数不一致
        state.file.phase = FileDomainPhase::Error;
        // 故意不更新 health 制造多重不一致
        states.insert(id.global_key(), state);

        // 第 2 步：检测
        let check = check_workspace_consistency(states.get(&id.global_key()).unwrap());
        assert!(!check.is_consistent);
        assert!(
            check.inconsistencies.len() >= 2,
            "应检测到多个不一致: {:?}",
            check.inconsistencies
        );

        // 第 3 步：按优先级排序恢复
        for window in check.recovery_decisions.windows(2) {
            assert!(
                window[0].priority <= window[1].priority,
                "恢复决策应按优先级排序"
            );
        }

        // 第 4 步：执行恢复
        let result = orchestrate_recovery(&check.recovery_decisions, &mut states);
        assert!(result.executed > 0);

        // 第 5 步：重新检查 — 应一致
        let recheck = check_workspace_consistency(states.get(&id.global_key()).unwrap());
        assert!(recheck.is_consistent, "恢复后应一致");

        // 第 6 步：幂等验证 — 再次执行不应改变状态
        let result2 = orchestrate_recovery(&check.recovery_decisions, &mut states);
        assert_eq!(result2.executed, 0, "幂等执行不应再次修改");
    }

    #[test]
    fn recovery_project_scope_does_not_cross_project_boundary() {
        let mut states = std::collections::HashMap::new();

        // proj-x 和 proj-y 各有一个同名工作区
        let id_x = WorkspaceCoordinatorId::new("proj-x", "shared-ws");
        let mut state_x = WorkspaceCoordinatorState::new(id_x.clone());
        state_x.terminal.phase = TerminalDomainPhase::Active;
        state_x.terminal.alive_count = 0;
        states.insert(id_x.global_key(), state_x);

        let id_y = WorkspaceCoordinatorId::new("proj-y", "shared-ws");
        let mut state_y = WorkspaceCoordinatorState::new(id_y.clone());
        state_y.ai.phase = AiDomainPhase::Active;
        state_y.ai.active_session_count = 0;
        states.insert(id_y.global_key(), state_y);

        // 只修复 proj-x 的问题
        let check_x = check_workspace_consistency(states.get(&id_x.global_key()).unwrap());
        let result = orchestrate_recovery(&check_x.recovery_decisions, &mut states);
        assert!(result.executed > 0);

        // proj-x 已修复
        let recheck_x = check_workspace_consistency(states.get(&id_x.global_key()).unwrap());
        assert!(recheck_x.is_consistent);

        // proj-y 仍然不一致（没被修复）
        let recheck_y = check_workspace_consistency(states.get(&id_y.global_key()).unwrap());
        assert!(!recheck_y.is_consistent, "proj-y 不应被 proj-x 的恢复影响");
    }
}
