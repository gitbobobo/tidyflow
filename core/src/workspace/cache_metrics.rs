//! 工作区缓存可观测性指标模型
//!
//! ## 设计原则
//!
//! - 所有指标按 `(project, workspace)` 唯一键隔离建模，兼容多项目同名工作区与 `default` 虚拟工作区。
//! - 底层采样以 workspace root path 为粒度（与现有缓存键对齐），快照时通过路径映射补全 project/workspace 标签。
//! - 资源预算判定和淘汰原因由 Core 统一计算，客户端只消费快照结果。

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};
use std::time::Instant;

// ============================================================================
// 内部指标计数器（以 root path 为键）
// ============================================================================

/// 文件索引缓存的可变计数器（内部使用）
#[derive(Debug, Default)]
struct FileCacheCounters {
    hit: u64,
    miss: u64,
    rebuild: u64,
    incremental_update: u64,
    eviction: u64,
    item_count: usize,
    last_eviction_reason: Option<String>,
    last_updated: Option<Instant>,
}

/// Git 状态缓存的可变计数器（内部使用）
#[derive(Debug, Default)]
struct GitCacheCounters {
    hit: u64,
    miss: u64,
    rebuild: u64,
    eviction: u64,
    item_count: usize,
    last_eviction_reason: Option<String>,
    last_updated: Option<Instant>,
}

/// 全局文件缓存指标注册表（以 workspace root path 为键）
static FILE_CACHE_METRICS: LazyLock<Mutex<HashMap<String, FileCacheCounters>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// 全局 Git 缓存指标注册表（以 workspace root path 为键）
static GIT_CACHE_METRICS: LazyLock<Mutex<HashMap<String, GitCacheCounters>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// 工作区最近淘汰原因（由 file 或 git 任一淘汰事件更新，按发生先后覆盖）
static WORKSPACE_LAST_EVICTION: LazyLock<Mutex<HashMap<String, String>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

// ============================================================================
// 文件缓存指标采样入口
// ============================================================================

/// 记录文件索引缓存命中
pub fn record_file_cache_hit(root_path: &str) {
    if let Ok(mut m) = FILE_CACHE_METRICS.lock() {
        let c = m.entry(root_path.to_string()).or_default();
        c.hit = c.hit.saturating_add(1);
        c.last_updated = Some(Instant::now());
    }
}

/// 记录文件索引缓存未命中（将触发全量重建）
pub fn record_file_cache_miss(root_path: &str) {
    if let Ok(mut m) = FILE_CACHE_METRICS.lock() {
        let c = m.entry(root_path.to_string()).or_default();
        c.miss = c.miss.saturating_add(1);
        c.last_updated = Some(Instant::now());
    }
}

/// 记录文件索引缓存全量重建完成
pub fn record_file_cache_rebuild(root_path: &str, item_count: usize) {
    if let Ok(mut m) = FILE_CACHE_METRICS.lock() {
        let c = m.entry(root_path.to_string()).or_default();
        c.rebuild = c.rebuild.saturating_add(1);
        c.item_count = item_count;
        c.last_updated = Some(Instant::now());
    }
}

/// 记录文件索引缓存增量更新
pub fn record_file_cache_incremental_update(root_path: &str, new_item_count: usize) {
    if let Ok(mut m) = FILE_CACHE_METRICS.lock() {
        let c = m.entry(root_path.to_string()).or_default();
        c.incremental_update = c.incremental_update.saturating_add(1);
        c.item_count = new_item_count;
        c.last_updated = Some(Instant::now());
    }
}

/// 记录文件索引缓存淘汰（TTL 过期或主动驱逐）
pub fn record_file_cache_eviction(root_path: &str, reason: &str) {
    if let Ok(mut m) = FILE_CACHE_METRICS.lock() {
        let c = m.entry(root_path.to_string()).or_default();
        c.eviction = c.eviction.saturating_add(1);
        c.last_eviction_reason = Some(reason.to_string());
        c.last_updated = Some(Instant::now());
    }
    // 同步更新工作区级别最新淘汰原因（任意缓存淘汰都覆盖此值）
    if let Ok(mut m) = WORKSPACE_LAST_EVICTION.lock() {
        m.insert(root_path.to_string(), reason.to_string());
    }
}

// ============================================================================
// Git 缓存指标采样入口
// ============================================================================

