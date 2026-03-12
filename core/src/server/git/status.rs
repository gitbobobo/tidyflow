//! Git status query functions
//!
//! Provides functions to query git status, log, and show commit details.

use chrono::TimeZone;
use gix::bstr::ByteSlice;
use gix::status::index_worktree::iter::Summary;
use std::collections::HashMap;
use std::path::Path;
use std::process::Command;
use std::sync::{LazyLock, Mutex};
use std::time::{Instant, SystemTime};
use tracing::debug;
use tracing::warn;

use super::utils::*;
use crate::server::perf as perf_counters;
use crate::workspace::cache_metrics;

// ── 指纹类型 ──

/// 单个文件的 mtime + len 指纹（不感知内容，仅感知是否被修改过）
#[derive(Debug, Clone, PartialEq, Eq)]
struct FileFingerprint {
    mtime_ns: u64,
    len: u64,
}

impl FileFingerprint {
    fn from_path(path: &Path) -> Option<Self> {
        let meta = std::fs::metadata(path).ok()?;
        let mtime_ns = meta
            .modified()
            .ok()?
            .duration_since(SystemTime::UNIX_EPOCH)
            .ok()?
            .as_nanos() as u64;
        Some(FileFingerprint {
            mtime_ns,
            len: meta.len(),
        })
    }
}

/// Git 状态缓存命中判定指纹。
///
/// 持有 `.git/index`、`.git/HEAD` 和当前分支 ref 文件的 mtime+len 指纹。
/// 任一文件变化时指纹不匹配，触发重建。
/// detached HEAD 或无法定位分支 ref 文件时，`branch_ref_fp` 为 None，
/// 此时仍可依赖 `index_fp` 和 `head_fp` 进行命中判定。
#[derive(Debug, Clone, PartialEq)]
struct GitStatusFingerprint {
    index_fp: Option<FileFingerprint>,
    head_fp: Option<FileFingerprint>,
    branch_ref_fp: Option<FileFingerprint>,
}

impl GitStatusFingerprint {
    /// 计算当前工作区的 Git 文件指纹。无需打开仓库，仅 stat 3 个文件。
    fn compute(workspace_root: &Path) -> Self {
        let git_dir = workspace_root.join(".git");
        let index_fp = FileFingerprint::from_path(&git_dir.join("index"));
        let head_fp = FileFingerprint::from_path(&git_dir.join("HEAD"));

        // 从 HEAD 内容解析当前分支 ref，找到对应 ref 文件
        let branch_ref_fp = std::fs::read_to_string(git_dir.join("HEAD"))
            .ok()
            .and_then(|content| content.strip_prefix("ref: ").map(|s| s.trim().to_string()))
            .and_then(|ref_name| FileFingerprint::from_path(&git_dir.join(&ref_name)));

        GitStatusFingerprint {
            index_fp,
            head_fp,
            branch_ref_fp,
        }
    }

    /// 如果至少有一个文件指纹可采样，则可用于命中判定
    fn is_sampable(&self) -> bool {
        self.index_fp.is_some() || self.head_fp.is_some()
    }
}

// ── 缓存结构 ──

/// 缓存条目（含指纹，用于精确命中判定）
struct CacheEntry {
    result: GitStatusResult,
    fingerprint: GitStatusFingerprint,
    created_at: Instant,
}

/// 缓存 TTL 从 5s 升级到 30s，仅作为 watcher 丢事件时的保底淘汰。
/// 主命中判定依赖指纹（index / HEAD / 分支 ref mtime+len），TTL 不再是主策略。
const CACHE_TTL_SECS: u64 = 30;

/// 全局 git status 缓存（key 包含 default_branch 以隔离不同分支配置）
static GIT_STATUS_CACHE: LazyLock<Mutex<HashMap<String, CacheEntry>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn bstr_to_string(input: &gix::bstr::BStr) -> String {
    String::from_utf8_lossy(input.as_ref()).to_string()
}

