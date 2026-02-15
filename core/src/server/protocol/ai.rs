//! AI 聊天协议类型
//!
//! 定义 OpenCode AI 聊天功能的请求与响应消息类型

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// AI 会话信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionInfo {
    /// 会话 ID
    pub id: String,
    /// 会话标题
    pub title: String,
    /// 最后更新时间戳（毫秒）
    pub updated_at: i64,
}

/// AI 相关的客户端消息
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum AIRequest {
    /// 开始新的 AI 聊天会话
    #[serde(rename = "ai_chat_start")]
    AIChatStart {
        /// 可选项目名，用于关联项目上下文
        #[serde(skip_serializing_if = "Option::is_none")]
        project_name: Option<String>,
        /// 可选会话标题
        #[serde(skip_serializing_if = "Option::is_none")]
        title: Option<String>,
    },
    /// 发送聊天消息
    #[serde(rename = "ai_chat_send")]
    AIChatSend {
        /// 会话 ID
        session_id: String,
        /// 消息内容
        message: String,
        /// 可选文件引用列表
        #[serde(skip_serializing_if = "Option::is_none")]
        file_refs: Option<Vec<String>>,
    },
    /// 终止正在进行的 AI 聊天
    #[serde(rename = "ai_chat_abort")]
    AIChatAbort {
        /// 会话 ID
        session_id: String,
    },
    /// 获取 AI 会话列表
    #[serde(rename = "ai_session_list")]
    AISessionList {
        /// 可选项目名，用于过滤特定项目的会话
        #[serde(skip_serializing_if = "Option::is_none")]
        project_name: Option<String>,
    },
    /// 删除 AI 会话
    #[serde(rename = "ai_session_delete")]
    AISessionDelete {
        /// 会话 ID
        session_id: String,
    },
}

