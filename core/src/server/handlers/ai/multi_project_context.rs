//! 多项目上下文聚合模块
//!
//! 负责从消息中解析 `@project-name` 提及，并收集对应项目的 Git 状态摘要，
//! 在发送给 AI 之前将上下文前置追加到消息内容中。

use std::collections::HashMap;
use std::path::Path;
use std::process::Command;

use crate::server::protocol::ai::ProjectContextSummary;

// ============================================================================
// 提取项目提及
// ============================================================================

/// 从消息文本中提取 `@@project-name` 提及（双 @ 为项目引用，单 `@` 为文件引用）。
///
/// 匹配规则：`@@` 或 `＠＠` 后紧跟 `[A-Za-z0-9_\-\.]+`（不含 `/`，避免与文件路径混淆）。
/// 返回去重后的项目名称列表，保持首次出现顺序。
pub fn extract_project_mentions(message: &str) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut result = Vec::new();
    let chars: Vec<char> = message.chars().collect();
    let len = chars.len();
    let mut i = 0;
    while i < len {
        // 检测双 ASCII @@ 或双全角 ＠＠
        let is_double_at = (chars[i] == '@' && i + 1 < len && chars[i + 1] == '@')
            || (chars[i] == '＠' && i + 1 < len && chars[i + 1] == '＠');

        if is_double_at {
            // 跳过两个 @ 字符
            i += 2;
            // 收集项目名：[A-Za-z0-9_\-\.]
            let start = i;
            while i < len && is_project_name_char(chars[i]) {
                i += 1;
            }
            if i > start {
                let name: String = chars[start..i].iter().collect();
                if seen.insert(name.clone()) {
                    result.push(name);
                }
            }
        } else {
            i += 1;
        }
    }
    result
}

/// 判断字符是否为合法项目名字符（字母、数字、`_`、`-`、`.`）
#[inline]
fn is_project_name_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.'
}

// ============================================================================
// 构建多项目上下文
// ============================================================================

/// 为每个被提及的项目收集 Git 状态摘要，返回 `ProjectContextSummary` 列表。
///
/// - `mentions`: 需要收集上下文的项目名称列表
/// - `projects`: 项目名称 -> workspace 根目录路径 的映射
/// - `workspace_root`: 回退根目录（当 projects 中找不到时尝试 `workspace_root/project_name`）
pub fn build_multi_project_context(
    mentions: &[String],
    projects: &HashMap<String, String>,
    workspace_root: &Path,
) -> Vec<ProjectContextSummary> {
    mentions
        .iter()
        .map(|name| {
            let dir = projects
                .get(name)
                .map(|s| s.as_str().to_string())
                .unwrap_or_else(|| workspace_root.join(name).to_string_lossy().into_owned());

            let context_text = collect_git_context(&dir);
            ProjectContextSummary {
                project_name: name.clone(),
                context_text,
            }
        })
        .collect()
}

/// 基于已持久化上下文快照构建多项目上下文。
///
/// - `mentions`: 需要收集上下文的项目名称列表
/// - `snapshots`: 项目名称 -> 上下文快照 的映射（来自已持久化的 session_index）
/// - `projects`: 项目名称 -> workspace 根目录路径 的映射（用于 git fallback）
/// - `workspace_root`: 回退根目录
pub fn build_multi_project_context_with_snapshots(
    mentions: &[String],
    snapshots: &HashMap<String, crate::server::protocol::ai::AiSessionContextSnapshot>,
    projects: &HashMap<String, String>,
    workspace_root: &Path,
) -> Vec<ProjectContextSummary> {
    mentions
        .iter()
        .map(|name| {
            let context_text = if let Some(snap) = snapshots.get(name) {
                build_context_from_snapshot(name, snap)
            } else {
                let dir = projects
                    .get(name)
                    .map(|s| s.as_str().to_string())
                    .unwrap_or_else(|| workspace_root.join(name).to_string_lossy().into_owned());
                collect_git_context(&dir)
            };
            ProjectContextSummary {
                project_name: name.clone(),
                context_text,
            }
        })
        .collect()
}

/// 从上下文快照构建注入文本（供跨工作区引用时使用）
fn build_context_from_snapshot(
    project_name: &str,
    snapshot: &crate::server::protocol::ai::AiSessionContextSnapshot,
) -> String {
    let mut parts = Vec::new();
    if let Some(summary) = &snapshot.context_summary {
        if !summary.trim().is_empty() {
            parts.push(format!(
                "## 会话摘要（来自 {}）\n{}",
                snapshot.session_id,
                summary.trim()
            ));
        }
    }
    if let Some(hint) = &snapshot.selection_hint {
        let mut hint_parts = Vec::new();
        if let Some(agent) = &hint.agent {
            hint_parts.push(format!("agent={}", agent));
        }
        if let Some(model) = &hint.model_id {
            hint_parts.push(format!("model={}", model));
        }
        if !hint_parts.is_empty() {
            parts.push(format!("## 模型配置\n{}", hint_parts.join(", ")));
        }
    }
    if parts.is_empty() {
        format!("[项目 {} 有会话历史但无可用摘要]", project_name)
    } else {
        parts.join("\n\n")
    }
}