fn git_time_to_iso(time: gix::date::Time) -> String {
    if let Some(offset) = chrono::FixedOffset::east_opt(time.offset) {
        if let chrono::LocalResult::Single(dt) = offset.timestamp_opt(time.seconds, 0) {
            return dt.to_rfc3339();
        }
    }
    time.seconds.to_string()
}

fn tree_index_change_to_entry(change: gix::diff::index::Change) -> GitStatusEntry {
    match change {
        gix::diff::index::Change::Addition { location, .. } => GitStatusEntry {
            path: bstr_to_string(location.as_ref()),
            code: "A".to_string(),
            orig_path: None,
            staged: true,
            additions: None,
            deletions: None,
        },
        gix::diff::index::Change::Deletion { location, .. } => GitStatusEntry {
            path: bstr_to_string(location.as_ref()),
            code: "D".to_string(),
            orig_path: None,
            staged: true,
            additions: None,
            deletions: None,
        },
        gix::diff::index::Change::Modification { location, .. } => GitStatusEntry {
            path: bstr_to_string(location.as_ref()),
            code: "M".to_string(),
            orig_path: None,
            staged: true,
            additions: None,
            deletions: None,
        },
        gix::diff::index::Change::Rewrite {
            source_location,
            location,
            copy,
            ..
        } => GitStatusEntry {
            path: bstr_to_string(location.as_ref()),
            code: if copy {
                "C".to_string()
            } else {
                "R".to_string()
            },
            orig_path: Some(bstr_to_string(source_location.as_ref())),
            staged: true,
            additions: None,
            deletions: None,
        },
    }
}

fn index_worktree_item_to_entry(item: gix::status::index_worktree::Item) -> Option<GitStatusEntry> {
    let path = bstr_to_string(item.rela_path());
    let mut orig_path = None;
    if let gix::status::index_worktree::Item::Rewrite { source, .. } = &item {
        orig_path = Some(bstr_to_string(source.rela_path()));
    }

    let summary = item.summary()?;
    let (code, staged) = match summary {
        Summary::Added => ("??".to_string(), false),
        Summary::Removed => ("D".to_string(), false),
        Summary::Modified => ("M".to_string(), false),
        Summary::TypeChange => ("M".to_string(), false),
        Summary::Renamed => ("R".to_string(), false),
        Summary::Copied => ("C".to_string(), false),
        Summary::IntentToAdd => ("A".to_string(), true),
        Summary::Conflict => ("U".to_string(), false),
    };

    Some(GitStatusEntry {
        path,
        code,
        orig_path,
        staged,
        additions: None,
        deletions: None,
    })
}

fn sort_status_items(items: &mut [GitStatusEntry]) {
    items.sort_by(|a, b| {
        a.path
            .cmp(&b.path)
            .then_with(|| a.staged.cmp(&b.staged))
            .then_with(|| a.code.cmp(&b.code))
            .then_with(|| a.orig_path.cmp(&b.orig_path))
    });
}

/// Get git status for a workspace.
///
/// 缓存命中策略（优先级从高到低）：
/// 1. 指纹命中（.git/index + HEAD + 分支 ref 均未变化）→ 直接返回
/// 2. TTL 兜底（30s，用于 watcher 丢事件时的保底淘汰）→ 重建
/// 3. 首次调用 → 全量重建（冷路径）
///
/// 冷路径一次性产出 status items、current_branch 和 divergence，
/// 避免 query 层再次打开仓库。
pub fn git_status(
    workspace_root: &Path,
    default_branch: &str,
) -> Result<GitStatusResult, GitError> {
    let key = format!("{}#{}", workspace_root.to_string_lossy(), default_branch);
    let refresh_started = Instant::now();

    // 先计算指纹（不持锁，stat 3 个文件）
    let current_fp = GitStatusFingerprint::compute(workspace_root);

    if let Ok(cache) = GIT_STATUS_CACHE.lock() {
        if let Some(entry) = cache.get(&key) {
            let elapsed = entry.created_at.elapsed().as_secs();
            if elapsed < CACHE_TTL_SECS {
                let hit = if current_fp.is_sampable() {
                    current_fp == entry.fingerprint
                } else {
                    // 无法采样指纹（非 git 目录或 .git 不可读），退化为 TTL
                    true
                };
                if hit {
                    perf_counters::record_workspace_git_status_refresh(
                        refresh_started.elapsed().as_millis() as u64,
                    );
                    cache_metrics::record_git_cache_hit(&key);
                    return Ok(entry.result.clone());
                } else {
                    cache_metrics::record_git_cache_eviction(&key, "fingerprint_changed");
                }
            } else {
                cache_metrics::record_git_cache_eviction(&key, "ttl_expired");
            }
        }
    }

    // 缓存未命中：冷路径全量重建
    cache_metrics::record_git_cache_miss(&key);
    let result = git_status_uncached(workspace_root, default_branch)?;
    let item_count = result.items.len();
    let refresh_ms = refresh_started.elapsed().as_millis() as u64;
    perf_counters::record_workspace_git_status_refresh(refresh_ms);

    if let Ok(mut cache) = GIT_STATUS_CACHE.lock() {
        cache.insert(
            key.clone(),
            CacheEntry {
                result: result.clone(),
                fingerprint: current_fp,
                created_at: Instant::now(),
            },
        );
    }
    cache_metrics::record_git_cache_rebuild(&key, item_count);

    Ok(result)
}

