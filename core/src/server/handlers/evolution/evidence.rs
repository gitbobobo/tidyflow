use std::collections::HashSet;
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Component, Path, PathBuf};

use chrono::Utc;
use serde::Deserialize;
use walkdir::WalkDir;

use crate::server::context::{resolve_workspace, HandlerContext};
use crate::server::protocol::{
    EvolutionEvidenceIssueInfo, EvolutionEvidenceItemInfo, EvolutionEvidenceSubsystemInfo,
};

use super::EvolutionManager;

const EVIDENCE_ROOT_RELATIVE: &str = ".tidyflow/evidence";
const EVIDENCE_INDEX_RELATIVE: &str = ".tidyflow/evidence/evidence.index.json";
const CHUNK_DEFAULT_LIMIT: usize = 256 * 1024;
const CHUNK_MAX_LIMIT: usize = 512 * 1024;

const ALLOWED_TYPES: &[&str] = &["screenshot", "log"];
const DEVICE_TYPE_BASELINE: &[&str] = &[
    "iphone",
    "ipad",
    "apple-tv",
    "apple-watch",
    "vision-pro",
    "mac",
    "android-phone",
    "android-pad",
    "android-tv",
    "android-wear",
    "ohos-phone",
    "ohos-pad",
    "ohos-tv",
    "web",
    "web-mobile",
    "linux",
    "windows",
    "server",
];

#[derive(Debug)]
pub(super) struct EvidenceSnapshotPayload {
    pub(super) evidence_root: String,
    pub(super) index_file: String,
    pub(super) index_exists: bool,
    pub(super) detected_subsystems: Vec<EvolutionEvidenceSubsystemInfo>,
    pub(super) detected_device_types: Vec<String>,
    pub(super) items: Vec<EvolutionEvidenceItemInfo>,
    pub(super) issues: Vec<EvolutionEvidenceIssueInfo>,
    pub(super) updated_at: String,
}

#[derive(Debug)]
pub(super) struct EvidenceRebuildPromptPayload {
    pub(super) prompt: String,
    pub(super) evidence_root: String,
    pub(super) index_file: String,
    pub(super) detected_subsystems: Vec<EvolutionEvidenceSubsystemInfo>,
    pub(super) detected_device_types: Vec<String>,
    pub(super) generated_at: String,
}

#[derive(Debug)]
pub(super) struct EvidenceChunkPayload {
    pub(super) item_id: String,
    pub(super) offset: u64,
    pub(super) next_offset: u64,
    pub(super) eof: bool,
    pub(super) total_size_bytes: u64,
    pub(super) mime_type: String,
    pub(super) content: Vec<u8>,
}

#[derive(Debug, Deserialize)]
struct EvidenceIndexRaw {
    #[serde(rename = "$schema_version")]
    schema_version: Option<String>,
    updated_at: Option<String>,
    items: Vec<EvidenceItemRaw>,
}

#[derive(Debug, Deserialize)]
struct EvidenceItemRaw {
    id: String,
    device_type: String,
    #[serde(rename = "type")]
    evidence_type: String,
    order: u32,
    path: String,
    title: String,
    description: String,
    scenario: Option<String>,
    subsystem: Option<String>,
    created_at: Option<String>,
}

#[derive(Debug, Clone)]
struct ValidatedEvidenceItem {
    item_id: String,
    device_type: String,
    evidence_type: String,
    order: u32,
    path: String,
    title: String,
    description: String,
    scenario: Option<String>,
    subsystem: Option<String>,
    created_at: Option<String>,
    full_path: PathBuf,
}

#[derive(Debug)]
struct ValidatedEvidenceIndex {
    updated_at: String,
    items: Vec<ValidatedEvidenceItem>,
    issues: Vec<EvolutionEvidenceIssueInfo>,
}

impl EvolutionManager {
    pub(super) async fn get_evidence_snapshot(
        &self,
        project: &str,
        workspace: &str,
        ctx: &HandlerContext,
    ) -> Result<EvidenceSnapshotPayload, String> {
        let ws = resolve_workspace(&ctx.app_state, project, workspace)
            .await
            .map_err(|e| e.to_string())?;
        let workspace_root = ws.root_path.clone();

        tokio::task::spawn_blocking(move || build_snapshot_sync(&workspace_root))
            .await
            .map_err(|e| format!("build evidence snapshot task failed: {}", e))?
    }

