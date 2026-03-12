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
        ws_task_broadcast_skipped_single_receiver_total:
            WS_TASK_BROADCAST_SKIPPED_SINGLE_RECEIVER_TOTAL.load(Ordering::Relaxed),
        ws_task_broadcast_skipped_empty_target_total: WS_TASK_BROADCAST_SKIPPED_EMPTY_TARGET_TOTAL
            .load(Ordering::Relaxed),
        ws_task_broadcast_filtered_target_total: WS_TASK_BROADCAST_FILTERED_TARGET_TOTAL
            .load(Ordering::Relaxed),
        terminal_unacked_timeout_total: TERMINAL_UNACKED_TIMEOUT_TOTAL.load(Ordering::Relaxed),
        terminal_reclaimed_total: TERMINAL_RECLAIMED_TOTAL.load(Ordering::Relaxed),
        terminal_scrollback_trim_total: TERMINAL_SCROLLBACK_TRIM_TOTAL.load(Ordering::Relaxed),
        project_command_output_throttled_total: PROJECT_COMMAND_OUTPUT_THROTTLED_TOTAL
            .load(Ordering::Relaxed),
        project_command_output_emitted_total: PROJECT_COMMAND_OUTPUT_EMITTED_TOTAL
            .load(Ordering::Relaxed),
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
        evolution_cycle_update_emitted_total: EVOLUTION_CYCLE_UPDATE_EMITTED_TOTAL
            .load(Ordering::Relaxed),
        evolution_cycle_update_debounced_total: EVOLUTION_CYCLE_UPDATE_DEBOUNCED_TOTAL
            .load(Ordering::Relaxed),
        evolution_snapshot_fallback_total: EVOLUTION_SNAPSHOT_FALLBACK_TOTAL
            .load(Ordering::Relaxed),
    }
}

// ============================================================================
// 历史观测聚合与预测评分（v1.44: 按 (project, workspace) 隔离）
// ============================================================================

use crate::server::protocol::health::HealthContext;
use crate::server::protocol::health::{
    AnalysisScopeLevel, BottleneckEntry, BottleneckKind, EvolutionAnalysisSummary, GateDecision,
    GateFailureReason, GateVerdict, ObservationAggregate, OptimizationSuggestion,
    PredictionConfidence, PredictionTimeWindow, PredictiveAnomaly, PredictiveAnomalyKind,
    ResourcePressureLevel, SchedulingRecommendation, SchedulingRecommendationKind,
};
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
    pub fn record_cycle(
        &mut self,
        success: bool,
        duration_ms: Option<u64>,
        rate_limit_hit: bool,
        timestamp: u64,
    ) {
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

fn observation_store(
) -> &'static std::sync::Mutex<HashMap<(String, String), WorkspaceObservationAccumulator>> {
    OBSERVATION_STORE.get_or_init(|| std::sync::Mutex::new(HashMap::new()))
}

