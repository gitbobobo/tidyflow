//! 统一协调层模块
//!
//! 将 AI、终端、文件三类领域状态收敛到统一的协调治理体系，
//! 提供跨工作区状态快照、一致性校验与故障恢复能力。
//!
//! ## 子模块
//!
//! - [`identity`]：协调层身份与寻址模型
//! - [`model`]：统一协调聚合状态模型
//! - [`snapshot`]：跨工作区状态快照生成与恢复
//! - [`consistency`]：一致性校验器与故障恢复编排

pub mod consistency;
pub mod identity;
pub mod model;
pub mod snapshot;

// 公开关键类型，减少外部引用路径长度
pub use consistency::{
    check_multi_workspace_consistency, check_workspace_consistency, orchestrate_recovery,
    ConsistencyCheckResult, Inconsistency, InconsistencyKind, InconsistencySeverity,
    RecoveryAction, RecoveryDecision, RecoveryOrchestrationResult, StateChange,
};
pub use identity::{CoordinatorScope, WorkspaceCoordinatorId};
pub use model::{
    AiDomainPhase, AiDomainState, CoordinatorHealth, FileDomainPhase, FileDomainState,
    StatePersistence, TerminalDomainPhase, TerminalDomainState, WorkspaceCoordinatorState,
};
pub use snapshot::{
    restore_from_snapshot, CoordinatorSnapshot, PersistableCoordinatorMeta, RecoveryStatus,
    WorkspaceRecoveryResult, WorkspaceSnapshotEntry, SNAPSHOT_VERSION,
};