    pub(super) async fn get_evidence_rebuild_prompt(
        &self,
        project: &str,
        workspace: &str,
        ctx: &HandlerContext,
    ) -> Result<EvidenceRebuildPromptPayload, String> {
        let ws = resolve_workspace(&ctx.app_state, project, workspace)
            .await
            .map_err(|e| e.to_string())?;
        let workspace_root = ws.root_path.clone();
        let project_name = project.to_string();
        let workspace_name = workspace.to_string();

        tokio::task::spawn_blocking(move || {
            build_rebuild_prompt_sync(&workspace_root, &project_name, &workspace_name)
        })
        .await
        .map_err(|e| format!("build evidence rebuild prompt task failed: {}", e))?
    }

    pub(super) async fn read_evidence_item_chunk(
        &self,
        project: &str,
        workspace: &str,
        item_id: &str,
        offset: u64,
        limit: Option<u32>,
        ctx: &HandlerContext,
    ) -> Result<EvidenceChunkPayload, String> {
        let ws = resolve_workspace(&ctx.app_state, project, workspace)
            .await
            .map_err(|e| e.to_string())?;
        let workspace_root = ws.root_path.clone();
        let item_id = item_id.to_string();

        tokio::task::spawn_blocking(move || {
            read_evidence_item_chunk_sync(&workspace_root, &item_id, offset, limit)
        })
        .await
        .map_err(|e| format!("read evidence item chunk task failed: {}", e))?
    }
}

fn build_snapshot_sync(workspace_root: &Path) -> Result<EvidenceSnapshotPayload, String> {
    let evidence_root = workspace_root.join(EVIDENCE_ROOT_RELATIVE);
    let index_file = workspace_root.join(EVIDENCE_INDEX_RELATIVE);

    let detected_subsystems = detect_subsystems(workspace_root);
    let mut detected_device_types = detect_device_types(workspace_root, &evidence_root);
    let mut issues: Vec<EvolutionEvidenceIssueInfo> = Vec::new();
    let mut items: Vec<EvolutionEvidenceItemInfo> = Vec::new();
    let updated_at: String;
    let index_exists = index_file.exists();

    if index_exists {
        match load_and_validate_index(&index_file, &evidence_root) {
            Ok(index) => {
                updated_at = index.updated_at;
                issues.extend(index.issues);
                for item in index.items {
                    let metadata = fs::metadata(&item.full_path).ok();
                    let exists = metadata.is_some();
                    let size_bytes = metadata.map(|m| m.len()).unwrap_or(0);
                    if !exists {
                        issues.push(issue_warning(
                            "item_file_missing",
                            format!("证据文件不存在: {}", item.path),
                        ));
                    }
                    detected_device_types.push(item.device_type.clone());
                    items.push(EvolutionEvidenceItemInfo {
                        item_id: item.item_id,
                        device_type: item.device_type,
                        evidence_type: item.evidence_type,
                        order: item.order,
                        path: item.path.clone(),
                        title: item.title,
                        description: item.description,
                        scenario: item.scenario,
                        subsystem: item.subsystem,
                        created_at: item.created_at,
                        size_bytes,
                        exists,
                        mime_type: infer_mime_type(&item.path),
                    });
                }
            }
            Err(err) => {
                updated_at = now_rfc3339();
                issues.push(issue_warning("index_invalid", err));
            }
        }
    } else {
        updated_at = now_rfc3339();
        issues.push(issue_warning(
            "index_missing",
            format!("未找到证据索引文件: {}", index_file.display()),
        ));
    }

    dedup_sort_device_types(&mut detected_device_types);
    sort_evidence_items(&mut items);

    Ok(EvidenceSnapshotPayload {
        evidence_root: evidence_root.to_string_lossy().to_string(),
        index_file: index_file.to_string_lossy().to_string(),
        index_exists,
        detected_subsystems,
        detected_device_types,
        items,
        issues,
        updated_at,
    })
}

