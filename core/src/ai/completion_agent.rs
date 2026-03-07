//! AI 代码补全引擎
//!
//! `CompletionAgent` 封装现有 `AiAgent` trait，将代码补全请求转换为
//! 结构化的 prompt 并通过流式接口返回增量分片。

use std::sync::Arc;

use tokio::sync::mpsc;
use tokio_stream::StreamExt;
use tracing::{debug, warn};

use crate::ai::{AiAgent, AiEventStream, AiImagePart};
use crate::server::protocol::ai::{
    CodeCompletionChunk, CodeCompletionRequest, CodeCompletionResponse,
};

// ============================================================================
// 代码补全引擎
// ============================================================================

/// 基于 AiAgent 的代码补全引擎
///
/// 复用现有 AI 会话通道，将补全请求转换为 fill-in-the-middle 风格的 prompt，
/// 并以流式增量分片方式推送给调用者。
pub struct CompletionAgent {
    agent: Arc<dyn AiAgent>,
}

impl CompletionAgent {
    /// 使用现有 AiAgent 实例创建 CompletionAgent
    pub fn new(agent: Arc<dyn AiAgent>) -> Self {
        Self { agent }
    }

    /// 执行代码补全，通过 `tx` 推送流式分片，最终推送完成响应。
    ///
    /// # 参数
    /// - `directory`：项目工作目录
    /// - `session_id`：AI 会话 ID
    /// - `req`：补全请求
    /// - `tx`：流式分片发送通道；发送 Err 表示终止
    pub async fn complete(
        &self,
        directory: &str,
        session_id: &str,
        req: &CodeCompletionRequest,
        tx: mpsc::Sender<Result<CodeCompletionChunk, String>>,
    ) -> CodeCompletionResponse {
        let prompt = build_completion_prompt(req);

        debug!(
            "CompletionAgent: request_id={}, language={:?}, prefix_len={}, trigger={}",
            req.request_id,
            req.language,
            req.prefix.len(),
            req.trigger_kind,
        );

        let stream_result = self
            .agent
            .send_message(
                directory,
                session_id,
                &prompt,
                None,
                None::<Vec<AiImagePart>>,
                None,
                None,
                None,
            )
            .await;

        let mut stream: AiEventStream = match stream_result {
            Ok(s) => s,
            Err(e) => {
                warn!("CompletionAgent: send_message failed: {}", e);
                return CodeCompletionResponse {
                    request_id: req.request_id.clone(),
                    completion_text: String::new(),
                    stop_reason: "error".to_string(),
                    error: Some(e),
                };
            }
        };

        let mut accumulated = String::new();
        let mut stop_reason = "done".to_string();
        let mut error: Option<String> = None;

        while let Some(event) = stream.next().await {
            match event {
                Ok(crate::ai::AiEvent::PartDelta { field, delta, .. }) if field == "text" => {
                    accumulated.push_str(&delta);
                    let chunk = CodeCompletionChunk {
                        request_id: req.request_id.clone(),
                        delta: delta.clone(),
                        is_final: false,
                    };
                    if tx.send(Ok(chunk)).await.is_err() {
                        // 调用方已取消
                        stop_reason = "cancelled".to_string();
                        break;
                    }
                }
                Ok(crate::ai::AiEvent::PartUpdated { part, .. }) => {
                    if part.part_type == "text" {
                        if let Some(text) = &part.text {
                            // full update — 仅当没有增量时追加
                            let new_part =
                                text.strip_prefix(&accumulated).unwrap_or(text).to_string();
                            if !new_part.is_empty() {
                                accumulated.push_str(&new_part);
                                let chunk = CodeCompletionChunk {
                                    request_id: req.request_id.clone(),
                                    delta: new_part,
                                    is_final: false,
                                };
                                if tx.send(Ok(chunk)).await.is_err() {
                                    stop_reason = "cancelled".to_string();
                                    break;
                                }
                            }
                        }
                    }
                }
                Ok(crate::ai::AiEvent::Done { .. }) => {
                    break;
                }
                Ok(crate::ai::AiEvent::Error { message }) => {
                    stop_reason = "error".to_string();
                    error = Some(message);
                    break;
                }
                _ => {}
            }
        }

        // 修剪 accumulated：去除多余的 markdown 代码块包装（常见于对话型模型）
        let completion_text = strip_completion_wrapper(&accumulated);

        CodeCompletionResponse {
            request_id: req.request_id.clone(),
            completion_text,
            stop_reason,
            error,
        }
    }
}

// ============================================================================
// Prompt 构建
// ============================================================================

