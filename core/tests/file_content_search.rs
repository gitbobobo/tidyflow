//! 文件内容搜索集成测试
//!
//! 覆盖：文本搜索定位、大小写敏感/不敏感、二进制文件过滤、忽略目录过滤、截断行为

use std::fs;
use tempfile::TempDir;

/// 创建临时工作区目录结构
fn setup_workspace() -> TempDir {
    let dir = TempDir::new().unwrap();
    let root = dir.path();

    // 创建测试文件
    fs::create_dir_all(root.join("src")).unwrap();
    fs::write(
        root.join("src/main.rs"),
        "fn main() {\n    println!(\"Hello, world!\");\n    let x = 42;\n}\n",
    )
    .unwrap();

    fs::write(
        root.join("src/lib.rs"),
        "pub fn add(a: i32, b: i32) -> i32 {\n    a + b\n}\n\npub fn hello() {\n    println!(\"hello\");\n}\n",
    )
    .unwrap();

    fs::write(
        root.join("README.md"),
        "# Test Project\n\nThis is a test.\n",
    )
    .unwrap();

    // 隐藏目录（应被跳过）
    fs::create_dir_all(root.join(".git")).unwrap();
    fs::write(
        root.join(".git/config"),
        "should be ignored\nHello hidden\n",
    )
    .unwrap();

    // node_modules（应被跳过）
    fs::create_dir_all(root.join("node_modules/pkg")).unwrap();
    fs::write(
        root.join("node_modules/pkg/index.js"),
        "module.exports = 'Hello';\n",
    )
    .unwrap();

    // 二进制文件（前 8KB 包含 null 字节）
    let mut binary_content = b"Hello binary\x00world".to_vec();
    binary_content.extend_from_slice(&[0u8; 100]);
    fs::write(root.join("src/data.bin"), binary_content).unwrap();

    dir
}

#[test]
fn test_basic_search() {
    let workspace = setup_workspace();
    let result = tidyflow_core::server::file_index::search_file_contents(
        workspace.path(),
        "Hello",
        false,
    )
    .unwrap();

    assert!(result.total_matches > 0, "应找到匹配结果");
    assert!(!result.truncated, "不应截断");
    assert!(result.search_duration_ms < 5000, "应快速完成");

    // 验证所有结果都有必需字段
    for item in &result.items {
        assert!(!item.path.is_empty(), "path 不应为空");
        assert!(item.line > 0, "line 应从 1 开始");
        assert!(!item.preview.is_empty(), "preview 不应为空");
        assert!(!item.match_ranges.is_empty(), "match_ranges 不应为空");
    }
}

#[test]
fn test_case_sensitive_search() {
    let workspace = setup_workspace();

    // 大小写敏感搜索 "Hello"
    let sensitive = tidyflow_core::server::file_index::search_file_contents(
        workspace.path(),
        "Hello",
        true,
    )
    .unwrap();

    // 大小写不敏感搜索 "Hello"
    let insensitive = tidyflow_core::server::file_index::search_file_contents(
        workspace.path(),
        "Hello",
        false,
    )
    .unwrap();

    // 不敏感搜索应找到更多结果（"hello" 也匹配）
    assert!(
        insensitive.total_matches >= sensitive.total_matches,
        "大小写不敏感搜索应找到 >= 敏感搜索的匹配数"
    );
}

#[test]
fn test_binary_file_skipped() {
    let workspace = setup_workspace();
    let result = tidyflow_core::server::file_index::search_file_contents(
        workspace.path(),
        "binary",
        false,
    )
    .unwrap();

    // 二进制文件中的 "binary" 不应被搜索到
    for item in &result.items {
        assert!(
            !item.path.ends_with(".bin"),
            "应跳过二进制文件，但找到了: {}",
            item.path
        );
    }
}

#[test]
fn test_ignored_directories_skipped() {
    let workspace = setup_workspace();
    let result = tidyflow_core::server::file_index::search_file_contents(
        workspace.path(),
        "Hello",
        false,
    )
    .unwrap();

    for item in &result.items {
        assert!(
            !item.path.starts_with(".git/"),
            "应跳过隐藏目录: {}",
            item.path
        );
        assert!(
            !item.path.starts_with("node_modules/"),
            "应跳过 node_modules: {}",
            item.path
        );
    }
}

#[test]
fn test_empty_query_returns_empty() {
    let workspace = setup_workspace();
    let result =
        tidyflow_core::server::file_index::search_file_contents(workspace.path(), "", false)
            .unwrap();

    assert_eq!(result.total_matches, 0);
    assert!(result.items.is_empty());
    assert!(!result.truncated);
}

#[test]
fn test_no_matches() {
    let workspace = setup_workspace();
    let result = tidyflow_core::server::file_index::search_file_contents(
        workspace.path(),
        "xyzzy_nonexistent_string_12345",
        false,
    )
    .unwrap();

    assert_eq!(result.total_matches, 0);
    assert!(result.items.is_empty());
}

#[test]
fn test_context_lines() {
    let workspace = setup_workspace();
    let result = tidyflow_core::server::file_index::search_file_contents(
        workspace.path(),
        "let x",
        false,
    )
    .unwrap();

    assert!(result.total_matches > 0, "应找到 'let x'");

    let item = &result.items[0];
    assert!(
        item.before_context.len() <= 2,
        "before_context 最多 2 行"
    );
    assert!(
        item.after_context.len() <= 2,
        "after_context 最多 2 行"
    );
}

#[test]
fn test_match_ranges() {
    let workspace = setup_workspace();
    let result = tidyflow_core::server::file_index::search_file_contents(
        workspace.path(),
        "println",
        false,
    )
    .unwrap();

    assert!(result.total_matches > 0);
    for item in &result.items {
        for (start, end) in &item.match_ranges {
            let length = end - start;
            assert_eq!(
                length as usize,
                "println".len(),
                "匹配长度应等于查询长度"
            );
            assert!(
                (*start as usize) < item.preview.len() + 10,
                "匹配起始位置应合理"
            );
        }
    }
}

#[test]
fn test_workspace_isolation() {
    // 创建两个独立工作区
    let ws1 = setup_workspace();
    let ws2 = TempDir::new().unwrap();
    fs::write(
        ws2.path().join("unique.txt"),
        "unique_string_ws2_only\n",
    )
    .unwrap();

    let result1 = tidyflow_core::server::file_index::search_file_contents(
        ws1.path(),
        "unique_string_ws2_only",
        false,
    )
    .unwrap();

    let result2 = tidyflow_core::server::file_index::search_file_contents(
        ws2.path(),
        "unique_string_ws2_only",
        false,
    )
    .unwrap();

    assert_eq!(result1.total_matches, 0, "ws1 不应找到 ws2 的内容");
    assert!(result2.total_matches > 0, "ws2 应找到自己的内容");
}
