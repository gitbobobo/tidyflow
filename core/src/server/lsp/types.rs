use std::path::Path;

use serde::{Deserialize, Serialize};

/// LSP 语言集合（首批）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum LspLanguage {
    Rust,
    Swift,
    Kotlin,
    TypeScript,
    Python,
}

impl LspLanguage {
    pub fn all() -> [LspLanguage; 5] {
        [
            LspLanguage::Rust,
            LspLanguage::Swift,
            LspLanguage::Kotlin,
            LspLanguage::TypeScript,
            LspLanguage::Python,
        ]
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            LspLanguage::Rust => "rust",
            LspLanguage::Swift => "swift",
            LspLanguage::Kotlin => "kotlin",
            LspLanguage::TypeScript => "typescript",
            LspLanguage::Python => "python",
        }
    }

    pub fn language_id(&self) -> &'static str {
        match self {
            LspLanguage::Rust => "rust",
            LspLanguage::Swift => "swift",
            LspLanguage::Kotlin => "kotlin",
            LspLanguage::TypeScript => "typescript",
            LspLanguage::Python => "python",
        }
    }

    pub fn extensions(&self) -> &'static [&'static str] {
        match self {
            LspLanguage::Rust => &["rs"],
            LspLanguage::Swift => &["swift"],
            LspLanguage::Kotlin => &["kt", "kts"],
            LspLanguage::TypeScript => &["ts", "tsx"],
            LspLanguage::Python => &["py"],
        }
    }

    pub fn matches_path(&self, path: &Path) -> bool {
        path.extension()
            .and_then(|ext| ext.to_str())
            .map(|ext| {
                let lower = ext.to_lowercase();
                self.extensions().iter().any(|x| *x == lower)
            })
            .unwrap_or(false)
    }
}

/// LSP 原始诊断严重级
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum LspSeverity {
    Error,
    Warning,
    Info,
    Hint,
}

impl LspSeverity {
    pub fn from_lsp_int(v: i64) -> LspSeverity {
        match v {
            1 => LspSeverity::Error,
            2 => LspSeverity::Warning,
            3 => LspSeverity::Info,
            4 => LspSeverity::Hint,
            _ => LspSeverity::Info,
        }
    }

    pub fn rank(&self) -> i32 {
        match self {
            LspSeverity::Error => 4,
            LspSeverity::Warning => 3,
            LspSeverity::Info => 2,
            LspSeverity::Hint => 1,
        }
    }

    pub fn as_protocol_str(&self) -> &'static str {
        match self {
            LspSeverity::Error => "error",
            LspSeverity::Warning => "warning",
            LspSeverity::Info | LspSeverity::Hint => "info",
        }
    }
}

/// publishDiagnostics 原始单条诊断（不含路径）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RawLspDiagnostic {
    pub line: u32,
    pub column: u32,
    pub end_line: u32,
    pub end_column: u32,
    pub severity: LspSeverity,
    pub message: String,
    pub source: Option<String>,
    pub code: Option<String>,
}

/// 工作区聚合后的诊断（含相对路径）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceDiagnostic {
    pub language: LspLanguage,
    pub path: String,
    pub line: u32,
    pub column: u32,
    pub end_line: u32,
    pub end_column: u32,
    pub severity: LspSeverity,
    pub message: String,
    pub source: Option<String>,
    pub code: Option<String>,
}

impl WorkspaceDiagnostic {
    pub fn dedupe_key(&self) -> String {
        format!(
            "{}|{}|{}:{}-{}:{}|{}|{}|{}",
            self.language.as_str(),
            self.path,
            self.line,
            self.column,
            self.end_line,
            self.end_column,
            self.severity.as_protocol_str(),
            self.source.clone().unwrap_or_default(),
            self.message
        )
    }
}

/// Session -> Supervisor 事件
#[derive(Debug, Clone)]
pub enum SupervisorEvent {
    PublishDiagnostics {
        workspace_key: String,
        language: LspLanguage,
        uri: String,
        diagnostics: Vec<RawLspDiagnostic>,
    },
    SessionExited {
        workspace_key: String,
        language: LspLanguage,
        reason: String,
    },
}
