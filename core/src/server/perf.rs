use std::sync::{
    atomic::{AtomicU64, Ordering},
    OnceLock,
};

use tracing::info;

/// `ws_task_broadcast_lag_total`
static WS_TASK_BROADCAST_LAG_TOTAL: AtomicU64 = AtomicU64::new(0);
/// `ws_task_broadcast_queue_depth`
static WS_TASK_BROADCAST_QUEUE_DEPTH: AtomicU64 = AtomicU64::new(0);
static WS_TASK_BROADCAST_QUEUE_DEPTH_SAMPLE_COUNT: AtomicU64 = AtomicU64::new(0);
/// `ws_task_broadcast_skipped_single_receiver_total`
static WS_TASK_BROADCAST_SKIPPED_SINGLE_RECEIVER_TOTAL: AtomicU64 = AtomicU64::new(0);
/// `ws_task_broadcast_skipped_empty_target_total`
static WS_TASK_BROADCAST_SKIPPED_EMPTY_TARGET_TOTAL: AtomicU64 = AtomicU64::new(0);
/// `ws_task_broadcast_filtered_target_total`
static WS_TASK_BROADCAST_FILTERED_TARGET_TOTAL: AtomicU64 = AtomicU64::new(0);
/// `terminal_unacked_timeout_total`
static TERMINAL_UNACKED_TIMEOUT_TOTAL: AtomicU64 = AtomicU64::new(0);
/// `project_command_output_throttled_total`
static PROJECT_COMMAND_OUTPUT_THROTTLED_TOTAL: AtomicU64 = AtomicU64::new(0);
/// `project_command_output_emitted_total`
static PROJECT_COMMAND_OUTPUT_EMITTED_TOTAL: AtomicU64 = AtomicU64::new(0);
/// `ws_outbound_loop_tick_ms`（最近一次采样）
static WS_OUTBOUND_LOOP_TICK_MS: AtomicU64 = AtomicU64::new(0);
static WS_OUTBOUND_LOOP_TICK_COUNT: AtomicU64 = AtomicU64::new(0);
static WS_OUTBOUND_LOOP_TICK_MAX_MS: AtomicU64 = AtomicU64::new(0);
/// `ws_outbound_select_wait_ms`（最近一次采样）
static WS_OUTBOUND_SELECT_WAIT_MS: AtomicU64 = AtomicU64::new(0);
static WS_OUTBOUND_SELECT_WAIT_COUNT: AtomicU64 = AtomicU64::new(0);
static WS_OUTBOUND_SELECT_WAIT_MAX_MS: AtomicU64 = AtomicU64::new(0);
/// `ws_outbound_handle_ms`（最近一次采样）
static WS_OUTBOUND_HANDLE_MS: AtomicU64 = AtomicU64::new(0);
static WS_OUTBOUND_HANDLE_COUNT: AtomicU64 = AtomicU64::new(0);
static WS_OUTBOUND_HANDLE_MAX_MS: AtomicU64 = AtomicU64::new(0);
/// `ws_decode_ms`
static WS_DECODE_MS: AtomicU64 = AtomicU64::new(0);
static WS_DECODE_COUNT: AtomicU64 = AtomicU64::new(0);
static WS_DECODE_MAX_MS: AtomicU64 = AtomicU64::new(0);
/// `ws_dispatch_ms`
static WS_DISPATCH_MS: AtomicU64 = AtomicU64::new(0);
static WS_DISPATCH_COUNT: AtomicU64 = AtomicU64::new(0);
static WS_DISPATCH_MAX_MS: AtomicU64 = AtomicU64::new(0);
/// `ws_encode_ms`
static WS_ENCODE_MS: AtomicU64 = AtomicU64::new(0);
static WS_ENCODE_COUNT: AtomicU64 = AtomicU64::new(0);
static WS_ENCODE_MAX_MS: AtomicU64 = AtomicU64::new(0);
/// `ws_outbound_queue_depth`
static WS_OUTBOUND_QUEUE_DEPTH: AtomicU64 = AtomicU64::new(0);
/// `ws_batch_flush_size`
static WS_BATCH_FLUSH_SIZE: AtomicU64 = AtomicU64::new(0);
static WS_BATCH_FLUSH_COUNT: AtomicU64 = AtomicU64::new(0);
/// `ai_subscriber_fanout`
static AI_SUBSCRIBER_FANOUT: AtomicU64 = AtomicU64::new(0);
static AI_SUBSCRIBER_FANOUT_MAX: AtomicU64 = AtomicU64::new(0);
/// `evolution_cycle_update_emitted_total`
static EVOLUTION_CYCLE_UPDATE_EMITTED_TOTAL: AtomicU64 = AtomicU64::new(0);
/// `evolution_cycle_update_debounced_total`
static EVOLUTION_CYCLE_UPDATE_DEBOUNCED_TOTAL: AtomicU64 = AtomicU64::new(0);
/// `evolution_snapshot_fallback_total`
static EVOLUTION_SNAPSHOT_FALLBACK_TOTAL: AtomicU64 = AtomicU64::new(0);
/// `terminal_reclaimed_total`：空闲/退出终端被自动回收的次数
static TERMINAL_RECLAIMED_TOTAL: AtomicU64 = AtomicU64::new(0);
/// `terminal_scrollback_trim_total`：因全局预算压力触发 scrollback 裁剪的次数（以终端数计）
static TERMINAL_SCROLLBACK_TRIM_TOTAL: AtomicU64 = AtomicU64::new(0);

const PERF_LOG_INTERVAL: u64 = 200;

