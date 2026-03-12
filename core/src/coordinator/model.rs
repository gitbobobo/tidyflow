//! 统一协调层聚合状态模型
//!
//! 将 AI、终端、文件三类领域状态统一聚合到 `WorkspaceCoordinatorState`，
//! 为每个 `(project, workspace)` 提供单一的协调状态入口。
//!
//! ## 设计原则
//!
//! - **Core 权威**：协调层状态由 Core 聚合产生，客户端只消费不推导。
//! - **显式生命周期**：每个领域子状态有明确的相位定义和状态迁移边界。
//! - **瞬时 vs 持久化**：运行时状态（如文件相位、AI 活跃状态）与持久化状态
//!   （如工作区恢复元数据）显式区分，快照时分别标记。
//! - **多工作区隔离**：通过 `WorkspaceCoordinatorId` 精确寻址，
//!   不同项目下的同名工作区绝不共享状态。

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::identity::WorkspaceCoordinatorId;

// ============================================================================
// 领域状态相位
// ============================================================================

/// AI 领域协调相位
///
/// 描述某个工作区的 AI 子系统聚合状态，
/// 由 Core 基于各 AI 工具会话的活跃度汇总产生。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AiDomainPhase {
    /// 无活跃 AI 会话
    Idle,
    /// 至少一个会话正在执行（running 或 awaiting_input）
    Active,
    /// 存在失败会话且无活跃会话
    Faulted,
}

impl Default for AiDomainPhase {
    fn default() -> Self {
        Self::Idle
    }
}

/// 终端领域协调相位
///
/// 描述某个工作区的终端子系统聚合状态，
/// 由 Core 基于终端注册表的存活状态汇总产生。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TerminalDomainPhase {
    /// 无存活终端
    Idle,
    /// 至少一个终端正在运行
    Active,
    /// 至少一个终端异常退出且无活跃终端
    Faulted,
}

impl Default for TerminalDomainPhase {
    fn default() -> Self {
        Self::Idle
    }
}

/// 文件领域协调相位
///
/// 对 `FileWorkspacePhase` 的语义映射。
/// 协调层使用此枚举屏蔽文件子系统的内部迁移细节，
/// 只暴露对协调治理有意义的聚合状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FileDomainPhase {
    /// 文件子系统未激活
    Idle,
    /// 文件子系统正常运行中（watching 或 indexing）
    Ready,
    /// 文件子系统降级或恢复中
    Degraded,
    /// 文件子系统错误不可用
    Error,
}

impl Default for FileDomainPhase {
    fn default() -> Self {
        Self::Idle
    }
}

// ============================================================================
// AI 展示状态（终端标签栏六态）
// ============================================================================

/// AI 展示状态——终端标签栏可感知的六态枚举。
///
/// 由 Core 聚合后写入 `AiDomainState.display_status`，
/// 客户端直接消费，不在视图层重新推导。
///
/// 多会话并发时的聚合优先级（固化在 Core）：
/// 1. 若存在 `awaiting_input` 会话 → `awaiting_input`
/// 2. 若存在 `running` 会话 → `running`
/// 3. 取最近终态：`failure > cancelled > success`（按 `display_updated_at` 决胜）
/// 4. 无会话记录 → `idle`
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AiDisplayStatus {
    /// 无活跃或近期 AI 会话
    Idle,
    /// 正在执行任务
    Running,
    /// 等待用户输入（如 question tool）
    AwaitingInput,
    /// 任务执行成功
    Success,
    /// 任务执行失败
    Failure,
    /// 任务被取消
    Cancelled,
}

impl Default for AiDisplayStatus {
    fn default() -> Self {
        Self::Idle
    }
}

impl AiDisplayStatus {
    /// 是否为活跃中间态
    pub fn is_active(&self) -> bool {
        matches!(self, Self::Running | Self::AwaitingInput)
    }

    /// 是否为终态
    pub fn is_terminal(&self) -> bool {
        matches!(self, Self::Success | Self::Failure | Self::Cancelled)
    }

    /// 协议字符串（与 AiSessionStatus 保持一致）
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Running => "running",
            Self::AwaitingInput => "awaiting_input",
            Self::Success => "success",
            Self::Failure => "failure",
            Self::Cancelled => "cancelled",
        }
    }
}

// ============================================================================
// 领域子状态
// ============================================================================