/// 在给定目录运行 git status --short 和 git log --oneline -3，
/// 拼成文本摘要（最多 20 行 status + 3 行 log）。
fn collect_git_context(dir: &str) -> String {
    let status = run_git_command(dir, &["status", "--short"])
        .lines()
        .take(20)
        .collect::<Vec<_>>()
        .join("\n");

    let log = run_git_command(dir, &["log", "--oneline", "-3"]);

    let mut parts = Vec::new();
    if !status.trim().is_empty() {
        parts.push(format!("## git status\n{}", status.trim()));
    }
    if !log.trim().is_empty() {
        parts.push(format!("## 最近提交\n{}", log.trim()));
    }

    if parts.is_empty() {
        format!("[项目 {} 无 Git 变动]", dir)
    } else {
        parts.join("\n\n")
    }
}

/// 在指定目录执行 git 命令，返回标准输出字符串；失败时返回空字符串。
fn run_git_command(dir: &str, args: &[&str]) -> String {
    Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

// ============================================================================
// 消息拼装
// ============================================================================

/// 将项目上下文摘要前置追加到原始消息中，格式如下：
///
/// ```text
/// [多项目上下文]
/// ### project-a
/// ## git status
/// ...
///
/// [原始消息]
/// ...
/// ```
pub fn append_project_context_to_message(
    message: &str,
    context: &[ProjectContextSummary],
) -> String {
    if context.is_empty() {
        return message.to_string();
    }

    let ctx_block = context
        .iter()
        .map(|c| format!("### {}\n{}", c.project_name, c.context_text))
        .collect::<Vec<_>>()
        .join("\n\n---\n\n");

    format!("[多项目上下文]\n\n{}\n\n[原始消息]\n{}", ctx_block, message)
}

// ============================================================================
// 单元测试
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_multi_project_context_extract_mentions() {
        let msg = "请检查 @@frontend 和 @@backend 的状态，另外 @file.rs 是文件引用";
        let mentions = extract_project_mentions(msg);
        assert_eq!(mentions, vec!["frontend", "backend"]);
    }

    #[test]
    fn test_multi_project_context_no_mentions() {
        let msg = "这条消息里没有项目引用，只有 @file.rs 文件引用";
        let mentions = extract_project_mentions(msg);
        assert!(mentions.is_empty(), "单 @ 不应被识别为项目提及");
    }

    #[test]
    fn test_multi_project_context_latency() {
        let start = std::time::Instant::now();
        let mentions: Vec<String> = vec![];
        let projects: HashMap<String, String> = HashMap::new();
        let root = Path::new("/tmp");
        let _ = build_multi_project_context(&mentions, &projects, root);
        let elapsed = start.elapsed();
        assert!(
            elapsed.as_millis() < 500,
            "空集合上下文构建耗时 {}ms，超过 500ms 预算",
            elapsed.as_millis()
        );
    }

    #[test]
    fn test_build_cross_workspace_context_with_snapshots() {
        use crate::server::protocol::ai::AiSessionContextSnapshot;
        use std::collections::HashMap;

        let mentions = vec!["backend".to_string()];
        let mut snapshots: HashMap<String, AiSessionContextSnapshot> = HashMap::new();
        snapshots.insert(
            "backend".to_string(),
            AiSessionContextSnapshot {
                project_name: "backend".to_string(),
                workspace_name: "default".to_string(),
                ai_tool: "codex".to_string(),
                session_id: "s1".to_string(),
                snapshot_at_ms: 1000,
                message_count: 10,
                context_summary: Some("已完成用户认证模块".to_string()),
                selection_hint: None,
                context_remaining_percent: Some(60.0),
            },
        );

        let result = build_multi_project_context_with_snapshots(
            &mentions,
            &snapshots,
            &HashMap::new(),
            Path::new("/tmp"),
        );

        assert_eq!(result.len(), 1);
        assert_eq!(result[0].project_name, "backend");
        assert!(
            result[0].context_text.contains("已完成用户认证模块"),
            "应包含快照摘要内容"
        );
    }

    #[test]
    fn test_cross_workspace_context_fallback_on_missing_snapshot() {
        use std::collections::HashMap;

        let mentions = vec!["frontend".to_string()];
        let result = build_multi_project_context_with_snapshots(
            &mentions,
            &HashMap::new(),
            &HashMap::new(),
            Path::new("/nonexistent/path"),
        );
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].project_name, "frontend");
    }
}
