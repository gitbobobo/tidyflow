use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use chrono::Utc;
use tokio::sync::{mpsc, Mutex};
use tracing::{info, warn};
use url::Url;
use walkdir::{DirEntry, WalkDir};

use crate::server::protocol::{LspDiagnosticInfo, ServerMessage};

use super::diagnostics::DiagnosticsStore;
use super::servers::detect_server;
use super::session::LspSession;
use super::types::{LspLanguage, RawLspDiagnostic, SupervisorEvent, WorkspaceDiagnostic};

const MAX_INITIAL_FILES_PER_LANGUAGE: usize = 1200;

struct ChangedFilePayload {
    abs_path: PathBuf,
    content: Option<String>,
    exists: bool,
}

struct WorkspaceRuntime {
    project: String,
    workspace: String,
    root_path: PathBuf,
    sessions: HashMap<LspLanguage, LspSession>,
    diagnostics: DiagnosticsStore,
    running_languages: Vec<LspLanguage>,
    missing_languages: Vec<String>,
    status_message: Option<String>,
}

impl WorkspaceRuntime {
    fn to_status_message(&self) -> ServerMessage {
        ServerMessage::LspStatus {
            project: self.project.clone(),
            workspace: self.workspace.clone(),
            running_languages: self
                .running_languages
                .iter()
                .map(|l| l.as_str().to_string())
                .collect(),
            missing_languages: self.missing_languages.clone(),
            message: self.status_message.clone(),
        }
    }

    fn to_diagnostics_message(&self) -> ServerMessage {
        let items = self.diagnostics.all_sorted();
        let highest = self
            .diagnostics
            .highest_severity()
            .map(|s| s.as_protocol_str().to_string())
            .unwrap_or_else(|| "none".to_string());
        let updated_at = self
            .diagnostics
            .updated_at_rfc3339()
            .unwrap_or_else(|| Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true));

        ServerMessage::LspDiagnostics {
            project: self.project.clone(),
            workspace: self.workspace.clone(),
            highest_severity: highest,
            updated_at,
            items: items
                .into_iter()
                .map(|d| LspDiagnosticInfo {
                    path: d.path,
                    line: d.line,
                    column: d.column,
                    end_line: d.end_line,
                    end_column: d.end_column,
                    severity: d.severity.as_protocol_str().to_string(),
                    message: d.message,
                    source: d.source,
                    code: d.code,
                    language: d.language.as_str().to_string(),
                })
                .collect(),
        }
    }
}

#[derive(Default)]
struct SupervisorInner {
    workspaces: HashMap<String, WorkspaceRuntime>,
}

#[derive(Clone)]
pub struct LspSupervisor {
    inner: Arc<Mutex<SupervisorInner>>,
    event_tx: mpsc::Sender<SupervisorEvent>,
    outbound_tx: mpsc::Sender<ServerMessage>,
}

impl LspSupervisor {
    pub fn new(outbound_tx: mpsc::Sender<ServerMessage>) -> LspSupervisor {
        let inner = Arc::new(Mutex::new(SupervisorInner::default()));
        let (event_tx, mut event_rx) = mpsc::channel::<SupervisorEvent>(1024);
        let loop_inner = inner.clone();
        let loop_outbound = outbound_tx.clone();

        tokio::spawn(async move {
            while let Some(event) = event_rx.recv().await {
                match event {
                    SupervisorEvent::PublishDiagnostics {
                        workspace_key,
                        language,
                        uri,
                        diagnostics,
                    } => {
                        let maybe_msg = {
                            let mut guard = loop_inner.lock().await;
                            if let Some(runtime) = guard.workspaces.get_mut(&workspace_key) {
                                let mapped = map_raw_diagnostics(
                                    &runtime.root_path,
                                    language,
                                    &uri,
                                    diagnostics,
                                );
                                runtime.diagnostics.update(language, uri.clone(), mapped);
                                Some(runtime.to_diagnostics_message())
                            } else {
                                None
                            }
                        };

                        if let Some(msg) = maybe_msg {
                            let _ = loop_outbound.send(msg).await;
                        }
                    }
                    SupervisorEvent::SessionExited {
                        workspace_key,
                        language,
                        reason,
                    } => {
                        let (status_msg, diag_msg) = {
                            let mut guard = loop_inner.lock().await;
                            if let Some(runtime) = guard.workspaces.get_mut(&workspace_key) {
                                runtime.sessions.remove(&language);
                                runtime.running_languages.retain(|x| *x != language);
                                runtime.diagnostics.clear_language(language);
                                runtime.status_message = Some(format!(
                                    "{} server exited: {}",
                                    language.as_str(),
                                    reason
                                ));
                                (
                                    Some(runtime.to_status_message()),
                                    Some(runtime.to_diagnostics_message()),
                                )
                            } else {
                                (None, None)
                            }
                        };

                        if let Some(msg) = status_msg {
                            let _ = loop_outbound.send(msg).await;
                        }
                        if let Some(msg) = diag_msg {
                            let _ = loop_outbound.send(msg).await;
                        }
                    }
                }
            }
        });

        LspSupervisor {
            inner,
            event_tx,
            outbound_tx,
        }
    }

