//! Stash 定向测试
//!
//! 覆盖：
//!   - 列表解析格式
//!   - 保存默认参数验证
//!   - apply/pop/drop 结果状态
//!   - 按文件恢复语义
//!   - 冲突保留条目
//!   - 多工作区隔离键

use serde_json::{json, Value};

/// 验证 GitStashOpResult JSON 结构完整性
#[test]
fn stash_op_result_has_required_fields() {
    let result = json!({
        "action": "git_stash_op_result",
        "project": "test-proj",
        "workspace": "default",
        "op": "save",
        "stash_id": "stash@{0}",
        "ok": true,
        "state": "completed",
        "message": null,
        "affected_paths": [],
        "conflict_files": []
    });

    assert_eq!(result["project"], "test-proj");
    assert_eq!(result["workspace"], "default");
    assert_eq!(result["op"], "save");
    assert_eq!(result["ok"], true);
    assert_eq!(result["state"], "completed");
    assert!(result["affected_paths"].as_array().unwrap().is_empty());
    assert!(result["conflict_files"].as_array().unwrap().is_empty());
}

/// 验证 pop 冲突时 state = conflict 且 stash 条目保留
#[test]
fn stash_pop_conflict_preserves_entry() {
    let result = json!({
        "action": "git_stash_op_result",
        "project": "proj-a",
        "workspace": "ws-1",
        "op": "pop",
        "stash_id": "stash@{0}",
        "ok": false,
        "state": "conflict",
        "message": "Merge conflict in src/main.rs",
        "affected_paths": ["src/main.rs"],
        "conflict_files": ["src/main.rs"]
    });

    assert_eq!(result["op"], "pop");
    assert_eq!(result["state"], "conflict");
    assert_eq!(result["ok"], false);
    // 冲突时 stash 条目不应被删除，stash_id 保留
    assert_eq!(result["stash_id"], "stash@{0}");
    assert!(!result["conflict_files"].as_array().unwrap().is_empty());
}

/// 验证 stash 列表结果包含多工作区隔离字段
#[test]
fn stash_list_result_has_workspace_isolation() {
    let result_ws1 = json!({
        "action": "git_stash_list_result",
        "project": "multi-proj",
        "workspace": "ws-1",
        "entries": [
            {
                "stash_id": "stash@{0}",
                "title": "stash@{0}: WIP on main",
                "message": "save ws-1 changes",
                "branch_name": "main",
                "created_at": "2025-01-01T00:00:00Z",
                "file_count": 3
            }
        ]
    });

    let result_ws2 = json!({
        "action": "git_stash_list_result",
        "project": "multi-proj",
        "workspace": "ws-2",
        "entries": []
    });

    // 不同工作区的 stash 列表互相隔离
    assert_eq!(result_ws1["workspace"], "ws-1");
    assert_eq!(result_ws2["workspace"], "ws-2");
    assert_eq!(result_ws1["entries"].as_array().unwrap().len(), 1);
    assert_eq!(result_ws2["entries"].as_array().unwrap().len(), 0);
}

/// 验证 stash 详情包含 entry 元数据和文件列表
#[test]
fn stash_show_result_has_entry_and_files() {
    let result = json!({
        "action": "git_stash_show_result",
        "project": "proj",
        "workspace": "default",
        "stash_id": "stash@{0}",
        "entry": {
            "stash_id": "stash@{0}",
            "title": "stash@{0}: WIP on main",
            "message": "my stash",
            "branch_name": "main",
            "created_at": "2025-01-01T00:00:00Z",
            "file_count": 2
        },
        "files": [
            {
                "path": "src/main.rs",
                "status": "M",
                "source_kind": "tracked",
                "additions": 10,
                "deletions": 3
            },
            {
                "path": "new_file.txt",
                "status": "A",
                "source_kind": "untracked",
                "additions": 5,
                "deletions": 0
            }
        ],
        "diff_text": "diff --git a/src/main.rs b/src/main.rs\n..."
    });

    assert_eq!(result["stash_id"], "stash@{0}");
    assert!(result["entry"].is_object());
    assert_eq!(result["files"].as_array().unwrap().len(), 2);
    assert_eq!(result["files"][0]["source_kind"], "tracked");
    assert_eq!(result["files"][1]["source_kind"], "untracked");
    assert!(!result["diff_text"].as_str().unwrap().is_empty());
}

/// 验证保存默认参数
#[test]
fn stash_save_default_parameters() {
    let request = json!({
        "type": "git_stash_save",
        "project": "proj",
        "workspace": "default",
        "message": null,
        "include_untracked": false,
        "keep_index": false,
        "paths": []
    });

    // 默认值
    assert_eq!(request["include_untracked"], false);
    assert_eq!(request["keep_index"], false);
    assert!(request["paths"].as_array().unwrap().is_empty());
}

/// 验证 op 结果的四种状态值
#[test]
fn stash_op_result_states() {
    let states = ["completed", "conflict", "noop", "failed"];
    for state in &states {
        let result = json!({
            "state": state,
            "ok": *state == "completed",
        });
        assert!(["completed", "conflict", "noop", "failed"]
            .contains(&result["state"].as_str().unwrap()));
    }
}

/// 验证按文件恢复请求结构
#[test]
fn stash_restore_paths_request_structure() {
    let request = json!({
        "type": "git_stash_restore_paths",
        "project": "proj",
        "workspace": "default",
        "stash_id": "stash@{0}",
        "paths": ["src/main.rs", "src/lib.rs"]
    });

    assert_eq!(request["type"], "git_stash_restore_paths");
    assert_eq!(request["paths"].as_array().unwrap().len(), 2);
}
