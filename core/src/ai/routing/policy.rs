//! AI 路由策略模块
//!
//! 定义路由输入（RoutingInput）、路由决策（RouteDecision）和路由策略（RoutingPolicy）。
//! 路由层在 agent/model 选择链路中插入，不破坏现有显式选择语义。

use std::collections::HashMap;
use std::str::FromStr;

// ============================================================================
// 任务类型
// ============================================================================

/// AI 任务类型，用于策略路由中的优先级判断
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum TaskType {
    /// 通用对话
    Chat,
    /// 代码生成
    CodeGeneration,
    /// 代码审查
    CodeReview,
    /// 代码补全（轻量）
    CodeCompletion,
    /// 文档生成
    Documentation,
    /// 调试辅助
    Debugging,
    /// 系统/进化任务（内部）
    System,
    /// 未分类
    Unknown,
}

impl TaskType {
    /// 转为字符串
    pub fn as_str(&self) -> &'static str {
        match self {
            TaskType::Chat => "chat",
            TaskType::CodeGeneration => "code_generation",
            TaskType::CodeReview => "code_review",
            TaskType::CodeCompletion => "code_completion",
            TaskType::Documentation => "documentation",
            TaskType::Debugging => "debugging",
            TaskType::System => "system",
            TaskType::Unknown => "unknown",
        }
    }

    /// 任务类型的成本权重（0.0–1.0），用于预算优先级排序
    pub fn cost_weight(&self) -> f64 {
        match self {
            TaskType::CodeCompletion => 0.1,
            TaskType::Chat => 0.3,
            TaskType::Documentation => 0.4,
            TaskType::CodeGeneration => 0.7,
            TaskType::CodeReview => 0.6,
            TaskType::Debugging => 0.6,
            TaskType::System => 1.0,
            TaskType::Unknown => 0.5,
        }
    }
}

impl FromStr for TaskType {
    type Err = std::convert::Infallible;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(match s {
            "chat" => TaskType::Chat,
            "code_generation" | "code_gen" => TaskType::CodeGeneration,
            "code_review" => TaskType::CodeReview,
            "code_completion" => TaskType::CodeCompletion,
            "documentation" | "docs" => TaskType::Documentation,
            "debugging" | "debug" => TaskType::Debugging,
            "system" => TaskType::System,
            _ => TaskType::Unknown,
        })
    }
}

// ============================================================================
// 路由输入
// ============================================================================

/// AI 路由统一输入，包含所有决策所需的上下文
#[derive(Debug, Clone)]
pub struct RoutingInput {
    /// 任务类型
    pub task_type: TaskType,
    /// 项目名称（多项目隔离键）
    pub project_name: String,
    /// 工作区名称（多工作区隔离键）
    pub workspace_name: String,
    /// 用户显式选择的 provider ID（优先级最高）
    pub explicit_provider_id: Option<String>,
    /// 用户显式选择的 model ID（优先级最高）
    pub explicit_model_id: Option<String>,
    /// 用户显式选择的 agent 名称
    pub explicit_agent: Option<String>,
    /// 历史 selection hint（用于恢复上次选择）
    pub selection_hint: Option<SelectionHint>,
    /// 额外策略参数（透传到策略实现）
    pub extra: HashMap<String, String>,
}

impl RoutingInput {
    /// 创建最简路由输入（无显式选择）
    pub fn new(
        task_type: TaskType,
        project_name: impl Into<String>,
        workspace_name: impl Into<String>,
    ) -> Self {
        Self {
            task_type,
            project_name: project_name.into(),
            workspace_name: workspace_name.into(),
            explicit_provider_id: None,
            explicit_model_id: None,
            explicit_agent: None,
            selection_hint: None,
            extra: HashMap::new(),
        }
    }

    /// 设置显式 provider/model 选择
    pub fn with_explicit_model(
        mut self,
        provider_id: impl Into<String>,
        model_id: impl Into<String>,
    ) -> Self {
        self.explicit_provider_id = Some(provider_id.into());
        self.explicit_model_id = Some(model_id.into());
        self
    }

