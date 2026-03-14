//! 工作区缓存性能基准测试套件
//!
//! ## 覆盖场景
//! - 文件索引缓存重建（全量）
//! - 文件索引缓存增量更新
//! - Git 状态缓存热路径与冷路径重建
//! - AI 会话上下文缓存命中、快照命中与适配器回源
//! - 工作区缓存指标快照
//! - 多项目、多工作区并行路径
//!
//! ## 运行方式
//! ```bash
//! cargo bench --manifest-path core/Cargo.toml workspace_cache
//! ```
//!
//! ## 共享夹具
//! 场景构造器（MultiProjectFixture、GitRepoFixture、AiContextTestHarness）
//! 已迁移至 `tidyflow_core::perf::hotspot_guard`，由本文件与守卫入口共同复用。

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use std::time::Duration;
use tempfile::TempDir;
use tidyflow_core::perf::hotspot_guard::{
    AiContextTestHarness, FakeAiAdapter, GitRepoFixture, MultiProjectFixture,
};
use tidyflow_core::server::git::{git_status, invalidate_git_status_cache};
use tidyflow_core::server::perf::{self as perf_counters, snapshot_perf_metrics};
use tidyflow_core::workspace::cache_metrics::{self, WorkspaceCacheSnapshot};
use tokio::runtime::Runtime;

const BENCH_SAMPLE_SIZE: usize = 10;
const BENCH_WARM_UP_TIME: Duration = Duration::from_millis(250);
const BENCH_MEASUREMENT_TIME: Duration = Duration::from_secs(1);

