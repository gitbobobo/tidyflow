//! 工作区缓存性能基准测试套件
//!
//! ## 覆盖场景
//! - 文件索引缓存重建（全量）
//! - 文件索引缓存增量更新
//! - Git 状态缓存 hit/miss
//! - 工作区缓存指标快照
//! - 多项目、多工作区并行路径
//!
//! ## 运行方式
//! ```bash
//! cargo bench --manifest-path core/Cargo.toml workspace_cache
//! ```

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use std::time::Duration;
use tidyflow_core::server::perf::{self as perf_counters, snapshot_perf_metrics};
use tidyflow_core::workspace::cache_metrics::{self, WorkspaceCacheSnapshot};

// ============================================================================
// 工具：多项目、多工作区测试场景构造器
// ============================================================================

struct BenchScenario {
    /// (project, workspace, root_path) 三元组列表
    entries: Vec<(String, String, String)>,
}

impl BenchScenario {
    /// 构造 n 个项目各有 m 个工作区的场景
    fn new_multi_project(num_projects: usize, workspaces_per_project: usize) -> Self {
        let mut entries = Vec::new();
        for p in 0..num_projects {
            let project = format!("bench_project_{}", p);
            // default 虚拟工作区
            entries.push((
                project.clone(),
                "default".to_string(),
                format!("/tmp/bench/{}/default", p),
            ));
            for w in 0..workspaces_per_project {
                let workspace = format!("workspace_{}", w);
                entries.push((
                    project.clone(),
                    workspace.clone(),
                    format!("/tmp/bench/{}/{}", p, w),
                ));
            }
        }
        Self { entries }
    }

    fn reset_metrics(&self) {
        for (_, _, root) in &self.entries {
            cache_metrics::clear_metrics_for_path(root);
        }
    }

    fn prime_file_cache_hits(&self, hit_count: u64) {
        for (_, _, root) in &self.entries {
            for _ in 0..hit_count {
                cache_metrics::record_file_cache_hit(root);
            }
        }
    }

    fn prime_git_cache_hits(&self, hit_count: u64) {
        for (_, _, root) in &self.entries {
            for _ in 0..hit_count {
                cache_metrics::record_git_cache_hit(root);
            }
        }
    }

    fn prime_rebuilds(&self, count: u64) {
        for (_, _, root) in &self.entries {
            for i in 0..count {
                cache_metrics::record_file_cache_rebuild(root, (i * 10 + 100) as usize);
            }
        }
    }
}

// ============================================================================
// Benchmark 1: 文件索引缓存重建指标记录（单工作区热路径）
// ============================================================================
fn bench_file_cache_rebuild(c: &mut Criterion) {
    let root = "/tmp/bench_single_rebuild/default";
    cache_metrics::clear_metrics_for_path(root);

    c.bench_function("workspace_cache/file_rebuild_single_ws", |b| {
        b.iter(|| {
            cache_metrics::record_file_cache_rebuild(black_box(root), black_box(850));
        })
    });
}

// ============================================================================
// Benchmark 2: 文件索引缓存增量更新（单工作区热路径）
// ============================================================================
fn bench_file_cache_incremental(c: &mut Criterion) {
    let root = "/tmp/bench_single_incremental/default";
    cache_metrics::clear_metrics_for_path(root);
    cache_metrics::record_file_cache_rebuild(root, 850);

    c.bench_function("workspace_cache/file_incremental_single_ws", |b| {
        b.iter(|| {
            cache_metrics::record_file_cache_incremental_update(black_box(root), black_box(851));
        })
    });
}

// ============================================================================
// Benchmark 3: 文件索引缓存 hit/miss（单工作区热路径）
// ============================================================================
fn bench_file_cache_hit_miss(c: &mut Criterion) {
    let root = "/tmp/bench_hit_miss/default";
    cache_metrics::clear_metrics_for_path(root);

    let mut group = c.benchmark_group("workspace_cache/file_hit_miss");
    group.bench_function("hit", |b| {
        b.iter(|| cache_metrics::record_file_cache_hit(black_box(root)))
    });
    group.bench_function("miss", |b| {
        b.iter(|| cache_metrics::record_file_cache_miss(black_box(root)))
    });
    group.finish();
}

// ============================================================================
// Benchmark 4: Git 状态缓存 hit/miss（单工作区热路径）
// ============================================================================
fn bench_git_cache_hit_miss(c: &mut Criterion) {
    let root = "/tmp/bench_git_hit_miss/default";
    cache_metrics::clear_metrics_for_path(root);

    let mut group = c.benchmark_group("workspace_cache/git_hit_miss");
    group.bench_function("hit", |b| {
        b.iter(|| cache_metrics::record_git_cache_hit(black_box(root)))
    });
    group.bench_function("miss", |b| {
        b.iter(|| cache_metrics::record_git_cache_miss(black_box(root)))
    });
    group.finish();
}

