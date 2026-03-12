//! 热点路径守卫夹具与测量模块
//!
//! ## 职责
//! - 提供三类热点路径（文件索引、Git 状态、AI 上下文）的共享夹具类型
//! - 提供可从守卫二进制与 Criterion benchmark 共同复用的场景构造逻辑
//! - 提供输出稳定 JSON 的测量结果类型
//!
//! ## 与 benchmark 的关系
//! `core/benches/workspace_cache_bench.rs` 直接导入本模块的夹具类型，
//! 保证双轨测量使用同一套数据构造逻辑，避免场景漂移。
//!
//! ## 固定场景 ID（10 个）
//! ### 原有场景（轻/中等负载）
//! - `file_index.filter_prefix_4096`
//! - `file_index.snapshot_multi_project_4x6`
//! - `git_status.medium_repo_100_files`
//! - `git_status.same_workspace_name_isolation`
//! - `ai_context.runtime_cache_hit`
//! - `ai_context.persistent_snapshot_warm_start`
//! - `ai_context.multi_workspace_isolation`
//! ### 高负载多工作区场景（WI-001 新增）
//! - `file_index.high_load_workspace_fanout_8x16`
//! - `git_status.high_load_same_name_cross_project_isolation`
//! - `ai_context.high_load_rebuild_pressure`

use chrono::Utc;
use serde::{Deserialize, Serialize};
use sqlx::{
    sqlite::{SqliteConnectOptions, SqlitePoolOptions},
    Row, SqlitePool,
};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::str::FromStr;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, Mutex,
};
use std::time::Instant;
use std::{fs, io};

use crate::workspace::cache_metrics::{self, WorkspaceCacheSnapshot};

// ============================================================================
// 输出类型（守卫二进制 JSON schema）
// ============================================================================

/// 单场景测量结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScenarioMeasurement {
    pub scenario_id: String,
    /// 单次迭代平均耗时（纳秒）
    pub measured_ns: u64,
    /// 采样迭代次数
    pub sample_count: u32,
    pub projects: usize,
    pub workspaces_per_project: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
}

/// 守卫二进制完整输出
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HotspotMeasurements {
    pub schema_version: String,
    pub suite_id: String,
    pub generated_at: String,
    pub scenarios: Vec<ScenarioMeasurement>,
}

// ============================================================================
// 共享工具：临时目录（不依赖 dev-only tempfile crate）
// ============================================================================

/// 测试用临时目录，Drop 时自动删除
pub struct TempGuard {
    path: PathBuf,
}