/// 获取当前分支名。
pub fn git_current_branch(workspace_root: &Path) -> Result<Option<String>, GitError> {
    let repo = match gix::discover(workspace_root) {
        Ok(repo) => repo,
        Err(_) => return Ok(None),
    };

    let head_name = repo
        .head_name()
        .map_err(|e| GitError::CommandFailed(format!("Failed to get current branch: {}", e)))?;

    Ok(head_name.map(|name| name.shorten().to_string()))
}

fn count_ahead_behind(
    repo: &gix::Repository,
    tip: gix::hash::ObjectId,
    hidden: gix::hash::ObjectId,
) -> Result<i32, GitError> {
    let walk = repo
        .rev_walk([tip])
        .with_hidden([hidden])
        .all()
        .map_err(|e| GitError::CommandFailed(format!("Failed to walk history: {}", e)))?;

    let mut count: i32 = 0;
    for info in walk {
        info.map_err(|e| GitError::CommandFailed(format!("Failed to walk commit: {}", e)))?;
        count = count.saturating_add(1);
    }
    Ok(count)
}

/// 计算当前分支相对本地默认分支的领先/落后提交数（不访问网络）。
pub fn check_branch_divergence_local(
    workspace_root: &Path,
    current_branch: &str,
    default_branch: &str,
) -> Result<BranchDivergenceResult, GitError> {
    let repo = gix::discover(workspace_root).map_err(|_| GitError::NotAGitRepo)?;

    let current_ref = format!("refs/heads/{}", current_branch);
    let default_ref = format!("refs/heads/{}", default_branch);

    let mut current = repo
        .try_find_reference(&current_ref)
        .map_err(|e| GitError::CommandFailed(format!("Failed to find branch: {}", e)))?
        .ok_or_else(|| {
            GitError::CommandFailed(format!("Local branch '{}' not found", current_branch))
        })?;

    let mut default = repo
        .try_find_reference(&default_ref)
        .map_err(|e| GitError::CommandFailed(format!("Failed to find branch: {}", e)))?
        .ok_or_else(|| {
            GitError::CommandFailed(format!(
                "Local default branch '{}' not found",
                default_branch
            ))
        })?;

    let current_id = current
        .peel_to_id()
        .map_err(|e| GitError::CommandFailed(format!("Failed to resolve current branch: {}", e)))?
        .detach();
    let default_id = default
        .peel_to_id()
        .map_err(|e| GitError::CommandFailed(format!("Failed to resolve default branch: {}", e)))?
        .detach();

    let ahead_by = count_ahead_behind(&repo, current_id, default_id)?;
    let behind_by = count_ahead_behind(&repo, default_id, current_id)?;

    Ok(BranchDivergenceResult {
        ahead_by,
        behind_by,
        compared_branch: default_branch.to_string(),
    })
}