fn build_rebuild_prompt_sync(
    workspace_root: &Path,
    project: &str,
    workspace: &str,
) -> Result<EvidenceRebuildPromptPayload, String> {
    let evidence_root = workspace_root.join(EVIDENCE_ROOT_RELATIVE);
    let index_file = workspace_root.join(EVIDENCE_INDEX_RELATIVE);
    let detected_subsystems = detect_subsystems(workspace_root);
    let mut detected_device_types = detect_device_types(workspace_root, &evidence_root);
    dedup_sort_device_types(&mut detected_device_types);

    let prompt = format!(
        r#"请重建当前工作空间的全链路证据体系，并严格遵循以下规则。

【工作空间上下文】
- project: {project}
- workspace: {workspace}
- evidence_root: {evidence_root}
- evidence_index_file: {index_file}

【目标】
1. 识别仓库中的子系统与设备类型（device_type）。
2. 按 device_type 建立端到端测试基础设施与执行脚本。
3. 使用真实数据执行端到端流程并采集截图/日志。
4. 产出并维护 evidence.index.json，确保证据可追溯、可复核、可排序展示。

【目录与设备类型规则（高优先级）】
- evidence_root 下第一层目录必须是 device_type，所有 device_type 必须同级。
- 禁止创建 `custom/<device_type>/...`、`wrapper/<device_type>/...` 这类包裹目录，所有 device_type 必须直接落在 evidence_root 同级目录。
- 设备类型固定基线（默认全部覆盖，除非用户明确删减）：iphone、ipad、apple-tv、apple-watch、vision-pro、mac、android-phone、android-pad、android-tv、android-wear、ohos-phone、ohos-pad、ohos-tv、web、web-mobile、linux、windows、server。
- 每个 device_type 都必须有独立的 e2e 入口与证据子目录（示例：`<device_type>/e2e/...`）。
- 若某个 device_type 暂不支持真实执行，仍需保留该 device_type 的目录与计划项，并在输出里标记 `not_applicable` 与原因。
- 若扫描到基线之外的新设备类型，必须新增同级目录与对应 e2e 计划；禁止把多个设备类型合并到同一目录。

【evidence.index.json 契约（必须满足）】
```json
{{
  "$schema_version": "1.0",
  "updated_at": "RFC3339 UTC",
  "items": [
    {{
      "id": "ev-001",
      "device_type": "iphone",
      "type": "screenshot|log",
      "order": 10,
      "path": "iphone/e2e/login/login-01.png",
      "title": "登录页",
      "description": "输入手机号前状态",
      "scenario": "可选",
      "subsystem": "可选",
      "created_at": "可选"
    }}
  ]
}}
```
- 必填字段：id/device_type/type/order/path/title/description
- path 必须是相对 evidence_root 的相对路径，禁止绝对路径和 `..`，且首段必须是 device_type
- path 的首段必须与该条目的 device_type 完全一致（示例：device_type=android-phone 时，path 必须以 `android-phone/` 开头）
- order 用于同一 device_type 内时序排序，数值越小越靠前

【执行约束（强制）】
- 必须使用真实数据，禁止 mock，禁止占位，禁止伪造截图。
- 禁止把“未执行”写成“已完成”。
- 任一步骤缺少必要信息时，立即停止并向用户提问，不允许自行补假设继续推进。
- 输出中必须明确列出：已完成项、未完成项、阻塞项、下一步问题。

现在开始执行：先扫描子系统与设备类型，再给出按 device_type 拆分的端到端测试计划和证据采集计划。"#,
        project = project,
        workspace = workspace,
        evidence_root = evidence_root.to_string_lossy(),
        index_file = index_file.to_string_lossy(),
    );

    Ok(EvidenceRebuildPromptPayload {
        prompt,
        evidence_root: evidence_root.to_string_lossy().to_string(),
        index_file: index_file.to_string_lossy().to_string(),
        detected_subsystems,
        detected_device_types,
        generated_at: now_rfc3339(),
    })
}

