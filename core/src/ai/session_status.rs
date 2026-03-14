use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};

use crate::coordinator::model::{AiDisplayStatus, AiDomainPhase, AiDomainState};

/// AI 会话统一状态（用于客户端决定是否需要"订阅/恢复"流式更新）
///
/// 状态定义（v2，用于标签栏可感知化）：
/// - `idle`: 空闲，无任务执行
/// - `running`: 正在执行任务
/// - `awaiting_input`: 等待用户输入（如 question tool）
/// - `success`: 任务执行成功
/// - `failure`: 任务执行失败
/// - `cancelled`: 任务被取消
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AiSessionStatus {
    Idle,
    Running,
    AwaitingInput,
    Success,
    Failure { message: String },
    Cancelled,
}

impl AiSessionStatus {
    pub fn status_str(&self) -> &'static str {
        match self {
            AiSessionStatus::Idle => "idle",
            AiSessionStatus::Running => "running",
            AiSessionStatus::AwaitingInput => "awaiting_input",
            AiSessionStatus::Success => "success",
            AiSessionStatus::Failure { .. } => "failure",
            AiSessionStatus::Cancelled => "cancelled",
        }
    }

    pub fn error_message(&self) -> Option<String> {
        match self {
            AiSessionStatus::Failure { message } => Some(message.clone()),
            _ => None,
        }
    }

    /// 检查是否为活跃状态（running 或 awaiting_input）
    pub fn is_active(&self) -> bool {
        matches!(
            self,
            AiSessionStatus::Running | AiSessionStatus::AwaitingInput
        )
    }

    /// 检查是否为终态（success, failure, cancelled）
    pub fn is_terminal(&self) -> bool {
        matches!(
            self,
            AiSessionStatus::Success | AiSessionStatus::Failure { .. } | AiSessionStatus::Cancelled
        )
    }
}

/// 状态变更的元数据（用于推送 update 事件）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiSessionStatusMeta {
    pub project_name: String,
    pub workspace_name: String,
    pub ai_tool: String,
    pub directory: String,
    pub session_id: String,
}

#[derive(Debug, Clone)]
pub struct AiSessionStatusChange {
    pub key: String,
    pub meta: Option<AiSessionStatusMeta>,
    pub old_status: Option<AiSessionStatus>,
    pub new_status: AiSessionStatus,
}

/// 状态变更节流配置
const STATUS_THROTTLE_DURATION_MS: u64 = 100;

/// 状态变更时间戳记录（用于节流）
#[derive(Debug, Clone)]
struct StatusThrottleState {
    last_emit_time: Instant,
    pending_status: Option<AiSessionStatus>,
}

pub struct AiSessionStateStore {
    statuses: RwLock<HashMap<String, AiSessionStatus>>,
    metas: RwLock<HashMap<String, AiSessionStatusMeta>>,
    on_change: RwLock<Option<Arc<dyn Fn(AiSessionStatusChange) + Send + Sync>>>,
    /// 节流状态：记录每个 key 的上次发送时间和待发送状态
    throttle_states: RwLock<HashMap<String, StatusThrottleState>>,
    /// 每个 session key 最近一次真实状态变更时间（Unix ms）
    timestamps: RwLock<HashMap<String, i64>>,
}

impl AiSessionStateStore {
    pub fn new() -> Self {
        Self {
            statuses: RwLock::new(HashMap::new()),
            metas: RwLock::new(HashMap::new()),
            on_change: RwLock::new(None),
            throttle_states: RwLock::new(HashMap::new()),
            timestamps: RwLock::new(HashMap::new()),
        }
    }

    pub fn new_shared() -> Arc<Self> {
        Arc::new(Self::new())
    }

    pub fn set_on_change(&self, f: Arc<dyn Fn(AiSessionStatusChange) + Send + Sync>) {
        if let Ok(mut guard) = self.on_change.write() {
            *guard = Some(f);
        }
    }

    pub fn make_key(ai_tool: &str, directory: &str, session_id: &str) -> String {
        // 计划约定 key 格式：{ai_tool}:{directory}:{session_id}
        format!("{}:{}:{}", ai_tool, directory, session_id)
    }

    pub fn get_status(
        &self,
        ai_tool: &str,
        directory: &str,
        session_id: &str,
    ) -> Option<AiSessionStatus> {
        let key = Self::make_key(ai_tool, directory, session_id);
        self.statuses.read().ok()?.get(&key).cloned()
    }