    /// 设置显式 agent 选择
    pub fn with_explicit_agent(mut self, agent: impl Into<String>) -> Self {
        self.explicit_agent = Some(agent.into());
        self
    }

    /// 设置 selection hint（历史恢复）
    pub fn with_selection_hint(mut self, hint: SelectionHint) -> Self {
        self.selection_hint = Some(hint);
        self
    }

    /// 工作区唯一键（用于状态隔离）
    pub fn workspace_key(&self) -> String {
        format!("{}::{}", self.project_name, self.workspace_name)
    }
}

/// 历史选择提示（来自上次会话或用户偏好）
#[derive(Debug, Clone, Default)]
pub struct SelectionHint {
    pub agent: Option<String>,
    pub provider_id: Option<String>,
    pub model_id: Option<String>,
}

// ============================================================================
// 路由决策
// ============================================================================

/// 路由选择来源
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RouteSelectedBy {
    /// 用户显式指定（最高优先级）
    Explicit,
    /// 任务类型策略自动选择
    TaskTypePolicy,
    /// 来自历史 selection hint 恢复
    SelectionHint,
    /// 系统默认（兜底）
    Default,
}

impl RouteSelectedBy {
    pub fn as_str(&self) -> &'static str {
        match self {
            RouteSelectedBy::Explicit => "explicit",
            RouteSelectedBy::TaskTypePolicy => "task_type_policy",
            RouteSelectedBy::SelectionHint => "selection_hint",
            RouteSelectedBy::Default => "default",
        }
    }
}

/// 单条候选路由
#[derive(Debug, Clone)]
pub struct RouteCandidate {
    pub provider_id: String,
    pub model_id: String,
    pub agent: Option<String>,
    /// 候选优先级（值越小优先级越高）
    pub priority: u32,
}

/// 路由决策结果（单次路由请求的完整决策）
#[derive(Debug, Clone)]
pub struct RouteDecision {
    /// 选定的 provider ID
    pub provider_id: String,
    /// 选定的 model ID
    pub model_id: String,
    /// 选定的 agent（若有）
    pub agent: Option<String>,
    /// 任务类型
    pub task_type: String,
    /// 工作区键（用于隔离追踪）
    pub workspace_key: String,
    /// 选择来源
    pub selected_by: RouteSelectedBy,
    /// 是否为降级路由（首选失败后切换到候选）
    pub is_fallback: bool,
    /// 降级原因（若 is_fallback = true）
    pub fallback_reason: Option<String>,
    /// 候选路由列表（用于降级链）
    pub candidates: Vec<RouteCandidate>,
}

impl RouteDecision {
    /// 是否为显式选择（用户指定，不允许策略覆盖）
    pub fn is_explicit(&self) -> bool {
        self.selected_by == RouteSelectedBy::Explicit
    }

    /// 创建降级版本（保留 candidates 链，更新主路由到下一候选）
    pub fn into_fallback(
        self,
        fallback_reason: impl Into<String>,
        next_provider: String,
        next_model: String,
        next_agent: Option<String>,
    ) -> Self {
        Self {
            provider_id: next_provider,
            model_id: next_model,
            agent: next_agent,
            is_fallback: true,
            fallback_reason: Some(fallback_reason.into()),
            selected_by: RouteSelectedBy::Default,
            ..self
        }
    }
}

// ============================================================================
// 路由策略接口
// ============================================================================

/// 路由策略 trait（可扩展，例如"任务类型优先"、"成本最低"等）
pub trait RoutingPolicy: Send + Sync {
    /// 名称（用于日志和追踪）
    fn name(&self) -> &str;

    /// 根据输入生成路由决策
    fn decide(&self, input: &RoutingInput) -> RouteDecision;
}

// ============================================================================
// 默认路由策略实现
// ============================================================================

/// 默认路由策略：
/// 1. 显式选择 > 2. 任务类型映射 > 3. selection hint > 4. 系统默认
pub struct DefaultRoutingPolicy {
    /// 任务类型到 (provider_id, model_id) 的静态映射
    task_type_map: HashMap<String, (String, String)>,
    /// 全局默认 provider/model（兜底）
    default_provider_id: String,
    default_model_id: String,
}