/// 记录 Git 状态缓存命中
pub fn record_git_cache_hit(root_path: &str) {
    if let Ok(mut m) = GIT_CACHE_METRICS.lock() {
        let c = m.entry(root_path.to_string()).or_default();
        c.hit = c.hit.saturating_add(1);
        c.last_updated = Some(Instant::now());
    }
}

/// 记录 Git 状态缓存未命中（将触发重新查询）
pub fn record_git_cache_miss(root_path: &str) {
    if let Ok(mut m) = GIT_CACHE_METRICS.lock() {
        let c = m.entry(root_path.to_string()).or_default();
        c.miss = c.miss.saturating_add(1);
        c.last_updated = Some(Instant::now());
    }
}

/// 记录 Git 状态缓存重建完成
pub fn record_git_cache_rebuild(root_path: &str, item_count: usize) {
    if let Ok(mut m) = GIT_CACHE_METRICS.lock() {
        let c = m.entry(root_path.to_string()).or_default();
        c.rebuild = c.rebuild.saturating_add(1);
        c.item_count = item_count;
        c.last_updated = Some(Instant::now());
    }
}

/// 记录 Git 状态缓存淘汰（TTL 过期或主动驱逐）
pub fn record_git_cache_eviction(root_path: &str, reason: &str) {
    if let Ok(mut m) = GIT_CACHE_METRICS.lock() {
        let c = m.entry(root_path.to_string()).or_default();
        c.eviction = c.eviction.saturating_add(1);
        c.last_eviction_reason = Some(reason.to_string());
        c.last_updated = Some(Instant::now());
    }
    // 同步更新工作区级别最新淘汰原因
    if let Ok(mut m) = WORKSPACE_LAST_EVICTION.lock() {
        m.insert(root_path.to_string(), reason.to_string());
    }
}

// ============================================================================
// 快照输出类型（与协议模型对齐，供 system_snapshot 消费）
// ============================================================================

/// 文件缓存指标快照（只读，用于协议输出）
#[derive(Debug, Clone, Default)]
pub struct FileCacheMetricsSample {
    pub hit_count: u64,
    pub miss_count: u64,
    pub rebuild_count: u64,
    pub incremental_update_count: u64,
    pub eviction_count: u64,
    pub item_count: usize,
    pub last_eviction_reason: Option<String>,
}

/// Git 缓存指标快照（只读，用于协议输出）
#[derive(Debug, Clone, Default)]
pub struct GitCacheMetricsSample {
    pub hit_count: u64,
    pub miss_count: u64,
    pub rebuild_count: u64,
    pub eviction_count: u64,
    pub item_count: usize,
    pub last_eviction_reason: Option<String>,
}

/// 工作区级缓存可观测性快照，按 `(project, workspace)` 标识
#[derive(Debug, Clone)]
pub struct WorkspaceCacheSnapshot {
    pub project: String,
    pub workspace: String,
    /// 该工作区 root path（用于调试追踪）
    pub root_path: String,
    pub file_cache: FileCacheMetricsSample,
    pub git_cache: GitCacheMetricsSample,
    /// 是否超出资源预算（file+git 总重建次数超过 REBUILD_BUDGET_THRESHOLD）
    pub budget_exceeded: bool,
    /// 最近一次淘汰原因（文件缓存或 Git 缓存，取最新发生的）
    pub last_eviction_reason: Option<String>,
}

/// 单工作区重建次数超过此阈值时视为预算异常（可作为预警线）
pub const REBUILD_BUDGET_THRESHOLD: u64 = 10;