fn perf_logging_enabled() -> bool {
    static PERF_LOG_ENABLED: OnceLock<bool> = OnceLock::new();
    *PERF_LOG_ENABLED.get_or_init(|| {
        matches!(
            std::env::var("TIDYFLOW_PERF_LOG")
                .ok()
                .as_deref()
                .map(str::to_ascii_lowercase)
                .as_deref(),
            Some("1") | Some("true") | Some("yes") | Some("on")
        )
    })
}

pub fn record_task_broadcast_lag(lagged: u64) {
    let total = WS_TASK_BROADCAST_LAG_TOTAL.fetch_add(lagged, Ordering::Relaxed) + lagged;
    WS_TASK_BROADCAST_QUEUE_DEPTH.store(lagged, Ordering::Relaxed);

    if perf_logging_enabled() && total % PERF_LOG_INTERVAL == 0 {
        info!(
            "perf ws_task_broadcast_lag_total={} ws_task_broadcast_queue_depth={}",
            total, lagged
        );
    }
}

pub fn record_task_broadcast_queue_depth(depth: u64) {
    WS_TASK_BROADCAST_QUEUE_DEPTH.store(depth, Ordering::Relaxed);
    let sample_count =
        WS_TASK_BROADCAST_QUEUE_DEPTH_SAMPLE_COUNT.fetch_add(1, Ordering::Relaxed) + 1;
    if perf_logging_enabled() && sample_count % PERF_LOG_INTERVAL == 0 {
        info!("perf ws_task_broadcast_queue_depth={}", depth);
    }
}

pub fn record_task_broadcast_skipped_single_receiver() {
    let total = WS_TASK_BROADCAST_SKIPPED_SINGLE_RECEIVER_TOTAL.fetch_add(1, Ordering::Relaxed) + 1;
    if perf_logging_enabled() && total % PERF_LOG_INTERVAL == 0 {
        info!(
            "perf ws_task_broadcast_skipped_single_receiver_total={}",
            total
        );
    }
}

pub fn record_task_broadcast_skipped_empty_target() {
    let total = WS_TASK_BROADCAST_SKIPPED_EMPTY_TARGET_TOTAL.fetch_add(1, Ordering::Relaxed) + 1;
    if perf_logging_enabled() && total % PERF_LOG_INTERVAL == 0 {
        info!(
            "perf ws_task_broadcast_skipped_empty_target_total={}",
            total
        );
    }
}

pub fn record_task_broadcast_filtered_target() {
    let total = WS_TASK_BROADCAST_FILTERED_TARGET_TOTAL.fetch_add(1, Ordering::Relaxed) + 1;
    if perf_logging_enabled() && total % PERF_LOG_INTERVAL == 0 {
        info!("perf ws_task_broadcast_filtered_target_total={}", total);
    }
}

pub fn record_terminal_unacked_timeout(term_id: &str, unacked_before_decay: u64) {
    let total = TERMINAL_UNACKED_TIMEOUT_TOTAL.fetch_add(1, Ordering::Relaxed) + 1;

    if perf_logging_enabled() && total % 20 == 0 {
        info!(
            "perf terminal_unacked_timeout_total={} term_id={} unacked_before_decay={}",
            total, term_id, unacked_before_decay
        );
    }
}

pub fn record_project_command_output_throttled(dropped: u64) {
    if dropped == 0 {
        return;
    }
    let total =
        PROJECT_COMMAND_OUTPUT_THROTTLED_TOTAL.fetch_add(dropped, Ordering::Relaxed) + dropped;
    if perf_logging_enabled() && total % PERF_LOG_INTERVAL == 0 {
        info!("perf project_command_output_throttled_total={}", total);
    }
}

pub fn record_project_command_output_emitted() {
    let total = PROJECT_COMMAND_OUTPUT_EMITTED_TOTAL.fetch_add(1, Ordering::Relaxed) + 1;
    if perf_logging_enabled() && total % PERF_LOG_INTERVAL == 0 {
        info!("perf project_command_output_emitted_total={}", total);
    }
}

fn update_max(target: &AtomicU64, value: u64) {
    let mut prev_max = target.load(Ordering::Relaxed);
    while value > prev_max
        && target
            .compare_exchange(prev_max, value, Ordering::Relaxed, Ordering::Relaxed)
            .is_err()
    {
        prev_max = target.load(Ordering::Relaxed);
    }
}

pub fn record_ws_outbound_select_wait(ms: u64) {
    WS_OUTBOUND_SELECT_WAIT_MS.store(ms, Ordering::Relaxed);
    WS_OUTBOUND_SELECT_WAIT_COUNT.fetch_add(1, Ordering::Relaxed);
    update_max(&WS_OUTBOUND_SELECT_WAIT_MAX_MS, ms);
}

pub fn record_ws_outbound_handle(ms: u64) {
    WS_OUTBOUND_HANDLE_MS.store(ms, Ordering::Relaxed);
    WS_OUTBOUND_HANDLE_COUNT.fetch_add(1, Ordering::Relaxed);
    update_max(&WS_OUTBOUND_HANDLE_MAX_MS, ms);
}

