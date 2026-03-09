//! AI 路由故障自动降级策略
//!
//! 当首选 provider/model 失败、超时或预算超阈值时，从 RouteDecision.candidates 中
//! 选择下一个候选路由继续执行，并记录降级元数据。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::policy::{RouteCandidate, RouteDecision, RouteSelectedBy};

// ============================================================================
// 降级原因枚举
// ============================================================================

/// 触发降级的原因类型
#[derive(Debug, Clone, PartialEq)]
pub enum FallbackReason {
    /// Provider 返回错误
    ProviderError { code: Option<u16>, message: String },
    /// 请求超时
    Timeout { timeout_ms: u64 },
    /// 预算超阈值
    BudgetExceeded { threshold: f64, current: f64 },
    /// 重试次数超限
    RetryLimitExceeded { limit: u32 },
    /// 其它原因
    Other { message: String },
}

impl FallbackReason {
    pub fn as_str(&self) -> String {
        match self {
            FallbackReason::ProviderError { code, message } => {
                if let Some(c) = code {
                    format!("provider_error:{c}:{message}")
                } else {
                    format!("provider_error:{message}")
                }
            }
            FallbackReason::Timeout { timeout_ms } => format!("timeout:{timeout_ms}ms"),
            FallbackReason::BudgetExceeded { threshold, current } => {
                format!("budget_exceeded:threshold={threshold:.2},current={current:.2}")
            }
            FallbackReason::RetryLimitExceeded { limit } => {
                format!("retry_limit_exceeded:{limit}")
            }
            FallbackReason::Other { message } => format!("other:{message}"),
        }
    }
}

// ============================================================================
// 降级状态（每个工作区独立）
// ============================================================================

/// 单次降级记录
#[derive(Debug, Clone)]
pub struct FallbackRecord {
    /// 降级发生时间
    pub at: Instant,
    /// 被降级的 provider/model
    pub from_provider: String,
    pub from_model: String,
    /// 降级到的 provider/model
    pub to_provider: String,
    pub to_model: String,
    /// 降级原因
    pub reason: String,
}

/// 工作区维度的降级状态（多工作区隔离）
#[derive(Debug, Default)]
pub struct WorkspaceFallbackState {
    /// 当前已降级次数
    pub fallback_count: u32,
    /// 降级历史（最近 N 条）
    pub records: Vec<FallbackRecord>,
}

impl WorkspaceFallbackState {
    pub fn record(
        &mut self,
        from_provider: &str,
        from_model: &str,
        to_provider: &str,
        to_model: &str,
        reason: &str,
        max_history: usize,
    ) {
        self.fallback_count += 1;
        self.records.push(FallbackRecord {
            at: Instant::now(),
            from_provider: from_provider.to_string(),
            from_model: from_model.to_string(),
            to_provider: to_provider.to_string(),
            to_model: to_model.to_string(),
            reason: reason.to_string(),
        });
        // 保留最近 max_history 条
        if self.records.len() > max_history {
            self.records.remove(0);
        }
    }
}

// ============================================================================
// 降级策略
// ============================================================================

/// 降级策略配置
#[derive(Debug, Clone)]
pub struct FallbackConfig {
    /// 最大重试次数（超过则返回错误，不再降级）
    pub max_retries: u32,
    /// 请求超时（触发超时降级）
    pub request_timeout: Duration,
    /// 最大降级历史记录数
    pub max_history_per_workspace: usize,
}

impl Default for FallbackConfig {
    fn default() -> Self {
        Self {
            max_retries: 3,
            request_timeout: Duration::from_secs(60),
            max_history_per_workspace: 20,
        }
    }
}

/// 降级执行结果
#[derive(Debug)]
pub enum FallbackResult {
    /// 成功找到降级路由
    Fallback {
        decision: RouteDecision,
        reason: String,
    },
    /// 无更多候选，降级失败
    Exhausted { reason: String },
}

/// AI 降级策略引擎（按工作区隔离状态）
pub struct FallbackEngine {
    config: FallbackConfig,
    /// 按 workspace_key 存储降级状态
    workspace_states: Arc<Mutex<HashMap<String, WorkspaceFallbackState>>>,
}

