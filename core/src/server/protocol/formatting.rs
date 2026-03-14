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