fn read_evidence_item_chunk_sync(
    workspace_root: &Path,
    item_id: &str,
    offset: u64,
    limit: Option<u32>,
) -> Result<EvidenceChunkPayload, String> {
    let evidence_root = workspace_root.join(EVIDENCE_ROOT_RELATIVE);
    let index_file = workspace_root.join(EVIDENCE_INDEX_RELATIVE);
    let index = load_and_validate_index(&index_file, &evidence_root)?;
    let item = index
        .items
        .iter()
        .find(|x| x.item_id == item_id)
        .ok_or_else(|| format!("evidence item not found: {}", item_id))?;

    let mut file = fs::File::open(&item.full_path).map_err(|e| {
        format!(
            "open evidence item failed ({}): {}",
            item.full_path.display(),
            e
        )
    })?;
    let total_size_bytes = file
        .metadata()
        .map_err(|e| format!("read evidence item metadata failed: {}", e))?
        .len();
    if offset > total_size_bytes {
        return Err(format!(
            "offset out of range: offset={}, total_size={}",
            offset, total_size_bytes
        ));
    }

    let limit = limit
        .map(|v| usize::try_from(v).unwrap_or(CHUNK_DEFAULT_LIMIT))
        .unwrap_or(CHUNK_DEFAULT_LIMIT)
        .clamp(1, CHUNK_MAX_LIMIT);
    let remaining = usize::try_from(total_size_bytes.saturating_sub(offset))
        .map_err(|_| "file too large to chunk on this runtime".to_string())?;
    let chunk_len = remaining.min(limit);

    file.seek(SeekFrom::Start(offset))
        .map_err(|e| format!("seek evidence item failed: {}", e))?;

    let mut content = vec![0u8; chunk_len];
    if chunk_len > 0 {
        file.read_exact(&mut content)
            .map_err(|e| format!("read evidence item chunk failed: {}", e))?;
    }
    let next_offset = offset.saturating_add(chunk_len as u64);

    Ok(EvidenceChunkPayload {
        item_id: item.item_id.clone(),
        offset,
        next_offset,
        eof: next_offset >= total_size_bytes,
        total_size_bytes,
        mime_type: infer_mime_type(&item.path),
        content,
    })
}

fn load_and_validate_index(
    index_file: &Path,
    evidence_root: &Path,
) -> Result<ValidatedEvidenceIndex, String> {
    let content = fs::read_to_string(index_file).map_err(|e| {
        format!(
            "read evidence index failed ({}): {}",
            index_file.display(),
            e
        )
    })?;
    let raw: EvidenceIndexRaw = serde_json::from_str(&content)
        .map_err(|e| format!("parse evidence index failed: {}", e))?;

    let schema_version = raw
        .schema_version
        .ok_or_else(|| "evidence.index.json 缺少 $schema_version".to_string())?;
    if schema_version.trim() != "1.0" {
        return Err(format!(
            "evidence.index.json $schema_version 不支持: {}",
            schema_version
        ));
    }
    let updated_at = raw
        .updated_at
        .ok_or_else(|| "evidence.index.json 缺少 updated_at".to_string())?;

    let mut id_set: HashSet<String> = HashSet::new();
    let mut issues = Vec::new();
    let mut items = Vec::new();

    for item in raw.items {
        let normalized_device_type = normalize_device_type(&item.device_type)?;
        if !ALLOWED_TYPES.contains(&item.evidence_type.as_str()) {
            return Err(format!(
                "evidence.index.json item type 非法: {}",
                item.evidence_type
            ));
        }
        if !id_set.insert(item.id.clone()) {
            return Err(format!("evidence.index.json item id 重复: {}", item.id));
        }

        let normalized_path = normalize_relative_path(&item.path)?;
        if !normalized_path.starts_with(&format!("{}/", normalized_device_type)) {
            issues.push(issue_warning(
                "device_type_path_mismatch",
                format!(
                    "item '{}' 的 path 未以 device_type 目录开头: device_type={}, path={}",
                    item.id, normalized_device_type, normalized_path
                ),
            ));
        }
        let full_path = evidence_root.join(&normalized_path);
        items.push(ValidatedEvidenceItem {
            item_id: item.id,
            device_type: normalized_device_type,
            evidence_type: item.evidence_type,
            order: item.order,
            path: normalized_path,
            title: item.title,
            description: item.description,
            scenario: sanitize_optional_text(item.scenario),
            subsystem: sanitize_optional_text(item.subsystem),
            created_at: sanitize_optional_text(item.created_at),
            full_path,
        });
    }

    items.sort_by(|a, b| {
        (a.device_type.as_str(), a.order, a.item_id.as_str()).cmp(&(
            b.device_type.as_str(),
            b.order,
            b.item_id.as_str(),
        ))
    });

    Ok(ValidatedEvidenceIndex {
        updated_at,
        items,
        issues,
    })
}