/// 构建 fill-in-the-middle 风格的补全 prompt
fn build_completion_prompt(req: &CodeCompletionRequest) -> String {
    let lang_name = req.language.display_name();

    // 上下文截断：最多取光标前 2000 字符
    let prefix_ctx = truncate_prefix(&req.prefix, 2000);
    // 下文最多 500 字符
    let suffix_ctx = req
        .suffix
        .as_deref()
        .map(|s| truncate_suffix(s, 500))
        .unwrap_or_default();

    let file_hint = req
        .file_path
        .as_deref()
        .map(|p| format!("文件路径: {}\n", p))
        .unwrap_or_default();

    if suffix_ctx.is_empty() {
        format!(
            "你是一个 {} 代码补全引擎。请续写光标位置后的代码，只输出补全的代码片段本身，不要解释，不要使用 markdown 代码块。\n\
             {}触发方式: {}\n\
             光标前代码：\n{}<CURSOR>",
            lang_name, file_hint, req.trigger_kind, prefix_ctx
        )
    } else {
        format!(
            "你是一个 {} 代码补全引擎。请填入 <FILL> 位置的代码，只输出填入的代码片段本身，不要解释，不要使用 markdown 代码块。\n\
             {}触发方式: {}\n\
             <PREFIX>\n{}\n<FILL>\n<SUFFIX>\n{}",
            lang_name, file_hint, req.trigger_kind, prefix_ctx, suffix_ctx
        )
    }
}

/// 去除补全文本中可能存在的 markdown 代码块包装
fn strip_completion_wrapper(text: &str) -> String {
    let trimmed = text.trim();
    // 尝试剥离 ```lang ... ``` 或 ``` ... ```
    if trimmed.starts_with("```") {
        let body = trimmed.trim_start_matches("```");
        // 跳过语言标签行（如果有）
        let body = if let Some(pos) = body.find('\n') {
            // 第一行是语言标签时跳过
            let first_line = body[..pos].trim();
            if first_line.chars().all(|c| c.is_alphanumeric() || c == '_') {
                &body[pos + 1..]
            } else {
                body
            }
        } else {
            body
        };
        let body = body.trim_end_matches("```").trim_end();
        return body.to_string();
    }
    trimmed.to_string()
}

/// 截断 prefix，保留最后 max_chars 个字符
fn truncate_prefix(s: &str, max_chars: usize) -> &str {
    if s.chars().count() <= max_chars {
        return s;
    }
    // 从末尾截取
    let start_byte = s
        .char_indices()
        .rev()
        .nth(max_chars - 1)
        .map(|(i, _)| i)
        .unwrap_or(0);
    &s[start_byte..]
}

/// 截断 suffix，保留最前 max_chars 个字符
fn truncate_suffix(s: &str, max_chars: usize) -> &str {
    if s.chars().count() <= max_chars {
        return s;
    }
    let end_byte = s
        .char_indices()
        .nth(max_chars)
        .map(|(i, _)| i)
        .unwrap_or(s.len());
    &s[..end_byte]
}

// ============================================================================
// 测试
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::protocol::ai::CodeCompletionLanguage;

    #[test]
    fn test_build_completion_prompt_no_suffix() {
        let req = CodeCompletionRequest {
            request_id: "r1".to_string(),
            language: CodeCompletionLanguage::Rust,
            file_content: None,
            prefix: "fn hello() {".to_string(),
            suffix: None,
            file_path: Some("src/lib.rs".to_string()),
            cursor_line: None,
            cursor_column: None,
            trigger_kind: "manual".to_string(),
        };
        let prompt = build_completion_prompt(&req);
        assert!(prompt.contains("Rust"));
        assert!(prompt.contains("fn hello() {"));
        assert!(prompt.contains("<CURSOR>"));
    }

    #[test]
    fn test_build_completion_prompt_with_suffix() {
        let req = CodeCompletionRequest {
            request_id: "r2".to_string(),
            language: CodeCompletionLanguage::TypeScript,
            file_content: None,
            prefix: "const x = ".to_string(),
            suffix: Some(";".to_string()),
            file_path: None,
            cursor_line: None,
            cursor_column: None,
            trigger_kind: "auto".to_string(),
        };
        let prompt = build_completion_prompt(&req);
        assert!(prompt.contains("TypeScript"));
        assert!(prompt.contains("<FILL>"));
        assert!(prompt.contains("<SUFFIX>"));
    }

    #[test]
    fn test_strip_completion_wrapper() {
        assert_eq!(
            strip_completion_wrapper("```rust\nlet x = 1;\n```"),
            "let x = 1;"
        );
        assert_eq!(strip_completion_wrapper("```\nfoo\n```"), "foo");
        assert_eq!(strip_completion_wrapper("plain code"), "plain code");
    }

    #[test]
    fn test_truncate_prefix() {
        let s = "hello world";
        assert_eq!(truncate_prefix(s, 100), s);
        let result = truncate_prefix(s, 5);
        assert_eq!(result, "world");
    }
}