impl DefaultRoutingPolicy {
    pub fn new(
        default_provider_id: impl Into<String>,
        default_model_id: impl Into<String>,
    ) -> Self {
        Self {
            task_type_map: HashMap::new(),
            default_provider_id: default_provider_id.into(),
            default_model_id: default_model_id.into(),
        }
    }

    /// 注册任务类型到模型的静态映射
    pub fn with_task_type_mapping(
        mut self,
        task_type: TaskType,
        provider_id: impl Into<String>,
        model_id: impl Into<String>,
    ) -> Self {
        self.task_type_map.insert(
            task_type.as_str().to_string(),
            (provider_id.into(), model_id.into()),
        );
        self
    }

    fn build_candidates(&self, primary_provider: &str, primary_model: &str) -> Vec<RouteCandidate> {
        let mut candidates = vec![RouteCandidate {
            provider_id: primary_provider.to_string(),
            model_id: primary_model.to_string(),
            agent: None,
            priority: 0,
        }];
        // 若首选不是 default，则添加 default 作为候选（用于降级）
        if primary_provider != self.default_provider_id || primary_model != self.default_model_id {
            candidates.push(RouteCandidate {
                provider_id: self.default_provider_id.clone(),
                model_id: self.default_model_id.clone(),
                agent: None,
                priority: 99,
            });
        }
        candidates
    }
}

impl RoutingPolicy for DefaultRoutingPolicy {
    fn name(&self) -> &str {
        "default"
    }

    fn decide(&self, input: &RoutingInput) -> RouteDecision {
        let workspace_key = input.workspace_key();
        let task_type = input.task_type.as_str().to_string();

        // 优先级 1：用户显式选择（不可被策略覆盖）
        if let (Some(provider_id), Some(model_id)) = (
            input.explicit_provider_id.as_ref(),
            input.explicit_model_id.as_ref(),
        ) {
            return RouteDecision {
                provider_id: provider_id.clone(),
                model_id: model_id.clone(),
                agent: input.explicit_agent.clone(),
                task_type,
                workspace_key,
                selected_by: RouteSelectedBy::Explicit,
                is_fallback: false,
                fallback_reason: None,
                candidates: self.build_candidates(provider_id, model_id),
            };
        }

        // 优先级 2：任务类型映射
        if let Some((provider_id, model_id)) = self.task_type_map.get(&task_type) {
            return RouteDecision {
                provider_id: provider_id.clone(),
                model_id: model_id.clone(),
                agent: input.explicit_agent.clone(),
                task_type,
                workspace_key,
                selected_by: RouteSelectedBy::TaskTypePolicy,
                is_fallback: false,
                fallback_reason: None,
                candidates: self.build_candidates(provider_id, model_id),
            };
        }

        // 优先级 3：历史 selection hint 恢复
        if let Some(hint) = &input.selection_hint {
            if let (Some(provider_id), Some(model_id)) =
                (hint.provider_id.as_ref(), hint.model_id.as_ref())
            {
                return RouteDecision {
                    provider_id: provider_id.clone(),
                    model_id: model_id.clone(),
                    agent: hint.agent.clone().or_else(|| input.explicit_agent.clone()),
                    task_type,
                    workspace_key,
                    selected_by: RouteSelectedBy::SelectionHint,
                    is_fallback: false,
                    fallback_reason: None,
                    candidates: self.build_candidates(provider_id, model_id),
                };
            }
        }

        // 优先级 4：系统默认兜底
        RouteDecision {
            provider_id: self.default_provider_id.clone(),
            model_id: self.default_model_id.clone(),
            agent: input.explicit_agent.clone(),
            task_type,
            workspace_key,
            selected_by: RouteSelectedBy::Default,
            is_fallback: false,
            fallback_reason: None,
            candidates: self.build_candidates(
                &self.default_provider_id.clone(),
                &self.default_model_id.clone(),
            ),
        }
    }
}