// ============================================================================
// Benchmark 5: 工作区缓存快照构建（多项目、多工作区）
// ============================================================================
fn bench_snapshot_multi_project(c: &mut Criterion) {
    let mut group = c.benchmark_group("workspace_cache/snapshot_multi_project");

    for (projects, ws_per_project) in [(1, 3), (3, 5), (5, 10)] {
        let scenario = BenchScenario::new_multi_project(projects, ws_per_project);
        scenario.reset_metrics();
        scenario.prime_file_cache_hits(50);
        scenario.prime_git_cache_hits(100);
        scenario.prime_rebuilds(3);

        let label = format!("{}proj_{}ws", projects, ws_per_project);
        group.bench_with_input(BenchmarkId::new("from_counters", &label), &label, |b, _| {
            b.iter(|| {
                // 模拟 system_snapshot 构建时对每个工作区调用 from_counters
                for (project, workspace, root) in &scenario.entries {
                    let _ = WorkspaceCacheSnapshot::from_counters(
                        black_box(project),
                        black_box(workspace),
                        black_box(root),
                    );
                }
            })
        });
    }
    group.finish();
}

// ============================================================================
// Benchmark 6: 工作区缓存淘汰扫描（多工作区淘汰路径）
// ============================================================================
fn bench_eviction_scan(c: &mut Criterion) {
    let scenario = BenchScenario::new_multi_project(3, 5);
    scenario.reset_metrics();

    c.bench_function("workspace_cache/eviction_scan_multi_ws", |b| {
        b.iter(|| {
            for (_, _, root) in &scenario.entries {
                cache_metrics::record_file_cache_eviction(
                    black_box(root),
                    black_box("ttl_expired"),
                );
                cache_metrics::record_git_cache_eviction(black_box(root), black_box("ttl_expired"));
            }
        })
    });
}

// ============================================================================
// Benchmark 7: 同名工作区不同项目的指标隔离性验证（多项目同名 ws）
// ============================================================================
fn bench_same_workspace_name_isolation(c: &mut Criterion) {
    // 模拟 project_a/ws1 和 project_b/ws1 有相同 workspace 名称但不同根路径
    let root_a = "/tmp/bench_iso/project_a/ws1";
    let root_b = "/tmp/bench_iso/project_b/ws1";
    cache_metrics::clear_metrics_for_path(root_a);
    cache_metrics::clear_metrics_for_path(root_b);
    cache_metrics::record_file_cache_rebuild(root_a, 100);
    cache_metrics::record_file_cache_rebuild(root_b, 200);

    c.bench_function("workspace_cache/isolation_same_name", |b| {
        b.iter(|| {
            let snap_a = WorkspaceCacheSnapshot::from_counters(
                black_box("project_a"),
                black_box("ws1"),
                black_box(root_a),
            );
            let snap_b = WorkspaceCacheSnapshot::from_counters(
                black_box("project_b"),
                black_box("ws1"),
                black_box(root_b),
            );
            // 验证指标隔离性（不允许交叉污染）
            let _ = black_box(snap_a.file_cache.item_count != snap_b.file_cache.item_count);
        })
    });
}

// ============================================================================
// Benchmark 8: 统一性能指标快照聚合（可观测性热路径）
// ============================================================================
fn bench_perf_metrics_snapshot(c: &mut Criterion) {
    // 先灌入一些计数器数据，模拟运行态
    for _ in 0..100 {
        perf_counters::record_ws_decode_ms(2);
        perf_counters::record_ws_dispatch_ms(1);
        perf_counters::record_ws_encode_ms(1);
        perf_counters::record_task_broadcast_lag(0);
        perf_counters::record_terminal_reclaimed(1);
    }

    c.bench_function("perf_metrics/snapshot_aggregate", |b| {
        b.iter(|| {
            let snap = snapshot_perf_metrics();
            black_box(snap);
        })
    });
}

// ============================================================================
// Benchmark 9: 性能快照在多项目多工作区场景的联合聚合路径
// ============================================================================
fn bench_combined_observability_snapshot(c: &mut Criterion) {
    let mut group = c.benchmark_group("observability/combined_snapshot");

    for (projects, ws_per_project) in [(1, 3), (3, 5), (5, 10)] {
        let scenario = BenchScenario::new_multi_project(projects, ws_per_project);
        scenario.reset_metrics();
        scenario.prime_file_cache_hits(50);
        scenario.prime_git_cache_hits(100);
        scenario.prime_rebuilds(3);

        let label = format!("{}proj_{}ws", projects, ws_per_project);
        group.bench_with_input(
            BenchmarkId::new("cache_plus_perf", &label),
            &label,
            |b, _| {
                b.iter(|| {
                    // 模拟 system_snapshot handler：先聚合全局 perf，再遍历各工作区 cache
                    let _perf = snapshot_perf_metrics();
                    for (project, workspace, root) in &scenario.entries {
                        let _ = WorkspaceCacheSnapshot::from_counters(
                            black_box(project),
                            black_box(workspace),
                            black_box(root),
                        );
                    }
                    black_box(());
                })
            },
        );
    }
    group.finish();
}

// 缩短 criterion 测量/预热时间，确保全量基准（~15 个点）在 300 秒内完成冒烟验证
criterion_group! {
    name = benches;
    config = Criterion::default()
        .measurement_time(Duration::from_secs(2))
        .warm_up_time(Duration::from_secs(1));
    targets =
        bench_file_cache_rebuild,
        bench_file_cache_incremental,
        bench_file_cache_hit_miss,
        bench_git_cache_hit_miss,
        bench_snapshot_multi_project,
        bench_eviction_scan,
        bench_same_workspace_name_isolation,
        bench_perf_metrics_snapshot,
        bench_combined_observability_snapshot,
}
criterion_main!(benches);
