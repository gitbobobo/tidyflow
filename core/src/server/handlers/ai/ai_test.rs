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
        assert!(state.agent.is_none());
    }

    #[test]
    fn test_ai_state_default() {
        let state = AIState::default();
        assert!(state.agent.is_none());
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
}
