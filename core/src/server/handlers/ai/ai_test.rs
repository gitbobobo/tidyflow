#[cfg(test)]
mod tests {
    use crate::ai::AiSession;
    use crate::server::handlers::ai::ai_state::AIState;

    #[test]
    fn test_ai_state_new() {
        let state = AIState::new();
        assert!(state.active_streams.is_empty());
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
}