impl WorkspaceCacheSnapshot {
    /// 从内部计数器构建快照，由 Core 调用端传入 project/workspace/root_path 三元组。
    pub fn from_counters(project: &str, workspace: &str, root_path: &str) -> Self {
        let file_sample = FILE_CACHE_METRICS
            .lock()
            .ok()
            .and_then(|m| {
                m.get(root_path).map(|c| FileCacheMetricsSample {
                    hit_count: c.hit,
                    miss_count: c.miss,
                    rebuild_count: c.rebuild,
                    incremental_update_count: c.incremental_update,
                    eviction_count: c.eviction,
                    item_count: c.item_count,
                    last_eviction_reason: c.last_eviction_reason.clone(),
                })
            })
            .unwrap_or_default();

        let git_sample = GIT_CACHE_METRICS
            .lock()
            .ok()
            .and_then(|m| {
                m.get(root_path).map(|c| GitCacheMetricsSample {
                    hit_count: c.hit,
                    miss_count: c.miss,
                    rebuild_count: c.rebuild,
                    eviction_count: c.eviction,
                    item_count: c.item_count,
                    last_eviction_reason: c.last_eviction_reason.clone(),
                })
            })
            .unwrap_or_default();

        let total_rebuilds = file_sample
            .rebuild_count
            .saturating_add(git_sample.rebuild_count);
        let budget_exceeded = total_rebuilds >= REBUILD_BUDGET_THRESHOLD;

        // 从工作区级别共享淘汰原因中取最新值（由 file 或 git 任一淘汰事件覆盖更新）
        let last_eviction_reason = WORKSPACE_LAST_EVICTION
            .lock()
            .ok()
            .and_then(|m| m.get(root_path).cloned());

        WorkspaceCacheSnapshot {
            project: project.to_string(),
            workspace: workspace.to_string(),
            root_path: root_path.to_string(),
            file_cache: file_sample,
            git_cache: git_sample,
            budget_exceeded,
            last_eviction_reason,
        }
    }
}