/// 记录一次工作区循环结果到观测历史
pub fn record_workspace_cycle(record: WorkspaceCycleRecord) {
    if let Ok(mut store) = observation_store().lock() {
        let key = (record.project.clone(), record.workspace.clone());
        let acc = store.entry(key).or_default();
        acc.record_cycle(
            record.success,
            record.duration_ms,
            record.rate_limit_hit,
            record.timestamp,
        );
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
            let cache_hit_ratio = cache_hit_ratios
                .get(&(project.clone(), workspace.clone()))
                .copied();
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
pub fn build_predictive_anomalies(aggregates: &[ObservationAggregate]) -> Vec<PredictiveAnomaly> {
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
                    anomaly_id: format!(
                        "pred:cache_efficiency_drop:{}:{}",
                        agg.project, agg.workspace
                    ),
                    kind: PredictiveAnomalyKind::CacheEfficiencyDrop,
                    confidence: if ratio < 0.3 {
                        PredictionConfidence::High
                    } else {
                        PredictionConfidence::Medium
                    },
                    root_cause: "low_cache_hit_ratio".to_string(),
                    summary: Some(format!(
                        "工作区 {}/{} 缓存命中率仅 {:.0}%",
                        agg.project,
                        agg.workspace,
                        ratio * 100.0
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
    if global_pressure == ResourcePressureLevel::Low
        && running_count >= current_max_parallel
        && current_max_parallel < 8
    {
        recommendations.push(SchedulingRecommendation {
            recommendation_id: format!("sched:increase_concurrency:system:{}", now),
            kind: SchedulingRecommendationKind::IncreaseConcurrency,
            pressure_level: global_pressure,
            reason: "resources_available_with_queue".to_string(),
            summary: Some(format!(
                "资源充裕，当前并发 {} 已满，建议提高至 {}",
                current_max_parallel,
                current_max_parallel + 1
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
                recommendation_id: format!(
                    "sched:enable_degradation:{}:{}:{}",
                    agg.project, agg.workspace, now
                ),
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
                recommendation_id: format!(
                    "sched:defer_queuing:{}:{}:{}",
                    agg.project, agg.workspace, now
                ),
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

/// 瓶颈类型转字符串标识（用于瓶颈 ID 生成）
fn bottleneck_kind_to_str(kind: &BottleneckKind) -> &'static str {
    match kind {
        BottleneckKind::Resource => "resource",
        BottleneckKind::RateLimit => "rate_limit",
        BottleneckKind::RecurringFailure => "recurring_failure",
        BottleneckKind::PerformanceDegradation => "perf_degradation",
        BottleneckKind::Configuration => "configuration",
        BottleneckKind::ProtocolInconsistency => "protocol_inconsistency",
    }
}

/// 构建工作区级智能演化分析摘要
///
/// 聚合质量门禁裁决、观测聚合、预测异常和调度建议，
/// 输出按 `(project, workspace, cycle_id)` 隔离的统一分析结果。
pub fn build_analysis_summary(
    project: &str,
    workspace: &str,
    cycle_id: &str,
    gate_decision: Option<&GateDecision>,
    aggregates: &[ObservationAggregate],
    anomalies: &[PredictiveAnomaly],
    recommendations: &[SchedulingRecommendation],
) -> EvolutionAnalysisSummary {
    let now = unix_ms_now();
    let one_hour_ms = 3_600_000u64;

    // 查找当前工作区的观测聚合
    let workspace_agg = aggregates
        .iter()
        .find(|a| a.project == project && a.workspace == workspace);
    let health_score = workspace_agg.map(|a| a.health_score).unwrap_or(1.0);
    let pressure_level = workspace_agg
        .map(|a| a.pressure_level)
        .unwrap_or(ResourcePressureLevel::Low);

    // 收集瓶颈
    let mut bottlenecks = Vec::new();

    // 从预测异常生成瓶颈
    for anomaly in anomalies.iter().filter(|a| {
        a.context.project.as_deref() == Some(project)
            && a.context.workspace.as_deref() == Some(workspace)
    }) {
        let (kind, reason_code) = match anomaly.kind {
            PredictiveAnomalyKind::RecurringFailure => (
                BottleneckKind::RecurringFailure,
                "recurring_failure_detected",
            ),
            PredictiveAnomalyKind::RateLimitRisk => (BottleneckKind::RateLimit, "rate_limit_risk"),
            PredictiveAnomalyKind::PerformanceDegradation => (
                BottleneckKind::PerformanceDegradation,
                "performance_degradation_trend",
            ),
            PredictiveAnomalyKind::ResourceExhaustion => {
                (BottleneckKind::Resource, "resource_exhaustion_predicted")
            }
            PredictiveAnomalyKind::CacheEfficiencyDrop => {
                (BottleneckKind::Resource, "cache_efficiency_drop")
            }
        };
        bottlenecks.push(BottleneckEntry {
            bottleneck_id: format!(
                "bn:{}:{}:{}",
                bottleneck_kind_to_str(&kind),
                project,
                workspace
            ),
            kind,
            reason_code: reason_code.to_string(),
            risk_score: anomaly.score,
            evidence_summary: anomaly
                .summary
                .clone()
                .unwrap_or_else(|| anomaly.root_cause.clone()),
            context: anomaly.context.clone(),
            related_ids: std::iter::once(anomaly.anomaly_id.clone())
                .chain(anomaly.related_incident_ids.iter().cloned())
                .collect(),
            detected_at: anomaly.predicted_at,
        });
    }

    // 从门禁裁决生成瓶颈（如果失败）
    if let Some(gate) = gate_decision {
        if gate.verdict == GateVerdict::Fail {
            for reason in &gate.failure_reasons {
                let (kind, reason_code, summary): (BottleneckKind, &str, &str) = match reason {
                    GateFailureReason::SystemUnhealthy => (
                        BottleneckKind::Resource,
                        "system_unhealthy",
                        "系统健康状态为 Unhealthy，存在关键故障",
                    ),
                    GateFailureReason::CriticalIncident => (
                        BottleneckKind::Resource,
                        "critical_incident_blocking",
                        "存在阻断性 critical incident",
                    ),
                    GateFailureReason::EvidenceIncomplete => (
                        BottleneckKind::Configuration,
                        "evidence_incomplete",
                        "证据完整性校验失败",
                    ),
                    GateFailureReason::ProtocolInconsistent => (
                        BottleneckKind::ProtocolInconsistency,
                        "protocol_inconsistent",
                        "协议一致性检查失败",
                    ),
                    GateFailureReason::CoreRegressionFailed => (
                        BottleneckKind::RecurringFailure,
                        "core_regression_failed",
                        "Core 回归测试失败",
                    ),
                    GateFailureReason::AppleVerificationFailed => (
                        BottleneckKind::RecurringFailure,
                        "apple_verification_failed",
                        "Apple 构建或回归失败",
                    ),
                    GateFailureReason::Custom(msg) => (
                        BottleneckKind::Configuration,
                        "custom_gate_failure",
                        msg.as_str(),
                    ),
                };
                bottlenecks.push(BottleneckEntry {
                    bottleneck_id: format!("bn:gate:{}:{}:{}", reason_code, project, workspace),
                    kind,
                    reason_code: reason_code.to_string(),
                    risk_score: 0.9,
                    evidence_summary: summary.to_string(),
                    context: HealthContext {
                        project: Some(project.to_string()),
                        workspace: Some(workspace.to_string()),
                        session_id: None,
                        cycle_id: Some(cycle_id.to_string()),
                    },
                    related_ids: Vec::new(),
                    detected_at: gate.decided_at,
                });
            }
        }
    }

    // 从观测聚合生成瓶颈（高压力或低健康评分）
    if let Some(agg) = workspace_agg {
        if agg.pressure_level >= ResourcePressureLevel::High {
            bottlenecks.push(BottleneckEntry {
                bottleneck_id: format!("bn:pressure:{}:{}", project, workspace),
                kind: BottleneckKind::Resource,
                reason_code: "high_resource_pressure".to_string(),
                risk_score: if agg.pressure_level == ResourcePressureLevel::Critical {
                    0.95
                } else {
                    0.7
                },
                evidence_summary: format!(
                    "资源压力级别 {:?}，健康评分 {:.2}，连续失败 {} 次",
                    agg.pressure_level, agg.health_score, agg.consecutive_failures
                ),
                context: HealthContext {
                    project: Some(project.to_string()),
                    workspace: Some(workspace.to_string()),
                    session_id: None,
                    cycle_id: Some(cycle_id.to_string()),
                },
                related_ids: Vec::new(),
                detected_at: now,
            });
        }
    }

    // 综合风险评分：取所有瓶颈中最高风险
    let overall_risk_score = bottlenecks
        .iter()
        .map(|b| b.risk_score)
        .fold(0.0f64, f64::max);

    // 从调度建议构建优化建议
    let mut suggestions: Vec<OptimizationSuggestion> = Vec::new();
    for (i, rec) in recommendations.iter().enumerate() {
        let scope = if rec.context.project.is_some() {
            AnalysisScopeLevel::Workspace
        } else {
            AnalysisScopeLevel::System
        };
        suggestions.push(OptimizationSuggestion {
            suggestion_id: format!("sug:{}:{}", rec.recommendation_id, i),
            scope,
            action: format!("{:?}", rec.kind).to_ascii_lowercase(),
            summary: rec.summary.clone().unwrap_or_else(|| rec.reason.clone()),
            priority: (i as u32) + 1,
            expected_impact: rec.suggested_value.map(|v| format!("建议目标值: {}", v)),
            context: rec.context.clone(),
        });
    }

    // 关联预测异常 ID
    let predictive_anomaly_ids: Vec<String> = anomalies
        .iter()
        .filter(|a| {
            a.context.project.as_deref() == Some(project)
                && a.context.workspace.as_deref() == Some(workspace)
        })
        .map(|a| a.anomaly_id.clone())
        .collect();

    EvolutionAnalysisSummary {
        project: project.to_string(),
        workspace: workspace.to_string(),
        cycle_id: cycle_id.to_string(),
        gate_decision: gate_decision.cloned(),
        bottlenecks,
        overall_risk_score,
        health_score,
        pressure_level,
        predictive_anomaly_ids,
        suggestions,
        analyzed_at: now,
        expires_at: now + one_hour_ms,
    }
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

    (success_ratio - failure_penalty - rate_limit_penalty + cache_bonus).clamp(0.0, 1.0)
}

// ============================================================================
// 滚动延迟窗口（WI-002）
// ============================================================================

use crate::server::protocol::health::{
    ClientPerformanceReport, CoreRuntimeMemorySnapshot, LatencyMetricWindow, PerformanceDiagnosis,
    PerformanceDiagnosisReason, PerformanceDiagnosisScope, PerformanceDiagnosisSeverity,
    PerformanceObservabilitySnapshot, WorkspacePerformanceSnapshot,
};

const LATENCY_WINDOW_SIZE: usize = 128;

/// 固定大小滚动延迟窗口
#[derive(Debug, Clone)]
pub struct LatencyWindow {
    samples: [u64; 128],
    write_pos: usize,
    count: usize,
    max: u64,
}

impl Default for LatencyWindow {
    fn default() -> Self {
        Self {
            samples: [0u64; 128],
            write_pos: 0,
            count: 0,
            max: 0,
        }
    }
}

impl LatencyWindow {
    pub fn push(&mut self, ms: u64) {
        self.samples[self.write_pos] = ms;
        self.write_pos = (self.write_pos + 1) % LATENCY_WINDOW_SIZE;
        if self.count < LATENCY_WINDOW_SIZE {
            self.count += 1;
        }
        if ms > self.max {
            self.max = ms;
        }
    }

    pub fn last_ms(&self) -> u64 {
        if self.count == 0 {
            return 0;
        }
        let last_pos = (self.write_pos + LATENCY_WINDOW_SIZE - 1) % LATENCY_WINDOW_SIZE;
        self.samples[last_pos]
    }

    pub fn avg_ms(&self) -> u64 {
        if self.count == 0 {
            return 0;
        }
        let n = self.count.min(LATENCY_WINDOW_SIZE);
        let sum: u64 = self.samples[..n].iter().sum();
        sum / n as u64
    }

    pub fn p95_ms(&self) -> u64 {
        if self.count == 0 {
            return 0;
        }
        let n = self.count.min(LATENCY_WINDOW_SIZE);
        let mut sorted: Vec<u64> = self.samples[..n].to_vec();
        sorted.sort_unstable();
        let idx = ((n as f64 * 0.95) as usize).saturating_sub(1).min(n - 1);
        sorted[idx]
    }

    pub fn to_metric_window(&self) -> LatencyMetricWindow {
        LatencyMetricWindow {
            last_ms: self.last_ms(),
            avg_ms: self.avg_ms(),
            p95_ms: self.p95_ms(),
            max_ms: self.max,
            sample_count: self.count as u64,
            window_size: LATENCY_WINDOW_SIZE as u64,
        }
    }
}

// ============================================================================
// 工作区关键路径采样注册表（WI-002）
// ============================================================================

/// 单工作区关键路径延迟累加器
#[derive(Debug, Default)]
pub struct WorkspaceLatencyAccumulator {
    pub system_snapshot_build: LatencyWindow,
    pub workspace_file_index_refresh: LatencyWindow,
    pub workspace_git_status_refresh: LatencyWindow,
    pub evolution_snapshot_read: LatencyWindow,
}

impl WorkspaceLatencyAccumulator {
    pub fn to_snapshot(&self, project: &str, workspace: &str) -> WorkspacePerformanceSnapshot {
        WorkspacePerformanceSnapshot {
            project: project.to_string(),
            workspace: workspace.to_string(),
            system_snapshot_build: self.system_snapshot_build.to_metric_window(),
            workspace_file_index_refresh: self.workspace_file_index_refresh.to_metric_window(),
            workspace_git_status_refresh: self.workspace_git_status_refresh.to_metric_window(),
            evolution_snapshot_read: self.evolution_snapshot_read.to_metric_window(),
            snapshot_at: unix_ms_now(),
        }
    }
}

/// 工作区性能注册表（全局单例）
static WORKSPACE_PERF_REGISTRY: OnceLock<
    std::sync::Mutex<HashMap<(String, String), WorkspaceLatencyAccumulator>>,
> = OnceLock::new();

fn workspace_perf_registry(
) -> &'static std::sync::Mutex<HashMap<(String, String), WorkspaceLatencyAccumulator>> {
    WORKSPACE_PERF_REGISTRY.get_or_init(|| std::sync::Mutex::new(HashMap::new()))
}

/// 客户端性能上报聚合（按 client_instance_id 存储最新一份）
static CLIENT_PERF_REPORTS: OnceLock<std::sync::Mutex<HashMap<String, ClientPerformanceReport>>> =
    OnceLock::new();

fn client_perf_reports() -> &'static std::sync::Mutex<HashMap<String, ClientPerformanceReport>> {
    CLIENT_PERF_REPORTS.get_or_init(|| std::sync::Mutex::new(HashMap::new()))
}

/// 记录工作区关键路径延迟样本
pub fn record_workspace_latency(project: &str, workspace: &str, event: &str, ms: u64) {
    let mut reg = match workspace_perf_registry().lock() {
        Ok(r) => r,
        Err(_) => return,
    };
    let acc = reg
        .entry((project.to_string(), workspace.to_string()))
        .or_default();
    match event {
        "system_snapshot_build" => acc.system_snapshot_build.push(ms),
        "workspace_file_index_refresh" => acc.workspace_file_index_refresh.push(ms),
        "workspace_git_status_refresh" => acc.workspace_git_status_refresh.push(ms),
        "evolution_snapshot_read" => acc.evolution_snapshot_read.push(ms),
        _ => {}
    }
}

/// 记录客户端性能上报（幂等更新 client_instance_id 对应的最新快照）
pub fn record_client_performance_report(report: ClientPerformanceReport) {
    let mut reports = match client_perf_reports().lock() {
        Ok(r) => r,
        Err(_) => return,
    };
    reports.insert(report.client_instance_id.clone(), report);
}

// ============================================================================
// Core 内存采样（WI-002）
// ============================================================================

/// 采样 Core 进程当前内存使用（Darwin task_vm_info）
/// 非 Darwin 平台返回全零快照。
pub fn sample_core_memory() -> CoreRuntimeMemorySnapshot {
    #[cfg(target_os = "macos")]
    {
        use std::mem;

        #[allow(non_camel_case_types)]
        type mach_port_t = u32;
        #[allow(non_camel_case_types)]
        type kern_return_t = i32;
        #[allow(non_camel_case_types)]
        type natural_t = u32;
        #[allow(non_camel_case_types)]
        type mach_msg_type_number_t = natural_t;

        #[repr(C)]
        #[derive(Default)]
        struct TaskVmInfo {
            virtual_size: u64,
            region_count: i32,
            page_size: i32,
            resident_size: u64,
            resident_size_peak: u64,
            reusable: u64,
            reusable_max: u64,
            purgeable_volatile_pmap: u64,
            purgeable_volatile_resident: u64,
            purgeable_volatile_virtual: u64,
            compressed: u64,
            compressed_peak: u64,
            compressed_lifetime: u64,
            phys_footprint: u64,
        }

        extern "C" {
            fn task_self_trap() -> mach_port_t;
            fn task_info(
                target_task: mach_port_t,
                flavor: u32,
                task_info_out: *mut TaskVmInfo,
                task_info_outCnt: *mut mach_msg_type_number_t,
            ) -> kern_return_t;
        }

        const TASK_VM_INFO: u32 = 22;
        let task_vm_info_count =
            (mem::size_of::<TaskVmInfo>() / mem::size_of::<natural_t>()) as mach_msg_type_number_t;

        let mut info = TaskVmInfo::default();
        let mut count = task_vm_info_count;
        let kr = unsafe {
            let task = task_self_trap();
            task_info(task, TASK_VM_INFO, &mut info as *mut TaskVmInfo, &mut count)
        };

        if kr == 0 {
            return CoreRuntimeMemorySnapshot {
                resident_bytes: info.resident_size,
                virtual_bytes: info.virtual_size,
                phys_footprint_bytes: info.phys_footprint,
                sample_time_ms: unix_ms_now(),
            };
        }
    }
    CoreRuntimeMemorySnapshot {
        resident_bytes: 0,
        virtual_bytes: 0,
        phys_footprint_bytes: 0,
        sample_time_ms: unix_ms_now(),
    }
}

// ============================================================================
// 统一性能可观测快照构建（WI-002）
// ============================================================================

/// 构建全链路性能可观测快照（Core 权威真源）
pub fn build_performance_observability_snapshot() -> PerformanceObservabilitySnapshot {
    let core_memory = sample_core_memory();

    // WS 管线延迟（复用现有全局计数器，用 dispatch 作为代表性管线延迟）
    let ws_pipeline_latency = {
        let last_ms = WS_DISPATCH_MS.load(Ordering::Relaxed);
        let max_ms = WS_DISPATCH_MAX_MS.load(Ordering::Relaxed);
        let count = WS_DISPATCH_COUNT.load(Ordering::Relaxed);
        LatencyMetricWindow {
            last_ms,
            avg_ms: last_ms,
            p95_ms: max_ms,
            max_ms,
            sample_count: count,
            window_size: LATENCY_WINDOW_SIZE as u64,
        }
    };

    // 工作区指标（按 project asc, workspace asc 排序）
    let workspace_metrics = {
        let reg = match workspace_perf_registry().lock() {
            Ok(r) => r,
            Err(_) => {
                return PerformanceObservabilitySnapshot {
                    core_memory,
                    ws_pipeline_latency,
                    workspace_metrics: vec![],
                    client_metrics: vec![],
                    diagnoses: vec![],
                    snapshot_at: unix_ms_now(),
                }
            }
        };
        let mut metrics: Vec<WorkspacePerformanceSnapshot> = reg
            .iter()
            .map(|((p, w), acc)| acc.to_snapshot(p, w))
            .collect();
        metrics.sort_by(|a, b| {
            a.project
                .cmp(&b.project)
                .then(a.workspace.cmp(&b.workspace))
        });
        metrics
    };

    // 客户端上报（按 client_instance_id 排序）
    let client_metrics = {
        let reports = match client_perf_reports().lock() {
            Ok(r) => r,
            Err(_) => {
                return PerformanceObservabilitySnapshot {
                    core_memory,
                    ws_pipeline_latency,
                    workspace_metrics,
                    client_metrics: vec![],
                    diagnoses: vec![],
                    snapshot_at: unix_ms_now(),
                }
            }
        };
        let mut metrics: Vec<ClientPerformanceReport> = reports.values().cloned().collect();
        metrics.sort_by(|a, b| a.client_instance_id.cmp(&b.client_instance_id));
        metrics
    };

    let snapshot_at = unix_ms_now();

    let mut snapshot = PerformanceObservabilitySnapshot {
        core_memory,
        ws_pipeline_latency,
        workspace_metrics,
        client_metrics,
        diagnoses: vec![],
        snapshot_at,
    };

    snapshot.diagnoses = build_performance_diagnoses(&snapshot);
    snapshot
}

// ============================================================================
// 性能自动诊断（WI-004）
// ============================================================================

const WS_PIPELINE_LATENCY_WARNING_MS: u64 = 100;
const WS_PIPELINE_LATENCY_CRITICAL_MS: u64 = 500;
const WORKSPACE_SWITCH_LATENCY_CRITICAL_MS: u64 = 1000;
const FILE_TREE_LATENCY_WARNING_MS: u64 = 500;
const FILE_TREE_LATENCY_CRITICAL_MS: u64 = 2000;
const AI_SESSION_LIST_LATENCY_WARNING_MS: u64 = 500;
const MESSAGE_FLUSH_LATENCY_WARNING_MS: u64 = 200;
const QUEUE_DEPTH_WARNING: u64 = 50;
const QUEUE_DEPTH_CRITICAL: u64 = 200;
const CORE_MEMORY_WARNING_BYTES: u64 = 512 * 1024 * 1024;
const CORE_MEMORY_CRITICAL_BYTES: u64 = 768 * 1024 * 1024;
const MACOS_CLIENT_MEMORY_WARNING_BYTES: u64 = 400 * 1024 * 1024;
const MACOS_CLIENT_MEMORY_CRITICAL_BYTES: u64 = 700 * 1024 * 1024;
const IOS_CLIENT_MEMORY_WARNING_BYTES: u64 = 250 * 1024 * 1024;
const IOS_CLIENT_MEMORY_CRITICAL_BYTES: u64 = 400 * 1024 * 1024;
const CROSS_LAYER_MISMATCH_RATIO: u64 = 3;

/// 根据全链路性能快照生成诊断结果
pub fn build_performance_diagnoses(
    snapshot: &PerformanceObservabilitySnapshot,
) -> Vec<PerformanceDiagnosis> {
    let mut diagnoses = Vec::new();
    let now = unix_ms_now();

    // 1. WS 管线延迟诊断
    let ws_last = snapshot.ws_pipeline_latency.last_ms;
    if ws_last >= WS_PIPELINE_LATENCY_CRITICAL_MS {
        diagnoses.push(PerformanceDiagnosis {
            diagnosis_id: format!("perf:ws_pipeline_latency_high:system:{}", now),
            scope: PerformanceDiagnosisScope::System,
            severity: PerformanceDiagnosisSeverity::Critical,
            reason: PerformanceDiagnosisReason::WsPipelineLatencyHigh,
            summary: format!(
                "WS 管线处理延迟 {}ms，超过临界阈值 {}ms",
                ws_last, WS_PIPELINE_LATENCY_CRITICAL_MS
            ),
            evidence: vec![format!("ws_dispatch.last_ms={}", ws_last)],
            recommended_action: "检查 WS 出站队列深度和处理线程负载".to_string(),
            context: HealthContext::system(),
            client_instance_id: None,
            diagnosed_at: now,
        });
    } else if ws_last >= WS_PIPELINE_LATENCY_WARNING_MS {
        diagnoses.push(PerformanceDiagnosis {
            diagnosis_id: format!("perf:ws_pipeline_latency_high:system:{}", now),
            scope: PerformanceDiagnosisScope::System,
            severity: PerformanceDiagnosisSeverity::Warning,
            reason: PerformanceDiagnosisReason::WsPipelineLatencyHigh,
            summary: format!(
                "WS 管线处理延迟 {}ms，超过警告阈值 {}ms",
                ws_last, WS_PIPELINE_LATENCY_WARNING_MS
            ),
            evidence: vec![format!("ws_dispatch.last_ms={}", ws_last)],
            recommended_action: "监控 WS 出站队列深度趋势".to_string(),
            context: HealthContext::system(),
            client_instance_id: None,
            diagnosed_at: now,
        });
    }

    // 2. 队列积压诊断
    let queue_depth = WS_OUTBOUND_QUEUE_DEPTH.load(Ordering::Relaxed);
    if queue_depth >= QUEUE_DEPTH_CRITICAL {
        diagnoses.push(PerformanceDiagnosis {
            diagnosis_id: format!("perf:queue_backpressure_high:system:{}", now),
            scope: PerformanceDiagnosisScope::System,
            severity: PerformanceDiagnosisSeverity::Critical,
            reason: PerformanceDiagnosisReason::QueueBackpressureHigh,
            summary: format!(
                "WS 出站队列深度 {}，超过临界阈值 {}",
                queue_depth, QUEUE_DEPTH_CRITICAL
            ),
            evidence: vec![format!("ws_outbound_queue_depth={}", queue_depth)],
            recommended_action: "检查消费者是否阻塞或慢于生产者速率".to_string(),
            context: HealthContext::system(),
            client_instance_id: None,
            diagnosed_at: now,
        });
    } else if queue_depth >= QUEUE_DEPTH_WARNING {
        diagnoses.push(PerformanceDiagnosis {
            diagnosis_id: format!("perf:queue_backpressure_high:system:{}", now),
            scope: PerformanceDiagnosisScope::System,
            severity: PerformanceDiagnosisSeverity::Warning,
            reason: PerformanceDiagnosisReason::QueueBackpressureHigh,
            summary: format!(
                "WS 出站队列深度 {}，超过警告阈值 {}",
                queue_depth, QUEUE_DEPTH_WARNING
            ),
            evidence: vec![format!("ws_outbound_queue_depth={}", queue_depth)],
            recommended_action: "监控队列增长趋势".to_string(),
            context: HealthContext::system(),
            client_instance_id: None,
            diagnosed_at: now,
        });
    }

    // 3. Core 内存压力诊断
    let core_phys = snapshot.core_memory.phys_footprint_bytes;
    if core_phys >= CORE_MEMORY_CRITICAL_BYTES {
        diagnoses.push(PerformanceDiagnosis {
            diagnosis_id: format!("perf:core_memory_pressure:system:{}", now),
            scope: PerformanceDiagnosisScope::System,
            severity: PerformanceDiagnosisSeverity::Critical,
            reason: PerformanceDiagnosisReason::CoreMemoryPressure,
            summary: format!(
                "Core 内存占用 {}MB，超过临界阈值 768MB",
                core_phys / (1024 * 1024)
            ),
            evidence: vec![format!("core.phys_footprint_bytes={}", core_phys)],
            recommended_action: "考虑减少并发工作区数量或重启 Core 进程".to_string(),
            context: HealthContext::system(),
            client_instance_id: None,
            diagnosed_at: now,
        });
    } else if core_phys >= CORE_MEMORY_WARNING_BYTES {
        diagnoses.push(PerformanceDiagnosis {
            diagnosis_id: format!("perf:core_memory_pressure:system:{}", now),
            scope: PerformanceDiagnosisScope::System,
            severity: PerformanceDiagnosisSeverity::Warning,
            reason: PerformanceDiagnosisReason::CoreMemoryPressure,
            summary: format!(
                "Core 内存占用 {}MB，超过警告阈值 512MB",
                core_phys / (1024 * 1024)
            ),
            evidence: vec![format!("core.phys_footprint_bytes={}", core_phys)],
            recommended_action: "监控内存增长趋势，检查缓存淘汰策略".to_string(),
            context: HealthContext::system(),
            client_instance_id: None,
            diagnosed_at: now,
        });
    }

    // 4. 工作区关键路径延迟诊断
    for ws in &snapshot.workspace_metrics {
        let ctx = HealthContext::for_workspace(&ws.project, &ws.workspace);
        let fi_p95 = ws.workspace_file_index_refresh.p95_ms;
        if fi_p95 >= FILE_TREE_LATENCY_CRITICAL_MS
            && ws.workspace_file_index_refresh.sample_count > 0
        {
            diagnoses.push(PerformanceDiagnosis {
                diagnosis_id: format!(
                    "perf:file_tree_latency_high:{}:{}:{}",
                    ws.project, ws.workspace, now
                ),
                scope: PerformanceDiagnosisScope::Workspace,
                severity: PerformanceDiagnosisSeverity::Critical,
                reason: PerformanceDiagnosisReason::FileTreeLatencyHigh,
                summary: format!(
                    "[{}/{}] 文件索引刷新 p95={}ms",
                    ws.project, ws.workspace, fi_p95
                ),
                evidence: vec![format!("workspace_file_index_refresh.p95_ms={}", fi_p95)],
                recommended_action: "检查工作区文件数量和磁盘 I/O 状态".to_string(),
                context: ctx,
                client_instance_id: None,
                diagnosed_at: now,
            });
        } else if fi_p95 >= FILE_TREE_LATENCY_WARNING_MS
            && ws.workspace_file_index_refresh.sample_count > 0
        {
            diagnoses.push(PerformanceDiagnosis {
                diagnosis_id: format!(
                    "perf:file_tree_latency_high:{}:{}:{}",
                    ws.project, ws.workspace, now
                ),
                scope: PerformanceDiagnosisScope::Workspace,
                severity: PerformanceDiagnosisSeverity::Warning,
                reason: PerformanceDiagnosisReason::FileTreeLatencyHigh,
                summary: format!(
                    "[{}/{}] 文件索引刷新 p95={}ms",
                    ws.project, ws.workspace, fi_p95
                ),
                evidence: vec![format!("workspace_file_index_refresh.p95_ms={}", fi_p95)],
                recommended_action: "监控文件索引增长趋势".to_string(),
                context: ctx,
                client_instance_id: None,
                diagnosed_at: now,
            });
        }
    }

    // 5. 客户端性能诊断
    for client in &snapshot.client_metrics {
        let (mem_warning, mem_critical) = if client.platform == "ios" {
            (
                IOS_CLIENT_MEMORY_WARNING_BYTES,
                IOS_CLIENT_MEMORY_CRITICAL_BYTES,
            )
        } else {
            (
                MACOS_CLIENT_MEMORY_WARNING_BYTES,
                MACOS_CLIENT_MEMORY_CRITICAL_BYTES,
            )
        };
        let ctx = HealthContext::for_workspace(&client.project, &client.workspace);

        // 客户端内存压力
        let client_mem = client.memory.current_bytes;
        if client_mem >= mem_critical {
            diagnoses.push(PerformanceDiagnosis {
                diagnosis_id: format!(
                    "perf:client_memory_pressure:{}:{}",
                    client.client_instance_id, now
                ),
                scope: PerformanceDiagnosisScope::ClientInstance,
                severity: PerformanceDiagnosisSeverity::Critical,
                reason: PerformanceDiagnosisReason::ClientMemoryPressure,
                summary: format!(
                    "[{}:{}] 客户端内存 {}MB，超过临界阈值",
                    client.client_instance_id,
                    client.platform,
                    client_mem / (1024 * 1024)
                ),
                evidence: vec![format!("client.memory.current_bytes={}", client_mem)],
                recommended_action: "检查客户端内存泄漏，考虑关闭不用的工作区".to_string(),
                context: ctx.clone(),
                client_instance_id: Some(client.client_instance_id.clone()),
                diagnosed_at: now,
            });
        } else if client_mem >= mem_warning && client_mem > 0 {
            diagnoses.push(PerformanceDiagnosis {
                diagnosis_id: format!(
                    "perf:client_memory_pressure:{}:{}",
                    client.client_instance_id, now
                ),
                scope: PerformanceDiagnosisScope::ClientInstance,
                severity: PerformanceDiagnosisSeverity::Warning,
                reason: PerformanceDiagnosisReason::ClientMemoryPressure,
                summary: format!(
                    "[{}:{}] 客户端内存 {}MB，超过警告阈值",
                    client.client_instance_id,
                    client.platform,
                    client_mem / (1024 * 1024)
                ),
                evidence: vec![format!("client.memory.current_bytes={}", client_mem)],
                recommended_action: "监控客户端内存增长趋势".to_string(),
                context: ctx.clone(),
                client_instance_id: Some(client.client_instance_id.clone()),
                diagnosed_at: now,
            });
        }

        // 工作区切换延迟
        let ws_p95 = client.workspace_switch.p95_ms;
        if ws_p95 >= WORKSPACE_SWITCH_LATENCY_CRITICAL_MS
            && client.workspace_switch.sample_count > 0
        {
            diagnoses.push(PerformanceDiagnosis {
                diagnosis_id: format!(
                    "perf:workspace_switch_latency_high:{}:{}",
                    client.client_instance_id, now
                ),
                scope: PerformanceDiagnosisScope::ClientInstance,
                severity: PerformanceDiagnosisSeverity::Critical,
                reason: PerformanceDiagnosisReason::WorkspaceSwitchLatencyHigh,
                summary: format!(
                    "[{}] 工作区切换 p95={}ms",
                    client.client_instance_id, ws_p95
                ),
                evidence: vec![format!("client.workspace_switch.p95_ms={}", ws_p95)],
                recommended_action: "检查工作区切换时加载的数据量，考虑懒加载优化".to_string(),
                context: ctx.clone(),
                client_instance_id: Some(client.client_instance_id.clone()),
                diagnosed_at: now,
            });
        }

        // AI 会话列表延迟
        let ai_p95 = client.ai_session_list_request.p95_ms;
        if ai_p95 >= AI_SESSION_LIST_LATENCY_WARNING_MS
            && client.ai_session_list_request.sample_count > 0
        {
            diagnoses.push(PerformanceDiagnosis {
                diagnosis_id: format!(
                    "perf:ai_session_list_latency_high:{}:{}",
                    client.client_instance_id, now
                ),
                scope: PerformanceDiagnosisScope::ClientInstance,
                severity: PerformanceDiagnosisSeverity::Warning,
                reason: PerformanceDiagnosisReason::AiSessionListLatencyHigh,
                summary: format!(
                    "[{}] AI 会话列表请求 p95={}ms",
                    client.client_instance_id, ai_p95
                ),
                evidence: vec![format!("client.ai_session_list_request.p95_ms={}", ai_p95)],
                recommended_action: "检查 AI 会话列表数据量和 Core 处理延迟".to_string(),
                context: ctx.clone(),
                client_instance_id: Some(client.client_instance_id.clone()),
                diagnosed_at: now,
            });
        }

        // 消息尾部刷新延迟
        let flush_p95 = client.ai_message_tail_flush.p95_ms;
        if flush_p95 >= MESSAGE_FLUSH_LATENCY_WARNING_MS
            && client.ai_message_tail_flush.sample_count > 0
        {
            diagnoses.push(PerformanceDiagnosis {
                diagnosis_id: format!(
                    "perf:message_flush_latency_high:{}:{}",
                    client.client_instance_id, now
                ),
                scope: PerformanceDiagnosisScope::ClientInstance,
                severity: PerformanceDiagnosisSeverity::Warning,
                reason: PerformanceDiagnosisReason::MessageFlushLatencyHigh,
                summary: format!(
                    "[{}] AI 消息尾部刷新 p95={}ms",
                    client.client_instance_id, flush_p95
                ),
                evidence: vec![format!("client.ai_message_tail_flush.p95_ms={}", flush_p95)],
                recommended_action: "检查消息批量写入频率和 WS 管线吞吐量".to_string(),
                context: ctx.clone(),
                client_instance_id: Some(client.client_instance_id.clone()),
                diagnosed_at: now,
            });
        }

        // 跨层延迟失配
        let client_ft_p95 = client.file_tree_request.p95_ms;
        if client_ft_p95 > 0 && client.file_tree_request.sample_count > 0 {
            let core_ft_p95 = snapshot
                .workspace_metrics
                .iter()
                .find(|w| w.project == client.project && w.workspace == client.workspace)
                .map(|w| w.workspace_file_index_refresh.p95_ms)
                .unwrap_or(0);

            if core_ft_p95 > 0
                && client_ft_p95 >= FILE_TREE_LATENCY_WARNING_MS
                && client_ft_p95 >= core_ft_p95 * CROSS_LAYER_MISMATCH_RATIO
            {
                diagnoses.push(PerformanceDiagnosis {
                    diagnosis_id: format!(
                        "perf:cross_layer_latency_mismatch:{}:{}",
                        client.client_instance_id, now
                    ),
                    scope: PerformanceDiagnosisScope::ClientInstance,
                    severity: PerformanceDiagnosisSeverity::Warning,
                    reason: PerformanceDiagnosisReason::CrossLayerLatencyMismatch,
                    summary: format!(
                        "[{}] 文件树延迟 client p95={}ms vs Core p95={}ms，客户端/UI 层可能是瓶颈",
                        client.client_instance_id, client_ft_p95, core_ft_p95
                    ),
                    evidence: vec![
                        format!("client.file_tree_request.p95_ms={}", client_ft_p95),
                        format!("core.workspace_file_index_refresh.p95_ms={}", core_ft_p95),
                    ],
                    recommended_action: "检查客户端文件树渲染性能和状态更新机制".to_string(),
                    context: ctx,
                    client_instance_id: Some(client.client_instance_id.clone()),
                    diagnosed_at: now,
                });
            } else if core_ft_p95 == 0
                && client_ft_p95 >= FILE_TREE_LATENCY_WARNING_MS
                && snapshot.ws_pipeline_latency.last_ms >= WS_PIPELINE_LATENCY_WARNING_MS
            {
                diagnoses.push(PerformanceDiagnosis {
                    diagnosis_id: format!(
                        "perf:cross_layer_latency_mismatch:{}:{}",
                        client.client_instance_id, now
                    ),
                    scope: PerformanceDiagnosisScope::ClientInstance,
                    severity: PerformanceDiagnosisSeverity::Warning,
                    reason: PerformanceDiagnosisReason::CrossLayerLatencyMismatch,
                    summary: format!(
                        "[{}] 文件树延迟 client p95={}ms，WS 管线同步升高，Core/协议层疑似瓶颈",
                        client.client_instance_id, client_ft_p95
                    ),
                    evidence: vec![
                        format!("client.file_tree_request.p95_ms={}", client_ft_p95),
                        format!(
                            "ws_dispatch.last_ms={}",
                            snapshot.ws_pipeline_latency.last_ms
                        ),
                    ],
                    recommended_action: "检查 Core WS 管线处理延迟和出站队列".to_string(),
                    context: ctx,
                    client_instance_id: Some(client.client_instance_id.clone()),
                    diagnosed_at: now,
                });
            }
        }
    }

    diagnoses
}

// ============================================================================
// 性能诊断 → HealthIncident 映射（WI-004）
// ============================================================================

/// 将高优先级性能诊断映射为 HealthIncident
pub fn performance_diagnoses_to_incidents(
    diagnoses: &[PerformanceDiagnosis],
) -> Vec<crate::server::protocol::health::HealthIncident> {
    use crate::server::protocol::health::{
        HealthIncident, IncidentRecoverability, IncidentSeverity, IncidentSource,
    };
    diagnoses
        .iter()
        .filter(|d| d.severity >= PerformanceDiagnosisSeverity::Warning)
        .map(|d| {
            let severity = match d.severity {
                PerformanceDiagnosisSeverity::Critical => IncidentSeverity::Critical,
                PerformanceDiagnosisSeverity::Warning => IncidentSeverity::Warning,
                PerformanceDiagnosisSeverity::Info => IncidentSeverity::Info,
            };
            HealthIncident {
                incident_id: d.diagnosis_id.clone(),
                severity,
                recoverability: IncidentRecoverability::Recoverable,
                source: IncidentSource::CoreProcess,
                root_cause: format!("{}", d.reason),
                summary: Some(d.summary.clone()),
                first_seen_at: d.diagnosed_at,
                last_seen_at: d.diagnosed_at,
                context: d.context.clone(),
            }
        })
        .collect()
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
        assert_eq!(
            compute_pressure_level(&acc, Some(0.9)),
            ResourcePressureLevel::Low
        );
    }

    #[test]
    fn test_pressure_level_critical() {
        let mut acc = WorkspaceObservationAccumulator::default();
        acc.consecutive_failures = 5;
        acc.rate_limit_hit_count = 10;
        assert_eq!(
            compute_pressure_level(&acc, Some(0.1)),
            ResourcePressureLevel::Critical
        );
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
            anomalies
                .iter()
                .any(|a| a.kind == PredictiveAnomalyKind::RecurringFailure),
            "should detect recurring failure"
        );
    }
}

#[cfg(test)]
mod analysis_tests {
    use super::*;
    use crate::server::protocol::health::*;

    #[test]
    fn analysis_summary_empty_inputs() {
        let summary = build_analysis_summary("proj", "ws", "cycle-1", None, &[], &[], &[]);
        assert_eq!(summary.project, "proj");
        assert_eq!(summary.workspace, "ws");
        assert_eq!(summary.cycle_id, "cycle-1");
        assert!(summary.bottlenecks.is_empty());
        assert!(summary.suggestions.is_empty());
        assert_eq!(summary.overall_risk_score, 0.0);
        assert_eq!(summary.health_score, 1.0);
        assert_eq!(summary.pressure_level, ResourcePressureLevel::Low);
    }

    #[test]
    fn analysis_summary_from_gate_failure() {
        let gate = GateDecision {
            verdict: GateVerdict::Fail,
            failure_reasons: vec![GateFailureReason::CriticalIncident],
            project: "proj".to_string(),
            workspace: "ws".to_string(),
            cycle_id: "cycle-1".to_string(),
            health_status: SystemHealthStatus::Unhealthy,
            retry_count: 0,
            bypassed: false,
            bypass_reason: None,
            decided_at: 1000,
        };
        let summary = build_analysis_summary("proj", "ws", "cycle-1", Some(&gate), &[], &[], &[]);
        assert!(!summary.bottlenecks.is_empty());
        assert!(summary.overall_risk_score > 0.0);
        assert!(summary.gate_decision.is_some());
    }

    #[test]
    fn analysis_summary_from_predictive_anomalies() {
        let anomalies = vec![PredictiveAnomaly {
            anomaly_id: "pred:recurring:proj:ws".to_string(),
            kind: PredictiveAnomalyKind::RecurringFailure,
            confidence: PredictionConfidence::High,
            root_cause: "consecutive_failures".to_string(),
            summary: Some("连续 3 次失败".to_string()),
            time_window: PredictionTimeWindow {
                start_at: 1000,
                end_at: 2000,
            },
            related_incident_ids: vec!["inc-1".to_string()],
            context: HealthContext {
                project: Some("proj".to_string()),
                workspace: Some("ws".to_string()),
                session_id: None,
                cycle_id: None,
            },
            score: 0.75,
            predicted_at: 1000,
        }];
        let summary = build_analysis_summary("proj", "ws", "cycle-1", None, &[], &anomalies, &[]);
        assert_eq!(summary.bottlenecks.len(), 1);
        assert_eq!(
            summary.bottlenecks[0].kind,
            BottleneckKind::RecurringFailure
        );
        assert_eq!(summary.predictive_anomaly_ids.len(), 1);
    }

    #[test]
    fn analysis_summary_isolates_by_project_workspace() {
        let anomalies = vec![
            PredictiveAnomaly {
                anomaly_id: "pred:a:projA:wsA".to_string(),
                kind: PredictiveAnomalyKind::RateLimitRisk,
                confidence: PredictionConfidence::Medium,
                root_cause: "rate_limit".to_string(),
                summary: None,
                time_window: PredictionTimeWindow {
                    start_at: 1000,
                    end_at: 2000,
                },
                related_incident_ids: Vec::new(),
                context: HealthContext::for_workspace("projA", "wsA"),
                score: 0.5,
                predicted_at: 1000,
            },
            PredictiveAnomaly {
                anomaly_id: "pred:b:projB:wsB".to_string(),
                kind: PredictiveAnomalyKind::RecurringFailure,
                confidence: PredictionConfidence::High,
                root_cause: "failures".to_string(),
                summary: None,
                time_window: PredictionTimeWindow {
                    start_at: 1000,
                    end_at: 2000,
                },
                related_incident_ids: Vec::new(),
                context: HealthContext::for_workspace("projB", "wsB"),
                score: 0.8,
                predicted_at: 1000,
            },
        ];
        // projA/wsA 的分析不应包含 projB/wsB 的异常
        let summary_a =
            build_analysis_summary("projA", "wsA", "cycle-1", None, &[], &anomalies, &[]);
        assert_eq!(summary_a.bottlenecks.len(), 1);
        assert_eq!(summary_a.bottlenecks[0].kind, BottleneckKind::RateLimit);
        assert_eq!(summary_a.predictive_anomaly_ids, vec!["pred:a:projA:wsA"]);
    }
}

// ============================================================================
// 性能可观测回归护栏测试（WI-006）
// ============================================================================
//
// 覆盖：协议序列化稳定性、工作区隔离、客户端实例隔离、诊断阈值、跨层延迟归因
// 注意：所有测试直接构造 PerformanceObservabilitySnapshot 快照并调用
//       build_performance_diagnoses()，避免依赖全局 Mutex 状态，测试间互不干扰。

#[cfg(test)]
mod perf_observability_tests {
    use super::*;
    use crate::server::protocol::health::*;

    // ── 辅助构造函数 ────────────────────────────────────────────────────────

    fn empty_latency() -> LatencyMetricWindow {
        LatencyMetricWindow {
            last_ms: 0,
            avg_ms: 0,
            p95_ms: 0,
            max_ms: 0,
            sample_count: 0,
            window_size: 128,
        }
    }

    fn latency_with(last_ms: u64, p95_ms: u64, sample_count: u64) -> LatencyMetricWindow {
        LatencyMetricWindow {
            last_ms,
            avg_ms: last_ms,
            p95_ms,
            max_ms: p95_ms,
            sample_count,
            window_size: 128,
        }
    }

    fn empty_memory() -> MemoryUsageSnapshot {
        MemoryUsageSnapshot::default()
    }

    fn empty_core_memory() -> CoreRuntimeMemorySnapshot {
        CoreRuntimeMemorySnapshot::default()
    }

    fn empty_obs() -> PerformanceObservabilitySnapshot {
        PerformanceObservabilitySnapshot {
            core_memory: empty_core_memory(),
            ws_pipeline_latency: empty_latency(),
            workspace_metrics: Vec::new(),
            client_metrics: Vec::new(),
            diagnoses: Vec::new(),
            snapshot_at: 0,
        }
    }

    fn client_report_for(
        id: &str,
        platform: &str,
        project: &str,
        workspace: &str,
    ) -> ClientPerformanceReport {
        ClientPerformanceReport {
            client_instance_id: id.to_string(),
            platform: platform.to_string(),
            project: project.to_string(),
            workspace: workspace.to_string(),
            memory: empty_memory(),
            workspace_switch: empty_latency(),
            file_tree_request: empty_latency(),
            file_tree_expand: empty_latency(),
            ai_session_list_request: empty_latency(),
            ai_message_tail_flush: empty_latency(),
            evidence_page_append: empty_latency(),
            reported_at: 0,
        }
    }

    fn ws_snapshot_for(
        project: &str,
        workspace: &str,
        file_index_refresh_p95: u64,
    ) -> WorkspacePerformanceSnapshot {
        WorkspacePerformanceSnapshot {
            project: project.to_string(),
            workspace: workspace.to_string(),
            system_snapshot_build: empty_latency(),
            workspace_file_index_refresh: if file_index_refresh_p95 > 0 {
                latency_with(file_index_refresh_p95, file_index_refresh_p95, 5)
            } else {
                empty_latency()
            },
            workspace_git_status_refresh: empty_latency(),
            evolution_snapshot_read: empty_latency(),
            snapshot_at: 0,
        }
    }

    // ── LatencyWindow 滚动统计正确性 ─────────────────────────────────────

    #[test]
    fn latency_window_statistics_correct_on_single_sample() {
        let mut w = LatencyWindow::default();
        assert_eq!(w.last_ms(), 0, "空窗口 last_ms 应为 0");
        assert_eq!(w.avg_ms(), 0, "空窗口 avg_ms 应为 0");
        assert_eq!(w.p95_ms(), 0, "空窗口 p95_ms 应为 0");

        w.push(100);
        assert_eq!(w.last_ms(), 100);
        assert_eq!(w.avg_ms(), 100);
        assert_eq!(w.p95_ms(), 100);
    }

    #[test]
    fn latency_window_p95_near_top_value_for_100_samples() {
        let mut w = LatencyWindow::default();
        for i in 1u64..=100 {
            w.push(i);
        }
        let p95 = w.p95_ms();
        assert!(p95 >= 94 && p95 <= 100, "p95={} 应在 [94,100]", p95);
    }

    #[test]
    fn latency_window_max_tracks_global_maximum() {
        let mut w = LatencyWindow::default();
        w.push(10);
        w.push(500);
        w.push(200);
        let mw = w.to_metric_window();
        assert_eq!(mw.max_ms, 500, "max_ms 应跟踪全局最大值");
        assert_eq!(mw.sample_count, 3);
        assert_eq!(mw.window_size, 128);
    }

    // ── 协议序列化稳定性 ─────────────────────────────────────────────────

    #[test]
    fn performance_observability_snapshot_serializes_stable_json_fields() {
        let snap = empty_obs();
        let json = serde_json::to_value(&snap).expect("should serialize");
        assert!(
            json.get("core_memory").is_some(),
            "core_memory 字段必须存在"
        );
        assert!(
            json.get("ws_pipeline_latency").is_some(),
            "ws_pipeline_latency 字段必须存在"
        );
        assert!(
            json.get("snapshot_at").is_some(),
            "snapshot_at 字段必须存在"
        );
    }

    #[test]
    fn workspace_performance_snapshot_field_names_are_snake_case() {
        let ws = ws_snapshot_for("proj_a", "ws1", 42);
        let json = serde_json::to_value(&ws).expect("should serialize");
        assert_eq!(json["project"], "proj_a");
        assert_eq!(json["workspace"], "ws1");
        assert!(
            json.get("workspace_file_index_refresh").is_some(),
            "workspace_file_index_refresh 字段必须存在"
        );
        assert_eq!(json["workspace_file_index_refresh"]["p95_ms"], 42);
        assert_eq!(json["snapshot_at"], 0);
    }

    #[test]
    fn client_performance_report_serializes_client_instance_id_correctly() {
        let r = client_report_for("inst-001", "macos", "proj_x", "ws_default");
        let json = serde_json::to_value(&r).expect("should serialize");
        assert_eq!(json["client_instance_id"], "inst-001");
        assert_eq!(json["platform"], "macos");
        assert_eq!(json["project"], "proj_x");
        assert_eq!(json["workspace"], "ws_default");
    }

    #[test]
    fn performance_diagnosis_reason_serializes_to_snake_case() {
        let reason = PerformanceDiagnosisReason::WsPipelineLatencyHigh;
        let json = serde_json::to_value(&reason).expect("should serialize");
        assert_eq!(json, "ws_pipeline_latency_high");

        let scope = PerformanceDiagnosisScope::ClientInstance;
        let json2 = serde_json::to_value(&scope).expect("should serialize");
        assert_eq!(json2, "client_instance");
    }

    // ── 工作区隔离：不同 project 下同名工作区指标不混用 ──────────────────

    #[test]
    fn workspace_isolation_same_workspace_name_different_projects() {
        let snap = PerformanceObservabilitySnapshot {
            core_memory: empty_core_memory(),
            ws_pipeline_latency: empty_latency(),
            workspace_metrics: vec![
                // proj_a/default: 文件索引 p95=3000ms（超过 critical 2000ms）
                ws_snapshot_for("proj_a", "default", 3000),
                // proj_b/default: 正常
                ws_snapshot_for("proj_b", "default", 10),
            ],
            client_metrics: Vec::new(),
            diagnoses: Vec::new(),
            snapshot_at: 0,
        };
        let diagnoses = build_performance_diagnoses(&snap);
        let ft: Vec<_> = diagnoses
            .iter()
            .filter(|d| d.reason == PerformanceDiagnosisReason::FileTreeLatencyHigh)
            .collect();
        assert_eq!(
            ft.len(),
            1,
            "只有 proj_a/default 应触发 file_tree_latency_high"
        );
        assert_eq!(ft[0].context.project.as_deref(), Some("proj_a"));
        assert_eq!(ft[0].context.workspace.as_deref(), Some("default"));
        assert_eq!(ft[0].scope, PerformanceDiagnosisScope::Workspace);
    }

    #[test]
    fn workspace_isolation_same_project_different_workspaces() {
        let snap = PerformanceObservabilitySnapshot {
            core_memory: empty_core_memory(),
            ws_pipeline_latency: empty_latency(),
            workspace_metrics: vec![
                ws_snapshot_for("proj_a", "ws_slow", 2500),
                ws_snapshot_for("proj_a", "ws_fast", 10),
            ],
            client_metrics: Vec::new(),
            diagnoses: Vec::new(),
            snapshot_at: 0,
        };
        let diagnoses = build_performance_diagnoses(&snap);
        let ft: Vec<_> = diagnoses
            .iter()
            .filter(|d| d.reason == PerformanceDiagnosisReason::FileTreeLatencyHigh)
            .collect();
        assert_eq!(ft.len(), 1, "只有 ws_slow 应触发");
        assert_eq!(ft[0].context.workspace.as_deref(), Some("ws_slow"));
    }

    // ── 客户端实例隔离：不同 client_instance_id 指标互不覆盖 ─────────────

    #[test]
    fn client_isolation_only_high_memory_instance_triggers_diagnosis() {
        // iOS critical = 400 MB
        let ios_critical: u64 = 400 * 1024 * 1024 + 1;
        let mut report_a = client_report_for("inst_a", "ios", "proj", "ws");
        report_a.memory.current_bytes = ios_critical;
        let mut report_b = client_report_for("inst_b", "ios", "proj", "ws");
        report_b.memory.current_bytes = 10 * 1024 * 1024; // 正常

        let snap = PerformanceObservabilitySnapshot {
            core_memory: empty_core_memory(),
            ws_pipeline_latency: empty_latency(),
            workspace_metrics: Vec::new(),
            client_metrics: vec![report_a, report_b],
            diagnoses: Vec::new(),
            snapshot_at: 0,
        };
        let diagnoses = build_performance_diagnoses(&snap);
        let mem: Vec<_> = diagnoses
            .iter()
            .filter(|d| d.reason == PerformanceDiagnosisReason::ClientMemoryPressure)
            .collect();
        assert_eq!(mem.len(), 1, "只有 inst_a 应触发内存诊断");
        assert_eq!(
            mem[0].client_instance_id.as_deref(),
            Some("inst_a"),
            "诊断的 client_instance_id 应为 inst_a"
        );
        assert_eq!(mem[0].severity, PerformanceDiagnosisSeverity::Critical);
        assert_eq!(mem[0].scope, PerformanceDiagnosisScope::ClientInstance);
    }

    #[test]
    fn client_isolation_two_instances_with_different_latency_problems() {
        // inst_c: workspace_switch 高延迟（>= critical 1000ms）
        // inst_d: workspace_switch 正常
        let mut report_c = client_report_for("inst_c", "macos", "proj", "ws");
        report_c.workspace_switch = latency_with(1200, 1200, 3);
        let report_d = client_report_for("inst_d", "macos", "proj", "ws");

        let snap = PerformanceObservabilitySnapshot {
            core_memory: empty_core_memory(),
            ws_pipeline_latency: empty_latency(),
            workspace_metrics: Vec::new(),
            client_metrics: vec![report_c, report_d],
            diagnoses: Vec::new(),
            snapshot_at: 0,
        };
        let diagnoses = build_performance_diagnoses(&snap);
        let ws_diag: Vec<_> = diagnoses
            .iter()
            .filter(|d| d.reason == PerformanceDiagnosisReason::WorkspaceSwitchLatencyHigh)
            .collect();
        assert_eq!(ws_diag.len(), 1, "只有 inst_c 应触发工作区切换延迟诊断");
        assert_eq!(ws_diag[0].client_instance_id.as_deref(), Some("inst_c"));
    }

    // ── 诊断阈值精确验证 ─────────────────────────────────────────────────

    #[test]
    fn threshold_core_memory_exactly_at_warning_triggers_warning() {
        let warning_bytes: u64 = 512 * 1024 * 1024;
        let mut snap = empty_obs();
        snap.core_memory.phys_footprint_bytes = warning_bytes;
        let d = build_performance_diagnoses(&snap);
        let mem: Vec<_> = d
            .iter()
            .filter(|d| d.reason == PerformanceDiagnosisReason::CoreMemoryPressure)
            .collect();
        assert_eq!(mem.len(), 1, "512MB 应触发 warning");
        assert_eq!(mem[0].severity, PerformanceDiagnosisSeverity::Warning);
    }

    #[test]
    fn threshold_core_memory_exactly_at_critical_triggers_critical() {
        let critical_bytes: u64 = 768 * 1024 * 1024;
        let mut snap = empty_obs();
        snap.core_memory.phys_footprint_bytes = critical_bytes;
        let d = build_performance_diagnoses(&snap);
        let mem: Vec<_> = d
            .iter()
            .filter(|d| d.reason == PerformanceDiagnosisReason::CoreMemoryPressure)
            .collect();
        assert_eq!(mem.len(), 1, "768MB 应触发 critical");
        assert_eq!(mem[0].severity, PerformanceDiagnosisSeverity::Critical);
    }

    #[test]
    fn threshold_below_warning_produces_no_memory_diagnosis() {
        let below: u64 = 511 * 1024 * 1024;
        let mut snap = empty_obs();
        snap.core_memory.phys_footprint_bytes = below;
        let d = build_performance_diagnoses(&snap);
        assert!(
            d.iter()
                .all(|d| d.reason != PerformanceDiagnosisReason::CoreMemoryPressure),
            "低于阈值不应产出 CoreMemoryPressure 诊断"
        );
    }

    #[test]
    fn threshold_macos_client_memory_at_warning() {
        let macos_warning: u64 = 400 * 1024 * 1024;
        let mut report = client_report_for("mac_inst", "macos", "p", "w");
        report.memory.current_bytes = macos_warning;
        let snap = PerformanceObservabilitySnapshot {
            core_memory: empty_core_memory(),
            ws_pipeline_latency: empty_latency(),
            workspace_metrics: Vec::new(),
            client_metrics: vec![report],
            diagnoses: Vec::new(),
            snapshot_at: 0,
        };
        let d = build_performance_diagnoses(&snap);
        let mem: Vec<_> = d
            .iter()
            .filter(|d| d.reason == PerformanceDiagnosisReason::ClientMemoryPressure)
            .collect();
        assert_eq!(mem.len(), 1, "macOS 400MB 应触发 warning");
        assert_eq!(mem[0].severity, PerformanceDiagnosisSeverity::Warning);
    }

    #[test]
    fn threshold_ios_client_memory_at_critical() {
        let ios_critical: u64 = 400 * 1024 * 1024;
        let mut report = client_report_for("ios_inst", "ios", "p", "w");
        report.memory.current_bytes = ios_critical;
        let snap = PerformanceObservabilitySnapshot {
            core_memory: empty_core_memory(),
            ws_pipeline_latency: empty_latency(),
            workspace_metrics: Vec::new(),
            client_metrics: vec![report],
            diagnoses: Vec::new(),
            snapshot_at: 0,
        };
        let d = build_performance_diagnoses(&snap);
        let mem: Vec<_> = d
            .iter()
            .filter(|d| d.reason == PerformanceDiagnosisReason::ClientMemoryPressure)
            .collect();
        assert_eq!(mem.len(), 1, "iOS 400MB 应触发 critical");
        assert_eq!(mem[0].severity, PerformanceDiagnosisSeverity::Critical);
    }

    #[test]
    fn threshold_ws_pipeline_at_warning() {
        let mut snap = empty_obs();
        snap.ws_pipeline_latency = latency_with(100, 100, 1);
        let d = build_performance_diagnoses(&snap);
        let ws: Vec<_> = d
            .iter()
            .filter(|d| d.reason == PerformanceDiagnosisReason::WsPipelineLatencyHigh)
            .collect();
        assert_eq!(ws.len(), 1, "WS 管线 100ms 应触发 warning");
        assert_eq!(ws[0].severity, PerformanceDiagnosisSeverity::Warning);
        assert_eq!(ws[0].scope, PerformanceDiagnosisScope::System);
    }

    #[test]
    fn threshold_ws_pipeline_at_critical() {
        let mut snap = empty_obs();
        snap.ws_pipeline_latency = latency_with(500, 500, 1);
        let d = build_performance_diagnoses(&snap);
        let ws: Vec<_> = d
            .iter()
            .filter(|d| d.reason == PerformanceDiagnosisReason::WsPipelineLatencyHigh)
            .collect();
        assert_eq!(ws.len(), 1, "WS 管线 500ms 应触发 critical");
        assert_eq!(ws[0].severity, PerformanceDiagnosisSeverity::Critical);
    }

    // ── 跨层延迟归因 ─────────────────────────────────────────────────────

    #[test]
    fn cross_layer_attribution_points_to_client_ui_when_core_normal() {
        // client file_tree p95 = 600ms >> Core p95 = 100ms（比值 = 6 > RATIO=3）
        // → 应归因为客户端/UI 层
        let core_p95: u64 = 100;
        let client_p95: u64 = 600;

        let mut report = client_report_for("inst_ui", "macos", "proj_x", "ws1");
        report.file_tree_request = latency_with(client_p95, client_p95, 5);

        let snap = PerformanceObservabilitySnapshot {
            core_memory: empty_core_memory(),
            ws_pipeline_latency: empty_latency(),
            workspace_metrics: vec![ws_snapshot_for("proj_x", "ws1", core_p95)],
            client_metrics: vec![report],
            diagnoses: Vec::new(),
            snapshot_at: 0,
        };
        let d = build_performance_diagnoses(&snap);
        let cl: Vec<_> = d
            .iter()
            .filter(|d| d.reason == PerformanceDiagnosisReason::CrossLayerLatencyMismatch)
            .collect();
        assert!(!cl.is_empty(), "应检测到跨层延迟失配");
        assert!(
            cl[0].summary.contains("客户端/UI 层"),
            "归因应偏向客户端/UI 层，got: {}",
            cl[0].summary
        );
        assert_eq!(cl[0].scope, PerformanceDiagnosisScope::ClientInstance);
    }

    #[test]
    fn cross_layer_attribution_points_to_protocol_when_ws_pipeline_also_high() {
        // client file_tree p95 高 + WS 管线同步升高 + 无 Core 工作区数据
        // → 应归因为 Core/协议层
        let mut report = client_report_for("inst_proto", "macos", "proj_y", "ws2");
        report.file_tree_request = latency_with(600, 600, 5);

        let snap = PerformanceObservabilitySnapshot {
            core_memory: empty_core_memory(),
            ws_pipeline_latency: latency_with(150, 150, 3), // WS 管线升高（>= 100ms warning）
            workspace_metrics: Vec::new(),                  // 无对应 Core 工作区数据
            client_metrics: vec![report],
            diagnoses: Vec::new(),
            snapshot_at: 0,
        };
        let d = build_performance_diagnoses(&snap);
        let cl: Vec<_> = d
            .iter()
            .filter(|d| d.reason == PerformanceDiagnosisReason::CrossLayerLatencyMismatch)
            .collect();
        assert!(!cl.is_empty(), "应检测到跨层延迟失配（协议侧）");
        assert!(
            cl[0].summary.contains("Core/协议"),
            "归因应偏向 Core/协议，got: {}",
            cl[0].summary
        );
    }

    // ── 诊断结果字段完整性 ───────────────────────────────────────────────

    #[test]
    fn diagnosis_has_non_empty_id_summary_and_recommended_action() {
        let mut snap = empty_obs();
        snap.core_memory.phys_footprint_bytes = 768 * 1024 * 1024;
        let d = build_performance_diagnoses(&snap);
        let diag = d
            .iter()
            .find(|d| d.reason == PerformanceDiagnosisReason::CoreMemoryPressure)
            .expect("应存在 CoreMemoryPressure 诊断");
        assert!(!diag.diagnosis_id.is_empty(), "diagnosis_id 不能为空");
        assert!(
            diag.diagnosis_id.contains("perf:core_memory_pressure"),
            "diagnosis_id 应包含原因前缀，got: {}",
            diag.diagnosis_id
        );
        assert!(!diag.summary.is_empty(), "summary 不能为空");
        assert!(
            !diag.recommended_action.is_empty(),
            "recommended_action 不能为空"
        );
    }
}