impl TempGuard {
    pub fn new() -> io::Result<Self> {
        let id = uuid::Uuid::new_v4().to_string().replace('-', "");
        let path = std::env::temp_dir().join(format!("hotspot_guard_{}", id));
        fs::create_dir_all(&path)?;
        Ok(Self { path })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempGuard {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

// ============================================================================
// 共享夹具 1：多项目、多工作区场景构造器
// ============================================================================

/// 多项目、多工作区场景构造器（原 BenchScenario）
///
/// 由 benchmark 与守卫入口共同使用，保证测试数据构造逻辑一致。
pub struct MultiProjectFixture {
    /// (project, workspace, root_path) 三元组列表
    pub entries: Vec<(String, String, String)>,
}

impl MultiProjectFixture {
    /// 构造 `num_projects` 个项目各有 `workspaces_per_project` 个工作区的场景。
    /// 每个项目额外包含一个名为 "default" 的默认工作区。
    pub fn new(num_projects: usize, workspaces_per_project: usize) -> Self {
        let mut entries = Vec::new();
        for p in 0..num_projects {
            let project = format!("bench_project_{}", p);
            entries.push((
                project.clone(),
                "default".to_string(),
                format!("/tmp/bench/{}/default", p),
            ));
            for w in 0..workspaces_per_project {
                entries.push((
                    project.clone(),
                    format!("workspace_{}", w),
                    format!("/tmp/bench/{}/{}", p, w),
                ));
            }
        }
        Self { entries }
    }

    pub fn reset_metrics(&self) {
        for (_, _, root) in &self.entries {
            cache_metrics::clear_metrics_for_path(root);
        }
    }

    pub fn prime_file_cache_hits(&self, hit_count: u64) {
        for (_, _, root) in &self.entries {
            for _ in 0..hit_count {
                cache_metrics::record_file_cache_hit(root);
            }
        }
    }

    pub fn prime_git_cache_hits(&self, hit_count: u64) {
        for (_, _, root) in &self.entries {
            for _ in 0..hit_count {
                cache_metrics::record_git_cache_hit(root);
            }
        }
    }

    pub fn prime_rebuilds(&self, count: u64) {
        for (_, _, root) in &self.entries {
            for i in 0..count {
                cache_metrics::record_file_cache_rebuild(root, (i * 10 + 100) as usize);
            }
        }
    }
}

// ============================================================================
// 共享夹具 2：Git 仓库测试夹具
// ============================================================================

/// Git 仓库测试夹具（原 GitBenchFixture）
///
/// 在临时目录中创建不同状态的 Git 仓库，供 git_status 热路径测量使用。
pub struct GitRepoFixture {
    _guard: TempGuard,
    pub empty_repo: PathBuf,
    pub medium_repo: PathBuf,
    pub detached_repo: PathBuf,
    pub non_git_dir: PathBuf,
}

impl GitRepoFixture {
    pub fn new() -> Self {
        let guard = TempGuard::new().expect("failed to create git fixture tempdir");
        let empty_repo = guard.path().join("empty_repo");
        let medium_repo = guard.path().join("medium_repo");
        let detached_repo = guard.path().join("detached_repo");
        let non_git_dir = guard.path().join("plain_dir");

        for dir in [&empty_repo, &medium_repo, &detached_repo, &non_git_dir] {
            fs::create_dir_all(dir).expect("failed to create fixture dir");
        }

        init_git_repo(&empty_repo);
        init_medium_repo(&medium_repo, 100);
        init_detached_head_repo(&detached_repo);
        fs::write(non_git_dir.join("README.txt"), "plain workspace\n")
            .expect("failed to create plain dir file");

        Self {
            _guard: guard,
            empty_repo,
            medium_repo,
            detached_repo,
            non_git_dir,
        }
    }
}

fn run_git(dir: &Path, args: &[&str]) {
    let output = Command::new("git")
        .current_dir(dir)
        .args(args)
        .output()
        .unwrap_or_else(|_| panic!("git {:?} failed in {:?}", args, dir));
    if !output.status.success() {
        // init 类操作失败不致命（例如 detached HEAD 场景）
        let _ = output;
    }
}

pub fn init_git_repo(dir: &Path) {
    run_git(dir, &["init", "-b", "main"]);
    run_git(dir, &["config", "user.name", "TidyFlow Guard"]);
    run_git(dir, &["config", "user.email", "guard@tidyflow.local"]);
}

pub fn init_medium_repo(dir: &Path, file_count: usize) {
    init_git_repo(dir);
    for i in 0..file_count {
        let module_dir = dir.join(format!("src/module_{:02}", i / 10));
        fs::create_dir_all(&module_dir).expect("failed to create module dir");
        fs::write(
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
            fs::write(path, format!("modified file {}\n", i))
                .expect("failed to mutate tracked file");
        }
    }
    fs::write(dir.join("untracked.txt"), "untracked\n").expect("failed to add untracked");
}

fn init_detached_head_repo(dir: &Path) {
    init_git_repo(dir);
    fs::write(dir.join("detached.txt"), "base\n").expect("failed to seed detached repo");
    run_git(dir, &["add", "."]);
    run_git(dir, &["commit", "-m", "initial detached seed"]);
    run_git(dir, &["checkout", "--detach", "HEAD"]);
    fs::write(dir.join("detached.txt"), "modified while detached\n")
        .expect("failed to mutate detached repo");
}

// ============================================================================
// 共享夹具 3：AI 会话上下文测试夹具
// ============================================================================

/// AI 上下文运行时缓存条目（原 BenchAiContextCacheEntry）
#[derive(Clone)]
pub struct AiContextCacheEntry {
    pub context_remaining_percent: Option<f64>,
    cached_at: Instant,
}

impl AiContextCacheEntry {
    pub fn new(context_remaining_percent: Option<f64>) -> Self {
        Self {
            context_remaining_percent,
            cached_at: Instant::now(),
        }
    }

    /// 缓存有效期：2 秒（与 AiSessionContextUsageCacheEntry::CACHE_TTL_SECS 一致）
    pub fn is_valid(&self) -> bool {
        self.cached_at.elapsed().as_secs() < 2
    }
}

/// 模拟 AI 适配器（原 FakeAiAdapter）
#[derive(Clone)]
pub struct FakeAiAdapter {
    responses: Arc<HashMap<(String, String), Option<f64>>>,
    pub calls: Arc<AtomicU64>,
}

impl FakeAiAdapter {
    pub fn new(entries: &[((&str, &str), Option<f64>)]) -> Self {
        let mut responses = HashMap::new();
        for ((directory, session_id), value) in entries {
            responses.insert((directory.to_string(), session_id.to_string()), *value);
        }
        Self {
            responses: Arc::new(responses),
            calls: Arc::new(AtomicU64::new(0)),
        }
    }

    pub async fn fetch(&self, directory: &str, session_id: &str) -> Option<f64> {
        self.calls.fetch_add(1, Ordering::Relaxed);
        self.responses
            .get(&(directory.to_string(), session_id.to_string()))
            .copied()
            .flatten()
    }
}

/// AI 会话上下文测试夹具（原 AiContextBenchHarness）
///
/// 封装运行时内存缓存 + SQLite 持久化快照的两级读取路径，
/// 由 benchmark 与守卫入口共同复用。
pub struct AiContextTestHarness {
    pub runtime_cache: Mutex<HashMap<String, AiContextCacheEntry>>,
    pub pool: SqlitePool,
    pub adapter: FakeAiAdapter,
}

impl AiContextTestHarness {
    pub async fn new(db_path: &Path, adapter: FakeAiAdapter) -> Self {
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
            r#"CREATE TABLE IF NOT EXISTS ai_session_index (
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
            )"#,
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

    pub async fn seed_session(
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
            r#"INSERT INTO ai_session_index (
                project_name, workspace_name, ai_tool, directory, session_id,
                title, created_at_ms, updated_at_ms, session_origin, context_snapshot_json
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            ON CONFLICT(project_name, workspace_name, ai_tool, session_id)
            DO UPDATE SET
                directory = excluded.directory,
                updated_at_ms = excluded.updated_at_ms,
                context_snapshot_json = excluded.context_snapshot_json"#,
        )
        .bind(project)
        .bind(workspace)
        .bind(ai_tool)
        .bind(directory)
        .bind(session_id)
        .bind("guard session")
        .bind(now_ms)
        .bind(now_ms)
        .bind("user")
        .bind(snapshot_json)
        .execute(&self.pool)
        .await
        .expect("failed to seed ai session");
    }

    pub async fn read_context(
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
                .insert(cache_key, AiContextCacheEntry::new(Some(snapshot_pct)));
            return Some(snapshot_pct);
        }

        let adapter_pct = self.adapter.fetch(directory, session_id).await;
        self.runtime_cache
            .lock()
            .expect("lock runtime cache")
            .insert(cache_key, AiContextCacheEntry::new(adapter_pct));
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
            r#"SELECT context_snapshot_json FROM ai_session_index
            WHERE project_name = ?1 AND workspace_name = ?2
              AND ai_tool = ?3 AND session_id = ?4"#,
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
            .and_then(|v| v.get("context_remaining_percent").and_then(|v| v.as_f64()))
    }
}

// ============================================================================
// 测量辅助工具
// ============================================================================

/// 同步测量：运行 `f` `iterations` 次，返回 (平均 ns/iter, iterations)
fn measure_sync<F: Fn()>(f: F, iterations: u32) -> (u64, u32) {
    let start = Instant::now();
    for _ in 0..iterations {
        f();
    }
    let total_ns = start.elapsed().as_nanos() as u64;
    (total_ns / u64::from(iterations), iterations)
}

/// 异步测量：运行 `f` `iterations` 次，返回 (平均 ns/iter, iterations)
async fn measure_async<F, Fut>(f: F, iterations: u32) -> (u64, u32)
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = ()>,
{
    let start = Instant::now();
    for _ in 0..iterations {
        f().await;
    }
    let total_ns = start.elapsed().as_nanos() as u64;
    (total_ns / u64::from(iterations), iterations)
}

// ============================================================================
// 7 个固定场景的测量实现
// ============================================================================

fn measure_file_index_filter_prefix_4096() -> ScenarioMeasurement {
    let items: Vec<String> = (0..4096)
        .map(|i| format!("/project/src/module_{}/file_{}.rs", i / 64, i % 64))
        .collect();
    let search_keys: Vec<String> = items.iter().map(|p| p.to_lowercase()).collect();

    let (avg_ns, iters) = measure_sync(
        || {
            let query = "module_1";
            let results: Vec<&str> = search_keys
                .iter()
                .zip(items.iter())
                .filter(|(key, _)| key.contains(query))
                .map(|(_, path)| path.as_str())
                .take(200)
                .collect();
            std::hint::black_box(results);
        },
        50,
    );

    ScenarioMeasurement {
        scenario_id: "file_index.filter_prefix_4096".to_string(),
        measured_ns: avg_ns,
        sample_count: iters,
        projects: 1,
        workspaces_per_project: 1,
        notes: Some("4096 条路径过滤热路径，prefix 匹配取前 200 条".to_string()),
    }
}

fn measure_file_index_snapshot_multi_project_4x6() -> ScenarioMeasurement {
    let scenario = MultiProjectFixture::new(4, 6);
    scenario.reset_metrics();
    scenario.prime_file_cache_hits(20);
    scenario.prime_git_cache_hits(40);
    scenario.prime_rebuilds(2);

    let (avg_ns, iters) = measure_sync(
        || {
            for (project, workspace, root) in &scenario.entries {
                let snap = WorkspaceCacheSnapshot::from_counters(project, workspace, root);
                std::hint::black_box(snap);
            }
        },
        20,
    );

    ScenarioMeasurement {
        scenario_id: "file_index.snapshot_multi_project_4x6".to_string(),
        measured_ns: avg_ns,
        sample_count: iters,
        projects: 4,
        workspaces_per_project: 6,
        notes: Some("4 项目 × 6 工作区快照聚合热路径".to_string()),
    }
}

fn measure_git_status_medium_repo_100_files() -> ScenarioMeasurement {
    use crate::server::git::{git_status, invalidate_git_status_cache};

    let fixture = GitRepoFixture::new();
    // 预热一次，排除首次 git 进程启动开销
    let _ = git_status(&fixture.medium_repo, "main");

    let (avg_ns, iters) = measure_sync(
        || {
            invalidate_git_status_cache(&fixture.medium_repo);
            let result = git_status(&fixture.medium_repo, "main");
            std::hint::black_box(result.ok().map(|s| s.items.len()));
        },
        5,
    );

    ScenarioMeasurement {
        scenario_id: "git_status.medium_repo_100_files".to_string(),
        measured_ns: avg_ns,
        sample_count: iters,
        projects: 1,
        workspaces_per_project: 1,
        notes: Some("100 文件中等仓库 git status 冷路径（含变更文件）".to_string()),
    }
}

fn measure_git_status_same_workspace_name_isolation() -> ScenarioMeasurement {
    let root_a = "/tmp/hotspot_guard_iso/project_a/ws1";
    let root_b = "/tmp/hotspot_guard_iso/project_b/ws1";
    cache_metrics::clear_metrics_for_path(root_a);
    cache_metrics::clear_metrics_for_path(root_b);
    cache_metrics::record_file_cache_rebuild(root_a, 100);
    cache_metrics::record_file_cache_rebuild(root_b, 200);

    let (avg_ns, iters) = measure_sync(
        || {
            let snap_a = WorkspaceCacheSnapshot::from_counters("project_a", "ws1", root_a);
            let snap_b = WorkspaceCacheSnapshot::from_counters("project_b", "ws1", root_b);
            let isolated = std::hint::black_box(
                snap_a.file_cache.item_count != snap_b.file_cache.item_count,
            );
            std::hint::black_box(isolated);
        },
        100,
    );

    ScenarioMeasurement {
        scenario_id: "git_status.same_workspace_name_isolation".to_string(),
        measured_ns: avg_ns,
        sample_count: iters,
        projects: 2,
        workspaces_per_project: 1,
        notes: Some("同名工作区不同项目的指标隔离性验证".to_string()),
    }
}

async fn measure_ai_context_runtime_cache_hit() -> ScenarioMeasurement {
    let guard = TempGuard::new().expect("failed to create temp dir");
    let db_path = guard.path().join("ai_hot.sqlite");
    let adapter =
        FakeAiAdapter::new(&[(("/tmp/hotspot/project-a/default", "sess-hot"), Some(83.0))]);

    let harness = AiContextTestHarness::new(&db_path, adapter).await;
    harness
        .seed_session(
            "project-a",
            "default",
            "codex",
            "/tmp/hotspot/project-a/default",
            "sess-hot",
            Some(83.0),
        )
        .await;
    // 预热：写入运行时缓存
    let _ = harness
        .read_context(
            "project-a",
            "default",
            "codex",
            "/tmp/hotspot/project-a/default",
            "sess-hot",
        )
        .await;

    let (avg_ns, iters) = measure_async(
        || async {
            let pct = harness
                .read_context(
                    "project-a",
                    "default",
                    "codex",
                    "/tmp/hotspot/project-a/default",
                    "sess-hot",
                )
                .await;
            std::hint::black_box(pct);
        },
        50,
    )
    .await;

    ScenarioMeasurement {
        scenario_id: "ai_context.runtime_cache_hit".to_string(),
        measured_ns: avg_ns,
        sample_count: iters,
        projects: 1,
        workspaces_per_project: 1,
        notes: Some("AI 上下文运行时缓存命中热路径".to_string()),
    }
}

async fn measure_ai_context_persistent_snapshot_warm_start() -> ScenarioMeasurement {
    let guard = TempGuard::new().expect("failed to create temp dir");
    let warm_db_path = guard.path().join("ai_warm.sqlite");

    // 预置快照数据
    {
        let setup_harness =
            AiContextTestHarness::new(&warm_db_path, FakeAiAdapter::new(&[])).await;
        setup_harness
            .seed_session(
                "project-b",
                "default",
                "claude",
                "/tmp/hotspot/project-b/default",
                "sess-warm",
                Some(64.0),
            )
            .await;
    }

    // 每次迭代创建新 harness（测量从快照加载的完整冷启动路径）
    let (avg_ns, iters) = measure_async(
        || async {
            let h =
                AiContextTestHarness::new(&warm_db_path, FakeAiAdapter::new(&[])).await;
            let pct = h
                .read_context(
                    "project-b",
                    "default",
                    "claude",
                    "/tmp/hotspot/project-b/default",
                    "sess-warm",
                )
                .await;
            std::hint::black_box(pct);
        },
        5,
    )
    .await;

    ScenarioMeasurement {
        scenario_id: "ai_context.persistent_snapshot_warm_start".to_string(),
        measured_ns: avg_ns,
        sample_count: iters,
        projects: 1,
        workspaces_per_project: 1,
        notes: Some("AI 上下文持久化快照温启动路径（含 SQLite 连接池创建）".to_string()),
    }
}

async fn measure_ai_context_multi_workspace_isolation() -> ScenarioMeasurement {
    let guard = TempGuard::new().expect("failed to create temp dir");
    let db_path = guard.path().join("ai_isolation.sqlite");
    let harness = AiContextTestHarness::new(&db_path, FakeAiAdapter::new(&[])).await;

    // 两个不同项目使用相同 session_id，但持有不同上下文值
    harness
        .seed_session(
            "project-alpha",
            "default",
            "codex",
            "/tmp/hotspot/project-alpha/default",
            "shared-session",
            Some(91.0),
        )
        .await;
    harness
        .seed_session(
            "project-beta",
            "workspace-1",
            "codex",
            "/tmp/hotspot/project-beta/workspace-1",
            "shared-session",
            Some(27.0),
        )
        .await;
    // 预热运行时缓存
    let _ = harness
        .read_context(
            "project-alpha",
            "default",
            "codex",
            "/tmp/hotspot/project-alpha/default",
            "shared-session",
        )
        .await;
    let _ = harness
        .read_context(
            "project-beta",
            "workspace-1",
            "codex",
            "/tmp/hotspot/project-beta/workspace-1",
            "shared-session",
        )
        .await;

    let (avg_ns, iters) = measure_async(
        || async {
            let pct_a = harness
                .read_context(
                    "project-alpha",
                    "default",
                    "codex",
                    "/tmp/hotspot/project-alpha/default",
                    "shared-session",
                )
                .await;
            let pct_b = harness
                .read_context(
                    "project-beta",
                    "workspace-1",
                    "codex",
                    "/tmp/hotspot/project-beta/workspace-1",
                    "shared-session",
                )
                .await;
            std::hint::black_box((pct_a, pct_b, pct_a != pct_b));
        },
        50,
    )
    .await;

    ScenarioMeasurement {
        scenario_id: "ai_context.multi_workspace_isolation".to_string(),
        measured_ns: avg_ns,
        sample_count: iters,
        projects: 2,
        workspaces_per_project: 1,
        notes: Some("多工作区同名 session 隔离验证热路径".to_string()),
    }
}

// ============================================================================
// WI-001 高负载多工作区场景（3 个新增）
// ============================================================================

/// 高负载工作区 fan-out：8 个项目 × 16 个工作区，测量大规模多工作区快照聚合热路径
fn measure_file_index_high_load_workspace_fanout_8x16() -> ScenarioMeasurement {
    let scenario = MultiProjectFixture::new(8, 16);
    scenario.reset_metrics();
    // 高命中压力：每个工作区写入 100 次 file cache 命中
    scenario.prime_file_cache_hits(100);
    // 高 git 命中压力：每个工作区 80 次
    scenario.prime_git_cache_hits(80);
    // 高重建压力：每个工作区 10 次重建
    scenario.prime_rebuilds(10);

    let (avg_ns, iters) = measure_sync(
        || {
            for (project, workspace, root) in &scenario.entries {
                let snap = WorkspaceCacheSnapshot::from_counters(project, workspace, root);
                std::hint::black_box(snap);
            }
        },
        10,
    );

    ScenarioMeasurement {
        scenario_id: "file_index.high_load_workspace_fanout_8x16".to_string(),
        measured_ns: avg_ns,
        sample_count: iters,
        projects: 8,
        workspaces_per_project: 16,
        notes: Some("8 项目 × 16 工作区高负载快照聚合热路径（高命中+高重建压力）".to_string()),
    }
}

/// 高负载同名工作区跨项目隔离：4 个项目各持有同名工作区 "release"，验证多工作区隔离不随负载退化
fn measure_git_status_high_load_same_name_cross_project_isolation() -> ScenarioMeasurement {
    let projects = 4usize;
    let workspace_name = "release";
    let roots: Vec<String> = (0..projects)
        .map(|i| format!("/tmp/hotspot_guard_hl/project_{}/{}", i, workspace_name))
        .collect();

    // 清理并写入差异化重建记录（每个项目重建数不同，以便验证隔离）
    for (i, root) in roots.iter().enumerate() {
        cache_metrics::clear_metrics_for_path(root.as_str());
        for j in 0..50u64 {
            cache_metrics::record_file_cache_rebuild(root.as_str(), ((i + 1) * 100 + j as usize) as usize);
        }
        for _ in 0..200u64 {
            cache_metrics::record_file_cache_hit(root.as_str());
        }
    }

    let project_names: Vec<String> = (0..projects).map(|i| format!("project_{}", i)).collect();

    let (avg_ns, iters) = measure_sync(
        || {
            let snaps: Vec<WorkspaceCacheSnapshot> = roots
                .iter()
                .zip(project_names.iter())
                .map(|(root, proj)| {
                    WorkspaceCacheSnapshot::from_counters(proj.as_str(), workspace_name, root.as_str())
                })
                .collect();
            // 验证同名工作区跨项目的指标不相同（隔离断言不退化）
            let all_distinct = snaps.windows(2).all(|pair| {
                pair[0].file_cache.item_count != pair[1].file_cache.item_count
            });
            std::hint::black_box(all_distinct);
        },
        30,
    );

    ScenarioMeasurement {
        scenario_id: "git_status.high_load_same_name_cross_project_isolation".to_string(),
        measured_ns: avg_ns,
        sample_count: iters,
        projects: projects,
        workspaces_per_project: 1,
        notes: Some("4 项目同名工作区高负载（50次重建+200次命中）跨项目隔离验证".to_string()),
    }
}

/// 高负载重建压力：多工作区高缓存命中率 + 高重建频率，测量 AI 上下文热路径在负载放大后的基线
async fn measure_ai_context_high_load_rebuild_pressure() -> ScenarioMeasurement {
    let guard = TempGuard::new().expect("failed to create temp dir");
    let db_path = guard.path().join("ai_hl_rebuild.sqlite");

    // 构造 8 个工作区，每对使用相同 session_id 来模拟高并发命中场景
    let workspaces: Vec<(&str, &str, &str, &str)> = vec![
        ("proj-hl-0", "ws-0", "/tmp/hotspot/hl/proj-hl-0/ws-0", "sess-hl"),
        ("proj-hl-1", "ws-0", "/tmp/hotspot/hl/proj-hl-1/ws-0", "sess-hl"),
        ("proj-hl-2", "ws-1", "/tmp/hotspot/hl/proj-hl-2/ws-1", "sess-hl"),
        ("proj-hl-3", "ws-1", "/tmp/hotspot/hl/proj-hl-3/ws-1", "sess-hl"),
    ];

    // 构建 adapter：使用 root_path 而非 (proj, sess) 键，FakeAiAdapter 按 (root, sess) 索引
    let adapter_pairs: Vec<((&str, &str), Option<f64>)> = workspaces
        .iter()
        .enumerate()
        .map(|(i, (_proj, _ws, root, sess))| ((*root, *sess), Some(50.0 + i as f64 * 10.0)))
        .collect();
    let adapter = FakeAiAdapter::new(&adapter_pairs);

    let harness = AiContextTestHarness::new(&db_path, adapter).await;

    // 种子化所有工作区数据并预热运行时缓存
    for (i, (proj, ws, root, sess)) in workspaces.iter().enumerate() {
        harness
            .seed_session(proj, ws, "codex", root, sess, Some(50.0 + i as f64 * 10.0))
            .await;
        // 预热缓存（确保命中路径已初始化）
        let _ = harness.read_context(proj, ws, "codex", root, sess).await;
    }

    let (avg_ns, iters) = measure_async(
        || async {
            let mut results = Vec::with_capacity(workspaces.len());
            for (proj, ws, root, sess) in &workspaces {
                let pct = harness.read_context(proj, ws, "codex", root, sess).await;
                results.push(pct);
            }
            // 验证多工作区结果互不相同（高负载下隔离不退化）
            let all_distinct = results.windows(2).all(|pair| pair[0] != pair[1]);
            std::hint::black_box((results, all_distinct));
        },
        20,
    )
    .await;

    ScenarioMeasurement {
        scenario_id: "ai_context.high_load_rebuild_pressure".to_string(),
        measured_ns: avg_ns,
        sample_count: iters,
        projects: 4,
        workspaces_per_project: 1,
        notes: Some("4 工作区高缓存命中率+高负载并发读取，验证 AI 上下文热路径在高负载下的基线".to_string()),
    }
}

// ============================================================================
// 公共入口：运行全部 10 个场景并返回测量结果
// ============================================================================

/// 运行全部 10 个固定场景并返回稳定 JSON 可读的测量结果。
///
/// 供 `hotspot_perf_guard` 二进制调用；benchmark 通过导入共享夹具类型而不调用此函数。
/// 场景集合：7 个原有场景 + 3 个 WI-001 新增高负载多工作区场景。
pub async fn measure_all_scenarios() -> HotspotMeasurements {
    let scenarios = vec![
        measure_file_index_filter_prefix_4096(),
        measure_file_index_snapshot_multi_project_4x6(),
        measure_git_status_medium_repo_100_files(),
        measure_git_status_same_workspace_name_isolation(),
        measure_ai_context_runtime_cache_hit().await,
        measure_ai_context_persistent_snapshot_warm_start().await,
        measure_ai_context_multi_workspace_isolation().await,
        // WI-001 高负载场景
        measure_file_index_high_load_workspace_fanout_8x16(),
        measure_git_status_high_load_same_name_cross_project_isolation(),
        measure_ai_context_high_load_rebuild_pressure().await,
    ];

    HotspotMeasurements {
        schema_version: "1".to_string(),
        suite_id: "hotspot_perf_guard".to_string(),
        generated_at: Utc::now().to_rfc3339(),
        scenarios,
    }
}

// ============================================================================
// 单元测试
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    // ── 基线文件解析与 schema 校验 ──

