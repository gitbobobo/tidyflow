use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{broadcast, mpsc, Mutex};
use tracing::{debug, info, warn};
use uuid::Uuid;

use crate::pty::PtySession;
use crate::server::protocol::TerminalInfo;

// chrono は chrono::Utc 経由で使用
use chrono;

/// 默认 scrollback 缓冲区大小：256KB（终端初始容量）
const DEFAULT_SCROLLBACK_CAPACITY: usize = 256 * 1024;

/// 每个终端的最大 scrollback 上限：512KB
const PER_TERMINAL_SCROLLBACK_LIMIT_BYTES: usize = 512 * 1024;

/// 全局 scrollback 总预算：64MB；超出时优先裁剪最久不活跃的终端
pub const GLOBAL_SCROLLBACK_BUDGET_BYTES: usize = 64 * 1024 * 1024;

/// TermAttach 回放限制：最多回放最近 64KB 输出，避免大量历史数据整块复制
pub const ATTACH_REPLAY_LIMIT_BYTES: usize = 64 * 1024;

/// 空闲终端回收超时：3600 秒（1 小时无订阅且无活动则自动回收）
const IDLE_REAP_TIMEOUT_SECS: u64 = 3600;

/// 后台空闲检测间隔：30 秒
const REAPER_INTERVAL_SECS: u64 = 30;

// ============================================================================
// 终端资源可观测性类型
// ============================================================================

/// 单工作区的终端资源摘要
#[derive(Debug, Clone)]
pub struct WorkspaceTerminalInfo {
    pub project: String,
    pub workspace: String,
    pub terminal_count: usize,
    pub scrollback_bytes: usize,
}

/// 终端注册表资源快照（用于 system_snapshot 与健康探针）
#[derive(Debug, Clone)]
pub struct TerminalResourceInfo {
    pub total_terminal_count: usize,
    pub total_scrollback_bytes: usize,
    pub global_budget_bytes: usize,
    pub budget_used_percent: u8,
    pub per_workspace: Vec<WorkspaceTerminalInfo>,
}

/// PTY 读取线程背压门控
///
/// 当所有订阅者都处于高水位暂停状态时，阻塞 PTY 读取线程，
/// 让子进程的 stdout 管道自然产生背压，避免无限制内存分配。
pub struct PtyFlowGate {
    state: std::sync::Mutex<FlowGateState>,
    condvar: std::sync::Condvar,
}

struct FlowGateState {
    subscriber_count: u32,
    paused_count: u32,
}

impl PtyFlowGate {
    pub fn new() -> Self {
        Self {
            state: std::sync::Mutex::new(FlowGateState {
                subscriber_count: 0,
                paused_count: 0,
            }),
            condvar: std::sync::Condvar::new(),
        }
    }

    /// PTY 读取线程每次 read 前调用；当所有订阅者都暂停时阻塞等待（带超时兜底）
    pub fn wait_if_all_paused(&self, timeout: Duration) {
        let guard = self.state.lock().unwrap();
        if guard.subscriber_count > 0 && guard.paused_count >= guard.subscriber_count {
            let _result = self.condvar.wait_timeout_while(guard, timeout, |s| {
                s.subscriber_count > 0 && s.paused_count >= s.subscriber_count
            });
        }
    }

    /// 查询当前活跃订阅者数量
    pub fn subscriber_count(&self) -> u32 {
        self.state.lock().unwrap().subscriber_count
    }

    /// 转发任务进入高水位时调用
    pub fn mark_paused(&self) {
        let mut guard = self.state.lock().unwrap();
        guard.paused_count = guard.paused_count.saturating_add(1);
    }

    /// 转发任务离开高水位时调用
    pub fn mark_resumed(&self) {
        let mut guard = self.state.lock().unwrap();
        guard.paused_count = guard.paused_count.saturating_sub(1);
        if guard.subscriber_count == 0 || guard.paused_count < guard.subscriber_count {
            self.condvar.notify_all();
        }
    }

    /// 新增订阅者
    pub fn add_subscriber(&self) {
        let mut guard = self.state.lock().unwrap();
        guard.subscriber_count += 1;
        // 新订阅者加入后，paused_count < subscriber_count，唤醒读取线程
        self.condvar.notify_all();
    }