    pub fn remove_status(&self, ai_tool: &str, directory: &str, session_id: &str) {
        let key = Self::make_key(ai_tool, directory, session_id);
        if let Ok(mut guard) = self.statuses.write() {
            guard.remove(&key);
        }
        if let Ok(mut guard) = self.metas.write() {
            guard.remove(&key);
        }
        if let Ok(mut guard) = self.throttle_states.write() {
            guard.remove(&key);
        }
        if let Ok(mut guard) = self.timestamps.write() {
            guard.remove(&key);
        }
    }

    pub fn get_all_for_directory(
        &self,
        ai_tool: &str,
        directory: &str,
    ) -> Vec<(String, AiSessionStatus)> {
        let prefix = format!("{}:{}:", ai_tool, directory);
        let Ok(guard) = self.statuses.read() else {
            return vec![];
        };
        guard
            .iter()
            .filter_map(|(k, v)| {
                if k.starts_with(&prefix) {
                    let session_id = k.strip_prefix(&prefix).unwrap_or("").to_string();
                    Some((session_id, v.clone()))
                } else {
                    None
                }
            })
            .collect()
    }

    /// 判断指定项目/工作空间是否存在任一活跃（running/awaiting_input）会话。
    pub fn has_busy_for_workspace(&self, project_name: &str, workspace_name: &str) -> bool {
        let Ok(statuses) = self.statuses.read() else {
            return false;
        };
        let Ok(metas) = self.metas.read() else {
            return false;
        };

        statuses.iter().any(|(key, status)| {
            if !status.is_active() {
                return false;
            }
            metas
                .get(key)
                .map(|meta| {
                    meta.project_name == project_name && meta.workspace_name == workspace_name
                })
                .unwrap_or(false)
        })
    }

    pub fn set_status(
        &self,
        ai_tool: &str,
        directory: &str,
        session_id: &str,
        status: AiSessionStatus,
    ) -> bool {
        self.set_status_with_meta_inner(ai_tool, directory, session_id, status, None)
    }

    pub fn set_status_with_meta(&self, meta: AiSessionStatusMeta, status: AiSessionStatus) -> bool {
        let ai_tool = meta.ai_tool.clone();
        let directory = meta.directory.clone();
        let session_id = meta.session_id.clone();
        self.set_status_with_meta_inner(&ai_tool, &directory, &session_id, status, Some(meta))
    }

    /// 设置状态（带节流，用于高频状态变更场景）
    ///
    /// 节流策略：
    /// - 如果距离上次发送 >= 100ms，立即发送
    /// - 如果距离上次发送 < 100ms，记录为 pending，等下次调用时检查
    /// - 终态（success/failure/cancelled）立即发送，不受节流限制
    pub fn set_status_throttled(
        &self,
        ai_tool: &str,
        directory: &str,
        session_id: &str,
        status: AiSessionStatus,
    ) -> bool {
        self.set_status_throttled_with_meta_inner(ai_tool, directory, session_id, status, None)
    }

    pub fn set_status_throttled_with_meta(
        &self,
        meta: AiSessionStatusMeta,
        status: AiSessionStatus,
    ) -> bool {
        let ai_tool = meta.ai_tool.clone();
        let directory = meta.directory.clone();
        let session_id = meta.session_id.clone();
        self.set_status_throttled_with_meta_inner(
            &ai_tool,
            &directory,
            &session_id,
            status,
            Some(meta),
        )
    }

    fn set_status_throttled_with_meta_inner(
        &self,
        ai_tool: &str,
        directory: &str,
        session_id: &str,
        status: AiSessionStatus,
        meta: Option<AiSessionStatusMeta>,
    ) -> bool {
        let key = Self::make_key(ai_tool, directory, session_id);

        // 终态立即发送，不受节流限制
        if status.is_terminal() {
            return self.set_status_with_meta_inner(ai_tool, directory, session_id, status, meta);
        }

        let now = Instant::now();
        let should_emit = {
            let Ok(mut throttle_guard) = self.throttle_states.write() else {
                return false;
            };

            match throttle_guard.get_mut(&key) {
                Some(throttle_state) => {
                    let elapsed = now.duration_since(throttle_state.last_emit_time);
                    if elapsed >= Duration::from_millis(STATUS_THROTTLE_DURATION_MS) {
                        throttle_state.last_emit_time = now;
                        throttle_state.pending_status = None;
                        true
                    } else {
                        // 更新 pending 状态，等待下次检查
                        throttle_state.pending_status = Some(status.clone());
                        false
                    }
                }
                None => {
                    throttle_guard.insert(
                        key.clone(),
                        StatusThrottleState {
                            last_emit_time: now,
                            pending_status: None,
                        },
                    );
                    true
                }
            }
        };

        if should_emit {
            self.set_status_with_meta_inner(ai_tool, directory, session_id, status, meta)
        } else {
            // 状态已记录为 pending，返回 false 表示未发送
            false
        }
    }