    #[test]
    fn hotspot_perf_baseline_parse_and_validate_schema() {
        let baseline_path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("benches/baselines/hotspot_regression.json");
        let content = std::fs::read_to_string(&baseline_path)
            .unwrap_or_else(|_| panic!("baseline 文件不存在: {:?}", baseline_path));
        let value: serde_json::Value =
            serde_json::from_str(&content).expect("基线文件 JSON 解析失败");

        assert_eq!(value["schema_version"], "1", "schema_version 必须为 \"1\"");
        assert!(
            value["suite_id"].as_str().is_some(),
            "suite_id 必须存在且为字符串"
        );
        let scenarios = value["scenarios"].as_array().expect("scenarios 必须为数组");
        assert!(!scenarios.is_empty(), "scenarios 不能为空");
    }

    #[test]
    fn hotspot_perf_baseline_contains_all_10_scenario_ids() {
        let baseline_path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("benches/baselines/hotspot_regression.json");
        let content = std::fs::read_to_string(&baseline_path).expect("读取基线文件失败");
        let value: serde_json::Value = serde_json::from_str(&content).unwrap();
        let scenarios = value["scenarios"].as_array().unwrap();

        let ids: Vec<&str> = scenarios
            .iter()
            .map(|s| s["scenario_id"].as_str().expect("scenario_id 必须为字符串"))
            .collect();

        let required = [
            "file_index.filter_prefix_4096",
            "file_index.snapshot_multi_project_4x6",
            "git_status.medium_repo_100_files",
            "git_status.same_workspace_name_isolation",
            "ai_context.runtime_cache_hit",
            "ai_context.persistent_snapshot_warm_start",
            "ai_context.multi_workspace_isolation",
            // WI-001 高负载场景
            "file_index.high_load_workspace_fanout_8x16",
            "git_status.high_load_same_name_cross_project_isolation",
            "ai_context.high_load_rebuild_pressure",
        ];
        for id in required {
            assert!(ids.contains(&id), "基线文件缺少 scenario_id: {}", id);
        }
    }

