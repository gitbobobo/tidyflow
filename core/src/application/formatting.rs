//! 编辑器格式化应用层
//!
//! 按 (project, workspace) 解析工作区根目录并执行格式化。
//! 不允许跨工作区复用缓存或路径推断。

use crate::server::protocol::formatting::{
    EditorFormattingCapability, EditorFormattingErrorCode, EditorFormatScope,
};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use tokio::process::Command;
use tracing::{debug, warn};

/// 格式化执行结果
pub enum FormatResult {
    /// 格式化成功
    Success {
        formatted_text: String,
        formatter_id: String,
        scope: EditorFormatScope,
        changed: bool,
    },
    /// 格式化失败
    Error {
        error_code: EditorFormattingErrorCode,
        message: String,
    },
}

/// 查询指定路径文件的格式化能力
pub fn query_capabilities(
    file_path: &str,
    workspace_root: &Path,
) -> (String, Vec<EditorFormattingCapability>) {
    let language = detect_language(file_path);
    let capabilities = match language.as_str() {
        "swift" => {
            let mut caps = Vec::new();
            if find_swift_formatter(workspace_root).is_some() {
                caps.push(EditorFormattingCapability {
                    formatter_id: "swift-format".to_string(),
                    language: "swift".to_string(),
                    supported_scopes: vec![EditorFormatScope::Document],
                });
            }
            caps
        }
        "rust" => {
            let mut caps = Vec::new();
            if which_tool("rustfmt").is_some() {
                caps.push(EditorFormattingCapability {
                    formatter_id: "rustfmt".to_string(),
                    language: "rust".to_string(),
                    supported_scopes: vec![EditorFormatScope::Document],
                });
            }
            caps
        }
        _ => Vec::new(),
    };
    debug!(
        language = %language,
        count = capabilities.len(),
        "格式化能力查询完成"
    );
    (language, capabilities)
}

/// 执行格式化
pub async fn execute_format(
    file_path: &str,
    workspace_root: &Path,
    scope: EditorFormatScope,
    text: &str,
    _selection_start: Option<u32>,
    _selection_end: Option<u32>,
) -> FormatResult {
    let language = detect_language(file_path);

    match language.as_str() {
        "swift" => execute_swift_format(workspace_root, scope, text).await,
        "rust" => execute_rust_format(workspace_root, scope, text).await,
        _ => FormatResult::Error {
            error_code: EditorFormattingErrorCode::UnsupportedLanguage,
            message: format!("语言 '{}' 无已注册的格式化器", language),
        },
    }
}

// ---------------------------------------------------------------------------
// 语言检测
// ---------------------------------------------------------------------------