pub fn record_ws_outbound_loop_tick(ms: u64) {
    WS_OUTBOUND_LOOP_TICK_MS.store(ms, Ordering::Relaxed);
    let count = WS_OUTBOUND_LOOP_TICK_COUNT.fetch_add(1, Ordering::Relaxed) + 1;
    update_max(&WS_OUTBOUND_LOOP_TICK_MAX_MS, ms);

    if perf_logging_enabled() && count % PERF_LOG_INTERVAL == 0 {
        let max_ms = WS_OUTBOUND_LOOP_TICK_MAX_MS.load(Ordering::Relaxed);
        let select_wait_ms = WS_OUTBOUND_SELECT_WAIT_MS.load(Ordering::Relaxed);
        let select_wait_max_ms = WS_OUTBOUND_SELECT_WAIT_MAX_MS.load(Ordering::Relaxed);
        let select_wait_count = WS_OUTBOUND_SELECT_WAIT_COUNT.load(Ordering::Relaxed);
        let handle_ms = WS_OUTBOUND_HANDLE_MS.load(Ordering::Relaxed);
        let handle_max_ms = WS_OUTBOUND_HANDLE_MAX_MS.load(Ordering::Relaxed);
        let handle_count = WS_OUTBOUND_HANDLE_COUNT.load(Ordering::Relaxed);
        let decode_ms = WS_DECODE_MS.load(Ordering::Relaxed);
        let decode_max_ms = WS_DECODE_MAX_MS.load(Ordering::Relaxed);
        let decode_count = WS_DECODE_COUNT.load(Ordering::Relaxed);
        let dispatch_ms = WS_DISPATCH_MS.load(Ordering::Relaxed);
        let dispatch_max_ms = WS_DISPATCH_MAX_MS.load(Ordering::Relaxed);
        let dispatch_count = WS_DISPATCH_COUNT.load(Ordering::Relaxed);
        let encode_ms = WS_ENCODE_MS.load(Ordering::Relaxed);
        let encode_max_ms = WS_ENCODE_MAX_MS.load(Ordering::Relaxed);
        let encode_count = WS_ENCODE_COUNT.load(Ordering::Relaxed);
        let outbound_queue_depth = WS_OUTBOUND_QUEUE_DEPTH.load(Ordering::Relaxed);
        let batch_flush_size = WS_BATCH_FLUSH_SIZE.load(Ordering::Relaxed);
        let batch_flush_count = WS_BATCH_FLUSH_COUNT.load(Ordering::Relaxed);
        let ai_subscriber_fanout = AI_SUBSCRIBER_FANOUT.load(Ordering::Relaxed);
        let ai_subscriber_fanout_max = AI_SUBSCRIBER_FANOUT_MAX.load(Ordering::Relaxed);
        info!(
            "perf ws_outbound_loop_tick_ms={} ws_outbound_loop_tick_max_ms={} ws_outbound_loop_tick_count={} ws_outbound_select_wait_ms={} ws_outbound_select_wait_max_ms={} ws_outbound_select_wait_count={} ws_outbound_handle_ms={} ws_outbound_handle_max_ms={} ws_outbound_handle_count={} ws_decode_ms={} ws_decode_max_ms={} ws_decode_count={} ws_dispatch_ms={} ws_dispatch_max_ms={} ws_dispatch_count={} ws_encode_ms={} ws_encode_max_ms={} ws_encode_count={} ws_outbound_queue_depth={} ws_batch_flush_size={} ws_batch_flush_count={} ai_subscriber_fanout={} ai_subscriber_fanout_max={}",
            ms,
            max_ms,
            count,
            select_wait_ms,
            select_wait_max_ms,
            select_wait_count,
            handle_ms,
            handle_max_ms,
            handle_count,
            decode_ms,
            decode_max_ms,
            decode_count,
            dispatch_ms,
            dispatch_max_ms,
            dispatch_count,
            encode_ms,
            encode_max_ms,
            encode_count,
            outbound_queue_depth,
            batch_flush_size,
            batch_flush_count,
            ai_subscriber_fanout,
            ai_subscriber_fanout_max
        );
    }
}

pub fn record_ws_decode_ms(ms: u64) {
    WS_DECODE_MS.store(ms, Ordering::Relaxed);
    WS_DECODE_COUNT.fetch_add(1, Ordering::Relaxed);
    update_max(&WS_DECODE_MAX_MS, ms);
}

pub fn record_ws_dispatch_ms(ms: u64) {
    WS_DISPATCH_MS.store(ms, Ordering::Relaxed);
    WS_DISPATCH_COUNT.fetch_add(1, Ordering::Relaxed);
    update_max(&WS_DISPATCH_MAX_MS, ms);
}

pub fn record_ws_encode_ms(ms: u64) {
    WS_ENCODE_MS.store(ms, Ordering::Relaxed);
    WS_ENCODE_COUNT.fetch_add(1, Ordering::Relaxed);
    update_max(&WS_ENCODE_MAX_MS, ms);
}

pub fn record_ws_outbound_queue_depth(depth: u64) {
    WS_OUTBOUND_QUEUE_DEPTH.store(depth, Ordering::Relaxed);
}

pub fn record_ws_batch_flush(size: usize, reason: &str) {
    WS_BATCH_FLUSH_SIZE.store(size as u64, Ordering::Relaxed);
    let count = WS_BATCH_FLUSH_COUNT.fetch_add(1, Ordering::Relaxed) + 1;
    if perf_logging_enabled() && count % PERF_LOG_INTERVAL == 0 {
        info!(
            "perf ws_batch_flush_size={} ws_batch_flush_reason={}",
            size, reason
        );
    }
}

pub fn record_ai_subscriber_fanout(count: usize) {
    AI_SUBSCRIBER_FANOUT.store(count as u64, Ordering::Relaxed);
    update_max(&AI_SUBSCRIBER_FANOUT_MAX, count as u64);
}

pub fn record_evolution_cycle_update_emitted() {
    let total = EVOLUTION_CYCLE_UPDATE_EMITTED_TOTAL.fetch_add(1, Ordering::Relaxed) + 1;
    if perf_logging_enabled() && total % PERF_LOG_INTERVAL == 0 {
        info!("perf evolution_cycle_update_emitted_total={}", total);
    }
}

pub fn record_evolution_cycle_update_debounced() {
    let total = EVOLUTION_CYCLE_UPDATE_DEBOUNCED_TOTAL.fetch_add(1, Ordering::Relaxed) + 1;
    if perf_logging_enabled() && total % PERF_LOG_INTERVAL == 0 {
        info!("perf evolution_cycle_update_debounced_total={}", total);
    }
}

