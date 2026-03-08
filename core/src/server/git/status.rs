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
use std::time::Instant;
use tracing::debug;

use super::utils::*;
use crate::workspace::cache_metrics;

/// 缓存条目
struct CacheEntry {
    result: GitStatusResult,
    created_at: Instant,
}

/// 缓存 TTL（5 秒），文件监控事件会主动失效缓存
const CACHE_TTL_SECS: u64 = 5;

/// 全局 git status 缓存
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

/// Get git status for a workspace
pub fn git_status(workspace_root: &Path) -> Result<GitStatusResult, GitError> {
    let key = workspace_root.to_string_lossy().to_string();

    if let Ok(cache) = GIT_STATUS_CACHE.lock() {
        if let Some(entry) = cache.get(&key) {
            if entry.created_at.elapsed().as_secs() < CACHE_TTL_SECS {
                cache_metrics::record_git_cache_hit(&key);
                return Ok(entry.result.clone());
            }
            // TTL 过期，将在下方重建
            cache_metrics::record_git_cache_eviction(&key, "ttl_expired");
        }
    }

    cache_metrics::record_git_cache_miss(&key);
    let result = git_status_uncached(workspace_root)?;
    let item_count = result.items.len();

    if let Ok(mut cache) = GIT_STATUS_CACHE.lock() {
        cache.insert(
            key.clone(),
            CacheEntry {
                result: result.clone(),
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

/// 使指定工作区的 git status 缓存失效
pub fn invalidate_git_status_cache(workspace_root: &Path) {
    let key = workspace_root.to_string_lossy().to_string();
    if let Ok(mut cache) = GIT_STATUS_CACHE.lock() {
        if cache.remove(&key).is_some() {
            cache_metrics::record_git_cache_eviction(&key, "invalidated");
        }
    }
}

/// 实际执行 git status 查询（无缓存）
fn git_status_uncached(workspace_root: &Path) -> Result<GitStatusResult, GitError> {
    let repo = match gix::discover(workspace_root) {
        Ok(repo) => repo,
        Err(_) => {
            return Ok(GitStatusResult {
                repo_root: String::new(),
                items: vec![],
                has_staged_changes: false,
                staged_count: 0,
                current_branch: None,
                default_branch: None,
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
    // gix 的状态扫描在不写回的情况下功能是完整的，只是少了性能缓存优化。

    sort_status_items(&mut items);

    let staged_count = items.iter().filter(|item| item.staged).count();
    let has_staged_changes = staged_count > 0;

    Ok(GitStatusResult {
        repo_root,
        items,
        has_staged_changes,
        staged_count,
        current_branch: None,
        default_branch: None,
        ahead_by: None,
        behind_by: None,
        compared_branch: None,
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
}
