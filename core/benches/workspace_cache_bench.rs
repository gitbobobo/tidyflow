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

use chrono::Utc;
use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use sqlx::{
    sqlite::{SqliteConnectOptions, SqlitePoolOptions},
    Row, SqlitePool,
};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use std::{fs, str::FromStr};
use tempfile::TempDir;
use tidyflow_core::ai::context_usage::AiSessionContextUsageCacheEntry;
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
// Benchmark 5: Git 冷路径重建（空仓库 / 中等仓库 / detached HEAD / 非 Git）
// ============================================================================

struct GitBenchFixture {
    _sandbox: TempDir,
    empty_repo: PathBuf,
    medium_repo: PathBuf,
    detached_repo: PathBuf,
    non_git_dir: PathBuf,
}

impl GitBenchFixture {
    fn new() -> Self {
        let sandbox = TempDir::new().expect("failed to create git bench tempdir");
        let empty_repo = sandbox.path().join("empty_repo");
        let medium_repo = sandbox.path().join("medium_repo");
        let detached_repo = sandbox.path().join("detached_repo");
        let non_git_dir = sandbox.path().join("plain_dir");

        std::fs::create_dir_all(&empty_repo).expect("failed to create empty repo dir");
        std::fs::create_dir_all(&medium_repo).expect("failed to create medium repo dir");
        std::fs::create_dir_all(&detached_repo).expect("failed to create detached repo dir");
        std::fs::create_dir_all(&non_git_dir).expect("failed to create plain dir");

        init_git_repo(&empty_repo);
        init_medium_repo(&medium_repo, 100);
        init_detached_head_repo(&detached_repo);
        std::fs::write(non_git_dir.join("README.txt"), "plain workspace\n")
            .expect("failed to seed non-git dir");

        Self {
            _sandbox: sandbox,
            empty_repo,
            medium_repo,
            detached_repo,
            non_git_dir,
        }
    }
}

