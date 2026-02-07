//! Git status query functions
//!
//! Provides functions to query git status, log, and show commit details.

use std::collections::HashMap;
use std::path::Path;
use std::process::Command;
use std::sync::{LazyLock, Mutex};
use std::time::Instant;

use super::utils::*;

/// 缓存条目
struct CacheEntry {
    result: GitStatusResult,
    created_at: Instant,
}

/// 缓存 TTL（1 秒）
const CACHE_TTL_SECS: u64 = 1;

/// 全局 git status 缓存
static GIT_STATUS_CACHE: LazyLock<Mutex<HashMap<String, CacheEntry>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// 获取 diff 行数统计
/// 返回 HashMap<路径, (新增行数, 删除行数)>，二进制文件返回 (None, None)
fn get_diff_numstat(
    workspace_root: &Path,
    staged: bool,
) -> HashMap<String, (Option<i32>, Option<i32>)> {
    let mut args = vec!["diff", "--numstat"];
    if staged {
        args.push("--cached");
    }

    let output = match Command::new("git")
        .args(&args)
        .current_dir(workspace_root)
        .output()
    {
        Ok(o) => o,
        Err(_) => return HashMap::new(),
    };

    if !output.status.success() {
        return HashMap::new();
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut result = HashMap::new();

    for line in stdout.lines() {
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.len() >= 3 {
            let path = parts[2].to_string();
            // 二进制文件显示为 "-\t-\t<path>"
            let additions = parts[0].parse::<i32>().ok();
            let deletions = parts[1].parse::<i32>().ok();
            result.insert(path, (additions, deletions));
        }
    }

    result
}

/// 单字符 (X 或 Y) 转状态码
fn char_to_code(c: char) -> String {
    match c {
        '?' => "??".to_string(),
        '!' => "!!".to_string(),
        'M' => "M".to_string(),
        'A' => "A".to_string(),
        'D' => "D".to_string(),
        'R' => "R".to_string(),
        'C' => "C".to_string(),
        'U' => "U".to_string(),
        _ => c.to_string(),
    }
}

/// Parse git status --porcelain=v1 -z output
///
/// Format: XY PATH\0 or XY ORIG_PATH\0PATH\0 for renames
/// X = index (staged), Y = work tree (unstaged). 每条线可产生 0/1/2 条记录以区分暂存/未暂存。
pub(super) fn parse_porcelain_status(output: &str) -> Vec<GitStatusEntry> {
    let mut items = Vec::new();
    let parts: Vec<&str> = output.split('\0').collect();

    let mut i = 0;
    while i < parts.len() {
        let part = parts[i];
        if part.is_empty() {
            i += 1;
            continue;
        }

        if part.len() < 3 {
            i += 1;
            continue;
        }

        let x = part.chars().next().unwrap_or(' ');
        let y = part.chars().nth(1).unwrap_or(' ');
        let path_str = &part[3..];

        // Rename/copy: XY ORIG\0NEW\0 → 用 new_path 作为 path，orig_path 为 ORIG
        let (path, orig_path, advance) = if (x == 'R' || x == 'C' || y == 'R' || y == 'C')
            && i + 1 < parts.len()
            && !parts[i + 1].is_empty()
        {
            (parts[i + 1].to_string(), Some(path_str.to_string()), 2)
        } else {
            (path_str.to_string(), None, 1)
        };

        // ??/!! 仅一条，视为未暂存
        if (x == '?' && y == '?') || (x == '!' && y == '!') {
            items.push(GitStatusEntry {
                path: path.clone(),
                code: if x == '?' { "??".into() } else { "!!".into() },
                orig_path: orig_path.clone(),
                staged: false,
                additions: None,
                deletions: None,
            });
            i += advance;
            continue;
        }

        // 否则按 X/Y 分别产出：X != ' ' → 暂存一条，Y != ' ' → 未暂存一条
        if x != ' ' {
            items.push(GitStatusEntry {
                path: path.clone(),
                code: char_to_code(x),
                orig_path: orig_path.clone(),
                staged: true,
                additions: None,
                deletions: None,
            });
        }
        if y != ' ' {
            items.push(GitStatusEntry {
                path: path.clone(),
                code: char_to_code(y),
                orig_path: orig_path.clone(),
                staged: false,
                additions: None,
                deletions: None,
            });
        }
        i += advance;
    }

    items
}

/// Parse XY status code to simplified code (保留供测试使用)
#[cfg(test)]
fn parse_status_code(xy: &str) -> String {
    let x = xy.chars().next().unwrap_or(' ');
    let y = xy.chars().nth(1).unwrap_or(' ');

    match (x, y) {
        ('?', '?') => "??".to_string(),
        ('!', '!') => "!!".to_string(),
        ('R', _) | (_, 'R') => "R".to_string(),
        ('C', _) | (_, 'C') => "C".to_string(),
        ('A', _) | (_, 'A') => "A".to_string(),
        ('D', _) | (_, 'D') => "D".to_string(),
        ('M', _) | (_, 'M') => "M".to_string(),
        ('U', _) | (_, 'U') => "U".to_string(),
        _ => {
            if x != ' ' {
                x.to_string()
            } else if y != ' ' {
                y.to_string()
            } else {
                "M".to_string()
            }
        }
    }
}

/// Get git status for a workspace
///
/// Uses `git status --porcelain=v1 -z` for stable parsing.
/// Staged changes are derived from the parsed porcelain output.
pub fn git_status(workspace_root: &Path) -> Result<GitStatusResult, GitError> {
    let key = workspace_root.to_string_lossy().to_string();

    // 查缓存
    if let Ok(cache) = GIT_STATUS_CACHE.lock() {
        if let Some(entry) = cache.get(&key) {
            if entry.created_at.elapsed().as_secs() < CACHE_TTL_SECS {
                return Ok(entry.result.clone());
            }
        }
    }

    let result = git_status_uncached(workspace_root)?;

    // 写缓存
    if let Ok(mut cache) = GIT_STATUS_CACHE.lock() {
        cache.insert(
            key,
            CacheEntry {
                result: result.clone(),
                created_at: Instant::now(),
            },
        );
    }

    Ok(result)
}

/// 获取当前分支名。
///
/// 返回：
/// - Ok(Some(branch))：正常分支
/// - Ok(None)：detached HEAD 或非 git 仓库
/// - Err(_)：git 命令执行失败
pub fn git_current_branch(workspace_root: &Path) -> Result<Option<String>, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Ok(None);
    }

    let output = Command::new("git")
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(GitError::CommandFailed(format!(
            "Failed to get current branch: {}",
            if stderr.is_empty() {
                "Unknown error"
            } else {
                &stderr
            }
        )));
    }

    let branch = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if branch.is_empty() || branch == "HEAD" {
        return Ok(None);
    }

    Ok(Some(branch))
}