fn workspace_cache_scenarios() -> [(usize, usize); 3] {
    // 保留单项目与多项目、多工作区分层覆盖，同时缩小最大场景，避免冒烟回归超时。
    [(1, 2), (2, 4), (4, 6)]
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
// Benchmark 5: Git 冷路径重建（空仓库 / 中等仓库 / detached HEAD / 非 Git）
// ============================================================================
fn bench_git_cache_rebuild(c: &mut Criterion) {
    let fixture = GitRepoFixture::new();
    let mut group = c.benchmark_group("workspace_cache/git_rebuild");
    group.sample_size(BENCH_SAMPLE_SIZE);
    group.measurement_time(BENCH_MEASUREMENT_TIME);
    group.warm_up_time(BENCH_WARM_UP_TIME);

    let cases = [
        ("empty_repo_fast_path", fixture.empty_repo.as_path()),
        ("medium_repo_100_files", fixture.medium_repo.as_path()),
        ("detached_head", fixture.detached_repo.as_path()),
        ("non_git_fallback", fixture.non_git_dir.as_path()),
    ];

    for (label, repo_root) in cases {
        group.bench_function(label, |b| {
            b.iter(|| {
                invalidate_git_status_cache(repo_root);
                let result = git_status(black_box(repo_root), black_box("main"));
                black_box(result.ok().map(|status| status.items.len()));
            })
        });
    }

    group.finish();
}

// ============================================================================
// Benchmark 6: 工作区缓存快照构建（多项目、多工作区）
// ============================================================================
fn bench_snapshot_multi_project(c: &mut Criterion) {
    let mut group = c.benchmark_group("workspace_cache/snapshot_multi_project");

    for (projects, ws_per_project) in workspace_cache_scenarios() {
        let scenario = MultiProjectFixture::new(projects, ws_per_project);
        scenario.reset_metrics();
        scenario.prime_file_cache_hits(20);
        scenario.prime_git_cache_hits(40);
        scenario.prime_rebuilds(2);

        let label = format!("{}proj_{}ws", projects, ws_per_project);
        group.bench_with_input(BenchmarkId::new("from_counters", &label), &label, |b, _| {
            b.iter(|| {
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
// Benchmark 7: AI 会话上下文读取路径（运行时命中 / 快照命中 / 冷回源 / 隔离）
// ============================================================================
fn bench_ai_context_query(c: &mut Criterion) {
    let runtime = Runtime::new().expect("failed to create tokio runtime");
    let db_file = TempDir::new().expect("failed to create ai bench dir");
    let hot_db_path = db_file.path().join("ai_context.sqlite");
    let hot_adapter =
        FakeAiAdapter::new(&[(("/tmp/bench/project-a/default", "sess-hot"), Some(83.0))]);

    let hot_harness = runtime.block_on(async {
        let harness = AiContextTestHarness::new(&hot_db_path, hot_adapter.clone()).await;
        harness
            .seed_session(
                "project-a",
                "default",
                "codex",
                "/tmp/bench/project-a/default",
                "sess-hot",
                Some(83.0),
            )
            .await;
        let _ = harness
            .read_context(
                "project-a",
                "default",
                "codex",
                "/tmp/bench/project-a/default",
                "sess-hot",
            )
            .await;
        harness
    });

    let mut group = c.benchmark_group("workspace_cache/ai_context_query");
    group.sample_size(BENCH_SAMPLE_SIZE);
    group.measurement_time(BENCH_MEASUREMENT_TIME);
    group.warm_up_time(BENCH_WARM_UP_TIME);

    group.bench_function("runtime_cache_hit", |b| {
        b.iter(|| {
            let pct = runtime.block_on(hot_harness.read_context(
                "project-a",
                "default",
                "codex",
                "/tmp/bench/project-a/default",
                "sess-hot",
            ));
            black_box(pct);
        })
    });

    let warm_db_file = TempDir::new().expect("failed to create warm db dir");
    let warm_db_path = warm_db_file.path().join("ai_context_warm.sqlite");
    runtime.block_on(async {
        let harness = AiContextTestHarness::new(&warm_db_path, FakeAiAdapter::new(&[])).await;
        harness
            .seed_session(
                "project-b",
                "default",
                "claude",
                "/tmp/bench/project-b/default",
                "sess-warm",
                Some(64.0),
            )
            .await;
    });
    group.bench_function("persistent_snapshot_warm_start", |b| {
        b.iter(|| {
            let pct = runtime.block_on(async {
                let harness =
                    AiContextTestHarness::new(&warm_db_path, FakeAiAdapter::new(&[])).await;
                harness
                    .read_context(
                        "project-b",
                        "default",
                        "claude",
                        "/tmp/bench/project-b/default",
                        "sess-warm",
                    )
                    .await
            });
            black_box(pct);
        })
    });

    let cold_db_file = TempDir::new().expect("failed to create cold db dir");
    let cold_db_path = cold_db_file.path().join("ai_context_cold.sqlite");
    let cold_adapter =
        FakeAiAdapter::new(&[(("/tmp/bench/project-c/default", "sess-cold"), Some(41.0))]);
    group.bench_function("adapter_fallback_cold_start", |b| {
        b.iter(|| {
            let pct = runtime.block_on(async {
                let harness = AiContextTestHarness::new(&cold_db_path, cold_adapter.clone()).await;
                harness
                    .read_context(
                        "project-c",
                        "default",
                        "codex",
                        "/tmp/bench/project-c/default",
                        "sess-cold",
                    )
                    .await
            });
            black_box(pct);
        })
    });

    let isolation_db_file = TempDir::new().expect("failed to create isolation db dir");
    let isolation_db_path = isolation_db_file.path().join("ai_context_isolation.sqlite");
    let isolation_harness = runtime.block_on(async {
        let harness = AiContextTestHarness::new(&isolation_db_path, FakeAiAdapter::new(&[])).await;
        harness
            .seed_session(
                "project-alpha",
                "default",
                "codex",
                "/tmp/bench/project-alpha/default",
                "shared-session",
                Some(91.0),
            )
            .await;
        harness
            .seed_session(
                "project-beta",
                "workspace-1",
                "codex",
                "/tmp/bench/project-beta/workspace-1",
                "shared-session",
                Some(27.0),
            )
            .await;
        harness
    });
    group.bench_function("multi_workspace_isolation", |b| {
        b.iter(|| {
            let result = runtime.block_on(async {
                let pct_a = isolation_harness
                    .read_context(
                        "project-alpha",
                        "default",
                        "codex",
                        "/tmp/bench/project-alpha/default",
                        "shared-session",
                    )
                    .await;
                let pct_b = isolation_harness
                    .read_context(
                        "project-beta",
                        "workspace-1",
                        "codex",
                        "/tmp/bench/project-beta/workspace-1",
                        "shared-session",
                    )
                    .await;
                (pct_a, pct_b, pct_a != pct_b)
            });
            black_box(result);
        })
    });

    group.finish();
}

// ============================================================================
// Benchmark 8: 工作区缓存淘汰扫描（多工作区淘汰路径）
// ============================================================================
fn bench_eviction_scan(c: &mut Criterion) {
    let scenario = MultiProjectFixture::new(2, 4);
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
// Benchmark 9: 同名工作区不同项目的指标隔离性验证（多项目同名 ws）
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
            let _ = black_box(snap_a.file_cache.item_count != snap_b.file_cache.item_count);
        })
    });
}

// ============================================================================
// Benchmark 10: 统一性能指标快照聚合（可观测性热路径）
// ============================================================================
fn bench_perf_metrics_snapshot(c: &mut Criterion) {
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
// Benchmark 11: 性能快照在多项目多工作区场景的联合聚合路径
// ============================================================================
fn bench_combined_observability_snapshot(c: &mut Criterion) {
    let mut group = c.benchmark_group("observability/combined_snapshot");

    for (projects, ws_per_project) in workspace_cache_scenarios() {
        let scenario = MultiProjectFixture::new(projects, ws_per_project);
        scenario.reset_metrics();
        scenario.prime_file_cache_hits(20);
        scenario.prime_git_cache_hits(40);
        scenario.prime_rebuilds(2);

        let label = format!("{}proj_{}ws", projects, ws_per_project);
        group.bench_with_input(
            BenchmarkId::new("cache_plus_perf", &label),
            &label,
            |b, _| {
                b.iter(|| {
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

// ============================================================================
// 热点路径基准：文件索引、Git 状态、AI 会话上下文三类计数器
// ============================================================================
//
// ## 预算阈值（口径固化，详见 core/benches/baselines/hotspot_regression.json）
// - 文件索引 cold refresh：< 200ms；hot（perf 记录函数本身）：< 2µs
// - Git 状态 cold refresh：< 500ms；hot（指纹写入 + perf 记录）：< 2µs
// - AI 会话上下文 hot（运行时缓存命中 + perf 记录）：< 1µs

fn bench_hotspot_perf_recording(c: &mut Criterion) {
    let mut group = c.benchmark_group("hotspot_perf_recording");
    group.sample_size(BENCH_SAMPLE_SIZE);
    group.measurement_time(BENCH_MEASUREMENT_TIME);
    group.warm_up_time(BENCH_WARM_UP_TIME);

    group.bench_function("record_file_index_refresh_hot", |b| {
        b.iter(|| {
            perf_counters::record_workspace_file_index_refresh(black_box(1));
        })
    });

    group.bench_function("record_file_index_refresh_cold", |b| {
        b.iter(|| {
            perf_counters::record_workspace_file_index_refresh(black_box(150));
        })
    });

    group.bench_function("record_git_status_refresh_hot", |b| {
        b.iter(|| {
            perf_counters::record_workspace_git_status_refresh(black_box(0));
        })
    });

    group.bench_function("record_git_status_refresh_cold", |b| {
        b.iter(|| {
            perf_counters::record_workspace_git_status_refresh(black_box(300));
        })
    });

    group.bench_function("record_ai_context_refresh_hot", |b| {
        b.iter(|| {
            perf_counters::record_workspace_ai_context_refresh(black_box(0));
        })
    });

    group.bench_function("record_ai_context_refresh_cold", |b| {
        b.iter(|| {
            perf_counters::record_workspace_ai_context_refresh(black_box(50));
        })
    });

    group.finish();
}

fn bench_file_index_filter_hot(c: &mut Criterion) {
    let items: Vec<String> = (0..4096)
        .map(|i| format!("/project/src/module_{}/file_{}.rs", i / 64, i % 64))
        .collect();
    let search_keys: Vec<String> = items.iter().map(|p| p.to_lowercase()).collect();

    let mut group = c.benchmark_group("file_index_filter_hot");
    group.sample_size(BENCH_SAMPLE_SIZE);
    group.measurement_time(BENCH_MEASUREMENT_TIME);
    group.warm_up_time(BENCH_WARM_UP_TIME);

    group.bench_function("filter_prefix_4096", |b| {
        b.iter(|| {
            let query = black_box("module_1");
            let results: Vec<&str> = search_keys
                .iter()
                .zip(items.iter())
                .filter(|(key, _)| key.contains(query))
                .map(|(_, path)| path.as_str())
                .take(200)
                .collect();
            black_box(results);
        })
    });

    group.bench_function("clone_full_vec_4096_baseline", |b| {
        b.iter(|| {
            let _cloned = black_box(items.clone());
        })
    });

    group.finish();
}

criterion_group! {
    name = benches;
    config = Criterion::default()
        .sample_size(BENCH_SAMPLE_SIZE)
        .measurement_time(BENCH_MEASUREMENT_TIME)
        .warm_up_time(BENCH_WARM_UP_TIME);
    targets =
        bench_file_cache_rebuild,
        bench_file_cache_incremental,
        bench_file_cache_hit_miss,
        bench_git_cache_hit_miss,
        bench_git_cache_rebuild,
        bench_snapshot_multi_project,
        bench_ai_context_query,
        bench_eviction_scan,
        bench_same_workspace_name_isolation,
        bench_perf_metrics_snapshot,
        bench_combined_observability_snapshot,
        bench_hotspot_perf_recording,
        bench_file_index_filter_hot,
}
criterion_main!(benches);