pub fn record_evolution_snapshot_fallback() {
    let total = EVOLUTION_SNAPSHOT_FALLBACK_TOTAL.fetch_add(1, Ordering::Relaxed) + 1;
    if perf_logging_enabled() && total % PERF_LOG_INTERVAL == 0 {
        info!("perf evolution_snapshot_fallback_total={}", total);
    }
}

/// 记录空闲/退出终端被自动回收（`count` 为本次回收的终端数量）
pub fn record_terminal_reclaimed(count: u64) {
    let total = TERMINAL_RECLAIMED_TOTAL.fetch_add(count, Ordering::Relaxed) + count;
    if perf_logging_enabled() {
        info!(
            "perf terminal_reclaimed_total={} this_batch={}",
            total, count
        );
    }
}

/// 记录因全局预算压力触发 scrollback 裁剪（`count` 为被裁剪的终端数量）
pub fn record_terminal_scrollback_trim(count: u64) {
    let total = TERMINAL_SCROLLBACK_TRIM_TOTAL.fetch_add(count, Ordering::Relaxed) + count;
    if perf_logging_enabled() {
        info!(
            "perf terminal_scrollback_trim_total={} this_batch={}",
            total, count
        );
    }
}

/// 终端性能指标快照
#[derive(Debug, Clone)]
pub struct TerminalPerfSnapshot {
    pub reclaimed_total: u64,
    pub scrollback_trim_total: u64,
}

/// 读取终端相关的性能计数器快照
pub fn snapshot_terminal_perf() -> TerminalPerfSnapshot {
    TerminalPerfSnapshot {
        reclaimed_total: TERMINAL_RECLAIMED_TOTAL.load(Ordering::Relaxed),
        scrollback_trim_total: TERMINAL_SCROLLBACK_TRIM_TOTAL.load(Ordering::Relaxed),
    }
}

// ============================================================================
// 统一性能指标快照（供 system_snapshot 可观测性输出）
// ============================================================================

use serde::Serialize;

/// WS 管线阶段的延迟与吞吐指标
#[derive(Debug, Clone, Serialize, Default)]
pub struct WsPipelineMetrics {
    pub last_ms: u64,
    pub max_ms: u64,
    pub count: u64,
}

/// 统一性能指标快照——将分散的 AtomicU64 计数器收敛为单一可序列化结构，
/// 供 `system_snapshot` 在协议 v8 下输出，避免多个 handler 各自拼装相似字段。
#[derive(Debug, Clone, Serialize)]
pub struct PerfMetricsSnapshot {
    // -- 广播相关 --
    pub ws_task_broadcast_lag_total: u64,
    pub ws_task_broadcast_queue_depth: u64,
    pub ws_task_broadcast_skipped_single_receiver_total: u64,
    pub ws_task_broadcast_skipped_empty_target_total: u64,
    pub ws_task_broadcast_filtered_target_total: u64,
    // -- 终端相关 --
    pub terminal_unacked_timeout_total: u64,
    pub terminal_reclaimed_total: u64,
    pub terminal_scrollback_trim_total: u64,
    // -- 项目命令输出 --
    pub project_command_output_throttled_total: u64,
    pub project_command_output_emitted_total: u64,
    // -- WS 管线延迟 --
    pub ws_outbound_loop_tick: WsPipelineMetrics,
    pub ws_outbound_select_wait: WsPipelineMetrics,
    pub ws_outbound_handle: WsPipelineMetrics,
    pub ws_decode: WsPipelineMetrics,
    pub ws_dispatch: WsPipelineMetrics,
    pub ws_encode: WsPipelineMetrics,
    // -- WS 队列 --
    pub ws_outbound_queue_depth: u64,
    pub ws_batch_flush_size: u64,
    pub ws_batch_flush_count: u64,
    // -- AI --
    pub ai_subscriber_fanout: u64,
    pub ai_subscriber_fanout_max: u64,
    // -- Evolution --
    pub evolution_cycle_update_emitted_total: u64,
    pub evolution_cycle_update_debounced_total: u64,
    pub evolution_snapshot_fallback_total: u64,
}