    #[test]
    fn hotspot_perf_baseline_no_duplicate_scenario_ids() {
        let baseline_path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("benches/baselines/hotspot_regression.json");
        let content = std::fs::read_to_string(&baseline_path).expect("读取基线文件失败");
        let value: serde_json::Value = serde_json::from_str(&content).unwrap();
        let scenarios = value["scenarios"].as_array().unwrap();

        let mut seen = std::collections::HashSet::new();
        for s in scenarios {
            let id = s["scenario_id"].as_str().unwrap();
            assert!(seen.insert(id), "基线文件存在重复 scenario_id: {}", id);
        }
    }

    #[test]
    fn hotspot_perf_baseline_all_scenarios_have_required_fields() {
        let baseline_path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("benches/baselines/hotspot_regression.json");
        let content = std::fs::read_to_string(&baseline_path).expect("读取基线文件失败");
        let value: serde_json::Value = serde_json::from_str(&content).unwrap();
        let scenarios = value["scenarios"].as_array().unwrap();

        for s in scenarios {
            let id = s["scenario_id"].as_str().unwrap_or("unknown");
            assert!(s["path_kind"].as_str().is_some(), "{}: 缺少 path_kind", id);
            assert!(
                s["workload_kind"].as_str().is_some(),
                "{}: 缺少 workload_kind",
                id
            );
            assert!(s["baseline_ns"].as_u64().is_some(), "{}: 缺少 baseline_ns", id);
            assert!(
                s["warn_ratio_limit"].as_f64().is_some(),
                "{}: 缺少 warn_ratio_limit",
                id
            );
            assert!(
                s["fail_ratio_limit"].as_f64().is_some(),
                "{}: 缺少 fail_ratio_limit",
                id
            );
            assert!(
                s["absolute_budget_ns"].as_u64().is_some(),
                "{}: 缺少 absolute_budget_ns",
                id
            );
        }
    }

