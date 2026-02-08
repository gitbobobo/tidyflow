use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::{broadcast, mpsc, Mutex};
use tracing::{debug, info};
use uuid::Uuid;

use crate::pty::PtySession;
use crate::server::protocol::TerminalInfo;

/// 默认 scrollback 缓冲区大小：256KB
const DEFAULT_SCROLLBACK_CAPACITY: usize = 256 * 1024;

/// 终端状态
#[derive(Debug, Clone)]
pub enum TerminalStatus {
    Running,
    Exited(i32),
}

/// 环形 scrollback 缓冲区，保留最近的终端输出用于重连回放
pub struct ScrollbackBuffer {
    chunks: VecDeque<Vec<u8>>,
    total_bytes: usize,
    capacity: usize,
}

impl ScrollbackBuffer {
    pub fn new(capacity: usize) -> Self {
        Self {
            chunks: VecDeque::new(),
            total_bytes: 0,
            capacity,
        }
    }

    /// 追加数据，超出容量时淘汰旧数据
    pub fn push(&mut self, data: Vec<u8>) {
        self.total_bytes += data.len();
        self.chunks.push_back(data);
        // 淘汰旧数据直到总量不超过容量
        while self.total_bytes > self.capacity && !self.chunks.is_empty() {
            if let Some(old) = self.chunks.pop_front() {
                self.total_bytes -= old.len();
            }
        }
    }

    /// 返回全部 scrollback 数据的快照，用于重连回放
    pub fn snapshot(&self) -> Vec<u8> {
        let mut result = Vec::with_capacity(self.total_bytes);
        for chunk in &self.chunks {
            result.extend_from_slice(chunk);
        }
        result
    }
}

/// 单个终端条目
pub struct TerminalEntry {
    pub session: PtySession,
    pub term_id: String,
    pub project: String,
    pub workspace: String,
    pub cwd: PathBuf,
    pub shell: String,
    pub status: TerminalStatus,
    /// 多订阅者广播通道（term_id, data）
    pub output_tx: broadcast::Sender<(String, Vec<u8>)>,
    pub scrollback: ScrollbackBuffer,
}

/// 全局终端注册表，生命周期 = Core 进程生命周期
pub struct TerminalRegistry {
    terminals: HashMap<String, TerminalEntry>,
    default_term_id: Option<String>,
}

pub type SharedTerminalRegistry = Arc<Mutex<TerminalRegistry>>;

impl Default for TerminalRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl TerminalRegistry {
    pub fn new() -> Self {
        Self {
            terminals: HashMap::new(),
            default_term_id: None,
        }
    }