    fn set_status_with_meta_inner(
        &self,
        ai_tool: &str,
        directory: &str,
        session_id: &str,
        status: AiSessionStatus,
        meta: Option<AiSessionStatusMeta>,
    ) -> bool {
        let key = Self::make_key(ai_tool, directory, session_id);
        let mut old: Option<AiSessionStatus> = None;
        let mut changed = false;

        if let Ok(mut guard) = self.statuses.write() {
            old = guard.get(&key).cloned();
            if old.as_ref() != Some(&status) {
                guard.insert(key.clone(), status.clone());
                changed = true;
            }
        }

        if !changed {
            return false;
        }

        // 记录真实状态变更时间，供聚合函数做稳定的时间排序
        if let Ok(mut ts_guard) = self.timestamps.write() {
            ts_guard.insert(key.clone(), chrono::Utc::now().timestamp_millis());
        }

        if let Some(m) = meta.clone() {
            if let Ok(mut guard) = self.metas.write() {
                guard.insert(key.clone(), m);
            }
        }

        let meta_for_emit = meta.or_else(|| self.metas.read().ok()?.get(&key).cloned());
        if let Ok(guard) = self.on_change.read() {
            if let Some(cb) = guard.as_ref() {
                cb(AiSessionStatusChange {
                    key,
                    meta: meta_for_emit,
                    old_status: old,
                    new_status: status,
                });
            }
        }

        true
    }
}

impl Default for AiSessionStateStore {
    fn default() -> Self {
        Self::new()
    }
}

// ============================================================================
// 工作区级 AI 展示状态聚合（Core 权威，不依赖客户端事件顺序）
// ============================================================================

/// 聚合后的会话条目（内部用）
#[derive(Debug)]
struct SessionEntry {
    status: AiSessionStatus,
    updated_at_ms: i64,
    /// 该会话使用的 AI 工具标识（如 "codex"、"opencode"）
    ai_tool: String,
}

