//! 编辑器格式化领域协议类型

use serde::{Deserialize, Serialize};

/// 格式化作用域
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EditorFormatScope {
    /// 整文档格式化
    Document,
    /// 选区格式化
    Selection,
}

/// 格式化错误码
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EditorFormattingErrorCode {
    /// 语言无对应格式化器
    UnsupportedLanguage,
    /// 格式化工具未安装或不在 PATH
    ToolUnavailable,
    /// 当前格式化器不支持请求的作用域
    UnsupportedScope,
    /// 工作区不可用（项目/工作区不存在）
    WorkspaceUnavailable,
    /// 格式化器执行失败（exit code 非零或超时）
    ExecutionFailed,
    /// 请求参数无效
    InvalidRequest,
}

impl EditorFormattingErrorCode {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::UnsupportedLanguage => "unsupported_language",
            Self::ToolUnavailable => "tool_unavailable",
            Self::UnsupportedScope => "unsupported_scope",
            Self::WorkspaceUnavailable => "workspace_unavailable",
            Self::ExecutionFailed => "execution_failed",
            Self::InvalidRequest => "invalid_request",
        }
    }
}

impl std::fmt::Display for EditorFormattingErrorCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// 单个格式化器的能力声明
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EditorFormattingCapability {
    /// 格式化器唯一标识（如 "swift-format"、"rustfmt"）
    pub formatter_id: String,
    /// 对应语言标识（与客户端 EditorSyntaxLanguage 对齐）
    pub language: String,
    /// 支持的作用域列表
    pub supported_scopes: Vec<EditorFormatScope>,
}

/// 格式化能力查询请求
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FormatCapabilitiesQueryRequest {
    pub project: String,
    pub workspace: String,
    pub path: String,
}

/// 格式化能力查询响应
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FormatCapabilitiesQueryResult {
    pub project: String,
    pub workspace: String,
    pub path: String,
    pub language: String,
    pub capabilities: Vec<EditorFormattingCapability>,
}

/// 格式化执行请求
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FormatExecuteRequest {
    pub project: String,
    pub workspace: String,
    pub path: String,
    pub scope: EditorFormatScope,
    pub text: String,
    /// 选区元数据（scope=selection 时必须）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selection_start: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selection_end: Option<u32>,
}

/// 格式化执行成功结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FormatExecuteResult {
    pub project: String,
    pub workspace: String,
    pub path: String,
    /// 格式化后的完整文本
    pub formatted_text: String,
    /// 使用的格式化器
    pub formatter_id: String,
    /// 实际使用的作用域
    pub scope: EditorFormatScope,
    /// 文本是否有变化
    pub changed: bool,
}

/// 格式化执行失败结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FormatExecuteError {
    pub project: String,
    pub workspace: String,
    pub path: String,
    pub error_code: EditorFormattingErrorCode,
    pub message: String,
}

