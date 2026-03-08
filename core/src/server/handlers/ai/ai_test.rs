#[cfg(test)]
mod tests {
    use crate::ai::AiSession;
    use crate::server::handlers::ai::ai_state::AIState;

    #[test]
    fn test_ai_state_new() {
        let state = AIState::new();
        assert!(state.active_streams.is_empty());
        assert!(state.stream_snapshots.is_empty());
        assert!(state.directory_last_used_ms.is_empty());
        assert!(state.directory_active_streams.is_empty());
        assert!(state.agents.is_empty());
    }

    #[test]
    fn test_ai_state_default() {
        let state = AIState::default();
        assert!(state.agents.is_empty());
    }

    #[test]
    fn test_ai_session_clone() {
        let session = AiSession {
            id: "test-session-123".to_string(),
            title: "Test Session".to_string(),
            updated_at: 1700000000000,
        };
        let cloned = session.clone();
        assert_eq!(cloned.id, "test-session-123");
        assert_eq!(cloned.title, "Test Session");
        assert_eq!(cloned.updated_at, 1700000000000);
    }

    #[test]
    fn test_session_subscribe_idempotent() {
        let mut state = AIState::new();
        let conn_id = "conn-1";
        let session_key = "opencode::/tmp/project::ses_abc123";

        state
            .session_subscriptions
            .entry(conn_id.to_string())
            .or_default()
            .insert(session_key.to_string());
        state
            .session_subscriptions
            .entry(conn_id.to_string())
            .or_default()
            .insert(session_key.to_string());

        let keys = state.session_subscriptions.get(conn_id).unwrap();
        assert_eq!(
            keys.len(),
            1,
            "重复 subscribe 同一 session_key 集合中只应有一条"
        );
    }

    #[test]
    fn test_session_subscribe_unsubscribe() {
        let mut state = AIState::new();
        let conn_id = "conn-2";
        let session_key = "opencode::/tmp/project::ses_abc456";

        state
            .session_subscriptions
            .entry(conn_id.to_string())
            .or_default()
            .insert(session_key.to_string());

        if let Some(keys) = state.session_subscriptions.get_mut(conn_id) {
            keys.remove(session_key);
            if keys.is_empty() {
                state.session_subscriptions.remove(conn_id);
            }
        }

        assert!(
            !state.session_subscriptions.contains_key(conn_id),
            "unsubscribe 后 conn_id 条目应被移除"
        );
    }

    #[test]
    fn test_session_cleanup_on_disconnect() {
        let mut state = AIState::new();
        let conn_id = "conn-3";

        state
            .session_subscriptions
            .entry(conn_id.to_string())
            .or_default()
            .insert("opencode::/tmp/proj::ses_aaa".to_string());
        state
            .session_subscriptions
            .entry(conn_id.to_string())
            .or_default()
            .insert("opencode::/tmp/proj::ses_bbb".to_string());

        state.session_subscriptions.remove(conn_id);

        assert!(
            !state.session_subscriptions.contains_key(conn_id),
            "remove(conn_id) 后该连接所有订阅应完全清除"
        );
    }

    /// 验证断连清理不会影响其他连接的订阅（连接级隔离语义）。
    #[test]
    fn test_session_cleanup_does_not_affect_other_connections() {
        let mut state = AIState::new();

        state
            .session_subscriptions
            .entry("conn-A".to_string())
            .or_default()
            .insert("ses-1".to_string());
        state
            .session_subscriptions
            .entry("conn-B".to_string())
            .or_default()
            .insert("ses-2".to_string());

        // 断开 conn-A
        state.session_subscriptions.remove("conn-A");

        assert!(
            !state.session_subscriptions.contains_key("conn-A"),
            "conn-A 的订阅应被清除"
        );
        assert!(
            state.session_subscriptions.contains_key("conn-B"),
            "conn-B 的订阅不应受 conn-A 断开影响"
        );
        assert!(
            state
                .session_subscriptions
                .get("conn-B")
                .unwrap()
                .contains("ses-2"),
            "conn-B 的 ses-2 订阅应保持不变"
        );
    }

    /// 验证一个连接订阅多个会话时，断连一次性全部回收。
    #[test]
    fn test_session_cleanup_multiple_sessions_per_connection() {
        let mut state = AIState::new();
        let conn_id = "conn-multi";

        state
            .session_subscriptions
            .entry(conn_id.to_string())
            .or_default()
            .insert("ses-1".to_string());
        state
            .session_subscriptions
            .entry(conn_id.to_string())
            .or_default()
            .insert("ses-2".to_string());
        state
            .session_subscriptions
            .entry(conn_id.to_string())
            .or_default()
            .insert("ses-3".to_string());

        assert_eq!(state.session_subscriptions.get(conn_id).unwrap().len(), 3);

        state.session_subscriptions.remove(conn_id);

        assert!(
            !state.session_subscriptions.contains_key(conn_id),
            "所有会话订阅应被一次性清除"
        );
    }

    /// 验证重复断连同一 conn_id 不会 panic 或产生副作用。
    #[test]
    fn test_double_cleanup_is_idempotent() {
        let mut state = AIState::new();
        let conn_id = "conn-double";

        state
            .session_subscriptions
            .entry(conn_id.to_string())
            .or_default()
            .insert("ses-x".to_string());

        state.session_subscriptions.remove(conn_id);
        // 第二次 remove 对不存在的 key 应为 no-op
        state.session_subscriptions.remove(conn_id);

        assert!(!state.session_subscriptions.contains_key(conn_id));
    }
}