/// 读取所有性能计数器的统一快照
pub fn snapshot_perf_metrics() -> PerfMetricsSnapshot {
    PerfMetricsSnapshot {
        ws_task_broadcast_lag_total: WS_TASK_BROADCAST_LAG_TOTAL.load(Ordering::Relaxed),
        ws_task_broadcast_queue_depth: WS_TASK_BROADCAST_QUEUE_DEPTH.load(Ordering::Relaxed),
        ws_task_broadcast_skipped_single_receiver_total: WS_TASK_BROADCAST_SKIPPED_SINGLE_RECEIVER_TOTAL.load(Ordering::Relaxed),
        ws_task_broadcast_skipped_empty_target_total: WS_TASK_BROADCAST_SKIPPED_EMPTY_TARGET_TOTAL.load(Ordering::Relaxed),
        ws_task_broadcast_filtered_target_total: WS_TASK_BROADCAST_FILTERED_TARGET_TOTAL.load(Ordering::Relaxed),
        terminal_unacked_timeout_total: TERMINAL_UNACKED_TIMEOUT_TOTAL.load(Ordering::Relaxed),
        terminal_reclaimed_total: TERMINAL_RECLAIMED_TOTAL.load(Ordering::Relaxed),
        terminal_scrollback_trim_total: TERMINAL_SCROLLBACK_TRIM_TOTAL.load(Ordering::Relaxed),
        project_command_output_throttled_total: PROJECT_COMMAND_OUTPUT_THROTTLED_TOTAL.load(Ordering::Relaxed),
        project_command_output_emitted_total: PROJECT_COMMAND_OUTPUT_EMITTED_TOTAL.load(Ordering::Relaxed),
        ws_outbound_loop_tick: WsPipelineMetrics {
            last_ms: WS_OUTBOUND_LOOP_TICK_MS.load(Ordering::Relaxed),
            max_ms: WS_OUTBOUND_LOOP_TICK_MAX_MS.load(Ordering::Relaxed),
            count: WS_OUTBOUND_LOOP_TICK_COUNT.load(Ordering::Relaxed),
        },
        ws_outbound_select_wait: WsPipelineMetrics {
            last_ms: WS_OUTBOUND_SELECT_WAIT_MS.load(Ordering::Relaxed),
            max_ms: WS_OUTBOUND_SELECT_WAIT_MAX_MS.load(Ordering::Relaxed),
            count: WS_OUTBOUND_SELECT_WAIT_COUNT.load(Ordering::Relaxed),
        },
        ws_outbound_handle: WsPipelineMetrics {
            last_ms: WS_OUTBOUND_HANDLE_MS.load(Ordering::Relaxed),
            max_ms: WS_OUTBOUND_HANDLE_MAX_MS.load(Ordering::Relaxed),
            count: WS_OUTBOUND_HANDLE_COUNT.load(Ordering::Relaxed),
        },
        ws_decode: WsPipelineMetrics {
            last_ms: WS_DECODE_MS.load(Ordering::Relaxed),
            max_ms: WS_DECODE_MAX_MS.load(Ordering::Relaxed),
            count: WS_DECODE_COUNT.load(Ordering::Relaxed),
        },
        ws_dispatch: WsPipelineMetrics {
            last_ms: WS_DISPATCH_MS.load(Ordering::Relaxed),
            max_ms: WS_DISPATCH_MAX_MS.load(Ordering::Relaxed),
            count: WS_DISPATCH_COUNT.load(Ordering::Relaxed),
        },
        ws_encode: WsPipelineMetrics {
            last_ms: WS_ENCODE_MS.load(Ordering::Relaxed),
            max_ms: WS_ENCODE_MAX_MS.load(Ordering::Relaxed),
            count: WS_ENCODE_COUNT.load(Ordering::Relaxed),
        },
        ws_outbound_queue_depth: WS_OUTBOUND_QUEUE_DEPTH.load(Ordering::Relaxed),
        ws_batch_flush_size: WS_BATCH_FLUSH_SIZE.load(Ordering::Relaxed),
        ws_batch_flush_count: WS_BATCH_FLUSH_COUNT.load(Ordering::Relaxed),
        ai_subscriber_fanout: AI_SUBSCRIBER_FANOUT.load(Ordering::Relaxed),
        ai_subscriber_fanout_max: AI_SUBSCRIBER_FANOUT_MAX.load(Ordering::Relaxed),
        evolution_cycle_update_emitted_total: EVOLUTION_CYCLE_UPDATE_EMITTED_TOTAL.load(Ordering::Relaxed),
        evolution_cycle_update_debounced_total: EVOLUTION_CYCLE_UPDATE_DEBOUNCED_TOTAL.load(Ordering::Relaxed),
        evolution_snapshot_fallback_total: EVOLUTION_SNAPSHOT_FALLBACK_TOTAL.load(Ordering::Relaxed),
    }
}

// ============================================================================
// 历史观测聚合与预测评分（v1.44: 按 (project, workspace) 隔离）
// ============================================================================

use crate::server::protocol::health::{
    ObservationAggregate, PredictiveAnomaly, PredictiveAnomalyKind, PredictionConfidence,
    PredictionTimeWindow, ResourcePressureLevel, SchedulingRecommendation,
    SchedulingRecommendationKind,
};
use crate::server::protocol::health::HealthContext;
use std::collections::HashMap;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

fn unix_ms_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis() as u64
}

/// 单个工作区的循环运行记录（用于聚合输入）
#[derive(Debug, Clone)]
pub struct WorkspaceCycleRecord {
    pub project: String,
    pub workspace: String,
    pub cycle_id: String,
    pub success: bool,
    pub duration_ms: Option<u64>,
    pub rate_limit_hit: bool,
    pub timestamp: u64,
}

/// 按 (project, workspace) 隔离的历史观测累加器
///
/// 在内存中聚合，由 health snapshot 生成时消费，
/// 异常中断恢复后从零开始重建（不会把不同项目同名工作区混到一起）。
#[derive(Debug, Clone, Default)]
pub struct WorkspaceObservationAccumulator {
    pub cycle_success_count: u32,
    pub cycle_failure_count: u32,
    pub cycle_durations: Vec<u64>,
    pub consecutive_failures: u32,
    pub rate_limit_hit_count: u32,
    pub first_record_at: Option<u64>,
    pub last_record_at: Option<u64>,
}

impl WorkspaceObservationAccumulator {
    /// 记录一次循环结果
    pub fn record_cycle(&mut self, success: bool, duration_ms: Option<u64>, rate_limit_hit: bool, timestamp: u64) {
        if success {
            self.cycle_success_count += 1;
            self.consecutive_failures = 0;
        } else {
            self.cycle_failure_count += 1;
            self.consecutive_failures += 1;
        }
        if let Some(d) = duration_ms {
            self.cycle_durations.push(d);
        }
        if rate_limit_hit {
            self.rate_limit_hit_count += 1;
        }
        if self.first_record_at.is_none() {
            self.first_record_at = Some(timestamp);
        }
        self.last_record_at = Some(timestamp);
    }

    /// 计算平均循环耗时
    fn avg_duration_ms(&self) -> Option<u64> {
        if self.cycle_durations.is_empty() {
            return None;
        }
        let sum: u64 = self.cycle_durations.iter().sum();
        Some(sum / self.cycle_durations.len() as u64)
    }

