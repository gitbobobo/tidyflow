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

pub(super) fn sanitize_name(raw: &str) -> String {
    raw.chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch
            } else {
                '_'
            }
        })
        .collect::<String>()
}

pub(super) fn evolution_workspace_dir(workspace_root: &str) -> Result<PathBuf, String> {
    let root = workspace_root.trim();
    if root.is_empty() {
        return Err("workspace root is empty".to_string());
    }
    Ok(Path::new(root).join(".tidyflow").join("evolution"))
}

pub(super) fn workspace_key(project: &str, workspace: &str) -> String {
    format!("{}:{}", project, workspace)
}

fn bootstrap_state_path(workspace_root: &str) -> Result<PathBuf, String> {
    Ok(evolution_workspace_dir(workspace_root)?.join("bootstrap.state.json"))
}

pub(super) fn bootstrap_skip_reason(workspace_root: &str) -> Result<Option<String>, String> {
    let path = bootstrap_state_path(workspace_root)?;
    if !path.exists() {
        return Ok(None);
    }

    let content = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
    let json: serde_json::Value = serde_json::from_str(&content).map_err(|e| e.to_string())?;
    let status = json
        .get("status")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .trim()
        .to_lowercase();
    if status != "ready" {
        return Ok(None);
    }

    let stored_fingerprint = json
        .get("project_fingerprint")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .trim()
        .to_string();
    if stored_fingerprint.is_empty() {
        return Ok(None);
    }

    let current_fingerprint = compute_project_fingerprint(Path::new(workspace_root));
    if stored_fingerprint == current_fingerprint {
        return Ok(Some(format!(
            "bootstrap.state.json is ready and fingerprint matched ({})",
            current_fingerprint
        )));
    }

    Ok(None)
}

fn compute_project_fingerprint(workspace_root: &Path) -> String {
    let candidates = [
        "Cargo.toml",
        "Cargo.lock",
        "package.json",
        "package-lock.json",
        "pnpm-lock.yaml",
        "yarn.lock",
        "pyproject.toml",
        "requirements.txt",
        "go.mod",
        "go.sum",
        "Package.swift",
        "Podfile",
        "Gemfile",
        "app/TidyFlow.xcodeproj/project.pbxproj",
        ".git/HEAD",
    ];
    let mut lines = Vec::with_capacity(candidates.len());

    for rel in candidates {
        let path = workspace_root.join(rel);
        if !path.exists() {
            lines.push(format!("{}|missing", rel));
            continue;
        }

        let meta = match std::fs::metadata(&path) {
            Ok(meta) => meta,
            Err(_) => {
                lines.push(format!("{}|metadata_error", rel));
                continue;
            }
        };

        let size = meta.len();
        let modified = meta
            .modified()
            .ok()
            .and_then(|v| v.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|v| v.as_secs())
            .unwrap_or(0);
        let content_hash = if size <= 1024 * 1024 {
            std::fs::read(&path)
                .ok()
                .map(|bytes| fnv1a64(&bytes))
                .unwrap_or(0)
        } else {
            0
        };
        lines.push(format!(
            "{}|size={}|modified={}|hash={:016x}",
            rel, size, modified, content_hash
        ));
    }

    format!("{:016x}", fnv1a64(lines.join("\n").as_bytes()))
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf29ce484222325u64;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}
