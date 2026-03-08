//! 工作区缓存 Benchmark Smoke Test
//!
//! 这不是真正的 benchmark，而是在 `cargo test` 路径下用于验证：
//! 1. Benchmark 套件能够正常编译和执行（不会 panic）
//! 2. 核心热点路径的指标数据产出符合预期（数量级校验）
//! 3. 多项目/多工作区场景下指标不产生交叉污染
//!
//! 真正的性能基准测试请运行：
//! ```bash
//! cargo bench --manifest-path core/Cargo.toml workspace_cache -- --noplot
//! ```

use tidyflow_core::workspace::cache_metrics::{
    self, WorkspaceCacheSnapshot, REBUILD_BUDGET_THRESHOLD,
};

/// 辅助：构造唯一的 root path（避免跨测试污染全局注册表）
fn unique_root(test_name: &str, idx: usize) -> String {
    format!("/tmp/smoke_bench_{}_{}", test_name, idx)
}

#[test]
fn file_cache_rebuild_hot_path_does_not_panic() {
    let root = unique_root("rebuild_hot", 1);
    cache_metrics::clear_metrics_for_path(&root);

    for i in 0..100 {
        cache_metrics::record_file_cache_rebuild(&root, i * 10 + 50);
    }

    let snap = WorkspaceCacheSnapshot::from_counters("p", "w", &root);
    assert_eq!(snap.file_cache.rebuild_count, 100);
    assert!(snap.budget_exceeded, "rebuild_count=100 >> REBUILD_BUDGET_THRESHOLD={}", REBUILD_BUDGET_THRESHOLD);
}

#[test]
fn file_cache_incremental_hot_path_does_not_panic() {
    let root = unique_root("incremental_hot", 2);
    cache_metrics::clear_metrics_for_path(&root);

    cache_metrics::record_file_cache_rebuild(&root, 500);
    for _ in 0..50 {
        cache_metrics::record_file_cache_incremental_update(&root, 501);
    }

    let snap = WorkspaceCacheSnapshot::from_counters("p", "ws_incr", &root);
    assert_eq!(snap.file_cache.rebuild_count, 1);
    assert_eq!(snap.file_cache.incremental_update_count, 50);
}

#[test]
fn git_cache_hit_miss_hot_path_does_not_panic() {
    let root = unique_root("git_hit_miss", 3);
    cache_metrics::clear_metrics_for_path(&root);

    for _ in 0..200 {
        cache_metrics::record_git_cache_hit(&root);
    }
    for _ in 0..10 {
        cache_metrics::record_git_cache_miss(&root);
        cache_metrics::record_git_cache_rebuild(&root, 15);
    }

    let snap = WorkspaceCacheSnapshot::from_counters("p", "ws_git", &root);
    assert_eq!(snap.git_cache.hit_count, 200);
    assert_eq!(snap.git_cache.miss_count, 10);
    assert_eq!(snap.git_cache.rebuild_count, 10);
}

#[test]
fn snapshot_multi_project_does_not_panic() {
    let num_projects = 3;
    let ws_per_project = 4;

    let mut entries: Vec<(String, String, String)> = Vec::new();
    for p in 0..num_projects {
        let project = format!("smoke_mp_project_{}", p);
        entries.push((
            project.clone(),
            "default".to_string(),
            unique_root(&format!("mp_{}_default", p), p * 100),
        ));
        for w in 0..ws_per_project {
            entries.push((
                project.clone(),
                format!("ws_{}", w),
                unique_root(&format!("mp_{}_{}", p, w), p * 100 + w + 1),
            ));
        }
    }

    // 初始化指标
    for (_, _, root) in &entries {
        cache_metrics::clear_metrics_for_path(root);
        cache_metrics::record_file_cache_rebuild(root, 100);
        cache_metrics::record_git_cache_hit(root);
    }

    // 构建快照，验证每个工作区都能独立产出快照
    for (project, workspace, root) in &entries {
        let snap = WorkspaceCacheSnapshot::from_counters(project, workspace, root);
        assert_eq!(snap.project, *project);
        assert_eq!(snap.workspace, *workspace);
        assert_eq!(snap.file_cache.rebuild_count, 1, "每个工作区重建次数应为 1");
        assert_eq!(snap.git_cache.hit_count, 1, "每个工作区 git hit 应为 1");
    }
}

#[test]
fn eviction_scan_does_not_panic() {
    let entries: Vec<String> = (0..12)
        .map(|i| unique_root("eviction_scan", i))
        .collect();

    for root in &entries {
        cache_metrics::clear_metrics_for_path(root);
    }

    for root in &entries {
        cache_metrics::record_file_cache_eviction(root, "ttl_expired");
        cache_metrics::record_git_cache_eviction(root, "ttl_expired");
    }

    for (i, root) in entries.iter().enumerate() {
        let snap = WorkspaceCacheSnapshot::from_counters("p", &format!("ws_{}", i), root);
        assert_eq!(snap.file_cache.eviction_count, 1);
        assert_eq!(snap.git_cache.eviction_count, 1);
        assert_eq!(
            snap.last_eviction_reason.as_deref(),
            Some("ttl_expired"),
            "淘汰原因应由 Core 记录"
        );
    }
}

#[test]
fn same_workspace_name_different_projects_metrics_are_isolated() {
    // 同名工作区 ws1 在不同项目中应完全独立
    let root_a = unique_root("iso_project_a_ws1", 999);
    let root_b = unique_root("iso_project_b_ws1", 1000);
    cache_metrics::clear_metrics_for_path(&root_a);
    cache_metrics::clear_metrics_for_path(&root_b);

    // project_a/ws1：100 次命中，3 次重建
    for _ in 0..100 {
        cache_metrics::record_file_cache_hit(&root_a);
    }
    for _ in 0..3 {
        cache_metrics::record_file_cache_rebuild(&root_a, 100);
    }

    // project_b/ws1：只有 5 次命中，0 次重建
    for _ in 0..5 {
        cache_metrics::record_file_cache_hit(&root_b);
    }

    let snap_a = WorkspaceCacheSnapshot::from_counters("project_a", "ws1", &root_a);
    let snap_b = WorkspaceCacheSnapshot::from_counters("project_b", "ws1", &root_b);

    assert_eq!(snap_a.file_cache.hit_count, 100, "project_a/ws1 命中数不匹配");
    assert_eq!(snap_a.file_cache.rebuild_count, 3, "project_a/ws1 重建数不匹配");
    assert_eq!(snap_b.file_cache.hit_count, 5, "project_b/ws1 命中数不匹配");
    assert_eq!(snap_b.file_cache.rebuild_count, 0, "project_b/ws1 不应有重建记录");

    // 核心：两个同名工作区指标完全独立
    assert_ne!(
        snap_a.file_cache.hit_count,
        snap_b.file_cache.hit_count,
        "同名工作区指标不应相同，必须按 (project, workspace) 隔离"
    );
}