    /// 最后一次循环耗时
    fn last_duration_ms(&self) -> Option<u64> {
        self.cycle_durations.last().copied()
    }
}

/// 全局观测历史仓库（按 (project, workspace) 隔离）
static OBSERVATION_STORE: std::sync::OnceLock<
    std::sync::Mutex<HashMap<(String, String), WorkspaceObservationAccumulator>>,
> = std::sync::OnceLock::new();

fn observation_store() -> &'static std::sync::Mutex<HashMap<(String, String), WorkspaceObservationAccumulator>> {
    OBSERVATION_STORE.get_or_init(|| std::sync::Mutex::new(HashMap::new()))
}

/// 记录一次工作区循环结果到观测历史
pub fn record_workspace_cycle(record: WorkspaceCycleRecord) {
    if let Ok(mut store) = observation_store().lock() {
        let key = (record.project.clone(), record.workspace.clone());
        let acc = store.entry(key).or_default();
        acc.record_cycle(record.success, record.duration_ms, record.rate_limit_hit, record.timestamp);
    }
}

/// 生成所有工作区的观测聚合摘要
pub fn build_observation_aggregates(
    cache_hit_ratios: &HashMap<(String, String), f64>,
) -> Vec<ObservationAggregate> {
    let now = unix_ms_now();
    let store = match observation_store().lock() {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };

    store
        .iter()
        .map(|((project, workspace), acc)| {
            let cache_hit_ratio = cache_hit_ratios.get(&(project.clone(), workspace.clone())).copied();
            let pressure_level = compute_pressure_level(acc, cache_hit_ratio);
            let health_score = compute_health_score(acc, cache_hit_ratio);

            ObservationAggregate {
                project: project.clone(),
                workspace: workspace.clone(),
                window_start: acc.first_record_at.unwrap_or(now),
                window_end: acc.last_record_at.unwrap_or(now),
                cycle_success_count: acc.cycle_success_count,
                cycle_failure_count: acc.cycle_failure_count,
                avg_cycle_duration_ms: acc.avg_duration_ms(),
                last_cycle_duration_ms: acc.last_duration_ms(),
                consecutive_failures: acc.consecutive_failures,
                cache_hit_ratio,
                rate_limit_hit_count: acc.rate_limit_hit_count,
                pressure_level,
                health_score,
                aggregated_at: now,
            }
        })
        .collect()
}

/// 根据历史聚合生成预测异常
pub fn build_predictive_anomalies(
    aggregates: &[ObservationAggregate],
) -> Vec<PredictiveAnomaly> {
    let now = unix_ms_now();
    let one_hour_ms = 3_600_000u64;
    let mut anomalies = Vec::new();

    for agg in aggregates {
        // 重复失败模式检测：连续失败 >= 2 次
        if agg.consecutive_failures >= 2 {
            let score = (agg.consecutive_failures as f64 * 0.25).min(1.0);
            let confidence = if agg.consecutive_failures >= 5 {
                PredictionConfidence::High
            } else if agg.consecutive_failures >= 3 {
                PredictionConfidence::Medium
            } else {
                PredictionConfidence::Low
            };
            anomalies.push(PredictiveAnomaly {
                anomaly_id: format!("pred:recurring_failure:{}:{}", agg.project, agg.workspace),
                kind: PredictiveAnomalyKind::RecurringFailure,
                confidence,
                root_cause: "evolution_consecutive_failures".to_string(),
                summary: Some(format!(
                    "工作区 {}/{} 连续 {} 次循环失败",
                    agg.project, agg.workspace, agg.consecutive_failures
                )),
                time_window: PredictionTimeWindow {
                    start_at: now,
                    end_at: now + one_hour_ms,
                },
                related_incident_ids: Vec::new(),
                context: HealthContext::for_workspace(&agg.project, &agg.workspace),
                score,
                predicted_at: now,
            });
        }

        // 速率限制风险检测
        if agg.rate_limit_hit_count >= 3 {
            let score = (agg.rate_limit_hit_count as f64 * 0.2).min(1.0);
            anomalies.push(PredictiveAnomaly {
                anomaly_id: format!("pred:rate_limit_risk:{}:{}", agg.project, agg.workspace),
                kind: PredictiveAnomalyKind::RateLimitRisk,
                confidence: if agg.rate_limit_hit_count >= 5 {
                    PredictionConfidence::High
                } else {
                    PredictionConfidence::Medium
                },
                root_cause: "frequent_rate_limit_hits".to_string(),
                summary: Some(format!(
                    "工作区 {}/{} 已触发 {} 次速率限制",
                    agg.project, agg.workspace, agg.rate_limit_hit_count
                )),
                time_window: PredictionTimeWindow {
                    start_at: now,
                    end_at: now + one_hour_ms,
                },
                related_incident_ids: Vec::new(),
                context: HealthContext::for_workspace(&agg.project, &agg.workspace),
                score,
                predicted_at: now,
            });
        }

        // 缓存效率下降检测
        if let Some(ratio) = agg.cache_hit_ratio {
            if ratio < 0.5 && (agg.cycle_success_count + agg.cycle_failure_count) > 2 {
                anomalies.push(PredictiveAnomaly {
                    anomaly_id: format!("pred:cache_efficiency_drop:{}:{}", agg.project, agg.workspace),
                    kind: PredictiveAnomalyKind::CacheEfficiencyDrop,
                    confidence: if ratio < 0.3 {
                        PredictionConfidence::High
                    } else {
                        PredictionConfidence::Medium
                    },
                    root_cause: "low_cache_hit_ratio".to_string(),
                    summary: Some(format!(
                        "工作区 {}/{} 缓存命中率仅 {:.0}%",
                        agg.project, agg.workspace, ratio * 100.0
                    )),
                    time_window: PredictionTimeWindow {
                        start_at: now,
                        end_at: now + one_hour_ms,
                    },
                    related_incident_ids: Vec::new(),
                    context: HealthContext::for_workspace(&agg.project, &agg.workspace),
                    score: 1.0 - ratio,
                    predicted_at: now,
                });
            }
        }
    }

    // 全局性能退化检测（基于 WS 管线延迟）
    let dispatch_max_ms = WS_DISPATCH_MAX_MS.load(Ordering::Relaxed);
    if dispatch_max_ms > 500 {
        let score = ((dispatch_max_ms as f64 - 500.0) / 1000.0).min(1.0);
        anomalies.push(PredictiveAnomaly {
            anomaly_id: "pred:performance_degradation:system:ws_dispatch".to_string(),
            kind: PredictiveAnomalyKind::PerformanceDegradation,
            confidence: if dispatch_max_ms > 2000 {
                PredictionConfidence::High
            } else {
                PredictionConfidence::Medium
            },
            root_cause: "ws_dispatch_latency_high".to_string(),
            summary: Some(format!(
                "WS 分发最大延迟 {}ms，可能导致 UI 卡顿",
                dispatch_max_ms
            )),
            time_window: PredictionTimeWindow {
                start_at: now,
                end_at: now + one_hour_ms,
            },
            related_incident_ids: Vec::new(),
            context: HealthContext::system(),
            score,
            predicted_at: now,
        });
    }

    // 全局终端资源耗尽预警
    let trim_total = TERMINAL_SCROLLBACK_TRIM_TOTAL.load(Ordering::Relaxed);
    if trim_total > 5 {
        anomalies.push(PredictiveAnomaly {
            anomaly_id: "pred:resource_exhaustion:system:terminal_budget".to_string(),
            kind: PredictiveAnomalyKind::ResourceExhaustion,
            confidence: if trim_total > 20 {
                PredictionConfidence::High
            } else {
                PredictionConfidence::Medium
            },
            root_cause: "terminal_scrollback_budget_pressure".to_string(),
            summary: Some(format!(
                "终端 scrollback 已触发 {} 次全局预算裁剪，内存压力持续",
                trim_total
            )),
            time_window: PredictionTimeWindow {
                start_at: now,
                end_at: now + one_hour_ms,
            },
            related_incident_ids: Vec::new(),
            context: HealthContext::system(),
            score: (trim_total as f64 / 30.0).min(1.0),
            predicted_at: now,
        });
    }

    anomalies
}