    /// 创建新的 PTY 终端，启动读取线程，返回 (term_id, shell)
    pub fn spawn(
        &mut self,
        cwd: Option<PathBuf>,
        project: Option<String>,
        workspace: Option<String>,
        scrollback_tx: mpsc::Sender<(String, Vec<u8>)>,
    ) -> Result<(String, String), String> {
        let term_id = Uuid::new_v4().to_string();
        let cwd_path = cwd.unwrap_or_else(|| {
            PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/".to_string()))
        });

        let mut session = PtySession::new(Some(cwd_path.clone()))
            .map_err(|e| format!("Failed to create PTY: {}", e))?;

        let shell_name = session.shell_name().to_string();

        // 创建 broadcast 通道，用于多 WS 订阅者
        let (output_tx, _) = broadcast::channel::<(String, Vec<u8>)>(256);

        // 为读取线程创建 broadcast sender 的克隆
        let reader_output_tx = output_tx.clone();
        let reader_scrollback_tx = scrollback_tx;
        let reader_term_id = term_id.clone();

        let reader = session
            .take_reader()
            .map_err(|e| format!("Failed to take reader: {}", e))?;

        // PTY 读取线程：复用原有 ANSI 序列完整性检查逻辑
        std::thread::spawn(move || {
            use std::io::Read;
            let mut reader = reader;
            let mut buf = [0u8; 8192];
            let mut pending: Vec<u8> = Vec::new();
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => {
                        if !pending.is_empty() {
                            let _ = reader_output_tx
                                .send((reader_term_id.clone(), pending.clone()));
                            let _ = reader_scrollback_tx
                                .blocking_send((reader_term_id.clone(), pending));
                        }
                        break;
                    }
                    Ok(n) => {
                        let mut data = if pending.is_empty() {
                            buf[..n].to_vec()
                        } else {
                            let mut combined = std::mem::take(&mut pending);
                            combined.extend_from_slice(&buf[..n]);
                            combined
                        };

                        if let Some(incomplete_start) =
                            find_incomplete_escape_sequence(&data)
                        {
                            pending = data.split_off(incomplete_start);
                        }

                        if !data.is_empty() {
                            // 发送到 broadcast（多订阅者）
                            let _ = reader_output_tx
                                .send((reader_term_id.clone(), data.clone()));
                            // 发送到 scrollback 写入通道
                            if reader_scrollback_tx
                                .blocking_send((reader_term_id.clone(), data))
                                .is_err()
                            {
                                break;
                            }
                        }
                    }
                    Err(e) => {
                        debug!(
                            "PTY read error for {}: {}",
                            reader_term_id, e
                        );
                        break;
                    }
                }
            }
        });

        let entry = TerminalEntry {
            session,
            term_id: term_id.clone(),
            project: project.unwrap_or_default(),
            workspace: workspace.unwrap_or_default(),
            cwd: cwd_path,
            shell: shell_name.clone(),
            status: TerminalStatus::Running,
            output_tx,
            scrollback: ScrollbackBuffer::new(DEFAULT_SCROLLBACK_CAPACITY),
        };

        if self.default_term_id.is_none() {
            self.default_term_id = Some(term_id.clone());
        }

        self.terminals.insert(term_id.clone(), entry);

        Ok((term_id, shell_name))
    }

    /// 订阅终端输出，返回 broadcast::Receiver
    pub fn subscribe(
        &self,
        term_id: &str,
    ) -> Option<broadcast::Receiver<(String, Vec<u8>)>> {
        self.terminals
            .get(term_id)
            .map(|e| e.output_tx.subscribe())
    }

    /// 获取终端的 scrollback 快照
    pub fn get_scrollback(&self, term_id: &str) -> Option<Vec<u8>> {
        self.terminals
            .get(term_id)
            .map(|e| e.scrollback.snapshot())
    }

    /// 写入终端输入
    pub fn write_input(
        &mut self,
        term_id: &str,
        data: &[u8],
    ) -> Result<(), String> {
        if let Some(entry) = self.terminals.get_mut(term_id) {
            entry
                .session
                .write_input(data)
                .map_err(|e| format!("Write error: {}", e))
        } else {
            Err(format!("Terminal '{}' not found", term_id))
        }
    }

    /// 调整终端大小
    pub fn resize(
        &self,
        term_id: &str,
        cols: u16,
        rows: u16,
    ) -> Result<(), String> {
        if let Some(entry) = self.terminals.get(term_id) {
            entry
                .session
                .resize(cols, rows)
                .map_err(|e| format!("Resize error: {}", e))
        } else {
            Err(format!("Terminal '{}' not found", term_id))
        }
    }

    /// 关闭指定终端
    pub fn close(&mut self, term_id: &str) -> bool {
        if let Some(mut entry) = self.terminals.remove(term_id) {
            entry.session.kill();
            if self.default_term_id.as_ref() == Some(&term_id.to_string()) {
                self.default_term_id = self.terminals.keys().next().cloned();
            }
            true
        } else {
            false
        }
    }

    /// 关闭所有终端（仅在 Core 进程退出时调用）
    pub fn close_all(&mut self) {
        for (_, mut entry) in self.terminals.drain() {
            entry.session.kill();
        }
        self.default_term_id = None;
    }

    /// 列出所有终端信息
    pub fn list(&self) -> Vec<TerminalInfo> {
        self.terminals
            .values()
            .map(|e| TerminalInfo {
                term_id: e.term_id.clone(),
                project: e.project.clone(),
                workspace: e.workspace.clone(),
                cwd: e.cwd.to_string_lossy().to_string(),
                status: match &e.status {
                    TerminalStatus::Running => "running".to_string(),
                    TerminalStatus::Exited(code) => {
                        format!("exited({})", code)
                    }
                },
                shell: e.shell.clone(),
            })
            .collect()
    }

    /// 获取终端信息（用于 TermAttach 响应）
    pub fn get_info(
        &self,
        term_id: &str,
    ) -> Option<(String, String, String, String)> {
        self.terminals.get(term_id).map(|e| {
            (
                e.project.clone(),
                e.workspace.clone(),
                e.cwd.to_string_lossy().to_string(),
                e.shell.clone(),
            )
        })
    }

    pub fn contains(&self, term_id: &str) -> bool {
        self.terminals.contains_key(term_id)
    }

    pub fn resolve_term_id(&self, term_id: Option<&str>) -> Option<String> {
        match term_id {
            Some(id) if self.terminals.contains_key(id) => {
                Some(id.to_string())
            }
            Some(_) => None,
            None => self.default_term_id.clone(),
        }
    }

    pub fn term_ids(&self) -> Vec<String> {
        self.terminals.keys().cloned().collect()
    }
}

/// 启动 scrollback 写入 task（异步处理，避免 std::thread 中 await Mutex）
pub fn spawn_scrollback_writer(
    registry: SharedTerminalRegistry,
) -> mpsc::Sender<(String, Vec<u8>)> {
    let (tx, mut rx) = mpsc::channel::<(String, Vec<u8>)>(512);

    tokio::spawn(async move {
        while let Some((term_id, data)) = rx.recv().await {
            let mut reg = registry.lock().await;
            if let Some(entry) = reg.terminals.get_mut(&term_id) {
                entry.scrollback.push(data);
            }
        }
        info!("Scrollback writer task exited");
    });

    tx
}