fn normalize_device_type(device_type: &str) -> Result<String, String> {
    let normalized = device_type.trim().to_ascii_lowercase();
    if normalized.is_empty() {
        return Err("evidence.index.json item device_type 不能为空".to_string());
    }
    if normalized.starts_with('-') || normalized.ends_with('-') {
        return Err(format!(
            "evidence.index.json item device_type 非法: {}",
            device_type
        ));
    }
    if !normalized
        .chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
    {
        return Err(format!(
            "evidence.index.json item device_type 非法: {}",
            device_type
        ));
    }
    Ok(normalized)
}

fn normalize_relative_path(path: &str) -> Result<String, String> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err("evidence.index.json item path 不能为空".to_string());
    }
    let p = Path::new(trimmed);
    if p.is_absolute() {
        return Err(format!(
            "evidence.index.json item path 不能是绝对路径: {}",
            trimmed
        ));
    }

    let mut normalized = PathBuf::new();
    for component in p.components() {
        match component {
            Component::CurDir => {}
            Component::Normal(seg) => normalized.push(seg),
            Component::ParentDir => {
                return Err(format!(
                    "evidence.index.json item path 禁止包含 '..': {}",
                    trimmed
                ));
            }
            Component::RootDir | Component::Prefix(_) => {
                return Err(format!("evidence.index.json item path 非法: {}", trimmed));
            }
        }
    }

    if normalized.as_os_str().is_empty() {
        return Err(format!("evidence.index.json item path 非法: {}", trimmed));
    }
    Ok(pathbuf_to_slash_string(&normalized))
}

fn detect_subsystems(workspace_root: &Path) -> Vec<EvolutionEvidenceSubsystemInfo> {
    let mut seen: HashSet<(String, String)> = HashSet::new();
    let mut result: Vec<EvolutionEvidenceSubsystemInfo> = Vec::new();

    for entry in WalkDir::new(workspace_root)
        .max_depth(3)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
    {
        let path = entry.path();
        if entry.file_type().is_dir() {
            if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                if name == ".git" || name == "target" || name == "build" || name == ".tidyflow" {
                    continue;
                }
            }
        }

        if !entry.file_type().is_file() {
            continue;
        }

        let file_name = path.file_name().and_then(|x| x.to_str()).unwrap_or("");
        let parent = path.parent().unwrap_or(workspace_root);
        let rel_path = relative_path_string(workspace_root, parent);
        let kind = match file_name {
            "Cargo.toml" => Some("rust_crate"),
            "Package.swift" => Some("swift_package"),
            "package.json" => Some("node_package"),
            "pyproject.toml" | "requirements.txt" => Some("python_module"),
            _ => None,
        };
        if let Some(kind) = kind {
            if seen.insert((kind.to_string(), rel_path.clone())) {
                result.push(EvolutionEvidenceSubsystemInfo {
                    id: subsystem_id(kind, &rel_path),
                    kind: kind.to_string(),
                    path: rel_path,
                });
            }
        }
    }

    for entry in WalkDir::new(workspace_root)
        .max_depth(3)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
    {
        if !entry.file_type().is_dir() {
            continue;
        }
        let dir_name = entry
            .path()
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("");
        if !dir_name.ends_with(".xcodeproj") {
            continue;
        }
        let rel_path = relative_path_string(workspace_root, entry.path());
        let kind = "xcode_project";
        if seen.insert((kind.to_string(), rel_path.clone())) {
            result.push(EvolutionEvidenceSubsystemInfo {
                id: subsystem_id(kind, &rel_path),
                kind: kind.to_string(),
                path: rel_path,
            });
        }
    }

    result.sort_by(|a, b| {
        (a.path.as_str(), a.kind.as_str(), a.id.as_str()).cmp(&(
            b.path.as_str(),
            b.kind.as_str(),
            b.id.as_str(),
        ))
    });
    result
}

