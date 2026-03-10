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