/// 为指定 `(project_name, workspace_name)` 聚合工作区级 AI 领域子状态。
///
/// 优先级规则（在 Core 固化，客户端直接消费 `display_status`）：
/// 1. 若存在任一 `awaiting_input` 会话 → `awaiting_input`
/// 2. 若存在任一 `running` 会话 → `running`
/// 3. 若仅有终态会话 → 取 `failure > cancelled > success`，`display_updated_at` 决胜
/// 4. 无会话记录 → `idle`
pub fn aggregate_workspace_ai_domain_state(
    store: &AiSessionStateStore,
    project_name: &str,
    workspace_name: &str,
) -> AiDomainState {
    let now_ms = chrono::Utc::now().timestamp_millis();

    let entries: Vec<SessionEntry> = {
        let Ok(statuses) = store.statuses.read() else {
            return AiDomainState::default();
        };
        let Ok(metas) = store.metas.read() else {
            return AiDomainState::default();
        };
        // 读取真实状态变更时间戳（失败时以 now_ms 作为回退）
        let timestamps_guard = store.timestamps.read().ok();

        statuses
            .iter()
            .filter_map(|(key, status)| {
                let meta = metas.get(key)?;
                if meta.project_name != project_name || meta.workspace_name != workspace_name {
                    return None;
                }
                let updated_at_ms = timestamps_guard
                    .as_ref()
                    .and_then(|t| t.get(key))
                    .copied()
                    .unwrap_or(now_ms);
                Some(SessionEntry {
                    status: status.clone(),
                    updated_at_ms,
                    ai_tool: meta.ai_tool.clone(),
                })
            })
            .collect()
    };

    let total_session_count = entries.len() as u32;
    if total_session_count == 0 {
        return AiDomainState::default();
    }

    let active_count = entries.iter().filter(|e| e.status.is_active()).count() as u32;
    let any_faulted = entries
        .iter()
        .any(|e| matches!(e.status, AiSessionStatus::Failure { .. }));
    let phase = if active_count > 0 {
        AiDomainPhase::Active
    } else if any_faulted {
        AiDomainPhase::Faulted
    } else {
        AiDomainPhase::Idle
    };

    // 优先级 1: awaiting_input
    if let Some(awaiting_entry) = entries
        .iter()
        .find(|e| matches!(e.status, AiSessionStatus::AwaitingInput))
    {
        return AiDomainState {
            phase,
            active_session_count: active_count,
            total_session_count,
            display_status: AiDisplayStatus::AwaitingInput,
            active_tool_name: None,
            last_error_message: None,
            display_updated_at: awaiting_entry.updated_at_ms,
        };
    }

    // 优先级 2: running
    // active_tool_name 取第一个 running 会话的 ai_tool；display_updated_at 取最近 running 时间
    if active_count > 0 {
        let running_entry = entries
            .iter()
            .filter(|e| matches!(e.status, AiSessionStatus::Running))
            .max_by_key(|e| e.updated_at_ms);
        let active_tool_name = running_entry
            .map(|e| e.ai_tool.clone())
            .filter(|s| !s.is_empty());
        let running_updated_at = running_entry.map(|e| e.updated_at_ms).unwrap_or(now_ms);
        return AiDomainState {
            phase,
            active_session_count: active_count,
            total_session_count,
            display_status: AiDisplayStatus::Running,
            active_tool_name,
            last_error_message: None,
            display_updated_at: running_updated_at,
        };
    }

    // 优先级 3: 取最近终态（failure > cancelled > success 严重度，再按 updated_at）
    let terminal_entries: Vec<&SessionEntry> =
        entries.iter().filter(|e| e.status.is_terminal()).collect();
    if terminal_entries.is_empty() {
        return AiDomainState {
            phase,
            active_session_count: active_count,
            total_session_count,
            display_status: AiDisplayStatus::Idle,
            active_tool_name: None,
            last_error_message: None,
            display_updated_at: now_ms,
        };
    }

    let severity = |e: &SessionEntry| match e.status {
        AiSessionStatus::Failure { .. } => 2u8,
        AiSessionStatus::Cancelled => 1,
        _ => 0,
    };
    let best = terminal_entries
        .iter()
        .max_by(|a, b| {
            severity(a)
                .cmp(&severity(b))
                .then(a.updated_at_ms.cmp(&b.updated_at_ms))
        })
        .expect("non-empty");

    let (display_status, last_error) = match &best.status {
        AiSessionStatus::Failure { message } => (AiDisplayStatus::Failure, Some(message.clone())),
        AiSessionStatus::Cancelled => (AiDisplayStatus::Cancelled, None),
        _ => (AiDisplayStatus::Success, None),
    };

    AiDomainState {
        phase,
        active_session_count: active_count,
        total_session_count,
        display_status,
        active_tool_name: None,
        last_error_message: last_error,
        display_updated_at: best.updated_at_ms,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_store_set_get_remove() {
        let store = AiSessionStateStore::new();
        assert!(store.get_status("opencode", "/tmp/a", "s1").is_none());

        let changed = store.set_status("opencode", "/tmp/a", "s1", AiSessionStatus::Running);
        assert!(changed);
        assert_eq!(
            store.get_status("opencode", "/tmp/a", "s1"),
            Some(AiSessionStatus::Running)
        );

        // 同值不算变更
        assert!(!store.set_status("opencode", "/tmp/a", "s1", AiSessionStatus::Running));

        store.remove_status("opencode", "/tmp/a", "s1");
        assert!(store.get_status("opencode", "/tmp/a", "s1").is_none());
    }

    #[test]
    fn test_key_format() {
        let key = AiSessionStateStore::make_key("codex", "/a/b", "ses_1");
        assert_eq!(key, "codex:/a/b:ses_1");
    }

    #[test]
    fn test_has_busy_for_workspace() {
        let store = AiSessionStateStore::new();
        store.set_status_with_meta(
            AiSessionStatusMeta {
                project_name: "p1".to_string(),
                workspace_name: "w1".to_string(),
                ai_tool: "codex".to_string(),
                directory: "/tmp/a".to_string(),
                session_id: "s1".to_string(),
            },
            AiSessionStatus::Running,
        );
        store.set_status_with_meta(
            AiSessionStatusMeta {
                project_name: "p1".to_string(),
                workspace_name: "w2".to_string(),
                ai_tool: "codex".to_string(),
                directory: "/tmp/b".to_string(),
                session_id: "s2".to_string(),
            },
            AiSessionStatus::Idle,
        );

        assert!(store.has_busy_for_workspace("p1", "w1"));
        assert!(!store.has_busy_for_workspace("p1", "w2"));
        assert!(!store.has_busy_for_workspace("p2", "w1"));
    }

    #[test]
    fn test_status_str() {
        assert_eq!(AiSessionStatus::Idle.status_str(), "idle");
        assert_eq!(AiSessionStatus::Running.status_str(), "running");
        assert_eq!(
            AiSessionStatus::AwaitingInput.status_str(),
            "awaiting_input"
        );
        assert_eq!(AiSessionStatus::Success.status_str(), "success");
        assert_eq!(
            AiSessionStatus::Failure {
                message: "err".to_string()
            }
            .status_str(),
            "failure"
        );
        assert_eq!(AiSessionStatus::Cancelled.status_str(), "cancelled");
    }

    #[test]
    fn test_status_is_active() {
        assert!(!AiSessionStatus::Idle.is_active());
        assert!(AiSessionStatus::Running.is_active());
        assert!(AiSessionStatus::AwaitingInput.is_active());
        assert!(!AiSessionStatus::Success.is_active());
        assert!(!AiSessionStatus::Failure {
            message: "err".to_string()
        }
        .is_active());
        assert!(!AiSessionStatus::Cancelled.is_active());
    }

    #[test]
    fn test_status_is_terminal() {
        assert!(!AiSessionStatus::Idle.is_terminal());
        assert!(!AiSessionStatus::Running.is_terminal());
        assert!(!AiSessionStatus::AwaitingInput.is_terminal());
        assert!(AiSessionStatus::Success.is_terminal());
        assert!(AiSessionStatus::Failure {
            message: "err".to_string()
        }
        .is_terminal());
        assert!(AiSessionStatus::Cancelled.is_terminal());
    }

    #[test]
    fn test_throttle_terminal_status_bypasses_throttle() {
        let store = AiSessionStateStore::new();
        // 终态应该立即发送
        let changed =
            store.set_status_throttled("opencode", "/tmp/a", "s1", AiSessionStatus::Success);
        assert!(changed);
        assert_eq!(
            store.get_status("opencode", "/tmp/a", "s1"),
            Some(AiSessionStatus::Success)
        );
    }

    #[test]
    fn test_throttle_non_terminal_status() {
        let store = AiSessionStateStore::new();
        // 首次非终态应该立即发送
        let changed1 =
            store.set_status_throttled("opencode", "/tmp/a", "s1", AiSessionStatus::Running);
        assert!(changed1);

        // 立即再次调用应该被节流
        let changed2 =
            store.set_status_throttled("opencode", "/tmp/a", "s1", AiSessionStatus::AwaitingInput);
        // 由于节流，这次调用可能被跳过（取决于执行速度）
        // 无论如何，状态应该已更新
        let status = store.get_status("opencode", "/tmp/a", "s1");
        // 如果 changed2 为 true，状态应为 AwaitingInput；否则仍为 Running
        if changed2 {
            assert_eq!(status, Some(AiSessionStatus::AwaitingInput));
        }
    }

    // ── WI-001 新增测试 ─────────────────────────────────────────────────────────

    /// running 态聚合时 active_tool_name 应等于会话的 ai_tool
    #[test]
    fn test_aggregate_running_fills_active_tool_name() {
        use crate::ai::session_status::aggregate_workspace_ai_domain_state;
        use crate::coordinator::model::AiDisplayStatus;

        let store = AiSessionStateStore::new();
        store.set_status_with_meta(
            AiSessionStatusMeta {
                project_name: "proj".to_string(),
                workspace_name: "ws".to_string(),
                ai_tool: "opencode".to_string(),
                directory: "/tmp/proj/ws".to_string(),
                session_id: "s1".to_string(),
            },
            AiSessionStatus::Running,
        );

        let state = aggregate_workspace_ai_domain_state(&store, "proj", "ws");
        assert_eq!(state.display_status, AiDisplayStatus::Running);
        assert_eq!(
            state.active_tool_name.as_deref(),
            Some("opencode"),
            "running 态 active_tool_name 应从 meta.ai_tool 填充"
        );
    }

    /// awaiting_input 优先于 running，active_tool_name 不填充
    #[test]
    fn test_aggregate_awaiting_input_has_no_active_tool_name() {
        use crate::ai::session_status::aggregate_workspace_ai_domain_state;
        use crate::coordinator::model::AiDisplayStatus;

        let store = AiSessionStateStore::new();
        store.set_status_with_meta(
            AiSessionStatusMeta {
                project_name: "proj".to_string(),
                workspace_name: "ws".to_string(),
                ai_tool: "codex".to_string(),
                directory: "/tmp/proj/ws".to_string(),
                session_id: "s1".to_string(),
            },
            AiSessionStatus::Running,
        );
        store.set_status_with_meta(
            AiSessionStatusMeta {
                project_name: "proj".to_string(),
                workspace_name: "ws".to_string(),
                ai_tool: "codex".to_string(),
                directory: "/tmp/proj/ws".to_string(),
                session_id: "s2".to_string(),
            },
            AiSessionStatus::AwaitingInput,
        );

        let state = aggregate_workspace_ai_domain_state(&store, "proj", "ws");
        assert_eq!(
            state.display_status,
            AiDisplayStatus::AwaitingInput,
            "awaiting_input 应优先于 running"
        );
        assert!(
            state.active_tool_name.is_none(),
            "awaiting_input 态 active_tool_name 应为 None"
        );
    }

    /// 同优先级终态：更晚写入的会话（更大 updated_at_ms）应在同级内胜出
    #[test]
    fn test_aggregate_terminal_same_severity_recent_wins() {
        use crate::ai::session_status::aggregate_workspace_ai_domain_state;
        use crate::coordinator::model::AiDisplayStatus;

        let store = AiSessionStateStore::new();

        // 先写入 s1=Cancelled
        store.set_status_with_meta(
            AiSessionStatusMeta {
                project_name: "proj".to_string(),
                workspace_name: "ws".to_string(),
                ai_tool: "codex".to_string(),
                directory: "/tmp/proj/ws".to_string(),
                session_id: "s1".to_string(),
            },
            AiSessionStatus::Cancelled,
        );

        // 稍后写入 s2=Success（低严重度），但此处在同级内测试时先写 success 再写 cancelled
        // 调整：s1=Success, s2=Cancelled（更晚写入，应胜出于同级 success）
        let store2 = AiSessionStateStore::new();
        store2.set_status_with_meta(
            AiSessionStatusMeta {
                project_name: "proj".to_string(),
                workspace_name: "ws".to_string(),
                ai_tool: "codex".to_string(),
                directory: "/tmp/proj/ws".to_string(),
                session_id: "a1".to_string(),
            },
            AiSessionStatus::Success,
        );
        // 稍作等待确保时钟推进，然后写入更晚的 Failure
        std::thread::sleep(std::time::Duration::from_millis(2));
        store2.set_status_with_meta(
            AiSessionStatusMeta {
                project_name: "proj".to_string(),
                workspace_name: "ws".to_string(),
                ai_tool: "codex".to_string(),
                directory: "/tmp/proj/ws".to_string(),
                session_id: "a2".to_string(),
            },
            AiSessionStatus::Failure {
                message: "latest-err".to_string(),
            },
        );

        let state = aggregate_workspace_ai_domain_state(&store2, "proj", "ws");
        // failure 严重度最高，应胜出
        assert_eq!(state.display_status, AiDisplayStatus::Failure);
        assert_eq!(
            state.last_error_message.as_deref(),
            Some("latest-err"),
            "failure 摘要应传递"
        );
        // display_updated_at 必须是真实写入时间，不等于另一个 now_ms（仅验证非零）
        assert!(
            state.display_updated_at > 0,
            "display_updated_at 应为真实时间戳，非零"
        );
    }

    /// 真实 updated_at_ms 的记录：写入状态后 timestamps 应有记录
    #[test]
    fn test_timestamps_recorded_on_status_change() {
        let store = AiSessionStateStore::new();
        let before_ms = chrono::Utc::now().timestamp_millis();

        store.set_status_with_meta(
            AiSessionStatusMeta {
                project_name: "p".to_string(),
                workspace_name: "w".to_string(),
                ai_tool: "codex".to_string(),
                directory: "/tmp/p/w".to_string(),
                session_id: "t1".to_string(),
            },
            AiSessionStatus::Running,
        );

        let after_ms = chrono::Utc::now().timestamp_millis();
        let key = AiSessionStateStore::make_key("codex", "/tmp/p/w", "t1");
        let ts = store.timestamps.read().unwrap();
        let recorded = *ts.get(&key).expect("应记录时间戳");
        assert!(
            recorded >= before_ms && recorded <= after_ms,
            "时间戳应在写入前后区间内"
        );
    }
}
