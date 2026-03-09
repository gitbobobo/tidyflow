//! AI 路由预算（成本感知）模块
//!
//! 按 project/workspace/ai_tool/session 维度追踪 token 使用量与成本估算，
//! 在触发预算阈值时通知降级策略。各工作区预算独立计算，互不影响。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

// ============================================================================
// 预算配置
// ============================================================================

/// 预算配置（全局或按工作区覆盖）
#[derive(Debug, Clone)]
pub struct BudgetConfig {
    /// 单会话最大 token 数（0 表示不限）
    pub max_tokens_per_session: u64,
    /// 单工作区每分钟最大并发请求数（0 表示不限）
    pub max_concurrent_requests_per_workspace: u32,
    /// 成本阈值（归一化单位，0.0 表示不限）
    pub cost_threshold: f64,
}

impl Default for BudgetConfig {
    fn default() -> Self {
        Self {
            max_tokens_per_session: 0,
            max_concurrent_requests_per_workspace: 10,
            cost_threshold: 0.0,
        }
    }
}

// ============================================================================
// 预算状态
// ============================================================================

/// 单会话的 token 使用快照
#[derive(Debug, Clone, Default)]
pub struct SessionTokenUsage {
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    pub total_tokens: u64,
    /// 估算成本（归一化单位）
    pub estimated_cost: f64,
}

impl SessionTokenUsage {
    pub fn add(&mut self, prompt: u64, completion: u64, cost_per_1k_tokens: f64) {
        self.prompt_tokens += prompt;
        self.completion_tokens += completion;
        self.total_tokens += prompt + completion;
        self.estimated_cost += (prompt + completion) as f64 / 1000.0 * cost_per_1k_tokens;
    }
}

/// 工作区预算状态
#[derive(Debug, Default)]
pub struct WorkspaceBudgetState {
    /// 按 session_id 的 token 使用量
    pub sessions: HashMap<String, SessionTokenUsage>,
    /// 当前活跃并发请求数
    pub active_requests: u32,
    /// 是否已触发预算告警（需要手动重置）
    pub budget_exceeded: bool,
    /// 最近超预算原因
    pub last_exceeded_reason: Option<String>,
}

impl WorkspaceBudgetState {
    /// 获取工作区所有会话的总 token 使用
    pub fn total_tokens(&self) -> u64 {
        self.sessions.values().map(|s| s.total_tokens).sum()
    }

    /// 获取工作区所有会话的总估算成本
    pub fn total_estimated_cost(&self) -> f64 {
        self.sessions.values().map(|s| s.estimated_cost).sum()
    }
}

// ============================================================================
// 预算引擎
// ============================================================================

/// 预算状态快照（用于协议层序列化）
#[derive(Debug, Clone)]
pub struct BudgetStatusSnapshot {
    /// 工作区键
    pub workspace_key: String,
    /// 是否已超阈值
    pub budget_exceeded: bool,
    /// 最近超阈值原因
    pub last_exceeded_reason: Option<String>,
    /// 当前并发请求数
    pub active_requests: u32,
    /// 总 token 数
    pub total_tokens: u64,
    /// 总估算成本
    pub total_estimated_cost: f64,
}

/// AI 预算引擎（按工作区隔离）
pub struct BudgetEngine {
    config: BudgetConfig,
    /// 按 workspace_key 存储预算状态
    workspace_states: Arc<Mutex<HashMap<String, WorkspaceBudgetState>>>,
}