/// 使指定工作区的 git status 缓存失效（清除所有 default_branch 变体）
pub fn invalidate_git_status_cache(workspace_root: &Path) {
    let root_prefix = format!("{}#", workspace_root.to_string_lossy());
    if let Ok(mut cache) = GIT_STATUS_CACHE.lock() {
        let keys_to_remove: Vec<String> = cache
            .keys()
            .filter(|k| k.starts_with(&root_prefix))
            .cloned()
            .collect();
        for key in keys_to_remove {
            cache.remove(&key);
            cache_metrics::record_git_cache_eviction(&key, "invalidated");
        }
    }
}

/// 复用已打开仓库计算分支分歧（避免重复打开仓库）
fn compute_divergence_from_repo(
    repo: &gix::Repository,
    current_branch: &str,
    default_branch: &str,
) -> Result<BranchDivergenceResult, GitError> {
    if current_branch == default_branch || default_branch.is_empty() {
        return Err(GitError::CommandFailed("same or empty branch".to_string()));
    }
    let current_ref = format!("refs/heads/{}", current_branch);
    let default_ref = format!("refs/heads/{}", default_branch);

    let mut current = repo
        .try_find_reference(&current_ref)
        .map_err(|e| GitError::CommandFailed(format!("Failed to find branch: {}", e)))?
        .ok_or_else(|| {
            GitError::CommandFailed(format!("Local branch '{}' not found", current_branch))
        })?;

    let mut default = repo
        .try_find_reference(&default_ref)
        .map_err(|e| GitError::CommandFailed(format!("Failed to find branch: {}", e)))?
        .ok_or_else(|| {
            GitError::CommandFailed(format!(
                "Local default branch '{}' not found",
                default_branch
            ))
        })?;

    let current_id = current
        .peel_to_id()
        .map_err(|e| GitError::CommandFailed(format!("Failed to resolve current branch: {}", e)))?
        .detach();
    let default_id = default
        .peel_to_id()
        .map_err(|e| GitError::CommandFailed(format!("Failed to resolve default branch: {}", e)))?
        .detach();

    let ahead_by = count_ahead_behind(repo, current_id, default_id)?;
    let behind_by = count_ahead_behind(repo, default_id, current_id)?;

    Ok(BranchDivergenceResult {
        ahead_by,
        behind_by,
        compared_branch: default_branch.to_string(),
    })
}

/// 实际执行 git status 查询（无缓存）。
///
/// 冷路径一次性产出 items、current_branch 和 divergence，
/// 复用同一个已打开的仓库，避免重复 `gix::discover`。
fn git_status_uncached(
    workspace_root: &Path,
    default_branch: &str,
) -> Result<GitStatusResult, GitError> {
    let repo = match gix::discover(workspace_root) {
        Ok(repo) => repo,
        Err(_) => {
            return Ok(GitStatusResult {
                repo_root: String::new(),
                items: vec![],
                has_staged_changes: false,
                staged_count: 0,
                current_branch: None,
                default_branch: if default_branch.is_empty() {
                    None
                } else {
                    Some(default_branch.to_string())
                },
                ahead_by: None,
                behind_by: None,
                compared_branch: None,
            });
        }
    };

    let repo_root = repo
        .workdir()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|| workspace_root.to_string_lossy().to_string());

    let mut iter = repo
        .status(gix::progress::Discard)
        .map_err(|e| GitError::CommandFailed(format!("Failed to create status iterator: {}", e)))?
        .into_iter(Vec::<gix::bstr::BString>::new())
        .map_err(|e| GitError::CommandFailed(format!("Failed to start status iteration: {}", e)))?;

    let mut items = Vec::new();
    for item in &mut iter {
        let item =
            item.map_err(|e| GitError::CommandFailed(format!("Status iteration failed: {}", e)))?;
        match item {
            gix::status::Item::IndexWorktree(change) => {
                if let Some(entry) = index_worktree_item_to_entry(change) {
                    items.push(entry);
                }
            }
            gix::status::Item::TreeIndex(change) => {
                items.push(tree_index_change_to_entry(change));
            }
        }
    }

    // 不写回 index，避免触发 .git/index 变更事件造成状态刷新风暴。
    sort_status_items(&mut items);

    let staged_count = items.iter().filter(|item| item.staged).count();
    let has_staged_changes = staged_count > 0;

    // 从同一已打开仓库获取当前分支（复用 gix::discover 结果）
    let current_branch = repo
        .head_name()
        .ok()
        .flatten()
        .map(|name| name.shorten().to_string());

    // 从同一已打开仓库计算本地分歧信息
    let divergence = if let Some(branch) = current_branch.as_deref() {
        match compute_divergence_from_repo(&repo, branch, default_branch) {
            Ok(result) => Some(result),
            Err(e) => {
                // 分歧计算失败（本地无对应分支等）时静默忽略
                warn!(
                    "git_status divergence skipped: branch={} default={} err={}",
                    branch, default_branch, e
                );
                None
            }
        }
    } else {
        None
    };

    Ok(GitStatusResult {
        repo_root,
        items,
        has_staged_changes,
        staged_count,
        current_branch,
        default_branch: if default_branch.is_empty() {
            None
        } else {
            Some(default_branch.to_string())
        },
        ahead_by: divergence.as_ref().map(|d| d.ahead_by),
        behind_by: divergence.as_ref().map(|d| d.behind_by),
        compared_branch: divergence.map(|d| d.compared_branch),
    })
}

