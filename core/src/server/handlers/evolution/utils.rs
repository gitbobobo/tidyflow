use std::path::{Path, PathBuf};

pub(super) fn write_json(path: &Path, value: &serde_json::Value) -> Result<(), String> {
    let data = serde_json::to_string_pretty(value).map_err(|e| e.to_string())?;
    std::fs::write(path, data).map_err(|e| e.to_string())
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
    use super::workspace_key;

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
}
