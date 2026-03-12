//! 热点性能守卫入口
//!
//! 运行三类热点路径（文件索引、Git 状态、AI 上下文）的全部 7 个固定场景，
//! 输出稳定的机器可读 JSON 测量结果，供比较器脚本消费。
//!
//! ## 用法
//! ```bash
//! cargo run --manifest-path core/Cargo.toml --bin hotspot_perf_guard -- \
//!     --output build/perf/hotspot-measurements.json
//! ```
//!
//! ## 输出 schema
//! - `schema_version`：当前为 "1"
//! - `suite_id`："hotspot_perf_guard"
//! - `generated_at`：ISO 8601 时间戳
//! - `scenarios[]`：7 个场景的测量结果

use std::path::PathBuf;

use tidyflow_core::perf::hotspot_guard::measure_all_scenarios;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let output_path = parse_output_arg();

    eprintln!("[hotspot_perf_guard] 开始运行 7 个热点场景...");
    let measurements = measure_all_scenarios().await;

    let json = serde_json::to_string_pretty(&measurements)?;

    if let Some(path) = &output_path {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, &json)?;
        eprintln!(
            "[hotspot_perf_guard] 测量结果已写入: {}",
            path.display()
        );
    } else {
        println!("{}", json);
    }

    eprintln!("[hotspot_perf_guard] 完成，共 {} 个场景", measurements.scenarios.len());
    Ok(())
}

fn parse_output_arg() -> Option<PathBuf> {
    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        if args[i] == "--output" || args[i] == "-o" {
            if i + 1 < args.len() {
                return Some(PathBuf::from(&args[i + 1]));
            }
        } else if let Some(val) = args[i].strip_prefix("--output=") {
            return Some(PathBuf::from(val));
        }
        i += 1;
    }
    None
}