/// 根据历史聚合和实时指标生成调度优化建议
pub fn build_scheduling_recommendations(
    aggregates: &[ObservationAggregate],
    current_max_parallel: u32,
    running_count: u32,
) -> Vec<SchedulingRecommendation> {
    let now = unix_ms_now();
    let one_hour_ms = 3_600_000u64;
    let mut recommendations = Vec::new();

    // 全局资源压力判断
    let dispatch_max = WS_DISPATCH_MAX_MS.load(Ordering::Relaxed);
    let queue_depth = WS_OUTBOUND_QUEUE_DEPTH.load(Ordering::Relaxed);
    let global_pressure = if dispatch_max > 1000 || queue_depth > 100 {
        ResourcePressureLevel::High
    } else if dispatch_max > 500 || queue_depth > 50 {
        ResourcePressureLevel::Moderate
    } else {
        ResourcePressureLevel::Low
    };

    // 高压时建议降低并发
    if global_pressure >= ResourcePressureLevel::High && running_count > 1 {
        let suggested = (current_max_parallel / 2).max(1);
        recommendations.push(SchedulingRecommendation {
            recommendation_id: format!("sched:reduce_concurrency:system:{}", now),
            kind: SchedulingRecommendationKind::ReduceConcurrency,
            pressure_level: global_pressure,
            reason: "ws_dispatch_latency_high".to_string(),
            summary: Some(format!(
                "WS 分发延迟 {}ms / 队列深度 {}，建议将并发从 {} 降至 {}",
                dispatch_max, queue_depth, current_max_parallel, suggested
            )),
            suggested_value: Some(suggested as i64),
            context: HealthContext::system(),
            generated_at: now,
            expires_at: now + one_hour_ms,
        });
    }

    // 低压且有排队时建议提高并发
    if global_pressure == ResourcePressureLevel::Low && running_count >= current_max_parallel && current_max_parallel < 8 {
        recommendations.push(SchedulingRecommendation {
            recommendation_id: format!("sched:increase_concurrency:system:{}", now),
            kind: SchedulingRecommendationKind::IncreaseConcurrency,
            pressure_level: global_pressure,
            reason: "resources_available_with_queue".to_string(),
            summary: Some(format!(
                "资源充裕，当前并发 {} 已满，建议提高至 {}",
                current_max_parallel, current_max_parallel + 1
            )),
            suggested_value: Some((current_max_parallel + 1) as i64),
            context: HealthContext::system(),
            generated_at: now,
            expires_at: now + one_hour_ms,
        });
    }

    // 工作区级别：连续失败过多建议降级
    for agg in aggregates {
        if agg.consecutive_failures >= 3 {
            recommendations.push(SchedulingRecommendation {
                recommendation_id: format!("sched:enable_degradation:{}:{}:{}", agg.project, agg.workspace, now),
                kind: SchedulingRecommendationKind::EnableDegradation,
                pressure_level: ResourcePressureLevel::High,
                reason: "consecutive_failures_threshold".to_string(),
                summary: Some(format!(
                    "工作区 {}/{} 连续 {} 次失败，建议暂停以释放资源",
                    agg.project, agg.workspace, agg.consecutive_failures
                )),
                suggested_value: None,
                context: HealthContext::for_workspace(&agg.project, &agg.workspace),
                generated_at: now,
                expires_at: now + one_hour_ms,
            });
        }

        // 速率限制频繁时建议延迟排队
        if agg.rate_limit_hit_count >= 3 {
            recommendations.push(SchedulingRecommendation {
                recommendation_id: format!("sched:defer_queuing:{}:{}:{}", agg.project, agg.workspace, now),
                kind: SchedulingRecommendationKind::DeferQueuing,
                pressure_level: ResourcePressureLevel::Moderate,
                reason: "rate_limit_frequency".to_string(),
                summary: Some(format!(
                    "工作区 {}/{} 频繁触发速率限制（{} 次），建议延迟排队间隔",
                    agg.project, agg.workspace, agg.rate_limit_hit_count
                )),
                suggested_value: None,
                context: HealthContext::for_workspace(&agg.project, &agg.workspace),
                generated_at: now,
                expires_at: now + one_hour_ms,
            });
        }
    }

    recommendations
}

