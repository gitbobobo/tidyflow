use chrono::Utc;
use std::path::{Path, PathBuf};

const MAX_VALIDATION_ATTEMPTS_PER_STAGE: usize = 8;
const MAX_VALIDATION_ISSUES_PER_ATTEMPT: usize = 16;
const MAX_VALIDATION_MESSAGE_CHARS: usize = 1_200;
const MAX_VALIDATION_ISSUE_CHARS: usize = 800;
const MAX_VALIDATION_SESSION_ID_CHARS: usize = 200;

fn normalized_jsonc_path(path: &Path) -> PathBuf {
    if path
        .extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| ext.eq_ignore_ascii_case("json"))
        .unwrap_or(false)
    {
        let mut buf = path.to_path_buf();
        buf.set_extension("jsonc");
        return buf;
    }
    path.to_path_buf()
}

fn strip_jsonc_comments(input: &str) -> String {
    #[derive(Clone, Copy, PartialEq, Eq)]
    enum State {
        Normal,
        InString,
        InLineComment,
        InBlockComment,
    }

    let mut chars = input.char_indices().peekable();
    let mut out = String::with_capacity(input.len());
    let mut state = State::Normal;
    let mut escaped = false;

    while let Some((_, ch)) = chars.next() {
        match state {
            State::Normal => {
                if ch == '"' {
                    state = State::InString;
                    out.push(ch);
                    continue;
                }
                if ch == '/' {
                    let next = chars.peek().map(|(_, next)| *next);
                    if next == Some('/') {
                        state = State::InLineComment;
                        chars.next();
                        continue;
                    }
                    if next == Some('*') {
                        state = State::InBlockComment;
                        chars.next();
                        continue;
                    }
                }
                out.push(ch);
            }
            State::InString => {
                out.push(ch);
                if escaped {
                    escaped = false;
                } else if ch == '\\' {
                    escaped = true;
                } else if ch == '"' {
                    state = State::Normal;
                }
            }
            State::InLineComment => {
                if ch == '\n' {
                    out.push('\n');
                    state = State::Normal;
                }
            }
            State::InBlockComment => {
                if ch == '\n' {
                    out.push('\n');
                    continue;
                }
                if ch == '*' && chars.peek().map(|(_, next)| *next) == Some('/') {
                    state = State::Normal;
                    chars.next();
                    continue;
                }
            }
        }
    }

    out
}

fn truncate_chars(input: &str, max_chars: usize) -> String {
    if max_chars == 0 {
        return String::new();
    }
    if input.chars().count() <= max_chars {
        return input.to_string();
    }

    let keep = max_chars.saturating_sub(9).max(1);
    let mut out = String::with_capacity(max_chars + 16);
    for ch in input.chars().take(keep) {
        out.push(ch);
    }
    out.push_str("...[已截断]");
    out
}