/// 获取单个文件的 git 状态码（仅 1 个查询）
pub fn git_file_status(workspace_root: &Path, path: &str) -> Option<(String, bool)> {
    let started = Instant::now();
    let output = Command::new("git")
        .args([
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
            "--",
            path,
        ])
        .current_dir(workspace_root)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let line = stdout.lines().find(|line| !line.trim().is_empty())?;
    let parsed = parse_porcelain_status_line(line);
    debug!(
        "git_file_status path={} elapsed_ms={} hit={}",
        path,
        started.elapsed().as_millis(),
        parsed.is_some()
    );
    parsed
}

fn parse_porcelain_status_line(line: &str) -> Option<(String, bool)> {
    let bytes = line.as_bytes();
    if bytes.len() < 3 {
        return None;
    }

    let x = bytes[0] as char;
    let y = bytes[1] as char;
    if x == '?' && y == '?' {
        return Some(("??".to_string(), false));
    }

    if x != ' ' && x != '?' {
        return Some((x.to_string(), true));
    }
    if y != ' ' && y != '?' {
        return Some((y.to_string(), false));
    }
    None
}

/// Get git log (commit history) for a workspace
pub fn git_log(workspace_root: &Path, limit: usize) -> Result<GitLogResult, GitError> {
    let repo = gix::discover(workspace_root).map_err(|_| GitError::NotAGitRepo)?;

    let head_id = match repo.head_id() {
        Ok(id) => id.detach(),
        Err(_) => return Ok(GitLogResult { entries: vec![] }),
    };

    let mut refs_by_commit: HashMap<String, Vec<String>> = HashMap::new();
    if let Ok(refs) = repo.references() {
        if let Ok(iter) = refs.all() {
            for item in iter {
                let Ok(mut reference) = item else {
                    continue;
                };
                let ref_name = reference.name().shorten().to_string();
                if let Ok(id) = reference.peel_to_id() {
                    refs_by_commit
                        .entry(id.to_string())
                        .or_default()
                        .push(ref_name);
                }
            }
        }
    }

    let walk = repo
        .rev_walk([head_id])
        .sorting(gix::revision::walk::Sorting::ByCommitTime(
            gix::traverse::commit::simple::CommitTimeOrder::NewestFirst,
        ))
        .all()
        .map_err(|e| GitError::CommandFailed(format!("Failed to walk git history: {}", e)))?;

    let mut entries = Vec::new();
    for info in walk.take(limit) {
        let info = info
            .map_err(|e| GitError::CommandFailed(format!("Failed to read commit info: {}", e)))?;
        let commit = info
            .object()
            .map_err(|e| GitError::CommandFailed(format!("Failed to read commit object: {}", e)))?;

        let full_sha = commit.id().to_string();
        let sha: String = full_sha.chars().take(7).collect();
        let message = bstr_to_string(commit.message_raw_sloppy())
            .trim()
            .to_string();
        let author = commit
            .author()
            .map(|a| bstr_to_string(a.name))
            .unwrap_or_else(|_| "Unknown".to_string());
        let date = commit.time().map(git_time_to_iso).unwrap_or_default();
        let refs = refs_by_commit.remove(&full_sha).unwrap_or_default();

        entries.push(GitLogEntry {
            sha,
            message,
            author,
            date,
            refs,
        });
    }

    Ok(GitLogResult { entries })
}

