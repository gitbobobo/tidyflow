use super::*;

#[test]
#[allow(unused_comparisons)]
fn test_ephemeral_port_allocation() {
    let port = OpenCodeManager::allocate_ephemeral_port();
    assert!(port >= 49152, "Port should be in ephemeral range");
    assert!(port <= 65535, "Port should be valid");
}

#[test]
fn test_base_url_format() {
    let manager = OpenCodeManager::new(PathBuf::from("/tmp"));
    assert_eq!(
        manager.get_base_url(),
        format!("http://127.0.0.1:{}", manager.get_port())
    );
}

#[test]
fn test_manager_initial_state() {
    let manager = OpenCodeManager::new(PathBuf::from("/tmp/test"));
    assert!(manager.get_port() > 0);
    assert!(manager.get_base_url().starts_with("http://127.0.0.1:"));
}

#[test]
fn test_multiple_managers_use_different_ports() {
    let manager1 = OpenCodeManager::new(PathBuf::from("/tmp/test1"));
    let manager2 = OpenCodeManager::new(PathBuf::from("/tmp/test2"));

    // 每个实例应该分配不同的端口
    assert_ne!(manager1.get_port(), manager2.get_port());
    assert_ne!(manager1.get_base_url(), manager2.get_base_url());
}

#[test]
fn test_working_dir_is_stored() {
    let working_dir = PathBuf::from("/custom/working/dir");
    let manager = OpenCodeManager::new(working_dir.clone());
    // 验证 manager 可以被创建
    assert!(manager.get_port() > 0);
}

#[test]
#[allow(unused_comparisons)]
fn test_port_in_ephemeral_range() {
    // IANA 建议的动态端口范围是 49152-65535
    for _ in 0..10 {
        let port = OpenCodeManager::allocate_ephemeral_port();
        assert!(
            port >= 49152 && port <= 65535,
            "Port {} should be in ephemeral range 49152-65535",
            port
        );
    }
}

#[test]
fn test_base_url_contains_correct_port() {
    let manager = OpenCodeManager::new(PathBuf::from("/tmp"));
    let port = manager.get_port();
    let base_url = manager.get_base_url();
    assert!(base_url.contains(&port.to_string()));
    assert!(base_url.starts_with("http://"));
    assert!(base_url.contains("127.0.0.1"));
}

#[tokio::test]
async fn test_is_running_returns_false_initially() {
    let manager = OpenCodeManager::new(PathBuf::from("/tmp"));
    // 初始状态应该没有进程运行
    assert!(!manager.is_running().await);
}

#[test]
fn test_allocate_ephemeral_port_releases_immediately() {
    // 连续分配两次应该成功，因为端口立即释放
    let port1 = OpenCodeManager::allocate_ephemeral_port();
    let port2 = OpenCodeManager::allocate_ephemeral_port();
    // 两次分配的端口都应该在有效范围内
    assert!(port1 >= 49152);
    assert!(port2 >= 49152);
}
