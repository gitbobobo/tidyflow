use std::path::{Path, PathBuf};

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

    let bytes = input.as_bytes();
    let mut i = 0usize;
    let mut out = String::with_capacity(input.len());
    let mut state = State::Normal;
    let mut escaped = false;

    while i < bytes.len() {
        let ch = bytes[i] as char;
        match state {
            State::Normal => {
                if ch == '"' {
                    state = State::InString;
                    out.push(ch);
                    i += 1;
                    continue;
                }
                if ch == '/' && i + 1 < bytes.len() {
                    let next = bytes[i + 1] as char;
                    if next == '/' {
                        state = State::InLineComment;
                        i += 2;
                        continue;
                    }
                    if next == '*' {
                        state = State::InBlockComment;
                        i += 2;
                        continue;
                    }
                }
                out.push(ch);
                i += 1;
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
                i += 1;
            }
            State::InLineComment => {
                if ch == '\n' {
                    out.push('\n');
                    state = State::Normal;
                }
                i += 1;
            }
            State::InBlockComment => {
                if ch == '\n' {
                    out.push('\n');
                    i += 1;
                    continue;
                }
                if ch == '*' && i + 1 < bytes.len() && (bytes[i + 1] as char) == '/' {
                    state = State::Normal;
                    i += 2;
                    continue;
                }
                i += 1;
            }
        }
    }

    out
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
    let content =
        std::fs::read_to_string(&path).map_err(|e| format!("读取 {} 失败: {}", path.display(), e))?;
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
    use super::{read_json, workspace_key};
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
}