    /// 移除订阅者（同时减少 paused_count 以保持一致性）
    pub fn remove_subscriber(&self) {
        let mut guard = self.state.lock().unwrap();
        guard.subscriber_count = guard.subscriber_count.saturating_sub(1);
        // 保守处理：同步减少 paused_count，避免 paused > subscriber
        if guard.paused_count > guard.subscriber_count {
            guard.paused_count = guard.subscriber_count;
        }
        // 订阅者减少后可能不再全部暂停，唤醒读取线程
        if guard.subscriber_count == 0 || guard.paused_count < guard.subscriber_count {
            self.condvar.notify_all();
        }
    }
}

/// 终端状态
#[derive(Debug, Clone)]
pub enum TerminalStatus {
    Running,
    Exited(i32),
}

/// 终端生命周期相位
///
/// 与 `TerminalStatus`（Running/Exited）正交：
/// - `TerminalStatus` 描述 PTY 进程状态
/// - `TerminalLifecyclePhase` 描述客户端连接层的相位
///
/// 状态迁移：
///   spawn → Entering → (首个订阅者) → Active
///   detach/断连(最后订阅者) → Idle
///   attach/重连 → Resuming → Active
///   Core 重启/恢复元数据存在 → Recovering → Active | RecoveryFailed
///   close/reclaim → 移除
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalLifecyclePhase {
    /// 正在创建/初始化，尚未有活跃订阅者确认
    Entering,
    /// 有活跃订阅者，输出正常流转
    Active,
    /// 客户端正在重新附着（attach/重连），回放 scrollback 中
    Resuming,
    /// 无活跃订阅者，终端保持运行但处于空闲
    Idle,
    /// Core 重启后从持久化恢复元数据重建终端中（区别于 Resuming 的 WS 断连场景）
    Recovering,
    /// 从持久化恢复失败，等待客户端确认或清除
    RecoveryFailed,
}

impl TerminalLifecyclePhase {
    /// 转为协议字段字符串
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Entering => "entering",
            Self::Active => "active",
            Self::Resuming => "resuming",
            Self::Idle => "idle",
            Self::Recovering => "recovering",
            Self::RecoveryFailed => "recovery_failed",
        }
    }
}

