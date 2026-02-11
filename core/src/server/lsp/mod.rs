//! LSP 诊断子系统
//!
//! 目标：
//! - Core 统一托管多语言 LSP 进程
//! - 聚合工作区诊断并通过 WS 推送给 App
//! - 服务缺失时降级提示，不阻塞其他语言

pub mod diagnostics;
pub mod manager;
pub mod servers;
pub mod session;
pub mod types;

pub use manager::LspSupervisor;
pub use types::{LspLanguage, LspSeverity, WorkspaceDiagnostic};