    pub async fn start_workspace(
        &self,
        project: &str,
        workspace: &str,
        root_path: PathBuf,
    ) -> Result<(), String> {
        self.stop_workspace(project, workspace).await?;

        let key = workspace_key(project, workspace);
        let mut runtime = WorkspaceRuntime {
            project: project.to_string(),
            workspace: workspace.to_string(),
            root_path: root_path.clone(),
            sessions: HashMap::new(),
            diagnostics: DiagnosticsStore::default(),
            running_languages: vec![],
            missing_languages: vec![],
            status_message: None,
        };

        let mut start_errors: Vec<String> = vec![];
        for language in LspLanguage::all() {
            match detect_server(language) {
                Some(spec) => {
                    match LspSession::start(
                        language,
                        key.clone(),
                        workspace.to_string(),
                        root_path.clone(),
                        spec,
                        self.event_tx.clone(),
                    )
                    .await
                    {
                        Ok(mut session) => {
                            runtime.running_languages.push(language);
                            let files = collect_workspace_files(&root_path, language);
                            let preloaded = read_workspace_files_blocking(files).await;
                            for (file, content) in preloaded {
                                let _ = session.sync_file(&file, &content).await;
                            }
                            runtime.sessions.insert(language, session);
                        }
                        Err(e) => {
                            runtime.missing_languages.push(language.as_str().to_string());
                            start_errors.push(format!("{}: {}", language.as_str(), e));
                        }
                    }
                }
                None => {
                    runtime.missing_languages.push(language.as_str().to_string());
                }
            }
        }

        if !start_errors.is_empty() {
            runtime.status_message = Some(format!(
                "Some language servers failed to start: {}",
                start_errors.join("; ")
            ));
        } else if runtime.running_languages.is_empty() {
            runtime.status_message = Some("No language server available in PATH".to_string());
        }

        let (status_msg, diag_msg) = (
            runtime.to_status_message(),
            runtime.to_diagnostics_message(),
        );
        {
            let mut guard = self.inner.lock().await;
            guard.workspaces.insert(key, runtime);
        }

        let _ = self.outbound_tx.send(status_msg).await;
        let _ = self.outbound_tx.send(diag_msg).await;

        info!(
            "LSP workspace started: project={}, workspace={}",
            project, workspace
        );
        Ok(())
    }

    pub async fn stop_workspace(&self, project: &str, workspace: &str) -> Result<(), String> {
        let key = workspace_key(project, workspace);
        let mut removed = {
            let mut guard = self.inner.lock().await;
            guard.workspaces.remove(&key)
        };

        if let Some(mut runtime) = removed.take() {
            for session in runtime.sessions.values_mut() {
                session.stop().await;
            }
            let status = ServerMessage::LspStatus {
                project: project.to_string(),
                workspace: workspace.to_string(),
                running_languages: vec![],
                missing_languages: vec![],
                message: Some("LSP stopped".to_string()),
            };
            let diagnostics = ServerMessage::LspDiagnostics {
                project: project.to_string(),
                workspace: workspace.to_string(),
                highest_severity: "none".to_string(),
                updated_at: Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
                items: vec![],
            };
            let _ = self.outbound_tx.send(status).await;
            let _ = self.outbound_tx.send(diagnostics).await;
        }
        Ok(())
    }

    pub async fn get_snapshot_messages(
        &self,
        project: &str,
        workspace: &str,
    ) -> Vec<ServerMessage> {
        let key = workspace_key(project, workspace);
        let guard = self.inner.lock().await;
        if let Some(runtime) = guard.workspaces.get(&key) {
            return vec![runtime.to_status_message(), runtime.to_diagnostics_message()];
        }
        vec![
            ServerMessage::LspStatus {
                project: project.to_string(),
                workspace: workspace.to_string(),
                running_languages: vec![],
                missing_languages: vec![],
                message: Some("LSP not started for this workspace".to_string()),
            },
            ServerMessage::LspDiagnostics {
                project: project.to_string(),
                workspace: workspace.to_string(),
                highest_severity: "none".to_string(),
                updated_at: Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
                items: vec![],
            },
        ]
    }

    pub async fn handle_paths_changed(
        &self,
        project: &str,
        workspace: &str,
        relative_paths: &[String],
    ) {
        let key = workspace_key(project, workspace);
        let coalesced = coalesce_relative_paths(relative_paths);
        if coalesced.is_empty() {
            return;
        }

        let root_path = {
            let guard = self.inner.lock().await;
            let Some(runtime) = guard.workspaces.get(&key) else {
                return;
            };
            runtime.root_path.clone()
        };

        // 先在阻塞线程池读取文件内容，避免在 async 线程里做磁盘 I/O
        let changed_payloads = read_changed_files_blocking(root_path, &coalesced).await;

        let mut guard = self.inner.lock().await;
        let Some(runtime) = guard.workspaces.get_mut(&key) else {
            return;
        };
        for payload in changed_payloads {
            for session in runtime.sessions.values_mut() {
                if !session.supports_path(&payload.abs_path) {
                    continue;
                }
                if payload.exists {
                    if let Some(content) = payload.content.as_deref() {
                        let _ = session.sync_file(&payload.abs_path, content).await;
                    }
                } else {
                    let _ = session.remove_file(&payload.abs_path).await;
                }
            }
        }
    }

