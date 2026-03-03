use std::collections::HashMap;
use std::sync::{Arc, RwLock};

/// AI 会话统一状态（用于客户端决定是否需要“订阅/恢复”流式更新）
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AiSessionStatus {
    Idle,
    Busy,
    Error { message: String },
}

impl AiSessionStatus {
    pub fn status_str(&self) -> &'static str {
        match self {
            AiSessionStatus::Idle => "idle",
            AiSessionStatus::Busy => "busy",
            AiSessionStatus::Error { .. } => "error",
        }
    }

    pub fn error_message(&self) -> Option<String> {
        match self {
            AiSessionStatus::Error { message } => Some(message.clone()),
            _ => None,
        }
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

pub struct AiSessionStateStore {
    statuses: RwLock<HashMap<String, AiSessionStatus>>,
    metas: RwLock<HashMap<String, AiSessionStatusMeta>>,
    on_change: RwLock<Option<Arc<dyn Fn(AiSessionStatusChange) + Send + Sync>>>,
}

impl AiSessionStateStore {
    pub fn new() -> Self {
        Self {
            statuses: RwLock::new(HashMap::new()),
            metas: RwLock::new(HashMap::new()),
            on_change: RwLock::new(None),
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

    /// 判断指定项目/工作空间是否存在任一 busy 会话。
    pub fn has_busy_for_workspace(&self, project_name: &str, workspace_name: &str) -> bool {
        let Ok(statuses) = self.statuses.read() else {
            return false;
        };
        let Ok(metas) = self.metas.read() else {
            return false;
        };

        statuses.iter().any(|(key, status)| {
            if status != &AiSessionStatus::Busy {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_store_set_get_remove() {
        let store = AiSessionStateStore::new();
        assert!(store.get_status("opencode", "/tmp/a", "s1").is_none());

        let changed = store.set_status("opencode", "/tmp/a", "s1", AiSessionStatus::Busy);
        assert!(changed);
        assert_eq!(
            store.get_status("opencode", "/tmp/a", "s1"),
            Some(AiSessionStatus::Busy)
        );

        // 同值不算变更
        assert!(!store.set_status("opencode", "/tmp/a", "s1", AiSessionStatus::Busy));

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
            AiSessionStatus::Busy,
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
}
