use std::collections::HashSet;
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Component, Path, PathBuf};

use crate::server::ws::OutboundTx as WebSocket;
use chrono::Utc;
use serde::Deserialize;
use walkdir::WalkDir;

use crate::server::context::{resolve_workspace, HandlerContext};
use crate::server::protocol::{
    ClientMessage, EvidenceIssueInfo, EvidenceItemInfo, EvidenceSubsystemInfo, ServerMessage,
};
use crate::server::ws::send_message;

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
struct EvidenceSnapshotPayload {
    evidence_root: String,
    index_file: String,
    index_exists: bool,
    detected_subsystems: Vec<EvidenceSubsystemInfo>,
    detected_device_types: Vec<String>,
    items: Vec<EvidenceItemInfo>,
    issues: Vec<EvidenceIssueInfo>,
    updated_at: String,
}

#[derive(Debug)]
struct EvidenceRebuildPromptPayload {
    prompt: String,
    evidence_root: String,
    index_file: String,
    detected_subsystems: Vec<EvidenceSubsystemInfo>,
    detected_device_types: Vec<String>,
    generated_at: String,
}

#[derive(Debug)]
struct EvidenceChunkPayload {
    item_id: String,
    offset: u64,
    next_offset: u64,
    eof: bool,
    total_size_bytes: u64,
    mime_type: String,
    content: Vec<u8>,
}

async fn send_read_via_http_required(
    socket: &WebSocket,
    action: &str,
    project: Option<String>,
    workspace: Option<String>,
) -> Result<(), String> {
    send_message(
        socket,
        &ServerMessage::Error {
            code: "read_via_http_required".to_string(),
            message: format!(
                "{} must be fetched via HTTP API (/api/v1/evidence/...)",
                action
            ),
            project,
            workspace,
            session_id: None,
            cycle_id: None,
        },
    )
    .await
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
    issues: Vec<EvidenceIssueInfo>,
}

pub async fn handle_evidence_message(
    client_msg: &ClientMessage,
    socket: &WebSocket,
    _ctx: &HandlerContext,
) -> Result<bool, String> {
    match client_msg {
        ClientMessage::EvidenceGetSnapshot { project, workspace } => {
            send_read_via_http_required(
                socket,
                "evidence_get_snapshot",
                Some(project.clone()),
                Some(workspace.clone()),
            )
            .await?;
            Ok(true)
        }
        ClientMessage::EvidenceGetRebuildPrompt { project, workspace } => {
            send_read_via_http_required(
                socket,
                "evidence_get_rebuild_prompt",
                Some(project.clone()),
                Some(workspace.clone()),
            )
            .await?;
            Ok(true)
        }
        ClientMessage::EvidenceReadItem {
            project, workspace, ..
        } => {
            send_read_via_http_required(
                socket,
                "evidence_read_item",
                Some(project.clone()),
                Some(workspace.clone()),
            )
            .await?;
            Ok(true)
        }
        _ => Ok(false),
    }
}

pub(crate) async fn query_evidence_snapshot(
    project: &str,
    workspace: &str,
    ctx: &HandlerContext,
) -> Result<ServerMessage, String> {
    let payload = get_evidence_snapshot(project, workspace, ctx).await?;
    Ok(ServerMessage::EvidenceSnapshot {
        project: project.to_string(),
        workspace: workspace.to_string(),
        evidence_root: payload.evidence_root,
        index_file: payload.index_file,
        index_exists: payload.index_exists,
        detected_subsystems: payload.detected_subsystems,
        detected_device_types: payload.detected_device_types,
        items: payload.items,
        issues: payload.issues,
        updated_at: payload.updated_at,
    })
}

pub(crate) async fn query_evidence_rebuild_prompt(
    project: &str,
    workspace: &str,
    ctx: &HandlerContext,
) -> Result<ServerMessage, String> {
    let payload = get_evidence_rebuild_prompt(project, workspace, ctx).await?;
    Ok(ServerMessage::EvidenceRebuildPrompt {
        project: project.to_string(),
        workspace: workspace.to_string(),
        prompt: payload.prompt,
        evidence_root: payload.evidence_root,
        index_file: payload.index_file,
        detected_subsystems: payload.detected_subsystems,
        detected_device_types: payload.detected_device_types,
        generated_at: payload.generated_at,
    })
}

