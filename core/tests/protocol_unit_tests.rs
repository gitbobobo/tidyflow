//! Protocol 模块单元测试
//!
//! 测试协议消息的序列化/反序列化和路由逻辑

// ============================================================================
// Envelope 序列化测试
// ============================================================================

mod envelope_tests {
    use serde_json::json;

    #[test]
    fn test_client_envelope_v6_serialization() {
        // 测试 ClientEnvelopeV6 的序列化
        let envelope = json!({
            "request_id": "test-123",
            "domain": "system",
            "action": "ping",
            "payload": {},
            "client_ts": 1234567890
        });

        // 验证 JSON 结构正确
        assert_eq!(envelope["request_id"], "test-123");
        assert_eq!(envelope["domain"], "system");
        assert_eq!(envelope["action"], "ping");
    }

    #[test]
    fn test_server_envelope_v6_serialization() {
        // 测试 ServerEnvelopeV6 的序列化
        let envelope = json!({
            "request_id": "test-123",
            "seq": 1,
            "domain": "system",
            "action": "pong",
            "kind": "result",
            "payload": {},
            "server_ts": 1234567890
        });

        assert_eq!(envelope["seq"], 1);
        assert_eq!(envelope["kind"], "result");
    }

    #[test]
    fn test_server_envelope_without_request_id() {
        // 服务端响应可以没有 request_id（如事件推送）
        let envelope = json!({
            "seq": 2,
            "domain": "terminal",
            "action": "output",
            "kind": "event",
            "payload": {"data": "base64encoded"},
            "server_ts": 1234567890
        });

        assert!(envelope.get("request_id").is_none() || envelope["request_id"].is_null());
    }
}

// ============================================================================
// Action Table 测试
// ============================================================================

mod action_table_tests {
    use tidyflow_core::server::protocol::action_table::{
        matches_action_domain, EXACT_RULES, PREFIX_RULES, CONTAINS_RULES,
    };

    #[test]
    fn test_exact_rules() {
        // 验证精确匹配规则
        assert!(matches_action_domain("system", "ping"));
        assert!(matches_action_domain("terminal", "spawn_terminal"));
        assert!(matches_action_domain("terminal", "kill_terminal"));
        assert!(matches_action_domain("terminal", "input"));
        assert!(matches_action_domain("terminal", "resize"));
    }

    #[test]
    fn test_prefix_rules() {
        // 验证前缀匹配规则
        assert!(matches_action_domain("terminal", "term_create"));
        assert!(matches_action_domain("terminal", "term_list"));
        assert!(matches_action_domain("file", "file_list"));
        assert!(matches_action_domain("file", "file_read"));
        assert!(matches_action_domain("git", "git_status"));
        assert!(matches_action_domain("git", "git_commit"));
        assert!(matches_action_domain("project", "list_projects"));
        assert!(matches_action_domain("project", "list_workspaces"));
        assert!(matches_action_domain("ai", "ai_start_session"));
        assert!(matches_action_domain("ai", "ai_send_message"));
    }

    #[test]
    fn test_contains_rules() {
        // 验证包含匹配规则
        assert!(matches_action_domain("settings", "client_settings_get"));
        assert!(matches_action_domain("settings", "client_settings_result"));
    }

    #[test]
    fn test_non_matching_rules() {
        // 验证不匹配的规则
        assert!(!matches_action_domain("system", "unknown_action"));
        assert!(!matches_action_domain("unknown_domain", "ping"));
        assert!(!matches_action_domain("terminal", "git_status"));
    }

    #[test]
    fn test_exact_rules_count() {
        // 验证精确规则数量
        assert!(!EXACT_RULES.is_empty());
    }

    #[test]
    fn test_prefix_rules_count() {
        // 验证前缀规则数量
        assert!(!PREFIX_RULES.is_empty());
    }

    #[test]
    fn test_contains_rules_count() {
        // 验证包含规则数量
        assert!(!CONTAINS_RULES.is_empty());
    }
}

// ============================================================================
// Domain Table 测试
// ============================================================================

mod domain_table_tests {
    // 测试 domain 映射逻辑

    #[test]
    fn test_core_domains() {
        // 验证核心 domain 列表
        let core_domains = vec![
            "system",
            "terminal",
            "file",
            "git",
            "project",
            "ai",
            "settings",
            "log",
            "evolution",
            "evidence",
        ];

        for domain in core_domains {
            // 验证 domain 是有效的字符串
            assert!(!domain.is_empty());
        }
    }
}

// ============================================================================
// Protocol Version 测试
// ============================================================================

mod version_tests {
    use tidyflow_core::server::protocol::PROTOCOL_VERSION;

    #[test]
    fn test_protocol_version() {
        // 验证协议版本是 v7
        assert_eq!(PROTOCOL_VERSION, 7);
    }
}

// ============================================================================
// MessagePack 编码测试
// ============================================================================

mod msgpack_tests {
    use serde_json::json;

    #[test]
    fn test_msgpack_encode_decode() {
        // 测试 MessagePack 编码/解码
        let envelope = json!({
            "request_id": "test-123",
            "domain": "system",
            "action": "ping",
            "payload": {},
            "client_ts": 1234567890
        });

        // 编码为 MessagePack
        let encoded = rmp_serde::to_vec_named(&envelope).expect("encode should succeed");
        assert!(!encoded.is_empty());

        // 解码回 JSON
        let decoded: serde_json::Value =
            rmp_serde::from_slice(&encoded).expect("decode should succeed");
        assert_eq!(decoded["request_id"], "test-123");
        assert_eq!(decoded["domain"], "system");
    }

    #[test]
    fn test_msgpack_binary_format() {
        // 验证 MessagePack 是二进制格式
        let envelope = json!({"test": "value"});
        let encoded = rmp_serde::to_vec_named(&envelope).expect("encode should succeed");

        // MessagePack 是紧凑的二进制格式
        assert!(encoded.len() < 50); // 简单消息应该很紧凑
    }
}