/// AI 相关的服务端消息
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum AIResponse {
    /// AI 聊天文本响应（流式输出）
    #[serde(rename = "ai_chat_text")]
    AIChatText {
        /// 会话 ID
        session_id: String,
        /// 累积文本内容
        text: String,
        /// 本次增量文本（用于流式更新）
        #[serde(skip_serializing_if = "Option::is_none")]
        delta: Option<String>,
        /// 是否为最终响应
        done: bool,
    },
    /// AI 思考过程响应（流式输出，可折叠显示）
    #[serde(rename = "ai_chat_thinking")]
    AIChatThinking {
        /// 会话 ID
        session_id: String,
        /// 累积思考过程文本
        text: String,
        /// 本次增量文本（用于流式更新）
        #[serde(skip_serializing_if = "Option::is_none")]
        delta: Option<String>,
        /// 是否为最终响应
        done: bool,
    },
    /// AI 工具调用响应
    #[serde(rename = "ai_chat_tool")]
    AIChatTool {
        /// 会话 ID
        session_id: String,
        /// 工具名称
        tool: String,
        /// 工具输入参数（JSON）
        input: Value,
        /// 工具输出结果（JSON）
        #[serde(skip_serializing_if = "Option::is_none")]
        output: Option<Value>,
    },
    /// AI 聊天错误响应
    #[serde(rename = "ai_chat_error")]
    AIChatError {
        /// 会话 ID
        session_id: String,
        /// 错误信息
        error: String,
    },
    /// AI 会话已开始（响应 AIChatStart）
    #[serde(rename = "ai_session_started")]
    AISessionStarted {
        /// 会话 ID
        session_id: String,
        /// 会话标题
        title: String,
    },
    /// AI 会话列表响应
    #[serde(rename = "ai_session_list")]
    AISessionList {
        /// 会话信息列表
        sessions: Vec<SessionInfo>,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    // ============================================================================
    // AIRequest 序列化/反序列化测试
    // ============================================================================

    #[test]
    fn test_ai_chat_start_serialization() {
        // 带所有字段
        let req = AIRequest::AIChatStart {
            project_name: Some("my-project".to_string()),
            title: Some("Feature Discussion".to_string()),
        };
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("\"type\":\"ai_chat_start\""));
        assert!(json.contains("\"project_name\":\"my-project\""));
        assert!(json.contains("\"title\":\"Feature Discussion\""));
        assert!(json.contains("\"project_name\":\"my-project\""));
        assert!(json.contains("\"title\":\"Feature Discussion\""));

        // 反序列化
        let parsed: AIRequest = serde_json::from_str(&json).unwrap();
        match parsed {
            AIRequest::AIChatStart {
                project_name,
                title,
            } => {
                assert_eq!(project_name, Some("my-project".to_string()));
                assert_eq!(title, Some("Feature Discussion".to_string()));
            }
            _ => panic!("Expected AIChatStart"),
        }
    }

    #[test]
    fn test_ai_chat_start_minimal() {
        // 无可选字段
        let req = AIRequest::AIChatStart {
            project_name: None,
            title: None,
        };
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("\"type\":\"ai_chat_start\""));

        let parsed: AIRequest = serde_json::from_str(&json).unwrap();
        match parsed {
            AIRequest::AIChatStart {
                project_name,
                title,
            } => {
                assert_eq!(project_name, None);
                assert_eq!(title, None);
            }
            _ => panic!("Expected AIChatStart"),
        }
    }

    #[test]
    fn test_ai_chat_send_serialization() {
        let req = AIRequest::AIChatSend {
            session_id: "session-123".to_string(),
            message: "Hello, help me with this code".to_string(),
            file_refs: Some(vec!["src/main.rs".to_string(), "src/lib.rs".to_string()]),
        };
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("\"type\":\"ai_chat_send\""));
        assert!(json.contains("\"session_id\":\"session-123\""));
        assert!(json.contains("\"message\":\"Hello, help me with this code\""));
        assert!(json.contains("\"file_refs\""));

        let parsed: AIRequest = serde_json::from_str(&json).unwrap();
        match parsed {
            AIRequest::AIChatSend {
                session_id,
                message,
                file_refs,
            } => {
                assert_eq!(session_id, "session-123");
                assert_eq!(message, "Hello, help me with this code");
                assert_eq!(file_refs.unwrap().len(), 2);
            }
            _ => panic!("Expected AIChatSend"),
        }
    }

    #[test]
    fn test_ai_chat_send_without_file_refs() {
        let req = AIRequest::AIChatSend {
            session_id: "session-456".to_string(),
            message: "Just a message".to_string(),
            file_refs: None,
        };
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("\"type\":\"ai_chat_send\""));
        assert!(!json.contains("\"file_refs\""));

        let parsed: AIRequest = serde_json::from_str(&json).unwrap();
        match parsed {
            AIRequest::AIChatSend {
                session_id,
                message,
                file_refs,
            } => {
                assert_eq!(session_id, "session-456");
                assert_eq!(message, "Just a message");
                assert_eq!(file_refs, None);
            }
            _ => panic!("Expected AIChatSend"),
        }
    }

    #[test]
    fn test_ai_chat_abort_serialization() {
        let req = AIRequest::AIChatAbort {
            session_id: "session-789".to_string(),
        };
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("\"type\":\"ai_chat_abort\""));
        assert!(json.contains("\"session_id\":\"session-789\""));

        let parsed: AIRequest = serde_json::from_str(&json).unwrap();
        match parsed {
            AIRequest::AIChatAbort { session_id } => {
                assert_eq!(session_id, "session-789");
            }
            _ => panic!("Expected AIChatAbort"),
        }
    }

    #[test]
    fn test_ai_session_list_serialization() {
        // 带 project_name
        let req = AIRequest::AISessionList {
            project_name: Some("test-project".to_string()),
        };
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("\"type\":\"ai_session_list\""));
        assert!(json.contains("\"project_name\":\"test-project\""));

        let parsed: AIRequest = serde_json::from_str(&json).unwrap();
        match parsed {
            AIRequest::AISessionList { project_name } => {
                assert_eq!(project_name, Some("test-project".to_string()));
            }
            _ => panic!("Expected AISessionList"),
        }

        // 不带 project_name
        let req_no_project = AIRequest::AISessionList { project_name: None };
        let json_no_project = serde_json::to_string(&req_no_project).unwrap();
        assert!(json_no_project.contains("\"type\":\"ai_session_list\""));
        assert!(!json_no_project.contains("\"project_name\""));
    }

    #[test]
    fn test_ai_session_delete_serialization() {
        let req = AIRequest::AISessionDelete {
            session_id: "delete-me-123".to_string(),
        };
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("\"type\":\"ai_session_delete\""));
        assert!(json.contains("\"session_id\":\"delete-me-123\""));

        let parsed: AIRequest = serde_json::from_str(&json).unwrap();
        match parsed {
            AIRequest::AISessionDelete { session_id } => {
                assert_eq!(session_id, "delete-me-123");
            }
            _ => panic!("Expected AISessionDelete"),
        }
    }

    // ============================================================================
    // AIResponse 序列化/反序列化测试
    // ============================================================================

    #[test]
    fn test_ai_chat_text_serialization() {
        let resp = AIResponse::AIChatText {
            session_id: "session-abc".to_string(),
            text: "Hello! How can I help you today?".to_string(),
            delta: Some("Hello!".to_string()),
            done: false,
        };
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains("\"type\":\"ai_chat_text\""));
        assert!(json.contains("\"session_id\":\"session-abc\""));
        assert!(json.contains("\"text\":\"Hello! How can I help you today?\""));
        assert!(json.contains("\"delta\":\"Hello!\""));
        assert!(json.contains("\"done\":false"));

        let parsed: AIResponse = serde_json::from_str(&json).unwrap();
        match parsed {
            AIResponse::AIChatText {
                session_id,
                text,
                delta,
                done,
            } => {
                assert_eq!(session_id, "session-abc");
                assert_eq!(text, "Hello! How can I help you today?");
                assert_eq!(delta, Some("Hello!".to_string()));
                assert_eq!(done, false);
            }
            _ => panic!("Expected AIChatText"),
        }
    }

    #[test]
    fn test_ai_chat_text_done() {
        let resp = AIResponse::AIChatText {
            session_id: "session-done".to_string(),
            text: "Complete response".to_string(),
            delta: None,
            done: true,
        };
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains("\"done\":true"));
        assert!(!json.contains("\"delta\""));

        let parsed: AIResponse = serde_json::from_str(&json).unwrap();
        match parsed {
            AIResponse::AIChatText { done, delta, .. } => {
                assert_eq!(done, true);
                assert_eq!(delta, None);
            }
            _ => panic!("Expected AIChatText"),
        }
    }

    #[test]
    fn test_ai_chat_thinking_serialization() {
        let resp = AIResponse::AIChatThinking {
            session_id: "session-think".to_string(),
            text: "thinking...".to_string(),
            delta: Some("thinking...".to_string()),
            done: false,
        };
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains("\"type\":\"ai_chat_thinking\""));
        assert!(json.contains("\"session_id\":\"session-think\""));
        assert!(json.contains("\"done\":false"));

        let parsed: AIResponse = serde_json::from_str(&json).unwrap();
        match parsed {
            AIResponse::AIChatThinking {
                session_id,
                text,
                delta,
                done,
            } => {
                assert_eq!(session_id, "session-think");
                assert_eq!(text, "thinking...");
                assert_eq!(delta, Some("thinking...".to_string()));
                assert_eq!(done, false);
            }
            _ => panic!("Expected AIChatThinking"),
        }
    }

    #[test]
    fn test_ai_chat_tool_serialization() {
        let input = serde_json::json!({
            "command": "ls",
            "path": "/tmp"
        });
        let output = serde_json::json!({
            "stdout": "file1.txt\nfile2.txt\n",
            "exit_code": 0
        });

        let resp = AIResponse::AIChatTool {
            session_id: "session-tool".to_string(),
            tool: "bash".to_string(),
            input: input.clone(),
            output: Some(output.clone()),
        };
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains("\"type\":\"ai_chat_tool\""));
        assert!(json.contains("\"session_id\":\"session-tool\""));
        assert!(json.contains("\"tool\":\"bash\""));
        assert!(json.contains("\"input\""));
        assert!(json.contains("\"output\""));

        let parsed: AIResponse = serde_json::from_str(&json).unwrap();
        match parsed {
            AIResponse::AIChatTool {
                session_id,
                tool,
                input: inp,
                output: out,
            } => {
                assert_eq!(session_id, "session-tool");
                assert_eq!(tool, "bash");
                assert_eq!(inp.get("command").unwrap(), "ls");
                assert!(out.is_some());
            }
            _ => panic!("Expected AIChatTool"),
        }
    }

    #[test]
    fn test_ai_chat_tool_without_output() {
        let input = serde_json::json!({"action": "read"});

        let resp = AIResponse::AIChatTool {
            session_id: "session-no-output".to_string(),
            tool: "read_file".to_string(),
            input,
            output: None,
        };
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains("\"type\":\"ai_chat_tool\""));
        assert!(!json.contains("\"output\""));
    }

    #[test]
    fn test_ai_chat_error_serialization() {
        let resp = AIResponse::AIChatError {
            session_id: "session-err".to_string(),
            error: "Failed to execute command: permission denied".to_string(),
        };
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains("\"type\":\"ai_chat_error\""));
        assert!(json.contains("\"session_id\":\"session-err\""));
        assert!(json.contains("\"error\":\"Failed to execute command: permission denied\""));

        let parsed: AIResponse = serde_json::from_str(&json).unwrap();
        match parsed {
            AIResponse::AIChatError { session_id, error } => {
                assert_eq!(session_id, "session-err");
                assert_eq!(error, "Failed to execute command: permission denied");
            }
            _ => panic!("Expected AIChatError"),
        }
    }

    #[test]
    fn test_ai_session_started_serialization() {
        let resp = AIResponse::AISessionStarted {
            session_id: "new-session-123".to_string(),
            title: "New Feature Discussion".to_string(),
        };
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains("\"type\":\"ai_session_started\""));
        assert!(json.contains("\"session_id\":\"new-session-123\""));
        assert!(json.contains("\"title\":\"New Feature Discussion\""));

        let parsed: AIResponse = serde_json::from_str(&json).unwrap();
        match parsed {
            AIResponse::AISessionStarted { session_id, title } => {
                assert_eq!(session_id, "new-session-123");
                assert_eq!(title, "New Feature Discussion");
            }
            _ => panic!("Expected AISessionStarted"),
        }
    }

    #[test]
    fn test_ai_session_list_response_serialization() {
        let sessions = vec![
            SessionInfo {
                id: "session-1".to_string(),
                title: "Bug Fix Discussion".to_string(),
                updated_at: 1700000000000,
            },
            SessionInfo {
                id: "session-2".to_string(),
                title: "Code Review".to_string(),
                updated_at: 1700001000000,
            },
        ];

        let resp = AIResponse::AISessionList {
            sessions: sessions.clone(),
        };
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains("\"type\":\"ai_session_list\""));
        assert!(json.contains("\"sessions\""));
        assert!(json.contains("\"session-1\""));
        assert!(json.contains("\"session-2\""));

        let parsed: AIResponse = serde_json::from_str(&json).unwrap();
        match parsed {
            AIResponse::AISessionList {
                sessions: parsed_sessions,
            } => {
                assert_eq!(parsed_sessions.len(), 2);
                assert_eq!(parsed_sessions[0].id, "session-1");
                assert_eq!(parsed_sessions[1].title, "Code Review");
            }
            _ => panic!("Expected AISessionList"),
        }
    }

    #[test]
    fn test_session_info_structure() {
        let info = SessionInfo {
            id: "test-id".to_string(),
            title: "Test Title".to_string(),
            updated_at: 1234567890,
        };

        // 序列化
        let json = serde_json::to_string(&info).unwrap();
        assert!(json.contains("\"id\":\"test-id\""));
        assert!(json.contains("\"title\":\"Test Title\""));
        assert!(json.contains("\"updated_at\":1234567890"));

        // 反序列化
        let parsed: SessionInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.id, "test-id");
        assert_eq!(parsed.title, "Test Title");
        assert_eq!(parsed.updated_at, 1234567890);
    }

    // ============================================================================
    // MessagePack 序列化测试
    // ============================================================================

    #[test]
    fn test_ai_request_msgpack() {
        use rmp_serde::decode;
        use rmp_serde::encode;

        let req = AIRequest::AIChatSend {
            session_id: "msgpack-session".to_string(),
            message: "Test message".to_string(),
            file_refs: Some(vec!["file1.rs".to_string()]),
        };

        let buf = encode::to_vec(&req).unwrap();
        let decoded: AIRequest = decode::from_slice(&buf).unwrap();

        match decoded {
            AIRequest::AIChatSend {
                session_id,
                message,
                file_refs,
            } => {
                assert_eq!(session_id, "msgpack-session");
                assert_eq!(message, "Test message");
                assert_eq!(file_refs, Some(vec!["file1.rs".to_string()]));
            }
            _ => panic!("Expected AIChatSend"),
        }
    }

    #[test]
    fn test_ai_response_msgpack() {
        use rmp_serde::decode;
        use rmp_serde::encode;

        let resp = AIResponse::AIChatText {
            session_id: "msgpack-text".to_string(),
            text: "Hello World".to_string(),
            delta: Some("Hello".to_string()),
            done: true,
        };

        let buf = encode::to_vec(&resp).unwrap();
        let decoded: AIResponse = decode::from_slice(&buf).unwrap();

        match decoded {
            AIResponse::AIChatText {
                session_id,
                text,
                delta: _,
                done,
            } => {
                assert_eq!(session_id, "msgpack-text");
                assert_eq!(text, "Hello World");
                assert_eq!(done, true);
            }
            _ => panic!("Expected AIChatText"),
        }
    }
}
