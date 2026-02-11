use std::path::{Path, PathBuf};

use super::types::LspLanguage;

#[derive(Debug, Clone)]
pub struct LspServerSpec {
    pub program: String,
    pub args: Vec<String>,
}

fn executable_exists_in_path(binary: &str) -> bool {
    let candidates = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect::<Vec<PathBuf>>())
        .unwrap_or_default();

    for dir in candidates {
        let full = dir.join(binary);
        if is_executable_file(&full) {
            return true;
        }
    }
    false
}

#[cfg(unix)]
fn is_executable_file(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    match std::fs::metadata(path) {
        Ok(meta) if meta.is_file() => meta.permissions().mode() & 0o111 != 0,
        _ => false,
    }
}

#[cfg(not(unix))]
fn is_executable_file(path: &Path) -> bool {
    path.is_file()
}

pub fn detect_server(language: LspLanguage) -> Option<LspServerSpec> {
    let candidates: Vec<LspServerSpec> = match language {
        LspLanguage::Rust => vec![LspServerSpec {
            program: "rust-analyzer".to_string(),
            args: vec![],
        }],
        LspLanguage::Swift => vec![LspServerSpec {
            program: "sourcekit-lsp".to_string(),
            args: vec![],
        }],
        LspLanguage::Kotlin => vec![
            LspServerSpec {
                program: "kotlin-language-server".to_string(),
                args: vec![],
            },
            LspServerSpec {
                program: "kotlin-lsp".to_string(),
                args: vec![],
            },
        ],
        LspLanguage::TypeScript => vec![LspServerSpec {
            program: "typescript-language-server".to_string(),
            args: vec!["--stdio".to_string()],
        }],
        LspLanguage::Python => vec![LspServerSpec {
            program: "pyright-langserver".to_string(),
            args: vec!["--stdio".to_string()],
        }],
    };

    for candidate in candidates {
        if executable_exists_in_path(&candidate.program) {
            return Some(candidate);
        }
    }
    None
}