fn sanitize_validation_attempt_object(
    obj: &serde_json::Map<String, serde_json::Value>,
) -> serde_json::Value {
    let mut sanitized = serde_json::Map::new();

    for key in ["attempt", "error_code", "ts"] {
        if let Some(value) = obj.get(key) {
            sanitized.insert(key.to_string(), value.clone());
        }
    }

    if let Some(message) = obj.get("message").and_then(|value| value.as_str()) {
        sanitized.insert(
            "message".to_string(),
            serde_json::Value::String(truncate_chars(message.trim(), MAX_VALIDATION_MESSAGE_CHARS)),
        );
    }

    if let Some(session_id) = obj.get("session_id").and_then(|value| value.as_str()) {
        sanitized.insert(
            "session_id".to_string(),
            serde_json::Value::String(truncate_chars(
                session_id.trim(),
                MAX_VALIDATION_SESSION_ID_CHARS,
            )),
        );
    }

    let issues = obj
        .get("issues")
        .and_then(|value| value.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|issue| issue.as_str())
                .take(MAX_VALIDATION_ISSUES_PER_ATTEMPT)
                .map(|issue| {
                    serde_json::Value::String(truncate_chars(
                        issue.trim(),
                        MAX_VALIDATION_ISSUE_CHARS,
                    ))
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    sanitized.insert("issues".to_string(), serde_json::Value::Array(issues));

    serde_json::Value::Object(sanitized)
}

pub(super) fn sanitize_validation_attempt(value: serde_json::Value) -> serde_json::Value {
    match value {
        serde_json::Value::Object(obj) => sanitize_validation_attempt_object(&obj),
        _ => serde_json::json!({}),
    }
}

pub(super) fn sanitize_validation_attempts(value: Option<&serde_json::Value>) -> serde_json::Value {
    let Some(items) = value.and_then(|value| value.as_array()) else {
        return serde_json::json!([]);
    };

    let start = items
        .len()
        .saturating_sub(MAX_VALIDATION_ATTEMPTS_PER_STAGE);
    serde_json::Value::Array(
        items[start..]
            .iter()
            .cloned()
            .map(sanitize_validation_attempt)
            .collect(),
    )
}

pub(super) fn write_json(path: &Path, value: &serde_json::Value) -> Result<(), String> {
    let path = normalized_jsonc_path(path);
    let data = serde_json::to_string_pretty(value).map_err(|e| e.to_string())?;
    std::fs::write(&path, data).map_err(|e| e.to_string())
}

pub(super) fn write_jsonc_text(path: &Path, content: &str) -> Result<(), String> {
    let path = normalized_jsonc_path(path);
    std::fs::write(&path, content).map_err(|e| e.to_string())
}

pub(super) fn read_json(path: &Path) -> Result<serde_json::Value, String> {
    let path = normalized_jsonc_path(path);
    let content = std::fs::read_to_string(&path)
        .map_err(|e| format!("读取 {} 失败: {}", path.display(), e))?;
    let stripped = strip_jsonc_comments(&content);
    serde_json::from_str::<serde_json::Value>(&stripped)
        .map_err(|e| format!("解析 {} 失败: {}", path.display(), e))
}

pub(super) fn cycle_dir_path(workspace_root: &str, cycle_id: &str) -> Result<PathBuf, String> {
    let root = workspace_root.trim();
    if root.is_empty() {
        return Err("workspace root is empty".to_string());
    }
    Ok(Path::new(root)
        .join(".tidyflow")
        .join("evolution")
        .join(cycle_id))
}

pub(super) fn evolution_workspace_dir(workspace_root: &str) -> Result<PathBuf, String> {
    let root = workspace_root.trim();
    if root.is_empty() {
        return Err("workspace root is empty".to_string());
    }
    Ok(Path::new(root).join(".tidyflow").join("evolution"))
}

/// 由系统在阶段产物写盘时自动注入或覆盖 updated_at（UTC RFC3339），
/// 代理无需提供该字段。文件不存在或格式不合法时返回 Err，不终止整体流程。
pub(super) fn inject_stage_artifact_updated_at(artifact_path: &Path) -> Result<(), String> {
    let mut value = read_json(artifact_path)?;
    if let Some(obj) = value.as_object_mut() {
        obj.insert(
            "updated_at".to_string(),
            serde_json::Value::String(Utc::now().to_rfc3339()),
        );
    }
    write_json(artifact_path, &value)
}

pub(super) fn workspace_key(project: &str, workspace: &str) -> String {
    // 使用长度前缀避免键碰撞：("a:b","c") 与 ("a","b:c") 不再冲突。
    format!(
        "p{}:{}|w{}:{}",
        project.len(),
        project,
        workspace.len(),
        workspace
    )
}

#[cfg(test)]
mod tests {
    use super::{read_json, sanitize_validation_attempts, workspace_key};
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn workspace_key_should_avoid_delimiter_collision() {
        let lhs = workspace_key("a:b", "c");
        let rhs = workspace_key("a", "b:c");
        assert_ne!(lhs, rhs);
    }

    #[test]
    fn workspace_key_should_remain_stable_for_same_input() {
        let first = workspace_key("demo", "default");
        let second = workspace_key("demo", "default");
        assert_eq!(first, second);
    }

    #[test]
    fn read_json_should_accept_jsonc_comments() {
        let dir = tempdir().expect("tempdir should be created");
        let file = dir.path().join("sample.jsonc");
        fs::write(
            &file,
            r#"
            {
              // 行注释
              "name": "tidyflow",
              "nested": {
                /* 块注释 */
                "enabled": true
              }
            }
            "#,
        )
        .expect("jsonc file should be written");

        let value = read_json(&file).expect("jsonc should parse");
        assert_eq!(value["name"], serde_json::json!("tidyflow"));
        assert_eq!(value["nested"]["enabled"], serde_json::json!(true));
    }

    #[test]
    fn read_json_should_preserve_utf8_strings() {
        let dir = tempdir().expect("tempdir should be created");
        let file = dir.path().join("unicode.jsonc");
        fs::write(
            &file,
            r#"
            {
              // 中文注释
              "title": "当前项目质量基线",
              "items": ["跨平台", "错误码", "验收标准"]
            }
            "#,
        )
        .expect("unicode jsonc file should be written");

        let value = read_json(&file).expect("unicode jsonc should parse");
        assert_eq!(value["title"], serde_json::json!("当前项目质量基线"));
        assert_eq!(value["items"][0], serde_json::json!("跨平台"));
        assert_eq!(value["items"][1], serde_json::json!("错误码"));
    }

    #[test]
    fn read_json_should_reject_json5_trailing_comma() {
        let dir = tempdir().expect("tempdir should be created");
        let file = dir.path().join("invalid.jsonc");
        fs::write(
            &file,
            r#"
            {
              "name": "tidyflow",
            }
            "#,
        )
        .expect("invalid jsonc file should be written");

        let err = read_json(&file).expect_err("trailing comma should be rejected");
        assert!(
            err.contains("解析"),
            "error should come from strict JSON parser, got: {}",
            err
        );
    }

    #[test]
    fn sanitize_validation_attempts_should_limit_size() {
        let issue = "错".repeat(2_000);
        let attempts = serde_json::json!((0..12)
            .map(|idx| serde_json::json!({
                "attempt": idx + 1,
                "error_code": "artifact_contract_violation",
                "message": format!("第{}次失败：{}", idx + 1, issue),
                "issues": vec![issue.clone(); 24],
                "session_id": "sess".repeat(80),
                "ts": "2026-03-06T12:00:00Z",
            }))
            .collect::<Vec<_>>());

        let sanitized = sanitize_validation_attempts(Some(&attempts));
        let items = sanitized
            .as_array()
            .expect("sanitized attempts should be array");
        assert_eq!(items.len(), 8);
        assert_eq!(items[0]["attempt"], serde_json::json!(5));
        assert_eq!(
            items[7]["issues"]
                .as_array()
                .expect("issues should remain array")
                .len(),
            16
        );
        assert!(items[0]["message"].as_str().unwrap().chars().count() <= 1_200);
        assert!(items[0]["issues"][0].as_str().unwrap().chars().count() <= 800);
        assert!(items[0]["session_id"].as_str().unwrap().chars().count() <= 200);
    }
}