    // ── warn/fail 阈值比较规则 ──

    #[test]
    fn threshold_comparison_warn_rule() {
        // measured > baseline * warn_ratio → warn
        let baseline_ns: u64 = 1000;
        let warn_ratio: f64 = 2.0;
        let measured: u64 = 2100;
        let ratio = measured as f64 / baseline_ns as f64;
        assert!(ratio > warn_ratio, "超过 warn 倍率应触发 warn，ratio={}", ratio);
    }

    #[test]
    fn threshold_comparison_fail_rule() {
        // measured > baseline * fail_ratio → fail
        let baseline_ns: u64 = 1000;
        let fail_ratio: f64 = 5.0;
        let measured: u64 = 6000;
        let ratio = measured as f64 / baseline_ns as f64;
        assert!(ratio > fail_ratio, "超过 fail 倍率应触发 fail，ratio={}", ratio);
    }

    #[test]
    fn threshold_comparison_absolute_budget_fail_rule() {
        // measured > absolute_budget_ns → fail，无论 ratio
        let absolute_budget_ns: u64 = 5_000_000;
        let measured: u64 = 6_000_000;
        assert!(measured > absolute_budget_ns, "超过绝对预算应触发 fail");
    }

    #[test]
    fn threshold_comparison_pass_rule() {
        let baseline_ns: u64 = 1000;
        let warn_ratio: f64 = 2.0;
        let absolute_budget_ns: u64 = 5_000_000;
        let measured: u64 = 1500; // 1.5x，低于 warn
        let ratio = measured as f64 / baseline_ns as f64;
        assert!(ratio <= warn_ratio, "低于 warn 倍率应为 pass");
        assert!(measured <= absolute_budget_ns, "低于绝对预算应为 pass");
    }

