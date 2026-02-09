//! 项目/工作空间领域协议类型

use serde::{Deserialize, Serialize};

/// 项目/工作空间相关的客户端消息
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ProjectRequest {
    ListProjects,
    ListWorkspaces { project: String },
    SelectWorkspace { project: String, workspace: String },
    ImportProject { name: String, path: String },
    CreateWorkspace {
        project: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        from_branch: Option<String>,
    },
    RemoveProject { name: String },
    RemoveWorkspace { project: String, workspace: String },
    SaveProjectCommands {
        project: String,
        commands: Vec<super::ProjectCommandInfo>,
    },
    RunProjectCommand { project: String, workspace: String, command_id: String },
    CancelProjectCommand { project: String, workspace: String, command_id: String },
}

/// 项目/工作空间相关的服务端消息
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ProjectResponse {
    Projects { items: Vec<super::ProjectInfo> },
    Workspaces { project: String, items: Vec<super::WorkspaceInfo> },
    SelectedWorkspace {
        project: String, workspace: String, root: String,
        session_id: String, shell: String,
    },
    ProjectImported {
        name: String, root: String, default_branch: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        workspace: Option<super::WorkspaceInfo>,
    },
    WorkspaceCreated { project: String, workspace: super::WorkspaceInfo },
    ProjectRemoved {
        name: String, ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    WorkspaceRemoved {
        project: String, workspace: String, ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    ProjectCommandsSaved {
        project: String, ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    ProjectCommandStarted {
        project: String, workspace: String,
        command_id: String, task_id: String,
    },
    ProjectCommandCompleted {
        project: String, workspace: String,
        command_id: String, task_id: String, ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    ProjectCommandCancelled {
        project: String, workspace: String,
        command_id: String, task_id: String,
    },
    ProjectCommandOutput { task_id: String, line: String },
}
