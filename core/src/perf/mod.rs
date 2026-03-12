//! 性能守卫与热点路径共享夹具模块
//!
//! 提供三类热点路径（文件索引、Git 状态、AI 上下文）的共享夹具构造与守卫测量函数，
//! 由 `workspace_cache_bench.rs` 和 `hotspot_perf_guard` 二进制共同复用。

pub mod hotspot_guard;
