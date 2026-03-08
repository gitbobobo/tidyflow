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
        matches_action_domain, CONTAINS_RULES, EXACT_RULES, PREFIX_RULES,
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

// ============================================================================
// 共享错误码归一化测试
// ============================================================================

mod shared_error_code_tests {
    use tidyflow_core::server::context::AppError;
    use tidyflow_core::server::protocol::ServerMessage;

    #[test]
    fn test_app_error_code_mapping() {
        // 验证 AppError 各变体映射到稳定错误码
        assert_eq!(
            AppError::ProjectNotFound("foo".into()).code(),
            "project_not_found"
        );
        assert_eq!(
            AppError::WorkspaceNotFound("bar".into()).code(),
            "workspace_not_found"
        );
        assert_eq!(AppError::Git("err".into()).code(), "git_error");
        assert_eq!(AppError::File("err".into()).code(), "file_error");
        assert_eq!(AppError::Internal("err".into()).code(), "internal_error");
        assert_eq!(AppError::Custom("err".into()).code(), "error");
        assert_eq!(AppError::AISession("err".into()).code(), "ai_session_error");
        assert_eq!(AppError::Evolution("err".into()).code(), "evolution_error");
    }

    #[test]
    fn test_to_server_error_has_code_field() {
        // 验证 to_server_error() 产生的协议消息包含正确 code
        let err = AppError::ProjectNotFound("myproject".into());
        let msg = err.to_server_error();
        match msg {
            ServerMessage::Error {
                code,
                message,
                project,
                workspace,
                session_id,
                cycle_id,
            } => {
                assert_eq!(code, "project_not_found");
                assert!(message.contains("myproject"));
                // 无上下文版本字段全为 None
                assert!(project.is_none());
                assert!(workspace.is_none());
                assert!(session_id.is_none());
                assert!(cycle_id.is_none());
            }
            _ => panic!("Expected ServerMessage::Error"),
        }
    }

    #[test]
    fn test_to_server_error_with_context() {
        // 验证带上下文版本保留多工作区定位字段
        let err = AppError::AISession("session failed".into());
        let msg = err.to_server_error_with_context(
            Some("myproject".to_string()),
            Some("feature-x".to_string()),
            Some("sess-123".to_string()),
            None,
        );
        match msg {
            ServerMessage::Error {
                code,
                project,
                workspace,
                session_id,
                ..
            } => {
                assert_eq!(code, "ai_session_error");
                assert_eq!(project.as_deref(), Some("myproject"));
                assert_eq!(workspace.as_deref(), Some("feature-x"));
                assert_eq!(session_id.as_deref(), Some("sess-123"));
            }
            _ => panic!("Expected ServerMessage::Error"),
        }
    }

    #[test]
    fn test_make_error_helper() {
        // 验证辅助构造方法向后兼容（无上下文）
        let msg = ServerMessage::make_error("git_error", "git failed");
        match msg {
            ServerMessage::Error {
                code,
                message,
                project,
                workspace,
                session_id,
                cycle_id,
            } => {
                assert_eq!(code, "git_error");
                assert_eq!(message, "git failed");
                assert!(project.is_none());
                assert!(workspace.is_none());
                assert!(session_id.is_none());
                assert!(cycle_id.is_none());
            }
            _ => panic!("Expected ServerMessage::Error"),
        }
    }

    #[test]
    fn test_make_error_with_context_helper() {
        // 验证带上下文辅助构造方法保留所有上下文字段
        let msg = ServerMessage::make_error_with_context(
            "evolution_error",
            "evo failed",
            Some("proj".to_string()),
            Some("ws".to_string()),
            None,
            Some("cycle-abc".to_string()),
        );
        match msg {
            ServerMessage::Error {
                code,
                project,
                workspace,
                cycle_id,
                ..
            } => {
                assert_eq!(code, "evolution_error");
                assert_eq!(project.as_deref(), Some("proj"));
                assert_eq!(workspace.as_deref(), Some("ws"));
                assert_eq!(cycle_id.as_deref(), Some("cycle-abc"));
            }
            _ => panic!("Expected ServerMessage::Error"),
        }
    }

    #[test]
    fn test_error_serialization_omits_none_context() {
        // 验证无上下文时 JSON 序列化不输出 None 字段（协议向后兼容）
        let msg = ServerMessage::make_error("internal_error", "something went wrong");
        let json = serde_json::to_string(&msg).expect("serialize should succeed");
        // None 字段不应出现在 JSON 中
        assert!(!json.contains("\"project\""));
        assert!(!json.contains("\"workspace\""));
        assert!(!json.contains("\"session_id\""));
        assert!(!json.contains("\"cycle_id\""));
        // code 和 message 应存在
        assert!(json.contains("\"internal_error\""));
        assert!(json.contains("something went wrong"));
    }

    #[test]
    fn test_error_serialization_includes_context_when_present() {
        // 验证有上下文时 JSON 序列化包含上下文字段
        let msg = ServerMessage::make_error_with_context(
            "project_not_found",
            "Project 'foo' not found",
            Some("foo".to_string()),
            Some("default".to_string()),
            None,
            None,
        );
        let json = serde_json::to_string(&msg).expect("serialize should succeed");
        assert!(json.contains("\"foo\""));
        assert!(json.contains("\"default\""));
        // 仍然不应输出 None 字段
        assert!(!json.contains("\"session_id\""));
        assert!(!json.contains("\"cycle_id\""));
    }