/// 计算当前分支相对本地默认分支的领先/落后提交数（不访问网络）。
pub fn check_branch_divergence_local(
    workspace_root: &Path,
    current_branch: &str,
    default_branch: &str,
) -> Result<BranchDivergenceResult, GitError> {
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    let default_ref = format!("refs/heads/{}", default_branch);
    let check_default = Command::new("git")
        .args(["show-ref", "--verify", "--quiet", &default_ref])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if !check_default.status.success() {
        return Err(GitError::CommandFailed(format!(
            "Local default branch '{}' not found",
            default_branch
        )));
    }

    let rev_list_output = Command::new("git")
        .args([
            "rev-list",
            "--left-right",
            "--count",
            &format!("{}...{}", current_branch, default_branch),
        ])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if !rev_list_output.status.success() {
        let stderr = String::from_utf8_lossy(&rev_list_output.stderr)
            .trim()
            .to_string();
        return Err(GitError::CommandFailed(format!(
            "Failed to compare local branches: {}",
            if stderr.is_empty() {
                "Unknown error"
            } else {
                &stderr
            }
        )));
    }

    let stdout = String::from_utf8_lossy(&rev_list_output.stdout);
    let parts: Vec<&str> = stdout.trim().split('\t').collect();
    if parts.len() != 2 {
        return Err(GitError::CommandFailed(format!(
            "Unexpected rev-list output format: '{}'",
            stdout.trim()
        )));
    }

    let ahead_by = parts[0]
        .parse::<i32>()
        .map_err(|e| GitError::CommandFailed(format!("Failed to parse ahead count: {}", e)))?;
    let behind_by = parts[1]
        .parse::<i32>()
        .map_err(|e| GitError::CommandFailed(format!("Failed to parse behind count: {}", e)))?;

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
        cache.remove(&key);
    }
}