/// AI 领域子状态
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AiDomainState {
    /// 聚合相位（治理/健康语义）
    pub phase: AiDomainPhase,
    /// 活跃会话数（running + awaiting_input）
    pub active_session_count: u32,
    /// 总会话数（含已终止）
    pub total_session_count: u32,
    /// 工作区级展示状态（终端标签栏直接消费）
    #[serde(default)]
    pub display_status: AiDisplayStatus,
    /// 当前运行中会话使用的工具名（仅 running 时有效）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_tool_name: Option<String>,
    /// 最近一次失败的错误摘要（仅 failure 时有效）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_error_message: Option<String>,
    /// 最近一次驱动展示状态变化的时间戳（Unix ms），用于多会话聚合择优
    #[serde(default)]
    pub display_updated_at: i64,
}

impl Default for AiDomainState {
    fn default() -> Self {
        Self {
            phase: AiDomainPhase::Idle,
            active_session_count: 0,
            total_session_count: 0,
            display_status: AiDisplayStatus::Idle,
            active_tool_name: None,
            last_error_message: None,
            display_updated_at: 0,
        }
    }
}

/// 终端领域子状态
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalDomainState {
    /// 聚合相位
    pub phase: TerminalDomainPhase,
    /// 存活终端数
    pub alive_count: u32,
    /// 总终端数（含已退出）
    pub total_count: u32,
}

impl Default for TerminalDomainState {
    fn default() -> Self {
        Self {
            phase: TerminalDomainPhase::Idle,
            alive_count: 0,
            total_count: 0,
        }
    }
}

/// 文件领域子状态
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileDomainState {
    /// 聚合相位
    pub phase: FileDomainPhase,
    /// watcher 是否就绪
    pub watcher_active: bool,
    /// 是否有正在进行的索引
    pub indexing_in_progress: bool,
}

impl Default for FileDomainState {
    fn default() -> Self {
        Self {
            phase: FileDomainPhase::Idle,
            watcher_active: false,
            indexing_in_progress: false,
        }
    }
}

// ============================================================================
// 工作区协调聚合状态
// ============================================================================

/// 状态持久化分类
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StatePersistence {
    /// 瞬时状态：仅存在于运行时，进程重启后丢失
    Transient,
    /// 持久化状态：可写入快照，重启后可恢复
    Persistent,
}

/// 工作区级协调聚合状态
///
/// 每个 `(project, workspace)` 一个实例，由 Core 协调层持有并维护。
/// 客户端通过协议消费此状态，不自行推导。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkspaceCoordinatorState {
    /// 身份标识
    pub id: WorkspaceCoordinatorId,
    /// AI 领域子状态（瞬时）
    pub ai: AiDomainState,
    /// 终端领域子状态（瞬时）
    pub terminal: TerminalDomainState,
    /// 文件领域子状态（瞬时）
    pub file: FileDomainState,
    /// 整体协调健康度
    pub health: CoordinatorHealth,
    /// 状态生成时间
    pub generated_at: DateTime<Utc>,
    /// 状态版本号（单调递增，用于客户端冲突检测）
    pub version: u64,
}

/// 协调层整体健康度
///
/// 由 AI、终端、文件三个领域的相位综合判定。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CoordinatorHealth {
    /// 所有领域正常
    Healthy,
    /// 至少一个领域降级但无故障
    Degraded,
    /// 至少一个领域故障
    Faulted,
}

impl Default for CoordinatorHealth {
    fn default() -> Self {
        Self::Healthy
    }
}

impl WorkspaceCoordinatorState {
    /// 创建初始协调状态
    pub fn new(id: WorkspaceCoordinatorId) -> Self {
        Self {
            id,
            ai: AiDomainState::default(),
            terminal: TerminalDomainState::default(),
            file: FileDomainState::default(),
            health: CoordinatorHealth::Healthy,
            generated_at: Utc::now(),
            version: 1,
        }
    }

    /// 从三个领域相位计算综合健康度
    pub fn compute_health(&self) -> CoordinatorHealth {
        let has_fault = self.ai.phase == AiDomainPhase::Faulted
            || self.terminal.phase == TerminalDomainPhase::Faulted
            || self.file.phase == FileDomainPhase::Error;

        if has_fault {
            return CoordinatorHealth::Faulted;
        }

        let has_degraded = self.file.phase == FileDomainPhase::Degraded;

        if has_degraded {
            return CoordinatorHealth::Degraded;
        }

        CoordinatorHealth::Healthy
    }

    /// 更新 AI 领域子状态
    pub fn update_ai(&mut self, state: AiDomainState) {
        self.ai = state;
        self.health = self.compute_health();
        self.version += 1;
        self.generated_at = Utc::now();
    }