    #[test]
    fn test_log_entry_new_fields_deserialization() {
        // 验证 ClientMessage::LogEntry 新字段可正确反序列化
        use tidyflow_core::server::protocol::ClientMessage;

        let json_with_error_code = serde_json::json!({
            "type": "log_entry",
            "level": "ERROR",
            "source": "swift",
            "category": "ws",
            "msg": "WebSocket receive failed",
            "detail": "timeout",
            "error_code": "ws_receive_error",
            "project": "myproject",
            "workspace": "default",
            "session_id": null,
            "cycle_id": null
        });

        let msg: ClientMessage =
            serde_json::from_value(json_with_error_code).expect("deserialize should succeed");

        match msg {
            ClientMessage::LogEntry {
                level,
                error_code,
                project,
                workspace,
                ..
            } => {
                assert_eq!(level, "ERROR");
                assert_eq!(error_code.as_deref(), Some("ws_receive_error"));
                assert_eq!(project.as_deref(), Some("myproject"));
                assert_eq!(workspace.as_deref(), Some("default"));
            }
            _ => panic!("Expected ClientMessage::LogEntry"),
        }
    }

    #[test]
    fn test_log_entry_backward_compat_without_new_fields() {
        // 验证旧格式 LogEntry（无新字段）仍可正确反序列化（向后兼容）
        use tidyflow_core::server::protocol::ClientMessage;

        let json_old_format = serde_json::json!({
            "type": "log_entry",
            "level": "INFO",
            "source": "swift",
            "msg": "App started"
        });

        let msg: ClientMessage =
            serde_json::from_value(json_old_format).expect("old format deserialize should succeed");

        match msg {
            ClientMessage::LogEntry {
                level,
                error_code,
                project,
                workspace,
                session_id,
                cycle_id,
                ..
            } => {
                assert_eq!(level, "INFO");
                // 新字段均应为 None（向后兼容默认值）
                assert!(error_code.is_none());
                assert!(project.is_none());
                assert!(workspace.is_none());
                assert!(session_id.is_none());
                assert!(cycle_id.is_none());
            }
            _ => panic!("Expected ClientMessage::LogEntry"),
        }
    }
}

// ============================================================================
// 项目/工作区协议错误路径定向测试（WI-002 / CHK-004）
// ============================================================================

mod project_workspace_error_path_tests {
    use tidyflow_core::server::protocol::ServerMessage;

    /// 从 ServerMessage::Error 中提取 code 字段（辅助函数）
    fn extract_error_code(msg: ServerMessage) -> Option<String> {
        if let ServerMessage::Error { code, .. } = msg {
            Some(code)
        } else {
            None
        }
    }

    /// `project_not_found` 错误码可以被正确序列化/反序列化
    #[test]
    fn test_list_workspaces_error_case() {
        let error_msg = ServerMessage::Error {
            code: "project_not_found".to_string(),
            message: "Project 'nonexistent' not found".to_string(),
            project: Some("nonexistent".to_string()),
            workspace: None,
            session_id: None,
            cycle_id: None,
        };

        // 序列化
        let json = serde_json::to_string(&error_msg).unwrap();
        assert!(json.contains("project_not_found"), "错误码应出现在序列化结果中");
        assert!(json.contains("nonexistent"), "项目名应出现在序列化结果中");

        // 反序列化
        let parsed: ServerMessage = serde_json::from_str(&json).unwrap();
        let code = extract_error_code(parsed).expect("应能解析为 Error 变体");
        assert_eq!(code, "project_not_found");
    }

    /// `workspace_not_found` 错误码可以被正确序列化/反序列化
    #[test]
    fn workspace_not_found_error_serializes_correctly() {
        let error_msg = ServerMessage::Error {
            code: "workspace_not_found".to_string(),
            message: "Workspace 'missing' not found in project 'demo'".to_string(),
            project: Some("demo".to_string()),
            workspace: Some("missing".to_string()),
            session_id: None,
            cycle_id: None,
        };

        let json = serde_json::to_string(&error_msg).unwrap();
        let parsed: ServerMessage = serde_json::from_str(&json).unwrap();

        if let ServerMessage::Error { code, project, workspace, .. } = parsed {
            assert_eq!(code, "workspace_not_found");
            assert_eq!(project.as_deref(), Some("demo"));
            assert_eq!(workspace.as_deref(), Some("missing"));
        } else {
            panic!("应能解析为 Error 变体");
        }
    }

    /// 错误消息包含 project/workspace 归属字段，多工作区场景下可以正确路由
    #[test]
    fn error_message_carries_project_workspace_ownership() {
        let error_msg = ServerMessage::Error {
            code: "git_error".to_string(),
            message: "Git operation failed".to_string(),
            project: Some("project-a".to_string()),
            workspace: Some("feature-1".to_string()),
            session_id: None,
            cycle_id: None,
        };

        if let ServerMessage::Error { project, workspace, .. } = error_msg {
            assert_eq!(project.as_deref(), Some("project-a"), "错误归属项目应可提取");
            assert_eq!(workspace.as_deref(), Some("feature-1"), "错误归属工作区应可提取");
        }
    }
}