pub(crate) async fn query_evidence_item_chunk(
    project: &str,
    workspace: &str,
    item_id: &str,
    offset: u64,
    limit: Option<u32>,
    ctx: &HandlerContext,
) -> Result<ServerMessage, String> {
    let payload = read_evidence_item_chunk(project, workspace, item_id, offset, limit, ctx).await?;
    Ok(ServerMessage::EvidenceItemChunk {
        project: project.to_string(),
        workspace: workspace.to_string(),
        item_id: payload.item_id,
        offset: payload.offset,
        next_offset: payload.next_offset,
        eof: payload.eof,
        total_size_bytes: payload.total_size_bytes,
        mime_type: payload.mime_type,
        content: payload.content,
    })
}

async fn get_evidence_snapshot(
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

async fn get_evidence_rebuild_prompt(
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

async fn read_evidence_item_chunk(
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

fn build_snapshot_sync(workspace_root: &Path) -> Result<EvidenceSnapshotPayload, String> {
    let evidence_root = workspace_root.join(EVIDENCE_ROOT_RELATIVE);
    let index_file = workspace_root.join(EVIDENCE_INDEX_RELATIVE);

    let detected_subsystems = detect_subsystems(workspace_root);
    let mut detected_device_types = detect_device_types(workspace_root, &evidence_root);
    let mut issues: Vec<EvidenceIssueInfo> = Vec::new();
    let mut items: Vec<EvidenceItemInfo> = Vec::new();
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
                    items.push(EvidenceItemInfo {
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

【总体目标】
1. 识别仓库中的子系统与设备类型（device_type）。
2. 构建或改造可重复执行的端到端验证框架（e2e）。
3. 让日志/截图等证据成为 e2e 运行的自动产物。
4. 由 e2e 测试在执行过程中自动生成/更新 evidence.index.json，确保仅索引真实执行产物并可追溯、可复核、可排序。

【通用性要求】
- 本提示词是跨项目通用模板，不预设技术栈、目录结构或测试框架名称。
- 优先复用仓库现有测试基础设施；仅在缺失时新增最小必要入口。
- 若用户明确限定设备范围，只覆盖用户指定范围；否则按仓库扫描结果与设备基线共同评估覆盖面。

【执行优先级（必须按顺序）】
1) 先审计现有测试与证据链路：测试入口、可运行性、断言覆盖、产物输出点。
2) 先补齐/改造 e2e 框架：每条验收标准必须映射到可执行 check 与证据产物。
3) 在 e2e 测试代码内定义证据语义（title/description/scenario/subsystem/order），并在执行时自动写入 evidence.index.json。
4) 最后才考虑补采集；补采集也必须通过 e2e 执行产出，禁止离线拼装。

【禁止事项（强约束）】
- 禁止把“写脚本生成证据文件”作为主方案。
- 禁止通过独立脚本离线搬运、拼接、伪造日志或截图来替代 e2e 执行。
- 禁止通过后处理脚本单独生成或重写 evidence.index.json。
- 禁止把“索引语义优化”当成主目标而跳过测试框架改造与语义化测试用例。
- 禁止把“未执行”写成“已完成”。

【允许事项（边界）】
- 允许新增很薄的统一入口脚本，但职责仅限触发 e2e 流程与收集退出状态。
- 入口脚本不得生成伪证据内容，不得绕过断言或测试执行。
- 若某设备类型当前确实无法执行，必须输出阻塞原因、已尝试动作和最小改造建议，状态标记为 `blocked` 或 `not_applicable`。

【目录与设备类型规则（高优先级）】
- evidence_root 下第一层目录必须是 device_type，所有 device_type 必须同级。
- 禁止创建 `custom/<device_type>/...`、`wrapper/<device_type>/...` 这类包裹目录，所有 device_type 必须直接落在 evidence_root 同级目录。
- 设备类型基线：iphone、ipad、apple-tv、apple-watch、vision-pro、mac、android-phone、android-pad、android-tv、android-wear、ohos-phone、ohos-pad、ohos-tv、web、web-mobile、linux、windows、server。
- 设备类型固定基线（默认全部覆盖，除非用户明确删减）。
- 每个 device_type 都必须有独立的 e2e 入口与证据子目录（示例：`<device_type>/e2e/...`）。
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
- type 仅允许 `log|screenshot`，且必须来自真实执行产物。
- evidence.index.json 必须由 e2e 执行自动生成/更新，禁止脱离测试执行离线写入。

【标题与描述语义规则（次优先级，仍需满足）】
- title 必须回答“在什么场景下，这条证据证明了什么状态/结果”；禁止仅写工具名、文件名、设备 ID、run_id、序号。
- description 必须包含 3 类信息：执行动作、关键观察、证据用途（用于证明或排除什么）。
- title/description 不得与 path 同义重复；即使隐藏 path，读者也能理解该证据意义。
- 日志类证据需基于关键日志行提炼语义；截图类证据需描述页面/流程状态与上下文步骤。
- 语义来源应直接来自测试步骤与断言上下文，而非事后从文件名反推。

【执行约束（强制）】
- 必须使用真实数据，禁止 mock，禁止占位，禁止伪造截图。
- 若上下文不足以继续执行，必须输出阻塞项与最小可执行下一步，不得虚构结果。
- 输出中必须明确列出：已完成项、未完成项、阻塞项、下一步问题。

现在开始执行：
1) 先完成“测试框架审计 + e2e 可执行性改造计划”（按 device_type 拆分）。
2) 再给出“通过 e2e 自动产证据并自动生成 evidence.index.json”的实施与补采集计划。
3) 最后给出基于测试语义的 evidence.index.json 验收标准。"#,
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