/// 清除指定 root path 对应的全部缓存指标（工作区删除或重置时调用）
pub fn clear_metrics_for_path(root_path: &str) {
    if let Ok(mut m) = FILE_CACHE_METRICS.lock() {
        m.remove(root_path);
    }
    if let Ok(mut m) = GIT_CACHE_METRICS.lock() {
        m.remove(root_path);
    }
    if let Ok(mut m) = WORKSPACE_LAST_EVICTION.lock() {
        m.remove(root_path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root(id: &str) -> String {
        format!("/tmp/unit_test_cache_metrics/{id}")
    }

    fn clean(id: &str) -> String {
        let path = root(id);
        clear_metrics_for_path(&path);
        path
    }

    #[test]
    fn file_cache_counters_increment_correctly() {
        let path = "/tmp/test_project_alpha";
        // 重置，避免跨测试污染（路径唯一即可）
        clear_metrics_for_path(path);

        record_file_cache_miss(path);
        record_file_cache_rebuild(path, 100);
        record_file_cache_hit(path);
        record_file_cache_hit(path);
        record_file_cache_incremental_update(path, 101);

        let snap = WorkspaceCacheSnapshot::from_counters("proj", "alpha", path);
        assert_eq!(snap.file_cache.hit_count, 2);
        assert_eq!(snap.file_cache.miss_count, 1);
        assert_eq!(snap.file_cache.rebuild_count, 1);
        assert_eq!(snap.file_cache.incremental_update_count, 1);
        assert_eq!(snap.file_cache.item_count, 101);
    }

    #[test]
    fn git_cache_counters_increment_correctly() {
        let path = "/tmp/test_project_git_beta";
        clear_metrics_for_path(path);

        record_git_cache_miss(path);
        record_git_cache_rebuild(path, 5);
        record_git_cache_hit(path);
        record_git_cache_eviction(path, "ttl_expired");

        let snap = WorkspaceCacheSnapshot::from_counters("proj", "beta", path);
        assert_eq!(snap.git_cache.hit_count, 1);
        assert_eq!(snap.git_cache.miss_count, 1);
        assert_eq!(snap.git_cache.rebuild_count, 1);
        assert_eq!(snap.git_cache.eviction_count, 1);
        assert_eq!(
            snap.git_cache.last_eviction_reason.as_deref(),
            Some("ttl_expired")
        );
    }

    #[test]
    fn budget_exceeded_when_rebuilds_above_threshold() {
        let path = "/tmp/test_budget_exceeded";
        clear_metrics_for_path(path);

        for _ in 0..=REBUILD_BUDGET_THRESHOLD {
            record_file_cache_rebuild(path, 10);
        }

        let snap = WorkspaceCacheSnapshot::from_counters("p", "w", path);
        assert!(
            snap.budget_exceeded,
            "should be budget_exceeded when rebuilds > threshold"
        );
    }

    #[test]
    fn metrics_isolated_per_path() {
        let path_a = "/tmp/iso_project_a_ws1";
        let path_b = "/tmp/iso_project_b_ws1"; // 同名工作区，不同项目
        clear_metrics_for_path(path_a);
        clear_metrics_for_path(path_b);

        record_file_cache_hit(path_a);
        record_file_cache_hit(path_a);
        record_file_cache_miss(path_b);

        let snap_a = WorkspaceCacheSnapshot::from_counters("project_a", "ws1", path_a);
        let snap_b = WorkspaceCacheSnapshot::from_counters("project_b", "ws1", path_b);

        assert_eq!(snap_a.file_cache.hit_count, 2);
        assert_eq!(snap_a.file_cache.miss_count, 0);
        assert_eq!(snap_b.file_cache.hit_count, 0);
        assert_eq!(snap_b.file_cache.miss_count, 1);
    }

    #[test]
    fn budget_not_exceeded_below_threshold() {
        let path = clean("budget_below");
        for _ in 0..(REBUILD_BUDGET_THRESHOLD - 1) {
            record_file_cache_rebuild(&path, 50);
        }

        let snap = WorkspaceCacheSnapshot::from_counters("p", "w", &path);
        assert!(!snap.budget_exceeded);
    }

    #[test]
    fn budget_exceeded_by_combined_file_and_git_rebuilds() {
        let path = clean("budget_combined");
        let half = REBUILD_BUDGET_THRESHOLD / 2;
        for _ in 0..=half {
            record_file_cache_rebuild(&path, 50);
            record_git_cache_rebuild(&path, 20);
        }

        let snap = WorkspaceCacheSnapshot::from_counters("p", "w", &path);
        assert!(snap.budget_exceeded);
    }

    #[test]
    fn eviction_reason_propagates_and_overwrites() {
        let path = clean("evict_reason");
        record_file_cache_eviction(&path, "memory_pressure");
        record_git_cache_eviction(&path, "invalidated");

        let snap = WorkspaceCacheSnapshot::from_counters("p", "w", &path);
        assert_eq!(snap.last_eviction_reason.as_deref(), Some("invalidated"));
    }

    #[test]
    fn clear_metrics_resets_all_counters() {
        let path = clean("clear_test");
        record_file_cache_hit(&path);
        record_file_cache_rebuild(&path, 50);
        record_git_cache_hit(&path);
        clear_metrics_for_path(&path);

        let snap = WorkspaceCacheSnapshot::from_counters("p", "w", &path);
        assert_eq!(snap.file_cache.hit_count, 0);
        assert_eq!(snap.file_cache.rebuild_count, 0);
        assert_eq!(snap.git_cache.hit_count, 0);
        assert!(!snap.budget_exceeded);
    }

    #[test]
    fn file_cache_rebuild_hot_path_does_not_panic() {
        let path = clean("rebuild_hot");
        for i in 0..100 {
            record_file_cache_rebuild(&path, i * 10 + 50);
        }

        let snap = WorkspaceCacheSnapshot::from_counters("p", "w", &path);
        assert_eq!(snap.file_cache.rebuild_count, 100);
        assert!(snap.budget_exceeded);
    }

    #[test]
    fn file_cache_incremental_hot_path_does_not_panic() {
        let path = clean("incremental_hot");
        record_file_cache_rebuild(&path, 500);
        for _ in 0..50 {
            record_file_cache_incremental_update(&path, 501);
        }

        let snap = WorkspaceCacheSnapshot::from_counters("p", "ws_incr", &path);
        assert_eq!(snap.file_cache.rebuild_count, 1);
        assert_eq!(snap.file_cache.incremental_update_count, 50);
    }

    #[test]
    fn git_cache_hit_miss_hot_path_does_not_panic() {
        let path = clean("git_hit_miss");
        for _ in 0..200 {
            record_git_cache_hit(&path);
        }
        for _ in 0..10 {
            record_git_cache_miss(&path);
            record_git_cache_rebuild(&path, 15);
        }

        let snap = WorkspaceCacheSnapshot::from_counters("p", "ws_git", &path);
        assert_eq!(snap.git_cache.hit_count, 200);
        assert_eq!(snap.git_cache.miss_count, 10);
        assert_eq!(snap.git_cache.rebuild_count, 10);
    }

    #[test]
    fn snapshot_multi_project_does_not_cross_pollute() {
        let num_projects = 3;
        let ws_per_project = 4;

        let mut entries: Vec<(String, String, String)> = Vec::new();
        for p in 0..num_projects {
            let project = format!("smoke_mp_project_{p}");
            entries.push((
                project.clone(),
                "default".to_string(),
                clean(&format!("mp_{p}_default")),
            ));
            for w in 0..ws_per_project {
                entries.push((
                    project.clone(),
                    format!("ws_{w}"),
                    clean(&format!("mp_{p}_{w}")),
                ));
            }
        }

        for (_, _, root_path) in &entries {
            record_file_cache_rebuild(root_path, 100);
            record_git_cache_hit(root_path);
        }

        for (project, workspace, root_path) in &entries {
            let snap = WorkspaceCacheSnapshot::from_counters(project, workspace, root_path);
            assert_eq!(snap.project, *project);
            assert_eq!(snap.workspace, *workspace);
            assert_eq!(snap.file_cache.rebuild_count, 1);
            assert_eq!(snap.git_cache.hit_count, 1);
        }
    }

    #[test]
    fn eviction_scan_does_not_panic() {
        let entries: Vec<String> = (0..12)
            .map(|i| clean(&format!("eviction_scan_{i}")))
            .collect();

        for path in &entries {
            record_file_cache_eviction(path, "ttl_expired");
            record_git_cache_eviction(path, "ttl_expired");
        }

        for (i, path) in entries.iter().enumerate() {
            let snap = WorkspaceCacheSnapshot::from_counters("p", &format!("ws_{i}"), path);
            assert_eq!(snap.file_cache.eviction_count, 1);
            assert_eq!(snap.git_cache.eviction_count, 1);
            assert_eq!(snap.last_eviction_reason.as_deref(), Some("ttl_expired"));
        }
    }

    #[test]
    fn same_workspace_name_different_projects_metrics_are_isolated() {
        let root_a = clean("iso_project_a_ws1");
        let root_b = clean("iso_project_b_ws1");

        for _ in 0..100 {
            record_file_cache_hit(&root_a);
        }
        for _ in 0..3 {
            record_file_cache_rebuild(&root_a, 100);
        }
        for _ in 0..5 {
            record_file_cache_hit(&root_b);
        }

        let snap_a = WorkspaceCacheSnapshot::from_counters("project_a", "ws1", &root_a);
        let snap_b = WorkspaceCacheSnapshot::from_counters("project_b", "ws1", &root_b);

        assert_eq!(snap_a.file_cache.hit_count, 100);
        assert_eq!(snap_a.file_cache.rebuild_count, 3);
        assert_eq!(snap_b.file_cache.hit_count, 5);
        assert_eq!(snap_b.file_cache.rebuild_count, 0);
        assert_ne!(snap_a.file_cache.hit_count, snap_b.file_cache.hit_count);
    }

    #[test]
    fn resource_guard_detects_rebuild_storm_and_reset() {
        let path = clean("guard_reset");
        for _ in 0..REBUILD_BUDGET_THRESHOLD {
            record_file_cache_rebuild(&path, 30);
        }

        let snap_before = WorkspaceCacheSnapshot::from_counters("proj", "ws", &path);
        assert!(snap_before.budget_exceeded);

        clear_metrics_for_path(&path);
        let snap_after = WorkspaceCacheSnapshot::from_counters("proj", "ws", &path);
        assert!(!snap_after.budget_exceeded);
    }

    #[test]
    fn resource_guard_isolated_across_workspaces() {
        let hot = clean("guard_hot");
        let cold = clean("guard_cold");

        for _ in 0..REBUILD_BUDGET_THRESHOLD {
            record_file_cache_rebuild(&hot, 40);
        }
        record_file_cache_hit(&cold);

        let snap_hot = WorkspaceCacheSnapshot::from_counters("proj", "hot_ws", &hot);
        let snap_cold = WorkspaceCacheSnapshot::from_counters("proj", "cold_ws", &cold);

        assert!(snap_hot.budget_exceeded);
        assert!(!snap_cold.budget_exceeded);
    }

    #[test]
    fn resource_guard_detects_eviction_events() {
        let path = clean("guard_evict");
        record_file_cache_eviction(&path, "memory_limit");
        record_git_cache_eviction(&path, "ttl_expired");

        let snap = WorkspaceCacheSnapshot::from_counters("proj", "ws", &path);
        assert_eq!(snap.last_eviction_reason.as_deref(), Some("ttl_expired"));
        assert_eq!(snap.file_cache.eviction_count, 1);
        assert_eq!(snap.git_cache.eviction_count, 1);
    }

    #[test]
    fn inactive_workspace_does_not_trigger_resource_guard() {
        let path = clean("guard_inactive");
        for _ in 0..100 {
            record_file_cache_hit(&path);
            record_git_cache_hit(&path);
        }

        let snap = WorkspaceCacheSnapshot::from_counters("proj", "ws", &path);
        assert!(!snap.budget_exceeded);
    }
}