fn detect_device_types(workspace_root: &Path, evidence_root: &Path) -> Vec<String> {
    let mut detected = Vec::new();

    if let Ok(entries) = fs::read_dir(evidence_root) {
        for entry in entries.filter_map(Result::ok) {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            if let Some(name) = path.file_name().and_then(|x| x.to_str()) {
                if let Ok(normalized) = normalize_device_type(name) {
                    detected.push(normalized);
                }
            }
        }
    }

    for entry in WalkDir::new(workspace_root)
        .max_depth(4)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
    {
        if !entry.file_type().is_dir() {
            continue;
        }
        let dir_name = entry
            .path()
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("");
        if !dir_name.ends_with(".xcodeproj") {
            continue;
        }
        let pbxproj = entry.path().join("project.pbxproj");
        let Ok(content) = fs::read_to_string(&pbxproj) else {
            continue;
        };
        let lowered = content.to_lowercase();
        if lowered.contains("iphoneos")
            || lowered.contains("iphonesimulator")
            || lowered.contains("ios_deployment_target")
        {
            detected.push("iphone".to_string());
            detected.push("ipad".to_string());
        }
        if lowered.contains("macosx") || lowered.contains("macosx_deployment_target") {
            detected.push("mac".to_string());
        }
        if lowered.contains("appletvos")
            || lowered.contains("appletvsimulator")
            || lowered.contains("tvos_deployment_target")
        {
            detected.push("apple-tv".to_string());
        }
        if lowered.contains("watchos")
            || lowered.contains("watchsimulator")
            || lowered.contains("watchos_deployment_target")
        {
            detected.push("apple-watch".to_string());
        }
        if lowered.contains("xros")
            || lowered.contains("visionos")
            || lowered.contains("xros_deployment_target")
        {
            detected.push("vision-pro".to_string());
        }
    }

    for entry in WalkDir::new(workspace_root)
        .max_depth(4)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
    {
        if !entry.file_type().is_file() {
            continue;
        }
        let file_name = entry
            .path()
            .file_name()
            .and_then(|x| x.to_str())
            .unwrap_or("");
        if file_name != "Package.swift" {
            continue;
        }
        let Ok(content) = fs::read_to_string(entry.path()) else {
            continue;
        };
        let lowered = content.to_lowercase();
        if lowered.contains(".ios(") {
            detected.push("iphone".to_string());
            detected.push("ipad".to_string());
        }
        if lowered.contains(".macos(") {
            detected.push("mac".to_string());
        }
        if lowered.contains(".tvos(") {
            detected.push("apple-tv".to_string());
        }
        if lowered.contains(".watchos(") {
            detected.push("apple-watch".to_string());
        }
        if lowered.contains(".visionos(") {
            detected.push("vision-pro".to_string());
        }
    }

    dedup_sort_device_types(&mut detected);
    detected
}

fn sort_evidence_items(items: &mut [EvolutionEvidenceItemInfo]) {
    items.sort_by(|a, b| {
        (a.device_type.as_str(), a.order, a.item_id.as_str()).cmp(&(
            b.device_type.as_str(),
            b.order,
            b.item_id.as_str(),
        ))
    });
}

fn dedup_sort_device_types(device_types: &mut Vec<String>) {
    let mut seen = HashSet::new();
    device_types.retain(|item| seen.insert(item.clone()));
    device_types.sort_by_key(|device_type| device_type_sort_order(device_type));
}