impl BudgetEngine {
    pub fn new(config: BudgetConfig) -> Self {
        Self {
            config,
            workspace_states: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// 开始一个新请求，返回是否允许（false = 并发超限）
    pub fn acquire_request_slot(&self, workspace_key: &str) -> bool {
        if self.config.max_concurrent_requests_per_workspace == 0 {
            return true;
        }
        let mut states = self.workspace_states.lock().unwrap_or_else(|e| e.into_inner());
        let state = states.entry(workspace_key.to_string()).or_default();
        if state.active_requests >= self.config.max_concurrent_requests_per_workspace {
            return false;
        }
        state.active_requests += 1;
        true
    }

    /// 释放请求槽（请求完成时调用，无论成功失败）
    pub fn release_request_slot(&self, workspace_key: &str) {
        let mut states = self.workspace_states.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(state) = states.get_mut(workspace_key) {
            state.active_requests = state.active_requests.saturating_sub(1);
        }
    }

    /// 记录会话 token 使用量，返回是否触发预算阈值
    pub fn record_token_usage(
        &self,
        workspace_key: &str,
        session_id: &str,
        prompt_tokens: u64,
        completion_tokens: u64,
        cost_per_1k_tokens: f64,
    ) -> bool {
        let mut states = self.workspace_states.lock().unwrap_or_else(|e| e.into_inner());
        let state = states.entry(workspace_key.to_string()).or_default();

        let session = state.sessions.entry(session_id.to_string()).or_default();
        session.add(prompt_tokens, completion_tokens, cost_per_1k_tokens);

        // 检查 token 限制
        if self.config.max_tokens_per_session > 0
            && session.total_tokens > self.config.max_tokens_per_session
        {
            let reason = format!(
                "session_token_limit: limit={}, current={}",
                self.config.max_tokens_per_session, session.total_tokens
            );
            state.budget_exceeded = true;
            state.last_exceeded_reason = Some(reason);
            return true;
        }

        // 检查成本阈值
        if self.config.cost_threshold > 0.0 {
            let total_cost: f64 = state.sessions.values().map(|s| s.estimated_cost).sum();
            if total_cost > self.config.cost_threshold {
                let reason = format!(
                    "cost_threshold_exceeded: threshold={:.4}, current={:.4}",
                    self.config.cost_threshold, total_cost
                );
                state.budget_exceeded = true;
                state.last_exceeded_reason = Some(reason);
                return true;
            }
        }

        false
    }

    /// 获取工作区预算状态快照
    pub fn snapshot(&self, workspace_key: &str) -> BudgetStatusSnapshot {
        let states = self.workspace_states.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(state) = states.get(workspace_key) {
            BudgetStatusSnapshot {
                workspace_key: workspace_key.to_string(),
                budget_exceeded: state.budget_exceeded,
                last_exceeded_reason: state.last_exceeded_reason.clone(),
                active_requests: state.active_requests,
                total_tokens: state.total_tokens(),
                total_estimated_cost: state.total_estimated_cost(),
            }
        } else {
            BudgetStatusSnapshot {
                workspace_key: workspace_key.to_string(),
                budget_exceeded: false,
                last_exceeded_reason: None,
                active_requests: 0,
                total_tokens: 0,
                total_estimated_cost: 0.0,
            }
        }
    }

    /// 重置工作区预算超阈值标志
    pub fn reset_budget_exceeded(&self, workspace_key: &str) {
        let mut states = self.workspace_states.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(state) = states.get_mut(workspace_key) {
            state.budget_exceeded = false;
            state.last_exceeded_reason = None;
        }
    }

    /// 清除工作区所有预算状态（会话清理时调用）
    pub fn clear_workspace(&self, workspace_key: &str) {
        let mut states = self.workspace_states.lock().unwrap_or_else(|e| e.into_inner());
        states.remove(workspace_key);
    }
}

// ============================================================================
// 测试
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn make_engine_with_token_limit(limit: u64) -> BudgetEngine {
        BudgetEngine::new(BudgetConfig {
            max_tokens_per_session: limit,
            max_concurrent_requests_per_workspace: 3,
            cost_threshold: 0.0,
        })
    }

    fn make_engine_with_cost_limit(cost: f64) -> BudgetEngine {
        BudgetEngine::new(BudgetConfig {
            max_tokens_per_session: 0,
            max_concurrent_requests_per_workspace: 10,
            cost_threshold: cost,
        })
    }

    #[test]
    fn budget_token_limit_triggers_exceeded() {
        let engine = make_engine_with_token_limit(100);

        // 未超限
        let exceeded = engine.record_token_usage("proj::ws-1", "sess-1", 40, 40, 0.01);
        assert!(!exceeded);

        // 超限（40+40+30+10 = 120 > 100）
        let exceeded = engine.record_token_usage("proj::ws-1", "sess-1", 30, 10, 0.01);
        assert!(exceeded);

        let snapshot = engine.snapshot("proj::ws-1");
        assert!(snapshot.budget_exceeded);
        assert!(snapshot.last_exceeded_reason.is_some());
    }

    #[test]
    fn budget_cost_limit_triggers_exceeded() {
        let engine = make_engine_with_cost_limit(0.1);

        // 1000 tokens * 0.2 / 1000 = 0.2 > 0.1
        let exceeded = engine.record_token_usage("proj::ws-2", "sess-1", 500, 500, 0.2);
        assert!(exceeded);
    }

    #[test]
    fn budget_workspace_isolation() {
        let engine = make_engine_with_token_limit(100);

        // ws-1 超限
        engine.record_token_usage("proj::ws-1", "sess-1", 60, 60, 0.01);

        // ws-2 未超限
        engine.record_token_usage("proj::ws-2", "sess-1", 20, 20, 0.01);

        assert!(engine.snapshot("proj::ws-1").budget_exceeded);
        assert!(!engine.snapshot("proj::ws-2").budget_exceeded);
    }

    #[test]
    fn budget_concurrent_request_slots() {
        let engine = BudgetEngine::new(BudgetConfig {
            max_concurrent_requests_per_workspace: 2,
            ..Default::default()
        });

        assert!(engine.acquire_request_slot("proj::ws-1")); // slot 1
        assert!(engine.acquire_request_slot("proj::ws-1")); // slot 2
        assert!(!engine.acquire_request_slot("proj::ws-1")); // 超限

        engine.release_request_slot("proj::ws-1");
        assert!(engine.acquire_request_slot("proj::ws-1")); // 再次可用
    }

    #[test]
    fn budget_concurrent_isolation_across_workspaces() {
        let engine = BudgetEngine::new(BudgetConfig {
            max_concurrent_requests_per_workspace: 1,
            ..Default::default()
        });

        engine.acquire_request_slot("proj::ws-1");
        // ws-2 不受 ws-1 的 slot 占用影响
        assert!(engine.acquire_request_slot("proj::ws-2"));
    }

    #[test]
    fn budget_reset_clears_exceeded_flag() {
        let engine = make_engine_with_token_limit(10);
        engine.record_token_usage("proj::ws-1", "sess-1", 10, 10, 0.01);
        assert!(engine.snapshot("proj::ws-1").budget_exceeded);

        engine.reset_budget_exceeded("proj::ws-1");
        assert!(!engine.snapshot("proj::ws-1").budget_exceeded);
    }
}
