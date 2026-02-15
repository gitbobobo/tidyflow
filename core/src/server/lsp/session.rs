use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdout};
use tokio::sync::{mpsc, Mutex};
use tokio::task::JoinHandle;
use tracing::{debug, info, warn};
use url::Url;

use super::servers::LspServerSpec;
use super::types::{LspLanguage, LspSeverity, RawLspDiagnostic, SupervisorEvent};

pub struct LspSession {
    language: LspLanguage,
    workspace_key: String,
    root_path: PathBuf,
    child: Child,
    stdin: Arc<Mutex<tokio::process::ChildStdin>>,
    reader_task: JoinHandle<()>,
    next_request_id: u64,
    opened_versions: HashMap<String, i32>,
}

impl LspSession {
    pub async fn start(
        language: LspLanguage,
        workspace_key: String,
        workspace_name: String,
        root_path: PathBuf,
        spec: LspServerSpec,
        event_tx: mpsc::Sender<SupervisorEvent>,
    ) -> Result<LspSession, String> {
        let mut command = tokio::process::Command::new(&spec.program);
        command.args(&spec.args);
        command.current_dir(&root_path);
        command.stdin(std::process::Stdio::piped());
        command.stdout(std::process::Stdio::piped());
        command.stderr(std::process::Stdio::piped());

        let mut child = command
            .spawn()
            .map_err(|e| format!("spawn {} failed: {}", spec.program, e))?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| format!("{} stdin not available", spec.program))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| format!("{} stdout not available", spec.program))?;

        let stdin = Arc::new(Mutex::new(stdin));
        let reader_task =
            Self::spawn_reader_task(stdout, workspace_key.clone(), language, event_tx.clone());

        let mut session = LspSession {
            language,
            workspace_key: workspace_key.clone(),
            root_path: root_path.clone(),
            child,
            stdin,
            reader_task,
            next_request_id: 1,
            opened_versions: HashMap::new(),
        };

        let root_uri = Url::from_file_path(&root_path)
            .map_err(|_| format!("invalid root path: {}", root_path.display()))?
            .to_string();

        // initialize request
        let init_params = json!({
            "processId": null,
            "rootUri": root_uri,
            "rootPath": root_path.to_string_lossy().to_string(),
            "capabilities": {},
            "trace": "off",
            "workspaceFolders": [
                {
                    "uri": Url::from_file_path(&root_path).map_err(|_| "invalid root uri".to_string())?.to_string(),
                    "name": workspace_name
                }
            ]
        });
        let _ = session.send_request("initialize", init_params).await?;
        let _ = session.send_notification("initialized", json!({})).await;

        info!(
            "LSP session started: workspace={}, language={}",
            workspace_key,
            language.as_str()
        );
        Ok(session)
    }

    pub fn supports_path(&self, path: &Path) -> bool {
        self.language.matches_path(path)
    }

    pub async fn sync_file(&mut self, path: &Path, content: &str) -> Result<(), String> {
        if !self.supports_path(path) {
            return Ok(());
        }
        let uri = Self::path_to_uri(path)?;
        let version = self.opened_versions.get(&uri).copied().unwrap_or(0) + 1;

        if self.opened_versions.contains_key(&uri) {
            self.send_notification(
                "textDocument/didChange",
                json!({
                    "textDocument": {
                        "uri": uri,
                        "version": version
                    },
                    "contentChanges": [
                        { "text": content }
                    ]
                }),
            )
            .await?;
        } else {
            self.send_notification(
                "textDocument/didOpen",
                json!({
                    "textDocument": {
                        "uri": uri,
                        "languageId": self.language.language_id(),
                        "version": version,
                        "text": content
                    }
                }),
            )
            .await?;
        }
        self.opened_versions.insert(uri, version);
        Ok(())
    }

    pub async fn remove_file(&mut self, path: &Path) -> Result<(), String> {
        let uri = Self::path_to_uri(path)?;
        if self.opened_versions.remove(&uri).is_some() {
            self.send_notification(
                "textDocument/didClose",
                json!({
                    "textDocument": { "uri": uri }
                }),
            )
            .await?;
        }
        Ok(())
    }

    pub async fn stop(&mut self) {
        let _ = self.send_request("shutdown", json!(null)).await;
        let _ = self.send_notification("exit", json!(null)).await;

        self.reader_task.abort();

        if let Err(e) = self.child.kill().await {
            warn!(
                "LSP kill failed: workspace={}, language={}, err={}",
                self.workspace_key,
                self.language.as_str(),
                e
            );
        }
    }

    async fn send_request(&mut self, method: &str, params: Value) -> Result<u64, String> {
        let id = self.next_request_id;
        self.next_request_id += 1;
        self.send_json(json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        }))
        .await?;
        Ok(id)
    }

    async fn send_notification(&self, method: &str, params: Value) -> Result<(), String> {
        self.send_json(json!({
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        }))
        .await
    }

    async fn send_json(&self, value: Value) -> Result<(), String> {
        let payload = serde_json::to_vec(&value).map_err(|e| e.to_string())?;
        let header = format!("Content-Length: {}\r\n\r\n", payload.len());
        let mut writer = self.stdin.lock().await;
        writer
            .write_all(header.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        writer
            .write_all(&payload)
            .await
            .map_err(|e| e.to_string())?;
        writer.flush().await.map_err(|e| e.to_string())
    }

    fn spawn_reader_task(
        stdout: ChildStdout,
        workspace_key: String,
        language: LspLanguage,
        event_tx: mpsc::Sender<SupervisorEvent>,
    ) -> JoinHandle<()> {
        tokio::spawn(async move {
            let mut reader = BufReader::new(stdout);
            loop {
                match Self::read_one_message(&mut reader).await {
                    Ok(Some(msg)) => {
                        if let Some(method) = msg.get("method").and_then(|v| v.as_str()) {
                            if method == "textDocument/publishDiagnostics" {
                                if let Some(params) = msg.get("params") {
                                    let uri = params
                                        .get("uri")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or_default()
                                        .to_string();
                                    if uri.is_empty() {
                                        continue;
                                    }
                                    let diagnostics = params
                                        .get("diagnostics")
                                        .and_then(|v| v.as_array())
                                        .map(|arr| {
                                            arr.iter()
                                                .map(Self::parse_raw_diagnostic)
                                                .collect::<Vec<RawLspDiagnostic>>()
                                        })
                                        .unwrap_or_default();

                                    let _ = event_tx
                                        .send(SupervisorEvent::PublishDiagnostics {
                                            workspace_key: workspace_key.clone(),
                                            language,
                                            uri,
                                            diagnostics,
                                        })
                                        .await;
                                }
                            }
                        }
                    }
                    Ok(None) => {
                        let _ = event_tx
                            .send(SupervisorEvent::SessionExited {
                                workspace_key: workspace_key.clone(),
                                language,
                                reason: "stdout_closed".to_string(),
                            })
                            .await;
                        break;
                    }
                    Err(err) => {
                        debug!(
                            "LSP reader error: workspace={}, language={}, err={}",
                            workspace_key,
                            language.as_str(),
                            err
                        );
                        let _ = event_tx
                            .send(SupervisorEvent::SessionExited {
                                workspace_key: workspace_key.clone(),
                                language,
                                reason: err,
                            })
                            .await;
                        break;
                    }
                }
            }
        })
    }

    async fn read_one_message(
        reader: &mut BufReader<ChildStdout>,
    ) -> Result<Option<Value>, String> {
        let mut content_length: Option<usize> = None;

        loop {
            let mut line = String::new();
            let n = reader
                .read_line(&mut line)
                .await
                .map_err(|e| e.to_string())?;

            if n == 0 {
                return Ok(None);
            }

            let trimmed = line.trim_end_matches(['\r', '\n']);
            if trimmed.is_empty() {
                break;
            }

            if let Some(rest) = trimmed.strip_prefix("Content-Length:") {
                let parsed = rest
                    .trim()
                    .parse::<usize>()
                    .map_err(|e| format!("invalid content-length: {}", e))?;
                content_length = Some(parsed);
            }
        }

        let len = match content_length {
            Some(v) => v,
            None => return Err("missing Content-Length".to_string()),
        };

        let mut buf = vec![0u8; len];
        reader
            .read_exact(&mut buf)
            .await
            .map_err(|e| e.to_string())?;
        let value = serde_json::from_slice::<Value>(&buf).map_err(|e| e.to_string())?;
        Ok(Some(value))
    }

    fn parse_raw_diagnostic(raw: &Value) -> RawLspDiagnostic {
        let start = raw
            .get("range")
            .and_then(|r| r.get("start"))
            .cloned()
            .unwrap_or_else(|| json!({}));
        let end = raw
            .get("range")
            .and_then(|r| r.get("end"))
            .cloned()
            .unwrap_or_else(|| json!({}));

        let line = start.get("line").and_then(|v| v.as_u64()).unwrap_or(0) as u32 + 1;
        let column = start.get("character").and_then(|v| v.as_u64()).unwrap_or(0) as u32 + 1;
        let end_line = end.get("line").and_then(|v| v.as_u64()).unwrap_or(0) as u32 + 1;
        let end_column = end.get("character").and_then(|v| v.as_u64()).unwrap_or(0) as u32 + 1;

        let severity = raw
            .get("severity")
            .and_then(|v| v.as_i64())
            .map(LspSeverity::from_lsp_int)
            .unwrap_or(LspSeverity::Info);
        let message = raw
            .get("message")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        let source = raw
            .get("source")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        let code = raw.get("code").and_then(|v| {
            if let Some(s) = v.as_str() {
                Some(s.to_string())
            } else {
                v.as_i64().map(|n| n.to_string())
            }
        });

        RawLspDiagnostic {
            line,
            column,
            end_line,
            end_column,
            severity,
            message,
            source,
            code,
        }
    }

    fn path_to_uri(path: &Path) -> Result<String, String> {
        Url::from_file_path(path)
            .map(|u| u.to_string())
            .map_err(|_| format!("invalid file path to uri: {}", path.display()))
    }

    pub fn root_path(&self) -> &Path {
        &self.root_path
    }
}
