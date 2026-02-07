//! Workspace Engine v1 - Project and Workspace management using git worktree
//!
//! This module provides:
//! - Project import (local path or git clone)
//! - Workspace creation using git worktree
//! - Setup step execution from project config
//! - State persistence

pub mod config;
pub mod project;
pub mod setup;
pub mod state;
pub mod state_saver;
pub mod workspace;

pub use config::ProjectConfig;
pub use project::ProjectManager;
pub use setup::{SetupExecutor, SetupResult, StepResult};
pub use state::{AppState, Project, Workspace, WorkspaceStatus};
pub use state_saver::spawn_state_saver;
pub use workspace::WorkspaceManager;