    /// 更新终端领域子状态
    pub fn update_terminal(&mut self, state: TerminalDomainState) {
        self.terminal = state;
        self.health = self.compute_health();
        self.version += 1;
        self.generated_at = Utc::now();
    }

    /// 更新文件领域子状态
    pub fn update_file(&mut self, state: FileDomainState) {
        self.file = state;
        self.health = self.compute_health();
        self.version += 1;
        self.generated_at = Utc::now();
    }

    /// 重置为初始状态（连接断开等场景）
    pub fn reset(&mut self) {
        self.ai = AiDomainState::default();
        self.terminal = TerminalDomainState::default();
        self.file = FileDomainState::default();
        self.health = CoordinatorHealth::Healthy;
        self.version += 1;
        self.generated_at = Utc::now();
    }

    /// 判断是否所有领域均为 Idle
    pub fn is_idle(&self) -> bool {
        self.ai.phase == AiDomainPhase::Idle
            && self.terminal.phase == TerminalDomainPhase::Idle
            && self.file.phase == FileDomainPhase::Idle
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ai::session_status::{AiSessionStateStore, AiSessionStatus, AiSessionStatusMeta};
    use crate::coordinator::identity::WorkspaceCoordinatorId;

    /// 辅助：向指定工作区注入一条 AI 会话状态
    fn inject_session(
        store: &AiSessionStateStore,
        project: &str,
        workspace: &str,
        session_id: &str,
        status: AiSessionStatus,
    ) {
        store.set_status_with_meta(
            AiSessionStatusMeta {
                project_name: project.to_string(),
                workspace_name: workspace.to_string(),
                ai_tool: "codex".to_string(),
                directory: format!("/tmp/{}/{}", project, workspace),
                session_id: session_id.to_string(),
            },
            status,
        );
    }

    /// 验证 Coordinator AI 展示聚合优先级：
    /// awaiting_input > running > 终态（failure > cancelled > success）> idle
    ///
    /// 覆盖场景：
    /// - 多会话并发（至少 3 个会话同时存在）
    /// - awaiting_input 优先于 running
    /// - 终态按严重度聚合
    /// - 无会话时为 idle
    /// - 同名工作区跨项目隔离（proj-a:default 不受 proj-b:default 影响）
    #[test]
    fn coordinator_ai_display_status_prioritizes_awaiting_input() {
        use crate::ai::session_status::aggregate_workspace_ai_domain_state;

        let store = AiSessionStateStore::new();

        // ── 场景 1：无会话时为 idle ──────────────────────────────────────────────
        {
            let state = aggregate_workspace_ai_domain_state(&store, "proj-a", "default");
            assert_eq!(state.display_status, AiDisplayStatus::Idle);
            assert_eq!(state.total_session_count, 0);
        }

        // ── 场景 2：3 个并发会话，awaiting_input 优先于 running ──────────────────
        {
            inject_session(&store, "proj-a", "default", "s1", AiSessionStatus::Running);
            inject_session(&store, "proj-a", "default", "s2", AiSessionStatus::Running);
            inject_session(
                &store,
                "proj-a",
                "default",
                "s3",
                AiSessionStatus::AwaitingInput,
            );

            let state = aggregate_workspace_ai_domain_state(&store, "proj-a", "default");
            assert_eq!(
                state.display_status,
                AiDisplayStatus::AwaitingInput,
                "awaiting_input 应优先于 running（3 会话并发）"
            );
            assert_eq!(state.active_session_count, 3);
            assert_eq!(state.total_session_count, 3);
            assert_eq!(state.phase, AiDomainPhase::Active);
        }

        // ── 场景 3：移除 awaiting_input，running 胜出 ────────────────────────────
        {
            store.remove_status("codex", "/tmp/proj-a/default", "s3");
            let state = aggregate_workspace_ai_domain_state(&store, "proj-a", "default");
            assert_eq!(
                state.display_status,
                AiDisplayStatus::Running,
                "无 awaiting_input 时 running 应胜出"
            );
        }

        // ── 场景 4：终态聚合——failure > cancelled > success ──────────────────────
        {
            store.remove_status("codex", "/tmp/proj-a/default", "s1");
            store.remove_status("codex", "/tmp/proj-a/default", "s2");

            inject_session(&store, "proj-a", "default", "t1", AiSessionStatus::Success);
            inject_session(
                &store,
                "proj-a",
                "default",
                "t2",
                AiSessionStatus::Cancelled,
            );
            inject_session(
                &store,
                "proj-a",
                "default",
                "t3",
                AiSessionStatus::Failure {
                    message: "OOM".to_string(),
                },
            );

            let state = aggregate_workspace_ai_domain_state(&store, "proj-a", "default");
            assert_eq!(
                state.display_status,
                AiDisplayStatus::Failure,
                "failure 应优先于 cancelled 和 success"
            );
            assert_eq!(state.last_error_message.as_deref(), Some("OOM"));
            assert_eq!(state.phase, AiDomainPhase::Faulted);
        }

        // ── 场景 5：同名工作区跨项目隔离 ─────────────────────────────────────────
        {
            // proj-b:default 有 running 会话
            inject_session(&store, "proj-b", "default", "b1", AiSessionStatus::Running);

            // proj-a:default 状态不变（仍是终态 failure）
            let state_a = aggregate_workspace_ai_domain_state(&store, "proj-a", "default");
            assert_eq!(
                state_a.display_status,
                AiDisplayStatus::Failure,
                "proj-b 的 running 不应影响 proj-a:default"
            );

            // proj-b:default 返回 running
            let state_b = aggregate_workspace_ai_domain_state(&store, "proj-b", "default");
            assert_eq!(
                state_b.display_status,
                AiDisplayStatus::Running,
                "proj-b:default 应独立返回 running"
            );
        }

        // ── 场景 6：cancelled 优先于 success ────────────────────────────────────
        {
            inject_session(&store, "proj-a", "default", "c1", AiSessionStatus::Success);
            inject_session(
                &store,
                "proj-a",
                "default",
                "c2",
                AiSessionStatus::Cancelled,
            );
            // 移除 failure 会话
            store.remove_status("codex", "/tmp/proj-a/default", "t3");

            let state = aggregate_workspace_ai_domain_state(&store, "proj-a", "default");
            // 仍有 t1(success), t2(cancelled), c1(success), c2(cancelled)
            assert_eq!(
                state.display_status,
                AiDisplayStatus::Cancelled,
                "cancelled 应优先于 success"
            );
        }
    }

    #[test]
    fn new_state_is_healthy_and_idle() {
        let id = WorkspaceCoordinatorId::new("proj", "default");
        let state = WorkspaceCoordinatorState::new(id);
        assert_eq!(state.health, CoordinatorHealth::Healthy);
        assert!(state.is_idle());
        assert_eq!(state.version, 1);
    }

    #[test]
    fn health_degrades_on_file_degraded() {
        let id = WorkspaceCoordinatorId::new("proj", "ws-1");
        let mut state = WorkspaceCoordinatorState::new(id);
        state.update_file(FileDomainState {
            phase: FileDomainPhase::Degraded,
            watcher_active: false,
            indexing_in_progress: false,
        });
        assert_eq!(state.health, CoordinatorHealth::Degraded);
    }

    #[test]
    fn health_faults_on_ai_faulted() {
        let id = WorkspaceCoordinatorId::new("proj", "ws-2");
        let mut state = WorkspaceCoordinatorState::new(id);
        state.update_ai(AiDomainState {
            phase: AiDomainPhase::Faulted,
            active_session_count: 0,
            total_session_count: 3,
            ..Default::default()
        });
        assert_eq!(state.health, CoordinatorHealth::Faulted);
    }

    #[test]
    fn reset_returns_to_healthy_idle() {
        let id = WorkspaceCoordinatorId::new("proj", "ws-3");
        let mut state = WorkspaceCoordinatorState::new(id);
        state.update_terminal(TerminalDomainState {
            phase: TerminalDomainPhase::Active,
            alive_count: 2,
            total_count: 3,
        });
        assert!(!state.is_idle());
        state.reset();
        assert!(state.is_idle());
        assert_eq!(state.health, CoordinatorHealth::Healthy);
    }

    #[test]
    fn version_increments_on_update() {
        let id = WorkspaceCoordinatorId::new("proj", "ws-4");
        let mut state = WorkspaceCoordinatorState::new(id);
        assert_eq!(state.version, 1);
        state.update_ai(AiDomainState::default());
        assert_eq!(state.version, 2);
        state.update_terminal(TerminalDomainState::default());
        assert_eq!(state.version, 3);
    }

    #[test]
    fn serialization_roundtrip() {
        let id = WorkspaceCoordinatorId::new("proj", "default");
        let state = WorkspaceCoordinatorState::new(id);
        let json = serde_json::to_string(&state).unwrap();
        let parsed: WorkspaceCoordinatorState = serde_json::from_str(&json).unwrap();
        assert_eq!(state, parsed);
    }
}