/// 根据文件扩展名检测语言（与客户端 EditorSyntaxLanguage 对齐）
fn detect_language(file_path: &str) -> String {
    let ext = Path::new(file_path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();

    match ext.as_str() {
        "swift" => "swift",
        "rs" => "rust",
        "js" | "jsx" | "mjs" | "cjs" => "javascript",
        "ts" | "tsx" | "mts" | "cts" => "typescript",
        "py" | "pyw" => "python",
        "json" | "jsonc" | "geojson" => "json",
        "md" | "markdown" => "markdown",
        _ => "plainText",
    }
    .to_string()
}

// ---------------------------------------------------------------------------
// Swift 格式化
// ---------------------------------------------------------------------------

enum SwiftFormatterKind {
    /// `swift format`（新版 Swift 工具链内置子命令）
    SwiftSubcommand(PathBuf),
    /// 独立 `swift-format` 可执行文件
    SwiftFormat(PathBuf),
}

/// 查找 Swift 格式化器：优先尝试 `swift format`，回退到 `swift-format`
fn find_swift_formatter(_workspace_root: &Path) -> Option<SwiftFormatterKind> {
    if let Some(swift_path) = which_tool("swift") {
        return Some(SwiftFormatterKind::SwiftSubcommand(swift_path));
    }
    if let Some(path) = which_tool("swift-format") {
        return Some(SwiftFormatterKind::SwiftFormat(path));
    }
    None
}

async fn execute_swift_format(
    workspace_root: &Path,
    scope: EditorFormatScope,
    text: &str,
) -> FormatResult {
    if scope != EditorFormatScope::Document {
        return FormatResult::Error {
            error_code: EditorFormattingErrorCode::UnsupportedScope,
            message: "Swift 格式化器仅支持整文档格式化".to_string(),
        };
    }

    let formatter = match find_swift_formatter(workspace_root) {
        Some(f) => f,
        None => {
            return FormatResult::Error {
                error_code: EditorFormattingErrorCode::ToolUnavailable,
                message: "未在 PATH 中找到 'swift format' 或 'swift-format'".to_string(),
            };
        }
    };

    let mut cmd = match &formatter {
        SwiftFormatterKind::SwiftSubcommand(path) => {
            let mut c = Command::new(path);
            c.arg("format");
            c
        }
        SwiftFormatterKind::SwiftFormat(path) => Command::new(path),
    };

    cmd.current_dir(workspace_root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    run_formatter(cmd, text, "swift-format").await
}

// ---------------------------------------------------------------------------
// Rust 格式化
// ---------------------------------------------------------------------------

async fn execute_rust_format(
    workspace_root: &Path,
    scope: EditorFormatScope,
    text: &str,
) -> FormatResult {
    if scope != EditorFormatScope::Document {
        return FormatResult::Error {
            error_code: EditorFormattingErrorCode::UnsupportedScope,
            message: "rustfmt 仅支持整文档格式化".to_string(),
        };
    }

    let rustfmt = match which_tool("rustfmt") {
        Some(p) => p,
        None => {
            return FormatResult::Error {
                error_code: EditorFormattingErrorCode::ToolUnavailable,
                message: "未在 PATH 中找到 'rustfmt'".to_string(),
            };
        }
    };

    let mut cmd = Command::new(rustfmt);
    cmd.current_dir(workspace_root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    run_formatter(cmd, text, "rustfmt").await
}

// ---------------------------------------------------------------------------
// 通用格式化执行
// ---------------------------------------------------------------------------

fn which_tool(name: &str) -> Option<PathBuf> {
    which::which(name).ok()
}

async fn run_formatter(mut cmd: Command, text: &str, formatter_id: &str) -> FormatResult {
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            warn!(formatter = formatter_id, error = %e, "格式化器启动失败");
            return FormatResult::Error {
                error_code: EditorFormattingErrorCode::ExecutionFailed,
                message: format!("启动 {} 失败: {}", formatter_id, e),
            };
        }
    };

    // 写入 stdin 并关闭以发送 EOF
    if let Some(ref mut stdin) = child.stdin {
        use tokio::io::AsyncWriteExt;
        if let Err(e) = stdin.write_all(text.as_bytes()).await {
            warn!(formatter = formatter_id, error = %e, "写入格式化器 stdin 失败");
            return FormatResult::Error {
                error_code: EditorFormattingErrorCode::ExecutionFailed,
                message: format!("写入 {} stdin 失败: {}", formatter_id, e),
            };
        }
        drop(child.stdin.take());
    }

    // 带 30 秒超时等待完成
    let output = match tokio::time::timeout(
        std::time::Duration::from_secs(30),
        child.wait_with_output(),
    )
    .await
    {
        Ok(Ok(output)) => output,
        Ok(Err(e)) => {
            warn!(formatter = formatter_id, error = %e, "格式化器执行错误");
            return FormatResult::Error {
                error_code: EditorFormattingErrorCode::ExecutionFailed,
                message: format!("{} 执行错误: {}", formatter_id, e),
            };
        }
        Err(_) => {
            warn!(formatter = formatter_id, "格式化器超时（30 秒）");
            return FormatResult::Error {
                error_code: EditorFormattingErrorCode::ExecutionFailed,
                message: format!("{} 执行超时（30 秒）", formatter_id),
            };
        }
    };

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        warn!(
            formatter = formatter_id,
            status = %output.status,
            stderr = %stderr.trim(),
            "格式化器退出码非零"
        );
        return FormatResult::Error {
            error_code: EditorFormattingErrorCode::ExecutionFailed,
            message: format!(
                "{} 退出码 {}: {}",
                formatter_id,
                output.status,
                stderr.trim()
            ),
        };
    }

    let formatted_text = String::from_utf8_lossy(&output.stdout).into_owned();
    let changed = formatted_text != text;

    debug!(
        formatter = formatter_id,
        changed = changed,
        "格式化执行完成"
    );

    FormatResult::Success {
        formatted_text,
        formatter_id: formatter_id.to_string(),
        scope: EditorFormatScope::Document,
        changed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detect_language_swift() {
        assert_eq!(detect_language("Sources/App.swift"), "swift");
    }

    #[test]
    fn detect_language_rust() {
        assert_eq!(detect_language("src/main.rs"), "rust");
    }

    #[test]
    fn detect_language_typescript() {
        assert_eq!(detect_language("src/index.tsx"), "typescript");
    }

    #[test]
    fn detect_language_unknown() {
        assert_eq!(detect_language("Makefile"), "plainText");
    }

    #[test]
    fn query_capabilities_returns_language() {
        let (lang, _caps) = query_capabilities("test.swift", Path::new("/tmp"));
        assert_eq!(lang, "swift");
    }

    #[test]
    fn query_capabilities_unknown_language_empty() {
        let (_lang, caps) = query_capabilities("Makefile", Path::new("/tmp"));
        assert!(caps.is_empty());
    }
}