fn run_git(dir: &Path, args: &[&str]) {
    let output = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap_or_else(|e| panic!("failed to run git {:?}: {}", args, e));
    assert!(
        output.status.success(),
        "git {:?} failed in {}: {}",
        args,
        dir.display(),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn init_git_repo(dir: &Path) {
    run_git(dir, &["init", "-b", "main"]);
    run_git(dir, &["config", "user.name", "TidyFlow Bench"]);
    run_git(dir, &["config", "user.email", "bench@tidyflow.local"]);
}

fn init_medium_repo(dir: &Path, file_count: usize) {
    init_git_repo(dir);
    for i in 0..file_count {
        let module_dir = dir.join(format!("src/module_{:02}", i / 10));
        std::fs::create_dir_all(&module_dir).expect("failed to create module dir");
        std::fs::write(
            module_dir.join(format!("file_{:03}.txt", i)),
            format!("tracked file {}\n", i),
        )
        .expect("failed to seed tracked file");
    }
    run_git(dir, &["add", "."]);
    run_git(dir, &["commit", "-m", "seed medium repo"]);

    for i in 0..file_count {
        if i % 3 == 0 {
            let path = dir.join(format!("src/module_{:02}/file_{:03}.txt", i / 10, i));
            std::fs::write(path, format!("modified file {}\n", i))
                .expect("failed to mutate tracked file");
        }
    }
    std::fs::write(dir.join("untracked.txt"), "untracked\n").expect("failed to add untracked");
}

fn init_detached_head_repo(dir: &Path) {
    init_git_repo(dir);
    std::fs::write(dir.join("detached.txt"), "base\n").expect("failed to seed detached repo");
    run_git(dir, &["add", "."]);
    run_git(dir, &["commit", "-m", "initial detached seed"]);
    run_git(dir, &["checkout", "--detach", "HEAD"]);
    std::fs::write(dir.join("detached.txt"), "modified while detached\n")
        .expect("failed to mutate detached repo");
}

fn bench_git_cache_rebuild(c: &mut Criterion) {
    let fixture = GitBenchFixture::new();
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
        let scenario = BenchScenario::new_multi_project(projects, ws_per_project);
        scenario.reset_metrics();
        scenario.prime_file_cache_hits(20);
        scenario.prime_git_cache_hits(40);
        scenario.prime_rebuilds(2);

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
// Benchmark 7: AI 会话上下文读取路径（运行时命中 / 快照命中 / 冷回源 / 隔离）
// ============================================================================

#[derive(Clone)]
struct BenchAiContextCacheEntry {
    context_remaining_percent: Option<f64>,
    cached_at: Instant,
}

impl BenchAiContextCacheEntry {
    fn new(context_remaining_percent: Option<f64>) -> Self {
        Self {
            context_remaining_percent,
            cached_at: Instant::now(),
        }
    }

    fn is_valid(&self) -> bool {
        self.cached_at.elapsed().as_secs() < AiSessionContextUsageCacheEntry::CACHE_TTL_SECS
    }
}

#[derive(Clone)]
struct FakeAiAdapter {
    responses: Arc<HashMap<(String, String), Option<f64>>>,
    calls: Arc<AtomicU64>,
}

impl FakeAiAdapter {
    fn new(entries: &[((&str, &str), Option<f64>)]) -> Self {
        let mut responses = HashMap::new();
        for ((directory, session_id), value) in entries {
            responses.insert((directory.to_string(), session_id.to_string()), *value);
        }
        Self {
            responses: Arc::new(responses),
            calls: Arc::new(AtomicU64::new(0)),
        }
    }

    async fn fetch(&self, directory: &str, session_id: &str) -> Option<f64> {
        self.calls.fetch_add(1, Ordering::Relaxed);
        self.responses
            .get(&(directory.to_string(), session_id.to_string()))
            .copied()
            .flatten()
    }
}

struct AiContextBenchHarness {
    runtime_cache: Mutex<HashMap<String, BenchAiContextCacheEntry>>,
    pool: SqlitePool,
    adapter: FakeAiAdapter,
}

impl AiContextBenchHarness {
    async fn new(db_path: &Path, adapter: FakeAiAdapter) -> Self {
        if let Some(parent) = db_path.parent() {
            fs::create_dir_all(parent).expect("failed to create sqlite parent dir");
        }
        let options = SqliteConnectOptions::from_str(&format!("sqlite://{}", db_path.display()))
            .expect("failed to parse sqlite url")
            .create_if_missing(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await
            .expect("failed to connect sqlite pool");
        sqlx::query(
            r#"
            CREATE TABLE IF NOT EXISTS ai_session_index (
                project_name TEXT NOT NULL,
                workspace_name TEXT NOT NULL,
                ai_tool TEXT NOT NULL,
                directory TEXT NOT NULL,
                session_id TEXT NOT NULL,
                title TEXT NOT NULL,
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL,
                session_origin TEXT NOT NULL,
                context_snapshot_json TEXT,
                PRIMARY KEY (project_name, workspace_name, ai_tool, session_id)
            )
            "#,
        )
        .execute(&pool)
        .await
        .expect("failed to create ai_session_index table");

        Self {
            runtime_cache: Mutex::new(HashMap::new()),
            pool,
            adapter,
        }
    }

    fn cache_key(project: &str, workspace: &str, ai_tool: &str, session_id: &str) -> String {
        format!("{project}:{workspace}:{ai_tool}:{session_id}")
    }

    async fn seed_session(
        &self,
        project: &str,
        workspace: &str,
        ai_tool: &str,
        directory: &str,
        session_id: &str,
        snapshot_pct: Option<f64>,
    ) {
        let now_ms = Utc::now().timestamp_millis();
        let snapshot_json = snapshot_pct.map(|pct| {
            serde_json::json!({
                "snapshot_at_ms": now_ms,
                "message_count": 0,
                "context_remaining_percent": pct
            })
            .to_string()
        });

        sqlx::query(
            r#"
            INSERT INTO ai_session_index (
                project_name, workspace_name, ai_tool, directory, session_id,
                title, created_at_ms, updated_at_ms, session_origin, context_snapshot_json
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            ON CONFLICT(project_name, workspace_name, ai_tool, session_id)
            DO UPDATE SET
                directory = excluded.directory,
                updated_at_ms = excluded.updated_at_ms,
                context_snapshot_json = excluded.context_snapshot_json
            "#,
        )
        .bind(project)
        .bind(workspace)
        .bind(ai_tool)
        .bind(directory)
        .bind(session_id)
        .bind("bench session")
        .bind(now_ms)
        .bind(now_ms)
        .bind("user")
        .bind(snapshot_json)
        .execute(&self.pool)
        .await
        .expect("failed to seed ai session");
    }

    async fn read_context(
        &self,
        project: &str,
        workspace: &str,
        ai_tool: &str,
        directory: &str,
        session_id: &str,
    ) -> Option<f64> {
        let cache_key = Self::cache_key(project, workspace, ai_tool, session_id);
        if let Some(hit) = self
            .runtime_cache
            .lock()
            .expect("lock runtime cache")
            .get(&cache_key)
            .cloned()
            .filter(|entry| entry.is_valid())
        {
            return hit.context_remaining_percent;
        }

        if let Some(snapshot_pct) =
            self.load_snapshot(project, workspace, ai_tool, session_id).await
        {
            self.runtime_cache
                .lock()
                .expect("lock runtime cache")
                .insert(cache_key, BenchAiContextCacheEntry::new(Some(snapshot_pct)));
            return Some(snapshot_pct);
        }

        let adapter_pct = self.adapter.fetch(directory, session_id).await;
        self.runtime_cache
            .lock()
            .expect("lock runtime cache")
            .insert(cache_key, BenchAiContextCacheEntry::new(adapter_pct));
        if let Some(pct) = adapter_pct {
            self.seed_session(project, workspace, ai_tool, directory, session_id, Some(pct))
                .await;
        }
        adapter_pct
    }

    async fn load_snapshot(
        &self,
        project: &str,
        workspace: &str,
        ai_tool: &str,
        session_id: &str,
    ) -> Option<f64> {
        let row = sqlx::query(
            r#"
            SELECT context_snapshot_json
            FROM ai_session_index
            WHERE project_name = ?1
              AND workspace_name = ?2
              AND ai_tool = ?3
              AND session_id = ?4
            "#,
        )
        .bind(project)
        .bind(workspace)
        .bind(ai_tool)
        .bind(session_id)
        .fetch_optional(&self.pool)
        .await
        .expect("failed to fetch context snapshot");

        row.and_then(|r| r.try_get::<Option<String>, _>("context_snapshot_json").ok().flatten())
            .and_then(|json| serde_json::from_str::<serde_json::Value>(&json).ok())
            .and_then(|value| {
                value
                    .get("context_remaining_percent")
                    .and_then(|v| v.as_f64())
            })
    }
}

fn bench_ai_context_query(c: &mut Criterion) {
    let runtime = Runtime::new().expect("failed to create tokio runtime");
    let db_file = TempDir::new().expect("failed to create ai bench dir");
    let hot_db_path = db_file.path().join("ai_context.sqlite");
    let hot_adapter = FakeAiAdapter::new(&[(("/tmp/bench/project-a/default", "sess-hot"), Some(83.0))]);

    let hot_harness = runtime.block_on(async {
        let harness = AiContextBenchHarness::new(&hot_db_path, hot_adapter.clone()).await;
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
        let harness = AiContextBenchHarness::new(&warm_db_path, FakeAiAdapter::new(&[])).await;
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
                let harness = AiContextBenchHarness::new(&warm_db_path, FakeAiAdapter::new(&[])).await;
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
    let cold_adapter = FakeAiAdapter::new(&[(("/tmp/bench/project-c/default", "sess-cold"), Some(41.0))]);
    group.bench_function("adapter_fallback_cold_start", |b| {
        b.iter(|| {
            let pct = runtime.block_on(async {
                let harness = AiContextBenchHarness::new(&cold_db_path, cold_adapter.clone()).await;
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
        let harness = AiContextBenchHarness::new(&isolation_db_path, FakeAiAdapter::new(&[])).await;
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
    let scenario = BenchScenario::new_multi_project(2, 4);
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
            // 验证指标隔离性（不允许交叉污染）
            let _ = black_box(snap_a.file_cache.item_count != snap_b.file_cache.item_count);
        })
    });
}

// ============================================================================
// Benchmark 10: 统一性能指标快照聚合（可观测性热路径）
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
// Benchmark 11: 性能快照在多项目多工作区场景的联合聚合路径
// ============================================================================
fn bench_combined_observability_snapshot(c: &mut Criterion) {
    let mut group = c.benchmark_group("observability/combined_snapshot");

    for (projects, ws_per_project) in workspace_cache_scenarios() {
        let scenario = BenchScenario::new_multi_project(projects, ws_per_project);
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

// ============================================================================
// 热点路径基准：文件索引、Git 状态、AI 会话上下文三类计数器
// ============================================================================
//
// ## 预算阈值（口径固化）
// - 文件索引 cold refresh：< 200ms；hot（perf 记录函数本身）：< 2µs
// - Git 状态 cold refresh：< 500ms；hot（指纹写入 + perf 记录）：< 2µs
// - AI 会话上下文 hot（运行时缓存命中 + perf 记录）：< 1µs

/// 热路径计数器记录函数基准：确认三类 record_* 函数本身不成为瓶颈
fn bench_hotspot_perf_recording(c: &mut Criterion) {
    let mut group = c.benchmark_group("hotspot_perf_recording");
    group.sample_size(BENCH_SAMPLE_SIZE);
    group.measurement_time(BENCH_MEASUREMENT_TIME);
    group.warm_up_time(BENCH_WARM_UP_TIME);

    group.bench_function("record_file_index_refresh_hot", |b| {
        b.iter(|| {
            // 热路径命中（模拟 < 2ms）
            perf_counters::record_workspace_file_index_refresh(black_box(1));
        })
    });

    group.bench_function("record_file_index_refresh_cold", |b| {
        b.iter(|| {
            // 冷路径（模拟接近预算阈值 200ms）
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

/// 文件索引过滤热路径：模拟在预构建 Vec<String> 上的过滤开销
fn bench_file_index_filter_hot(c: &mut Criterion) {
    // 预构建索引（4096 条，模拟中等规模项目）
    let items: Vec<String> = (0..4096)
        .map(|i| format!("/project/src/module_{}/file_{}.rs", i / 64, i % 64))
        .collect();
    let search_keys: Vec<String> = items.iter().map(|p| p.to_lowercase()).collect();

    let mut group = c.benchmark_group("file_index_filter_hot");
    group.sample_size(BENCH_SAMPLE_SIZE);
    group.measurement_time(BENCH_MEASUREMENT_TIME);
    group.warm_up_time(BENCH_WARM_UP_TIME);

    // 热路径：在已有快照上过滤（不复制整个 Vec，只分配匹配结果集）
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

    // 冷路径：全量 clone 整个 Vec（对照基准，证明不再这样做）
    group.bench_function("clone_full_vec_4096_baseline", |b| {
        b.iter(|| {
            let _cloned = black_box(items.clone());
        })
    });

    group.finish();
}

// 将 workspace_cache 冒烟回归收敛到 10 次采样，保证统计意义的同时把总时长压到 120 秒内。
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