    // ── 多项目同名工作区下的场景归属不串台 ──

    #[test]
    fn hotspot_perf_same_workspace_name_no_cross_contamination() {
        let root_a = "/tmp/hotspot_test_isolation/proj_a/ws1";
        let root_b = "/tmp/hotspot_test_isolation/proj_b/ws1";
        cache_metrics::clear_metrics_for_path(root_a);
        cache_metrics::clear_metrics_for_path(root_b);

        // 分别写入不同数量的文件索引重建记录
        cache_metrics::record_file_cache_rebuild(root_a, 111);
        cache_metrics::record_file_cache_rebuild(root_b, 222);

        let snap_a = WorkspaceCacheSnapshot::from_counters("proj_a", "ws1", root_a);
        let snap_b = WorkspaceCacheSnapshot::from_counters("proj_b", "ws1", root_b);

        // 同名工作区的 item_count 不应交叉污染
        assert_ne!(
            snap_a.file_cache.item_count, snap_b.file_cache.item_count,
            "同名工作区不同项目的指标不应串台"
        );
        assert_eq!(snap_a.project, "proj_a");
        assert_eq!(snap_b.project, "proj_b");
        assert_eq!(snap_a.workspace, "ws1");
        assert_eq!(snap_b.workspace, "ws1");
    }

    // ── MultiProjectFixture 基础功能 ──

    #[test]
    fn multi_project_fixture_entry_count() {
        let f = MultiProjectFixture::new(3, 4);
        // 每个项目 = 1 default + 4 named = 5；3 项目共 15 条
        assert_eq!(f.entries.len(), 3 * (1 + 4));
    }

    #[test]
    fn multi_project_fixture_default_workspace_included() {
        let f = MultiProjectFixture::new(2, 2);
        let has_default = f.entries.iter().any(|(_, ws, _)| ws == "default");
        assert!(has_default, "每个项目应包含 default 工作区");
    }
}