    pub async fn shutdown_all(&self) {
        let mut all = {
            let mut guard = self.inner.lock().await;
            guard.workspaces.drain().map(|(_, runtime)| runtime).collect::<Vec<_>>()
        };

        for runtime in &mut all {
            for session in runtime.sessions.values_mut() {
                session.stop().await;
            }
        }
    }
}

fn workspace_key(project: &str, workspace: &str) -> String {
    format!("{}:{}", project, workspace)
}

fn is_ignored_dir(entry: &DirEntry) -> bool {
    if !entry.file_type().is_dir() {
        return false;
    }
    let name = entry.file_name().to_string_lossy();
    matches!(
        name.as_ref(),
        ".git"
            | "node_modules"
            | "target"
            | "build"
            | "dist"
            | ".next"
            | ".gradle"
            | ".idea"
            | ".venv"
            | "venv"
            | "__pycache__"
    )
}

fn collect_workspace_files(root: &Path, language: LspLanguage) -> Vec<PathBuf> {
    let mut result = Vec::new();
    for entry in WalkDir::new(root)
        .follow_links(false)
        .into_iter()
        .filter_entry(|e| !is_ignored_dir(e))
        .filter_map(Result::ok)
    {
        if !entry.file_type().is_file() {
            continue;
        }
        let path = entry.path();
        if language.matches_path(path) {
            result.push(path.to_path_buf());
            if result.len() >= MAX_INITIAL_FILES_PER_LANGUAGE {
                break;
            }
        }
    }
    result
}

fn map_raw_diagnostics(
    root_path: &Path,
    language: LspLanguage,
    uri: &str,
    diagnostics: Vec<RawLspDiagnostic>,
) -> Vec<WorkspaceDiagnostic> {
    let rel_path = uri_to_relative_path(root_path, uri).unwrap_or_else(|| uri.to_string());
    diagnostics
        .into_iter()
        .map(|d| WorkspaceDiagnostic {
            language,
            path: rel_path.clone(),
            line: d.line,
            column: d.column,
            end_line: d.end_line,
            end_column: d.end_column,
            severity: d.severity,
            message: d.message,
            source: d.source,
            code: d.code,
        })
        .collect()
}

fn uri_to_relative_path(root_path: &Path, uri: &str) -> Option<String> {
    let url = Url::parse(uri).ok()?;
    let full = url.to_file_path().ok()?;
    let rel = full.strip_prefix(root_path).ok()?;
    Some(rel.to_string_lossy().replace('\\', "/"))
}

fn coalesce_relative_paths(relative_paths: &[String]) -> Vec<String> {
    // watcher 已做防抖，这里再做一次去重合并，降低 burst 事件放大
    let mut set = BTreeSet::new();
    for rel_path in relative_paths {
        let trimmed = rel_path.trim();
        if trimmed.is_empty() {
            continue;
        }
        set.insert(trimmed.to_string());
    }
    set.into_iter().collect()
}

async fn read_workspace_files_blocking(paths: Vec<PathBuf>) -> Vec<(PathBuf, String)> {
    tokio::task::spawn_blocking(move || {
        let mut loaded = Vec::new();
        for path in paths {
            match std::fs::read_to_string(&path) {
                Ok(content) => loaded.push((path, content)),
                Err(e) => {
                    warn!("read file for LSP failed: {} ({})", path.display(), e);
                }
            }
        }
        loaded
    })
    .await
    .unwrap_or_default()
}

async fn read_changed_files_blocking(
    root_path: PathBuf,
    relative_paths: &[String],
) -> Vec<ChangedFilePayload> {
    let rel_paths = relative_paths.to_vec();
    tokio::task::spawn_blocking(move || {
        let mut payloads = Vec::with_capacity(rel_paths.len());
        for rel_path in rel_paths {
            let abs_path = root_path.join(rel_path);
            if abs_path.exists() && abs_path.is_file() {
                let content = std::fs::read_to_string(&abs_path).ok();
                payloads.push(ChangedFilePayload {
                    abs_path,
                    content,
                    exists: true,
                });
            } else {
                payloads.push(ChangedFilePayload {
                    abs_path,
                    content: None,
                    exists: false,
                });
            }
        }
        payloads
    })
    .await
    .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::coalesce_relative_paths;

    #[test]
    fn coalesce_relative_paths_dedups_and_sorts() {
        let input = vec![
            "src/main.rs".to_string(),
            " src/main.rs ".to_string(),
            "".to_string(),
            "src/lib.rs".to_string(),
        ];
        let merged = coalesce_relative_paths(&input);
        assert_eq!(merged, vec!["src/lib.rs".to_string(), "src/main.rs".to_string()]);
    }
}
