use crate::server::context::SharedTaskHistory;
use crate::server::protocol::{ServerMessage, TaskSnapshotEntry};

/// 任务快照是否可安全重试的判定
///
/// project_command 失败时可重试（用户可以安全地再次执行命令），
/// ai_commit / ai_merge 类型当前不自动重试（需要用户确认）。
fn is_retryable(task_type: &str, status: &str) -> bool {
    status == "failed" && task_type == "project_command"
}

/// 计算任务耗时（毫秒），由 Core 权威输出
fn compute_duration_ms(started_at: i64, completed_at: Option<i64>) -> Option<u64> {
    completed_at.and_then(|end| {
        let d = end - started_at;
        if d >= 0 {
            Some(d as u64)
        } else {
            None
        }
    })
}

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
            duration_ms: compute_duration_ms(e.started_at, e.completed_at),
            error_code: e.error_code.clone(),
            error_detail: e.error_detail.clone(),
            retryable: is_retryable(&e.task_type, &e.status),
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
                error_code: None,
                error_detail: None,
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
                error_code: None,
                error_detail: None,
            },
        ]));

        let msg = list_tasks_snapshot_message(&history).await;
        let ServerMessage::TasksSnapshot { tasks } = msg else {
            panic!("expected tasks snapshot");
        };

        assert_eq!(tasks.first().map(|t| t.task_id.as_str()), Some("a"));
        assert_eq!(tasks.last().map(|t| t.task_id.as_str()), Some("b"));
    }

    #[tokio::test]
    async fn task_snapshot_populates_duration_and_retry() {
        let history: SharedTaskHistory = Arc::new(Mutex::new(vec![
            TaskHistoryEntry {
                task_id: "ok".to_string(),
                project: "p".to_string(),
                workspace: "w".to_string(),
                task_type: "project_command".to_string(),
                command_id: Some("cmd1".to_string()),
                title: "build".to_string(),
                status: "completed".to_string(),
                message: None,
                started_at: 1000,
                completed_at: Some(5000),
                error_code: None,
                error_detail: None,
            },
            TaskHistoryEntry {
                task_id: "fail".to_string(),
                project: "p".to_string(),
                workspace: "w".to_string(),
                task_type: "project_command".to_string(),
                command_id: Some("cmd2".to_string()),
                title: "lint".to_string(),
                status: "failed".to_string(),
                message: Some("exit code 1".to_string()),
                started_at: 2000,
                completed_at: Some(3000),
                error_code: Some("command_failed".to_string()),
                error_detail: Some("lint error on line 42".to_string()),
            },
        ]));

        let msg = list_tasks_snapshot_message(&history).await;
        let ServerMessage::TasksSnapshot { tasks } = msg else {
            panic!("expected tasks snapshot");
        };

        // 按 started_at desc 排序 → fail(2000) 排前
        let fail_task = &tasks[0];
        assert_eq!(fail_task.task_id, "fail");
        assert_eq!(fail_task.duration_ms, Some(1000));
        assert_eq!(fail_task.error_code.as_deref(), Some("command_failed"));
        assert_eq!(
            fail_task.error_detail.as_deref(),
            Some("lint error on line 42")
        );
        assert!(fail_task.retryable);

        let ok_task = &tasks[1];
        assert_eq!(ok_task.task_id, "ok");
        assert_eq!(ok_task.duration_ms, Some(4000));
        assert!(ok_task.error_code.is_none());
        assert!(!ok_task.retryable);
    }

    #[test]
    fn is_retryable_logic() {
        assert!(is_retryable("project_command", "failed"));
        assert!(!is_retryable("project_command", "completed"));
        assert!(!is_retryable("ai_commit", "failed"));
        assert!(!is_retryable("ai_merge", "failed"));
    }

    #[test]
    fn compute_duration_ms_logic() {
        assert_eq!(compute_duration_ms(1000, Some(5000)), Some(4000));
        assert_eq!(compute_duration_ms(1000, None), None);
        assert_eq!(compute_duration_ms(5000, Some(1000)), None); // negative
    }

    /// 多工作区隔离：来自不同 project/workspace 的任务快照排序互不干扰，
    /// 按 started_at desc 全局排序后仍能通过 project+workspace 字段区分归属。
    #[tokio::test]
    async fn task_snapshot_multi_workspace_isolation() {
        let history: SharedTaskHistory = Arc::new(Mutex::new(vec![
            TaskHistoryEntry {
                task_id: "t1".to_string(),
                project: "proj-a".to_string(),
                workspace: "ws1".to_string(),
                task_type: "project_command".to_string(),
                command_id: None,
                title: "build-a".to_string(),
                status: "completed".to_string(),
                message: None,
                started_at: 100,
                completed_at: Some(200),
                error_code: None,
                error_detail: None,
            },
            TaskHistoryEntry {
                task_id: "t2".to_string(),
                project: "proj-b".to_string(),
                workspace: "ws2".to_string(),
                task_type: "project_command".to_string(),
                command_id: None,
                title: "build-b".to_string(),
                status: "failed".to_string(),
                message: Some("err".to_string()),
                started_at: 300,
                completed_at: Some(400),
                error_code: Some("exit_nonzero".to_string()),
                error_detail: None,
            },
            TaskHistoryEntry {
                task_id: "t3".to_string(),
                project: "proj-a".to_string(),
                workspace: "ws1".to_string(),
                task_type: "project_command".to_string(),
                command_id: None,
                title: "lint-a".to_string(),
                status: "running".to_string(),
                message: None,
                started_at: 500,
                completed_at: None,
                error_code: None,
                error_detail: None,
            },
        ]));

        let msg = list_tasks_snapshot_message(&history).await;
        let ServerMessage::TasksSnapshot { tasks } = msg else {
            panic!("expected tasks snapshot");
        };

        // 全局按 started_at desc 排序：t3(500) > t2(300) > t1(100)
        assert_eq!(tasks.len(), 3);
        assert_eq!(tasks[0].task_id, "t3");
        assert_eq!(tasks[1].task_id, "t2");
        assert_eq!(tasks[2].task_id, "t1");

        // 归属不应串台
        assert_eq!(tasks[0].project, "proj-a");
        assert_eq!(tasks[0].workspace, "ws1");
        assert_eq!(tasks[1].project, "proj-b");
        assert_eq!(tasks[1].workspace, "ws2");
        assert_eq!(tasks[2].project, "proj-a");
        assert_eq!(tasks[2].workspace, "ws1");
    }

    /// 稳定排序：相同 started_at 的任务按 task_id 升序排列
    #[tokio::test]
    async fn task_snapshot_stable_sort_on_same_started_at() {
        let history: SharedTaskHistory = Arc::new(Mutex::new(vec![
            TaskHistoryEntry {
                task_id: "zzz".to_string(),
                project: "p".to_string(),
                workspace: "w".to_string(),
                task_type: "project_command".to_string(),
                command_id: None,
                title: "z".to_string(),
                status: "running".to_string(),
                message: None,
                started_at: 1000,
                completed_at: None,
                error_code: None,
                error_detail: None,
            },
            TaskHistoryEntry {
                task_id: "aaa".to_string(),
                project: "p".to_string(),
                workspace: "w".to_string(),
                task_type: "project_command".to_string(),
                command_id: None,
                title: "a".to_string(),
                status: "running".to_string(),
                message: None,
                started_at: 1000,
                completed_at: None,
                error_code: None,
                error_detail: None,
            },
        ]));

        let msg = list_tasks_snapshot_message(&history).await;
        let ServerMessage::TasksSnapshot { tasks } = msg else {
            panic!("expected tasks snapshot");
        };

        // 同一 started_at 按 task_id asc
        assert_eq!(tasks[0].task_id, "aaa");
        assert_eq!(tasks[1].task_id, "zzz");
    }

    /// 运行中任务的 duration_ms 应为 None（Core 只在完成时计算耗时）
    #[tokio::test]
    async fn running_task_has_no_duration() {
        let history: SharedTaskHistory = Arc::new(Mutex::new(vec![TaskHistoryEntry {
            task_id: "r1".to_string(),
            project: "p".to_string(),
            workspace: "w".to_string(),
            task_type: "project_command".to_string(),
            command_id: None,
            title: "running-task".to_string(),
            status: "running".to_string(),
            message: None,
            started_at: 1000,
            completed_at: None,
            error_code: None,
            error_detail: None,
        }]));

        let msg = list_tasks_snapshot_message(&history).await;
        let ServerMessage::TasksSnapshot { tasks } = msg else {
            panic!("expected tasks snapshot");
        };

        assert_eq!(tasks[0].duration_ms, None, "运行中任务不应有 duration_ms");
        assert!(!tasks[0].retryable, "运行中任务不可重试");
    }

    /// ai_commit / ai_merge 失败时不可重试，仅 project_command 失败可重试
    #[test]
    fn non_project_command_failures_not_retryable() {
        assert!(!is_retryable("ai_commit", "failed"));
        assert!(!is_retryable("ai_merge", "failed"));
        assert!(!is_retryable("project_command", "running"));
        assert!(!is_retryable("project_command", "completed"));
        assert!(is_retryable("project_command", "failed"));
    }

    /// 诊断字段透传：error_code 和 error_detail 在快照中完整保留
    #[tokio::test]
    async fn error_fields_propagated_in_snapshot() {
        let history: SharedTaskHistory = Arc::new(Mutex::new(vec![TaskHistoryEntry {
            task_id: "e1".to_string(),
            project: "p".to_string(),
            workspace: "w".to_string(),
            task_type: "project_command".to_string(),
            command_id: Some("cmd-x".to_string()),
            title: "failing-task".to_string(),
            status: "failed".to_string(),
            message: Some("exit code 127".to_string()),
            started_at: 5000,
            completed_at: Some(6000),
            error_code: Some("command_not_found".to_string()),
            error_detail: Some("line 1: foo: command not found\nline 2: details".to_string()),
        }]));

        let msg = list_tasks_snapshot_message(&history).await;
        let ServerMessage::TasksSnapshot { tasks } = msg else {
            panic!("expected tasks snapshot");
        };

        let t = &tasks[0];
        assert_eq!(t.error_code.as_deref(), Some("command_not_found"));
        assert!(t
            .error_detail
            .as_ref()
            .unwrap()
            .contains("command not found"));
        assert_eq!(t.duration_ms, Some(1000));
        assert!(t.retryable);
    }
}