/// 实际执行 git status 查询（无缓存）
fn git_status_uncached(workspace_root: &Path) -> Result<GitStatusResult, GitError> {
    // Check if it's a git repo
    let repo_root = match get_git_repo_root(workspace_root) {
        Some(root) => root,
        None => {
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

    // Run git status
    let output = Command::new("git")
        .args(["status", "--porcelain=v1", "-z"])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(GitError::CommandFailed(stderr.to_string()));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut items = parse_porcelain_status(&stdout);

    // 获取行数统计
    let unstaged_stats = get_diff_numstat(workspace_root, false);
    let staged_stats = get_diff_numstat(workspace_root, true);

    // 合并行数统计到每个 entry
    for item in &mut items {
        let stats = if item.staged {
            &staged_stats
        } else {
            &unstaged_stats
        };
        if let Some((additions, deletions)) = stats.get(&item.path) {
            item.additions = *additions;
            item.deletions = *deletions;
        }
    }

    // 从已解析的 items 推导暂存状态（无需额外子进程）
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

/// 获取单个文件的 git 状态码（仅 1 个子进程）
///
/// 返回 `Some((code, staged))` 或 `None`（文件无变更）。
pub fn git_file_status(workspace_root: &Path, path: &str) -> Option<(String, bool)> {
    let output = Command::new("git")
        .args(["status", "--porcelain=v1", "-z", "--", path])
        .current_dir(workspace_root)
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let items = parse_porcelain_status(&stdout);
    items.first().map(|item| (item.code.clone(), item.staged))
}

/// Get git log (commit history) for a workspace
///
/// Uses `git log --pretty=format:...` to get commit history.
/// Returns up to `limit` entries.
pub fn git_log(workspace_root: &Path, limit: usize) -> Result<GitLogResult, GitError> {
    // Check if it's a git repo
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    // 使用特定格式获取日志：SHA%x00subject%x00body%x00作者%x00日期%x00引用%x1e
    // %s=subject(首行) %b=body(正文，可含换行)，弹出层需要完整 message
    // %x00 = NUL 分隔字段，%x1e = Record Separator 分隔条目
    // 不使用 --no-walk，否则 git 不遍历历史，只显示 HEAD（1 条）
    let format = "%h%x00%s%x00%b%x00%an%x00%aI%x00%D%x1e";

    let output = Command::new("git")
        .args([
            "log",
            &format!("--pretty=format:{}", format),
            &format!("-{}", limit),
        ])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        // 如果没有提交，返回空列表
        if stderr.contains("does not have any commits") {
            return Ok(GitLogResult { entries: vec![] });
        }
        return Err(GitError::CommandFailed(stderr.to_string()));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut entries = Vec::new();

    // 按 Record Separator 分割条目
    for record in stdout.split('\x1e') {
        let record = record.trim();
        if record.is_empty() {
            continue;
        }

        let fields: Vec<&str> = record.split('\x00').collect();
        // 6 字段：hash, subject, body, author, date, refs
        if fields.len() >= 6 {
            let sha = fields[0].to_string();
            let subject = fields[1].trim();
            let body = fields[2].trim();
            let message = if body.is_empty() {
                subject.to_string()
            } else {
                format!("{}\n\n{}", subject, body)
            };
            let author = fields[3].to_string();
            let date = fields[4].to_string();
            // 解析引用（如 "HEAD -> main, origin/main, tag: v1.0"）
            let refs: Vec<String> = if !fields[5].is_empty() {
                fields[5]
                    .split(", ")
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .collect()
            } else {
                vec![]
            };

            entries.push(GitLogEntry {
                sha,
                message,
                author,
                date,
                refs,
            });
        }
    }

    Ok(GitLogResult { entries })
}

/// Get details for a single commit
///
/// Uses `git show --name-status --format=...` to get commit details and changed files.
pub fn git_show(workspace_root: &Path, sha: &str) -> Result<GitShowResult, GitError> {
    // Check if it's a git repo
    if get_git_repo_root(workspace_root).is_none() {
        return Err(GitError::NotAGitRepo);
    }

    // 验证 SHA 格式，防止命令注入
    if !sha.chars().all(|c| c.is_ascii_hexdigit()) || sha.is_empty() || sha.len() > 40 {
        return Err(GitError::CommandFailed("Invalid SHA format".to_string()));
    }

    // 获取提交元信息：%H (full SHA), %h (short SHA), %s (subject), %b (body), %an (author), %ae (email), %aI (date)
    let format = "%H%x00%h%x00%s%x00%b%x00%an%x00%ae%x00%aI";

    let output = Command::new("git")
        .args([
            "show",
            "--name-status",
            &format!("--pretty=format:{}", format),
            sha,
        ])
        .current_dir(workspace_root)
        .output()
        .map_err(GitError::IoError)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(GitError::CommandFailed(stderr.to_string()));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let s = stdout.as_ref();

    // 元信息格式：%H\0%h\0%s\0%b\0%an\0%ae\0%aI\n，其中 %b 可能含换行，不能按「第一行」解析
    // 定位第 6 个 NUL，其前为 6 个字段（full_sha, short_sha, subject, body, author, author_email），其后到 \n 为 date
    let mut nul_count = 0u32;
    let mut pos_after_6th_nul = None::<usize>;
    for (i, c) in s.char_indices() {
        if c == '\x00' {
            nul_count += 1;
            if nul_count == 6 {
                pos_after_6th_nul = Some(i + 1);
                break;
            }
        }
    }
    let pos_after_6th_nul = pos_after_6th_nul.ok_or_else(|| {
        GitError::CommandFailed("Invalid git show output: missing NULs".to_string())
    })?;
    let rest = &s[pos_after_6th_nul..];
    let newline_pos = rest.find('\n').ok_or_else(|| {
        GitError::CommandFailed("Invalid git show output: missing newline after date".to_string())
    })?;
    let date = rest[..newline_pos].trim().to_string();
    let file_list_start = pos_after_6th_nul + newline_pos + 1;

    let header_part = &s[..pos_after_6th_nul - 1];
    let fields: Vec<&str> = header_part.split('\x00').collect();
    if fields.len() < 6 {
        return Err(GitError::CommandFailed(
            "Invalid git show output format (header fields)".to_string(),
        ));
    }
    let full_sha = fields[0].to_string();
    let short_sha = fields[1].to_string();
    let subject = fields[2].to_string();
    let body = fields[3].trim().to_string();
    let author = fields[4].to_string();
    let author_email = fields[5].to_string();

    // 组合完整消息
    let message = if body.is_empty() {
        subject
    } else {
        format!("{}\n\n{}", subject, body)
    };

    // 解析文件变更列表：STATUS\tPATH 或 STATUS\tOLD_PATH\tNEW_PATH（重命名）
    let mut files = Vec::new();
    for line in s[file_list_start..].lines() {
        let line = line.trim();

        // 跳过空行
        if line.is_empty() {
            continue;
        }

        // 尝试解析为文件变更行：STATUS\tPATH
        let parts: Vec<&str> = line.split('\t').collect();

        if parts.len() >= 2 {
            // 检查第一部分是否是有效的状态码（M, A, D, R100 等）
            let status_part = parts[0];
            let first_char = status_part.chars().next().unwrap_or('?');

            // 有效的 git 状态码：M, A, D, R, C, T, U, X, B
            if "MADRCTUXYB".contains(first_char) {
                let status = first_char.to_string();
                let (path, old_path) = if parts.len() >= 3 && (status == "R" || status == "C") {
                    // 重命名/复制: R100\told_path\tnew_path
                    (parts[2].to_string(), Some(parts[1].to_string()))
                } else {
                    (parts[1].to_string(), None)
                };

                files.push(GitShowFileEntry {
                    status,
                    path,
                    old_path,
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
    fn test_parse_status_code() {
        assert_eq!(parse_status_code("??"), "??");
        assert_eq!(parse_status_code(" M"), "M");
        assert_eq!(parse_status_code("M "), "M");
        assert_eq!(parse_status_code("MM"), "M");
        assert_eq!(parse_status_code("A "), "A");
        assert_eq!(parse_status_code(" A"), "A");
        assert_eq!(parse_status_code("D "), "D");
        assert_eq!(parse_status_code("R "), "R");
    }

    #[test]
    fn test_parse_porcelain_status() {
        // 未暂存修改 (X=space, Y=M)
        let output = " M src/main.rs\0";
        let items = parse_porcelain_status(output);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].path, "src/main.rs");
        assert_eq!(items[0].code, "M");
        assert!(!items[0].staged);

        // 已暂存修改 (X=M, Y=space)
        let output = "M  staged.rs\0";
        let items = parse_porcelain_status(output);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].path, "staged.rs");
        assert_eq!(items[0].code, "M");
        assert!(items[0].staged);

        // Untracked file
        let output = "?? new-file.txt\0";
        let items = parse_porcelain_status(output);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].path, "new-file.txt");
        assert_eq!(items[0].code, "??");
        assert!(!items[0].staged);
    }
}