impl FallbackEngine {
    pub fn new(config: FallbackConfig) -> Self {
        Self {
            config,
            workspace_states: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// 对给定路由决策执行降级（返回下一个候选路由或 Exhausted）
    ///
    /// - `current_decision`：当前已失败的路由决策
    /// - `reason`：触发降级的原因
    pub fn try_fallback(
        &self,
        current_decision: &RouteDecision,
        reason: FallbackReason,
    ) -> FallbackResult {
        let reason_str = reason.as_str();

        // 查找当前路由在候选列表中的位置
        let current_idx = current_decision
            .candidates
            .iter()
            .position(|c| {
                c.provider_id == current_decision.provider_id
                    && c.model_id == current_decision.model_id
            })
            .unwrap_or(0);

        // 找到下一个未尝试候选
        let next_candidate = current_decision
            .candidates
            .iter()
            .enumerate()
            .skip(current_idx + 1)
            .map(|(_, c)| c)
            .next();

        // 检查重试次数限制
        let fallback_count = {
            let states = self.workspace_states.lock().unwrap_or_else(|e| e.into_inner());
            states
                .get(&current_decision.workspace_key)
                .map(|s| s.fallback_count)
                .unwrap_or(0)
        };

        if fallback_count >= self.config.max_retries {
            return FallbackResult::Exhausted {
                reason: format!(
                    "retry_limit_exceeded: max_retries={}, reason={}",
                    self.config.max_retries, reason_str
                ),
            };
        }

        match next_candidate {
            None => FallbackResult::Exhausted {
                reason: format!("no_more_candidates: reason={reason_str}"),
            },
            Some(candidate) => {
                let new_decision = current_decision.clone().into_fallback(
                    reason_str.clone(),
                    candidate.provider_id.clone(),
                    candidate.model_id.clone(),
                    candidate.agent.clone(),
                );

                // 记录降级
                {
                    let mut states = self
                        .workspace_states
                        .lock()
                        .unwrap_or_else(|e| e.into_inner());
                    let state = states
                        .entry(current_decision.workspace_key.clone())
                        .or_default();
                    state.record(
                        &current_decision.provider_id,
                        &current_decision.model_id,
                        &new_decision.provider_id,
                        &new_decision.model_id,
                        &reason_str,
                        self.config.max_history_per_workspace,
                    );
                }

                FallbackResult::Fallback {
                    decision: new_decision,
                    reason: reason_str,
                }
            }
        }
    }

    /// 获取工作区的当前降级次数（用于状态展示）
    pub fn fallback_count(&self, workspace_key: &str) -> u32 {
        let states = self.workspace_states.lock().unwrap_or_else(|e| e.into_inner());
        states
            .get(workspace_key)
            .map(|s| s.fallback_count)
            .unwrap_or(0)
    }

    /// 重置工作区降级状态（会话结束时调用）
    pub fn reset_workspace(&self, workspace_key: &str) {
        let mut states = self.workspace_states.lock().unwrap_or_else(|e| e.into_inner());
        states.remove(workspace_key);
    }

    /// 清理所有降级状态（维护时调用）
    pub fn clear_all(&self) {
        let mut states = self.workspace_states.lock().unwrap_or_else(|e| e.into_inner());
        states.clear();
    }
}

// ============================================================================
// 测试
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ai::routing::policy::{
        DefaultRoutingPolicy, RoutingInput, RoutingPolicy, TaskType,
    };

    fn make_engine() -> FallbackEngine {
        FallbackEngine::new(FallbackConfig {
            max_retries: 2,
            ..Default::default()
        })
    }

    fn make_decision_with_candidates() -> RouteDecision {
        let policy = DefaultRoutingPolicy::new("openai", "gpt-4o")
            .with_task_type_mapping(TaskType::CodeGeneration, "anthropic", "claude-3-5-sonnet");
        let input = RoutingInput::new(TaskType::CodeGeneration, "proj-a", "ws-1");
        policy.decide(&input)
    }

    #[test]
    fn fallback_switches_to_next_candidate() {
        let engine = make_engine();
        let decision = make_decision_with_candidates();

        assert_eq!(decision.provider_id, "anthropic");
        assert_eq!(decision.candidates.len(), 2);

        let result = engine.try_fallback(
            &decision,
            FallbackReason::ProviderError {
                code: Some(503),
                message: "Service Unavailable".to_string(),
            },
        );

        match result {
            FallbackResult::Fallback { decision: new_decision, reason } => {
                assert!(new_decision.is_fallback);
                assert_eq!(new_decision.provider_id, "openai");
                assert_eq!(new_decision.model_id, "gpt-4o");
                assert!(reason.contains("provider_error"));
            }
            FallbackResult::Exhausted { .. } => panic!("Should have found a fallback"),
        }
    }

    #[test]
    fn fallback_exhausted_when_no_more_candidates() {
        let engine = make_engine();
        let decision = make_decision_with_candidates();

        // 第一次降级
        let result1 = engine.try_fallback(
            &decision,
            FallbackReason::Timeout { timeout_ms: 5000 },
        );
        let second_decision = match result1 {
            FallbackResult::Fallback { decision, .. } => decision,
            _ => panic!("Expected fallback"),
        };

        // 第二次降级（已无候选）
        let result2 = engine.try_fallback(
            &second_decision,
            FallbackReason::Timeout { timeout_ms: 5000 },
        );
        assert!(matches!(result2, FallbackResult::Exhausted { .. }));
    }

    #[test]
    fn fallback_respects_retry_limit() {
        let engine = make_engine(); // max_retries=2
        let decision = make_decision_with_candidates();

        // 前 2 次降级都成功
        let _ = engine.try_fallback(&decision, FallbackReason::Other { message: "err1".into() });
        let _ = engine.try_fallback(&decision, FallbackReason::Other { message: "err2".into() });

        // 第 3 次触发 retry limit
        let result = engine.try_fallback(&decision, FallbackReason::Other { message: "err3".into() });
        assert!(matches!(result, FallbackResult::Exhausted { .. }));
    }

    #[test]
    fn fallback_workspace_isolation() {
        let engine = make_engine();

        // ws-1 降级 1 次
        let decision_ws1 = {
            let policy = DefaultRoutingPolicy::new("openai", "gpt-4o")
                .with_task_type_mapping(TaskType::CodeGeneration, "anthropic", "claude");
            let input = RoutingInput::new(TaskType::CodeGeneration, "proj-a", "ws-1");
            policy.decide(&input)
        };
        let _ = engine.try_fallback(&decision_ws1, FallbackReason::Other { message: "err".into() });

        // ws-2 未降级
        let decision_ws2 = {
            let policy = DefaultRoutingPolicy::new("openai", "gpt-4o")
                .with_task_type_mapping(TaskType::CodeGeneration, "anthropic", "claude");
            let input = RoutingInput::new(TaskType::CodeGeneration, "proj-a", "ws-2");
            policy.decide(&input)
        };

        assert_eq!(engine.fallback_count("proj-a::ws-1"), 1);
        assert_eq!(engine.fallback_count("proj-a::ws-2"), 0);
    }

    #[test]
    fn fallback_reset_clears_state() {
        let engine = make_engine();
        let decision = make_decision_with_candidates();
        let _ = engine.try_fallback(&decision, FallbackReason::Other { message: "err".into() });
        assert_eq!(engine.fallback_count("proj-a::ws-1"), 1);

        engine.reset_workspace("proj-a::ws-1");
        assert_eq!(engine.fallback_count("proj-a::ws-1"), 0);
    }

    #[test]
    fn fallback_reason_budget_exceeded() {
        let reason = FallbackReason::BudgetExceeded { threshold: 10.0, current: 15.5 };
        let s = reason.as_str();
        assert!(s.contains("budget_exceeded"));
        assert!(s.contains("15.50") || s.contains("15.5"));
    }
}