/// 查找数据末尾不完整的 ANSI 转义序列的起始位置
/// 返回 Some(index) 表示从 index 开始是不完整的序列，需要保留到下次发送
/// 返回 None 表示数据完整，可以直接发送
///
/// ANSI 转义序列格式：
/// - CSI (Control Sequence Introducer): ESC [ ... 终止符 (字母)
/// - OSC (Operating System Command): ESC ] ... BEL 或 ESC \\
/// - DCS (Device Control String): ESC P ... ESC \\
/// - 简单序列: ESC 后跟单个字符
fn find_incomplete_escape_sequence(data: &[u8]) -> Option<usize> {
    if data.is_empty() {
        return None;
    }

    let search_start = data.len().saturating_sub(256);

    for i in (search_start..data.len()).rev() {
        if data[i] == 0x1b {
            let remaining = &data[i..];

            if remaining.len() < 2 {
                return Some(i);
            }

            match remaining[1] {
                b'[' => {
                    if remaining.len() == 2 {
                        return Some(i);
                    }
                    let found_terminator = remaining
                        .iter()
                        .skip(2)
                        .any(|&c| (0x40..=0x7E).contains(&c));
                    if !found_terminator {
                        return Some(i);
                    }
                }
                b']' => {
                    let mut found_terminator = false;
                    for j in 2..remaining.len() {
                        if remaining[j] == 0x07 {
                            found_terminator = true;
                            break;
                        }
                        if remaining[j] == 0x1b
                            && j + 1 < remaining.len()
                            && remaining[j + 1] == b'\\'
                        {
                            found_terminator = true;
                            break;
                        }
                    }
                    if !found_terminator {
                        return Some(i);
                    }
                }
                b'P' => {
                    let mut found_terminator = false;
                    for j in 2..remaining.len() {
                        if remaining[j] == 0x1b
                            && j + 1 < remaining.len()
                            && remaining[j + 1] == b'\\'
                        {
                            found_terminator = true;
                            break;
                        }
                    }
                    if !found_terminator {
                        return Some(i);
                    }
                }
                _ => {}
            }
        }
    }

    // 检查 UTF-8 多字节字符是否被截断
    if !data.is_empty() {
        let last = data[data.len() - 1];
        if last >= 0xC0 {
            return Some(data.len() - 1);
        }
        if data.len() >= 2 {
            let second_last = data[data.len() - 2];
            if second_last >= 0xE0 && (0x80..0xC0).contains(&last) {
                return Some(data.len() - 2);
            }
        }
        if data.len() >= 3 {
            let third_last = data[data.len() - 3];
            if third_last >= 0xF0
                && data[data.len() - 2] >= 0x80
                && last >= 0x80
            {
                return Some(data.len() - 3);
            }
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_scrollback_buffer() {
        let mut buf = ScrollbackBuffer::new(100);
        buf.push(vec![1; 50]);
        buf.push(vec![2; 50]);
        assert_eq!(buf.total_bytes, 100);
        assert_eq!(buf.snapshot().len(), 100);

        // 超出容量，淘汰旧数据
        buf.push(vec![3; 60]);
        assert!(buf.total_bytes <= 100);
        let snap = buf.snapshot();
        // 应该只包含最新的数据
        assert!(snap.len() <= 110);
    }

    #[test]
    fn test_find_incomplete_escape_sequence_complete() {
        let data = b"\x1b[31mHello\x1b[0m";
        assert_eq!(find_incomplete_escape_sequence(data), None);

        let data = b"\x1b]0;Title\x07";
        assert_eq!(find_incomplete_escape_sequence(data), None);

        let data = b"Hello World";
        assert_eq!(find_incomplete_escape_sequence(data), None);
    }

    #[test]
    fn test_find_incomplete_escape_sequence_incomplete_csi() {
        let data = b"Hello\x1b[";
        assert_eq!(find_incomplete_escape_sequence(data), Some(5));

        let data = b"Hello\x1b[38;2;255";
        assert_eq!(find_incomplete_escape_sequence(data), Some(5));
    }

    #[test]
    fn test_find_incomplete_escape_sequence_incomplete_osc() {
        let data = b"Hello\x1b]0;Title";
        assert_eq!(find_incomplete_escape_sequence(data), Some(5));
    }

    #[test]
    fn test_find_incomplete_escape_sequence_lone_esc() {
        let data = b"Hello\x1b";
        assert_eq!(find_incomplete_escape_sequence(data), Some(5));
    }

    #[test]
    fn test_find_incomplete_escape_sequence_utf8() {
        let data = "你好".as_bytes();
        assert_eq!(find_incomplete_escape_sequence(data), None);

        let data = b"Hello\xe4";
        assert_eq!(find_incomplete_escape_sequence(data), Some(5));

        let data = b"Hello\xe4\xbd";
        assert_eq!(find_incomplete_escape_sequence(data), Some(5));
    }
}