fn detect_subsystems(workspace_root: &Path) -> Vec<EvidenceSubsystemInfo> {
    let mut seen: HashSet<(String, String)> = HashSet::new();
    let mut result: Vec<EvidenceSubsystemInfo> = Vec::new();

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
                result.push(EvidenceSubsystemInfo {
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
            result.push(EvidenceSubsystemInfo {
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

fn sort_evidence_items(items: &mut [EvidenceItemInfo]) {
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

fn issue_warning(code: impl Into<String>, message: impl Into<String>) -> EvidenceIssueInfo {
    EvidenceIssueInfo {
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

        assert!(prompt.contains("【通用性要求】"));
        assert!(prompt.contains("本提示词是跨项目通用模板"));
        assert!(prompt.contains("【执行优先级（必须按顺序）】"));
        assert!(prompt.contains("先审计现有测试与证据链路"));
        assert!(prompt.contains("先补齐/改造 e2e 框架"));
        assert!(prompt.contains("禁止把“写脚本生成证据文件”作为主方案"));
        assert!(prompt.contains("由 e2e 测试在执行过程中自动生成/更新 evidence.index.json"));
        assert!(prompt.contains("禁止通过后处理脚本单独生成或重写 evidence.index.json"));
        assert!(prompt.contains("允许新增很薄的统一入口脚本"));
        assert!(prompt.contains(
            "禁止创建 `custom/<device_type>/...`、`wrapper/<device_type>/...` 这类包裹目录"
        ));
        assert!(prompt.contains("设备类型固定基线（默认全部覆盖，除非用户明确删减）"));
        assert!(!prompt.contains("detected_device_types"));
        assert!(prompt.contains("path 的首段必须与该条目的 device_type 完全一致"));
        assert!(prompt.contains("【标题与描述语义规则（次优先级，仍需满足）】"));
        assert!(prompt.contains("禁止仅写工具名、文件名、设备 ID、run_id、序号"));
        assert!(prompt.contains("先完成“测试框架审计 + e2e 可执行性改造计划”"));
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