fn device_type_sort_order(device_type: &str) -> (u8, u8, String) {
    if let Some(pos) = DEVICE_TYPE_BASELINE.iter().position(|v| *v == device_type) {
        return (0, pos as u8, String::new());
    }
    (1, u8::MAX, device_type.to_string())
}

fn pathbuf_to_slash_string(path: &Path) -> String {
    path.components()
        .filter_map(|c| match c {
            Component::Normal(seg) => seg.to_str().map(ToString::to_string),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("/")
}

fn relative_path_string(base: &Path, target: &Path) -> String {
    match target.strip_prefix(base) {
        Ok(rel) => {
            let value = pathbuf_to_slash_string(rel);
            if value.is_empty() {
                ".".to_string()
            } else {
                value
            }
        }
        Err(_) => ".".to_string(),
    }
}

fn subsystem_id(kind: &str, path: &str) -> String {
    let mut value = format!("{}-{}", kind, path)
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() {
                ch.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect::<String>();
    while value.contains("--") {
        value = value.replace("--", "-");
    }
    value.trim_matches('-').to_string()
}

fn infer_mime_type(path: &str) -> String {
    let ext = Path::new(path)
        .extension()
        .and_then(|x| x.to_str())
        .map(|x| x.to_ascii_lowercase())
        .unwrap_or_default();

    match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "webp" => "image/webp",
        "gif" => "image/gif",
        "heic" => "image/heic",
        "log" | "txt" | "md" | "json" => "text/plain",
        _ => "application/octet-stream",
    }
    .to_string()
}

fn now_rfc3339() -> String {
    Utc::now().to_rfc3339()
}

fn issue_warning(
    code: impl Into<String>,
    message: impl Into<String>,
) -> EvolutionEvidenceIssueInfo {
    EvolutionEvidenceIssueInfo {
        code: code.into(),
        level: "warning".to_string(),
        message: message.into(),
    }
}

fn sanitize_optional_text(value: Option<String>) -> Option<String> {
    value.and_then(|s| {
        let trimmed = s.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::tempdir;

    #[test]
    fn normalize_relative_path_rejects_parent_segment() {
        let result = normalize_relative_path("../iphone/a.png");
        assert!(result.is_err());
    }

    #[test]
    fn load_and_validate_index_missing_required_field_fails() {
        let dir = tempdir().expect("tempdir");
        let evidence_root = dir.path().join(".tidyflow/evidence");
        fs::create_dir_all(&evidence_root).expect("create evidence dir");
        let index_file = evidence_root.join("evidence.index.json");

        let broken = r#"{
            "$schema_version": "1.0",
            "updated_at": "2026-02-25T08:00:00Z",
            "items": [
                { "id": "ev-1", "device_type": "iphone", "type": "screenshot", "path": "iphone/a.png", "title": "t", "description": "d" }
            ]
        }"#;
        fs::write(&index_file, broken).expect("write index");

        let parsed = load_and_validate_index(&index_file, &evidence_root);
        assert!(parsed.is_err());
    }

    #[test]
    fn load_and_validate_index_sorts_items_stably() {
        let dir = tempdir().expect("tempdir");
        let evidence_root = dir.path().join(".tidyflow/evidence");
        fs::create_dir_all(evidence_root.join("iphone")).expect("create iphone dir");
        fs::create_dir_all(evidence_root.join("mac")).expect("create mac dir");
        fs::write(evidence_root.join("iphone/b.png"), b"1").expect("write file");
        fs::write(evidence_root.join("iphone/a.png"), b"1").expect("write file");
        fs::write(evidence_root.join("mac/a.log"), b"1").expect("write file");
        let index_file = evidence_root.join("evidence.index.json");
        let json = r#"{
            "$schema_version": "1.0",
            "updated_at": "2026-02-25T08:00:00Z",
            "items": [
                { "id": "ev-2", "device_type": "iphone", "type": "screenshot", "order": 20, "path": "iphone/b.png", "title": "b", "description": "b" },
                { "id": "ev-1", "device_type": "iphone", "type": "screenshot", "order": 20, "path": "iphone/a.png", "title": "a", "description": "a" },
                { "id": "ev-3", "device_type": "mac", "type": "log", "order": 5, "path": "mac/a.log", "title": "m", "description": "m" }
            ]
        }"#;
        fs::write(&index_file, json).expect("write index");

        let parsed = load_and_validate_index(&index_file, &evidence_root).expect("parse index");
        let ids: Vec<String> = parsed.items.iter().map(|x| x.item_id.clone()).collect();
        assert_eq!(ids, vec!["ev-1", "ev-2", "ev-3"]);
    }

    #[test]
    fn detect_device_types_from_xcodeproj_and_package_swift() {
        let dir = tempdir().expect("tempdir");
        let proj_dir = dir.path().join("app/TidyFlow.xcodeproj");
        fs::create_dir_all(&proj_dir).expect("create xcodeproj");
        fs::write(
            proj_dir.join("project.pbxproj"),
            r#"
            SDKROOT = iphoneos;
            SDKROOT = macosx;
            SDKROOT = appletvos;
            "#,
        )
        .expect("write pbxproj");
        fs::write(
            dir.path().join("Package.swift"),
            r#"
            platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17)]
            "#,
        )
        .expect("write package");

        let device_types = detect_device_types(dir.path(), &dir.path().join(".tidyflow/evidence"));
        assert_eq!(device_types, vec!["iphone", "ipad", "apple-tv", "mac"]);
    }

    #[test]
    fn rebuild_prompt_emphasizes_device_type_and_flat_directories() {
        let dir = tempdir().expect("tempdir");
        let payload =
            build_rebuild_prompt_sync(dir.path(), "demo-project", "default").expect("prompt");
        let prompt = payload.prompt;

        assert!(prompt.contains(
            "禁止创建 `custom/<device_type>/...`、`wrapper/<device_type>/...` 这类包裹目录"
        ));
        assert!(prompt.contains("设备类型固定基线（默认全部覆盖，除非用户明确删减）"));
        assert!(prompt.contains("iphone"));
        assert!(prompt.contains("ipad"));
        assert!(prompt.contains("apple-tv"));
        assert!(prompt.contains("apple-watch"));
        assert!(prompt.contains("vision-pro"));
        assert!(prompt.contains("mac"));
        assert!(prompt.contains("android-phone"));
        assert!(prompt.contains("android-pad"));
        assert!(prompt.contains("android-tv"));
        assert!(prompt.contains("android-wear"));
        assert!(prompt.contains("ohos-phone"));
        assert!(prompt.contains("ohos-pad"));
        assert!(prompt.contains("ohos-tv"));
        assert!(prompt.contains("web"));
        assert!(prompt.contains("web-mobile"));
        assert!(prompt.contains("linux"));
        assert!(prompt.contains("windows"));
        assert!(prompt.contains("server"));
        assert!(prompt.contains("path 的首段必须与该条目的 device_type 完全一致"));
    }

    #[test]
    fn read_evidence_item_chunk_respects_offset_and_limit() {
        let dir = tempdir().expect("tempdir");
        let evidence_root = dir.path().join(".tidyflow/evidence/iphone");
        fs::create_dir_all(&evidence_root).expect("create evidence dir");
        let file_path = evidence_root.join("run.log");
        let mut f = fs::File::create(&file_path).expect("create file");
        f.write_all(b"abcdefghijklmn").expect("write file");

        let index_file = dir.path().join(".tidyflow/evidence/evidence.index.json");
        fs::write(
            &index_file,
            r#"{
                "$schema_version":"1.0",
                "updated_at":"2026-02-25T08:00:00Z",
                "items":[
                    {"id":"ev-1","device_type":"iphone","type":"log","order":1,"path":"iphone/run.log","title":"t","description":"d"}
                ]
            }"#,
        )
        .expect("write index");

        let chunk =
            read_evidence_item_chunk_sync(dir.path(), "ev-1", 2, Some(4)).expect("read chunk");
        assert_eq!(chunk.content, b"cdef");
        assert_eq!(chunk.offset, 2);
        assert_eq!(chunk.next_offset, 6);
        assert!(!chunk.eof);
    }
}