// ============================================================================
// 测试
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn make_policy() -> DefaultRoutingPolicy {
        DefaultRoutingPolicy::new("openai", "gpt-4o")
            .with_task_type_mapping(TaskType::CodeCompletion, "anthropic", "claude-3-haiku")
            .with_task_type_mapping(TaskType::CodeGeneration, "anthropic", "claude-3-5-sonnet")
    }

    #[test]
    fn routing_explicit_selection_overrides_all() {
        let policy = make_policy();
        let input = RoutingInput::new(TaskType::CodeGeneration, "proj-a", "ws-1")
            .with_explicit_model("custom_provider", "custom_model");

        let decision = policy.decide(&input);
        assert_eq!(decision.provider_id, "custom_provider");
        assert_eq!(decision.model_id, "custom_model");
        assert_eq!(decision.selected_by, RouteSelectedBy::Explicit);
        assert!(!decision.is_fallback);
    }

    #[test]
    fn routing_task_type_mapping() {
        let policy = make_policy();
        let input = RoutingInput::new(TaskType::CodeCompletion, "proj-a", "ws-1");

        let decision = policy.decide(&input);
        assert_eq!(decision.provider_id, "anthropic");
        assert_eq!(decision.model_id, "claude-3-haiku");
        assert_eq!(decision.selected_by, RouteSelectedBy::TaskTypePolicy);
    }

    #[test]
    fn routing_selection_hint_fallback() {
        let policy = make_policy();
        let hint = SelectionHint {
            provider_id: Some("openai".to_string()),
            model_id: Some("gpt-4-turbo".to_string()),
            agent: None,
        };
        let input =
            RoutingInput::new(TaskType::Unknown, "proj-b", "ws-2").with_selection_hint(hint);

        let decision = policy.decide(&input);
        assert_eq!(decision.provider_id, "openai");
        assert_eq!(decision.model_id, "gpt-4-turbo");
        assert_eq!(decision.selected_by, RouteSelectedBy::SelectionHint);
    }

    #[test]
    fn routing_default_when_no_hint() {
        let policy = make_policy();
        let input = RoutingInput::new(TaskType::Unknown, "proj-c", "ws-3");

        let decision = policy.decide(&input);
        assert_eq!(decision.provider_id, "openai");
        assert_eq!(decision.model_id, "gpt-4o");
        assert_eq!(decision.selected_by, RouteSelectedBy::Default);
    }

    #[test]
    fn routing_workspace_key_isolation() {
        let policy = make_policy();
        let input_a = RoutingInput::new(TaskType::Chat, "proj-a", "ws-1");
        let input_b = RoutingInput::new(TaskType::Chat, "proj-b", "ws-2");

        let decision_a = policy.decide(&input_a);
        let decision_b = policy.decide(&input_b);

        assert_ne!(decision_a.workspace_key, decision_b.workspace_key);
        assert_eq!(decision_a.workspace_key, "proj-a::ws-1");
        assert_eq!(decision_b.workspace_key, "proj-b::ws-2");
    }

    #[test]
    fn routing_candidates_include_default_as_fallback() {
        let policy = make_policy();
        // CodeCompletion 会选 claude-3-haiku，不是 default(gpt-4o)
        let input = RoutingInput::new(TaskType::CodeCompletion, "proj-a", "ws-1");
        let decision = policy.decide(&input);

        // candidates[0] 是首选，candidates[1] 是 default 兜底
        assert_eq!(decision.candidates.len(), 2);
        assert_eq!(decision.candidates[0].model_id, "claude-3-haiku");
        assert_eq!(decision.candidates[1].model_id, "gpt-4o");
    }

    #[test]
    fn routing_into_fallback() {
        let policy = make_policy();
        let input = RoutingInput::new(TaskType::CodeGeneration, "proj-a", "ws-1");
        let decision = policy.decide(&input);

        let fallback = decision.into_fallback(
            "provider_error: 503",
            "openai".to_string(),
            "gpt-4o".to_string(),
            None,
        );
        assert!(fallback.is_fallback);
        assert_eq!(
            fallback.fallback_reason.as_deref(),
            Some("provider_error: 503")
        );
        assert_eq!(fallback.provider_id, "openai");
        assert_eq!(fallback.model_id, "gpt-4o");
    }
}
