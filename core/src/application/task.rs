use crate::server::context::SharedTaskHistory;
use crate::server::protocol::{ServerMessage, TaskSnapshotEntry};

pub async fn list_tasks_snapshot_message(task_history: &SharedTaskHistory) -> ServerMessage {
    let history = task_history.lock().await;
    let mut tasks: Vec<TaskSnapshotEntry> = history
        .iter()
        .map(|e| TaskSnapshotEntry {
            task_id: e.task_id.clone(),
            project: e.project.clone(),
            workspace: e.workspace.clone(),
            task_type: e.task_type.clone(),
            command_id: e.command_id.clone(),
            title: e.title.clone(),
            status: e.status.clone(),
            message: e.message.clone(),
            started_at: e.started_at,
            completed_at: e.completed_at,
        })
        .collect();
    drop(history);

    // 对外返回任务列表时显式排序，避免依赖内部存储顺序。
    tasks.sort_by(|a, b| {
        b.started_at
            .cmp(&a.started_at)
            .then_with(|| a.task_id.cmp(&b.task_id))
    });

    ServerMessage::TasksSnapshot { tasks }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::context::{SharedTaskHistory, TaskHistoryEntry};
    use std::sync::Arc;
    use tokio::sync::Mutex;

    #[tokio::test]
    async fn list_tasks_snapshot_sorts_by_started_at_desc() {
        let history: SharedTaskHistory = Arc::new(Mutex::new(vec![
            TaskHistoryEntry {
                task_id: "b".to_string(),
                project: "p".to_string(),
                workspace: "w".to_string(),
                task_type: "project_command".to_string(),
                command_id: None,
                title: "b".to_string(),
                status: "running".to_string(),
                message: None,
                started_at: 1,
                completed_at: None,
            },
            TaskHistoryEntry {
                task_id: "a".to_string(),
                project: "p".to_string(),
                workspace: "w".to_string(),
                task_type: "project_command".to_string(),
                command_id: None,
                title: "a".to_string(),
                status: "running".to_string(),
                message: None,
                started_at: 2,
                completed_at: None,
            },
        ]));

        let msg = list_tasks_snapshot_message(&history).await;
        let ServerMessage::TasksSnapshot { tasks } = msg else {
            panic!("expected tasks snapshot");
        };

        assert_eq!(tasks.first().map(|t| t.task_id.as_str()), Some("a"));
        assert_eq!(tasks.last().map(|t| t.task_id.as_str()), Some("b"));
    }
}
