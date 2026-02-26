use std::sync::atomic::{AtomicU64, Ordering};

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

const PERF_LOG_INTERVAL: u64 = 200;

pub fn record_task_broadcast_lag(lagged: u64) {
    let total = WS_TASK_BROADCAST_LAG_TOTAL.fetch_add(lagged, Ordering::Relaxed) + lagged;
    WS_TASK_BROADCAST_QUEUE_DEPTH.store(lagged, Ordering::Relaxed);

    if total % PERF_LOG_INTERVAL == 0 {
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
    if sample_count % PERF_LOG_INTERVAL == 0 {
        info!("perf ws_task_broadcast_queue_depth={}", depth);
    }
}

pub fn record_task_broadcast_skipped_single_receiver() {
    let total = WS_TASK_BROADCAST_SKIPPED_SINGLE_RECEIVER_TOTAL.fetch_add(1, Ordering::Relaxed) + 1;
    if total % PERF_LOG_INTERVAL == 0 {
        info!(
            "perf ws_task_broadcast_skipped_single_receiver_total={}",
            total
        );
    }
}

pub fn record_task_broadcast_skipped_empty_target() {
    let total = WS_TASK_BROADCAST_SKIPPED_EMPTY_TARGET_TOTAL.fetch_add(1, Ordering::Relaxed) + 1;
    if total % PERF_LOG_INTERVAL == 0 {
        info!(
            "perf ws_task_broadcast_skipped_empty_target_total={}",
            total
        );
    }
}

pub fn record_task_broadcast_filtered_target() {
    let total = WS_TASK_BROADCAST_FILTERED_TARGET_TOTAL.fetch_add(1, Ordering::Relaxed) + 1;
    if total % PERF_LOG_INTERVAL == 0 {
        info!("perf ws_task_broadcast_filtered_target_total={}", total);
    }
}

pub fn record_terminal_unacked_timeout(term_id: &str, unacked_before_decay: u64) {
    let total = TERMINAL_UNACKED_TIMEOUT_TOTAL.fetch_add(1, Ordering::Relaxed) + 1;

    if total % 20 == 0 {
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
    if total % PERF_LOG_INTERVAL == 0 {
        info!("perf project_command_output_throttled_total={}", total);
    }
}

pub fn record_project_command_output_emitted() {
    let total = PROJECT_COMMAND_OUTPUT_EMITTED_TOTAL.fetch_add(1, Ordering::Relaxed) + 1;
    if total % PERF_LOG_INTERVAL == 0 {
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

    if count % PERF_LOG_INTERVAL == 0 {
        let max_ms = WS_OUTBOUND_LOOP_TICK_MAX_MS.load(Ordering::Relaxed);
        let select_wait_ms = WS_OUTBOUND_SELECT_WAIT_MS.load(Ordering::Relaxed);
        let select_wait_max_ms = WS_OUTBOUND_SELECT_WAIT_MAX_MS.load(Ordering::Relaxed);
        let select_wait_count = WS_OUTBOUND_SELECT_WAIT_COUNT.load(Ordering::Relaxed);
        let handle_ms = WS_OUTBOUND_HANDLE_MS.load(Ordering::Relaxed);
        let handle_max_ms = WS_OUTBOUND_HANDLE_MAX_MS.load(Ordering::Relaxed);
        let handle_count = WS_OUTBOUND_HANDLE_COUNT.load(Ordering::Relaxed);
        info!(
            "perf ws_outbound_loop_tick_ms={} ws_outbound_loop_tick_max_ms={} ws_outbound_loop_tick_count={} ws_outbound_select_wait_ms={} ws_outbound_select_wait_max_ms={} ws_outbound_select_wait_count={} ws_outbound_handle_ms={} ws_outbound_handle_max_ms={} ws_outbound_handle_count={}",
            ms,
            max_ms,
            count,
            select_wait_ms,
            select_wait_max_ms,
            select_wait_count,
            handle_ms,
            handle_max_ms,
            handle_count
        );
    }
}