/// 终端恢复元数据（Core 权威持久化字段）
///
/// 只存储恢复所需的最小字段，不持久化 scrollback、订阅计数等运行时数据。
/// 按 `(project, workspace, term_id)` 三元组严格隔离，禁止跨工作区共享。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalRecoveryMeta {
    /// 终端 ID（Core 生成的 UUID）
    pub term_id: String,
    /// 所属项目名
    pub project: String,
    /// 所属工作区名
    pub workspace: String,
    /// 终端工作目录（用于重建 PTY）
    pub cwd: String,
    /// Shell 名称（如 "zsh", "bash"）
    pub shell: String,
    /// 用户自定义展示名称
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// 用户自定义图标
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    /// 恢复状态：`pending` | `recovering` | `recovered` | `failed`
    pub recovery_state: String,
    /// 恢复失败原因（仅 recovery_state=failed 时有值）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub failed_reason: Option<String>,
    /// 记录创建时间（用于清理过期恢复记录）
    pub created_at: String,
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

    /// 返回最近 `max_bytes` 字节的快照，用于受限回放
    ///
    /// - 从尾部截取，保证 UTF-8 多字节边界完整性（跳过截断的前导字节）
    /// - 不保证截断点之前的 ANSI 序列完整，但能保证客户端不会因 UTF-8 截断而乱码
    pub fn snapshot_limited(&self, max_bytes: usize) -> Vec<u8> {
        if self.total_bytes <= max_bytes {
            return self.snapshot();
        }
        // 需要跳过最前面 (total_bytes - max_bytes) 字节
        let skip = self.total_bytes - max_bytes;
        let mut result = Vec::with_capacity(max_bytes);
        let mut skipped = 0usize;
        for chunk in &self.chunks {
            if skipped + chunk.len() <= skip {
                skipped += chunk.len();
                continue;
            }
            let chunk_skip = skip.saturating_sub(skipped);
            skipped += chunk.len();
            result.extend_from_slice(&chunk[chunk_skip..]);
        }
        // 确保从有效 UTF-8 起始字节开始，避免乱码
        align_to_utf8_start(result)
    }

    /// 裁剪缓冲区到目标字节数（移除最旧的数据）
    pub fn trim_to(&mut self, target_bytes: usize) {
        while self.total_bytes > target_bytes && !self.chunks.is_empty() {
            if let Some(old) = self.chunks.pop_front() {
                self.total_bytes -= old.len();
            }
        }
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
    /// 客户端连接层生命周期相位
    pub lifecycle_phase: TerminalLifecyclePhase,
    /// 客户端自定义展示名称（如命令名）
    pub name: Option<String>,
    /// 客户端自定义图标标识
    pub icon: Option<String>,
    /// 终端恢复元数据（Core 重启后持久化恢复所需最小字段）
    pub recovery_meta: Option<TerminalRecoveryMeta>,
    /// 多订阅者广播通道（term_id, data）
    pub output_tx: broadcast::Sender<(String, Vec<u8>)>,
    pub scrollback: ScrollbackBuffer,
    /// PTY 读取线程背压门控
    pub flow_gate: Arc<PtyFlowGate>,
    /// 最近活跃时间（写入 input 或收到 PTY 输出时更新）
    pub last_active_at: Instant,
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
        initial_cols: Option<u16>,
        initial_rows: Option<u16>,
        name: Option<String>,
        icon: Option<String>,
    ) -> Result<(String, String), String> {
        let term_id = Uuid::new_v4().to_string();
        let cwd_path = cwd.unwrap_or_else(|| {
            PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/".to_string()))
        });

        let mut session = PtySession::new(Some(cwd_path.clone()), initial_cols, initial_rows)
            .map_err(|e| format!("Failed to create PTY: {}", e))?;

        let shell_name = session.shell_name().to_string();

        // 创建 broadcast 通道，用于多 WS 订阅者
        let (output_tx, _) = broadcast::channel::<(String, Vec<u8>)>(256);

        // 创建背压门控
        let flow_gate = Arc::new(PtyFlowGate::new());

        // 为读取线程创建 broadcast sender 的克隆
        let reader_output_tx = output_tx.clone();
        let reader_scrollback_tx = scrollback_tx;
        // 使用 Arc<str> 避免每次循环都 clone String
        let reader_term_id: Arc<str> = Arc::from(term_id.as_str());
        let reader_flow_gate = flow_gate.clone();

        let reader = session
            .take_reader()
            .map_err(|e| format!("Failed to take reader: {}", e))?;

        // PTY 读取线程：复用原有 ANSI 序列完整性检查逻辑
        std::thread::spawn(move || {
            use std::io::Read;
            let mut reader = reader;
            let mut buf = [0u8; 8192];
            let mut pending: Vec<u8> = Vec::new();
            // 预分配 term_id String，循环内直接 clone（比 Arc<str>.to_string() 略快）
            let tid_string = reader_term_id.to_string();
            loop {
                // 背压门控：当所有订阅者都处于高水位时阻塞，让子进程 stdout 管道自然产生背压
                reader_flow_gate.wait_if_all_paused(Duration::from_secs(2));
                match reader.read(&mut buf) {
                    Ok(0) => {
                        if !pending.is_empty() {
                            let _ = reader_output_tx.send((tid_string.clone(), pending.clone()));
                            let _ =
                                reader_scrollback_tx.blocking_send((tid_string.clone(), pending));
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

                        if let Some(incomplete_start) = find_incomplete_escape_sequence(&data) {
                            pending = data.split_off(incomplete_start);
                        }

                        if !data.is_empty() {
                            // 先发送到 scrollback（clone 数据）
                            let scrollback_data = data.clone();
                            // 发送到 broadcast（多订阅者），转移 data 所有权避免额外 clone
                            let _ = reader_output_tx.send((tid_string.clone(), data));
                            // 发送到 scrollback 写入通道
                            if reader_scrollback_tx
                                .blocking_send((tid_string.clone(), scrollback_data))
                                .is_err()
                            {
                                break;
                            }
                        }
                    }
                    Err(e) => {
                        debug!("PTY read error for {}: {}", reader_term_id, e);
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
            lifecycle_phase: TerminalLifecyclePhase::Entering,
            name,
            icon,
            recovery_meta: None,
            output_tx,
            scrollback: ScrollbackBuffer::new(DEFAULT_SCROLLBACK_CAPACITY),
            flow_gate,
            last_active_at: Instant::now(),
        };

        if self.default_term_id.is_none() {
            self.default_term_id = Some(term_id.clone());
        }

        self.terminals.insert(term_id.clone(), entry);

        Ok((term_id, shell_name))
    }

    /// 订阅终端输出，返回 (broadcast::Receiver, Arc<PtyFlowGate>)
    pub fn subscribe(
        &self,
        term_id: &str,
    ) -> Option<(broadcast::Receiver<(String, Vec<u8>)>, Arc<PtyFlowGate>)> {
        self.terminals
            .get(term_id)
            .map(|e| (e.output_tx.subscribe(), e.flow_gate.clone()))
    }

    /// 获取终端的 scrollback 快照（全量）
    pub fn get_scrollback(&self, term_id: &str) -> Option<Vec<u8>> {
        self.terminals.get(term_id).map(|e| e.scrollback.snapshot())
    }

    /// 获取终端的受限 scrollback 快照（用于 TermAttach 回放，避免整块复制大缓冲）
    pub fn get_scrollback_limited(&self, term_id: &str, max_bytes: usize) -> Option<Vec<u8>> {
        self.terminals
            .get(term_id)
            .map(|e| e.scrollback.snapshot_limited(max_bytes))
    }

    /// 统计所有终端的 scrollback 总字节数
    pub fn total_scrollback_bytes(&self) -> usize {
        self.terminals
            .values()
            .map(|e| e.scrollback.total_bytes)
            .sum()
    }

    /// 按全局预算裁剪 scrollback：优先裁剪最久不活跃的终端
    ///
    /// 同时强制各终端不超过 PER_TERMINAL_SCROLLBACK_LIMIT_BYTES。
    /// 返回被裁剪的终端数量。
    pub fn trim_scrollback_to_budget(&mut self) -> usize {
        // 先强制每个终端不超过单终端上限
        for entry in self.terminals.values_mut() {
            if entry.scrollback.total_bytes > PER_TERMINAL_SCROLLBACK_LIMIT_BYTES {
                entry
                    .scrollback
                    .trim_to(PER_TERMINAL_SCROLLBACK_LIMIT_BYTES);
                entry.scrollback.capacity = PER_TERMINAL_SCROLLBACK_LIMIT_BYTES;
            }
        }

        let total = self.total_scrollback_bytes();
        if total <= GLOBAL_SCROLLBACK_BUDGET_BYTES {
            return 0;
        }

        // 按 last_active_at 升序（最旧的排前面）
        let mut ids: Vec<String> = self.terminals.keys().cloned().collect();
        ids.sort_by_key(|id| {
            self.terminals
                .get(id)
                .map(|e| e.last_active_at)
                .unwrap_or(Instant::now())
        });

        let mut excess = total.saturating_sub(GLOBAL_SCROLLBACK_BUDGET_BYTES);
        let mut trimmed_count = 0usize;

        for id in ids {
            if excess == 0 {
                break;
            }
            if let Some(entry) = self.terminals.get_mut(&id) {
                let before = entry.scrollback.total_bytes;
                if before == 0 {
                    continue;
                }
                let new_target = before.saturating_sub(excess);
                entry.scrollback.trim_to(new_target);
                entry.scrollback.capacity = new_target;
                let freed = before - entry.scrollback.total_bytes;
                excess = excess.saturating_sub(freed);
                if freed > 0 {
                    trimmed_count += 1;
                }
            }
        }

        trimmed_count
    }

    /// 回收空闲/退出终端：
    /// - 已退出（Exited）且订阅者为 0 的终端立即回收
    /// - 运行中但订阅者为 0 且空闲超时的终端回收
    ///
    /// 返回被回收的 term_id 列表。
    pub fn reclaim_idle(&mut self, idle_timeout: Duration) -> Vec<String> {
        let now = Instant::now();

        // 先把无订阅者的终端标记为 Idle（使协议输出一致）
        for entry in self.terminals.values_mut() {
            if entry.flow_gate.subscriber_count() == 0
                && entry.lifecycle_phase != TerminalLifecyclePhase::Idle
            {
                entry.lifecycle_phase = TerminalLifecyclePhase::Idle;
            }
        }

        let to_reclaim: Vec<String> = self
            .terminals
            .iter()
            .filter_map(|(id, entry)| {
                let subs = entry.flow_gate.subscriber_count();
                match &entry.status {
                    TerminalStatus::Exited(_) if subs == 0 => Some(id.clone()),
                    TerminalStatus::Running if subs == 0 => {
                        if now.duration_since(entry.last_active_at) >= idle_timeout {
                            Some(id.clone())
                        } else {
                            None
                        }
                    }
                    _ => None,
                }
            })
            .collect();

        for id in &to_reclaim {
            if let Some(mut entry) = self.terminals.remove(id) {
                entry.session.kill();
                if self.default_term_id.as_deref() == Some(id.as_str()) {
                    self.default_term_id = self.terminals.keys().next().cloned();
                }
                debug!(term_id = %id, "Idle reaper reclaimed terminal");
            }
        }

        if !to_reclaim.is_empty() {
            info!(count = to_reclaim.len(), "Idle reaper reclaimed terminals");
        }

        to_reclaim
    }

    /// 更新指定终端的最近活跃时间（由外部异步路径调用）
    pub fn update_last_active(&mut self, term_id: &str) {
        if let Some(entry) = self.terminals.get_mut(term_id) {
            entry.last_active_at = Instant::now();
        }
    }

    /// 返回终端注册表资源快照（多工作区隔离）
    pub fn resource_info(&self) -> TerminalResourceInfo {
        let total_scrollback_bytes = self.total_scrollback_bytes();
        let budget_used_percent = if GLOBAL_SCROLLBACK_BUDGET_BYTES > 0 {
            ((total_scrollback_bytes as f64 / GLOBAL_SCROLLBACK_BUDGET_BYTES as f64) * 100.0)
                .min(100.0) as u8
        } else {
            0
        };

        // 按 (project, workspace) 聚合
        let mut ws_map: HashMap<(String, String), (usize, usize)> = HashMap::new();
        for entry in self.terminals.values() {
            let key = (entry.project.clone(), entry.workspace.clone());
            let slot = ws_map.entry(key).or_insert((0, 0));
            slot.0 += 1;
            slot.1 += entry.scrollback.total_bytes;
        }

        let mut per_workspace: Vec<WorkspaceTerminalInfo> = ws_map
            .into_iter()
            .map(
                |((project, workspace), (terminal_count, scrollback_bytes))| {
                    WorkspaceTerminalInfo {
                        project,
                        workspace,
                        terminal_count,
                        scrollback_bytes,
                    }
                },
            )
            .collect();
        per_workspace.sort_by(|a, b| (&a.project, &a.workspace).cmp(&(&b.project, &b.workspace)));

        TerminalResourceInfo {
            total_terminal_count: self.terminals.len(),
            total_scrollback_bytes,
            global_budget_bytes: GLOBAL_SCROLLBACK_BUDGET_BYTES,
            budget_used_percent,
            per_workspace,
        }
    }

    /// 写入终端输入
    pub fn write_input(&mut self, term_id: &str, data: &[u8]) -> Result<(), String> {
        if let Some(entry) = self.terminals.get_mut(term_id) {
            entry.last_active_at = Instant::now();
            entry
                .session
                .write_input(data)
                .map_err(|e| format!("Write error: {}", e))
        } else {
            Err(format!("Terminal '{}' not found", term_id))
        }
    }

    /// 调整终端大小
    pub fn resize(&self, term_id: &str, cols: u16, rows: u16) -> Result<(), String> {
        if let Some(entry) = self.terminals.get(term_id) {
            entry
                .session
                .resize(cols, rows)
                .map_err(|e| format!("Resize error: {}", e))
        } else {
            Err(format!("Terminal '{}' not found", term_id))
        }
    }

    // MARK: - 生命周期相位迁移

    /// 将终端相位迁移到 Active（首个订阅者连接或 attach 完成后调用）
    pub fn transition_to_active(&mut self, term_id: &str) {
        if let Some(entry) = self.terminals.get_mut(term_id) {
            entry.lifecycle_phase = TerminalLifecyclePhase::Active;
        }
    }

    /// 将终端相位迁移到 Resuming（客户端 attach 请求到达时调用）
    pub fn transition_to_resuming(&mut self, term_id: &str) {
        if let Some(entry) = self.terminals.get_mut(term_id) {
            entry.lifecycle_phase = TerminalLifecyclePhase::Resuming;
        }
    }

    /// 将终端相位迁移到 Idle（最后一个订阅者断开时调用）
    pub fn transition_to_idle(&mut self, term_id: &str) {
        if let Some(entry) = self.terminals.get_mut(term_id) {
            entry.lifecycle_phase = TerminalLifecyclePhase::Idle;
        }
    }

    /// 获取终端当前的生命周期相位
    pub fn lifecycle_phase(&self, term_id: &str) -> Option<TerminalLifecyclePhase> {
        self.terminals.get(term_id).map(|e| e.lifecycle_phase)
    }

    /// 检查 attach 请求的 (project, workspace) 是否与终端实际上下文匹配。
    /// 返回 None 表示终端不存在，Some(true) 表示匹配，Some(false) 表示失配。
    pub fn validate_workspace_context(
        &self,
        term_id: &str,
        project: &str,
        workspace: &str,
    ) -> Option<bool> {
        self.terminals
            .get(term_id)
            .map(|e| e.project == project && e.workspace == workspace)
    }

    /// 获取终端的当前订阅者数量
    pub fn subscriber_count(&self, term_id: &str) -> Option<u32> {
        self.terminals
            .get(term_id)
            .map(|e| e.flow_gate.subscriber_count())
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
                lifecycle_phase: e.lifecycle_phase.as_str().to_string(),
                shell: e.shell.clone(),
                name: e.name.clone(),
                icon: e.icon.clone(),
                recovery_phase: if matches!(
                    e.lifecycle_phase,
                    TerminalLifecyclePhase::Recovering | TerminalLifecyclePhase::RecoveryFailed
                ) {
                    Some(e.lifecycle_phase.as_str().to_string())
                } else {
                    None
                },
                recovery_failed_reason: e
                    .recovery_meta
                    .as_ref()
                    .and_then(|m| m.failed_reason.clone()),
                remote_subscribers: Vec::new(),
            })
            .collect()
    }

    /// 收集当前所有活跃终端的恢复元数据，用于 Core 关闭前持久化
    pub fn collect_recovery_metas(&self) -> Vec<TerminalRecoveryMeta> {
        self.terminals
            .values()
            .filter(|e| matches!(e.status, TerminalStatus::Running))
            .map(|e| TerminalRecoveryMeta {
                term_id: e.term_id.clone(),
                project: e.project.clone(),
                workspace: e.workspace.clone(),
                cwd: e.cwd.to_string_lossy().to_string(),
                shell: e.shell.clone(),
                name: e.name.clone(),
                icon: e.icon.clone(),
                recovery_state: "pending".to_string(),
                failed_reason: None,
                created_at: chrono::Utc::now().to_rfc3339(),
            })
            .collect()
    }

    /// 为终端注册恢复元数据（从持久化加载，Core 重启后使用）
    pub fn set_recovery_meta(&mut self, term_id: &str, meta: TerminalRecoveryMeta) {
        if let Some(entry) = self.terminals.get_mut(term_id) {
            entry.recovery_meta = Some(meta);
        }
    }

    /// 将终端相位推进到 Recovering（Core 重启恢复编排调用）
    pub fn mark_recovering(&mut self, term_id: &str) {
        if let Some(entry) = self.terminals.get_mut(term_id) {
            entry.lifecycle_phase = TerminalLifecyclePhase::Recovering;
            if let Some(meta) = &mut entry.recovery_meta {
                meta.recovery_state = "recovering".to_string();
            }
        }
    }

    /// 将终端相位推进到 RecoveryFailed（恢复编排失败时调用）
    pub fn mark_recovery_failed(&mut self, term_id: &str, reason: String) {
        if let Some(entry) = self.terminals.get_mut(term_id) {
            entry.lifecycle_phase = TerminalLifecyclePhase::RecoveryFailed;
            if let Some(meta) = &mut entry.recovery_meta {
                meta.recovery_state = "failed".to_string();
                meta.failed_reason = Some(reason);
            }
        }
    }

    /// 将终端相位从 Recovering 推进到 Active（恢复成功）
    pub fn mark_recovery_succeeded(&mut self, term_id: &str) {
        if let Some(entry) = self.terminals.get_mut(term_id) {
            entry.lifecycle_phase = TerminalLifecyclePhase::Active;
            if let Some(meta) = &mut entry.recovery_meta {
                meta.recovery_state = "recovered".to_string();
                meta.failed_reason = None;
            }
        }
    }

    /// 列出处于 Recovering 或 RecoveryFailed 相位的终端 ID
    pub fn recovering_term_ids(&self) -> Vec<String> {
        self.terminals
            .values()
            .filter(|e| {
                matches!(
                    e.lifecycle_phase,
                    TerminalLifecyclePhase::Recovering | TerminalLifecyclePhase::RecoveryFailed
                )
            })
            .map(|e| e.term_id.clone())
            .collect()
    }

    /// 获取终端信息（用于 TermAttach 响应）
    pub fn get_info(
        &self,
        term_id: &str,
    ) -> Option<(
        String,
        String,
        String,
        String,
        Option<String>,
        Option<String>,
    )> {
        self.terminals.get(term_id).map(|e| {
            (
                e.project.clone(),
                e.workspace.clone(),
                e.cwd.to_string_lossy().to_string(),
                e.shell.clone(),
                e.name.clone(),
                e.icon.clone(),
            )
        })
    }

    pub fn contains(&self, term_id: &str) -> bool {
        self.terminals.contains_key(term_id)
    }

    pub fn resolve_term_id(&self, term_id: Option<&str>) -> Option<String> {
        match term_id {
            Some(id) if self.terminals.contains_key(id) => Some(id.to_string()),
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
                // PTY 输出到达时更新活跃时间（后台进程也算活跃）
                entry.last_active_at = Instant::now();
            }
        }
        info!("Scrollback writer task exited");
    });

    tx
}