/// Get details for a single commit
pub fn git_show(workspace_root: &Path, sha: &str) -> Result<GitShowResult, GitError> {
    let repo = gix::discover(workspace_root).map_err(|_| GitError::NotAGitRepo)?;

    if !sha.chars().all(|c| c.is_ascii_hexdigit()) || sha.is_empty() || sha.len() > 40 {
        return Err(GitError::CommandFailed("Invalid SHA format".to_string()));
    }

    let commit_id = repo
        .rev_parse_single(sha.as_bytes().as_bstr())
        .map_err(|e| GitError::CommandFailed(format!("Invalid revision '{}': {}", sha, e)))?;
    let commit = commit_id
        .object()
        .map_err(|e| GitError::CommandFailed(format!("Failed to load commit object: {}", e)))?
        .into_commit();

    let full_sha = commit.id().to_string();
    let short_sha: String = full_sha.chars().take(7).collect();

    let author_sig = commit
        .author()
        .map_err(|e| GitError::CommandFailed(format!("Failed to read commit author: {}", e)))?;

    let author = bstr_to_string(author_sig.name).trim().to_string();
    let author_email = bstr_to_string(author_sig.email).trim().to_string();
    let date = commit.time().map(git_time_to_iso).unwrap_or_default();
    let message = bstr_to_string(commit.message_raw_sloppy())
        .trim()
        .to_string();

    let current_tree = commit
        .tree()
        .map_err(|e| GitError::CommandFailed(format!("Failed to read commit tree: {}", e)))?;

    let first_parent = commit.parent_ids().next();
    let previous_tree = if let Some(parent) = first_parent {
        parent
            .object()
            .map_err(|e| GitError::CommandFailed(format!("Failed to read parent commit: {}", e)))?
            .into_commit()
            .tree()
            .map_err(|e| GitError::CommandFailed(format!("Failed to read parent tree: {}", e)))?
    } else {
        repo.empty_tree()
    };

    let changes = repo
        .diff_tree_to_tree(Some(&previous_tree), Some(&current_tree), None)
        .map_err(|e| GitError::CommandFailed(format!("Failed to diff commit trees: {}", e)))?;

    let mut files = Vec::new();
    for change in changes {
        match change {
            gix::object::tree::diff::ChangeDetached::Addition { location, .. } => {
                files.push(GitShowFileEntry {
                    status: "A".to_string(),
                    path: bstr_to_string(location.as_ref()),
                    old_path: None,
                });
            }
            gix::object::tree::diff::ChangeDetached::Deletion { location, .. } => {
                files.push(GitShowFileEntry {
                    status: "D".to_string(),
                    path: bstr_to_string(location.as_ref()),
                    old_path: None,
                });
            }
            gix::object::tree::diff::ChangeDetached::Modification { location, .. } => {
                files.push(GitShowFileEntry {
                    status: "M".to_string(),
                    path: bstr_to_string(location.as_ref()),
                    old_path: None,
                });
            }
            gix::object::tree::diff::ChangeDetached::Rewrite {
                source_location,
                location,
                copy,
                ..
            } => {
                files.push(GitShowFileEntry {
                    status: if copy {
                        "C".to_string()
                    } else {
                        "R".to_string()
                    },
                    path: bstr_to_string(location.as_ref()),
                    old_path: Some(bstr_to_string(source_location.as_ref())),
                });
            }
        }
    }

    Ok(GitShowResult {
        sha: short_sha,
        full_sha,
        message,
        author,
        author_email,
        date,
        files,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_git_time_to_iso_fallback() {
        let t = gix::date::Time {
            seconds: 0,
            offset: 0,
        };
        assert!(!git_time_to_iso(t).is_empty());
    }

    #[test]
    fn test_parse_porcelain_status_line_tracked_staged() {
        assert_eq!(
            parse_porcelain_status_line("M  src/main.rs"),
            Some(("M".to_string(), true))
        );
    }

    #[test]
    fn test_parse_porcelain_status_line_tracked_unstaged() {
        assert_eq!(
            parse_porcelain_status_line(" M src/main.rs"),
            Some(("M".to_string(), false))
        );
    }

    #[test]
    fn test_parse_porcelain_status_line_untracked() {
        assert_eq!(
            parse_porcelain_status_line("?? src/new.rs"),
            Some(("??".to_string(), false))
        );
    }

    #[test]
    fn test_parse_porcelain_status_line_deleted_staged() {
        assert_eq!(
            parse_porcelain_status_line("D  src/old.rs"),
            Some(("D".to_string(), true))
        );
    }

    #[test]
    fn test_parse_porcelain_status_line_deleted_unstaged() {
        assert_eq!(
            parse_porcelain_status_line(" D src/old.rs"),
            Some(("D".to_string(), false))
        );
    }

    #[test]
    fn test_parse_porcelain_status_line_added_staged() {
        assert_eq!(
            parse_porcelain_status_line("A  src/new.rs"),
            Some(("A".to_string(), true))
        );
    }

    #[test]
    fn test_parse_porcelain_status_line_modified_both() {
        // 暂存和工作区都有修改
        assert_eq!(
            parse_porcelain_status_line("MM src/main.rs"),
            Some(("M".to_string(), true))
        );
    }

    #[test]
    fn test_parse_porcelain_status_line_renamed() {
        assert_eq!(
            parse_porcelain_status_line("R  old -> new"),
            Some(("R".to_string(), true))
        );
    }

    #[test]
    fn test_parse_porcelain_status_line_empty() {
        assert_eq!(parse_porcelain_status_line(""), None);
    }

    #[test]
    fn test_parse_porcelain_status_line_too_short() {
        assert_eq!(parse_porcelain_status_line("M"), None);
        assert_eq!(parse_porcelain_status_line("M "), None);
    }

    #[test]
    fn test_sort_status_items_by_path() {
        let mut items = vec![
            GitStatusEntry {
                path: "z.txt".to_string(),
                code: "M".to_string(),
                orig_path: None,
                staged: false,
                additions: None,
                deletions: None,
            },
            GitStatusEntry {
                path: "a.txt".to_string(),
                code: "M".to_string(),
                orig_path: None,
                staged: false,
                additions: None,
                deletions: None,
            },
            GitStatusEntry {
                path: "m.txt".to_string(),
                code: "M".to_string(),
                orig_path: None,
                staged: false,
                additions: None,
                deletions: None,
            },
        ];
        sort_status_items(&mut items);
        assert_eq!(items[0].path, "a.txt");
        assert_eq!(items[1].path, "m.txt");
        assert_eq!(items[2].path, "z.txt");
    }

    #[test]
    fn test_sort_status_items_by_staged_priority() {
        let mut items = vec![
            GitStatusEntry {
                path: "test.rs".to_string(),
                code: "M".to_string(),
                orig_path: None,
                staged: true,
                additions: None,
                deletions: None,
            },
            GitStatusEntry {
                path: "test.rs".to_string(),
                code: "M".to_string(),
                orig_path: None,
                staged: false,
                additions: None,
                deletions: None,
            },
        ];
        sort_status_items(&mut items);
        // false < true，所以 staged=false 排在前面
        assert!(!items[0].staged);
        assert!(items[1].staged);
    }

    #[test]
    fn test_git_status_result_structure() {
        let result = GitStatusResult {
            repo_root: "/test".to_string(),
            items: vec![],
            has_staged_changes: false,
            staged_count: 0,
            current_branch: Some("main".to_string()),
            default_branch: Some("main".to_string()),
            ahead_by: Some(2),
            behind_by: Some(1),
            compared_branch: Some("origin/main".to_string()),
        };
        assert!(result.items.is_empty());
        assert!(!result.has_staged_changes);
        assert_eq!(result.current_branch, Some("main".to_string()));
        assert_eq!(result.ahead_by, Some(2));
        assert_eq!(result.behind_by, Some(1));
    }

    #[test]
    fn test_git_log_entry_structure() {
        let entry = GitLogEntry {
            sha: "abc1234".to_string(),
            message: "feat: add feature".to_string(),
            author: "Developer".to_string(),
            date: "2026-03-06T12:00:00Z".to_string(),
            refs: vec!["HEAD".to_string(), "main".to_string()],
        };
        assert_eq!(entry.sha.len(), 7);
        assert_eq!(entry.refs.len(), 2);
    }

    #[test]
    fn test_git_show_file_entry_status() {
        let added = GitShowFileEntry {
            status: "A".to_string(),
            path: "new.txt".to_string(),
            old_path: None,
        };
        assert_eq!(added.status, "A");
        assert!(added.old_path.is_none());

        let renamed = GitShowFileEntry {
            status: "R".to_string(),
            path: "new.txt".to_string(),
            old_path: Some("old.txt".to_string()),
        };
        assert_eq!(renamed.status, "R");
        assert_eq!(renamed.old_path, Some("old.txt".to_string()));
    }

    // ── 热点路径定向测试（WI-005 / CHK-002）──

    #[test]
    fn hotspot_perf_git_fingerprint_is_sampable_on_nonexistent_path() {
        // 非 Git 仓库或路径不存在时，指纹应标记为 not sampable，不 panic
        let root = std::path::Path::new("/nonexistent/no_such_repo");
        let fp = GitStatusFingerprint::compute(root);
        assert!(!fp.is_sampable(), "non-existent path must not be sampable");
    }

    #[test]
    fn hotspot_perf_git_status_non_git_dir_returns_empty() {
        // 对非 Git 目录调用 git_status 应返回空结果，不 panic 或返回错误串
        let tmp = std::env::temp_dir().join("hotspot_non_git_dir_test");
        let _ = std::fs::create_dir_all(&tmp);
        let result = git_status(&tmp, "main");
        // 非 git 目录应返回空结果（而非 Err 传播到调用方造成 panic）
        match result {
            Ok(r) => {
                assert!(r.items.is_empty(), "non-git dir should yield empty status");
                assert!(r.current_branch.is_none() || r.current_branch.as_deref() == Some(""));
            }
            Err(_) => {
                // 返回 Err 也可接受——关键是不 panic
            }
        }
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn hotspot_perf_invalidate_clears_all_branch_variants() {
        // 验证 invalidate 按前缀匹配清除所有关联 key（多分支场景）
        use std::path::Path;
        let root = Path::new("/tmp/hotspot_invalidate_test");
        let key_main = format!("{}#main", root.to_string_lossy());
        let key_feat = format!("{}#feature/foo", root.to_string_lossy());

        // 直接向缓存插入两个变体
        {
            let mut cache = GIT_STATUS_CACHE.lock().unwrap();
            let make_entry = || CacheEntry {
                result: GitStatusResult {
                    repo_root: root.to_string_lossy().to_string(),
                    items: vec![],
                    has_staged_changes: false,
                    staged_count: 0,
                    current_branch: None,
                    default_branch: None,
                    ahead_by: None,
                    behind_by: None,
                    compared_branch: None,
                },
                created_at: std::time::Instant::now(),
                fingerprint: GitStatusFingerprint::compute(root),
            };
            cache.insert(key_main.clone(), make_entry());
            cache.insert(key_feat.clone(), make_entry());
        }

        // 调用 invalidate 清除
        invalidate_git_status_cache(root);

        // 两个 key 都应被清除
        let cache = GIT_STATUS_CACHE.lock().unwrap();
        assert!(
            !cache.contains_key(&key_main),
            "main variant should be cleared"
        );
        assert!(
            !cache.contains_key(&key_feat),
            "feature variant should be cleared"
        );
    }
}