/// 语言级格式化配置（客户端设置持久化用）
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct EditorFormattingLanguageConfig {
    /// 语言标识
    pub language: String,
    /// 首选格式化器 ID（为空时使用默认）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preferred_formatter_id: Option<String>,
    /// 保存时自动格式化（本轮默认 false）
    #[serde(default)]
    pub format_on_save: bool,
    /// 允许整文档回退（本轮默认 false）
    #[serde(default)]
    pub allow_full_document_fallback: bool,
    /// 格式化器额外参数
    #[serde(default)]
    pub extra_args: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    // -----------------------------------------------------------------
    // EditorFormatScope 序列化/反序列化
    // -----------------------------------------------------------------

    #[test]
    fn format_scope_serialization() {
        let doc = EditorFormatScope::Document;
        let json = serde_json::to_string(&doc).unwrap();
        assert_eq!(json, "\"document\"");

        let sel = EditorFormatScope::Selection;
        let json = serde_json::to_string(&sel).unwrap();
        assert_eq!(json, "\"selection\"");
    }

    #[test]
    fn format_scope_deserialization() {
        let doc: EditorFormatScope = serde_json::from_str("\"document\"").unwrap();
        assert_eq!(doc, EditorFormatScope::Document);

        let sel: EditorFormatScope = serde_json::from_str("\"selection\"").unwrap();
        assert_eq!(sel, EditorFormatScope::Selection);
    }

    // -----------------------------------------------------------------
    // EditorFormattingErrorCode
    // -----------------------------------------------------------------

    #[test]
    fn error_code_serialization() {
        let code = EditorFormattingErrorCode::ToolUnavailable;
        let json = serde_json::to_string(&code).unwrap();
        assert_eq!(json, "\"tool_unavailable\"");
    }

    #[test]
    fn error_code_as_str() {
        assert_eq!(
            EditorFormattingErrorCode::UnsupportedLanguage.as_str(),
            "unsupported_language"
        );
        assert_eq!(
            EditorFormattingErrorCode::ToolUnavailable.as_str(),
            "tool_unavailable"
        );
        assert_eq!(
            EditorFormattingErrorCode::UnsupportedScope.as_str(),
            "unsupported_scope"
        );
        assert_eq!(
            EditorFormattingErrorCode::WorkspaceUnavailable.as_str(),
            "workspace_unavailable"
        );
        assert_eq!(
            EditorFormattingErrorCode::ExecutionFailed.as_str(),
            "execution_failed"
        );
        assert_eq!(
            EditorFormattingErrorCode::InvalidRequest.as_str(),
            "invalid_request"
        );
    }

    #[test]
    fn error_code_display() {
        let code = EditorFormattingErrorCode::ExecutionFailed;
        assert_eq!(format!("{}", code), "execution_failed");
    }

    // -----------------------------------------------------------------
    // EditorFormattingCapability 编解码
    // -----------------------------------------------------------------

    #[test]
    fn capability_serialization_roundtrip() {
        let cap = EditorFormattingCapability {
            formatter_id: "rustfmt".to_string(),
            language: "rust".to_string(),
            supported_scopes: vec![EditorFormatScope::Document],
        };
        let json = serde_json::to_string(&cap).unwrap();
        let decoded: EditorFormattingCapability = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.formatter_id, "rustfmt");
        assert_eq!(decoded.language, "rust");
        assert_eq!(decoded.supported_scopes, vec![EditorFormatScope::Document]);
    }

    // -----------------------------------------------------------------
    // FormatExecuteRequest 编解码
    // -----------------------------------------------------------------

    #[test]
    fn format_execute_request_roundtrip() {
        let req = FormatExecuteRequest {
            project: "proj".to_string(),
            workspace: "ws".to_string(),
            path: "main.rs".to_string(),
            scope: EditorFormatScope::Document,
            text: "fn main() {}".to_string(),
            selection_start: None,
            selection_end: None,
        };
        let json = serde_json::to_string(&req).unwrap();
        let decoded: FormatExecuteRequest = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.project, "proj");
        assert_eq!(decoded.scope, EditorFormatScope::Document);
        assert!(decoded.selection_start.is_none());
    }

    #[test]
    fn format_execute_request_with_selection() {
        let req = FormatExecuteRequest {
            project: "p".to_string(),
            workspace: "w".to_string(),
            path: "file.swift".to_string(),
            scope: EditorFormatScope::Selection,
            text: "let x = 1".to_string(),
            selection_start: Some(4),
            selection_end: Some(9),
        };
        let json = serde_json::to_string(&req).unwrap();
        let decoded: FormatExecuteRequest = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.scope, EditorFormatScope::Selection);
        assert_eq!(decoded.selection_start, Some(4));
        assert_eq!(decoded.selection_end, Some(9));
    }

    // -----------------------------------------------------------------
    // EditorFormattingLanguageConfig 编解码与默认值
    // -----------------------------------------------------------------

    #[test]
    fn language_config_serialization_roundtrip() {
        let config = EditorFormattingLanguageConfig {
            language: "swift".to_string(),
            preferred_formatter_id: Some("swift-format".to_string()),
            format_on_save: false,
            allow_full_document_fallback: false,
            extra_args: vec!["--indent-width".to_string(), "4".to_string()],
        };
        let json = serde_json::to_string(&config).unwrap();
        let decoded: EditorFormattingLanguageConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.language, "swift");
        assert_eq!(
            decoded.preferred_formatter_id,
            Some("swift-format".to_string())
        );
        assert!(!decoded.format_on_save);
        assert_eq!(decoded.extra_args.len(), 2);
    }

    #[test]
    fn language_config_defaults() {
        let json = r#"{"language": "rust"}"#;
        let config: EditorFormattingLanguageConfig = serde_json::from_str(json).unwrap();
        assert_eq!(config.language, "rust");
        assert_eq!(config.preferred_formatter_id, None);
        assert!(!config.format_on_save);
        assert!(!config.allow_full_document_fallback);
        assert!(config.extra_args.is_empty());
    }

    #[test]
    fn language_config_optional_fields_skip_none() {
        let config = EditorFormattingLanguageConfig {
            language: "rust".to_string(),
            preferred_formatter_id: None,
            format_on_save: false,
            allow_full_document_fallback: false,
            extra_args: vec![],
        };
        let json = serde_json::to_string(&config).unwrap();
        // preferred_formatter_id 为 None 时应被 skip
        assert!(!json.contains("preferred_formatter_id"));
    }

    // -----------------------------------------------------------------
    // FormatCapabilitiesQueryResult 编解码
    // -----------------------------------------------------------------

    #[test]
    fn capabilities_result_roundtrip() {
        let result = FormatCapabilitiesQueryResult {
            project: "p".to_string(),
            workspace: "w".to_string(),
            path: "main.rs".to_string(),
            language: "rust".to_string(),
            capabilities: vec![EditorFormattingCapability {
                formatter_id: "rustfmt".to_string(),
                language: "rust".to_string(),
                supported_scopes: vec![EditorFormatScope::Document],
            }],
        };
        let json = serde_json::to_string(&result).unwrap();
        let decoded: FormatCapabilitiesQueryResult = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.language, "rust");
        assert_eq!(decoded.capabilities.len(), 1);
        assert_eq!(decoded.capabilities[0].formatter_id, "rustfmt");
    }

    // -----------------------------------------------------------------
    // FormatExecuteResult / FormatExecuteError 编解码
    // -----------------------------------------------------------------

    #[test]
    fn format_execute_result_roundtrip() {
        let result = FormatExecuteResult {
            project: "p".to_string(),
            workspace: "w".to_string(),
            path: "main.rs".to_string(),
            formatted_text: "fn main() {}\n".to_string(),
            formatter_id: "rustfmt".to_string(),
            scope: EditorFormatScope::Document,
            changed: true,
        };
        let json = serde_json::to_string(&result).unwrap();
        let decoded: FormatExecuteResult = serde_json::from_str(&json).unwrap();
        assert!(decoded.changed);
        assert_eq!(decoded.formatted_text, "fn main() {}\n");
    }

    #[test]
    fn format_execute_error_roundtrip() {
        let err = FormatExecuteError {
            project: "p".to_string(),
            workspace: "w".to_string(),
            path: "f.swift".to_string(),
            error_code: EditorFormattingErrorCode::ToolUnavailable,
            message: "swift-format not found".to_string(),
        };
        let json = serde_json::to_string(&err).unwrap();
        let decoded: FormatExecuteError = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.error_code, EditorFormattingErrorCode::ToolUnavailable);
        assert_eq!(decoded.message, "swift-format not found");
    }
}