/// 启动空闲终端回收后台任务
///
/// 每 REAPER_INTERVAL_SECS 秒运行一次，回收无订阅者的空闲/退出终端，
/// 同时触发全局 scrollback 预算裁剪。
pub fn spawn_idle_reaper(registry: SharedTerminalRegistry) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(REAPER_INTERVAL_SECS));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let idle_timeout = Duration::from_secs(IDLE_REAP_TIMEOUT_SECS);

        loop {
            interval.tick().await;

            let (reclaimed, trimmed) = {
                let mut reg = registry.lock().await;
                let reclaimed = reg.reclaim_idle(idle_timeout);
                let trimmed = reg.trim_scrollback_to_budget();
                (reclaimed.len(), trimmed)
            };

            if reclaimed > 0 {
                crate::server::perf::record_terminal_reclaimed(reclaimed as u64);
            }
            if trimmed > 0 {
                crate::server::perf::record_terminal_scrollback_trim(trimmed as u64);
                warn!(
                    trimmed_count = trimmed,
                    "Terminal scrollback trimmed due to global budget pressure"
                );
            }
        }
    });
}

/// 从截取点对齐到有效 UTF-8 起始字节，避免截断多字节字符导致乱码
///
/// 连续字节 0x80~0xBF 是 UTF-8 续字节，跳过至多 3 个续字节找到起始字节。
fn align_to_utf8_start(mut data: Vec<u8>) -> Vec<u8> {
    let skip = data
        .iter()
        .take(4)
        .position(|&b| b < 0x80 || b >= 0xC0)
        .unwrap_or(0);
    if skip > 0 {
        data.drain(..skip);
    }
    data
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
            if third_last >= 0xF0 && data[data.len() - 2] >= 0x80 && last >= 0x80 {
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

    // CHK-002: scrollback 回放与裁剪
    #[test]
    fn test_scrollback_limited_returns_full_when_under_limit() {
        let mut buf = ScrollbackBuffer::new(1024);
        buf.push(b"hello world".to_vec());
        let snap = buf.snapshot_limited(1024);
        assert_eq!(snap, b"hello world");
    }

    #[test]
    fn test_scrollback_limited_truncates_to_max_bytes() {
        let mut buf = ScrollbackBuffer::new(1024);
        buf.push(vec![b'A'; 100]);
        buf.push(vec![b'B'; 100]);
        // 要求最多 80 字节
        let snap = buf.snapshot_limited(80);
        assert!(snap.len() <= 80);
        // 末尾应是 'B'
        assert!(snap.iter().all(|&b| b == b'B'));
    }

    #[test]
    fn test_scrollback_limited_utf8_boundary_alignment() {
        // "你好世界" = 12 字节（每汉字 3 字节）
        let text = "你好世界";
        let bytes = text.as_bytes();
        assert_eq!(bytes.len(), 12);
        let mut buf = ScrollbackBuffer::new(1024);
        buf.push(bytes.to_vec());
        // 截取 11 字节会截在最后一个汉字的续字节处
        let snap = buf.snapshot_limited(11);
        // 必须是合法的 UTF-8（如果有内容的话）
        assert!(std::str::from_utf8(&snap).is_ok(), "Should be valid UTF-8");
    }

    #[test]
    fn test_scrollback_trim_to() {
        let mut buf = ScrollbackBuffer::new(1024);
        buf.push(vec![1; 200]);
        buf.push(vec![2; 200]);
        assert_eq!(buf.total_bytes, 400);
        buf.trim_to(150);
        assert!(buf.total_bytes <= 150);
    }

    // CHK-001: 预算裁剪
    #[test]
    fn test_trim_scrollback_to_budget_under_limit_does_nothing() {
        let mut reg = TerminalRegistry::new();
        // 手动插入一个轻量条目
        // 直接构造 scrollback，不启动 PTY
        let total_before = reg.total_scrollback_bytes();
        assert_eq!(total_before, 0);
        let trimmed = reg.trim_scrollback_to_budget();
        assert_eq!(trimmed, 0);
    }

    #[test]
    fn test_resource_info_empty_registry() {
        let reg = TerminalRegistry::new();
        let info = reg.resource_info();
        assert_eq!(info.total_terminal_count, 0);
        assert_eq!(info.total_scrollback_bytes, 0);
        assert_eq!(info.budget_used_percent, 0);
        assert_eq!(info.global_budget_bytes, GLOBAL_SCROLLBACK_BUDGET_BYTES);
        assert!(info.per_workspace.is_empty());
    }

    // CHK-003: 空闲终端回收
    #[test]
    fn test_reclaim_idle_returns_empty_for_empty_registry() {
        let mut reg = TerminalRegistry::new();
        let reclaimed = reg.reclaim_idle(Duration::from_secs(0));
        assert!(reclaimed.is_empty());
    }

    #[test]
    fn test_scrollback_limited_single_chunk_exact_boundary() {
        let mut buf = ScrollbackBuffer::new(1024);
        buf.push(b"abcdefghij".to_vec());
        let snap = buf.snapshot_limited(5);
        assert_eq!(&snap, b"fghij");
    }

    #[test]
    fn test_align_to_utf8_start_with_ascii() {
        let data = b"hello".to_vec();
        let result = align_to_utf8_start(data.clone());
        assert_eq!(result, data);
    }

    #[test]
    fn test_align_to_utf8_start_skips_continuation_bytes() {
        // 0x80-0xBF 是续字节，应该被跳过
        let data = vec![0x80, 0x80, b'h', b'i'];
        let result = align_to_utf8_start(data);
        assert_eq!(result, b"hi");
    }

    #[test]
    fn test_pty_flow_gate_subscriber_count() {
        let gate = PtyFlowGate::new();
        assert_eq!(gate.subscriber_count(), 0);
        gate.add_subscriber();
        assert_eq!(gate.subscriber_count(), 1);
        gate.add_subscriber();
        assert_eq!(gate.subscriber_count(), 2);
        gate.remove_subscriber();
        assert_eq!(gate.subscriber_count(), 1);
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
