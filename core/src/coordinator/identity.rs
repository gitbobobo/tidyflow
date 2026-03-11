//! 协调层身份与寻址模型
//!
//! 定义跨工作区并行场景下的统一身份标识。
//! 所有协调层操作（快照、校验、恢复）通过此身份模型定位目标作用域。

use serde::{Deserialize, Serialize};

/// 工作区级协调身份：唯一定位一个 `(project, workspace)` 上下文。
///
/// 与协议层 `(project, workspace)` 二元组语义对齐，
/// 不同项目下的同名工作区通过 project 字段严格隔离。
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct WorkspaceCoordinatorId {
    /// 项目名称
    pub project: String,
    /// 工作区名称
    pub workspace: String,
}

impl WorkspaceCoordinatorId {
    pub fn new(project: impl Into<String>, workspace: impl Into<String>) -> Self {
        Self {
            project: project.into(),
            workspace: workspace.into(),
        }
    }

    /// 全局键，格式 `"project:workspace"`，与客户端 `globalKey` 语义一致。
    pub fn global_key(&self) -> String {
        format!("{}:{}", self.project, self.workspace)
    }

    /// 从全局键解析。
    pub fn from_global_key(key: &str) -> Option<Self> {
        let (project, workspace) = key.split_once(':')?;
        if project.is_empty() || workspace.is_empty() {
            return None;
        }
        Some(Self {
            project: project.to_string(),
            workspace: workspace.to_string(),
        })
    }
}

impl std::fmt::Display for WorkspaceCoordinatorId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}:{}", self.project, self.workspace)
    }
}

/// 协调层作用域：区分系统级、项目级和工作区级操作。
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "scope", rename_all = "snake_case")]
pub enum CoordinatorScope {
    /// 系统级（跨所有项目和工作区）
    System,
    /// 项目级（指定项目下所有工作区）
    Project { project: String },
    /// 工作区级（精确到单个工作区）
    Workspace(WorkspaceCoordinatorId),
}

impl CoordinatorScope {
    pub fn system() -> Self {
        Self::System
    }

    pub fn project(project: impl Into<String>) -> Self {
        Self::Project {
            project: project.into(),
        }
    }

    pub fn workspace(project: impl Into<String>, workspace: impl Into<String>) -> Self {
        Self::Workspace(WorkspaceCoordinatorId::new(project, workspace))
    }

    /// 判断给定的工作区 ID 是否落在此作用域内。
    pub fn contains(&self, id: &WorkspaceCoordinatorId) -> bool {
        match self {
            Self::System => true,
            Self::Project { project } => id.project == *project,
            Self::Workspace(ws) => ws == id,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_id_global_key_roundtrip() {
        let id = WorkspaceCoordinatorId::new("my-project", "default");
        assert_eq!(id.global_key(), "my-project:default");
        let parsed = WorkspaceCoordinatorId::from_global_key(&id.global_key()).unwrap();
        assert_eq!(id, parsed);
    }

    #[test]
    fn workspace_id_from_invalid_key() {
        assert!(WorkspaceCoordinatorId::from_global_key("no-colon").is_none());
        assert!(WorkspaceCoordinatorId::from_global_key(":empty-project").is_none());
        assert!(WorkspaceCoordinatorId::from_global_key("empty-ws:").is_none());
    }

    #[test]
    fn scope_contains() {
        let id = WorkspaceCoordinatorId::new("proj-a", "ws-1");
        let id_b = WorkspaceCoordinatorId::new("proj-b", "ws-1");

        assert!(CoordinatorScope::system().contains(&id));
        assert!(CoordinatorScope::project("proj-a").contains(&id));
        assert!(!CoordinatorScope::project("proj-b").contains(&id));
        assert!(CoordinatorScope::workspace("proj-a", "ws-1").contains(&id));
        assert!(!CoordinatorScope::workspace("proj-a", "ws-1").contains(&id_b));
    }
}