/// 计算工作区资源压力级别
fn compute_pressure_level(
    acc: &WorkspaceObservationAccumulator,
    cache_hit_ratio: Option<f64>,
) -> ResourcePressureLevel {
    let mut score = 0u32;

    if acc.consecutive_failures >= 3 {
        score += 3;
    } else if acc.consecutive_failures >= 1 {
        score += 1;
    }

    if acc.rate_limit_hit_count >= 5 {
        score += 3;
    } else if acc.rate_limit_hit_count >= 2 {
        score += 1;
    }

    if let Some(ratio) = cache_hit_ratio {
        if ratio < 0.3 {
            score += 2;
        } else if ratio < 0.5 {
            score += 1;
        }
    }

    match score {
        0 => ResourcePressureLevel::Low,
        1..=2 => ResourcePressureLevel::Moderate,
        3..=5 => ResourcePressureLevel::High,
        _ => ResourcePressureLevel::Critical,
    }
}

/// 计算工作区综合健康评分（0.0-1.0）
fn compute_health_score(
    acc: &WorkspaceObservationAccumulator,
    cache_hit_ratio: Option<f64>,
) -> f64 {
    let total = acc.cycle_success_count + acc.cycle_failure_count;
    if total == 0 {
        return 1.0;
    }

    let success_ratio = acc.cycle_success_count as f64 / total as f64;
    let failure_penalty = (acc.consecutive_failures as f64 * 0.1).min(0.3);
    let rate_limit_penalty = (acc.rate_limit_hit_count as f64 * 0.05).min(0.2);
    let cache_bonus = cache_hit_ratio.unwrap_or(0.5) * 0.1;

    (success_ratio - failure_penalty - rate_limit_penalty + cache_bonus)
        .clamp(0.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_workspace_observation_accumulator_basic() {
        let mut acc = WorkspaceObservationAccumulator::default();
        acc.record_cycle(true, Some(1000), false, 100);
        acc.record_cycle(true, Some(2000), false, 200);
        acc.record_cycle(false, Some(500), true, 300);

        assert_eq!(acc.cycle_success_count, 2);
        assert_eq!(acc.cycle_failure_count, 1);
        assert_eq!(acc.consecutive_failures, 1);
        assert_eq!(acc.rate_limit_hit_count, 1);
        assert_eq!(acc.avg_duration_ms(), Some(1166)); // (1000+2000+500)/3
        assert_eq!(acc.last_duration_ms(), Some(500));
    }

    #[test]
    fn test_consecutive_failures_reset_on_success() {
        let mut acc = WorkspaceObservationAccumulator::default();
        acc.record_cycle(false, None, false, 100);
        acc.record_cycle(false, None, false, 200);
        assert_eq!(acc.consecutive_failures, 2);
        acc.record_cycle(true, None, false, 300);
        assert_eq!(acc.consecutive_failures, 0);
    }

    #[test]
    fn test_health_score_perfect() {
        let mut acc = WorkspaceObservationAccumulator::default();
        for i in 0..10 {
            acc.record_cycle(true, Some(1000), false, i * 100);
        }
        let score = compute_health_score(&acc, Some(0.9));
        assert!(score > 0.9, "expected high health score, got {}", score);
    }

    #[test]
    fn test_health_score_degraded() {
        let mut acc = WorkspaceObservationAccumulator::default();
        for i in 0..5 {
            acc.record_cycle(false, None, true, i * 100);
        }
        let score = compute_health_score(&acc, Some(0.2));
        assert!(score < 0.3, "expected low health score, got {}", score);
    }

    #[test]
    fn test_pressure_level_low() {
        let acc = WorkspaceObservationAccumulator::default();
        assert_eq!(compute_pressure_level(&acc, Some(0.9)), ResourcePressureLevel::Low);
    }

    #[test]
    fn test_pressure_level_critical() {
        let mut acc = WorkspaceObservationAccumulator::default();
        acc.consecutive_failures = 5;
        acc.rate_limit_hit_count = 10;
        assert_eq!(compute_pressure_level(&acc, Some(0.1)), ResourcePressureLevel::Critical);
    }

    #[test]
    fn test_predictive_anomalies_recurring_failure() {
        let agg = ObservationAggregate {
            project: "proj".to_string(),
            workspace: "ws".to_string(),
            window_start: 0,
            window_end: 1000,
            cycle_success_count: 1,
            cycle_failure_count: 3,
            avg_cycle_duration_ms: None,
            last_cycle_duration_ms: None,
            consecutive_failures: 3,
            cache_hit_ratio: None,
            rate_limit_hit_count: 0,
            pressure_level: ResourcePressureLevel::High,
            health_score: 0.3,
            aggregated_at: 1000,
        };
        let anomalies = build_predictive_anomalies(&[agg]);
        assert!(
            anomalies.iter().any(|a| a.kind == PredictiveAnomalyKind::RecurringFailure),
            "should detect recurring failure"
        );
    }
}
