//! AI 路由模块
//!
//! 统一的 AI 请求路由层，负责：
//! - 基于任务类型、工作区上下文与用户显式选择决策目标 provider/model
//! - 故障自动降级（首选失败时切换候选路由）
//! - 成本感知预算治理（按工作区独立追踪）

pub mod budget;
pub mod fallback;
pub mod policy;

pub use budget::{BudgetConfig, BudgetEngine, BudgetStatusSnapshot};
pub use fallback::{FallbackConfig, FallbackEngine, FallbackReason, FallbackResult};
pub use policy::{
    DefaultRoutingPolicy, RouteCandidate, RouteDecision, RouteSelectedBy, RoutingInput,
    RoutingPolicy, SelectionHint, TaskType,
};

use std::sync::Arc;

// ============================================================================
// 路由元数据（用于协议层与状态追踪）
// ============================================================================

/// 路由元数据（随 AI 响应一起写入会话快照，便于恢复与追踪）
#[derive(Debug, Clone)]
pub struct RouteMetadata {
    /// 最终选定的 provider ID
    pub provider_id: String,
    /// 最终选定的 model ID
    pub model_id: String,
    /// 选定的 agent（若有）
    pub agent: Option<String>,
    /// 任务类型
    pub task_type: String,
    /// 选择来源
    pub selected_by: String,
    /// 是否为降级路由
    pub is_fallback: bool,
    /// 降级原因（若 is_fallback = true）
    pub fallback_reason: Option<String>,
    /// 预算状态快照（若有）
    pub budget_status: Option<BudgetStatusSnapshot>,
}

impl RouteMetadata {
    /// 从路由决策构建元数据（不含预算状态）
    pub fn from_decision(decision: &RouteDecision) -> Self {
        Self {
            provider_id: decision.provider_id.clone(),
            model_id: decision.model_id.clone(),
            agent: decision.agent.clone(),
            task_type: decision.task_type.clone(),
            selected_by: decision.selected_by.as_str().to_string(),
            is_fallback: decision.is_fallback,
            fallback_reason: decision.fallback_reason.clone(),
            budget_status: None,
        }
    }

    /// 附加预算状态
    pub fn with_budget_status(mut self, snapshot: BudgetStatusSnapshot) -> Self {
        self.budget_status = Some(snapshot);
        self
    }
}

// ============================================================================
// 路由器（组合策略 + 降级 + 预算）
// ============================================================================

/// AI 路由器：将策略、降级和预算治理组合为一个统一入口
pub struct AiRouter {
    policy: Arc<dyn RoutingPolicy>,
    fallback_engine: Arc<FallbackEngine>,
    budget_engine: Arc<BudgetEngine>,
}

impl AiRouter {
    pub fn new(
        policy: Arc<dyn RoutingPolicy>,
        fallback_engine: Arc<FallbackEngine>,
        budget_engine: Arc<BudgetEngine>,
    ) -> Self {
        Self {
            policy,
            fallback_engine,
            budget_engine,
        }
    }

    /// 根据路由输入决策路由（包含预算检查）
    ///
    /// 若当前工作区预算已超阈值，立即触发降级到下一候选。
    pub fn route(&self, input: &RoutingInput) -> (RouteDecision, RouteMetadata) {
        let decision = self.policy.decide(input);

        // 若预算已超阈值，立即降级（除非是显式指定或系统任务）
        let budget_snapshot = self.budget_engine.snapshot(&decision.workspace_key);
        if budget_snapshot.budget_exceeded && !decision.is_explicit() {
            let reason = FallbackReason::BudgetExceeded {
                threshold: 1.0,
                current: budget_snapshot.total_estimated_cost,
            };
            match self.fallback_engine.try_fallback(&decision, reason) {
                FallbackResult::Fallback {
                    decision: fallback_decision,
                    ..
                } => {
                    let metadata = RouteMetadata::from_decision(&fallback_decision)
                        .with_budget_status(budget_snapshot);
                    return (fallback_decision, metadata);
                }
                FallbackResult::Exhausted { .. } => {
                    // 预算超阈值且无候选，仍使用原决策（由上层决定是否拒绝）
                }
            }
        }

        let metadata = RouteMetadata::from_decision(&decision).with_budget_status(budget_snapshot);
        (decision, metadata)
    }

    /// 对已失败的路由执行降级
    pub fn fallback(
        &self,
        current_decision: &RouteDecision,
        reason: FallbackReason,
    ) -> FallbackResult {
        self.fallback_engine.try_fallback(current_decision, reason)
    }

    /// 获取底层预算引擎（供 session handler 记录 token 使用）
    pub fn budget_engine(&self) -> Arc<BudgetEngine> {
        Arc::clone(&self.budget_engine)
    }

    /// 获取底层降级引擎（供状态监控使用）
    pub fn fallback_engine(&self) -> Arc<FallbackEngine> {
        Arc::clone(&self.fallback_engine)
    }
}

// ============================================================================
// 便捷构造器
// ============================================================================

/// 构建一个使用默认策略和默认配置的 AiRouter
pub fn build_default_router(
    default_provider_id: impl Into<String>,
    default_model_id: impl Into<String>,
) -> AiRouter {
    let policy = Arc::new(DefaultRoutingPolicy::new(
        default_provider_id,
        default_model_id,
    ));
    let fallback_engine = Arc::new(FallbackEngine::new(FallbackConfig::default()));
    let budget_engine = Arc::new(BudgetEngine::new(BudgetConfig::default()));
    AiRouter::new(policy, fallback_engine, budget_engine)
}
